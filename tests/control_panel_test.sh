#!/usr/bin/env bash
###############################################################################
# control_panel_test.sh -- functional test harness for the web control
# panel (control-panel.py, control-panel-instance-action.sh,
# setup-control-panel.sh). Companion to tests/profile_smoke_test.sh, using
# the same sandboxed-mock-systemctl approach it establishes -- no root, no
# real systemd, no network beyond 127.0.0.1, nothing outside a throwaway
# temp directory is touched.
#
# What this actually proves, end to end:
#   - The server fails CLOSED before an operator opts in (403 on every
#     action, even with no token supplied at all).
#   - setup-control-panel.sh --enable genuinely turns it on and produces a
#     usable token.
#   - Missing / wrong / query-string-only tokens are all rejected (401).
#   - GET on an action path is rejected (405) -- actions are POST-only.
#   - A valid token genuinely starts/stops/restarts the mocked instance --
#     verified by querying the mock systemctl's own state afterward, not
#     just by trusting the HTTP response code.
#   - Unknown instance names and invalid actions are rejected (404/400)
#     before ever reaching the privileged action script.
#
# Usage: tests/control_panel_test.sh
# Exit code: 0 if every check passed, 1 otherwise.
###############################################################################
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"
SCRIPTS_DIR="${REPO_ROOT}/multi-game-platform/scripts"
PANEL_PY="${SCRIPTS_DIR}/control-panel.py"
ACTION_SH="${SCRIPTS_DIR}/control-panel-instance-action.sh"
SETUP_SH="${SCRIPTS_DIR}/setup-control-panel.sh"

command -v python3 >/dev/null 2>&1 || { echo "python3 not found -- cannot run this test." >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "openssl not found -- cannot run this test." >&2; exit 1; }

PASS_COUNT=0
FAIL_COUNT=0
FAILURES=()
pass() { PASS_COUNT=$(( PASS_COUNT + 1 )); echo "  [ OK ] $1"; }
fail() { FAIL_COUNT=$(( FAIL_COUNT + 1 )); FAILURES+=("$1"); echo "  [FAIL] $1"; }
section() { echo; echo "=== $1 ==="; }

SANDBOX="$(mktemp -d)"
MOCK_BIN="$(mktemp -d)"
GS_BASE="${SANDBOX}/gameservers"
CONF_FILE="${GS_BASE}/control-panel.conf"
REGISTRY="${GS_BASE}/instances.registry"
INSTANCES_DIR="${GS_BASE}/instances"
STATE_FILE="${SANDBOX}/systemctl_state"
SERVER_LOG="${SANDBOX}/server.log"
SERVER_PID=""

cleanup() {
    [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" >/dev/null 2>&1
    rm -rf "$SANDBOX" "$MOCK_BIN"
}
trap cleanup EXIT

###############################################################################
# Sandbox fixture: one on-demand=0 instance ("myinstance") and its registry
# entry, plus a mocked systemctl (state-file-backed, identical shape to
# the one in tests/profile_smoke_test.sh) and a mocked ss reporting the
# instance's port as listening only while its unit is active.
###############################################################################
mkdir -p "${INSTANCES_DIR}/myinstance"
cat > "${INSTANCES_DIR}/myinstance/config.env" << 'EOF'
INSTANCE_NAME="myinstance"
GAME="testgame"
SERVER_PORT=27999
ON_DEMAND=0
EOF
echo "myinstance:testgame:27999:2026-01-01 00:00:00" > "$REGISTRY"

write_mock() {
    local name="$1" body="$2"
    cat > "${MOCK_BIN}/${name}" << MOCKEOF
#!/usr/bin/env bash
${body}
MOCKEOF
    chmod +x "${MOCK_BIN}/${name}"
}

write_mock systemctl '
state_file="'"${STATE_FILE}"'"
touch "$state_file"
cmd="${1:-}"; unit="${2:-}"
case "$cmd" in
    start)   sed -i.bak "/^${unit}=/d" "$state_file" 2>/dev/null; echo "${unit}=active" >> "$state_file" ;;
    stop)    sed -i.bak "/^${unit}=/d" "$state_file" 2>/dev/null; echo "${unit}=inactive" >> "$state_file" ;;
    restart) sed -i.bak "/^${unit}=/d" "$state_file" 2>/dev/null; echo "${unit}=active" >> "$state_file" ;;
    is-active)
        grep -q "^${unit}=active$" "$state_file" 2>/dev/null && { echo active; exit 0; }
        echo inactive; exit 3 ;;
    *) exit 0 ;;
esac
'
write_mock ss '
state_file="'"${STATE_FILE}"'"
if grep -q "^gameserver@myinstance=active$" "$state_file" 2>/dev/null; then
    echo "UNCONN 0 0 0.0.0.0:27999 0.0.0.0:*"
fi
exit 0
'

export PATH="${MOCK_BIN}:${PATH}"
export CONTROL_PANEL_GS_BASE="$GS_BASE"
export CONTROL_PANEL_ACTION_ALLOW_NONROOT=1

###############################################################################
# 1. Static analysis sanity (the repo-wide sweep in profile_smoke_test.sh
#    already covers these files too -- this is a fast, local double-check
#    specific to this feature so a broken syntax error here fails loudly
#    and immediately in this test's own output).
###############################################################################
section "Static analysis"
if bash -n "$ACTION_SH" 2>/dev/null; then pass "bash -n: control-panel-instance-action.sh"; else fail "bash -n: control-panel-instance-action.sh"; fi
if bash -n "$SETUP_SH" 2>/dev/null; then pass "bash -n: setup-control-panel.sh"; else fail "bash -n: setup-control-panel.sh"; fi
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -s bash -S error "$ACTION_SH" >/dev/null 2>&1; then pass "shellcheck -S error: control-panel-instance-action.sh"; else fail "shellcheck -S error: control-panel-instance-action.sh"; fi
    if shellcheck -s bash -S error "$SETUP_SH" >/dev/null 2>&1; then pass "shellcheck -S error: setup-control-panel.sh"; else fail "shellcheck -S error: setup-control-panel.sh"; fi
else
    fail "shellcheck not found on PATH -- install it to run the same gate CI uses"
fi
if python3 -m py_compile "$PANEL_PY" 2>/dev/null; then pass "python3 -m py_compile: control-panel.py"; else fail "python3 -m py_compile: control-panel.py"; fi
find "${REPO_ROOT}" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true

###############################################################################
# 2. Server starts DISABLED (no config written yet) -- every action must
#    be refused with 403, even with no Authorization header at all. This
#    is the "fails closed before opt-in" guarantee.
###############################################################################
section "Fail-closed: before setup-control-panel.sh has ever run"

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')

start_server() {
    python3 "$PANEL_PY" \
        --conf "$CONF_FILE" \
        --registry "$REGISTRY" \
        --action-script "$ACTION_SH" \
        --audit-log "${SANDBOX}/audit.log" \
        --bind 127.0.0.1 --port "$PORT" \
        > "$SERVER_LOG" 2>&1 &
    SERVER_PID=$!
    for _ in $(seq 1 50); do
        if curl -s -o /dev/null "http://127.0.0.1:${PORT}/api/status"; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

if start_server; then
    pass "control-panel.py started and is accepting connections"
else
    fail "control-panel.py never started listening (see ${SERVER_LOG})"
    cat "$SERVER_LOG" >&2
fi

code=$(curl -s -o /tmp/cp_body.$$ -w '%{http_code}' -X POST "http://127.0.0.1:${PORT}/api/instances/myinstance/start")
body=$(cat /tmp/cp_body.$$ 2>/dev/null); rm -f /tmp/cp_body.$$
if [[ "$code" == "403" ]]; then pass "POST start with no config at all -> 403 (fail closed)"; else fail "POST start with no config -> expected 403, got ${code} (${body})"; fi

code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/api/status")
if [[ "$code" == "200" ]]; then pass "GET /api/status still works while actions are disabled (read-only stays available)"; else fail "GET /api/status expected 200, got ${code}"; fi

###############################################################################
# 3. Run the real opt-in setup script and confirm it actually enables
#    things -- extract the printed token the same way an operator would
#    read it off their own terminal.
###############################################################################
section "setup-control-panel.sh --enable"

SETUP_OUT="$("$SETUP_SH" --enable -y --no-systemd --bind 127.0.0.1 --port "$PORT" 2>&1)"
TOKEN="$(echo "$SETUP_OUT" | awk '/^   [0-9a-f]{64}$/ {print $1; exit}')"

if [[ -f "$CONF_FILE" ]]; then pass "setup-control-panel.sh --enable wrote ${CONF_FILE}"; else fail "setup-control-panel.sh --enable did not write a config file"; fi
if grep -q '^CONTROL_PANEL_ENABLED=1' "$CONF_FILE" 2>/dev/null; then pass "config file has CONTROL_PANEL_ENABLED=1"; else fail "config file missing CONTROL_PANEL_ENABLED=1"; fi
if [[ "${#TOKEN}" -eq 64 ]]; then pass "a 64-hex-char token was generated and printed"; else fail "could not extract a 64-char token from setup output: ${SETUP_OUT}"; fi
# GNU stat (-c, real Ubuntu target + CI) tried first, BSD/macOS stat
# (-f) as a local-dev-on-Mac fallback. Order matters: GNU stat's "-f"
# flag means something different (filesystem status, not file mode)
# and doesn't fail cleanly on an unrecognized %Lp directive -- it just
# prints something that isn't "600" -- so putting the BSD form first
# silently reported "not mode 600" on every Linux/CI run regardless
# of the real (correct) permissions.
if [[ "$(stat -c '%a' "$CONF_FILE" 2>/dev/null || stat -f '%Lp' "$CONF_FILE" 2>/dev/null)" == "600" ]]; then
    pass "config file is mode 600"
else
    fail "config file is not mode 600"
fi

###############################################################################
# 4. Auth rejection paths, now that actions ARE enabled -- these are the
#    "even with the feature turned on, a bad/missing credential still
#    gets nowhere" checks. control-panel.py re-reads the config file on
#    every request, so no server restart is needed after step 3.
###############################################################################
section "Auth rejection paths (feature enabled, credential missing/wrong)"

code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:${PORT}/api/instances/myinstance/start")
if [[ "$code" == "401" ]]; then pass "POST start with NO Authorization header -> 401"; else fail "expected 401 with no header, got ${code}"; fi

code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer wrong-token-entirely" "http://127.0.0.1:${PORT}/api/instances/myinstance/start")
if [[ "$code" == "401" ]]; then pass "POST start with WRONG token -> 401"; else fail "expected 401 with wrong token, got ${code}"; fi

code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:${PORT}/api/instances/myinstance/start?token=${TOKEN}")
if [[ "$code" == "401" ]]; then pass "correct token passed via QUERY STRING (not header) -> still 401, never accepted"; else fail "expected 401 for query-string token, got ${code}"; fi

code=$(curl -s -o /dev/null -w '%{http_code}' -X GET -H "Authorization: Bearer ${TOKEN}" "http://127.0.0.1:${PORT}/api/instances/myinstance/start")
if [[ "$code" == "405" ]]; then pass "GET (instead of POST) on an action path with a valid token -> 405"; else fail "expected 405 for GET on action path, got ${code}"; fi

###############################################################################
# 5. Auth success path -- confirm the HTTP response AND that the
#    underlying mocked systemd unit genuinely changed state, not just
#    that the server said "ok".
###############################################################################
section "Auth success path: valid token genuinely starts/stops/restarts"

: > "$STATE_FILE"  # instance starts "stopped" (no state line = inactive)

code=$(curl -s -o /tmp/cp_start.$$ -w '%{http_code}' -X POST -H "Authorization: Bearer ${TOKEN}" "http://127.0.0.1:${PORT}/api/instances/myinstance/start")
start_body="$(cat /tmp/cp_start.$$ 2>/dev/null)"; rm -f /tmp/cp_start.$$
if [[ "$code" == "200" ]]; then pass "POST start with VALID token -> 200"; else fail "POST start with valid token expected 200, got ${code} (${start_body})"; fi
if grep -q '^gameserver@myinstance=active$' "$STATE_FILE" 2>/dev/null; then
    pass "mock systemctl state genuinely shows gameserver@myinstance=active after start (not just an HTTP 200)"
else
    fail "mock systemctl state does NOT show the unit active after a 200 start response -- the action didn't really happen"
fi

code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/api/status")
listening=$(curl -s "http://127.0.0.1:${PORT}/api/status" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["instances"][0]["listening"])' 2>/dev/null)
if [[ "$listening" == "True" ]]; then pass "GET /api/status reflects the port now listening, post-start"; else fail "GET /api/status did not reflect the started instance (listening=${listening})"; fi

code=$(curl -s -o /tmp/cp_stop.$$ -w '%{http_code}' -X POST -H "Authorization: Bearer ${TOKEN}" "http://127.0.0.1:${PORT}/api/instances/myinstance/stop")
stop_body="$(cat /tmp/cp_stop.$$ 2>/dev/null)"; rm -f /tmp/cp_stop.$$
if [[ "$code" == "200" ]]; then pass "POST stop with VALID token -> 200"; else fail "POST stop expected 200, got ${code} (${stop_body})"; fi
if grep -q '^gameserver@myinstance=inactive$' "$STATE_FILE" 2>/dev/null; then
    pass "mock systemctl state genuinely shows the unit inactive after stop"
else
    fail "mock systemctl state still shows the unit active after a 200 stop response"
fi

code=$(curl -s -o /tmp/cp_restart.$$ -w '%{http_code}' -X POST -H "Authorization: Bearer ${TOKEN}" "http://127.0.0.1:${PORT}/api/instances/myinstance/restart")
restart_body="$(cat /tmp/cp_restart.$$ 2>/dev/null)"; rm -f /tmp/cp_restart.$$
if [[ "$code" == "200" ]]; then pass "POST restart with VALID token -> 200"; else fail "POST restart expected 200, got ${code} (${restart_body})"; fi
if grep -q '^gameserver@myinstance=active$' "$STATE_FILE" 2>/dev/null; then
    pass "mock systemctl state genuinely shows the unit active again after restart"
else
    fail "mock systemctl state does not show the unit active after restart"
fi

###############################################################################
# 6. Input validation: unknown instance / invalid action must never reach
#    the privileged action script at all.
###############################################################################
section "Input validation (before ever invoking the privileged action script)"

code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer ${TOKEN}" "http://127.0.0.1:${PORT}/api/instances/no-such-instance/start")
if [[ "$code" == "404" ]]; then pass "POST start for an UNKNOWN instance -> 404"; else fail "expected 404 for unknown instance, got ${code}"; fi

code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer ${TOKEN}" "http://127.0.0.1:${PORT}/api/instances/myinstance/reboot-the-host")
if [[ "$code" == "400" ]]; then pass "POST an INVALID action ('reboot-the-host') -> 400"; else fail "expected 400 for invalid action, got ${code}"; fi

###############################################################################
# 7. Disable path: setup-control-panel.sh --disable makes the (still
#    technically valid) token stop working immediately.
###############################################################################
section "setup-control-panel.sh --disable"

"$SETUP_SH" --disable --no-systemd >/dev/null 2>&1
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer ${TOKEN}" "http://127.0.0.1:${PORT}/api/instances/myinstance/start")
if [[ "$code" == "403" ]]; then pass "after --disable, the SAME previously-valid token now gets 403"; else fail "after --disable, expected 403, got ${code}"; fi

###############################################################################
# Summary
###############################################################################
section "Summary"
echo "  ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
    echo
    echo "Failures:"
    for f in "${FAILURES[@]}"; do
        echo "  - $f"
    done
    echo
    echo "Server log:"
    cat "$SERVER_LOG" 2>/dev/null
fi

[[ "$FAIL_COUNT" -eq 0 ]] && exit 0 || exit 1

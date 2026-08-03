#!/usr/bin/env bash
###############################################################################
# profile_smoke_test.sh -- contributor-facing smoke test harness.
#
# Formalizes the "sandboxed mock environment" CONTRIBUTING.md refers to
# (fake systemctl/ss/journalctl, no real Steam/Wine/hardware needed) into a
# single command a contributor can run locally, or CI can run on every push,
# to catch real regressions -- not just syntax errors -- without ever
# touching a real system: no root required, nothing outside a throwaway
# temp directory is written to, no package is installed, no systemd unit is
# touched.
#
# What this does NOT replace: CONTRIBUTING.md's own real-VM checklist (Wine
# profiles, SteamCMD downloads, actual systemd units) still needs a real,
# disposable Ubuntu box -- this script only proves the parts of the
# platform that can be proven without one.
#
# Usage:
#   tests/profile_smoke_test.sh            # run every check
#   tests/profile_smoke_test.sh --quick     # skip the slower per-profile
#                                            # --check/--validate-profile
#                                            # subprocess loop (static +
#                                            # unit checks only)
#
# Exit code: 0 if every check passed, 1 if anything failed (see the
# summary printed at the end either way).
###############################################################################
set -uo pipefail
# Deliberately NOT set -e: this script's whole job is to run many
# independent checks and report ALL failures at the end, not abort at the
# first one (which would hide every check after it on this run).

QUICK=0
[[ "${1:-}" == "--quick" ]] && QUICK=1

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"
PLATFORM_DIR="${REPO_ROOT}/multi-game-platform"
INSTALLER="${PLATFORM_DIR}/install-game-server.sh"
COMMON_SH="${REPO_ROOT}/lib/common.sh"

PASS_COUNT=0
FAIL_COUNT=0
FAILURES=()
SHELLCHECK_OFFENSE_COUNT=0

# pass/fail: the two primitives every check below reports through, so the
# final summary is always accurate no matter how a given check is written.
pass() { PASS_COUNT=$(( PASS_COUNT + 1 )); echo "  [ OK ] $1"; }
fail() { FAIL_COUNT=$(( FAIL_COUNT + 1 )); FAILURES+=("$1"); echo "  [FAIL] $1"; }
section() { echo; echo "=== $1 ==="; }

# Report location: tests/../test-results/latest.md (gitignored -- generated
# fresh on every run, not committed). REPORT_DIR is created up front so a
# failure partway through this script still leaves a directory to write
# into via the EXIT trap below.
REPORT_DIR="${REPO_ROOT}/test-results"
REPORT_FILE="${REPORT_DIR}/latest.md"
mkdir -p "$REPORT_DIR"

MOCK_BIN="$(mktemp -d)"
SANDBOX="$(mktemp -d)"
cleanup() { rm -rf "$MOCK_BIN" "$SANDBOX"; }
trap cleanup EXIT

###############################################################################
# Mock environment: fake systemctl/ss/journalctl/steamcmd, matching the
# sandboxed approach CONTRIBUTING.md describes. These are deliberately
# simple state machines controlled by env vars rather than full re-
# implementations -- enough to exercise this codebase's own branches
# (is-active vs not, a port already bound vs not), not to simulate systemd
# itself.
###############################################################################
write_mock() {
    local name="$1" body="$2"
    cat > "${MOCK_BIN}/${name}" << MOCKEOF
#!/usr/bin/env bash
${body}
MOCKEOF
    chmod +x "${MOCK_BIN}/${name}"
}

# ss: reports listening sockets from a caller-supplied port list
# (MOCK_SS_BUSY_PORTS, space-separated), in the same "LISTEN ... :PORT"
# shape the real `ss -uln`/`ss -tln` output has -- specifically the part
# port_block_free/gather_generic_instance_input actually grep for
# (":${port}" followed by whitespace).
write_mock ss '
for p in ${MOCK_SS_BUSY_PORTS:-}; do
    echo "UNCONN 0 0 0.0.0.0:${p} 0.0.0.0:*"
done
exit 0
'

# systemctl: tracks "active"/"inactive" per unit name via a state file, so
# a mock "systemctl start X" makes a later "systemctl is-active X" report
# active, without a real systemd anywhere nearby.
write_mock systemctl '
state_file="${MOCK_STATE_DIR:-/tmp}/systemctl_state"
touch "$state_file"
cmd="${1:-}"; unit="${2:-}"
case "$cmd" in
    start)   sed -i.bak "/^${unit}=/d" "$state_file" 2>/dev/null; echo "${unit}=active" >> "$state_file" ;;
    stop)    sed -i.bak "/^${unit}=/d" "$state_file" 2>/dev/null; echo "${unit}=inactive" >> "$state_file" ;;
    restart) sed -i.bak "/^${unit}=/d" "$state_file" 2>/dev/null; echo "${unit}=active" >> "$state_file" ;;
    is-active)
        grep -q "^${unit}=active$" "$state_file" 2>/dev/null && { echo active; exit 0; }
        echo inactive; exit 3 ;;
    status) grep "^${unit}=" "$state_file" 2>/dev/null || echo "${unit}=unknown"; exit 0 ;;
    show) echo "ActiveEnterTimestamp=Thu 2026-01-01 00:00:00 UTC"; exit 0 ;;
    *) exit 0 ;;
esac
'

write_mock journalctl 'echo "-- mock journal: no real systemd on this host --"; exit 0'
write_mock steamcmd.sh 'echo "mock steamcmd: +app_update $* validate +quit (no-op)"; exit 0'

export PATH="${MOCK_BIN}:${PATH}"

###############################################################################
# 1. Static analysis: every .sh file in the repo, PLUS the validate-config.sh
#    template this script generates via a heredoc (and so never exists as
#    its own file on disk -- extracted below so it gets checked too).
###############################################################################
section "Static analysis (bash -n, shellcheck -S error)"

if ! command -v shellcheck > /dev/null 2>&1; then
    fail "shellcheck not found on PATH -- install it (brew install shellcheck / apt-get install shellcheck) to run the same gate CI uses"
else
    while IFS= read -r -d '' f; do
        rel="${f#"${REPO_ROOT}"/}"
        if ! bash -n "$f" 2>/dev/null; then
            fail "bash -n: ${rel}"
        else
            pass "bash -n: ${rel}"
        fi
        sc_out="$(shellcheck -s bash -S error -f gcc "$f" 2>/dev/null)"
        sc_rc=$?
        if [[ -n "$sc_out" ]]; then
            SHELLCHECK_OFFENSE_COUNT=$(( SHELLCHECK_OFFENSE_COUNT + $(wc -l <<< "$sc_out") ))
        fi
        if [[ "$sc_rc" -ne 0 ]]; then
            fail "shellcheck -S error: ${rel}"
        else
            pass "shellcheck -S error: ${rel}"
        fi
    done < <(find "$REPO_ROOT" -type f -name "*.sh" -print0)
fi

# Extract the validate-config.sh template this script writes to disk at
# install time (a literal 'EOF' heredoc inside install-game-server.sh, so
# what's between the markers below is byte-for-byte what a real install
# would produce -- checking it here is the only way it ever gets checked,
# since it has no file of its own in the repo).
VALIDATE_CONFIG_TEMPLATE="${SANDBOX}/validate-config.sh"
awk '
    /cat > "\$\{SCRIPTS_DIR\}\/validate-config\.sh" << .EOF./ { grabbing=1; next }
    grabbing && /^EOF$/ { grabbing=0; exit }
    grabbing { print }
' "$INSTALLER" > "$VALIDATE_CONFIG_TEMPLATE"

if [[ -s "$VALIDATE_CONFIG_TEMPLATE" ]]; then
    if bash -n "$VALIDATE_CONFIG_TEMPLATE" 2>/dev/null; then
        pass "bash -n: extracted validate-config.sh template"
    else
        fail "bash -n: extracted validate-config.sh template"
    fi
    if command -v shellcheck > /dev/null 2>&1; then
        sc_out="$(shellcheck -s bash -S error -f gcc "$VALIDATE_CONFIG_TEMPLATE" 2>/dev/null)"
        sc_rc=$?
        if [[ -n "$sc_out" ]]; then
            SHELLCHECK_OFFENSE_COUNT=$(( SHELLCHECK_OFFENSE_COUNT + $(wc -l <<< "$sc_out") ))
        fi
        if [[ "$sc_rc" -eq 0 ]]; then
            pass "shellcheck -S error: extracted validate-config.sh template"
        else
            fail "shellcheck -S error: extracted validate-config.sh template"
        fi
    fi
else
    fail "could not extract validate-config.sh template out of install-game-server.sh (heredoc markers may have moved -- update the awk pattern in this test)"
fi

###############################################################################
# 2. Unit checks: source lib/common.sh directly and exercise the pure
#    functions that back the structured JSON log (#3 on the original list).
#    Deterministic string comparison instead of a JSON parser, so this has
#    no dependency (jq/python3) beyond bash itself.
###############################################################################
section "lib/common.sh: json_escape / log_json_line"

(
    set -uo pipefail
    # shellcheck source=/dev/null
    source "$COMMON_SH"

    raw=$'A "quoted" \\backslash\\ and a\nnewline plus a\ttab'
    expected='A \"quoted\" \\backslash\\ and a\nnewline plus a\ttab'
    got="$(json_escape "$raw")"
    if [[ "$got" == "$expected" ]]; then
        echo "PASS json_escape: quote/backslash/newline/tab all escaped correctly"
    else
        echo "FAIL json_escape: got [${got}] want [${expected}]"
    fi

    LOG_FILE="${SANDBOX}/fake.log"
    : > "$LOG_FILE"
    log_json_line "INFO" "$raw"
    line="$(cat "${SANDBOX}/fake.jsonl")"
    expected_line='{"ts":"'"$(date '+%Y-%m-%d')"
    if [[ "$line" == \{\"ts\":*\"level\":\"INFO\"* ]] && [[ "$line" == *"\"message\":\"${expected}\"}" ]]; then
        echo "PASS log_json_line: produced a well-formed, correctly-escaped JSON line"
    else
        echo "FAIL log_json_line: unexpected output: ${line}"
    fi

    # jsonl_log_path: .log -> .jsonl, and the "doesn't end in .log" fallback.
    LOG_FILE="/var/log/gameserver-install.log"
    p="$(jsonl_log_path)"
    [[ "$p" == "/var/log/gameserver-install.jsonl" ]] && echo "PASS jsonl_log_path: .log suffix swapped correctly" || echo "FAIL jsonl_log_path: got ${p}"
    LOG_FILE="/var/log/weird-name"
    p="$(jsonl_log_path)"
    [[ "$p" == "/var/log/weird-name.jsonl" ]] && echo "PASS jsonl_log_path: non-.log fallback appends correctly" || echo "FAIL jsonl_log_path: got ${p}"
) > "${SANDBOX}/common_unit.out" 2>&1
while IFS= read -r line; do
    case "$line" in
        PASS*) pass "${line#PASS }" ;;
        FAIL*) fail "${line#FAIL }" ;;
    esac
done < "${SANDBOX}/common_unit.out"

###############################################################################
# 3. Unit checks: port-conflict resolver (port_block_free / find_free_port)
#    against the mocked `ss` above -- proves the auto-suggest logic actually
#    walks past busy ports instead of just being read as plausible.
###############################################################################
section "install-game-server.sh: port_block_free / find_free_port"

(
    set -uo pipefail
    # Source in a subshell (not the parent shell) so this file's own
    # `readonly` constants and IFS change never leak into the rest of this
    # test script. Sourcing (rather than executing) is safe: main() only
    # runs when BASH_SOURCE[0] == $0, which is false when sourced.
    # shellcheck source=/dev/null
    source "$INSTALLER"

    PROFILE_PORT_COUNT=1
    # PORT_RANGE_STEP is `readonly` inside install-game-server.sh (already
    # 10 by default) -- reassigning it would abort this subshell, so it's
    # left alone rather than overridden.

    export MOCK_SS_BUSY_PORTS="25565"
    if port_block_free 25565; then
        echo "FAIL port_block_free: reported 25565 free, but mock ss reports it busy"
    else
        echo "PASS port_block_free: correctly reports a busy port as busy"
    fi
    if port_block_free 25566; then
        echo "PASS port_block_free: correctly reports an unlisted port as free"
    else
        echo "FAIL port_block_free: reported 25566 busy, but mock ss doesn't list it"
    fi

    export MOCK_SS_BUSY_PORTS="25565 25575 25585"
    found="$(find_free_port 25565)"
    if [[ "$found" == "25595" ]]; then
        echo "PASS find_free_port: stepped past 3 consecutive busy blocks (25565/25575/25585) to 25595"
    else
        echo "FAIL find_free_port: expected 25595, got ${found}"
    fi

    export MOCK_SS_BUSY_PORTS=""
    found="$(find_free_port 30000)"
    if [[ "$found" == "30000" ]]; then
        echo "PASS find_free_port: returns the original candidate immediately when already free"
    else
        echo "FAIL find_free_port: expected 30000, got ${found}"
    fi

    # PROFILE_PORT_COUNT > 1: a block is only "free" if EVERY port in it is
    # free -- one busy port inside the range must still block the whole
    # block, not just the exact port that's busy.
    PROFILE_PORT_COUNT=3
    export MOCK_SS_BUSY_PORTS="7779"
    if port_block_free 7777; then
        echo "FAIL port_block_free: block 7777-7779 should be busy (7779 is in-range and busy)"
    else
        echo "PASS port_block_free: correctly blocks a multi-port range when any port inside it is busy"
    fi
) > "${SANDBOX}/port_unit.out" 2>&1
while IFS= read -r line; do
    case "$line" in
        PASS*) pass "${line#PASS }" ;;
        FAIL*) fail "${line#FAIL }" ;;
    esac
done < "${SANDBOX}/port_unit.out"

###############################################################################
# 4. Functional: extracted validate-config.sh template against a synthetic
#    on-disk instance -- both a config that should pass every check and one
#    engineered to fail each check independently, run as a real subprocess
#    (not just read as plausible).
###############################################################################
section "validate-config.sh template: functional pass/fail cases"

if [[ -s "$VALIDATE_CONFIG_TEMPLATE" ]]; then
    RUNNABLE="${SANDBOX}/validate-config-runnable.sh"
    FAKE_SRV="${SANDBOX}/srv/gameservers"
    mkdir -p "${FAKE_SRV}/scripts/profiles" "${FAKE_SRV}/instances/goodinst"
    cp "$COMMON_SH" "${FAKE_SRV}/scripts/common.sh"
    # The template hardcodes /srv/gameservers paths (correct for a real
    # install; this is the only line rewritten for the sandbox, everything
    # else about the file runs untouched).
    sed \
        -e "s#/srv/gameservers/scripts/common.sh#${FAKE_SRV}/scripts/common.sh#" \
        -e "s#/srv/gameservers/instances/#${FAKE_SRV}/instances/#g" \
        -e "s#/srv/gameservers/scripts/profiles/#${FAKE_SRV}/scripts/profiles/#g" \
        "$VALIDATE_CONFIG_TEMPLATE" > "$RUNNABLE"
    chmod +x "$RUNNABLE"

    cat > "${FAKE_SRV}/scripts/profiles/testgame.profile.sh" << 'EOF'
PROFILE_PORT_COUNT=1
PROFILE_EXTRA_CONFIG_VARS=(TG_WORLD_NAME)
EOF

    write_config() {
        cat > "${FAKE_SRV}/instances/goodinst/config.env"
    }

    # Case A: a fully valid config.env -> exit 0.
    write_config << 'EOF'
INSTANCE_NAME="goodinst"
GAME="testgame"
SERVER_PORT="25565"
BACKUP_DIR="/srv/gameservers/instances/goodinst/backups"
BACKUP_RETENTION_DAYS="7"
BACKUP_TIME="03:30"
UPDATE_TIME="04:00"
DISCORD_WEBHOOK_URL=""
ON_DEMAND="0"
TG_WORLD_NAME="world1"
EOF
    if "$RUNNABLE" goodinst > "${SANDBOX}/vc_good.out" 2>&1; then
        pass "validate-config.sh: exits 0 on a fully valid config.env"
    else
        fail "validate-config.sh: expected exit 0 on a valid config, got $?; output: $(cat "${SANDBOX}/vc_good.out")"
    fi

    # Case B: bad port (out of range) -> exit 1, with SERVER_PORT flagged.
    write_config << 'EOF'
INSTANCE_NAME="goodinst"
GAME="testgame"
SERVER_PORT="99"
BACKUP_DIR="/srv/gameservers/instances/goodinst/backups"
BACKUP_RETENTION_DAYS="7"
BACKUP_TIME="03:30"
UPDATE_TIME="04:00"
DISCORD_WEBHOOK_URL=""
ON_DEMAND="0"
TG_WORLD_NAME="world1"
EOF
    out="$("$RUNNABLE" goodinst 2>&1)"; rc=$?
    if [[ "$rc" -ne 0 ]] && grep -q "SERVER_PORT" <<< "$out"; then
        pass "validate-config.sh: catches an out-of-range SERVER_PORT and exits non-zero"
    else
        fail "validate-config.sh: did not correctly flag an out-of-range SERVER_PORT (rc=${rc}): ${out}"
    fi

    # Case C: shell-metacharacter injection in a profile-specific field ->
    # caught by the generic has_forbidden_chars check. Uses a literal
    # single quote embedded inside a double-quoted assignment (valid bash,
    # and NOT evaluated away when config.env is sourced -- unlike
    # $(command) substitution, which the shell would silently resolve
    # during sourcing before has_forbidden_chars ever saw it, since
    # config.env is itself bash that gets sourced, not treated as inert
    # data).
    write_config << 'EOF'
INSTANCE_NAME="goodinst"
GAME="testgame"
SERVER_PORT="25565"
BACKUP_DIR="/srv/gameservers/instances/goodinst/backups"
BACKUP_RETENTION_DAYS="7"
BACKUP_TIME="03:30"
UPDATE_TIME="04:00"
DISCORD_WEBHOOK_URL=""
ON_DEMAND="0"
TG_WORLD_NAME="world'quote"
EOF
    out="$("$RUNNABLE" goodinst 2>&1)"; rc=$?
    if [[ "$rc" -ne 0 ]] && grep -q "TG_WORLD_NAME" <<< "$out"; then
        pass "validate-config.sh: catches shell-metacharacter corruption in a profile-specific field"
    else
        fail "validate-config.sh: did not flag TG_WORLD_NAME containing a shell metacharacter (rc=${rc}): ${out}"
    fi

    # Case D: INSTANCE_NAME field doesn't match the instance's own directory
    # name (the "renamed/copied directory" drift case the header comment
    # calls out specifically).
    write_config << 'EOF'
INSTANCE_NAME="somethingelse"
GAME="testgame"
SERVER_PORT="25565"
BACKUP_DIR="/srv/gameservers/instances/goodinst/backups"
BACKUP_RETENTION_DAYS="7"
BACKUP_TIME="03:30"
UPDATE_TIME="04:00"
DISCORD_WEBHOOK_URL=""
ON_DEMAND="0"
TG_WORLD_NAME="world1"
EOF
    out="$("$RUNNABLE" goodinst 2>&1)"; rc=$?
    if [[ "$rc" -ne 0 ]] && grep -q "INSTANCE_NAME" <<< "$out"; then
        pass "validate-config.sh: catches a directory-name/INSTANCE_NAME mismatch (drift detection)"
    else
        fail "validate-config.sh: did not flag the INSTANCE_NAME/directory mismatch (rc=${rc}): ${out}"
    fi

    # Case E: a syntactically corrupt config.env (truncated mid-line) must
    # be caught by the bash -n pre-check, not sourced and allowed to abort
    # the validator itself.
    printf 'INSTANCE_NAME="goodinst"\nSERVER_PORT="25565\n' > "${FAKE_SRV}/instances/goodinst/config.env"
    out="$("$RUNNABLE" goodinst 2>&1)"; rc=$?
    if [[ "$rc" -ne 0 ]] && grep -qi "syntax" <<< "$out"; then
        pass "validate-config.sh: catches a syntactically corrupt config.env before sourcing it"
    else
        fail "validate-config.sh: did not cleanly reject a corrupt config.env (rc=${rc}): ${out}"
    fi

    # Case F: unknown instance name -> clear usage error, not a crash.
    out="$("$RUNNABLE" totally-not-a-real-instance 2>&1)"; rc=$?
    if [[ "$rc" -ne 0 ]] && grep -qi "no instance" <<< "$out"; then
        pass "validate-config.sh: unknown instance name gives a clear error instead of crashing"
    else
        fail "validate-config.sh: unknown instance name didn't produce the expected error (rc=${rc}): ${out}"
    fi
else
    fail "skipped validate-config.sh functional cases -- template extraction failed above"
fi

###############################################################################
# 5. Functional: every profile against the platform's real, no-root entry
#    points (--validate-profile, --list-games, --check --game). These are
#    genuine subprocess runs of install-game-server.sh itself, not a
#    simulation of it.
###############################################################################
if [[ "$QUICK" -eq 1 ]]; then
    section "Per-profile functional checks (skipped: --quick)"
else
    section "Per-profile functional checks (--validate-profile, --check --game)"

    mapfile -t PROFILE_IDS < <(cd "${PLATFORM_DIR}/profiles" && for f in *.profile.sh; do basename "$f" .profile.sh; done | sort)

    # NOTE: --list-games is NOT tested here via subprocess -- despite being
    # read-only, it sits (in main()) after the require_root call, so it
    # re-execs under sudo on a non-root test run and would hang this
    # script waiting on a password prompt. --validate-profile below
    # exercises every profile file directly and needs no root at all.

    validate_fail=0
    for id in "${PROFILE_IDS[@]}"; do
        if ! (cd "$PLATFORM_DIR" && "./$(basename "$INSTALLER")" --validate-profile "$id" > "${SANDBOX}/vp_${id}.out" 2>&1); then
            fail "--validate-profile ${id}: failed contract check (see: ${SANDBOX}/vp_${id}.out)"
            validate_fail=1
        fi
    done
    [[ "$validate_fail" -eq 0 ]] && pass "--validate-profile: all ${#PROFILE_IDS[@]} profiles satisfy the platform contract"

    # --check --game <id>: read-only pre-flight check, deliberately no-root
    # (see run_environment_check's own header comment). Runs against every
    # profile to touch each one's PROFILE_RECOMMENDED_RAM_MB/PROFILE_REQUIRES_WINE
    # branches; only asserts it doesn't crash (a non-Ubuntu dev/CI machine is
    # EXPECTED to report real [FAIL] lines here -- e.g. no /proc/meminfo on
    # macOS -- that's correct behavior, not a bug).
    check_crash=0
    for id in "${PROFILE_IDS[@]}"; do
        (cd "$PLATFORM_DIR" && "./$(basename "$INSTALLER")" --check --game "$id" > "${SANDBOX}/chk_${id}.out" 2>&1)
        rc=$?
        # exit code must be exactly 0 (all checks passed) or 1 (some check
        # correctly reported failed) -- anything else (127, 2, a bash trap
        # message) means the script itself broke, not that the environment
        # failed a legitimate check.
        if [[ "$rc" -gt 1 ]]; then
            fail "--check --game ${id}: crashed (exit ${rc}), see ${SANDBOX}/chk_${id}.out"
            check_crash=1
        fi
    done
    [[ "$check_crash" -eq 0 ]] && pass "--check --game <profile>: ran cleanly (no crash) for all ${#PROFILE_IDS[@]} profiles"
fi

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
fi

###############################################################################
# Persisted report: test-results/latest.md -- machine- and human-readable
# summary of this run (total/pass/fail counts, timestamp, shellcheck offense
# count, and the full failure list if any), written regardless of pass/fail
# so CI can upload it as a build artifact even on a red run.
###############################################################################
TOTAL_COUNT=$(( PASS_COUNT + FAIL_COUNT ))
TIMESTAMP="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
STATUS="PASS"
[[ "$FAIL_COUNT" -gt 0 ]] && STATUS="FAIL"

{
    echo "# profile_smoke_test.sh report"
    echo
    echo "- **Status:** ${STATUS}"
    echo "- **Timestamp:** ${TIMESTAMP}"
    echo "- **Total checks:** ${TOTAL_COUNT}"
    echo "- **Passed:** ${PASS_COUNT}"
    echo "- **Failed:** ${FAIL_COUNT}"
    echo "- **ShellCheck offenses (-S error):** ${SHELLCHECK_OFFENSE_COUNT}"
    echo "- **Mode:** $([[ "$QUICK" -eq 1 ]] && echo "--quick (per-profile loop skipped)" || echo "full")"
    echo
    if [[ "$FAIL_COUNT" -gt 0 ]]; then
        echo "## Failures"
        echo
        for f in "${FAILURES[@]}"; do
            echo "- ${f}"
        done
    else
        echo "## Failures"
        echo
        echo "None."
    fi
} > "$REPORT_FILE"

echo
echo "Report written to: ${REPORT_FILE}"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi
exit 0

#!/usr/bin/env bash
###############################################################################
# install-valheim-server.sh  (v2.0.0 -- multi-instance / "shard" edition)
#
# Deploys and manages any number of independent Valheim dedicated server
# instances ("shards") on a single Ubuntu Server LTS host, since Valheim
# itself has a hard, engine-level limit of ~10 well-behaved concurrent
# players per world. If you need more total concurrent players than that,
# the only real answer is several separate worlds running side by side --
# this script automates exactly that, instead of pretending one instance
# can be tuned to hold hundreds of people.
#
# Each instance:
#   - Has its own port block, world save, config, logs, and backups.
#   - Shares one SteamCMD-managed "golden" copy of the game files (so
#     updating once updates the source everyone else is synced from).
#   - Runs as its own systemd service (valheim@<name>.service), restarts
#     independently, and is backed up/updated/health-checked independently.
#   - Can optionally run BepInEx + the MaxPlayerCount mod to raise its
#     player cap above the vanilla 10 (default 15) -- note this forces
#     Crossplay OFF for that instance, since Crossplay and BepInEx mods
#     are mutually exclusive in Valheim (Crossplay uses a different
#     networking backend that mods cannot hook into).
#
# USAGE:
#   First run (installs shared prerequisites + your first instance):
#     chmod +x install-valheim-server.sh
#     ./install-valheim-server.sh
#
#   Add another shard later:
#     ./install-valheim-server.sh --add-instance <name>
#
#   List / remove / uninstall:
#     ./install-valheim-server.sh --list-instances
#     ./install-valheim-server.sh --remove-instance <name>
#     ./install-valheim-server.sh --uninstall              (removes everything)
#
# You do not need to type "sudo" yourself -- the script re-launches itself
# with sudo automatically if needed.
###############################################################################

if [ -z "${BASH_VERSION:-}" ]; then
    echo "ERROR: This script must be run with bash, e.g.: sudo bash install-valheim-server.sh" >&2
    exit 1
fi

set -Eeuo pipefail
IFS=$'\n\t'

# --- Load shared library with common functions ---
# BASE_DIR resolves to this script's own directory so relative paths to
# lib/common.sh work regardless of where the caller invokes us from.
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BASE_DIR
# source loads common.sh into this shell's environment; the trailing
# "${BASE_DIR}" argument tells common.sh where the project root lives so
# its path helpers resolve correctly.
source "${BASE_DIR}/../lib/common.sh" "${BASE_DIR}"

###############################################################################
# GLOBAL CONSTANTS
###############################################################################
readonly SCRIPT_VERSION="2.0.0"
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
LOG_FILE="/var/log/valheim-install.log"  # not readonly -- init_logging sets it

readonly VALHEIM_USER="valheim"
readonly VALHEIM_GROUP="valheim"
readonly VALHEIM_BASE="/srv/valheim"

readonly STEAMCMD_DIR="${VALHEIM_BASE}/steamcmd"
readonly GOLDEN_SERVER_DIR="${VALHEIM_BASE}/golden-server"   # one shared, SteamCMD-managed vanilla install
readonly SCRIPTS_DIR="${VALHEIM_BASE}/scripts"
readonly INSTANCES_DIR="${VALHEIM_BASE}/instances"
readonly INSTANCE_REGISTRY="${VALHEIM_BASE}/instances.registry"
readonly BASE_TMP_DIR="${VALHEIM_BASE}/tmp"

readonly STEAMCMD_URL="https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz"
readonly STEAM_APPID_VALHEIM_SERVER=896660

readonly SYSTEMD_TEMPLATE_UNIT_PATH="/etc/systemd/system/valheim@.service"
readonly LOGROTATE_CONF="/etc/logrotate.d/valheim"
readonly CRON_BACKUP_FILE="/etc/cron.d/valheim-backup"
readonly CRON_UPDATE_FILE="/etc/cron.d/valheim-update"
readonly CRON_HEALTHCHECK_FILE="/etc/cron.d/valheim-healthcheck"
readonly CRON_CAPACITY_FILE="/etc/cron.d/valheim-capacity"
readonly JOURNALD_CONF="/etc/systemd/journald.conf"
readonly JOURNALD_MAX_USE_FLOOR_MB=500     # minimum cap even with zero/one instance
readonly JOURNALD_MAX_USE_PER_INSTANCE_MB=150  # added per registered shard
readonly JOURNALD_MAX_USE_CEILING_MB=8192  # hard ceiling regardless of fleet size
readonly FAIL2BAN_JAIL_LOCAL="/etc/fail2ban/jail.local"

readonly MIN_DISK_MB=10240
readonly MIN_RAM_MB_HARD=1800
readonly MIN_RAM_MB_RECOMMENDED=4096
readonly SWAP_FILE_PATH="/swapfile"
readonly SWAP_SIZE_MB=4096
readonly APT_LOCK_WAIT_SECONDS=180

readonly PROFILE_PORT_COUNT=3  # Valheim uses 3 consecutive UDP ports per instance (N, N+1, N+2)

readonly PORT_RANGE_START=2456
readonly PORT_RANGE_STEP=10          # each instance gets a 10-port-wide block (only 3 are used); leaves room and keeps math easy to read in logs
readonly VANILLA_MAX_PLAYERS=10
readonly CAPACITY_LOW_THRESHOLD=40   # below this: plenty of headroom for another shard
readonly CAPACITY_HIGH_THRESHOLD=80  # at/above this: this host is already running hot

readonly SYSTEMD_SLEEP_TEMPLATE_UNIT_PATH="/etc/systemd/system/valheim-sleep@.service"
readonly CRON_IDLE_FILE="/etc/cron.d/valheim-idle"
readonly IDLE_MINUTES_THRESHOLD=5   # auto-save + auto-stop after this many consecutive idle minutes
readonly CAPACITY_SUSTAINED_SAMPLES=3   # consecutive high readings (see host-capacity-monitor.sh) before alerting
readonly DEFAULT_MAX_PLAYERS=15
readonly MAX_PLAYERS_HARD_CAP=30     # see validate_max_players -- above ~20 is genuinely unreliable; this is a safety ceiling, not an endorsement

readonly BEPINEX_NAMESPACE="denikson"
readonly BEPINEX_NAME="BepInExPack_Valheim"
readonly MAXPLAYERCOUNT_NAMESPACE="Azumatt"
readonly MAXPLAYERCOUNT_NAME="MaxPlayerCount"
readonly THUNDERSTORE_API_BASE="https://thunderstore.io/api/experimental/package"

ASSUME_DEFAULTS=0   # set to 1 by -y/--yes
ORIGINAL_ARGS_STRING=""   # set at the top of main(); used by on_error's re-run suggestion

###############################################################################
# ERROR HANDLING / TRAPS  (unchanged from v1)
###############################################################################

# on_error: the ERR trap handler -- reports where the script failed and
# reassures the admin that re-running is safe once the issue is fixed.
on_error() {
    local line="$1" cmd="$2" rc="$3"
    log_err "Unexpected failure at line ${line} (exit code ${rc}): ${cmd}"
    log_err "Nothing further will be changed. Fix the underlying problem, then simply re-run:"
    log_err "  ./${SCRIPT_NAME} ${ORIGINAL_ARGS_STRING}"
    log_err "Full log: ${LOG_FILE}"
    exit "$rc"
}
trap 'on_error "$LINENO" "$BASH_COMMAND" "$?"' ERR
trap 'echo; log_warn "Interrupted by user (Ctrl+C)."; exit 130' INT TERM

###############################################################################
# BANNER
###############################################################################

# print_banner: title banner printed at the start of a run.
print_banner() {
    echo -e "${C_BOLD}"
    echo "==============================================================="
    echo "  Valheim Dedicated Server Installer  (v${SCRIPT_VERSION})"
    echo "  Multi-instance / shard edition -- Ubuntu Server LTS"
    echo "==============================================================="
    echo -e "${C_RESET}"
}

###############################################################################
# INSTANCE REGISTRY / PORT ALLOCATION
#
# /srv/valheim/instances.registry is a simple "name:port:created_at" text
# file used only to hand out non-conflicting port blocks and to list what
# exists -- the per-instance config.env files remain the actual source of
# truth for everything else.
###############################################################################

# registry_ensure: creates an empty registry file if one doesn't exist yet.
# A no-op (does not error) if the base install hasn't happened at all yet
# (VALHEIM_BASE doesn't exist) -- callers that need it to exist should
# check registry_base_exists first.
registry_ensure() {
    [[ -d "$VALHEIM_BASE" ]] || return 0
    [[ -f "$INSTANCE_REGISTRY" ]] || { touch "$INSTANCE_REGISTRY"; chmod 644 "$INSTANCE_REGISTRY"; }
}

# registry_base_exists: true if the base install has happened at all
# (i.e. it's safe to assume $INSTANCE_REGISTRY's parent directory exists).
registry_base_exists() { [[ -d "$VALHEIM_BASE" ]]; }

# registry_next_port: returns the next free port block start (a multiple of
# PORT_RANGE_STEP above the highest one already handed out).
registry_next_port() {
    registry_ensure
    local max_used candidate="$PORT_RANGE_START"
    max_used="$(awk -F: '{print $2}' "$INSTANCE_REGISTRY" 2>/dev/null | sort -n | tail -1)"
    if [[ -n "$max_used" ]]; then
        candidate=$(( max_used + PORT_RANGE_STEP ))
    fi
    echo "$candidate"
}

# registry_add: appends a new "name:port:timestamp" line.
# registry_add: appends a new "name:port:timestamp" line. Uses a
# colon-free timestamp format here specifically (unlike ts()), since the
# registry itself uses ':' as its field separator -- a normal HH:MM:SS
# timestamp would otherwise be silently truncated when later split on ':'.
registry_add() {
    local name="$1" port="$2"
    registry_ensure
    echo "${name}:${port}:$(date '+%Y-%m-%d_%H-%M-%S')" >> "$INSTANCE_REGISTRY"
}

# registry_remove: deletes the line for the given instance name, if present.
registry_remove() {
    local name="$1"
    registry_ensure
    sed -i "/^${name}:/d" "$INSTANCE_REGISTRY"
}

# registry_has: true if an instance with this name is already registered.
registry_has() {
    local name="$1"
    registry_ensure
    grep -q "^${name}:" "$INSTANCE_REGISTRY" 2>/dev/null
}

# registry_port_for: prints the registered port for an instance name, or
# nothing if not found.
registry_port_for() {
    local name="$1"
    registry_ensure
    awk -F: -v n="$name" '$1==n{print $2}' "$INSTANCE_REGISTRY" 2>/dev/null | head -n1
}

# registry_list_names: prints every registered instance name, one per line.
registry_list_names() {
    registry_ensure
    awk -F: '{print $1}' "$INSTANCE_REGISTRY" 2>/dev/null
}

###############################################################################
# INSTANCE PATH HELPERS
# VH uses "world" instead of common.sh's "data" for the save directory,
# so we keep this one helper here. The rest come from common.sh.
###############################################################################
# instance_world_dir: prints instance $1's world-save directory.
instance_world_dir()    { echo "${INSTANCES_DIR}/$1/world"; }

###############################################################################
# INPUT VALIDATION FUNCTIONS
# Each prints an error message (captured by the caller) and returns non-zero
# on invalid input, or returns 0 on valid input.
###############################################################################

# validate_server_name: 1-60 chars, safe punctuation only, no shell
# metacharacters (this ends up inside a generated, later-sourced config file).
validate_server_name() {
    local v="$1"
    if has_forbidden_chars "$v"; then
        echo "Server name may not contain: \" ' \` \\ \$"
        return 1
    fi
    if [[ ! "$v" =~ ^[A-Za-z0-9._\ -]{1,60}$ ]]; then
        echo "Server name must be 1-60 characters: letters, numbers, spaces, '.', '_', '-'."
        return 1
    fi
    return 0
}

# validate_world_name: 1-32 chars, letters/digits/_/- only (no spaces).
validate_world_name() {
    local v="$1"
    if [[ ! "$v" =~ ^[A-Za-z0-9_-]{1,32}$ ]]; then
        echo "World name must be 1-32 characters: letters, numbers, '_', '-' (no spaces)."
        return 1
    fi
    return 0
}

# validate_password: 5-64 chars, no spaces, no shell metacharacters, and
# must not overlap the server name in either direction (Valheim itself
# rejects such passwords).
validate_password() {
    local v="$1" server_name="${SERVER_NAME:-}"
    if has_forbidden_chars "$v"; then
        echo "Password may not contain: \" ' \` \\ \$"
        return 1
    fi
    if [[ "${#v}" -lt 5 || "${#v}" -gt 64 ]]; then
        echo "Password must be between 5 and 64 characters."
        return 1
    fi
    if [[ "$v" == *" "* ]]; then
        echo "Password may not contain spaces."
        return 1
    fi
    if [[ -n "$server_name" ]]; then
        local v_lower="${v,,}" name_lower="${server_name,,}"
        if [[ "$name_lower" == *"$v_lower"* || "$v_lower" == *"$name_lower"* ]]; then
            echo "Password must not overlap with the server name (Valheim will reject it)."
            return 1
        fi
    fi
    return 0
}

# validate_backup_dir: absolute path, no shell metacharacters, must not sit
# inside this instance's own world/server directories.
validate_backup_dir() {
    local v="$1"
    if has_forbidden_chars "$v"; then
        echo "Path may not contain: \" ' \` \\ \$"
        return 1
    fi
    if [[ "$v" != /* ]]; then
        echo "Please provide an absolute path (starting with /)."
        return 1
    fi
    if [[ -n "${CURRENT_INSTANCE_WORLD_DIR:-}" ]] && { [[ "$v" == "$CURRENT_INSTANCE_WORLD_DIR" ]] || [[ "$v" == "$CURRENT_INSTANCE_WORLD_DIR"/* ]]; }; then
        echo "Backup directory must not be inside this instance's world directory."
        return 1
    fi
    return 0
}

# validate_max_players: whole number, 2-MAX_PLAYERS_HARD_CAP. Anything
# above vanilla's 10 requires BepInEx + MaxPlayerCount (handled elsewhere)
# and forces Crossplay off for that instance. Strongly (non-fatally) warns
# above 20, since that is past where the community/hosting consensus says
# Valheim holds up "regardless of server specs."
validate_max_players() {
    local v="$1"
    if [[ ! "$v" =~ ^[0-9]+$ ]] || (( v < 2 || v > MAX_PLAYERS_HARD_CAP )); then
        echo "Max players must be a whole number between 2 and ${MAX_PLAYERS_HARD_CAP}."
        return 1
    fi
    return 0
}

###############################################################################
# DEDICATED LINUX USER  (unchanged from v1)
###############################################################################

# create_valheim_user: creates the unprivileged, no-login, no-password
# system group/user every instance's game process runs as.
create_valheim_user() {
    log_step "Creating dedicated '${VALHEIM_USER}' system user"

    if getent group "$VALHEIM_GROUP" >/dev/null 2>&1; then
        log_info "Group '${VALHEIM_GROUP}' already exists."
    else
        groupadd --system "$VALHEIM_GROUP"
        log_ok "Group '${VALHEIM_GROUP}' created."
    fi

    if id -u "$VALHEIM_USER" >/dev/null 2>&1; then
        log_info "User '${VALHEIM_USER}' already exists."
    else
        useradd --system --gid "$VALHEIM_GROUP" --home-dir "$VALHEIM_BASE" \
                --no-create-home --shell /usr/sbin/nologin \
                --comment "Valheim dedicated server (unprivileged, no login)" \
                "$VALHEIM_USER"
        log_ok "User '${VALHEIM_USER}' created (no login shell, no password)."
    fi
}

# run_as_valheim: runs a shell command string as the unprivileged valheim
# user. Uses `runuser -u USER -- CMD` (not `-s SHELL -c CMD`, which
# util-linux's runuser rejects as mutually exclusive with -u) -- this form
# execs the command directly under that UID/GID, which also means the
# account's /usr/sbin/nologin shell is never an obstacle.
run_as_valheim() {
    # Usage: run_as_valheim "shell command string"
    runuser -u "$VALHEIM_USER" -- bash -c "$1"
}

###############################################################################
# BASE DIRECTORY LAYOUT (shared, created once)
###############################################################################

# create_base_directory_layout: creates the top-level shared directories
# (everything that ISN'T per-instance). Per-instance directories are
# created later by add_instance/create_instance_directories.
create_base_directory_layout() {
    log_step "Creating base directory layout under ${VALHEIM_BASE}"
    local dir
    for dir in "$VALHEIM_BASE" "$STEAMCMD_DIR" "$GOLDEN_SERVER_DIR" "$SCRIPTS_DIR" "$INSTANCES_DIR" "$BASE_TMP_DIR"; do
        install -d -o "$VALHEIM_USER" -g "$VALHEIM_GROUP" -m 0750 "$dir"
    done
    registry_ensure
    chown "$VALHEIM_USER:$VALHEIM_GROUP" "$INSTANCE_REGISTRY"
    log_ok "Base layout ready."
}

###############################################################################
# STEAMCMD + SHARED "GOLDEN" VALHEIM SERVER INSTALL
###############################################################################

# install_or_update_golden_server: runs SteamCMD to install/validate App ID
# 896660 into the one shared GOLDEN_SERVER_DIR. Every instance's own server
# copy is synced FROM this directory (see sync_instance_from_golden), so
# updating the game only means re-running this once, not once per shard.
# SteamCMD's own exit code is informational only; the real proof of success
# is the resulting binary's presence.
install_or_update_golden_server() {
    log_step "Installing/updating the shared Valheim Dedicated Server (App ID ${STEAM_APPID_VALHEIM_SERVER})"
    log_info "This can take several minutes on the first run."

    local steamcmd_rc=0
    set +e
    run_as_valheim "\"${STEAMCMD_DIR}/steamcmd.sh\" +force_install_dir \"${GOLDEN_SERVER_DIR}\" +login anonymous +app_update ${STEAM_APPID_VALHEIM_SERVER} validate +quit" \
        >> "$LOG_FILE" 2>&1
    steamcmd_rc=$?
    set -e
    log_info "SteamCMD exited with code ${steamcmd_rc} (see ${LOG_FILE}; verifying the binary directly)."

    if [[ -x "${GOLDEN_SERVER_DIR}/valheim_server.x86_64" ]]; then
        log_ok "Shared Valheim server executable verified."
    else
        die "valheim_server.x86_64 was not found after SteamCMD ran. Check ${LOG_FILE}, then re-run (safe to re-run)."
    fi
    chown -R "$VALHEIM_USER:$VALHEIM_GROUP" "$GOLDEN_SERVER_DIR"
}

###############################################################################
# PER-INSTANCE DIRECTORIES / SYNC FROM GOLDEN
###############################################################################

# create_instance_directories: creates the directory tree for one instance.
create_instance_directories() {
    local name="$1" dir
    for dir in "$(instance_dir "$name")" "$(instance_server_dir "$name")" \
               "$(instance_world_dir "$name")" "$(instance_logs_dir "$name")" \
               "$(instance_tmp_dir "$name")" "$(instance_default_backup_dir "$name")"; do
        install -d -o "$VALHEIM_USER" -g "$VALHEIM_GROUP" -m 0750 "$dir"
    done
}

# sync_instance_from_golden: copies the shared golden server install into
# this instance's own server directory. Deliberately does NOT use rsync
# --delete, so anything instance-specific added later (BepInEx, plugin
# configs) is never wiped out by a future golden-server update sync.
sync_instance_from_golden() {
    local name="$1" server_dir
    server_dir="$(instance_server_dir "$name")"
    log_info "[$name] Syncing server files from the shared golden install..."
    rsync -a "${GOLDEN_SERVER_DIR}/" "${server_dir}/"
    chown -R "$VALHEIM_USER:$VALHEIM_GROUP" "$server_dir"
}

###############################################################################
# BEPINEX + MAXPLAYERCOUNT (optional, per instance)
#
# Only used when an instance's MAX_PLAYERS is set above vanilla's 10. This
# is a best-effort layer: every step verifies its own result and falls back
# to a clear warning (never a silent failure) if anything doesn't match
# what's expected, since Thunderstore package internals can change over
# time in ways a static script can't fully anticipate.
###############################################################################

# fetch_thunderstore_download_url: queries Thunderstore's package API for a
# package's latest version and prints its direct download URL. Prints
# nothing and returns 1 on any failure (network, missing package, unexpected
# response shape).
fetch_thunderstore_download_url() {
    local namespace="$1" name="$2" json url
    json="$(curl -fsS --max-time 20 "${THUNDERSTORE_API_BASE}/${namespace}/${name}/" 2>>"$LOG_FILE")" || return 1
    url="$(echo "$json" | jq -r '.latest.download_url // empty' 2>>"$LOG_FILE")"
    [[ -n "$url" && "$url" != "null" ]] || return 1
    echo "$url"
}

# install_bepinex_and_maxplayercount: downloads and installs BepInEx plus
# the MaxPlayerCount plugin into one instance's server directory. Returns 1
# (and logs a clear warning) on any failure, so the caller can fall back to
# vanilla for that instance instead of leaving it half-configured.
install_bepinex_and_maxplayercount() {
    local name="$1" server_dir
    server_dir="$(instance_server_dir "$name")"

    log_info "[$name] Looking up BepInEx's current download URL on Thunderstore..."
    local bepinex_url
    bepinex_url="$(fetch_thunderstore_download_url "$BEPINEX_NAMESPACE" "$BEPINEX_NAME")" || {
        log_warn "[$name] Could not look up BepInEx on Thunderstore (network issue, or Thunderstore's API changed). Falling back to vanilla for this instance."
        return 1
    }

    local work="${BASE_TMP_DIR}/${name}-bepinex-install"
    rm -rf "$work"; mkdir -p "$work"

    curl -fsSL "$bepinex_url" -o "${work}/bepinex.zip" 2>>"$LOG_FILE" || {
        log_warn "[$name] BepInEx download failed."; rm -rf "$work"; return 1;
    }
    unzip -oq "${work}/bepinex.zip" -d "${work}/extracted" 2>>"$LOG_FILE" || {
        log_warn "[$name] BepInEx archive could not be extracted."; rm -rf "$work"; return 1;
    }

    # Thunderstore packages are wrapped in an icon.png/manifest.json/README
    # shell around one inner payload folder; find that folder and copy its
    # CONTENTS (not itself) directly into the server directory.
    local payload_dir
    payload_dir="$(find "${work}/extracted" -maxdepth 1 -mindepth 1 -type d | head -n1)"
    [[ -n "$payload_dir" ]] || payload_dir="${work}/extracted"
    cp -a "${payload_dir}/." "${server_dir}/" 2>>"$LOG_FILE" || {
        log_warn "[$name] Could not copy BepInEx files into the server directory."; rm -rf "$work"; return 1;
    }

    # Verify something recognizable actually landed, rather than assuming success.
    if [[ ! -d "${server_dir}/BepInEx" ]]; then
        log_warn "[$name] BepInEx was downloaded but no BepInEx/ folder appeared after extraction -- the package layout may have changed. Falling back to vanilla for this instance."
        rm -rf "$work"; return 1
    fi
    log_ok "[$name] BepInEx installed."

    log_info "[$name] Looking up MaxPlayerCount's current download URL on Thunderstore..."
    local mpc_url
    mpc_url="$(fetch_thunderstore_download_url "$MAXPLAYERCOUNT_NAMESPACE" "$MAXPLAYERCOUNT_NAME")" || {
        log_warn "[$name] Could not look up MaxPlayerCount on Thunderstore. This instance will run vanilla (10-player cap)."
        rm -rf "$work"; return 1
    }
    curl -fsSL "$mpc_url" -o "${work}/mpc.zip" 2>>"$LOG_FILE" || {
        log_warn "[$name] MaxPlayerCount download failed."; rm -rf "$work"; return 1;
    }
    mkdir -p "${server_dir}/BepInEx/plugins"
    unzip -oq "${work}/mpc.zip" -d "${work}/mpc-extracted" 2>>"$LOG_FILE" || {
        log_warn "[$name] MaxPlayerCount archive could not be extracted."; rm -rf "$work"; return 1;
    }
    local dll_count
    dll_count="$(find "${work}/mpc-extracted" -iname '*.dll' -exec cp -t "${server_dir}/BepInEx/plugins/" {} + -print 2>>"$LOG_FILE" | wc -l)"
    if [[ "$dll_count" -eq 0 ]]; then
        log_warn "[$name] MaxPlayerCount package didn't contain a .dll where expected. Falling back to vanilla for this instance."
        rm -rf "$work"; return 1
    fi

    rm -rf "$work"
    chown -R "$VALHEIM_USER:$VALHEIM_GROUP" "$server_dir"
    log_ok "[$name] MaxPlayerCount plugin installed (${dll_count} file(s))."
    return 0
}

# configure_max_player_count: briefly launches the instance once (a
# throwaway probe world on an unused port, never exposed through the
# firewall) purely so BepInEx/MaxPlayerCount generate their default config
# file, then patches that file to the requested MAX_PLAYERS value. Verifies
# every step and returns 1 with a clear, specific message rather than
# silently assuming success if anything about the generated file doesn't
# match what's expected.
configure_max_player_count() {
    local name="$1" max_players="$2" server_dir
    server_dir="$(instance_server_dir "$name")"

    local doorstop_lib launcher
    doorstop_lib="$(find "$server_dir" -iname 'libdoorstop*.so' 2>/dev/null | head -n1)"
    launcher="$(find "$server_dir" -maxdepth 1 -iname '*bepinex*.sh' 2>/dev/null | head -n1)"

    if [[ -z "$doorstop_lib" && -z "$launcher" ]]; then
        log_warn "[$name] Could not find a BepInEx loader (script or doorstop library) after install. This instance will run vanilla (10-player cap)."
        return 1
    fi

    log_info "[$name] Briefly starting the server once so BepInEx can generate its default config..."
    # BepInEx can be slow to bootstrap on first launch (JIT compilation,
    # plugin loading, config generation). 60 seconds is generous enough
    # for even constrained VMs without waiting indefinitely.
    # A fixed literal password here would be a hardcoded credential-shaped
    # string sitting in source control -- harmless in practice (the probe
    # binds to an unused port never opened in the firewall and is torn
    # down within seconds), but a throwaway random one costs nothing and
    # avoids that pattern entirely, matching how every other
    # auto-generated password in this codebase is produced.
    local probe_password
    probe_password="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16 || true)"
    local probe_cmd probe_log="${BASE_TMP_DIR}/${name}-bepinex-probe.log"
    if [[ -n "$launcher" ]]; then
        probe_cmd="cd '${server_dir}' && export SteamAppId=892970 && timeout 60 '${launcher}' -nographics -batchmode -name bepinexprobe -port 59999 -world probeworld -password ${probe_password} -savedir '${BASE_TMP_DIR}' -public 0"
    else
        probe_cmd="cd '${server_dir}' && export SteamAppId=892970 DOORSTOP_ENABLE=TRUE DOORSTOP_TARGET_ASSEMBLY='${server_dir}/BepInEx/core/BepInEx.Preloader.dll' LD_PRELOAD='${doorstop_lib}' && timeout 60 ./valheim_server.x86_64 -nographics -batchmode -name bepinexprobe -port 59999 -world probeworld -password ${probe_password} -savedir '${BASE_TMP_DIR}' -public 0"
    fi

    set +e
    run_as_valheim "$probe_cmd" >> "$probe_log" 2>&1
    set -e
    rm -f "${BASE_TMP_DIR}"/probeworld* 2>/dev/null || true

    local cfg_file="${server_dir}/BepInEx/config/Azumatt.MaxPlayerCount.cfg"
    if [[ ! -f "$cfg_file" ]]; then
        log_warn "[$name] BepInEx did not generate ${cfg_file} as expected. This instance will run vanilla (10-player cap); see ${probe_log}."
        return 1
    fi

    if grep -qi '^MaxPlayers' "$cfg_file"; then
        sed -i "s/^MaxPlayers[[:space:]]*=.*/MaxPlayers = ${max_players}/I" "$cfg_file"
        if grep -q "^MaxPlayers = ${max_players}$" "$cfg_file"; then
            log_ok "[$name] MaxPlayerCount configured: MaxPlayers = ${max_players} (verified in ${cfg_file})."
        else
            log_warn "[$name] Tried to set MaxPlayers but couldn't verify the change stuck. Please check ${cfg_file} by hand."
            chown -R "$VALHEIM_USER:$VALHEIM_GROUP" "$server_dir"
            return 1
        fi
    else
        log_warn "[$name] Generated config exists but no 'MaxPlayers' key was found in it. Please open ${cfg_file} and set the player cap manually."
        chown -R "$VALHEIM_USER:$VALHEIM_GROUP" "$server_dir"
        return 1
    fi

    chown -R "$VALHEIM_USER:$VALHEIM_GROUP" "$server_dir"
    return 0
}

###############################################################################
# PER-INSTANCE CONFIGURATION PROMPTS
#
# Every instance is private by design: -public is always 0, so it never
# appears in any Steam/in-game server browser. Joining requires knowing the
# exact IP:port (and password) for that specific shard -- see the "How to
# connect" section printed after each instance is added.
###############################################################################

CURRENT_INSTANCE_WORLD_DIR=""   # set just before the backup-dir prompt so validate_backup_dir can check against it

# gather_instance_input: asks every question needed to configure ONE new
# instance and validates each answer. Leaves INSTANCE_NAME/SERVER_NAME/
# WORLD_NAME/SERVER_PASSWORD/SERVER_PORT/CROSSPLAY/MAX_PLAYERS/
# BACKUP_RETENTION_DAYS/BACKUP_DIR/BACKUP_TIME/UPDATE_TIME populated.
gather_instance_input() {
    local suggested_name="$1"   # may be empty; used for --add-instance <name>

    log_step "Configuring new instance"
    echo "Press Enter at any prompt to accept the default shown in [brackets]."
    echo "Every instance is PRIVATE: it will not appear in any server browser."
    echo "Joining always requires the exact IP:port (and password) you hand out."
    echo

    if [[ -n "$suggested_name" ]]; then
        INSTANCE_NAME="$suggested_name"
        if ! validate_instance_name "$INSTANCE_NAME" >/dev/null; then
            die "Instance name '${INSTANCE_NAME}' is invalid: letters, numbers, '_', '-' only, 1-32 characters."
        fi
    else
        prompt_and_validate "Instance (shard) name" "main" validate_instance_name INSTANCE_NAME 0
    fi
    if registry_has "$INSTANCE_NAME"; then
        die "An instance named '${INSTANCE_NAME}' already exists. Use --remove-instance first, or choose a different name."
    fi

    prompt_and_validate "Server name (shown to players)" "Valheim - ${INSTANCE_NAME}" validate_server_name SERVER_NAME 0
    prompt_and_validate "World name" "Midgard" validate_world_name WORLD_NAME 0

    if [[ "$ASSUME_DEFAULTS" -eq 1 ]]; then
        SERVER_PASSWORD="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16 || true)"
        log_warn "Non-interactive mode: generated a random password for '${INSTANCE_NAME}' (shown once below, saved to its config.env)."
        echo -e "${C_BOLD}    Generated password: ${SERVER_PASSWORD}${C_RESET}"
    else
        while true; do
            read -r -s -p "Server password (min 5 characters): " pw1 < /dev/tty; echo
            read -r -s -p "Confirm password: " pw2 < /dev/tty; echo
            if [[ "$pw1" != "$pw2" ]]; then log_warn "Passwords did not match. Try again."; continue; fi
            local errmsg
            if errmsg="$(validate_password "$pw1" 2>&1)"; then SERVER_PASSWORD="$pw1"; break; else log_warn "$errmsg"; fi
        done
    fi

    local suggested_port
    suggested_port="$(registry_next_port)"
    prompt_and_validate "Port for this instance (uses N, N+1, N+2)" "$suggested_port" validate_port SERVER_PORT 0
    local ss_output
    if command_exists ss && ss_output="$(ss -uln 2>/dev/null)" && grep -q ":${SERVER_PORT}[[:space:]]" <<< "$ss_output"; then
        log_warn "Port ${SERVER_PORT}/udp already appears to be in use on this machine."
    fi

    prompt_and_validate "Max players for this shard (10 = vanilla, no mods; >10 installs BepInEx+MaxPlayerCount)" \
        "$DEFAULT_MAX_PLAYERS" validate_max_players MAX_PLAYERS 0
    if (( MAX_PLAYERS > 20 )); then
        log_warn "Max players set to ${MAX_PLAYERS}. Community/hosting consensus is that Valheim's performance degrades badly past ~10-15 players regardless of hardware -- ${MAX_PLAYERS} is genuinely past where this is known to hold up well."
    fi

    if (( MAX_PLAYERS > VANILLA_MAX_PLAYERS )); then
        log_info "Max players > ${VANILLA_MAX_PLAYERS} requires BepInEx mods, which are not compatible with Crossplay. Crossplay will be disabled for this instance."
        CROSSPLAY=0
    else
        prompt_and_validate "Enable Crossplay (Xbox/Game Pass) for this shard? (yes/no)" "no" validate_yesno CROSSPLAY_INPUT 0
        CROSSPLAY="$(normalize_yesno_bit "$CROSSPLAY_INPUT")"
    fi

    prompt_and_validate "Backup retention (days)" "7" validate_retention_days BACKUP_RETENTION_DAYS 0
    CURRENT_INSTANCE_WORLD_DIR="$(instance_world_dir "$INSTANCE_NAME")"
    prompt_and_validate "Backup destination directory" "$(instance_default_backup_dir "$INSTANCE_NAME")" validate_backup_dir BACKUP_DIR 0
    prompt_and_validate "Daily backup time (24h HH:MM)" "03:00" validate_time_hhmm BACKUP_TIME 0
    prompt_and_validate "Daily update-check time (24h HH:MM)" "04:00" validate_time_hhmm UPDATE_TIME 0

    # Warn if backup and update are scheduled for the same minute --
    # both will fire simultaneously via cron, which can cause race
    # conditions (update stops the service while backup tries to copy).
    if [[ "$BACKUP_TIME" == "$UPDATE_TIME" ]]; then
        log_warn "Backup time (${BACKUP_TIME}) and update time (${UPDATE_TIME}) are identical."
        log_warn "This may cause conflicts since both run at the same minute."
    fi

    prompt_and_validate "Sleep until a player connects, auto-stop after ${IDLE_MINUTES_THRESHOLD} idle minutes (saves resources when idle)? (yes/no)" \
        "yes" validate_yesno ON_DEMAND_INPUT 0
    ON_DEMAND="$(normalize_yesno_bit "$ON_DEMAND_INPUT")"
    if [[ "$ON_DEMAND" == "1" ]]; then
        log_warn "Valheim has no built-in way to query exact player count, so idle detection"
        log_warn "uses a network-traffic heuristic -- it can occasionally misjudge a quiet-but-"
        log_warn "connected player as idle. Consider disabling on-demand if that's a concern."
    fi

    DISCORD_WEBHOOK_URL=""
    log_ok "Configuration collected for instance '${INSTANCE_NAME}'."
}

# write_instance_config: writes this instance's config.env (mode 600 --
# contains the password).
write_instance_config() {
    local name="$1" cfg
    cfg="$(instance_config_file "$name")"
    cat > "$cfg" << EOF
# Valheim instance configuration - generated by ${SCRIPT_NAME} on $(ts)
# This instance is always PRIVATE (-public 0): it never appears in any
# server browser. Players need this exact IP:port + password to join.
INSTANCE_NAME="${name}"
SERVER_NAME="${SERVER_NAME}"
WORLD_NAME="${WORLD_NAME}"
SERVER_PASSWORD="${SERVER_PASSWORD}"
SERVER_PORT=${SERVER_PORT}
ON_DEMAND=${ON_DEMAND}
CROSSPLAY=${CROSSPLAY}
MAX_PLAYERS=${MAX_PLAYERS}
BEPINEX_ENABLED=${BEPINEX_ENABLED:-0}
BACKUP_DIR="${BACKUP_DIR}"
BACKUP_RETENTION_DAYS=${BACKUP_RETENTION_DAYS}
BACKUP_TIME="${BACKUP_TIME}"
UPDATE_TIME="${UPDATE_TIME}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL}"
EOF
    chown "$VALHEIM_USER:$VALHEIM_GROUP" "$cfg"
    chmod 600 "$cfg"
}

###############################################################################
# HELPER SCRIPT GENERATION
#
# Every generated script takes an instance name as its first argument (the
# one exception being scripts that legitimately operate across ALL
# instances, which say so explicitly). Each sources common.sh with that
# name, which loads that ONE instance's config.env -- nothing is baked in
# by the installer via string interpolation, so re-running to add/change
# an instance never requires touching already-generated scripts.
###############################################################################

# write_common_script: writes scripts/common.sh, the shared library every
# other generated script sources (with an instance name argument) for
# config access, colored logging, the optional Discord notifier, and a
# disk-space guard used before risky operations.
write_common_script() {
    cat > "${SCRIPTS_DIR}/common.sh" << 'EOF'
#!/usr/bin/env bash
# common.sh - shared functions/config sourced by every Valheim helper
# script. Not meant to be executed directly.
#
# Usage from another script: source common.sh; load_instance "<name>"
set -uo pipefail

VALHEIM_BASE="/srv/valheim"
INSTANCES_DIR="${VALHEIM_BASE}/instances"
SCRIPTS_DIR="${VALHEIM_BASE}/scripts"
INSTANCE_REGISTRY="${VALHEIM_BASE}/instances.registry"

if [[ -t 1 ]]; then
    C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_BLUE='\033[0;34m'
else
    C_RESET=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''
fi

# ts: current timestamp in the same format the installer uses.
ts() { date '+%Y-%m-%d %H:%M:%S'; }
# log_info / log_ok / log_warn / log_err: colored, timestamped status lines.
log_info() { echo -e "${C_BLUE}[INFO]${C_RESET} $(ts) $1"; }
log_ok()   { echo -e "${C_GREEN}[ OK ]${C_RESET} $(ts) $1"; }
log_warn() { echo -e "${C_YELLOW}[WARN]${C_RESET} $(ts) $1" >&2; }
log_err()  { echo -e "${C_RED}[FAIL]${C_RESET} $(ts) $1" >&2; }

# curl_with_retry: retries curl up to 3 times with a 5-second delay
# between attempts. Handles transient network glitches during server
# setup -- far better to retry silently than to abort over one failure.
curl_with_retry() {
    local attempt=1 max_attempts=3 delay_seconds=5
    while (( attempt <= max_attempts )); do
        if curl "$@"; then return 0; fi
        if (( attempt < max_attempts )); then
            log_warn "Network request failed (attempt ${attempt}/${max_attempts}); retrying in ${delay_seconds}s..."
            sleep "$delay_seconds"
        fi
        attempt=$(( attempt + 1 ))
    done
    log_err "Network request failed after ${max_attempts} attempts: curl $*"
    return 1
}

# The config file is 0600 (contains the password), readable only by root or
# the 'valheim' user. Any other invoking user gets transparently
# re-executed under sudo (all arguments preserved) instead of a confusing
# permission error. Skipped for systemd/cron, which already run as
# 'valheim' or root.
if [[ "${EUID}" -ne 0 && "$(id -un 2>/dev/null)" != "valheim" ]]; then
    if command -v sudo >/dev/null 2>&1; then
        exec sudo -E bash "$0" "$@"
    else
        echo "ERROR: this needs root (or the 'valheim' user) to read instance configs, and 'sudo' was not found." >&2
        exit 1
    fi
fi

# load_instance: sources the named instance's config.env, setting
# INSTANCE_DIR/INSTANCE_WORLD_DIR/INSTANCE_LOG_DIR/INSTANCE_SERVER_DIR
# alongside everything from that instance's config.env (SERVER_NAME,
# WORLD_NAME, SERVER_PASSWORD, SERVER_PORT, MAX_PLAYERS, etc.). Exits with
# a clear error (listing what IS available) if the name doesn't exist.
load_instance() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        echo "ERROR: an instance name is required." >&2
        list_instance_names_to_stderr
        exit 1
    fi
    INSTANCE_DIR="${INSTANCES_DIR}/${name}"
    local cfg="${INSTANCE_DIR}/config.env"
    if [[ ! -f "$cfg" ]]; then
        echo "ERROR: no instance named '${name}' (looked for ${cfg})." >&2
        list_instance_names_to_stderr
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$cfg"
    INSTANCE_SERVER_DIR="${INSTANCE_DIR}/server"
    INSTANCE_WORLD_DIR="${INSTANCE_DIR}/world"
    INSTANCE_LOG_DIR="${INSTANCE_DIR}/logs"
    INSTANCE_TMP_DIR="${INSTANCE_DIR}/tmp"
}

# list_instance_names_to_stderr: prints every known instance name to stderr
# (used inside error messages so a typo'd instance name is easy to fix).
list_instance_names_to_stderr() {
    echo "Known instances:" >&2
    awk -F: '{print "  " $1}' "$INSTANCE_REGISTRY" >&2 2>/dev/null
}

# all_instance_names: prints every registered instance name, one per line
# (used by scripts that operate across all instances, e.g. status/backup-all).
all_instance_names() {
    awk -F: '{print $1}' "$INSTANCE_REGISTRY" 2>/dev/null
}

# notify_discord: posts $1 to DISCORD_WEBHOOK_URL if one is configured for
# the currently loaded instance; a complete no-op otherwise.
notify_discord() {
    local message="$1"
    if [[ -n "${DISCORD_WEBHOOK_URL:-}" ]]; then
        local payload
        payload="$(printf '%s' "$message" | jq -Rs '{content: .}')"
        curl -fsS -m 10 -H "Content-Type: application/json" -d "$payload" \
            "$DISCORD_WEBHOOK_URL" >/dev/null 2>&1 || log_warn "Discord notification failed."
    fi
}

# have_enough_disk_space: returns 0 if the filesystem containing path $1
# has at least $2 MB free; otherwise logs an error and returns 1.
have_enough_disk_space() {
    local path="$1" min_mb="$2" avail_mb
    avail_mb="$(df --output=avail -m "$path" 2>/dev/null | tail -n1 | tr -d '[:space:]')"
    [[ -z "$avail_mb" ]] && return 0
    if (( avail_mb < min_mb )); then
        log_err "Only ${avail_mb}MB free on the filesystem containing ${path} (need ${min_mb}MB+). Aborting to avoid a corrupt result."
        return 1
    fi
    return 0
}
EOF
    chmod 644 "${SCRIPTS_DIR}/common.sh"
    chown "$VALHEIM_USER:$VALHEIM_GROUP" "${SCRIPTS_DIR}/common.sh"
}

# write_start_instance_script: writes scripts/start-instance.sh, the
# ExecStart target for the systemd template unit (valheim@<name>.service).
# Auto-detects whether this instance has a working BepInEx install (via
# BEPINEX_ENABLED in its config) and launches through the correct
# mechanism -- a BepInEx wrapper script if the pack shipped one, or the
# doorstop environment variables directly if not, falling back to a plain
# vanilla launch if BepInEx was never configured for this instance.
write_start_instance_script() {
    cat > "${SCRIPTS_DIR}/start-instance.sh" << 'EOF'
#!/usr/bin/env bash
# start-instance.sh <instance-name> - launches one Valheim instance in the
# foreground. Invoked by systemd (User=valheim) as
# ExecStart=.../start-instance.sh %i ; not meant to be run by hand except
# for debugging (use manual-foreground-start.sh for that instead, which
# handles dropping to the 'valheim' user for you).
set -uo pipefail
source /srv/valheim/scripts/common.sh
load_instance "${1:-}"

cd "$INSTANCE_SERVER_DIR" || { log_err "Server directory missing for instance '${INSTANCE_NAME}'."; exit 1; }

export SteamAppId=892970

args=(
    -name "$SERVER_NAME"
    -port "$SERVER_PORT"
    -world "$WORLD_NAME"
    -password "$SERVER_PASSWORD"
    -savedir "$INSTANCE_WORLD_DIR"
    -logFile "${INSTANCE_LOG_DIR}/valheim_server.log"
    -public 0
)
[[ "${CROSSPLAY:-0}" == "1" ]] && args+=(-crossplay)

log_info "[$INSTANCE_NAME] Launching (private, port ${SERVER_PORT}, world '${WORLD_NAME}', max players ${MAX_PLAYERS})..."

if [[ "${BEPINEX_ENABLED:-0}" == "1" ]]; then
    launcher="$(find "$INSTANCE_SERVER_DIR" -maxdepth 1 -iname '*bepinex*.sh' 2>/dev/null | head -n1)"
    doorstop_lib="$(find "$INSTANCE_SERVER_DIR" -iname 'libdoorstop*.so' 2>/dev/null | head -n1)"
    if [[ -n "$launcher" ]]; then
        exec "$launcher" "${args[@]}"
    elif [[ -n "$doorstop_lib" ]]; then
        export DOORSTOP_ENABLE=TRUE
        export DOORSTOP_TARGET_ASSEMBLY="${INSTANCE_SERVER_DIR}/BepInEx/core/BepInEx.Preloader.dll"
        export LD_PRELOAD="$doorstop_lib"
        exec ./valheim_server.x86_64 "${args[@]}"
    else
        log_warn "[$INSTANCE_NAME] BEPINEX_ENABLED=1 but no BepInEx loader was found; starting vanilla instead."
        exec ./valheim_server.x86_64 "${args[@]}"
    fi
else
    export LD_LIBRARY_PATH="./linux64:${LD_LIBRARY_PATH:-}"
    exec ./valheim_server.x86_64 "${args[@]}"
fi
EOF
    chmod 750 "${SCRIPTS_DIR}/start-instance.sh"
    chown "$VALHEIM_USER:$VALHEIM_GROUP" "${SCRIPTS_DIR}/start-instance.sh"
}

# write_fix_permissions_script: writes scripts/fix-permissions.sh, which
# runs as root via systemd's ExecStartPre=+ before every start/restart of
# ANY instance, fixing ownership on that one instance's directories (never
# runs the game itself as root).
write_fix_permissions_script() {
    cat > "${SCRIPTS_DIR}/fix-permissions.sh" << 'EOF'
#!/usr/bin/env bash
# fix-permissions.sh <instance-name>
set -Eeuo pipefail
VALHEIM_USER="valheim"
VALHEIM_GROUP="valheim"
INSTANCE_DIR="/srv/valheim/instances/${1:?instance name required}"

chown -R "${VALHEIM_USER}:${VALHEIM_GROUP}" \
    "${INSTANCE_DIR}/world" "${INSTANCE_DIR}/logs" "${INSTANCE_DIR}/tmp" "${INSTANCE_DIR}/server"
chmod 750 "${INSTANCE_DIR}/world" "${INSTANCE_DIR}/logs"
if [[ -f "${INSTANCE_DIR}/config.env" ]]; then
    chmod 600 "${INSTANCE_DIR}/config.env"
    chown "${VALHEIM_USER}:${VALHEIM_GROUP}" "${INSTANCE_DIR}/config.env"
fi
exit 0
EOF
    chmod 700 "${SCRIPTS_DIR}/fix-permissions.sh"
    chown root:root "${SCRIPTS_DIR}/fix-permissions.sh"
}

# write_service_wrapper_scripts: writes stop/restart/status/logs wrappers
# and a manual foreground-debugging launcher. Each accepts either one
# instance name or the literal "all" (where that makes sense) so a single
# admin never has to remember per-instance systemctl/journalctl syntax.
write_service_wrapper_scripts() {
    cat > "${SCRIPTS_DIR}/stop-valheim.sh" << 'EOF'
#!/usr/bin/env bash
# stop-valheim.sh <instance-name|all>
set -uo pipefail
source /srv/valheim/scripts/common.sh
if [[ $EUID -ne 0 ]]; then log_err "Please run with sudo: sudo $0 <instance|all>"; exit 1; fi
target="${1:-}"
[[ -n "$target" ]] || { echo "Usage: $0 <instance-name|all>"; list_instance_names_to_stderr; exit 1; }

names=()
if [[ "$target" == "all" ]]; then
    while IFS= read -r n; do names+=("$n"); done < <(all_instance_names)
else
    if [[ ! -f "/srv/valheim/instances/${target}/config.env" ]]; then
        echo "ERROR: no instance named '${target}' (looked for /srv/valheim/instances/${target}/config.env)." >&2
        list_instance_names_to_stderr
        exit 1
    fi
    names=("$target")
fi

for name in "${names[@]}"; do
    log_info "Stopping instance '${name}'..."
    systemctl stop "valheim@${name}"
    systemctl stop "valheim-sleep@${name}" 2>/dev/null || true
    sleep 1
    if systemctl is-active --quiet "valheim@${name}"; then
        log_err "Instance '${name}' is still active."
    else
        log_ok "Instance '${name}' stopped."
    fi
done
EOF

    cat > "${SCRIPTS_DIR}/restart-valheim.sh" << 'EOF'
#!/usr/bin/env bash
# restart-valheim.sh <instance-name|all>
set -uo pipefail
source /srv/valheim/scripts/common.sh
if [[ $EUID -ne 0 ]]; then log_err "Please run with sudo: sudo $0 <instance|all>"; exit 1; fi
target="${1:-}"
[[ -n "$target" ]] || { echo "Usage: $0 <instance-name|all>"; list_instance_names_to_stderr; exit 1; }

names=()
if [[ "$target" == "all" ]]; then
    while IFS= read -r n; do names+=("$n"); done < <(all_instance_names)
else
    if [[ ! -f "/srv/valheim/instances/${target}/config.env" ]]; then
        echo "ERROR: no instance named '${target}' (looked for /srv/valheim/instances/${target}/config.env)." >&2
        list_instance_names_to_stderr
        exit 1
    fi
    names=("$target")
fi

overall_rc=0
for name in "${names[@]}"; do
    load_instance "$name"
    if [[ "${ON_DEMAND:-0}" == "1" ]] && systemctl is-active --quiet "valheim-sleep@${name}"; then
        log_info "Instance '${name}' is sleeping -- waking it instead of restarting..."
        systemctl stop "valheim-sleep@${name}" 2>/dev/null || true
    else
        log_info "Restarting instance '${name}'..."
    fi
    systemctl restart "valheim@${name}"
    sleep 2
    if systemctl is-active --quiet "valheim@${name}"; then
        log_ok "Instance '${name}' restarted."
    else
        log_err "Instance '${name}' failed to restart. Check: journalctl -u valheim@${name} -n 100"
        overall_rc=1
    fi
done
exit $overall_rc
EOF

    cat > "${SCRIPTS_DIR}/status-valheim.sh" << 'EOF'
#!/usr/bin/env bash
# status-valheim.sh [instance-name]  (default: summary of every instance)
set -uo pipefail
source /srv/valheim/scripts/common.sh

target="${1:-}"

# print_one: prints a one-line summary row for instance $1 in the "all
# instances" table view.
print_one() {
    local name="$1"
    load_instance "$name"
    local state port2 port3
    state="$(systemctl is-active "valheim@${name}" 2>/dev/null || echo unknown)"
    if [[ "${ON_DEMAND:-0}" == "1" && "$state" != "active" ]]; then
        if systemctl is-active --quiet "valheim-sleep@${name}" 2>/dev/null; then
            state="sleeping"
        fi
    fi
    port2=$((SERVER_PORT + 1)); port3=$((SERVER_PORT + 2))
    local listening="no" ss_output
    ss_output="$(ss -uln 2>/dev/null)"
    grep -q ":${SERVER_PORT}[[:space:]]" <<< "$ss_output" && listening="yes"
    printf '%-16s %-10s %-8s %-22s %-8s %s\n' "$name" "$state" "$SERVER_PORT" "$SERVER_NAME" "$listening" "cap:${MAX_PLAYERS}"
}

if [[ -n "$target" ]]; then
    load_instance "$target"
    echo "======================================================"
    echo " Instance: ${target}"
    echo "======================================================"
    systemctl status "valheim@${target}" --no-pager -l 2>&1 || true
    echo
    port2=$((SERVER_PORT + 1)); port3=$((SERVER_PORT + 2))
    echo "--- Ports (${SERVER_PORT}, ${port2}, ${port3}) ---"
    ss -uln 2>/dev/null | grep -E ":(${SERVER_PORT}|${port2}|${port3})[[:space:]]" || echo "Not currently listening."
    echo
    echo "--- Disk usage ---"
    df -h "$INSTANCE_DIR"
else
    echo "======================================================"
    echo " All Instances"
    echo "======================================================"
    printf '%-16s %-10s %-8s %-22s %-8s %s\n' "NAME" "STATE" "PORT" "SERVER NAME" "LISTEN" "CAP"
    while IFS= read -r n; do
        [[ -n "$n" ]] && print_one "$n"
    done < <(all_instance_names)
    echo
    echo "--- Overall disk/RAM ---"
    df -h /srv/valheim
    free -h
fi
EOF

    cat > "${SCRIPTS_DIR}/logs-valheim.sh" << 'EOF'
#!/usr/bin/env bash
# logs-valheim.sh <instance-name> [service|game|backup|update]  (default: service)
set -uo pipefail
source /srv/valheim/scripts/common.sh

name="${1:-}"
[[ -n "$name" ]] || { echo "Usage: $0 <instance-name> [service|game|backup|update]"; list_instance_names_to_stderr; exit 1; }
load_instance "$name"
MODE="${2:-service}"

case "$MODE" in
    service|-f|follow)
        echo "Following systemd journal for valheim@${name}.service (Ctrl+C to stop)..."
        journalctl -u "valheim@${name}" -n 200 -f
        ;;
    game)
        echo "Following the game engine log file (Ctrl+C to stop)..."
        touch "${INSTANCE_LOG_DIR}/valheim_server.log"
        tail -n 200 -f "${INSTANCE_LOG_DIR}/valheim_server.log"
        ;;
    backup)
        tail -n 100 "${INSTANCE_LOG_DIR}/backup.log" 2>/dev/null || echo "No backup log yet."
        ;;
    update)
        tail -n 100 "${INSTANCE_LOG_DIR}/update.log" 2>/dev/null || echo "No update log yet."
        ;;
    *)
        echo "Usage: $0 <instance-name> [service|game|backup|update]"
        exit 1
        ;;
esac
EOF

    chmod 750 "${SCRIPTS_DIR}"/{stop-valheim.sh,restart-valheim.sh,status-valheim.sh,logs-valheim.sh}
    chown "$VALHEIM_USER:$VALHEIM_GROUP" "${SCRIPTS_DIR}"/{stop-valheim.sh,restart-valheim.sh,status-valheim.sh,logs-valheim.sh}

    cat > "${SCRIPTS_DIR}/manual-foreground-start.sh" << 'EOF'
#!/usr/bin/env bash
# manual-foreground-start.sh <instance-name> - runs one instance in the
# foreground for debugging, as the unprivileged 'valheim' user (same as the
# real systemd-managed service). Stop the real service first with:
#   sudo systemctl stop valheim@<instance-name>
# Tip: run this inside 'tmux' or 'screen' so you can detach and it keeps
# running, e.g.: tmux new -s debug
set -uo pipefail
source /srv/valheim/scripts/common.sh
name="${1:-}"
[[ -n "$name" ]] || { echo "Usage: $0 <instance-name>"; list_instance_names_to_stderr; exit 1; }
load_instance "$name"
if [[ $EUID -ne 0 ]]; then
    log_err "This needs root so it can switch to the 'valheim' user. Run with sudo."
    exit 1
fi
log_warn "Running instance '${name}' in the FOREGROUND for debugging. Press Ctrl+C to stop."
exec runuser -u valheim -- bash -c "/srv/valheim/scripts/start-instance.sh '${name}'"
EOF
    chmod 750 "${SCRIPTS_DIR}/manual-foreground-start.sh"
    chown "$VALHEIM_USER:$VALHEIM_GROUP" "${SCRIPTS_DIR}/manual-foreground-start.sh"
}

# write_backup_script: writes scripts/backup-valheim.sh <instance|all>.
write_backup_script() {
    cat > "${SCRIPTS_DIR}/backup-valheim.sh" << 'EOF'
#!/usr/bin/env bash
# backup-valheim.sh <instance-name|all> - creates a timestamped,
# integrity-checked ZIP backup of one instance's (or every instance's)
# current world, prunes old backups past that instance's retention, and
# sweeps up orphaned staging directories from any interrupted previous run.
# Exit codes: 0 = success (including "nothing to back up yet" or "disk too
# full, skipped"), 1 = a real failure.
set -uo pipefail
source /srv/valheim/scripts/common.sh

target="${1:-}"
[[ -n "$target" ]] || { echo "Usage: $0 <instance-name|all>"; list_instance_names_to_stderr; exit 1; }

# backup_one: performs the full backup+verify+prune flow for a single
# named instance; called once directly, or once per instance when the
# target is "all".
backup_one() {
    local name="$1"
    load_instance "$name"
    exec >> "${INSTANCE_LOG_DIR}/backup.log" 2>&1
    log_info "[$name] === Backup started ==="

    find "$INSTANCE_TMP_DIR" -maxdepth 1 -type d \( -name 'backup-staging-*' -o -name 'pre-restore-*' \) -mtime +1 -exec rm -rf {} + 2>/dev/null || true

    # Retention pruning always runs, independent of whether a NEW backup
    # gets created below -- this is deliberate: if world files are
    # temporarily missing, or the disk is too full to attempt a new
    # backup, old backups should still age out on schedule rather than
    # accumulating unbounded for the duration of any such issue. Pruning
    # first also gives the disk-space check below a chance to succeed by
    # freeing space before it's evaluated.
    local deleted=0
    while IFS= read -r -d '' old; do
        rm -f "$old"; log_info "[$name] Removed old backup: $(basename "$old")"; deleted=$((deleted+1))
    done < <(find "$BACKUP_DIR" -maxdepth 1 -name "valheim-backup-${name}-*.zip" -mtime "+${BACKUP_RETENTION_DAYS}" -print0 2>/dev/null)
    (( deleted > 0 )) && log_ok "[$name] Pruned ${deleted} old backup(s)."

    if ! have_enough_disk_space "$BACKUP_DIR" 200; then
        notify_discord "Valheim backup SKIPPED for [$name] on $(hostname): backup disk is nearly full."
        exit 1
    fi

    local ts_now archive_name archive_path staging
    ts_now="$(date '+%Y%m%d-%H%M%S')"
    staging="${INSTANCE_TMP_DIR}/backup-staging-${ts_now}"
    archive_name="valheim-backup-${name}-${WORLD_NAME}-${ts_now}.zip"
    archive_path="${BACKUP_DIR}/${archive_name}"

    mkdir -p "$BACKUP_DIR" "$staging"
    shopt -s nullglob
    world_files=("${INSTANCE_WORLD_DIR}/${WORLD_NAME}"*)
    shopt -u nullglob

    if [[ ${#world_files[@]} -eq 0 ]]; then
        log_warn "[$name] No world files found yet for '${WORLD_NAME}'. Nothing to back up."
        rmdir "$staging" 2>/dev/null || true
        exit 0
    fi

    if ! rsync -a "${world_files[@]}" "${staging}/"; then
        log_err "[$name] Failed to copy world files into staging."; rm -rf "$staging"; exit 1
    fi
    if ! ( cd "$staging" && zip -rq "$archive_path" . ); then
        log_err "[$name] Failed to create archive ${archive_path}."; rm -rf "$staging"; exit 1
    fi
    rm -rf "$staging"

    if unzip -tq "$archive_path" >/dev/null 2>&1; then
        log_ok "[$name] Backup created and verified: ${archive_path}"
    else
        log_err "[$name] Backup verification FAILED for ${archive_path}."
        notify_discord "Valheim backup verification FAILED for [$name] on $(hostname)."
        exit 1
    fi

    log_ok "[$name] === Backup finished. ${deleted} old backup(s) pruned. ==="
    notify_discord "Valheim backup completed for [$name] on $(hostname): ${archive_name}"
}

if [[ "$target" == "all" ]]; then
    overall_rc=0
    while IFS= read -r n; do
        [[ -n "$n" ]] || continue
        ( backup_one "$n" ) || overall_rc=1
    done < <(all_instance_names)
    exit $overall_rc
else
    ( backup_one "$target" )
fi
EOF
    chmod 750 "${SCRIPTS_DIR}/backup-valheim.sh"
    chown "$VALHEIM_USER:$VALHEIM_GROUP" "${SCRIPTS_DIR}/backup-valheim.sh"
}

# write_restore_script: writes scripts/restore-valheim.sh <instance> <backup.zip>.
write_restore_script() {
    cat > "${SCRIPTS_DIR}/restore-valheim.sh" << 'EOF'
#!/usr/bin/env bash
# restore-valheim.sh <instance-name> <path-to-backup.zip> - restores one
# instance's world from a backup made by backup-valheim.sh. Stops that
# instance, saves whatever world is currently in place as a safety copy,
# restores, then restarts.
set -uo pipefail
source /srv/valheim/scripts/common.sh

# usage: prints how to call this script, plus (if an instance name was
# already given) that instance's available backups, then exits 1.
usage() {
    echo "Usage: $0 <instance-name> <path-to-backup.zip>"
    list_instance_names_to_stderr
    if [[ -n "${1:-}" ]]; then
        echo "Available backups for '${1}':" >&2
        ls -1t "${BACKUP_DIR:-}"/valheim-backup-"${1}"-*.zip 2>/dev/null >&2 || echo "  (none found)" >&2
    fi
    exit 1
}

name="${1:-}"; backup_file="${2:-}"
[[ -n "$name" ]] || usage
load_instance "$name"
[[ -n "$backup_file" ]] || usage "$name"

if [[ $EUID -ne 0 ]]; then log_err "Please run with sudo (needs to stop/start the systemd service)."; exit 1; fi
[[ -f "$backup_file" ]] || { log_err "File not found: $backup_file"; exit 1; }
if ! unzip -tq "$backup_file" >/dev/null 2>&1; then log_err "That file does not look like a valid ZIP archive."; exit 1; fi
have_enough_disk_space "$INSTANCE_WORLD_DIR" 200 || exit 1

log_info "[$name] Stopping service..."
systemctl stop "valheim@${name}"

safety_ts="$(date '+%Y%m%d-%H%M%S')"
safety_dir="${INSTANCE_TMP_DIR}/pre-restore-${safety_ts}"
mkdir -p "$safety_dir"
shopt -s nullglob
current_files=("${INSTANCE_WORLD_DIR}/${WORLD_NAME}"*)
shopt -u nullglob
if [[ ${#current_files[@]} -gt 0 ]]; then
    cp -a "${current_files[@]}" "$safety_dir/"
    log_info "[$name] Safety copy of current world saved to ${safety_dir}"
else
    log_warn "[$name] No current world files to back up before restoring (fine on a first restore)."
fi

log_info "[$name] Extracting backup: $backup_file"
if ! unzip -oq "$backup_file" -d "$INSTANCE_WORLD_DIR"; then
    log_err "[$name] Extraction failed. Restarting with the previous world untouched."
    systemctl start "valheim@${name}"
    exit 1
fi
chown -R valheim:valheim "$INSTANCE_WORLD_DIR"

log_info "[$name] Starting service..."
systemctl start "valheim@${name}"
sleep 2
if systemctl is-active --quiet "valheim@${name}"; then
    log_ok "[$name] Restore complete and running. Safety copy: ${safety_dir}"
else
    log_err "[$name] Service did not come back up. Check: journalctl -u valheim@${name} -n 100"
    exit 1
fi
EOF
    chmod 750 "${SCRIPTS_DIR}/restore-valheim.sh"
    chown "$VALHEIM_USER:$VALHEIM_GROUP" "${SCRIPTS_DIR}/restore-valheim.sh"
}

# write_update_script: writes scripts/update-valheim.sh <instance|all>.
# Always validates the shared GOLDEN server first (cheap/incremental if
# nothing changed), then re-syncs and restarts only the targeted
# instance(s) -- so updating "all" rolls through shards one at a time
# instead of taking every shard offline simultaneously.
write_update_script() {
    cat > "${SCRIPTS_DIR}/update-valheim.sh" << 'EOF'
#!/usr/bin/env bash
# update-valheim.sh <instance-name|all>
set -uo pipefail
source /srv/valheim/scripts/common.sh

GOLDEN_SERVER_DIR="/srv/valheim/golden-server"
STEAMCMD_DIR="/srv/valheim/steamcmd"

if [[ $EUID -ne 0 ]]; then log_err "Please run with sudo."; exit 1; fi

target="${1:-}"
[[ -n "$target" ]] || { echo "Usage: $0 <instance-name|all>"; list_instance_names_to_stderr; exit 1; }

log_info "=== Update check started (target: ${target}) ==="

if ! have_enough_disk_space "$GOLDEN_SERVER_DIR" 1024; then
    log_err "Disk nearly full; skipping the update entirely."
    exit 1
fi

log_info "Validating the shared golden install via SteamCMD..."
steamcmd_rc=0
runuser -u valheim -- bash -c \
    "\"${STEAMCMD_DIR}/steamcmd.sh\" +force_install_dir \"${GOLDEN_SERVER_DIR}\" +login anonymous +app_update 896660 validate +quit" \
    || steamcmd_rc=$?
log_info "SteamCMD exited with code ${steamcmd_rc} (informational; verifying binary directly)."

if [[ ! -x "${GOLDEN_SERVER_DIR}/valheim_server.x86_64" ]]; then
    log_err "Golden server executable missing after update! Aborting before touching any instance."
    exit 1
fi
log_ok "Golden install verified."

# update_one: syncs one instance from the (already-validated) golden
# install and restarts it if it was running; called once directly, or
# once per instance (sequentially, not all at once) when target is "all".
update_one() {
    local name="$1"
    load_instance "$name"
    local was_active=0
    if systemctl is-active --quiet "valheim@${name}"; then
        was_active=1
        log_info "[$name] Stopping for update..."
        systemctl stop "valheim@${name}"
    fi

    log_info "[$name] Syncing server files from the golden install..."
    if ! rsync -a "${GOLDEN_SERVER_DIR}/" "${INSTANCE_SERVER_DIR}/"; then
        log_err "[$name] Sync from golden failed!"
        [[ "$was_active" -eq 1 ]] && systemctl start "valheim@${name}"
        return 1
    fi
    chown -R valheim:valheim "$INSTANCE_SERVER_DIR"

    if [[ "$was_active" -eq 1 ]]; then
        log_info "[$name] Restarting..."
        systemctl start "valheim@${name}"
        sleep 3
        if systemctl is-active --quiet "valheim@${name}"; then
            log_ok "[$name] Restarted successfully after update."
        else
            log_err "[$name] FAILED to restart after update!"
            notify_discord "Valheim instance [$name] failed to restart after update on $(hostname)."
            return 1
        fi
    fi
    notify_discord "Valheim instance [$name] updated on $(hostname)."
    return 0
}

if [[ "$target" == "all" ]]; then
    overall_rc=0
    while IFS= read -r n; do
        [[ -n "$n" ]] || continue
        update_one "$n" >> "/srv/valheim/instances/${n}/logs/update.log" 2>&1 || overall_rc=1
    done < <(all_instance_names)
    exit $overall_rc
else
    if [[ ! -f "/srv/valheim/instances/${target}/config.env" ]]; then
        echo "ERROR: no instance named '${target}' (looked for /srv/valheim/instances/${target}/config.env)." >&2
        list_instance_names_to_stderr
        exit 1
    fi
    update_one "$target" >> "/srv/valheim/instances/${target}/logs/update.log" 2>&1
fi
EOF
    chmod 750 "${SCRIPTS_DIR}/update-valheim.sh"
    chown "$VALHEIM_USER:$VALHEIM_GROUP" "${SCRIPTS_DIR}/update-valheim.sh"
}

# write_healthcheck_script: writes scripts/healthcheck-valheim.sh
# <instance|all>. Verifies the service is active and its game port is
# listening; restarts automatically if run as root. A grace period avoids
# false alarms while a fresh world is still generating.
write_healthcheck_script() {
    cat > "${SCRIPTS_DIR}/healthcheck-valheim.sh" << 'EOF'
#!/usr/bin/env bash
# healthcheck-valheim.sh <instance-name|all>
set -uo pipefail
source /srv/valheim/scripts/common.sh

GRACE_PERIOD_SECONDS=180
target="${1:-}"
[[ -n "$target" ]] || { echo "Usage: $0 <instance-name|all>"; list_instance_names_to_stderr; exit 1; }

# check_one: verifies (and, if run as root, self-heals) a single named
# instance; called once directly, or once per instance when target is "all".
check_one() {
    local name="$1"
    load_instance "$name"

    if ! systemctl is-active --quiet "valheim@${name}"; then
        log_err "[$name] Service is not active."
        if [[ $EUID -eq 0 ]]; then
            log_warn "[$name] Attempting to start..."
            systemctl start "valheim@${name}"
            notify_discord "Valheim instance [$name] was down on $(hostname) -- restarted automatically."
        fi
        return 1
    fi
    log_ok "[$name] Service is active."

    if [[ "${BEPINEX_ENABLED:-0}" == "1" ]]; then
        local cfg="${INSTANCE_SERVER_DIR}/BepInEx/config/Azumatt.MaxPlayerCount.cfg"
        if [[ -f "$cfg" ]]; then
            if ! grep -q "^MaxPlayers = ${MAX_PLAYERS}$" "$cfg"; then
                log_warn "[$name] MaxPlayerCount's config no longer matches the configured MAX_PLAYERS=${MAX_PLAYERS} (check ${cfg})."
            fi
        else
            log_warn "[$name] BEPINEX_ENABLED=1 but ${cfg} is missing -- the player cap may silently be back to vanilla (10)."
        fi
    fi

    local active_since_raw active_since_epoch=0 now_epoch uptime_seconds
    active_since_raw="$(systemctl show "valheim@${name}" --property=ActiveEnterTimestamp --value 2>/dev/null || true)"
    [[ -n "$active_since_raw" ]] && active_since_epoch="$(date -d "$active_since_raw" +%s 2>/dev/null || echo 0)"
    now_epoch="$(date +%s)"
    uptime_seconds=$(( now_epoch - active_since_epoch ))

    if [[ "$active_since_epoch" -eq 0 || "$uptime_seconds" -lt "$GRACE_PERIOD_SECONDS" ]]; then
        log_info "[$name] Started recently (~${uptime_seconds}s ago); skipping port check for now."
        return 0
    fi

    local ss_output
    ss_output="$(ss -uln 2>/dev/null)"
    if grep -q ":${SERVER_PORT}[[:space:]]" <<< "$ss_output"; then
        log_ok "[$name] Game port ${SERVER_PORT}/udp is listening."
        return 0
    fi

    log_err "[$name] Game port ${SERVER_PORT}/udp is not listening after the grace period."
    if [[ $EUID -eq 0 ]]; then
        log_warn "[$name] Restarting..."
        systemctl restart "valheim@${name}"
        notify_discord "Valheim instance [$name] port was unresponsive on $(hostname) -- restarted automatically."
    fi
    return 1
}

overall_rc=0
if [[ "$target" == "all" ]]; then
    while IFS= read -r n; do
        [[ -n "$n" ]] || continue
        check_one "$n" || overall_rc=1
    done < <(all_instance_names)
else
    check_one "$target" || overall_rc=1
fi
exit $overall_rc
EOF
    chmod 750 "${SCRIPTS_DIR}/healthcheck-valheim.sh"
    chown "$VALHEIM_USER:$VALHEIM_GROUP" "${SCRIPTS_DIR}/healthcheck-valheim.sh"
}

# write_monitoring_scripts: writes the CPU/RAM/disk/SMART/network helpers.
# Network status is instance-aware (lists every instance's ports); the
# others are host-wide and unchanged by the multi-instance model.
write_monitoring_scripts() {
    cat > "${SCRIPTS_DIR}/cpu-status.sh" << 'EOF'
#!/usr/bin/env bash
# cpu-status.sh - CPU model/topology, a live usage snapshot, and the top
# CPU-consuming processes (useful for seeing which instance is busiest).
set -uo pipefail
echo "=== CPU Info ==="
lscpu | grep -E 'Model name|Socket|Core\(s\) per socket|Thread\(s\) per core' || true
echo
echo "=== Live Snapshot ==="
top -bn1 | grep -i "Cpu(s)" || true
echo
echo "=== Top CPU-consuming processes ==="
ps aux --sort=-%cpu | head -n 10
EOF

    cat > "${SCRIPTS_DIR}/ram-status.sh" << 'EOF'
#!/usr/bin/env bash
# ram-status.sh - memory usage and the top memory-consuming processes.
set -uo pipefail
echo "=== Memory Usage ==="
free -h
echo
echo "=== Top memory-consuming processes ==="
ps aux --sort=-%mem | head -n 10
EOF

    cat > "${SCRIPTS_DIR}/disk-status.sh" << 'EOF'
#!/usr/bin/env bash
# disk-status.sh - filesystem usage and a per-instance size breakdown.
set -uo pipefail
echo "=== Disk Usage ==="
df -h /srv/valheim /
echo
echo "=== Per-Instance Sizes ==="
du -sh /srv/valheim/instances/*/ 2>/dev/null
echo
echo "=== Golden Install / SteamCMD ==="
du -sh /srv/valheim/golden-server /srv/valheim/steamcmd 2>/dev/null
EOF

    cat > "${SCRIPTS_DIR}/smart-status.sh" << 'EOF'
#!/usr/bin/env bash
# smart-status.sh - SMART health for every detected physical disk.
set -uo pipefail
[[ $EUID -ne 0 ]] && echo "Note: run with sudo for complete SMART data."
disks="$(lsblk -dn -o NAME 2>/dev/null | grep -E '^(sd|nvme|vd)' || true)"
if [[ -z "$disks" ]]; then echo "No physical disks detected by lsblk."; exit 0; fi
for disk in $disks; do
    echo "=== /dev/${disk} ==="
    smartctl -H "/dev/${disk}" 2>/dev/null || echo "  SMART data not available for /dev/${disk}."
    echo
done
EOF

    cat > "${SCRIPTS_DIR}/network-status.sh" << 'EOF'
#!/usr/bin/env bash
# network-status.sh - interfaces, every instance's listening ports, and UFW status.
set -uo pipefail
source /srv/valheim/scripts/common.sh
echo "=== Network Interfaces ==="
ip -brief addr show 2>/dev/null || ip addr show
echo
echo "=== Per-Instance Ports ==="
printf '%-16s %-8s %s\n' "INSTANCE" "PORT" "LISTENING"
while IFS=: read -r name port _; do
    [[ -n "$name" ]] || continue
    listening="no"
    ss_output="$(ss -uln 2>/dev/null)"
    grep -q ":${port}[[:space:]]" <<< "$ss_output" && listening="yes"
    printf '%-16s %-8s %s\n' "$name" "$port" "$listening"
done < "$INSTANCE_REGISTRY"
echo
echo "=== UFW Status ==="
ufw status verbose 2>/dev/null || echo "UFW not active or not installed."
EOF

    chmod 750 "${SCRIPTS_DIR}"/{cpu-status.sh,ram-status.sh,disk-status.sh,smart-status.sh,network-status.sh}
    chown "$VALHEIM_USER:$VALHEIM_GROUP" "${SCRIPTS_DIR}"/{cpu-status.sh,ram-status.sh,disk-status.sh,smart-status.sh,network-status.sh}
}

# write_all_helper_scripts: generates every helper script in one call.
write_all_helper_scripts() {
    log_step "Generating helper and monitoring scripts"
    write_common_script
    write_start_instance_script
    write_fix_permissions_script
    write_service_wrapper_scripts
    write_backup_script
    write_restore_script
    write_update_script
    write_healthcheck_script
    write_monitoring_scripts
    write_host_capacity_monitor_script
    write_sleep_listener_script
    write_wake_instance_script
    write_idle_monitor_script
    log_ok "Helper scripts written to ${SCRIPTS_DIR}/"
}

###############################################################################
# SYSTEMD TEMPLATE UNIT
###############################################################################

# install_systemd_template: writes ONE templated unit,
# /etc/systemd/system/valheim@.service -- systemd's "%i" is substituted
# with whatever instance name follows the @ when the unit is
# started/enabled (e.g. `systemctl start valheim@shard1`). This means
# adding a new instance never requires writing a new unit file.
install_systemd_template() {
    log_step "Installing systemd template unit"

    cat > "$SYSTEMD_TEMPLATE_UNIT_PATH" << EOF
[Unit]
Description=Valheim Dedicated Server (instance: %i)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=${VALHEIM_USER}
Group=${VALHEIM_GROUP}
WorkingDirectory=${INSTANCES_DIR}/%i/server

# Runs as root just long enough to fix this instance's ownership, then
# drops privileges for the actual game process.
ExecStartPre=+${SCRIPTS_DIR}/fix-permissions.sh %i
ExecStart=${SCRIPTS_DIR}/start-instance.sh %i

Restart=always
RestartSec=10

# Valheim only saves the world cleanly on SIGINT, not SIGTERM.
KillSignal=SIGINT
TimeoutStopSec=30

LimitNOFILE=100000
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$SYSTEMD_TEMPLATE_UNIT_PATH"
    systemctl daemon-reload
    log_ok "systemd template installed at ${SYSTEMD_TEMPLATE_UNIT_PATH}."
}

# enable_and_start_instance_service: enables (auto-start on boot) and
# starts one instance's systemd unit, then polls for the game port to
# actually bind (a fresh world can take a minute or two to generate).
enable_and_start_instance_service() {
    local name="$1" port="$2"
    log_step "[$name] Starting service"

    systemctl enable "valheim@${name}" >>"$LOG_FILE" 2>&1
    systemctl restart "valheim@${name}"
    log_info "[$name] Waiting for the world to load and the game port to bind..."

    local waited=0 max_wait=180 port_ready=0 ss_output
    while (( waited < max_wait )); do
        if systemctl is-active --quiet "valheim@${name}"; then
            ss_output="$(ss -uln 2>/dev/null)"
            if grep -q ":${port}[[:space:]]" <<< "$ss_output"; then
                port_ready=1; break
            fi
        else
            log_err "[$name] Service is not active. Recent logs:"
            journalctl -u "valheim@${name}" -n 40 --no-pager >> "$LOG_FILE" 2>&1
            die "[$name] Failed to start. See ${LOG_FILE} and: journalctl -u valheim@${name} -n 100"
        fi
        sleep 5; waited=$(( waited + 5 )); echo -n "."
    done
    echo

    if [[ "$port_ready" -eq 1 ]]; then
        log_ok "[$name] Active and port ${port}/udp is listening (after ~${waited}s)."
    else
        log_warn "[$name] Active, but port ${port}/udp was not yet listening after ${max_wait}s (can happen while a new world generates). Check later with: status-valheim.sh ${name}"
    fi
}

###############################################################################
# FIREWALL (UFW) -- per instance
###############################################################################

# configure_firewall_base: one-time setup -- rate-limited SSH, and enables
# UFW if it wasn't already active (asking first, never silently taking
# over an already-managed firewall). This is a Valheim-specific version
# with rate-limiting and UFW enablement that the generic common.sh version
# does not provide.
configure_firewall_base() {
    log_step "Configuring firewall (UFW) -- base rules"
    local ssh_port=22
    if [[ -r /etc/ssh/sshd_config ]]; then
        local configured_ssh_port
        configured_ssh_port="$(awk '/^[Pp]ort[ \t]+[0-9]+/{print $2; exit}' /etc/ssh/sshd_config || true)"
        [[ -n "$configured_ssh_port" ]] && ssh_port="$configured_ssh_port"
    fi
    log_info "Allowing SSH on port ${ssh_port}/tcp (rate-limited against brute force)..."
    ufw limit "${ssh_port}/tcp" comment 'SSH (rate-limited)' >>"$LOG_FILE" 2>&1

    if ufw status | grep -q "Status: active"; then
        log_ok "UFW is already active."
    else
        local enable_ufw="yes"
        if [[ "$ASSUME_DEFAULTS" -ne 1 ]]; then
            local reply=""
            read -r -p "UFW is currently inactive. Enable it now to secure this server? [Y/n]: " reply < /dev/tty || true
            reply="${reply:-y}"
            [[ "$reply" =~ ^[Yy] ]] || enable_ufw="no"
        fi
        if [[ "$enable_ufw" == "yes" ]]; then
            ufw --force enable >>"$LOG_FILE" 2>&1
            log_ok "UFW enabled (SSH allowed)."
        else
            log_warn "Leaving UFW disabled at your request."
        fi
    fi
}

# configure_firewall_for_instance: opens the 3-port UDP block for one
# instance.
configure_firewall_for_instance() {
    local name="$1" port="$2"
    local port2=$((port+1)) port3=$((port+2))
    log_info "[$name] Allowing UDP ${port}, ${port2}, ${port3}..."
    ufw allow "${port}/udp" comment "Valheim:${name}" >>"$LOG_FILE" 2>&1
    ufw allow "${port2}/udp" comment "Valheim:${name}" >>"$LOG_FILE" 2>&1
    ufw allow "${port3}/udp" comment "Valheim:${name}" >>"$LOG_FILE" 2>&1
}

###############################################################################
# FAIL2BAN (SSH brute-force protection) -- unchanged from v1, host-wide
###############################################################################

# configure_fail2ban: Valheim-specific version with progressive banning
# (increasing ban durations on repeat offenders). The common.sh version
# uses a different filter/config that may not be suitable.
configure_fail2ban() {
    log_step "Configuring fail2ban (SSH brute-force protection)"
    local ssh_port=22
    if [[ -r /etc/ssh/sshd_config ]]; then
        local configured_ssh_port
        configured_ssh_port="$(awk '/^[Pp]ort[ \t]+[0-9]+/{print $2; exit}' /etc/ssh/sshd_config || true)"
        [[ -n "$configured_ssh_port" ]] && ssh_port="$configured_ssh_port"
    fi
    cat > "$FAIL2BAN_JAIL_LOCAL" << EOF
# Managed by ${SCRIPT_NAME}.
[DEFAULT]
bantime.increment = true
bantime.multipliers = 1 2 4 8 16 32 64
bantime.maxtime = 1w
bantime.rndtime = 30

[sshd]
enabled  = true
port     = ${ssh_port}
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 1h
EOF
    chmod 644 "$FAIL2BAN_JAIL_LOCAL"
    systemctl enable fail2ban >>"$LOG_FILE" 2>&1 || true
    systemctl restart fail2ban >>"$LOG_FILE" 2>&1
    if systemctl is-active --quiet fail2ban; then
        log_ok "fail2ban is active, protecting SSH on port ${ssh_port}."
    else
        log_warn "fail2ban did not start correctly; check 'systemctl status fail2ban'."
    fi
}

###############################################################################
# LOG ROTATION + JOURNALD CAP -- host-wide, unchanged in spirit from v1
###############################################################################

# configure_logrotate: Valheim-specific version that rotates all instance
# logs via a glob pattern. The common.sh version only handles a single
# file path, which is incompatible with multi-instance setups.
configure_logrotate() {
    log_step "Configuring log rotation"
    cat > "$LOGROTATE_CONF" << EOF
${INSTANCES_DIR}/*/logs/*.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    create 0640 ${VALHEIM_USER} ${VALHEIM_GROUP}
}
EOF
    chmod 644 "$LOGROTATE_CONF"
    log_ok "Logrotate configured: weekly rotation, 8 weeks retained, compressed (applies to every instance)."
}

# configure_journald_limit is provided by common.sh. It takes
# (journald_conf, max_use) -- we compute the value from instance count
# and fleet-size constants, then pass it.

###############################################################################
# CRON SCHEDULING -- one shared set of cron files that loop over every
# registered instance and run each at ITS OWN configured time, rather than
# one cron file per instance (which would mean rewriting /etc/cron.d every
# time an instance is added or removed).
###############################################################################
schedule_cron_jobs() {
    log_step "Scheduling backups, updates, and health checks"

    cat > "$CRON_BACKUP_FILE" << EOF
# Managed by ${SCRIPT_NAME}. Runs every minute (cheap -- it's just a string
# comparison per instance); each instance's own BACKUP_TIME in config.env
# decides whether now is actually its scheduled time -- see
# cron-backup-dispatch.sh. Every minute (not every 5) so any HH:MM value an
# admin picks is guaranteed to actually fire.
* * * * * ${VALHEIM_USER} ${SCRIPTS_DIR}/cron-backup-dispatch.sh
EOF
    chmod 644 "$CRON_BACKUP_FILE"

    cat > "$CRON_UPDATE_FILE" << EOF
# Managed by ${SCRIPT_NAME}. Same dispatch pattern as backups, for updates.
* * * * * root ${SCRIPTS_DIR}/cron-update-dispatch.sh
EOF
    chmod 644 "$CRON_UPDATE_FILE"

    cat > "$CRON_HEALTHCHECK_FILE" << EOF
# Managed by ${SCRIPT_NAME} - health check / self-healing restart, all instances.
*/10 * * * * root ${SCRIPTS_DIR}/healthcheck-valheim.sh all >> ${VALHEIM_BASE}/instances-healthcheck.log 2>&1
EOF
    chmod 644 "$CRON_HEALTHCHECK_FILE"

    cat > "$CRON_CAPACITY_FILE" << EOF
# Managed by ${SCRIPT_NAME} - host-wide CPU/RAM utilization monitor (see
# ${VALHEIM_BASE}/host-capacity.log). Read-only checks; runs as the
# unprivileged valheim user.
*/15 * * * * ${VALHEIM_USER} ${SCRIPTS_DIR}/host-capacity-monitor.sh
EOF
    chmod 644 "$CRON_CAPACITY_FILE"

    cat > "$CRON_IDLE_FILE" << EOF
# Managed by ${SCRIPT_NAME} - on-demand idle detection (auto-save + auto-stop).
* * * * * root ${SCRIPTS_DIR}/idle-monitor.sh >> ${VALHEIM_BASE}/idle-monitor.log 2>&1
EOF
    chmod 644 "$CRON_IDLE_FILE"

    systemctl reload cron >>"$LOG_FILE" 2>&1 || systemctl restart cron >>"$LOG_FILE" 2>&1 || true
    log_ok "Cron scheduling installed (checked every minute for any instance whose backup/update time has arrived; health checks every 10 minutes; host capacity checked every 15 minutes)."
}

# write_cron_dispatch_scripts: writes the two small dispatcher scripts cron
# actually calls every 5 minutes, each of which checks EVERY instance's own
# BACKUP_TIME/UPDATE_TIME against the current HH:MM and only actually runs
# backup-valheim.sh/update-valheim.sh for instances whose time it is right
# now. This is what lets each instance keep its own independently-chosen
# schedule without maintaining one cron line per instance.
write_cron_dispatch_scripts() {
    cat > "${SCRIPTS_DIR}/cron-backup-dispatch.sh" << 'EOF'
#!/usr/bin/env bash
set -uo pipefail
source /srv/valheim/scripts/common.sh
now_hhmm="$(date '+%H:%M')"
while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    load_instance "$name"
    if [[ "${BACKUP_TIME:-}" == "$now_hhmm" ]]; then
        /srv/valheim/scripts/backup-valheim.sh "$name"
    fi
done < <(all_instance_names)
EOF

    cat > "${SCRIPTS_DIR}/cron-update-dispatch.sh" << 'EOF'
#!/usr/bin/env bash
set -uo pipefail
source /srv/valheim/scripts/common.sh
now_hhmm="$(date '+%H:%M')"
while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    load_instance "$name"
    if [[ "${UPDATE_TIME:-}" == "$now_hhmm" ]]; then
        /srv/valheim/scripts/update-valheim.sh "$name"
    fi
done < <(all_instance_names)
EOF
    chmod 750 "${SCRIPTS_DIR}/cron-backup-dispatch.sh" "${SCRIPTS_DIR}/cron-update-dispatch.sh"
    chown "$VALHEIM_USER:$VALHEIM_GROUP" "${SCRIPTS_DIR}/cron-backup-dispatch.sh" "${SCRIPTS_DIR}/cron-update-dispatch.sh"
}

###############################################################################
# INSTANCE ORCHESTRATION: add / remove / list
###############################################################################

# add_instance: the full flow for bringing up one new shard -- gather
# input, allocate a port, create directories, sync from golden, optionally
# install BepInEx/MaxPlayerCount, write config, register it, wire up
# systemd/firewall, start it, and print a connection summary.
add_instance() {
    local suggested_name="${1:-}"

    check_host_capacity_before_add
    gather_instance_input "$suggested_name"

    create_instance_directories "$INSTANCE_NAME"
    sync_instance_from_golden "$INSTANCE_NAME"

    BEPINEX_ENABLED=0
    if (( MAX_PLAYERS > VANILLA_MAX_PLAYERS )); then
        log_step "[$INSTANCE_NAME] Installing mods to raise the player cap to ${MAX_PLAYERS}"
        if install_bepinex_and_maxplayercount "$INSTANCE_NAME" && configure_max_player_count "$INSTANCE_NAME" "$MAX_PLAYERS"; then
            BEPINEX_ENABLED=1
            log_ok "[$INSTANCE_NAME] Modded cap active: up to ${MAX_PLAYERS} players."
        else
            log_warn "[$INSTANCE_NAME] Falling back to VANILLA (10-player cap) for this instance -- see warnings above for exactly why."
            MAX_PLAYERS="$VANILLA_MAX_PLAYERS"
            BEPINEX_ENABLED=0
        fi
    fi

    write_instance_config "$INSTANCE_NAME"
    registry_add "$INSTANCE_NAME" "$SERVER_PORT"

    configure_firewall_for_instance "$INSTANCE_NAME" "$SERVER_PORT"

    if [[ "$ON_DEMAND" == "1" ]]; then
        log_step "[$INSTANCE_NAME] Enabling on-demand mode (sleeping until a player connects)"
        systemctl enable "valheim@${INSTANCE_NAME}" >>"$LOG_FILE" 2>&1
        systemctl enable --now "valheim-sleep@${INSTANCE_NAME}" >>"$LOG_FILE" 2>&1
        if systemctl is-active --quiet "valheim-sleep@${INSTANCE_NAME}"; then
            log_ok "[$INSTANCE_NAME] Sleeping -- will wake automatically on the first connection to port ${SERVER_PORT}."
        else
            log_warn "[$INSTANCE_NAME] Sleep listener did not start; check 'systemctl status valheim-sleep@${INSTANCE_NAME}'."
        fi
    else
        enable_and_start_instance_service "$INSTANCE_NAME" "$SERVER_PORT"
    fi

    print_instance_summary "$INSTANCE_NAME"
}

# remove_instance: stops/disables one instance's service, removes its
# firewall rules and registry entry, then asks (separately) whether to
# also delete its data (world/backups/logs). Always cleans up firewall
# and registry even if the port lookup fails (best-effort cleanup).
remove_instance() {
    local name="$1"
    # Validate before this name is used inside grep/sed patterns in the
    # registry_* helpers below -- an unvalidated --remove-instance value
    # (this function's only caller besides the validated interactive path)
    # could otherwise contain regex metacharacters. A name like ".*" would
    # make registry_has() match any line (bypassing the "no such instance"
    # error right below) and make registry_remove()'s sed delete every
    # line in instances.registry, wiping the whole fleet's bookkeeping.
    validate_instance_name "$name" >/dev/null \
        || die "Instance name '${name}' is invalid: letters, numbers, '_', '-' only, 1-32 characters."
    registry_has "$name" || die "No instance named '${name}' is registered. Use --list-instances to see what exists."

    log_step "Removing instance '${name}'"
    local port; port="$(registry_port_for "$name")"

    systemctl stop "valheim@${name}" 2>>"$LOG_FILE" || true
    systemctl disable "valheim@${name}" 2>>"$LOG_FILE" || true
    systemctl stop "valheim-sleep@${name}" 2>>"$LOG_FILE" || true
    systemctl disable "valheim-sleep@${name}" 2>>"$LOG_FILE" || true

    if [[ -n "$port" ]]; then
        remove_firewall_for_instance "$name" "$port"
    else
        log_warn "Could not look up port for '${name}'; firewall rules may need manual cleanup."
    fi
    registry_remove "$name"
    log_ok "Service, firewall rules, and registry entry removed for '${name}'."

    # In non-interactive mode (-y), skip the data deletion prompt entirely
    # to avoid hanging. Data is preserved by default (safe choice).
    if [[ "$ASSUME_DEFAULTS" -eq 1 ]]; then
        log_info "Non-interactive mode: preserving data at $(instance_dir "$name")."
        return 0
    fi

    local confirm=""
    read -r -p "Also DELETE all data for '${name}' (world, backups, logs)? Type 'yes' to confirm: " confirm < /dev/tty || true
    if [[ "$confirm" == "yes" ]]; then
        rm -rf "$(instance_dir "$name")"
        log_ok "Removed $(instance_dir "$name")."
    else
        log_ok "Data preserved at $(instance_dir "$name")."
    fi
}

# list_instances: prints a quick table of every registered instance
# (delegates to the generated status-valheim.sh for the live/detailed view).
list_instances() {
    if ! registry_base_exists; then
        echo "Nothing installed yet. Run the installer first: ./${SCRIPT_NAME}"
        return 0
    fi
    registry_ensure
    if [[ ! -s "$INSTANCE_REGISTRY" ]]; then
        echo "No instances configured yet. Add one with: ./${SCRIPT_NAME} --add-instance <name>"
        return 0
    fi
    echo "Registered instances:"
    printf '%-16s %-8s %s\n' "NAME" "PORT" "CREATED"
    awk -F: '{printf "%-16s %-8s %s\n", $1, $2, $3}' "$INSTANCE_REGISTRY"
    echo
    echo "For live status: sudo ${SCRIPTS_DIR}/status-valheim.sh"
}

###############################################################################
# HOST CAPACITY CHECK
#
# There is no way to "elastically allocate more" CPU/RAM on a fixed piece
# of hardware -- unlike a cloud auto-scaling group, this box has whatever
# it physically has. What IS meaningful is telling you clearly, before you
# commit to adding another shard here, whether this host is already
# running hot -- so you can decide to reduce a busy shard's player count,
# move a shard to different hardware, or add capacity, rather than finding
# out the hard way after every shard on the box starts stuttering.
###############################################################################

# get_cpu_utilization_pct: approximates current CPU utilization as a
# percentage, using the 1-minute load average normalized by core count.
# This is a deliberately dependency-free approximation (no extra packages
# needed) -- load average also reflects processes waiting on disk/network
# I/O, not purely CPU-bound work, so treat this as "roughly how busy the
# machine is," not a lab-grade CPU benchmark.
get_cpu_utilization_pct() {
    local load1 cores
    load1="$(awk '{print $1}' /proc/loadavg)"
    cores="$(nproc)"
    awk -v l="$load1" -v c="$cores" 'BEGIN { printf "%.0f", (l/c)*100 }'
}

# get_ram_utilization_pct: current RAM utilization as a percentage
# (used / total, from /proc/meminfo's MemAvailable so page cache that can
# be reclaimed on demand doesn't count as "used").
get_ram_utilization_pct() {
    awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{ if (t>0) printf "%.0f", ((t-a)/t)*100; else print 0 }' /proc/meminfo
}

# check_host_capacity_before_add: samples current CPU/RAM utilization and
# warns clearly (asking for confirmation in interactive mode) if this host
# is already running hot before adding yet another shard to it. Below the
# low threshold, just confirms there's comfortable headroom. This is a
# point-in-time check, not a guarantee -- see host-capacity-monitor.sh for
# ongoing, sustained-trend monitoring.
check_host_capacity_before_add() {
    log_step "Checking current host resource usage"
    local cpu_pct ram_pct
    cpu_pct="$(get_cpu_utilization_pct)"
    ram_pct="$(get_ram_utilization_pct)"
    log_info "Current utilization: CPU ~${cpu_pct}% (1-min load average based), RAM ~${ram_pct}%"

    if (( cpu_pct >= CAPACITY_HIGH_THRESHOLD || ram_pct >= CAPACITY_HIGH_THRESHOLD )); then
        log_warn "This host is already running hot (the healthy range for adding another shard is ${CAPACITY_LOW_THRESHOLD}-${CAPACITY_HIGH_THRESHOLD}% utilization)."
        log_warn "Adding another shard here risks starving every shard already running on this box."
        log_warn "Consider: lowering MAX_PLAYERS on a busy shard, moving a shard to different hardware, or adding this new one elsewhere instead."
        if [[ "$ASSUME_DEFAULTS" -ne 1 ]]; then
            local reply=""
            read -r -p "Add the new shard here anyway? [y/N]: " reply < /dev/tty || true
            reply="${reply:-n}"
            [[ "$reply" =~ ^[Yy] ]] || die "Cancelled. Consider provisioning this shard on different hardware instead."
        else
            log_warn "Continuing anyway (-y was given), but keep an eye on ${SCRIPTS_DIR}/status-valheim.sh."
        fi
    elif (( cpu_pct < CAPACITY_LOW_THRESHOLD && ram_pct < CAPACITY_LOW_THRESHOLD )); then
        log_ok "Plenty of headroom -- this host can comfortably take another shard."
    else
        log_ok "Utilization is within the healthy range for adding another shard."
    fi
}

# write_host_capacity_monitor_script: writes scripts/host-capacity-monitor.sh
# (see the script's own header comment for exactly what it does).
write_host_capacity_monitor_script() {
    cat > "${SCRIPTS_DIR}/host-capacity-monitor.sh" << 'EOF'
#!/usr/bin/env bash
# host-capacity-monitor.sh - samples overall host CPU/RAM utilization and
# logs a warning once it's been sustained above the high-water mark for
# several checks in a row (avoiding false alarms from a brief spike). This
# is visibility/alerting, not an "auto-scale" mechanism -- there is no way
# to conjure more physical CPU/RAM than a box actually has. A sustained
# warning here is your signal to lower a busy shard's MAX_PLAYERS, move a
# shard to different hardware, or add capacity to this one.
set -uo pipefail

LOG_FILE="/srv/valheim/host-capacity.log"
STATE_FILE="/srv/valheim/tmp/host-capacity-high-streak"
HIGH_THRESHOLD=80
LOW_THRESHOLD=40
SUSTAINED_SAMPLES=3

# ts: current timestamp for this script's own log lines.
ts() { date '+%Y-%m-%d %H:%M:%S'; }

load1="$(awk '{print $1}' /proc/loadavg)"
cores="$(nproc)"
cpu_pct=$(awk -v l="$load1" -v c="$cores" 'BEGIN{printf "%.0f", (l/c)*100}')
ram_pct=$(awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{ if (t>0) printf "%.0f", ((t-a)/t)*100; else print 0 }' /proc/meminfo)

mkdir -p "$(dirname "$STATE_FILE")"
echo "$(ts) CPU=${cpu_pct}% RAM=${ram_pct}% (load1=${load1}, cores=${cores})" >> "$LOG_FILE"

streak=0
[[ -f "$STATE_FILE" ]] && streak="$(cat "$STATE_FILE" 2>/dev/null || echo 0)"
[[ "$streak" =~ ^[0-9]+$ ]] || streak=0

if (( cpu_pct >= HIGH_THRESHOLD || ram_pct >= HIGH_THRESHOLD )); then
    streak=$((streak + 1))
    echo "$streak" > "$STATE_FILE"
    if (( streak >= SUSTAINED_SAMPLES )); then
        echo "$(ts) WARNING: sustained high utilization (CPU ${cpu_pct}%, RAM ${ram_pct}%) for ${streak} consecutive checks. Consider lowering a shard's MAX_PLAYERS, moving a shard to different hardware, or adding capacity to this host." >> "$LOG_FILE"
    fi
elif (( cpu_pct < LOW_THRESHOLD && ram_pct < LOW_THRESHOLD )); then
    echo 0 > "$STATE_FILE"
else
    # Within the healthy 40-80% band: don't let a brief high spike's streak
    # linger, but don't reset to 0 either -- just hold steady.
    :
fi
EOF
    chmod 750 "${SCRIPTS_DIR}/host-capacity-monitor.sh"
    chown "$VALHEIM_USER:$VALHEIM_GROUP" "${SCRIPTS_DIR}/host-capacity-monitor.sh"
}

###############################################################################
# ON-DEMAND (SLEEP UNTIL CONNECTED / AUTO-STOP WHEN IDLE)
#
# Same design as the multi-game platform's on-demand system: an on-demand
# instance's REAL systemd unit (valheim@<name>) is normally stopped. In its
# place, a lightweight "sleep listener" (valheim-sleep@<name>) sits on the
# instance's game port using socat -- the moment any packet arrives, it
# triggers the real server to start and exits cleanly (so it never fights
# the real server for the port). Once running, a per-minute cron check
# looks for recent network traffic to that port (via conntrack -- Valheim
# has no RCON or similar interface to query exact player count, unlike
# some of the multi-game platform's games, so this heuristic is the only
# option here), and after IDLE_MINUTES_THRESHOLD consecutive idle minutes,
# stops the real server (which saves the world cleanly via SIGINT, per the
# systemd unit's own KillSignal setting) and re-arms the sleep listener.
###############################################################################

# write_sleep_listener_script: writes scripts/sleep-listener.sh
# <instance-name>, the ExecStart target for valheim-sleep@.service.
write_sleep_listener_script() {
    cat > "${SCRIPTS_DIR}/sleep-listener.sh" << 'EOF'
#!/usr/bin/env bash
# sleep-listener.sh <instance-name> - blocks until the first packet
# arrives on this instance's game port, then triggers wake-instance.sh and
# exits. Run by systemd as valheim-sleep@<name>; Restart=on-failure (not
# "always") means a clean exit after a successful wake does NOT get
# restarted, so it never re-binds the port out from under the now-starting
# real server.
set -uo pipefail
source /srv/valheim/scripts/common.sh
load_instance "${1:?instance name required}"

log_info "[$INSTANCE_NAME] Sleeping -- waiting for a connection on port ${SERVER_PORT}/udp to wake it..."
socat UDP-RECV:"${SERVER_PORT}" SYSTEM:"/srv/valheim/scripts/wake-instance.sh '${INSTANCE_NAME}'"
EOF
    chmod 750 "${SCRIPTS_DIR}/sleep-listener.sh"
    chown "$VALHEIM_USER:$VALHEIM_GROUP" "${SCRIPTS_DIR}/sleep-listener.sh"
}

# write_wake_instance_script: writes scripts/wake-instance.sh <instance>,
# invoked by the sleep listener the moment a connection arrives.
write_wake_instance_script() {
    cat > "${SCRIPTS_DIR}/wake-instance.sh" << 'EOF'
#!/usr/bin/env bash
# wake-instance.sh <instance-name> - starts the real server after the
# sleep listener detects a connection attempt. The player's FIRST attempt
# triggers this; it will very likely need to retry/rejoin once the world
# has actually finished loading (this is a fundamental limit of waking a
# cold server, not something this script can paper over).
set -uo pipefail
source /srv/valheim/scripts/common.sh
load_instance "${1:?instance name required}"

log_info "[$INSTANCE_NAME] Connection detected -- waking the server..."
notify_discord "Instance [$INSTANCE_NAME] is waking up on $(hostname) (someone tried to connect)."
systemctl start "valheim@${INSTANCE_NAME}" >> "${INSTANCE_LOG_DIR}/on-demand.log" 2>&1
EOF
    chmod 750 "${SCRIPTS_DIR}/wake-instance.sh"
    chown "$VALHEIM_USER:$VALHEIM_GROUP" "${SCRIPTS_DIR}/wake-instance.sh"
}

# write_idle_monitor_script: writes scripts/idle-monitor.sh, run every
# minute via cron for every on-demand instance that is currently awake.
# Valheim has no RCON-like interface to query exact player count, so this
# always uses the conntrack-based "any recent traffic" heuristic -- see
# the on-demand section header above for the honest caveat that comes
# with that (a quiet-but-connected player can occasionally be misjudged
# as idle).
write_idle_monitor_script() {
    cat > "${SCRIPTS_DIR}/idle-monitor.sh" << EOF
#!/usr/bin/env bash
set -uo pipefail
source /srv/valheim/scripts/common.sh

IDLE_MINUTES_THRESHOLD=${IDLE_MINUTES_THRESHOLD}

while IFS= read -r name; do
    [[ -n "\$name" ]] || continue
    load_instance "\$name"
    [[ "\${ON_DEMAND:-0}" == "1" ]] || continue
    systemctl is-active --quiet "valheim@\${name}" || continue

    is_idle=0
    if command -v conntrack >/dev/null 2>&1; then
        if ! conntrack -L --dport "\${SERVER_PORT}" 2>/dev/null | grep -q . \\
           && ! conntrack -L --sport "\${SERVER_PORT}" 2>/dev/null | grep -q .; then
            is_idle=1
        fi
    fi
    # conntrack unavailable: can't determine -- assume NOT idle (safer to
    # keep running than to guess-stop an active session).

    state_file="\${INSTANCE_TMP_DIR}/idle-streak"
    if [[ "\$is_idle" == "1" ]]; then
        streak=\$(( \$(cat "\$state_file" 2>/dev/null || echo 0) + 1 ))
    else
        streak=0
    fi
    echo "\$streak" > "\$state_file"

    if (( streak >= IDLE_MINUTES_THRESHOLD )); then
        log_info "[\$name] Idle for \${streak} consecutive minute(s); stopping (Valheim saves on"
        log_info "[\$name] clean shutdown via SIGINT, per the systemd unit's own setting)."
        systemctl stop "valheim@\${name}" >> "\${INSTANCE_LOG_DIR}/on-demand.log" 2>&1
        rm -f "\$state_file"
        systemctl start "valheim-sleep@\${name}" >> "\${INSTANCE_LOG_DIR}/on-demand.log" 2>&1
        notify_discord "Instance [\$name] auto-stopped on \$(hostname) after \${IDLE_MINUTES_THRESHOLD}+ idle minutes."
    fi
done < <(all_instance_names)
EOF
    chmod 750 "${SCRIPTS_DIR}/idle-monitor.sh"
    chown "$VALHEIM_USER:$VALHEIM_GROUP" "${SCRIPTS_DIR}/idle-monitor.sh"
}

# install_systemd_sleep_template: writes the sleep-listener's template
# unit. Restart=on-failure (not "always") is deliberate -- see the
# confidence note in write_sleep_listener_script.
install_systemd_sleep_template() {
    log_step "Installing on-demand sleep-listener systemd template"
    cat > "$SYSTEMD_SLEEP_TEMPLATE_UNIT_PATH" << EOF
[Unit]
Description=Sleep listener (wakes on connect) for Valheim instance %i
After=network-online.target

[Service]
Type=simple
User=${VALHEIM_USER}
Group=${VALHEIM_GROUP}
ExecStart=${SCRIPTS_DIR}/sleep-listener.sh %i
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$SYSTEMD_SLEEP_TEMPLATE_UNIT_PATH"
    systemctl daemon-reload
    log_ok "Sleep-listener template installed at ${SYSTEMD_SLEEP_TEMPLATE_UNIT_PATH}."
}

###############################################################################
# PER-INSTANCE SUMMARY
###############################################################################

# print_instance_summary: the connection/status report for one just-added
# instance. Uses whatever SERVER_NAME/WORLD_NAME/etc. are currently in
# memory (set moments earlier by gather_instance_input/add_instance),
# rather than re-reading from disk.
print_instance_summary() {
    local name="$1"
    local port2 port3
    port2=$((SERVER_PORT+1)); port3=$((SERVER_PORT+2))
    local status_phrase="is up and running"
    [[ "$ON_DEMAND" == "1" ]] && status_phrase="is configured (sleeping until first connection)"
    echo
    echo -e "${C_BOLD}==============================================================="
    echo "  Instance '${name}' ${status_phrase}"
    echo -e "===============================================================${C_RESET}"
    echo
    echo "  Server name:     ${SERVER_NAME}"
    echo "  World name:      ${WORLD_NAME}"
    echo "  Ports:           ${SERVER_PORT}/udp (game query)"
    echo "                   ${port2}/udp     (Steam master)"
    echo "                   ${port3}/udp     (Steam P2P)"
    echo "  LAN IP:          ${LAN_IP}   (for players on this local network)"
    [[ -n "${PUBLIC_IP:-}" ]] && echo "  Public IP:       ${PUBLIC_IP}   (for remote players -- requires port forwarding, see below)"
    echo "  Max players:     ${MAX_PLAYERS} $( [[ "${BEPINEX_ENABLED:-0}" == "1" ]] && echo "(BepInEx + MaxPlayerCount)" || echo "(vanilla)" )"
    echo "  Crossplay:       $( [[ "$CROSSPLAY" == "1" ]] && echo enabled || echo disabled )"
    echo "  Visibility:      PRIVATE -- not listed in any Steam/in-game server browser"
    if [[ "$ON_DEMAND" == "1" ]]; then
        echo "  On-demand:       yes -- sleeping now; wakes on first connection, auto-saves"
        echo "                   and stops after ${IDLE_MINUTES_THRESHOLD} idle minutes (first join attempt after"
        echo "                   waking may need a retry once the world finishes loading)"
    fi
    echo "  Backup schedule: daily at ${BACKUP_TIME}, ${BACKUP_RETENTION_DAYS}-day retention, in ${BACKUP_DIR}"
    echo "  Update schedule: daily check at ${UPDATE_TIME}"
    echo
    echo -e "${C_BOLD}How to connect (share only with players meant for THIS shard):${C_RESET}"
    echo "  In Steam: View -> Game Servers -> Favorites tab -> Add a Server"
    echo "  LAN players enter:    ${LAN_IP}:${SERVER_PORT}"
    [[ -n "${PUBLIC_IP:-}" ]] && echo "  Remote players enter: ${PUBLIC_IP}:${SERVER_PORT}"
    echo "  Password: whatever you set for this instance."
    echo "  Then in Valheim: Join Game -> Favorites."
    if [[ -n "${PUBLIC_IP:-}" ]]; then
        echo
        echo "  For remote players to reach this shard, forward these UDP ports"
        echo "  to ${LAN_IP} on your router:"
        echo "    ${SERVER_PORT}/udp  (game query)"
        echo "    ${port2}/udp        (Steam master)"
        echo "    ${port3}/udp        (Steam P2P)"
    fi
    echo
    echo -e "${C_BOLD}Manage this instance:${C_RESET}"
    echo "  sudo systemctl status  valheim@${name}"
    echo "  sudo systemctl restart valheim@${name}"
    echo "  journalctl -u valheim@${name} -f"
    echo "  sudo ${SCRIPTS_DIR}/status-valheim.sh ${name}"
    echo
    echo "  Add another shard:  ./${SCRIPT_NAME} --add-instance <name>"
    echo "  List all shards:    ./${SCRIPT_NAME} --list-instances"
    echo "  Full install log:   ${LOG_FILE}"
    echo
}

###############################################################################
# BASE (SHARED, ONE-TIME-PER-BOOT) INSTALL
###############################################################################

# ensure_base_install: everything that's shared across every instance --
# packages, the 'valheim' user, the base directory layout, SteamCMD, the
# golden game install, every helper script, the systemd template, base
# firewall rules, fail2ban, logrotate, the journald cap, and cron. Runs
# (safely, idempotently) before every add_instance call, whether this is
# the very first run or the tenth shard being added.
ensure_base_install() {
    check_ubuntu_version
    check_cpu_arch
    check_internet
    check_ram
    check_disk_space
    maybe_create_swap

    enable_required_repos
    apt_update_upgrade
    install_packages

    create_valheim_user
    create_base_directory_layout

    install_steamcmd "$STEAMCMD_DIR" "$BASE_TMP_DIR"
    install_or_update_golden_server

    write_all_helper_scripts
    write_cron_dispatch_scripts

    install_systemd_template
    install_systemd_sleep_template
    configure_firewall_base
    configure_fail2ban
    configure_logrotate
    # Compute the journal cap from instance count and fleet-size constants,
    # then call common.sh's configure_journald_limit(journald_conf, max_use)
    local instance_count target_mb
    instance_count="$(registry_list_names 2>/dev/null | grep -c . || true)"
    [[ "$instance_count" =~ ^[0-9]+$ ]] || instance_count=0
    target_mb=$(( JOURNALD_MAX_USE_FLOOR_MB + instance_count * JOURNALD_MAX_USE_PER_INSTANCE_MB ))
    (( target_mb > JOURNALD_MAX_USE_CEILING_MB )) && target_mb=$JOURNALD_MAX_USE_CEILING_MB
    configure_journald_limit "$JOURNALD_CONF" "${target_mb}M"
    schedule_cron_jobs

    gather_network_info
}

###############################################################################
# FULL UNINSTALL (removes every instance, all shared infrastructure)
###############################################################################

# uninstall_everything: stops/disables every registered instance, removes
# the systemd template, cron, logrotate, and every instance's firewall
# rules, then asks (once, separately) whether to delete all game data.
# fail2ban is deliberately left in place -- removing Valheim shouldn't
# weaken SSH protection.
uninstall_everything() {
    require_root
    init_logging "$LOG_FILE" "Valheim installer v${SCRIPT_VERSION}"
    log_step "Uninstalling everything"

    registry_ensure
    while IFS=: read -r name port _; do
        [[ -n "$name" ]] || continue
        log_info "Stopping and disabling instance '${name}'..."
        systemctl stop "valheim@${name}" 2>>"$LOG_FILE" || true
        systemctl disable "valheim@${name}" 2>>"$LOG_FILE" || true
        systemctl stop "valheim-sleep@${name}" 2>>"$LOG_FILE" || true
        systemctl disable "valheim-sleep@${name}" 2>>"$LOG_FILE" || true
        if [[ -n "$port" ]]; then
            remove_firewall_for_instance "$name" "$port"
        fi
    done < "$INSTANCE_REGISTRY"

    rm -f "$SYSTEMD_TEMPLATE_UNIT_PATH" "$SYSTEMD_SLEEP_TEMPLATE_UNIT_PATH"
    systemctl daemon-reload
    rm -f "$CRON_BACKUP_FILE" "$CRON_UPDATE_FILE" "$CRON_HEALTHCHECK_FILE" "$CRON_CAPACITY_FILE" "$CRON_IDLE_FILE"
    rm -f "$LOGROTATE_CONF"
    log_ok "Services, schedules, and firewall rules removed for every instance."
    log_info "Note: fail2ban and its SSH jail (${FAIL2BAN_JAIL_LOCAL}) are left in place -- uninstalling Valheim shouldn't weaken your SSH protection. Remove it yourself with 'sudo apt remove fail2ban' if you no longer want it."

    local confirm="" remove_user=""
    read -r -p "Also DELETE ALL Valheim data (every instance's worlds/backups/logs, plus the shared game install) under ${VALHEIM_BASE}? Type 'yes' to confirm: " confirm < /dev/tty || true
    if [[ "$confirm" == "yes" ]]; then
        rm -rf "$VALHEIM_BASE"
        log_ok "Removed ${VALHEIM_BASE}."
        read -r -p "Also remove the '${VALHEIM_USER}' system user? [y/N]: " remove_user < /dev/tty || true
        if [[ "${remove_user,,}" =~ ^y ]]; then
            userdel "$VALHEIM_USER" 2>>"$LOG_FILE" || true
            groupdel "$VALHEIM_GROUP" 2>>"$LOG_FILE" || true
            log_ok "Removed user/group '${VALHEIM_USER}'."
        fi
    else
        log_ok "All instance data preserved under ${VALHEIM_BASE}."
    fi
    log_ok "Uninstall complete."
    exit 0
}

###############################################################################
# CLI PARSING + MAIN
###############################################################################

print_usage() {
    cat << EOF
Usage: ./${SCRIPT_NAME} [OPTIONS]
(sudo is applied automatically if needed -- you don't have to type it yourself)

First run (installs shared prerequisites + your first instance):
  ./${SCRIPT_NAME}

Not sure if this server is ready? Check first, without changing anything:
  ./${SCRIPT_NAME} --check

Options:
  --check                    Check this server WITHOUT installing or changing
                              anything (OS, architecture, internet, RAM,
                              disk). Safe to run as many times as you like,
                              doesn't need sudo.
  --add-instance <name>     Add another shard (prompts for its settings).
  --remove-instance <name>  Stop and remove one shard (asks before deleting data).
  --list-instances          List every configured shard.
  --status [name]           Show live status for one or all instances.
  --uninstall               Remove everything (asks before deleting data).
  --version                 Show the installer version and exit.
  -y, --yes                 Non-interactive: accept defaults / generate a
                             random password instead of prompting.
  -h, --help                Show this help message and exit.
EOF
}

# run_environment_check: the --check dry-run mode -- confirms this
# machine meets Valheim's basic requirements WITHOUT installing or
# changing anything at all. Deliberately doesn't require root, since it's
# entirely read-only, and is meant to be safe for anyone to run first,
# before committing to a real install.
run_environment_check() {
    print_banner
    echo -e "${C_BOLD}Check-only mode: nothing will be installed or changed.${C_RESET}"
    echo

    local all_ok=1

    log_step "Checking operating system"
    if detect_os_release && [[ "$OS_ID" == "ubuntu" ]]; then
        log_ok "Ubuntu ${OS_VERSION_ID} detected."
        [[ "$OS_IS_LTS" -eq 1 ]] || log_warn "Not an LTS release -- should still work, but LTS is recommended."
    else
        log_err "This does not look like Ubuntu (detected: ${OS_ID:-unknown}). This script requires Ubuntu."
        all_ok=0
    fi

    log_step "Checking CPU architecture"
    local arch; arch="$(uname -m)"
    if [[ "$arch" == "x86_64" ]]; then
        log_ok "Architecture: ${arch}"
    else
        log_err "Architecture is ${arch}; Valheim's dedicated server requires x86_64 (64-bit Intel/AMD)."
        all_ok=0
    fi

    log_step "Checking internet connectivity"
    if curl -fsS --max-time 8 -o /dev/null "https://archive.ubuntu.com" 2>/dev/null \
       || curl -fsS --max-time 8 -o /dev/null "https://steamcdn-a.akamaihd.net" 2>/dev/null; then
        log_ok "Internet connectivity confirmed."
    else
        log_err "No internet connectivity detected -- downloads would fail."
        all_ok=0
    fi

    log_step "Checking RAM"
    local ram_kb ram_mb
    ram_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo)"
    ram_mb=$(( ram_kb / 1024 ))
    if (( ram_mb < MIN_RAM_MB_HARD )); then
        log_err "${ram_mb} MB RAM detected; at least ${MIN_RAM_MB_HARD} MB is required."
        all_ok=0
    else
        log_ok "${ram_mb} MB RAM detected."
        if (( ram_mb < MIN_RAM_MB_RECOMMENDED )); then
            log_warn "Valheim's own guidance is roughly 2-4GB per shard depending on player count"
            log_warn "and mod usage -- this will likely work but is on the lighter side."
        fi
    fi

    log_step "Checking disk space"
    local target avail_mb
    target="/srv"; [[ -d "$target" ]] || target="/"
    avail_mb="$(df --output=avail -m "$target" 2>/dev/null | tail -n1 | tr -d '[:space:]')"
    if [[ -z "$avail_mb" ]] || (( avail_mb < MIN_DISK_MB )); then
        log_err "Only ${avail_mb:-an unknown amount of} MB free on ${target}; at least ${MIN_DISK_MB} MB is required."
        all_ok=0
    else
        log_ok "${avail_mb} MB free on ${target}."
    fi

    echo
    if [[ "$all_ok" -eq 1 ]]; then
        echo -e "${C_GREEN}${C_BOLD}This server looks ready.${C_RESET} Nothing was changed by this check. When ready:"
        echo "  ./${SCRIPT_NAME} --add-instance <name>"
    else
        echo -e "${C_RED}${C_BOLD}One or more checks failed${C_RESET} -- see the [FAIL] lines above. Fix those before installing for real."
    fi
    exit $(( 1 - all_ok ))
}

ADD_INSTANCE_NAME=""
REMOVE_INSTANCE_NAME=""
LIST_INSTANCES_MODE=0
STATUS_MODE=0
STATUS_INSTANCE_NAME=""
UNINSTALL_MODE=0
CHECK_MODE=0

# parse_args: interprets every CLI option above.
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes) ASSUME_DEFAULTS=1 ;;
            --add-instance)
                # --add-instance <name> is documented as required to add a
                # shard, but --game <game> alone (no --add-instance at all)
                # is also accepted and behaves identically -- the flag here
                # only exists to optionally capture the instance NAME that
                # follows it, not to gate whether an instance gets added.
                if [[ -n "${2:-}" && "${2:0:1}" != "-" ]]; then
                    ADD_INSTANCE_NAME="$2"
                    shift
                fi
                ;;
            --remove-instance)
                if [[ -z "${2:-}" || "${2:0:1}" == "-" ]]; then
                    echo "Error: --remove-instance requires a name, e.g. --remove-instance shard2" >&2
                    exit 1
                fi
                REMOVE_INSTANCE_NAME="$2"
                shift
                ;;
            --list-instances) LIST_INSTANCES_MODE=1 ;;
            --status)
                STATUS_MODE=1
                # --status optionally takes an instance name as the next argument
                if [[ -n "${2:-}" && "${2:0:1}" != "-" ]]; then
                    STATUS_INSTANCE_NAME="$2"
                    shift
                fi
                ;;
            --uninstall) UNINSTALL_MODE=1 ;;
            --check) CHECK_MODE=1 ;;
            --version) echo "install-valheim-server.sh v${SCRIPT_VERSION}"; exit 0 ;;
            -h|--help) print_usage; exit 0 ;;
            *) echo "Unknown option: $1" >&2; print_usage; exit 1 ;;
        esac
        shift
    done
}

# main: orchestrates everything -- uninstall / list / remove / add-instance
# / first-run, in that order of precedence.
main() {
    ORIGINAL_ARGS_STRING="$*"
    parse_args "$@"

    if [[ "$CHECK_MODE" -eq 1 ]]; then
        run_environment_check
        return
    fi

    require_root "$@"

    if [[ "$UNINSTALL_MODE" -eq 1 ]]; then
        uninstall_everything
        return
    fi

    if [[ "$LIST_INSTANCES_MODE" -eq 1 ]]; then
        list_instances
        return
    fi

    if [[ "$STATUS_MODE" -eq 1 ]]; then
        local status_script="${SCRIPTS_DIR}/status-valheim.sh"
        if [[ -x "$status_script" ]]; then
            # Pass the instance name if one was given, otherwise show all
            "$status_script" ${STATUS_INSTANCE_NAME:+"$STATUS_INSTANCE_NAME"}
        else
            die "Status script not found at ${status_script}. Run the installer first."
        fi
        return
    fi

    if [[ -n "$REMOVE_INSTANCE_NAME" ]]; then
        init_logging "$LOG_FILE" "Valheim installer v${SCRIPT_VERSION}"
        remove_instance "$REMOVE_INSTANCE_NAME"
        return
    fi

    print_banner
    init_logging "$LOG_FILE" "Valheim installer v${SCRIPT_VERSION}"
    ensure_base_install
    add_instance "$ADD_INSTANCE_NAME"
    log_line "Valheim installer finished successfully (instance: ${INSTANCE_NAME})."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

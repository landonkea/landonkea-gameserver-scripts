#!/usr/bin/env bash
###############################################################################
# install-game-server.sh  (v1.0.0 -- multi-game dedicated server platform)
#
# Deploys and manages any number of independent dedicated game server
# instances ("shards") on a single Ubuntu Server LTS host, across multiple
# different games. Each game is a small, self-contained "profile" plugging
# into a shared core (SteamCMD, systemd templating, backups, firewall,
# fail2ban, log rotation, host-capacity monitoring, on-demand sleep/wake,
# sudo auto-elevation) -- adding support for a new game means writing one
# profile file (see PROFILE-AUTHORING.md), not touching this script.
#
# Supported games out of the box (see profiles/*.profile.sh):
#   terraria, projectzomboid, rust, minecraft, mindustry, teamfortress2,
#   garrysmod, left4dead2, factorio, corekeeper, satisfactory,
#   arksurvivalevolved, conanexiles, sevendaystodie, palworld, unturned,
#   openttd, enshrouded, spaceengineers, astroneer, arksurvivalascended
# (the last three, plus enshrouded, are "Wine-tier": Windows-only server
# binaries run through Wine, since no native Linux version exists.)
#
# USAGE:
#   First run (installs shared prerequisites + your first instance):
#     chmod +x install-game-server.sh
#     ./install-game-server.sh --game <game> [--add-instance <name>]
#
#   Add another shard later (same or different game):
#     ./install-game-server.sh --game <game> --add-instance <name>
#
#   List / remove / uninstall:
#     ./install-game-server.sh --list-instances
#     ./install-game-server.sh --remove-instance <name>
#     ./install-game-server.sh --uninstall
#
#   List available game profiles:
#     ./install-game-server.sh --list-games
#
# You do not need to type "sudo" yourself -- the script re-launches itself
# with sudo automatically if needed.
#
# -----------------------------------------------------------------------
# NEW TO READING CODE? Start with HOW-TO-READ-THIS-CODE.md in this same
# repository -- it explains, in plain English with no assumed experience,
# every recurring pattern used throughout this file (variables, if/then,
# functions, loops, and so on). Come back here once that makes sense.
# -----------------------------------------------------------------------
#
# HOW THIS FILE ITSELF IS ORGANIZED (top to bottom):
#   1. Constants -- fixed settings used throughout (file paths, port
#      ranges, thresholds). Search for "GLOBAL CONSTANTS" below.
#   2. Logging -- the log_info/log_ok/log_warn/log_err functions every
#      other function uses to report what it's doing.
#   3. Small reusable helpers -- little one-purpose functions (checking if
#      a command exists, re-launching as root if needed, etc).
#   4. Pre-flight checks -- confirming the computer meets the basic
#      requirements (Ubuntu, 64-bit, internet, enough RAM/disk) before
#      attempting anything real.
#   5. The instance registry -- a simple on-disk record of which game
#      server instances exist, on which ports, tracked so a new instance
#      never accidentally reuses a port an existing one is already using.
#   6. Game profile loading -- the mechanism explained in detail in
#      PROFILE-AUTHORING.md; search for "GAME PROFILE LOADING" below.
#   7. Package installation, the dedicated system user, directory layout,
#      SteamCMD -- the shared groundwork every instance relies on.
#   8. Helper script generation -- this script WRITES several other,
#      smaller scripts to disk (backup, restore, status, etc.) -- search
#      for "HELPER SCRIPT GENERATION" below.
#   9. systemd, firewall, fail2ban, log rotation, cron scheduling -- the
#      pieces that make instances start automatically, stay secure, and
#      get backed up/updated/health-checked on a schedule without a human
#      needing to remember to do any of it.
#  10. The on-demand (sleep-until-connected) system -- search for
#      "ON-DEMAND" below.
#  11. Instance orchestration (add/remove/list) -- the functions that tie
#      everything above together into what actually happens when someone
#      runs "--add-instance".
#  12. Command-line parsing and "main" -- the very last section, and the
#      genuine starting point of the whole script: this is the first code
#      that actually runs when this file is executed, at the very bottom.
###############################################################################

# BASH_VERSION is a variable bash itself always sets, so if it's empty/unset
# this file got launched with a DIFFERENT interpreter (e.g. `sh
# install-game-server.sh`, where `sh` is often dash, not bash). The rest of
# this script uses bash-only syntax ([[ ]], arrays, etc.), which dash cannot
# run, so we fail immediately with a clear message instead of a confusing
# syntax error deep inside the file. "${BASH_VERSION:-}" is parameter
# expansion with a default: "use $BASH_VERSION, or an empty string if it's
# unset" -- avoiding an "unbound variable" error under `set -u` (enabled
# below) if run under a shell that doesn't define it at all.
if [ -z "${BASH_VERSION:-}" ]; then
    echo "ERROR: This script must be run with bash, e.g.: sudo bash install-game-server.sh" >&2
    exit 1
fi

# set -Eeuo pipefail is the standard "strict mode" combo for bash scripts:
#   -E  ERR trap (see `trap ... ERR` below) is inherited into functions and
#       subshells too, not just the top-level script -- without this, a
#       failure inside a function wouldn't trigger our on_error handler.
#   -e  ("errexit") abort the whole script the instant any command exits
#       non-zero, instead of ignoring the failure and barreling ahead.
#   -u  ("nounset") treat referencing an undefined variable as an error
#       instead of silently substituting an empty string -- catches typos'd
#       variable names immediately instead of them causing a mysterious bug
#       later.
#   -o pipefail  makes a pipeline (cmd1 | cmd2) fail if ANY command in it
#       fails, not just the last one -- normally only the last command's
#       exit code counts, which can hide a real failure earlier in the pipe.
set -Eeuo pipefail
# IFS ("Internal Field Separator") controls which characters bash treats as
# word boundaries when it splits unquoted text -- e.g. inside a `for x in
# $var` loop, or a `read` without a delimiter. The default IFS is space,
# tab, and newline, which means an instance name or file path containing a
# space could silently become TWO words. Setting IFS to just newline+tab
# here removes the space from that list, so plain spaces inside a quoted
# variable never accidentally get split into separate "words" -- a
# defensive hardening measure common in strict-mode bash scripts. Individual
# loops below that specifically WANT space-splitting (or colon-splitting,
# etc.) set IFS again just for that one line.
IFS=$'\n\t'

# --- Load shared library with common functions ---
# BASE_DIR is this script's own directory, computed independent of the
# caller's current working directory: `dirname "${BASH_SOURCE[0]}"` gets the
# folder this file lives in, and `cd ... && pwd` resolves that to a full
# absolute path (turning something like "./multi-game-platform" into
# "/home/user/multi-game-platform"), which matters because we're about to
# `cd`-independently source another file relative to it, and later re-exec
# ourselves under sudo from a possibly different working directory.
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BASE_DIR # exported so common.sh (and anything it launches) can see it too
# "source" loads lib/common.sh's variables and functions directly into THIS
# script's own memory (see load_game_profile below for a fuller explanation
# of what sourcing means) -- that's how log_info, die, require_root,
# validate_port, and the rest of the shared library become usable here.
source "${BASE_DIR}/../lib/common.sh" "${BASE_DIR}"

###############################################################################
# GLOBAL CONSTANTS
# `readonly` makes each of these a constant: any later attempt to reassign
# one is a hard error under `set -e`. That's deliberate here -- these are
# fixed facts about this platform's on-disk layout and behavior that no
# code path should ever be able to accidentally change mid-run.
###############################################################################
readonly SCRIPT_VERSION="1.0.0"
# basename strips the directory part off a path, leaving just the filename
# (e.g. "/opt/foo/install-game-server.sh" -> "install-game-server.sh").
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_FILE="/var/log/gameserver-install.log"

readonly GS_USER="gameserver"   # the unprivileged Linux user every game server process runs as
readonly GS_GROUP="gameserver"  # its matching group
readonly GS_BASE="/srv/gameservers" # the root directory everything this platform manages lives under

readonly STEAMCMD_DIR="${GS_BASE}/steamcmd"
readonly GOLDEN_DIR="${GS_BASE}/golden"           # one shared, per-GAME SteamCMD-managed install
readonly SCRIPTS_DIR="${GS_BASE}/scripts"
readonly PROFILES_DIR="${SCRIPTS_DIR}/profiles"
readonly INSTANCES_DIR="${GS_BASE}/instances"
readonly INSTANCE_REGISTRY="${GS_BASE}/instances.registry"
readonly BASE_TMP_DIR="${GS_BASE}/tmp"

# STEAMCMD_URL is already declared readonly by lib/common.sh (sourced
# above) -- redeclaring it here would abort the script with "readonly
# variable" under set -e.

readonly SYSTEMD_TEMPLATE_UNIT_PATH="/etc/systemd/system/gameserver@.service"
readonly LOGROTATE_CONF="/etc/logrotate.d/gameserver"
readonly CRON_BACKUP_FILE="/etc/cron.d/gameserver-backup"
readonly CRON_UPDATE_FILE="/etc/cron.d/gameserver-update"
readonly CRON_HEALTHCHECK_FILE="/etc/cron.d/gameserver-healthcheck"
readonly CRON_CAPACITY_FILE="/etc/cron.d/gameserver-capacity"
readonly JOURNALD_CONF="/etc/systemd/journald.conf"
readonly JOURNALD_MAX_USE_FLOOR_MB=500
readonly JOURNALD_MAX_USE_PER_INSTANCE_MB=150
readonly JOURNALD_MAX_USE_CEILING_MB=8192
readonly FAIL2BAN_JAIL_LOCAL="/etc/fail2ban/jail.local"

readonly MIN_DISK_MB=10240
readonly MIN_RAM_MB_HARD=1800
readonly MIN_RAM_MB_RECOMMENDED=4096
readonly SWAP_FILE_PATH="/swapfile"
readonly SWAP_SIZE_MB=4096
readonly APT_LOCK_WAIT_SECONDS=180

readonly PORT_RANGE_START=25000
readonly PORT_RANGE_STEP=10
readonly CAPACITY_LOW_THRESHOLD=40
readonly CAPACITY_HIGH_THRESHOLD=80

readonly SYSTEMD_SLEEP_TEMPLATE_UNIT_PATH="/etc/systemd/system/gameserver-sleep@.service"
readonly CRON_IDLE_FILE="/etc/cron.d/gameserver-idle"
readonly IDLE_MINUTES_THRESHOLD=5   # auto-save + auto-stop after this many consecutive idle minutes

# These three are plain (non-readonly) globals because, unlike the constants
# above, their values legitimately change while the script runs -- CLI flag
# parsing (parse_args, near the bottom of this file) flips ASSUME_DEFAULTS
# and DRY_RUN from 0 to 1, and main() fills in ORIGINAL_ARGS_STRING.
ASSUME_DEFAULTS=0 # when set to 1 via -y/--yes, all prompts use defaults automatically
DRY_RUN=0         # when set to 1 via --dry-run, add_instance/remove_instance/uninstall_everything show what would happen without doing it
ORIGINAL_ARGS_STRING="" # stores the raw CLI arguments so the error handler can suggest re-running

###############################################################################
# Color/log setup is provided by the shared library (common.sh) sourced above.
###############################################################################

###############################################################################
# ERROR HANDLING / TRAPS
#
# A "trap" tells bash "run this command automatically when X happens,"
# instead of me having to check for X after every single command. Two are
# registered below: one for ERR (any command failing, thanks to -e above)
# and one for INT/TERM (Ctrl+C, or another process asking us to stop).
###############################################################################

# These two track progress through add_instance, purely so on_error
# (below) can safely clean up a half-created instance directory if
# something fails partway through setting one up -- WITHOUT ever risking
# deleting an instance's real data once it's actually been registered.
PARTIAL_INSTANCE_NAME=""
PARTIAL_INSTANCE_REGISTERED=0

# on_error: the ERR trap handler -- reports where the script failed and
# reassures the admin that re-running is safe once the issue is fixed. If
# a new instance's directory was created but the instance was never
# successfully registered (meaning nothing else could possibly be
# depending on it yet), that half-created directory is removed so a retry
# starts clean rather than potentially colliding with leftover partial
# files from the failed attempt.
on_error() {
    # $1/$2/$3 here are NOT this script's own CLI arguments -- they're
    # whatever the trap command below passed in when it invoked this
    # function ("$LINENO" "$BASH_COMMAND" "$?"), i.e. the line number, the
    # exact command text, and the exit code of the command that just failed.
    local line="$1" cmd="$2" rc="$3"
    log_err "Unexpected failure at line ${line} (exit code ${rc}): ${cmd}"

    if [[ -n "$PARTIAL_INSTANCE_NAME" && "$PARTIAL_INSTANCE_REGISTERED" -eq 0 ]]; then
        local partial_dir
        partial_dir="$(instance_dir "$PARTIAL_INSTANCE_NAME")"
        if [[ -d "$partial_dir" ]]; then
            log_warn "Cleaning up the half-created instance directory (${partial_dir}) from this failed attempt..."
            rm -rf "$partial_dir"
        fi
    fi

    log_err "Nothing further will be changed. Fix the underlying problem, then simply re-run:"
    log_err "  ./${SCRIPT_NAME} ${ORIGINAL_ARGS_STRING}"
    log_err "Full log: ${LOG_FILE}"
    exit "$rc"
}
# `trap 'COMMAND' SIGNAL...` registers COMMAND to run when SIGNAL fires. The
# command string is single-quoted so $LINENO/$BASH_COMMAND/$? are expanded
# freshly at the MOMENT the trap fires (not once, right now, while they're
# still empty) -- $LINENO is the line that failed, $BASH_COMMAND is the
# literal text of the command that was running, and $? is its exit code.
# ERR fires on any command failing (see `set -e` above); INT is Ctrl+C;
# TERM is a normal "please stop" request from another process (e.g. systemd
# or `kill`) -- both get a friendly message and a distinct exit code (130,
# the conventional "killed by signal 2 / SIGINT" code) instead of an
# on_error-style stack trace, since a user-requested interrupt isn't a bug.
trap 'on_error "$LINENO" "$BASH_COMMAND" "$?"' ERR
trap 'echo; log_warn "Interrupted by user (Ctrl+C)."; exit 130' INT TERM

###############################################################################
# Small general-purpose helpers (has_forbidden_chars, command_exists,
# curl_with_retry, require_root) are provided by common.sh.
###############################################################################

# print_banner: title banner printed at the start of a run.
print_banner() {
    echo -e "${C_BOLD}"
    echo "==============================================================="
    echo "  Multi-Game Dedicated Server Platform  (v${SCRIPT_VERSION})"
    echo "  Ubuntu Server LTS"
    echo "==============================================================="
    echo -e "${C_RESET}"
}

# init_logging is provided by common.sh; called with LOG_FILE and SCRIPT_NAME
# at each call site below.

# wait_for_apt_lock is provided by common.sh.

###############################################################################
# Pre-flight checks (detect_os_release, check_ubuntu_version, check_cpu_arch,
# check_internet, check_ram, check_disk_space) are provided by common.sh.
###############################################################################

###############################################################################
# INSTANCE REGISTRY / PORT ALLOCATION
#
# /srv/gameservers/instances.registry is "name:game:port:created_at" -- used
# to hand out non-conflicting port blocks and to list what exists across
# every game. Each instance's own config.env remains the source of truth
# for everything else.
###############################################################################

# registry_base_exists: true if the base install has happened at all.
# The function body is a single [[ ]] test with no explicit `return` -- in
# bash, a function's exit status defaults to the exit status of the LAST
# command it ran, so this "returns" 0 (true, meaning "the directory exists")
# or 1 (false) exactly like an explicit `return` would, just more tersely.
registry_base_exists() { [[ -d "$GS_BASE" ]]; }

# registry_ensure: creates an empty registry file if one doesn't exist yet.
# A no-op if the base install hasn't happened at all yet.
registry_ensure() {
    registry_base_exists || return 0
    # `[[ cond ]] || { multiple; commands; }` runs the braced block only if
    # the test is FALSE (file doesn't exist yet) -- the braces group two
    # commands into one so `||` treats them as a single right-hand side.
    [[ -f "$INSTANCE_REGISTRY" ]] || { touch "$INSTANCE_REGISTRY"; chmod 644 "$INSTANCE_REGISTRY"; }
}

# registry_next_port: returns the next free port block start. Scans every
# existing instance's port column, takes the highest one, and offers the
# next block after it -- so a newly added instance's ports never collide
# with an already-registered instance's ports.
registry_next_port() {
    registry_ensure
    local max_used candidate="$PORT_RANGE_START"
    if [[ -f "$INSTANCE_REGISTRY" ]]; then
        # awk -F: splits each registry line on ':' and prints field 3 (the
        # port); sort -n sorts those numerically; tail -1 takes the highest.
        max_used="$(awk -F: '{print $3}' "$INSTANCE_REGISTRY" 2>/dev/null | sort -n | tail -1)"
        if [[ -n "$max_used" ]]; then
            candidate=$(( max_used + PORT_RANGE_STEP ))
        fi
    fi
    echo "$candidate" # the caller captures this via command substitution: $(registry_next_port)
}

# registry_add: appends "name:game:port:timestamp". Uses a colon-free
# timestamp format (unlike ts()) since the registry itself uses ':' as its
# field separator.
registry_add() {
    local name="$1" game="$2" port="$3"
    registry_ensure
    echo "${name}:${game}:${port}:$(date '+%Y-%m-%d_%H-%M-%S')" >> "$INSTANCE_REGISTRY"
}

# registry_remove: deletes the line for the given instance name, if present.
# Every caller of this function validates `name` against
# validate_instance_name (letters/digits/'_'/'-' only) BEFORE calling it --
# that matters here because $name is interpolated directly into a sed
# regular expression address (/^${name}:/d). An unvalidated name containing
# regex metacharacters (like ".*") could match far more lines than intended
# and delete the wrong entries, or all of them.
registry_remove() {
    local name="$1"
    registry_ensure
    if [[ -f "$INSTANCE_REGISTRY" ]]; then
        # sed -i edits the file in place; "/^${name}:/d" means "delete any
        # line that starts with this name followed by a colon."
        sed -i "/^${name}:/d" "$INSTANCE_REGISTRY"
    fi
}

# registry_has: true if an instance with this name is already registered.
# Same regex-injection caveat as registry_remove above applies here.
registry_has() {
    local name="$1"
    registry_ensure
    [[ -f "$INSTANCE_REGISTRY" ]] || return 1
    grep -q "^${name}:" "$INSTANCE_REGISTRY" 2>/dev/null
}

# registry_port_for: prints the registered port for an instance name.
registry_port_for() {
    local name="$1"
    registry_ensure
    [[ -f "$INSTANCE_REGISTRY" ]] || return 0
    # awk -v n="$name" passes the shell variable into awk safely (as data,
    # not as part of awk's own program text), then '$1==n{print $3}' prints
    # field 3 (the port) only for the line whose field 1 (name) matches --
    # an exact string comparison, not a regex, so this one has no injection
    # risk even with an unvalidated name.
    awk -F: -v n="$name" '$1==n{print $3}' "$INSTANCE_REGISTRY" 2>/dev/null | head -n1
}

# registry_game_for: prints the registered game profile id for an instance name.
registry_game_for() {
    local name="$1"
    registry_ensure
    [[ -f "$INSTANCE_REGISTRY" ]] || return 0
    awk -F: -v n="$name" '$1==n{print $2}' "$INSTANCE_REGISTRY" 2>/dev/null | head -n1
}

# registry_list_names: prints every registered instance name, one per line.
registry_list_names() {
    registry_ensure
    [[ -f "$INSTANCE_REGISTRY" ]] || return 0
    awk -F: '{print $1}' "$INSTANCE_REGISTRY" 2>/dev/null
}

###############################################################################
# INSTANCE PATH HELPERS
###############################################################################
# instance_dir: prints the root directory for instance $1.
instance_dir()          { echo "${INSTANCES_DIR}/$1"; }
# instance_server_dir: prints instance $1's own copy of the game server files.
instance_server_dir()   { echo "${INSTANCES_DIR}/$1/server"; }
# instance_data_dir: prints instance $1's save/world data directory.
instance_data_dir()     { echo "${INSTANCES_DIR}/$1/data"; }
# instance_logs_dir: prints instance $1's log directory.
instance_logs_dir()     { echo "${INSTANCES_DIR}/$1/logs"; }
# instance_tmp_dir: prints instance $1's scratch/tmp directory.
instance_tmp_dir()      { echo "${INSTANCES_DIR}/$1/tmp"; }
# instance_default_backup_dir: prints instance $1's default backup location.
instance_default_backup_dir() { echo "${INSTANCES_DIR}/$1/backups"; }
# instance_config_file: prints the path to instance $1's config.env.
instance_config_file()  { echo "${INSTANCES_DIR}/$1/config.env"; }
# golden_dir_for_game: prints the shared golden install directory for a game id.
golden_dir_for_game()   { echo "${GOLDEN_DIR}/$1"; }

###############################################################################
# Optional swap file creation is provided by common.sh (maybe_create_swap).
###############################################################################

###############################################################################
# Generic validators (validate_instance_name, validate_generic_safe_string,
# validate_generic_password, validate_yesno, normalize_yesno_bit,
# validate_port, validate_retention_days, validate_time_hhmm) and the prompt
# engine (prompt_and_validate) are provided by common.sh.
###############################################################################

###############################################################################
# MG-SPECIFIC VALIDATORS
###############################################################################

# validate_backup_dir: absolute path, no shell metacharacters, must not sit
# inside this instance's own data/server directories.
validate_backup_dir() {
    local v="$1"
    if has_forbidden_chars "$v"; then
        echo "Path may not contain: \" ' \` \\ \$"
        return 1
    fi
    # "$v" != /* means "does NOT start with a forward slash" -- an absolute
    # path always starts with /, so anything else (like "backups" or
    # "../backups") is a relative path we deliberately reject: a relative
    # backup destination would resolve differently depending on whatever
    # directory a cron job or systemd unit happens to be running from.
    if [[ "$v" != /* ]]; then
        echo "Please provide an absolute path (starting with /)."
        return 1
    fi
    # Reject the exact data directory, OR anything nested inside it
    # ("$CURRENT_INSTANCE_DATA_DIR"/* matches any path with that prefix
    # followed by a slash and more path) -- otherwise the nightly backup
    # job would be zipping up its own previous backups forever, or restoring
    # from a backup could wipe the very thing it's trying to restore.
    if [[ -n "${CURRENT_INSTANCE_DATA_DIR:-}" ]] && { [[ "$v" == "$CURRENT_INSTANCE_DATA_DIR" ]] || [[ "$v" == "$CURRENT_INSTANCE_DATA_DIR"/* ]]; }; then
        echo "Backup directory must not be inside this instance's data directory."
        return 1
    fi
    return 0
}

# validate_discord_webhook_url: this field is entirely optional -- an empty
# value is always valid and simply leaves Discord notifications disabled
# for this instance (see notify_discord() below). If the user DOES supply
# a value, it must look like a real Discord webhook URL so a typo doesn't
# silently fail every notification later; Discord webhook URLs always
# start with this exact prefix.
validate_discord_webhook_url() {
    local v="$1"
    [[ -z "$v" ]] && return 0 # blank -- notifications stay disabled; nothing to validate
    if has_forbidden_chars "$v"; then
        echo "May not contain: \" ' \` \\ \$"
        return 1
    fi
    if [[ "$v" != https://discord.com/api/webhooks/* ]]; then
        echo "Must be a Discord webhook URL (https://discord.com/api/webhooks/...), or blank to disable notifications."
        return 1
    fi
    return 0
}

###############################################################################
# GENERIC PROMPT ENGINE
###############################################################################
CURRENT_INSTANCE_DATA_DIR=""

###############################################################################
# GAME PROFILE LOADING
#
# Each profile is a small file at scripts/profiles/<game_id>.profile.sh
# that, when sourced, defines PROFILE_* variables and profile_* functions.
# See PROFILE-AUTHORING.md for the full contract new profiles must follow.
###############################################################################

# list_available_games: prints every installed game profile's id (one per line).
list_available_games() {
    local f
    # "${PROFILES_DIR}"/*.profile.sh is a glob (wildcard pattern) that bash
    # expands into a list of matching file paths BEFORE the loop even
    # starts. If NO files match, bash leaves the literal, unexpanded pattern
    # string as the only "match" (this is bash's default glob behavior) --
    # that's exactly why the next line checks [[ -e "$f" ]] (does this path
    # really exist?) and skips it with `continue` if not, so an empty
    # PROFILES_DIR produces no output instead of one bogus line.
    for f in "${PROFILES_DIR}"/*.profile.sh; do
        [[ -e "$f" ]] || continue
        # basename "$f" .profile.sh strips both the directory AND the
        # ".profile.sh" suffix, turning ".../terraria.profile.sh" into just
        # "terraria" -- the game's short id.
        basename "$f" .profile.sh
    done
}

# load_game_profile: this is the heart of the whole "one small file per
# game" design. Given a game's short id (like "terraria"), this finds that
# game's profile file, loads it, and then carefully checks it actually
# defines everything the rest of this script will assume it defines --
# catching a broken or incomplete profile HERE, with one clear error
# message, rather than letting it fail confusingly at some random later
# point while an instance is being set up.
load_game_profile() {
    local game_id="$1"
    local profile_file="${PROFILES_DIR}/${game_id}.profile.sh"
    if [[ ! -f "$profile_file" ]]; then
        # Not installed under PROFILES_DIR yet (e.g. --dry-run on a fresh
        # box, before ensure_base_install has ever run install_profiles) --
        # fall back to the copy bundled alongside this script itself, same
        # as run_environment_check's --check mode already does.
        local bundled_file="${SCRIPT_DIR}/profiles/${game_id}.profile.sh"
        if [[ -f "$bundled_file" ]]; then
            profile_file="$bundled_file"
        else
            log_err "No profile found for game '${game_id}'."
            log_err "Available games:"
            list_available_games | sed 's/^/  /' >&2
            die "Unknown game '${game_id}'."
        fi
    fi
    # "source" is what actually LOADS the profile file -- it's different
    # from just running the file as its own separate program. Sourcing
    # means "read this file's variables and functions directly into my
    # OWN current memory," as if its lines had been typed right here.
    # That's exactly why a profile's PROFILE_GAME_ID variable and its
    # profile_gather_prompts function (etc.) become usable immediately,
    # by name, everywhere else in this script from this point onward.
    # shellcheck source=/dev/null
    source "$profile_file"

    # This next block is the "contract check": every profile file
    # PROMISES to define a specific list of variables and a specific list
    # of functions (see PROFILE-AUTHORING.md for the full list, with
    # explanations of what each one is for). Rather than trusting that
    # promise blindly, this loops through each required NAME and
    # confirms it's really there.
    local required_vars=(PROFILE_GAME_ID PROFILE_DISPLAY_NAME PROFILE_STEAM_APPID PROFILE_STEAM_PLATFORM PROFILE_REQUIRES_WINE PROFILE_PORT_COUNT)
    local v
    for v in "${required_vars[@]}"; do
        # "${!v}" is a slightly advanced trick called "indirect expansion"
        # -- it means "treat the TEXT stored in variable v as itself
        # being the NAME of another variable, and look THAT one up."
        # Since v takes on values like "PROFILE_GAME_ID" one at a time as
        # this loop runs, "${!v}" ends up meaning "whatever
        # PROFILE_GAME_ID is currently set to" on that pass, then
        # "whatever PROFILE_DISPLAY_NAME is set to" on the next pass, and
        # so on -- without needing to write out a separate check for
        # every single one of these variable names by hand.
        [[ -n "${!v:-}" || "${!v-unset}" != "unset" ]] || die "Profile '${game_id}' is missing required variable ${v}."
    done

    # Same idea, but checking that specific FUNCTIONS exist rather than
    # variables. "declare -F name" is how Bash checks "is there a function
    # already defined with this exact name?" without actually calling it.
    local required_funcs=(profile_gather_prompts profile_build_launch_args profile_find_binary profile_port_specs)
    local fn
    for fn in "${required_funcs[@]}"; do
        declare -F "$fn" >/dev/null || die "Profile '${game_id}' is missing required function ${fn}()."
    done
}

# validate_profile_standalone: the --validate-profile <game> entry point,
# for contributors writing/editing a profile. Runs exactly the same
# contract check load_game_profile always runs (required
# PROFILE_*/profile_* variables and functions), but as its own standalone
# command with a clear pass/fail message -- so a contributor can check
# their new profile in one command, without running --check or a real
# install, and without needing root (loading/sourcing a profile file has
# no side effects on the machine).
validate_profile_standalone() {
    local game_id="$1"
    log_step "Validating profile '${game_id}'"
    if load_game_profile "$game_id"; then
        log_ok "Profile '${game_id}' satisfies the platform's contract (all required variables and functions present)."
        echo "  Display name: ${PROFILE_DISPLAY_NAME}"
        echo "  Steam AppID:  ${PROFILE_STEAM_APPID}"
        echo "  Requires Wine: $([ "$PROFILE_REQUIRES_WINE" == "1" ] && echo "yes" || echo "no")"
        echo "  Port count:   ${PROFILE_PORT_COUNT}"
    fi
    # No explicit failure branch needed here: load_game_profile calls
    # die() itself (via the required_vars/required_funcs loops above, or
    # if the profile file can't be found at all) on any contract
    # violation, which already prints a clear error and exits non-zero --
    # this function is only ever reached on success.
}

###############################################################################
# PACKAGE INSTALLATION
###############################################################################
# CORE_PACKAGES and OPTIONAL_PACKAGES are provided by common.sh (sourced at
# the top of this script) -- deliberately not redeclared here, so there is
# exactly one place that lists them and the two can never silently drift
# out of sync with each other.
# Only installed on demand, the first time an instance of a Wine-requiring
# game (profile PROFILE_REQUIRES_WINE=1) is added -- most users running
# only native-Linux games never need any of this.
readonly WINE_PACKAGES=(wine64 wine32:i386 winbind cabextract xvfb)

# enable_required_repos, apt_update_upgrade, and install_packages are
# provided by common.sh (sourced at the top of this script).

# ensure_wine_installed: installs Wine + its 32-bit/xvfb dependencies the
# first time they're actually needed (a Wine-requiring profile is being
# used), and is a fast no-op on every subsequent call. Keeps native-Linux-only
# deployments free of Wine entirely.
ensure_wine_installed() {
    if command_exists wine64 && command_exists xvfb-run; then
        log_info "Wine is already installed."
        return 0
    fi
    log_step "Installing Wine (required by this game's Windows-only server binary)"
    log_warn "This game has no native Linux server -- it runs the Windows binary through Wine."
    log_warn "This is a genuinely more fragile setup than a native Linux server: expect higher"
    log_warn "CPU overhead, and check that game's profile notes for known quirks."
    export DEBIAN_FRONTEND=noninteractive
    wait_for_apt_lock
    run_logged "apt-get install (wine)" apt-get install -y -qq "${WINE_PACKAGES[@]}" \
        || die "Failed to install Wine. See ${LOG_FILE}."
    log_ok "Wine installed."
}

# ensure_java_installed: installs a JVM the first time it's actually
# needed (a profile with PROFILE_REQUIRES_JAVA=1, e.g. Minecraft), and is a
# fast no-op on every subsequent call. Tries a specific modern OpenJDK
# first, falling back to Ubuntu's generic default-jre-headless metapackage
# -- if a given game version needs an even newer/older JDK than either
# provides, the server will say so clearly in its own log output.
ensure_java_installed() {
    if command_exists java; then
        log_info "Java is already installed."
        return 0
    fi
    log_step "Installing Java (required by this game's server)"
    export DEBIAN_FRONTEND=noninteractive
    wait_for_apt_lock
    if apt-get install -y -qq openjdk-21-jre-headless >>"$LOG_FILE" 2>&1; then
        log_ok "Java installed (openjdk-21-jre-headless)."
    else
        log_warn "openjdk-21-jre-headless not found; trying Ubuntu's generic default-jre-headless..."
        wait_for_apt_lock
        apt-get install -y -qq default-jre-headless >>"$LOG_FILE" 2>&1 \
            || die "Could not install Java under either package name."
        log_ok "Java installed (default-jre-headless)."
    fi
}

# ensure_xvfb_installed: installs xvfb (X virtual framebuffer) the first
# time a profile with PROFILE_REQUIRES_XVFB=1 needs it. Some Unity-based
# dedicated servers (Core Keeper is the example) still expect a graphics
# context even in "headless" mode -- this is unrelated to Wine (the
# binary is still native Linux, it just needs a virtual display to
# initialize against).
ensure_xvfb_installed() {
    if command_exists xvfb-run; then
        log_info "xvfb is already installed."
        return 0
    fi
    log_step "Installing xvfb (required by this game's server, a Unity headless-mode quirk)"
    export DEBIAN_FRONTEND=noninteractive
    wait_for_apt_lock
    apt-get install -y -qq xvfb >>"$LOG_FILE" 2>&1 || die "Failed to install xvfb. See ${LOG_FILE}."
    log_ok "xvfb installed."
}

###############################################################################
# DEDICATED LINUX USER
###############################################################################

# create_gameserver_user: creates the unprivileged, no-login, no-password
# system group/user every instance's game process runs as. Idempotent (safe
# to call on every run) -- each half checks whether its thing already
# exists before trying to create it, so re-running the installer never
# errors out over "user already exists."
create_gameserver_user() {
    log_step "Creating dedicated '${GS_USER}' system user"
    # `getent group NAME` looks NAME up in the system's group database
    # (works whether that database is the plain /etc/group file, LDAP,
    # etc.) and exits non-zero if no such group exists.
    if getent group "$GS_GROUP" >/dev/null 2>&1; then
        log_info "Group '${GS_GROUP}' already exists."
    else
        groupadd --system "$GS_GROUP" # --system: a service/daemon group, not an interactive human account
        log_ok "Group '${GS_GROUP}' created."
    fi
    if id -u "$GS_USER" >/dev/null 2>&1; then
        log_info "User '${GS_USER}' already exists."
    else
        useradd --system --gid "$GS_GROUP" --home-dir "$GS_BASE" \
                --no-create-home --shell /usr/sbin/nologin \
                --comment "Dedicated game server (unprivileged, no login)" \
                "$GS_USER"
        # --shell /usr/sbin/nologin: this account can never get an
        # interactive shell (e.g. via `su gameserver` or SSH) -- it exists
        # purely so game server processes have an unprivileged identity to
        # run under, never as a way for a human to log in.
        log_ok "User '${GS_USER}' created (no login shell, no password)."
    fi
}

# run_as_gameserver: runs a shell command string as the unprivileged
# gameserver user. Uses `runuser -u USER -- CMD` (not `-s SHELL -c CMD`,
# which util-linux's runuser rejects as mutually exclusive with -u).
run_as_gameserver() {
    # `--` marks the end of runuser's own options, so anything after it is
    # treated purely as the command to run, even if it happened to start
    # with a dash. "$1" here is the FULL command line as one string
    # (typically built up with embedded quoting by the caller), handed to
    # `bash -c` which parses and executes it as if typed at a prompt.
    runuser -u "$GS_USER" -- bash -c "$1"
}

###############################################################################
# BASE DIRECTORY LAYOUT
###############################################################################

# create_base_directory_layout: creates the top-level shared directories
# (everything that ISN'T per-instance or per-game). Per-instance and
# per-game directories are created on demand.
create_base_directory_layout() {
    log_step "Creating base directory layout under ${GS_BASE}"
    local dir
    for dir in "$GS_BASE" "$STEAMCMD_DIR" "$GOLDEN_DIR" "$SCRIPTS_DIR" "$PROFILES_DIR" "$INSTANCES_DIR" "$BASE_TMP_DIR"; do
        # `install -d` creates a directory (like mkdir -p) AND sets its
        # owner/group/mode in one atomic step, instead of mkdir followed by
        # separate chown/chmod calls -- there's no brief window where the
        # directory exists with the wrong (looser) permissions.
        install -d -o "$GS_USER" -g "$GS_GROUP" -m 0750 "$dir"
    done
    registry_ensure
    chown "$GS_USER:$GS_GROUP" "$INSTANCE_REGISTRY"
    log_ok "Base layout ready."
}

# install_profiles: copies the bundled game profiles into
# scripts/profiles/ (idempotent -- safe to re-run; always refreshes to the
# version shipped with this installer).
install_profiles() {
    log_step "Installing game profiles"
    install -d -o "$GS_USER" -g "$GS_GROUP" -m 0750 "$PROFILES_DIR"
    local f
    for f in "${SCRIPT_DIR}/profiles"/*.profile.sh; do
        [[ -e "$f" ]] || continue
        cp "$f" "$PROFILES_DIR/"
        chmod 640 "${PROFILES_DIR}/$(basename "$f")"
        chown "$GS_USER:$GS_GROUP" "${PROFILES_DIR}/$(basename "$f")"
    done
    # `tr '\n' ' '` turns list_available_games' one-name-per-line output
    # into a single space-separated line, just for a tidier log message.
    log_ok "Installed profiles: $(list_available_games | tr '\n' ' ')"
}

###############################################################################
# install_steamcmd is provided by common.sh (sourced at the top of this
# script). It downloads Valve's SteamCMD tarball, extracts it, and sets
# ownership -- idempotent, safe to re-run.
###############################################################################

# install_or_update_golden: runs SteamCMD to install/validate the active
# profile's App ID into its shared GOLDEN_DIR/<game_id> directory. Every
# instance of that game syncs its own server copy FROM this directory, so
# updating the game only means re-running this once per game, not once per
# instance. Honors PROFILE_STEAM_PLATFORM (some games only ship a Windows
# build, downloaded and run through Wine). SteamCMD's own exit code is
# informational only; the real proof of success is the resulting binary
# actually being found (via profile_find_binary).
install_or_update_golden() {
    local game_id="$1" golden_dir
    golden_dir="$(golden_dir_for_game "$game_id")"
    install -d -o "$GS_USER" -g "$GS_GROUP" -m 0750 "$golden_dir"

    # PROFILE_STEAM_APPID is empty for games not distributed via Steam (like
    # Minecraft) -- those profiles instead provide their own
    # profile_custom_download function that knows how to fetch that game's
    # server files directly (e.g. from Mojang's own servers).
    if [[ -z "$PROFILE_STEAM_APPID" ]]; then
        # Non-Steam game (e.g. Minecraft) -- the profile handles its own download.
        log_step "[$game_id] Installing/updating the shared server files (direct download, not Steam)"
        declare -F profile_custom_download >/dev/null \
            || die "[$game_id] This profile has no PROFILE_STEAM_APPID and no profile_custom_download() -- can't install it."
        profile_custom_download "$golden_dir" \
            || die "[$game_id] Custom download failed. Check ${LOG_FILE}, then re-run (safe to re-run)."
    else
        log_step "[$game_id] Installing/updating the shared server files (App ID ${PROFILE_STEAM_APPID}, platform: ${PROFILE_STEAM_PLATFORM})"
        log_info "This can take several minutes on the first run."

        local platform_flag=""
        if [[ "$PROFILE_STEAM_PLATFORM" == "windows" ]]; then
            platform_flag="+@sSteamCmdForcePlatformType windows"
        fi

        local steamcmd_rc=0
        # `set +e` temporarily turns OFF the strict "abort on any failure"
        # behavior enabled at the top of this script, just for the one
        # command below, then `set -e` immediately turns it back on. This is
        # necessary because SteamCMD often exits non-zero even on a
        # perfectly successful install (it's simply not a reliable signal
        # for this particular tool) -- without this, a normal, successful
        # run could still abort the whole script. The real check happens a
        # few lines down: does the expected binary actually exist on disk?
        set +e
        run_as_gameserver "\"${STEAMCMD_DIR}/steamcmd.sh\" ${platform_flag} +force_install_dir \"${golden_dir}\" +login anonymous +app_update ${PROFILE_STEAM_APPID} validate +quit" \
            >> "$LOG_FILE" 2>&1
        steamcmd_rc=$? # capture the exit code immediately -- the next command would overwrite $?
        set -e
        log_info "SteamCMD exited with code ${steamcmd_rc} (see ${LOG_FILE}; verifying the binary directly)."
    fi

    local found_binary
    found_binary="$(profile_find_binary "$golden_dir")"
    if [[ -n "$found_binary" && -e "$found_binary" ]]; then
        log_ok "[$game_id] Server files verified (${found_binary})."
    else
        die "[$game_id] Could not find the server binary after installing. Check ${LOG_FILE}, then re-run (safe to re-run)."
    fi
    chown -R "$GS_USER:$GS_GROUP" "$golden_dir"
}

###############################################################################
# PER-INSTANCE DIRECTORIES / SYNC FROM GOLDEN
###############################################################################

# create_instance_directories: creates the directory tree for one instance.
create_instance_directories() {
    local name="$1" dir
    # The backslash at the end of each line is a line continuation -- it
    # tells bash "this logical line isn't finished yet, keep reading the
    # next physical line as part of it." Purely a readability choice so this
    # one long `for ... in a b c d e f` list doesn't run off the screen.
    for dir in "$(instance_dir "$name")" "$(instance_server_dir "$name")" \
               "$(instance_data_dir "$name")" "$(instance_logs_dir "$name")" \
               "$(instance_tmp_dir "$name")" "$(instance_default_backup_dir "$name")"; do
        install -d -o "$GS_USER" -g "$GS_GROUP" -m 0750 "$dir"
    done
}

# sync_instance_from_golden: copies the shared per-game golden install into
# this instance's own server directory. Deliberately does NOT use rsync
# --delete, so anything instance-specific added later (Wine prefixes, mod
# files) is never wiped out by a future golden-install update sync.
sync_instance_from_golden() {
    local name="$1" game_id="$2" server_dir golden_dir
    server_dir="$(instance_server_dir "$name")"
    golden_dir="$(golden_dir_for_game "$game_id")"
    log_info "[$name] Syncing server files from the shared golden install..."
    # The trailing slash on "${golden_dir}/" is significant to rsync: it
    # means "copy the CONTENTS of this directory," not "copy this directory
    # itself as a subfolder" -- without it, files would land one level
    # deeper than intended (e.g. server_dir/golden/foo instead of
    # server_dir/foo). -a ("archive mode") preserves permissions,
    # timestamps, and symlinks, and recurses into subdirectories.
    rsync -a "${golden_dir}/" "${server_dir}/"
    chown -R "$GS_USER:$GS_GROUP" "$server_dir"
}

###############################################################################
# PER-INSTANCE CONFIGURATION
###############################################################################
GENERIC_INSTANCE_NAME=""

# gather_generic_instance_input: asks the questions common to EVERY game
# (instance name, port, backup schedule), then delegates to the active
# profile's profile_gather_prompts for anything game-specific. Leaves
# INSTANCE_NAME/PORT/BACKUP_* populated, plus whatever the profile itself
# sets (recorded in PROFILE_EXTRA_CONFIG_VARS for the generic config writer).
gather_generic_instance_input() {
    local suggested_name="$1"

    log_step "Configuring new instance (${PROFILE_DISPLAY_NAME})"
    echo "Press Enter at any prompt to accept the default shown in [brackets]."
    echo

    if [[ -n "$suggested_name" ]]; then
        INSTANCE_NAME="$suggested_name"
        validate_instance_name "$INSTANCE_NAME" >/dev/null \
            || die "Instance name '${INSTANCE_NAME}' is invalid: letters, numbers, '_', '-' only, 1-32 characters."
    else
        prompt_and_validate "Instance (shard) name" "${PROFILE_GAME_ID}1" validate_instance_name INSTANCE_NAME 0
    fi
    if registry_has "$INSTANCE_NAME"; then
        die "An instance named '${INSTANCE_NAME}' already exists. Use --remove-instance first, or choose a different name."
    fi

    # If this game's profile states a recommended minimum amount of RAM
    # (PROFILE_RECOMMENDED_RAM_MB is optional -- not every profile sets
    # it), compare that against how much RAM this machine actually has
    # (checked once, early, during ensure_base_install) and warn clearly
    # before going any further if there's a real mismatch. This matters
    # most for exactly the situation where someone picks a RAM-hungry game
    # (ARK-family titles especially) on a small, inexpensive server without
    # realizing the two don't fit together until something crashes later.
    if [[ -n "${PROFILE_RECOMMENDED_RAM_MB:-}" && -n "${TOTAL_RAM_MB:-}" ]] && (( TOTAL_RAM_MB < PROFILE_RECOMMENDED_RAM_MB )); then
        log_warn "${PROFILE_DISPLAY_NAME} recommends at least ${PROFILE_RECOMMENDED_RAM_MB}MB RAM; this machine has ${TOTAL_RAM_MB}MB total."
        log_warn "With less than that, it may run poorly, fail to start, or crash under real load."
        if [[ "$ASSUME_DEFAULTS" -eq 1 ]]; then
            log_warn "Non-interactive mode: proceeding anyway. Consider a smaller game or a larger machine for production use."
        else
            local ram_confirm=""
            read -r -p "Continue anyway? [y/N]: " ram_confirm < /dev/tty || true
            if [[ ! "${ram_confirm,,}" =~ ^y ]]; then
                die "Cancelled. Consider a lighter game for this machine, or add more RAM, then re-run."
            fi
        fi
    fi

    local suggested_port
    suggested_port="$(registry_next_port)"
    prompt_and_validate "Base port for this instance (uses ${PROFILE_PORT_COUNT} consecutive port(s))" "$suggested_port" validate_port SERVER_PORT 0
    if command_exists ss; then
        # `ss -uln` lists listening (-l) UDP (-u) sockets in numeric form
        # (-n, so it shows raw port numbers instead of resolving service
        # names); `ss -tln` does the same for TCP. Running both and
        # concatenating their output (via the `;` inside the same command
        # substitution) lets one grep check both protocols at once.
        local ss_output; ss_output="$(ss -uln 2>/dev/null; ss -tln 2>/dev/null)"
        # <<< "$ss_output" is a "here-string" -- it feeds the variable's
        # text to grep's stdin as if it were a one-line file, without
        # needing a temp file or a pipe. The [[:space:]] after the port
        # number avoids a false match against a longer port number that
        # merely starts with the same digits (e.g. searching for ":80"
        # shouldn't match ":8080").
        grep -q ":${SERVER_PORT}[[:space:]]" <<< "$ss_output" && log_warn "Port ${SERVER_PORT} already appears to be in use on this machine."
    fi

    # Profile-specific prompts (world name, max players, password, etc.)
    profile_gather_prompts

    prompt_and_validate "Sleep until a player connects, auto-stop after ${IDLE_MINUTES_THRESHOLD} idle minutes (saves resources when idle)? (yes/no)" \
        "yes" validate_yesno ON_DEMAND_INPUT 0
    ON_DEMAND="$(normalize_yesno_bit "$ON_DEMAND_INPUT")"
    if [[ "$ON_DEMAND" == "1" ]] && ! declare -F profile_get_player_count >/dev/null; then
        log_warn "This profile has no precise player-count check, so idle detection will use a"
        log_warn "network-traffic heuristic instead -- it can occasionally misjudge a quiet-but-"
        log_warn "connected player as idle. Consider disabling on-demand if that's a concern."
    fi

    prompt_and_validate "Backup retention (days)" "7" validate_retention_days BACKUP_RETENTION_DAYS 0
    CURRENT_INSTANCE_DATA_DIR="$(instance_data_dir "$INSTANCE_NAME")"
    prompt_and_validate "Backup destination directory" "$(instance_default_backup_dir "$INSTANCE_NAME")" validate_backup_dir BACKUP_DIR 0
    prompt_and_validate "Daily backup time (24h HH:MM)" "03:00" validate_time_hhmm BACKUP_TIME 0
    prompt_and_validate "Daily update-check time (24h HH:MM)" "04:00" validate_time_hhmm UPDATE_TIME 0

    if [[ "$BACKUP_TIME" == "$UPDATE_TIME" ]]; then
        log_warn "Backup and update times are identical (${BACKUP_TIME}); they will run back-to-back."
    fi

    # Discord notifications are entirely optional -- leaving this blank
    # (the default) disables them completely; notify_discord() below just
    # no-ops in that case. See README.md for how to create a webhook URL.
    prompt_and_validate "Discord webhook URL for crash/backup-failure alerts (blank to disable)" \
        "" validate_discord_webhook_url DISCORD_WEBHOOK_URL 0
    log_ok "Configuration collected for instance '${INSTANCE_NAME}'."
}

# write_instance_config: writes this instance's config.env (mode 600 --
# may contain a password). GAME=<id> is always included so every generic
# script (backup/restore/update/etc.) knows which profile to load; the
# rest is generic fields plus whatever profile_gather_prompts populated,
# via PROFILE_EXTRA_CONFIG_VARS (an array of variable names the profile
# wants persisted).
write_instance_config() {
    local name="$1" game_id="$2" cfg
    cfg="$(instance_config_file "$name")"

    {
        echo "# Instance configuration - generated by ${SCRIPT_NAME} on $(ts)"
        echo "INSTANCE_NAME=\"${name}\""
        echo "GAME=\"${game_id}\""
        echo "SERVER_PORT=${SERVER_PORT}"
        echo "ON_DEMAND=${ON_DEMAND}"
        echo "BACKUP_DIR=\"${BACKUP_DIR}\""
        echo "BACKUP_RETENTION_DAYS=${BACKUP_RETENTION_DAYS}"
        echo "BACKUP_TIME=\"${BACKUP_TIME}\""
        echo "UPDATE_TIME=\"${UPDATE_TIME}\""
        echo "DISCORD_WEBHOOK_URL=\"${DISCORD_WEBHOOK_URL}\""
        local varname
        # "${PROFILE_EXTRA_CONFIG_VARS[@]:-}" loops over every element of an
        # array the active game profile set (e.g. a Minecraft profile might
        # list "MAX_PLAYERS RCON_PASSWORD" here) -- the ":-" fallback keeps
        # this from erroring under `set -u` if a profile doesn't define the
        # array at all. "${!varname}" is INDIRECT EXPANSION again (see the
        # fuller explanation in load_game_profile above): it looks up
        # whatever variable NAME is currently stored in $varname, and
        # substitutes THAT variable's value -- so this one loop writes out
        # every profile-specific setting without this script needing to
        # know their names in advance.
        for varname in "${PROFILE_EXTRA_CONFIG_VARS[@]:-}"; do
            [[ -n "$varname" ]] || continue
            echo "${varname}=\"${!varname}\""
        done
    } > "$cfg"

    chown "$GS_USER:$GS_GROUP" "$cfg"
    chmod 600 "$cfg"
}

###############################################################################
# HELPER SCRIPT GENERATION
#
# Every generated script takes an instance name as its first argument. Each
# sources common.sh with that name, which loads that instance's config.env
# AND the matching game profile -- nothing is baked in by the installer via
# string interpolation, so adding/changing a game or instance never
# requires touching already-generated scripts.
###############################################################################

# write_common_script: writes scripts/common.sh, the shared library every
# other generated script sources. Provides load_instance (config.env +
# matching game profile), logging, the optional Discord notifier, and a
# disk-space guard used before risky operations.
write_common_script() {
    # `cat > file << 'EOF' ... EOF` is a here-document: everything between
    # the two EOF markers becomes the file's content. Quoting the opening
    # delimiter as 'EOF' (with quotes) is important -- it tells bash "do NOT
    # expand any $variables or `commands` inside this block; write it out
    # completely literally." That matters enormously here: the text below
    # is itself a bash SCRIPT that will run later, on a different machine
    # state, and it has its own $1, $LOG_FILE, etc. that must stay literal
    # dollar-signs in the generated file, not get replaced by THIS script's
    # own variables right now while we're merely writing the file out.
    # (Contrast with the unquoted << EOF used later in this file for
    # systemd unit files, where we DO want ${GS_USER} etc. substituted in.)
    cat > "${SCRIPTS_DIR}/common.sh" << 'EOF'
#!/usr/bin/env bash
# common.sh - shared functions/config sourced by every generated helper
# script. Not meant to be executed directly.
set -uo pipefail

GS_BASE="/srv/gameservers"
INSTANCES_DIR="${GS_BASE}/instances"
SCRIPTS_DIR="${GS_BASE}/scripts"
PROFILES_DIR="${SCRIPTS_DIR}/profiles"
GOLDEN_DIR="${GS_BASE}/golden"
INSTANCE_REGISTRY="${GS_BASE}/instances.registry"

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

# The config file is 0600 (may contain a password), readable only by root
# or the 'gameserver' user. Any other invoking user gets transparently
# re-executed under sudo (all arguments preserved) instead of a confusing
# permission error. Skipped for systemd/cron, which already run as
# 'gameserver' or root.
if [[ "${EUID}" -ne 0 && "$(id -un 2>/dev/null)" != "gameserver" ]]; then
    if command -v sudo >/dev/null 2>&1; then
        # `exec` REPLACES this script's own process with the sudo command,
        # instead of running sudo as a child and waiting for it -- there is
        # no "this script" left afterward, just the re-launched one running
        # as root. -E preserves the calling user's environment variables
        # across the sudo boundary (so things like a custom PATH survive).
        exec sudo -E bash "$0" "$@"
    else
        echo "ERROR: this needs root (or the 'gameserver' user) to read instance configs, and 'sudo' was not found." >&2
        exit 1
    fi
fi

# list_instance_names_to_stderr: prints every known instance name to
# stderr (used inside error messages so a typo'd instance name is easy to fix).
list_instance_names_to_stderr() {
    echo "Known instances:" >&2
    awk -F: '{print "  " $1 " (" $2 ")"}' "$INSTANCE_REGISTRY" >&2 2>/dev/null
}

# all_instance_names: prints every registered instance name, one per line.
all_instance_names() { awk -F: '{print $1}' "$INSTANCE_REGISTRY" 2>/dev/null; }

# load_instance: sources the named instance's config.env AND its matching
# game profile, setting INSTANCE_DIR/INSTANCE_SERVER_DIR/INSTANCE_DATA_DIR/
# INSTANCE_LOG_DIR/INSTANCE_TMP_DIR alongside everything from config.env
# (GAME, SERVER_PORT, BACKUP_*, and whatever the profile itself asked for).
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
    INSTANCE_DATA_DIR="${INSTANCE_DIR}/data"
    INSTANCE_LOG_DIR="${INSTANCE_DIR}/logs"
    INSTANCE_TMP_DIR="${INSTANCE_DIR}/tmp"

    local profile_file="${PROFILES_DIR}/${GAME}.profile.sh"
    if [[ ! -f "$profile_file" ]]; then
        echo "ERROR: instance '${name}' uses game '${GAME}', but no such profile is installed at ${profile_file}." >&2
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$profile_file"
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

# curl_with_retry: identical to the same-named function in the main
# installer script -- see there for the full explanation. Duplicated here
# because profiles can also run inside scripts that source THIS file
# (common.sh) directly, such as update-instance.sh calling a profile's
# profile_custom_download during a scheduled update, rather than during
# the original install.
curl_with_retry() {
    local attempt=1 max_attempts=3 delay_seconds=5
    while (( attempt <= max_attempts )); do
        if curl "$@"; then
            return 0
        fi
        if (( attempt < max_attempts )); then
            log_warn "Network request failed (attempt ${attempt}/${max_attempts}); retrying in ${delay_seconds}s..."
            sleep "$delay_seconds"
        fi
        attempt=$(( attempt + 1 ))
    done
    log_err "Network request failed after ${max_attempts} attempts: curl $*"
    return 1
}
EOF
    chmod 644 "${SCRIPTS_DIR}/common.sh"
    chown "$GS_USER:$GS_GROUP" "${SCRIPTS_DIR}/common.sh"
}

# write_start_instance_script: writes scripts/start-instance.sh, the
# ExecStart target for the systemd template unit (gameserver@<name>.service).
# Branches on PROFILE_REQUIRES_WINE: native games exec the Linux binary
# directly; Wine-requiring games launch through xvfb-run + wine64 with a
# per-instance WINEPREFIX (so multiple Wine-based instances never share
# Wine state).
write_start_instance_script() {
    cat > "${SCRIPTS_DIR}/start-instance.sh" << 'EOF'
#!/usr/bin/env bash
# start-instance.sh <instance-name> - launches one game instance in the
# foreground. Invoked by systemd (User=gameserver) as
# ExecStart=.../start-instance.sh %i ; not meant to be run by hand except
# for debugging (use manual-foreground-start.sh instead).
set -uo pipefail
source /srv/gameservers/scripts/common.sh
load_instance "${1:-}"

binary="$(profile_find_binary "$INSTANCE_SERVER_DIR")"
if [[ -z "$binary" || ! -e "$binary" ]]; then
    log_err "[$INSTANCE_NAME] Could not locate the ${GAME} server binary under ${INSTANCE_SERVER_DIR}."
    exit 1
fi

LAUNCH_ARGS=()
profile_build_launch_args

# Optional hook: lets a profile do last-second setup in THIS shell, right
# before exec replaces it -- e.g. creating a named pipe and backgrounding a
# process to hold its write side open, so the exec'd process (which
# inherits file descriptors, including a redirected stdin) can be driven
# by console commands instead of CLI args/a config file. Backgrounded
# processes survive the exec below (exec replaces the process image, it
# doesn't kill already-started children) and remain in the same systemd
# cgroup, so they stop cleanly together with the real server.
if declare -F profile_pre_launch_setup >/dev/null; then
    profile_pre_launch_setup
fi

log_info "[$INSTANCE_NAME] Launching ${GAME} (port ${SERVER_PORT})..."

# THIS IS THE ACTUAL MOMENT THE GAME SERVER PROGRAM STARTS. Depending on
# what KIND of program this game turned out to be (checked via the 3
# PROFILE_REQUIRES_* flags each profile sets), it needs to be started in
# one of four different ways -- this if/elif/elif/else chooses exactly
# one of them, in order, for any given game:
if [[ "${PROFILE_REQUIRES_WINE:-0}" == "1" ]]; then
    # CASE 1: a Windows-only program, run through Wine (a Windows
    # compatibility layer). WINEPREFIX is Wine's own name for "a private,
    # separate pretend Windows installation" -- giving each instance its
    # own means several different Wine-based games can run on the same
    # computer at once without their internal Windows-side settings
    # getting mixed up with each other.
    export WINEPREFIX="${INSTANCE_DIR}/wineprefix"
    export WINEARCH=win64
    export WINEDEBUG=-all
    mkdir -p "$WINEPREFIX"
    cd "$(dirname "$binary")" || exit 1
    # "exec" here means "become this new program, instead of continuing
    # to exist alongside it" -- rather than starting wine64 as a
    # separate, additional program and waiting around for it, this
    # script's own process is completely REPLACED by it. This matters
    # for systemd (the part of Linux that watches over background
    # programs): it's simpler and more reliable for systemd to track one
    # single, clearly-identified process for this whole instance, rather
    # than a parent script plus a child program underneath it.
    exec xvfb-run -a wine64 "$binary" "${LAUNCH_ARGS[@]}"
elif [[ "${PROFILE_REQUIRES_JAVA:-0}" == "1" ]]; then
    # CASE 2: a ".jar" file (Minecraft, Mindustry), which needs to be
    # handed to the "java" program rather than being run directly.
    cd "$(dirname "$binary")" || exit 1
    exec java -jar "$binary" "${LAUNCH_ARGS[@]}"
elif [[ "${PROFILE_REQUIRES_XVFB:-0}" == "1" ]]; then
    # CASE 3: a genuine, native Linux program (unlike case 1) that still
    # insists on a fake graphics display existing before it'll start --
    # see corekeeper.profile.sh for a full explanation of why this
    # happens and how it's different from the Wine case above.
    cd "$(dirname "$binary")" || exit 1
    export LD_LIBRARY_PATH=".:${LD_LIBRARY_PATH:-}"
    exec xvfb-run -a "$binary" "${LAUNCH_ARGS[@]}"
else
    # CASE 4 (the most common case by far): an ordinary, native Linux
    # program that can just be run directly, with no translation layer,
    # no fake display, and no separate runtime program needed at all.
    cd "$(dirname "$binary")" || exit 1
    export LD_LIBRARY_PATH=".:${LD_LIBRARY_PATH:-}"
    exec "$binary" "${LAUNCH_ARGS[@]}"
fi
EOF
    chmod 750 "${SCRIPTS_DIR}/start-instance.sh"
    chown "$GS_USER:$GS_GROUP" "${SCRIPTS_DIR}/start-instance.sh"
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
GS_USER="gameserver"
GS_GROUP="gameserver"
# "${1:?instance name required}" is parameter expansion with a required
# check baked in: if $1 was passed and non-empty, this evaluates to its
# value as normal; if $1 is empty or unset, bash immediately prints
# "instance name required" to stderr and exits -- a compact way to enforce
# "this argument is mandatory" without a separate if-statement.
INSTANCE_DIR="/srv/gameservers/instances/${1:?instance name required}"

chown -R "${GS_USER}:${GS_GROUP}" \
    "${INSTANCE_DIR}/data" "${INSTANCE_DIR}/logs" "${INSTANCE_DIR}/tmp" "${INSTANCE_DIR}/server"
chmod 750 "${INSTANCE_DIR}/data" "${INSTANCE_DIR}/logs"
if [[ -f "${INSTANCE_DIR}/config.env" ]]; then
    chmod 600 "${INSTANCE_DIR}/config.env"
    chown "${GS_USER}:${GS_GROUP}" "${INSTANCE_DIR}/config.env"
fi
exit 0
EOF
    chmod 700 "${SCRIPTS_DIR}/fix-permissions.sh"
    chown root:root "${SCRIPTS_DIR}/fix-permissions.sh"
}

# write_service_wrapper_scripts: writes stop/restart/status/logs wrappers
# and a manual foreground-debugging launcher. Each accepts either one
# instance name or the literal "all" (where that makes sense).
write_service_wrapper_scripts() {
    cat > "${SCRIPTS_DIR}/stop-instance.sh" << 'EOF'
#!/usr/bin/env bash
# stop-instance.sh <instance-name|all>
set -uo pipefail
source /srv/gameservers/scripts/common.sh
if [[ $EUID -ne 0 ]]; then log_err "Please run with sudo: sudo $0 <instance|all>"; exit 1; fi
target="${1:-}"
[[ -n "$target" ]] || { echo "Usage: $0 <instance-name|all>"; list_instance_names_to_stderr; exit 1; }

# names is an empty array being built up one element at a time below.
names=()
if [[ "$target" == "all" ]]; then
    # `while IFS= read -r n; do ...; done < <(COMMAND)` is the standard,
    # safe way to loop over another command's output line-by-line in bash.
    # `< <(COMMAND)` is PROCESS SUBSTITUTION: it runs COMMAND and makes its
    # output readable as if it were a file, fed into this `while` loop's
    # stdin. This is deliberately NOT written as `COMMAND | while ...`
    # (a pipe) because a pipe would run the while loop in a SUBSHELL (a
    # separate, temporary copy of the shell's environment) -- any variables
    # set inside it, like the `names` array being appended to here, would
    # vanish the instant the loop ended and never be visible afterward.
    # Process substitution avoids that subshell entirely. `IFS= read -r n`
    # (empty IFS, -r) reads each line exactly as-is, without trimming
    # leading/trailing whitespace or treating backslashes specially.
    while IFS= read -r n; do names+=("$n"); done < <(all_instance_names)
else
    if [[ ! -f "/srv/gameservers/instances/${target}/config.env" ]]; then
        echo "ERROR: no instance named '${target}'." >&2
        list_instance_names_to_stderr
        exit 1
    fi
    names=("$target")
fi

for name in "${names[@]}"; do
    log_info "Stopping instance '${name}'..."
    systemctl stop "gameserver@${name}"
    systemctl stop "gameserver-sleep@${name}" 2>/dev/null || true
    sleep 1
    if systemctl is-active --quiet "gameserver@${name}"; then
        log_err "Instance '${name}' is still active."
    else
        log_ok "Instance '${name}' stopped."
    fi
done
EOF

    cat > "${SCRIPTS_DIR}/restart-instance.sh" << 'EOF'
#!/usr/bin/env bash
# restart-instance.sh <instance-name|all>
set -uo pipefail
source /srv/gameservers/scripts/common.sh
if [[ $EUID -ne 0 ]]; then log_err "Please run with sudo: sudo $0 <instance|all>"; exit 1; fi
target="${1:-}"
[[ -n "$target" ]] || { echo "Usage: $0 <instance-name|all>"; list_instance_names_to_stderr; exit 1; }

names=()
if [[ "$target" == "all" ]]; then
    while IFS= read -r n; do names+=("$n"); done < <(all_instance_names)
else
    if [[ ! -f "/srv/gameservers/instances/${target}/config.env" ]]; then
        echo "ERROR: no instance named '${target}'." >&2
        list_instance_names_to_stderr
        exit 1
    fi
    names=("$target")
fi

overall_rc=0
for name in "${names[@]}"; do
    load_instance "$name"
    if [[ "${ON_DEMAND:-0}" == "1" ]] && systemctl is-active --quiet "gameserver-sleep@${name}"; then
        log_info "Instance '${name}' is sleeping -- waking it instead of restarting..."
        systemctl stop "gameserver-sleep@${name}" 2>/dev/null || true
    else
        log_info "Restarting instance '${name}'..."
    fi
    systemctl restart "gameserver@${name}"
    sleep 2
    if systemctl is-active --quiet "gameserver@${name}"; then
        log_ok "Instance '${name}' restarted."
    else
        log_err "Instance '${name}' failed to restart. Check: journalctl -u gameserver@${name} -n 100"
        overall_rc=1
    fi
done
exit $overall_rc
EOF

    cat > "${SCRIPTS_DIR}/status-instance.sh" << 'EOF'
#!/usr/bin/env bash
# status-instance.sh [instance-name]  (default: summary of every instance)
set -uo pipefail
source /srv/gameservers/scripts/common.sh
target="${1:-}"

# print_one: prints a one-line summary row for instance $1 in the "all instances" table view.
print_one() {
    local name="$1"
    load_instance "$name"
    local state
    state="$(systemctl is-active "gameserver@${name}" 2>/dev/null || echo unknown)"
    if [[ "${ON_DEMAND:-0}" == "1" && "$state" != "active" ]]; then
        if systemctl is-active --quiet "gameserver-sleep@${name}" 2>/dev/null; then
            state="sleeping"
        fi
    fi
    local ss_output listening="no"
    ss_output="$(ss -uln 2>/dev/null; ss -tln 2>/dev/null)"
    grep -q ":${SERVER_PORT}[[:space:]]" <<< "$ss_output" && listening="yes"
    printf '%-16s %-14s %-10s %-8s %s\n' "$name" "$GAME" "$state" "$SERVER_PORT" "$listening"
}

if [[ -n "$target" ]]; then
    load_instance "$target"
    echo "======================================================"
    echo " Instance: ${target}  (${PROFILE_DISPLAY_NAME})"
    echo "======================================================"
    systemctl status "gameserver@${target}" --no-pager -l 2>&1 || true
    echo
    echo "--- Disk usage ---"
    df -h "$INSTANCE_DIR"
else
    echo "======================================================"
    echo " All Instances"
    echo "======================================================"
    printf '%-16s %-14s %-10s %-8s %s\n' "NAME" "GAME" "STATE" "PORT" "LISTEN"
    while IFS= read -r n; do
        if [[ -n "$n" ]]; then
            print_one "$n"
        fi
    done < <(all_instance_names)
    echo
    echo "--- Overall disk/RAM ---"
    df -h /srv/gameservers
    free -h
fi
EOF

    cat > "${SCRIPTS_DIR}/logs-instance.sh" << 'EOF'
#!/usr/bin/env bash
# logs-instance.sh <instance-name> [service|backup|update]  (default: service)
set -uo pipefail
source /srv/gameservers/scripts/common.sh
name="${1:-}"
[[ -n "$name" ]] || { echo "Usage: $0 <instance-name> [service|backup|update]"; list_instance_names_to_stderr; exit 1; }
load_instance "$name"
MODE="${2:-service}"
case "$MODE" in
    service|-f|follow)
        echo "Following systemd journal for gameserver@${name}.service (Ctrl+C to stop)..."
        journalctl -u "gameserver@${name}" -n 200 -f
        ;;
    backup) tail -n 100 "${INSTANCE_LOG_DIR}/backup.log" 2>/dev/null || echo "No backup log yet." ;;
    update) tail -n 100 "${INSTANCE_LOG_DIR}/update.log" 2>/dev/null || echo "No update log yet." ;;
    *) echo "Usage: $0 <instance-name> [service|backup|update]"; exit 1 ;;
esac
EOF

    chmod 750 "${SCRIPTS_DIR}"/{stop-instance.sh,restart-instance.sh,status-instance.sh,logs-instance.sh}
    chown "$GS_USER:$GS_GROUP" "${SCRIPTS_DIR}"/{stop-instance.sh,restart-instance.sh,status-instance.sh,logs-instance.sh}

    cat > "${SCRIPTS_DIR}/manual-foreground-start.sh" << 'EOF'
#!/usr/bin/env bash
# manual-foreground-start.sh <instance-name> - runs one instance in the
# foreground for debugging, as the unprivileged 'gameserver' user. Stop the
# real service first: sudo systemctl stop gameserver@<instance-name>
# Tip: run this inside 'tmux'/'screen' so you can detach and it keeps running.
set -uo pipefail
source /srv/gameservers/scripts/common.sh
name="${1:-}"
[[ -n "$name" ]] || { echo "Usage: $0 <instance-name>"; list_instance_names_to_stderr; exit 1; }
load_instance "$name"
if [[ $EUID -ne 0 ]]; then
    log_err "This needs root so it can switch to the 'gameserver' user. Run with sudo."
    exit 1
fi
log_warn "Running instance '${name}' in the FOREGROUND for debugging. Press Ctrl+C to stop."
exec runuser -u gameserver -- bash -c "/srv/gameservers/scripts/start-instance.sh '${name}'"
EOF
    chmod 750 "${SCRIPTS_DIR}/manual-foreground-start.sh"
    chown "$GS_USER:$GS_GROUP" "${SCRIPTS_DIR}/manual-foreground-start.sh"
}

# write_backup_script: writes scripts/backup-instance.sh <instance|all>.
# Game-agnostic: backs up whatever is in the instance's data/ directory
# (each profile is responsible for making its data land there -- see
# PROFILE-AUTHORING.md).
write_backup_script() {
    cat > "${SCRIPTS_DIR}/backup-instance.sh" << 'EOF'
#!/usr/bin/env bash
# backup-instance.sh <instance-name|all> - creates a timestamped,
# integrity-checked ZIP backup of one instance's (or every instance's)
# data directory, prunes old backups past retention, and sweeps up
# orphaned staging directories from any interrupted previous run.
# Exit codes: 0 = success (including "nothing to back up yet" or "disk too
# full, skipped"), 1 = a real failure.
set -uo pipefail
source /srv/gameservers/scripts/common.sh

# BACKUP_SIZE_TREND_LOG: one shared CSV (date,instance,size_bytes) that
# every instance's backup run appends one line to, so backup size over
# time can be eyeballed or graphed across the whole fleet.
BACKUP_SIZE_TREND_LOG="${GS_BASE}/backup-size-trend.csv"

target="${1:-}"
[[ -n "$target" ]] || { echo "Usage: $0 <instance-name|all>"; list_instance_names_to_stderr; exit 1; }

# backup_one: performs the full backup+verify+prune flow for a single named instance.
backup_one() {
    local name="$1"
    load_instance "$name"
    exec >> "${INSTANCE_LOG_DIR}/backup.log" 2>&1
    log_info "[$name] === Backup started ==="

    find "$INSTANCE_TMP_DIR" -maxdepth 1 -type d \( -name 'backup-staging-*' -o -name 'pre-restore-*' \) -mtime +1 -exec rm -rf {} + 2>/dev/null || true

    # Retention pruning always runs, independent of whether a NEW backup
    # gets created below.
    local deleted=0
    while IFS= read -r -d '' old; do
        rm -f "$old"; log_info "[$name] Removed old backup: $(basename "$old")"; deleted=$((deleted+1))
    done < <(find "$BACKUP_DIR" -maxdepth 1 -name "gsbackup-${name}-*.zip" -mtime "+${BACKUP_RETENTION_DAYS}" -print0 2>/dev/null)
    (( deleted > 0 )) && log_ok "[$name] Pruned ${deleted} old backup(s)."

    if ! have_enough_disk_space "$BACKUP_DIR" 200; then
        notify_discord "Backup SKIPPED for [$name] on $(hostname): backup disk is nearly full."
        exit 1
    fi

    local ts_now archive_name archive_path staging
    ts_now="$(date '+%Y%m%d-%H%M%S')"
    staging="${INSTANCE_TMP_DIR}/backup-staging-${ts_now}"
    archive_name="gsbackup-${name}-${ts_now}.zip"
    archive_path="${BACKUP_DIR}/${archive_name}"

    mkdir -p "$BACKUP_DIR" "$staging"
    if [[ -z "$(ls -A "$INSTANCE_DATA_DIR" 2>/dev/null)" ]]; then
        log_warn "[$name] Data directory is empty. Nothing to back up yet."
        rmdir "$staging" 2>/dev/null || true
        exit 0
    fi

    if ! rsync -a "${INSTANCE_DATA_DIR}/" "${staging}/"; then
        log_err "[$name] Failed to copy data into staging."; rm -rf "$staging"; exit 1
    fi
    if ! ( cd "$staging" && zip -rq "$archive_path" . ); then
        log_err "[$name] Failed to create archive ${archive_path}."; rm -rf "$staging"; exit 1
    fi
    rm -rf "$staging"

    if unzip -tq "$archive_path" >/dev/null 2>&1; then
        log_ok "[$name] Backup created and verified: ${archive_path}"
    else
        log_err "[$name] Backup verification FAILED for ${archive_path}."
        notify_discord "Backup verification FAILED for [$name] on $(hostname)."
        exit 1
    fi

    # Record this backup's size in a small, shared trend log (one line per
    # backup run, across every instance): date,instance,size_bytes. This
    # is intentionally append-only and never pruned by this script itself
    # -- it's small (one line per backup) and lets an operator eyeball
    # whether an instance's save data is growing over time, or spot a
    # sudden jump/drop that might mean something's wrong.
    local backup_size_bytes
    backup_size_bytes="$(stat -c%s "$archive_path" 2>/dev/null || wc -c < "$archive_path" 2>/dev/null || echo 0)"
    backup_size_bytes="${backup_size_bytes//[[:space:]]/}"
    if [[ ! -f "$BACKUP_SIZE_TREND_LOG" ]]; then
        echo "date,instance,size_bytes" > "$BACKUP_SIZE_TREND_LOG" 2>/dev/null || true
    fi
    echo "$(date '+%Y-%m-%d'),${name},${backup_size_bytes}" >> "$BACKUP_SIZE_TREND_LOG" 2>/dev/null || \
        log_warn "[$name] Could not write to backup size trend log ${BACKUP_SIZE_TREND_LOG}."

    log_ok "[$name] === Backup finished. ${deleted} old backup(s) pruned. ==="
    notify_discord "Backup completed for [$name] on $(hostname): ${archive_name}"
}

if [[ "$target" == "all" ]]; then
    overall_rc=0
    while IFS= read -r n; do
        [[ -n "$n" ]] || continue
        ( backup_one "$n" ) || overall_rc=1
    done < <(all_instance_names)
    exit $overall_rc
else
    if [[ ! -f "/srv/gameservers/instances/${target}/config.env" ]]; then
        echo "ERROR: no instance named '${target}'." >&2
        list_instance_names_to_stderr
        exit 1
    fi
    ( backup_one "$target" )
fi
EOF
    chmod 750 "${SCRIPTS_DIR}/backup-instance.sh"
    chown "$GS_USER:$GS_GROUP" "${SCRIPTS_DIR}/backup-instance.sh"
}

# write_restore_script: writes scripts/restore-instance.sh <instance> <backup.zip>.
write_restore_script() {
    cat > "${SCRIPTS_DIR}/restore-instance.sh" << 'EOF'
#!/usr/bin/env bash
# restore-instance.sh <instance-name> <path-to-backup.zip> - restores one
# instance's data directory from a backup made by backup-instance.sh.
# Stops that instance, saves whatever data is currently in place as a
# safety copy, restores, then restarts.
set -uo pipefail
source /srv/gameservers/scripts/common.sh

# usage: prints how to call this script, plus (if an instance name was already given) that instance's available backups, then exits 1.
usage() {
    echo "Usage: $0 <instance-name> <path-to-backup.zip>"
    list_instance_names_to_stderr
    if [[ -n "${1:-}" ]]; then
        echo "Available backups for '${1}':" >&2
        ls -1t "${BACKUP_DIR:-}"/gsbackup-"${1}"-*.zip 2>/dev/null >&2 || echo "  (none found)" >&2
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
have_enough_disk_space "$INSTANCE_DATA_DIR" 200 || exit 1

log_info "[$name] Stopping service..."
systemctl stop "gameserver@${name}"

safety_ts="$(date '+%Y%m%d-%H%M%S')"
safety_dir="${INSTANCE_TMP_DIR}/pre-restore-${safety_ts}"
mkdir -p "$safety_dir"
if [[ -n "$(ls -A "$INSTANCE_DATA_DIR" 2>/dev/null)" ]]; then
    cp -a "${INSTANCE_DATA_DIR}/." "$safety_dir/"
    log_info "[$name] Safety copy of current data saved to ${safety_dir}"
else
    log_warn "[$name] No current data to back up before restoring (fine on a first restore)."
fi

# Clear the destination before extracting, so the result is exactly the
# archive's contents -- nothing stale left mixed in from the previous
# data (the safety copy just above already preserved it). Only ever
# removes DIRECT children of INSTANCE_DATA_DIR (no recursive descent
# into subdirectories that could follow a symlink out of the target),
# and only runs at all if that variable is a real, non-root directory.
if [[ -n "$INSTANCE_DATA_DIR" && "$INSTANCE_DATA_DIR" != "/" && -d "$INSTANCE_DATA_DIR" ]]; then
    find "$INSTANCE_DATA_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
fi

log_info "[$name] Extracting backup: $backup_file"
if ! unzip -oq "$backup_file" -d "$INSTANCE_DATA_DIR"; then
    log_err "[$name] Extraction failed. Restarting with the previous data untouched."
    systemctl start "gameserver@${name}"
    exit 1
fi
chown -R gameserver:gameserver "$INSTANCE_DATA_DIR"

log_info "[$name] Starting service..."
systemctl start "gameserver@${name}"
sleep 2
if systemctl is-active --quiet "gameserver@${name}"; then
    log_ok "[$name] Restore complete and running. Safety copy: ${safety_dir}"
else
    log_err "[$name] Service did not come back up. Check: journalctl -u gameserver@${name} -n 100"
    exit 1
fi
EOF
    chmod 750 "${SCRIPTS_DIR}/restore-instance.sh"
    chown "$GS_USER:$GS_GROUP" "${SCRIPTS_DIR}/restore-instance.sh"
}

# write_update_script: writes scripts/update-instance.sh <instance|all>.
# Always validates the shared per-GAME golden install first (cheap/
# incremental if nothing changed), then re-syncs and restarts only the
# targeted instance(s) -- so updating "all" rolls through shards one at a
# time instead of taking every shard offline simultaneously. Honors each
# instance's own game profile (steam app id + platform type).
write_update_script() {
    cat > "${SCRIPTS_DIR}/update-instance.sh" << 'EOF'
#!/usr/bin/env bash
# update-instance.sh <instance-name|all>
set -uo pipefail
source /srv/gameservers/scripts/common.sh

STEAMCMD_DIR="/srv/gameservers/steamcmd"

if [[ $EUID -ne 0 ]]; then log_err "Please run with sudo."; exit 1; fi

target="${1:-}"
[[ -n "$target" ]] || { echo "Usage: $0 <instance-name|all>"; list_instance_names_to_stderr; exit 1; }

# validate_golden: runs SteamCMD validate (or custom download) for a game
# exactly once. Uses an associative array to skip re-validation when
# multiple instances share the same game. Returns 0 on success, 1 on
# failure (after which the instance update is skipped).
declare -A VALIDATED_GAMES

validate_golden() {
    local game_id="$1"
    if [[ -n "${VALIDATED_GAMES[$game_id]:-}" ]]; then
        log_info "Golden install for '${game_id}' already validated this run; skipping."
        return 0
    fi
    local golden_dir="/srv/gameservers/golden/${game_id}"

    # Load the game profile to get STEAM_APPID and platform info.
    local profile_file="/srv/gameservers/scripts/profiles/${game_id}.profile.sh"
    if [[ ! -f "$profile_file" ]]; then
        log_err "Profile for '${game_id}' not found at ${profile_file}."
        return 1
    fi
    # shellcheck source=/dev/null
    source "$profile_file"

    if [[ -z "${PROFILE_STEAM_APPID:-}" ]]; then
        log_info "[${game_id}] Refreshing the shared golden install (direct download, not Steam)..."
        if ! declare -F profile_custom_download >/dev/null || ! profile_custom_download "$golden_dir"; then
            log_err "[${game_id}] Custom download failed during update."
            return 1
        fi
    else
        log_info "[${game_id}] Validating the shared golden install via SteamCMD (App ID ${PROFILE_STEAM_APPID})..."
        local platform_flag=""
        if [[ "${PROFILE_STEAM_PLATFORM:-linux}" == "windows" ]]; then
            platform_flag="+@sSteamCmdForcePlatformType windows"
        fi
        local steamcmd_rc=0
        runuser -u gameserver -- bash -c \
            "\"${STEAMCMD_DIR}/steamcmd.sh\" ${platform_flag} +force_install_dir \"${golden_dir}\" +login anonymous +app_update ${PROFILE_STEAM_APPID} validate +quit" \
            || steamcmd_rc=$?
        log_info "[${game_id}] SteamCMD exited with code ${steamcmd_rc} (informational; verifying binary directly)."
    fi

    local found_binary
    found_binary="$(profile_find_binary "$golden_dir")"
    if [[ -z "$found_binary" || ! -e "$found_binary" ]]; then
        log_err "[${game_id}] Golden server binary missing after validation!"
        return 1
    fi
    log_ok "[${game_id}] Golden install verified."
    VALIDATED_GAMES[$game_id]=1
    return 0
}

# update_one: syncs one instance from the (already-validated) golden install and restarts it if it was running.
update_one() {
    local name="$1"
    load_instance "$name"
    local golden_dir="/srv/gameservers/golden/${GAME}"

    if ! have_enough_disk_space "$golden_dir" 1024; then
        log_err "[$name] Disk nearly full; skipping the update entirely."
        return 1
    fi

    # Validate this game's golden install (once per unique game, not per instance).
    if ! validate_golden "$GAME"; then
        return 1
    fi

    local was_active=0
    if systemctl is-active --quiet "gameserver@${name}"; then
        was_active=1
        log_info "[$name] Stopping for update..."
        systemctl stop "gameserver@${name}"
    fi

    log_info "[$name] Syncing server files from the golden install..."
    if ! rsync -a "${golden_dir}/" "${INSTANCE_SERVER_DIR}/"; then
        log_err "[$name] Sync from golden failed!"
        if [[ "$was_active" -eq 1 ]]; then
            systemctl start "gameserver@${name}"
        fi
        return 1
    fi
    chown -R gameserver:gameserver "$INSTANCE_SERVER_DIR"

    if [[ "$was_active" -eq 1 ]]; then
        log_info "[$name] Restarting..."
        systemctl start "gameserver@${name}"
        sleep 3
        if systemctl is-active --quiet "gameserver@${name}"; then
            log_ok "[$name] Restarted successfully after update."
        else
            log_err "[$name] FAILED to restart after update!"
            notify_discord "Instance [$name] failed to restart after update on $(hostname)."
            return 1
        fi
    fi
    notify_discord "Instance [$name] (${GAME}) updated on $(hostname)."
    return 0
}

if [[ "$target" == "all" ]]; then
    overall_rc=0
    while IFS= read -r n; do
        [[ -n "$n" ]] || continue
        update_one "$n" >> "/srv/gameservers/instances/${n}/logs/update.log" 2>&1 || overall_rc=1
    done < <(all_instance_names)
    exit $overall_rc
else
    if [[ ! -f "/srv/gameservers/instances/${target}/config.env" ]]; then
        echo "ERROR: no instance named '${target}'." >&2
        list_instance_names_to_stderr
        exit 1
    fi
    update_one "$target" >> "/srv/gameservers/instances/${target}/logs/update.log" 2>&1
fi
EOF
    chmod 750 "${SCRIPTS_DIR}/update-instance.sh"
    chown "$GS_USER:$GS_GROUP" "${SCRIPTS_DIR}/update-instance.sh"
}

# write_healthcheck_script: writes scripts/healthcheck-instance.sh
# <instance|all>. Verifies the service is active and its port is
# listening; restarts automatically if run as root. A grace period avoids
# false alarms while a game is still loading/generating a fresh world.
# Also monitors the sleep-listener service for on-demand instances.
write_healthcheck_script() {
    cat > "${SCRIPTS_DIR}/healthcheck-instance.sh" << 'EOF'
#!/usr/bin/env bash
# healthcheck-instance.sh <instance-name|all>
set -uo pipefail
source /srv/gameservers/scripts/common.sh

GRACE_PERIOD_SECONDS=180
CRASH_LOG_LINES=15  # how many recent journalctl lines to pull into a Discord notification on auto-restart
target="${1:-}"
[[ -n "$target" ]] || { echo "Usage: $0 <instance-name|all>"; list_instance_names_to_stderr; exit 1; }

# capture_crash_reason: pulls the last CRASH_LOG_LINES lines of this
# instance's journal (i.e. whatever the game process itself printed right
# before it died) and formats them as a Discord code block, so an
# auto-restart notification tells you WHY it died, not just THAT it did.
# Prints an empty string (no extra section) if journalctl has nothing to
# show, so callers can always safely append its output to a message.
capture_crash_reason() {
    local name="$1" lines
    lines="$(journalctl -u "gameserver@${name}" -n "$CRASH_LOG_LINES" --no-pager -o cat 2>/dev/null || true)"
    [[ -n "$lines" ]] || return 0
    # Discord's per-message limit is 2000 chars; truncate defensively so a
    # chatty crash (a giant stack trace, say) can never make the webhook
    # POST itself fail outright.
    if [[ "${#lines}" -gt 1500 ]]; then
        lines="${lines: -1500}"
        lines="(...truncated...)"$'\n'"${lines}"
    fi
    printf '\n\nLast %s journal lines for gameserver@%s:\n```\n%s\n```' "$CRASH_LOG_LINES" "$name" "$lines"
}

# check_one: verifies (and, if run as root, self-heals) a single named instance.
check_one() {
    local name="$1"
    load_instance "$name"

    # For on-demand instances, check the sleep-listener service first.
    # If the instance is supposed to be sleeping but the listener is down,
    # that means new players can't wake it -- a silent failure.
    if [[ "${ON_DEMAND:-0}" == "1" ]]; then
        if ! systemctl is-active --quiet "gameserver@${name}"; then
            # The real server should be stopped; verify the sleep listener is running.
            if ! systemctl is-active --quiet "gameserver-sleep@${name}" 2>/dev/null; then
                log_err "[$name] On-demand instance is not running AND sleep listener is down -- nobody can connect!"
                if [[ $EUID -eq 0 ]]; then
                    log_warn "[$name] Re-arming the sleep listener..."
                    systemctl start "gameserver-sleep@${name}"
                    notify_discord "Instance [$name] sleep listener was down on $(hostname) -- restarted automatically."
                fi
                return 1
            fi
            log_ok "[$name] On-demand sleep listener is active (instance is sleeping, waiting for connection)."
            return 0
        fi
    fi

    if ! systemctl is-active --quiet "gameserver@${name}"; then
        log_err "[$name] Service is not active."
        if [[ $EUID -eq 0 ]]; then
            log_warn "[$name] Attempting to start..."
            local crash_log
            crash_log="$(capture_crash_reason "$name")"
            systemctl start "gameserver@${name}"
            notify_discord "Instance [$name] was down on $(hostname) -- restarted automatically.${crash_log}"
        fi
        return 1
    fi
    log_ok "[$name] Service is active."

    local active_since_raw active_since_epoch=0 now_epoch uptime_seconds
    active_since_raw="$(systemctl show "gameserver@${name}" --property=ActiveEnterTimestamp --value 2>/dev/null || true)"
    [[ -n "$active_since_raw" ]] && active_since_epoch="$(date -d "$active_since_raw" +%s 2>/dev/null || echo 0)"
    now_epoch="$(date +%s)"
    uptime_seconds=$(( now_epoch - active_since_epoch ))

    if [[ "$active_since_epoch" -eq 0 || "$uptime_seconds" -lt "$GRACE_PERIOD_SECONDS" ]]; then
        log_info "[$name] Started recently (~${uptime_seconds}s ago); skipping port check for now."
        return 0
    fi

    local ss_output
    ss_output="$(ss -uln 2>/dev/null; ss -tln 2>/dev/null)"
    if grep -q ":${SERVER_PORT}[[:space:]]" <<< "$ss_output"; then
        log_ok "[$name] Port ${SERVER_PORT} is listening."
        return 0
    fi

    log_err "[$name] Port ${SERVER_PORT} is not listening after the grace period."
    if [[ $EUID -eq 0 ]]; then
        log_warn "[$name] Restarting..."
        local crash_log
        crash_log="$(capture_crash_reason "$name")"
        systemctl restart "gameserver@${name}"
        notify_discord "Instance [$name] port was unresponsive on $(hostname) -- restarted automatically.${crash_log}"
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
    chmod 750 "${SCRIPTS_DIR}/healthcheck-instance.sh"
    chown "$GS_USER:$GS_GROUP" "${SCRIPTS_DIR}/healthcheck-instance.sh"
}

# write_monitoring_scripts: writes the CPU/RAM/disk/SMART/network helpers.
write_monitoring_scripts() {
    cat > "${SCRIPTS_DIR}/cpu-status.sh" << 'EOF'
#!/usr/bin/env bash
set -uo pipefail
echo "=== CPU Info ==="
lscpu | grep -E 'Model name|Socket|Core\(s\) per socket|Thread\(s\) per core' || true
echo; echo "=== Live Snapshot ==="
top -bn1 | grep -i "Cpu(s)" || true
echo; echo "=== Top CPU-consuming processes ==="
ps aux --sort=-%cpu | head -n 10
EOF

    cat > "${SCRIPTS_DIR}/ram-status.sh" << 'EOF'
#!/usr/bin/env bash
set -uo pipefail
echo "=== Memory Usage ==="
free -h
echo; echo "=== Top memory-consuming processes ==="
ps aux --sort=-%mem | head -n 10
EOF

    cat > "${SCRIPTS_DIR}/disk-status.sh" << 'EOF'
#!/usr/bin/env bash
set -uo pipefail
echo "=== Disk Usage ==="
df -h /srv/gameservers /
echo; echo "=== Per-Instance Sizes ==="
du -sh /srv/gameservers/instances/*/ 2>/dev/null
echo; echo "=== Golden Installs / SteamCMD ==="
du -sh /srv/gameservers/golden/*/ /srv/gameservers/steamcmd 2>/dev/null
EOF

    cat > "${SCRIPTS_DIR}/smart-status.sh" << 'EOF'
#!/usr/bin/env bash
set -uo pipefail
if [[ $EUID -ne 0 ]]; then
    echo "Note: run with sudo for complete SMART data."
fi
disks="$(lsblk -dn -o NAME 2>/dev/null | grep -E '^(sd|nvme|vd)' || true)"
[[ -z "$disks" ]] && { echo "No physical disks detected by lsblk."; exit 0; }
for disk in $disks; do
    echo "=== /dev/${disk} ==="
    smartctl -H "/dev/${disk}" 2>/dev/null || echo "  SMART data not available for /dev/${disk}."
    echo
done
EOF

    cat > "${SCRIPTS_DIR}/network-status.sh" << 'EOF'
#!/usr/bin/env bash
set -uo pipefail
source /srv/gameservers/scripts/common.sh
echo "=== Network Interfaces ==="
ip -brief addr show 2>/dev/null || ip addr show
echo; echo "=== Per-Instance Ports ==="
printf '%-16s %-14s %-8s %s\n' "INSTANCE" "GAME" "PORT" "LISTENING"
while IFS=: read -r name game port _; do
    [[ -n "$name" ]] || continue
    ss_output="$(ss -uln 2>/dev/null; ss -tln 2>/dev/null)"
    listening="no"
    grep -q ":${port}[[:space:]]" <<< "$ss_output" && listening="yes"
    printf '%-16s %-14s %-8s %s\n' "$name" "$game" "$port" "$listening"
done < "$INSTANCE_REGISTRY"
echo; echo "=== UFW Status ==="
ufw status verbose 2>/dev/null || echo "UFW not active or not installed."
EOF

    chmod 750 "${SCRIPTS_DIR}"/{cpu-status.sh,ram-status.sh,disk-status.sh,smart-status.sh,network-status.sh}
    chown "$GS_USER:$GS_GROUP" "${SCRIPTS_DIR}"/{cpu-status.sh,ram-status.sh,disk-status.sh,smart-status.sh,network-status.sh}
}

# write_host_capacity_monitor_script: writes scripts/host-capacity-monitor.sh.
# Logs host-wide CPU/RAM utilization and flags sustained (not momentary)
# high usage -- your signal to lower a shard's settings, move a shard to
# different hardware, or add capacity. There is no way to "auto-scale"
# physical CPU/RAM, so this is visibility/alerting, not allocation.
write_host_capacity_monitor_script() {
    cat > "${SCRIPTS_DIR}/host-capacity-monitor.sh" << 'EOF'
#!/usr/bin/env bash
set -uo pipefail
LOG_FILE="/srv/gameservers/host-capacity.log"
STATE_FILE="/srv/gameservers/tmp/host-capacity-high-streak"
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
        echo "$(ts) WARNING: sustained high utilization (CPU ${cpu_pct}%, RAM ${ram_pct}%) for ${streak} consecutive checks." >> "$LOG_FILE"
    fi
elif (( cpu_pct < LOW_THRESHOLD && ram_pct < LOW_THRESHOLD )); then
    echo 0 > "$STATE_FILE"
fi
EOF
    chmod 750 "${SCRIPTS_DIR}/host-capacity-monitor.sh"
    chown "$GS_USER:$GS_GROUP" "${SCRIPTS_DIR}/host-capacity-monitor.sh"
}

###############################################################################
# ON-DEMAND (SLEEP UNTIL CONNECTED / AUTO-STOP WHEN IDLE)
#
# An on-demand instance's REAL systemd unit (gameserver@<name>) is normally
# stopped. In its place, a lightweight "sleep listener" (gameserver-sleep@
# <name>) sits on the instance's primary port using socat -- the moment
# any connection/packet arrives, it triggers the real server to start and
# exits cleanly (so it never fights the real server for the port). Once
# running, a per-minute cron check calls the profile's precise player-count
# hook if it has one, or falls back to a conntrack-based "any recent
# traffic" heuristic, and after IDLE_MINUTES_THRESHOLD consecutive idle
# minutes: triggers an optional profile save hook, stops the real server,
# and re-arms the sleep listener.
###############################################################################

# write_sleep_listener_script: writes scripts/sleep-listener.sh
# <instance-name>, the ExecStart target for gameserver-sleep@.service.
write_sleep_listener_script() {
    cat > "${SCRIPTS_DIR}/sleep-listener.sh" << 'EOF'
#!/usr/bin/env bash
# sleep-listener.sh <instance-name> - blocks until the first connection/
# packet arrives on this instance's primary port, then triggers
# wake-instance.sh and exits. Run by systemd as gameserver-sleep@<name>;
# Restart=on-failure (not "always") means a clean exit after a successful
# wake does NOT get restarted, so it never re-binds the port out from
# under the now-starting real server.
set -uo pipefail
source /srv/gameservers/scripts/common.sh
load_instance "${1:?instance name required}"

# Determine the primary (offset 0) port's protocol from the profile.
proto="udp"
while IFS=: read -r offset p desc; do
    if [[ "$offset" == "0" ]]; then
        proto="$p"
        break
    fi
done < <(profile_port_specs)

log_info "[$INSTANCE_NAME] Sleeping -- waiting for a connection on port ${SERVER_PORT}/${proto} to wake it..."

if [[ "$proto" == "tcp" ]]; then
    socat TCP-LISTEN:"${SERVER_PORT}",reuseaddr SYSTEM:"/srv/gameservers/scripts/wake-instance.sh '${INSTANCE_NAME}'"
else
    socat UDP-RECV:"${SERVER_PORT}" SYSTEM:"/srv/gameservers/scripts/wake-instance.sh '${INSTANCE_NAME}'"
fi
EOF
    chmod 750 "${SCRIPTS_DIR}/sleep-listener.sh"
    chown "$GS_USER:$GS_GROUP" "${SCRIPTS_DIR}/sleep-listener.sh"
}

# write_wake_instance_script: writes scripts/wake-instance.sh <instance>,
# invoked by the sleep listener the moment a connection arrives.
write_wake_instance_script() {
    cat > "${SCRIPTS_DIR}/wake-instance.sh" << 'EOF'
#!/usr/bin/env bash
# wake-instance.sh <instance-name> - starts the real game server after the
# sleep listener detects a connection attempt. The player's FIRST attempt
# triggers this; it will very likely need to retry/rejoin once the server
# has actually finished booting (this is a fundamental limit of waking a
# cold server, not something this script can paper over).
set -uo pipefail
source /srv/gameservers/scripts/common.sh
load_instance "${1:?instance name required}"

log_info "[$INSTANCE_NAME] Connection detected -- waking the server..."
notify_discord "Instance [$INSTANCE_NAME] is waking up on $(hostname) (someone tried to connect)."
# Deliberately does NOT call 'systemctl stop' on the sleep-listener unit
# here: this script runs as a child process WITHIN that unit's own cgroup
# (spawned by socat), so stopping it from here would send a stop signal to
# our own process too. socat (without 'fork') already releases its
# listening socket as soon as it accepts/receives the single triggering
# connection -- well before this script even runs -- so the port is
# already free by this point; Restart=on-failure then ensures the
# sleep-listener's own subsequent clean exit doesn't restart and re-bind it.
systemctl start "gameserver@${INSTANCE_NAME}" >> "${INSTANCE_LOG_DIR}/on-demand.log" 2>&1
EOF
    chmod 750 "${SCRIPTS_DIR}/wake-instance.sh"
    chown "$GS_USER:$GS_GROUP" "${SCRIPTS_DIR}/wake-instance.sh"
}

# write_idle_monitor_script: writes scripts/idle-monitor.sh, run every
# minute via cron for every on-demand instance that is currently awake.
# Uses profile_get_player_count() when available (precise); otherwise a
# conntrack-based "any recent traffic" heuristic (approximate -- can
# misjudge a quiet-but-connected player as idle, hence the multi-minute
# threshold rather than a single check).
write_idle_monitor_script() {
    cat > "${SCRIPTS_DIR}/idle-monitor.sh" << EOF
#!/usr/bin/env bash
set -uo pipefail
source /srv/gameservers/scripts/common.sh

IDLE_MINUTES_THRESHOLD=${IDLE_MINUTES_THRESHOLD}

while IFS= read -r name; do
    [[ -n "\$name" ]] || continue
    load_instance "\$name"
    [[ "\${ON_DEMAND:-0}" == "1" ]] || continue
    systemctl is-active --quiet "gameserver@\${name}" || continue

    player_count=""
    if declare -F profile_get_player_count >/dev/null; then
        player_count="\$(profile_get_player_count 2>/dev/null || true)"
    fi

    is_idle=0
    if [[ "\$player_count" =~ ^[0-9]+\$ ]]; then
        (( player_count == 0 )) && is_idle=1
    else
        # Fallback heuristic: any conntrack'd traffic to/from this port in
        # roughly the last minute? conntrack entries age out on their own;
        # its mere presence here is "recent" by definition.
        if command -v conntrack >/dev/null 2>&1; then
            if ! conntrack -L --dport "\${SERVER_PORT}" 2>/dev/null | grep -q . \\
               && ! conntrack -L --sport "\${SERVER_PORT}" 2>/dev/null | grep -q .; then
                is_idle=1
            fi
        fi
        # conntrack unavailable: can't determine -- assume NOT idle (safer
        # to keep running than to guess-stop an active session).
    fi

    state_file="\${INSTANCE_TMP_DIR}/idle-streak"
    if [[ "\$is_idle" == "1" ]]; then
        streak=\$(( \$(cat "\$state_file" 2>/dev/null || echo 0) + 1 ))
    else
        streak=0
    fi
    echo "\$streak" > "\$state_file"

    if (( streak >= IDLE_MINUTES_THRESHOLD )); then
        log_info "[\$name] Idle for \${streak} consecutive minute(s); saving and stopping."
        if declare -F profile_trigger_save >/dev/null; then
            profile_trigger_save >> "\${INSTANCE_LOG_DIR}/on-demand.log" 2>&1 || true
            sleep 2
        fi
        systemctl stop "gameserver@\${name}" >> "\${INSTANCE_LOG_DIR}/on-demand.log" 2>&1
        rm -f "\$state_file"
        systemctl start "gameserver-sleep@\${name}" >> "\${INSTANCE_LOG_DIR}/on-demand.log" 2>&1
        notify_discord "Instance [\$name] auto-stopped on \$(hostname) after \${IDLE_MINUTES_THRESHOLD}+ idle minutes."
    fi
done < <(all_instance_names)
EOF
    chmod 750 "${SCRIPTS_DIR}/idle-monitor.sh"
    chown "$GS_USER:$GS_GROUP" "${SCRIPTS_DIR}/idle-monitor.sh"
}

# write_status_dashboard_script: writes scripts/status-dashboard.sh -- a
# unified health-check dashboard that shows host resources and per-instance
# status in a single, color-coded view. Run interactively or pipe to a file.
write_status_dashboard_script() {
    local dashboard_src="${BASE_DIR}/scripts/status-dashboard.sh"
    if [[ -f "$dashboard_src" ]]; then
        cp "$dashboard_src" "${SCRIPTS_DIR}/status-dashboard.sh"
    else
        # Fallback: write inline if source file is missing
        cat > "${SCRIPTS_DIR}/status-dashboard.sh" << 'DASHEOF'
#!/usr/bin/env bash
# status-dashboard.sh [instance-name] -- unified health-check dashboard
set -uo pipefail
source /srv/gameservers/scripts/common.sh
REGISTRY="${GS_BASE}/instances.registry"
C_RESET=$'\033[0m'; C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_BOLD=$'\033[1m'
[[ -f "$REGISTRY" ]] || { log_err "No instances registered."; exit 1; }
host_uptime=$(uptime -p 2>/dev/null || uptime | sed 's/.*up /up /' | sed 's/,.*load.*//')
echo -e "${C_BOLD}=== Game Server Dashboard ===${C_RESET}"
echo "Host: $(hostname)  |  $(date '+%Y-%m-%d %H:%M:%S')  |  Uptime: ${host_uptime}"
load=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "?"); cores=$(nproc 2>/dev/null || echo "?")
ram_used=$(awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{printf "%.0f", ((t-a)/t)*100}' /proc/meminfo 2>/dev/null || echo "?")
disk_pct=$(df /srv/gameservers 2>/dev/null | awk 'NR==2{print $5}' || echo "?")
echo "CPU Load: ${load}  |  RAM: ${ram_used}%  |  Disk: ${disk_pct}%"
echo ""
printf '%-20s %-16s %-10s %-8s %-10s %-14s %s\n' "INSTANCE" "GAME" "STATUS" "PORT" "LISTENING" "UPTIME" "DISK"
printf '%-20s %-16s %-10s %-8s %-10s %-14s %s\n' "--------" "----" "------" "----" "---------" "------" "----"
running=0; stopped=0; total=0
while IFS=: read -r name game port _; do
    [[ -n "$name" ]] || continue; total=$((total + 1))
    svc_status="stopped"; svc_color="$C_RED"
    systemctl is-active --quiet "gameserver@${name}" 2>/dev/null && { svc_status="running"; svc_color="$C_GREEN"; running=$((running + 1)); } || stopped=$((stopped + 1))
    listening="no"; ss -uln 2>/dev/null; ss -tln 2>/dev/null | grep -q ":${port}[[:space:]]" && listening="yes"
    inst_uptime="-"; active_since=$(systemctl show "gameserver@${name}" --property=ActiveEnterTimestamp --value 2>/dev/null || true)
    [[ -n "$active_since" ]] && inst_uptime=$(date -d "$active_since" +'%H:%M:%S' 2>/dev/null || echo "-")
    inst_disk=$(du -sh "/srv/gameservers/instances/${name}" 2>/dev/null | awk '{print $1}' || echo "?")
    printf '%-20s %-16s %b%-10s%b %-8s %-10s %-14s %s\n' "$name" "$game" "$svc_color" "$svc_status" "$C_RESET" "$port" "$listening" "$inst_uptime" "$inst_disk"
done < "$REGISTRY"
echo ""
echo -e "${C_GREEN}${running} running${C_RESET}  |  ${C_RED}${stopped} stopped${C_RESET}  |  ${C_BOLD}${total} total${C_RESET}"
[[ "$stopped" -eq 0 ]] && exit 0 || exit 1
DASHEOF
    fi
    chmod 750 "${SCRIPTS_DIR}/status-dashboard.sh"
    chown "$GS_USER:$GS_GROUP" "${SCRIPTS_DIR}/status-dashboard.sh"
}

# install_systemd_sleep_template: writes the sleep-listener's template
# unit. Restart=on-failure (not "always") is deliberate -- see the
# confidence note in write_sleep_listener_script.
install_systemd_sleep_template() {
    log_step "Installing on-demand sleep-listener systemd template"
    cat > "$SYSTEMD_SLEEP_TEMPLATE_UNIT_PATH" << EOF
[Unit]
Description=Sleep listener (wakes on connect) for game server instance %i
After=network-online.target

[Service]
Type=simple
User=${GS_USER}
Group=${GS_GROUP}
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
    write_status_dashboard_script
    log_ok "Helper scripts written to ${SCRIPTS_DIR}/"
}

###############################################################################
# SYSTEMD TEMPLATE UNIT
###############################################################################

# install_systemd_template: writes ONE templated unit,
# /etc/systemd/system/gameserver@.service -- systemd's "%i" becomes
# whatever instance name follows the @ when started/enabled. The SAME
# template covers every game, native or Wine-based, since the Wine
# branching lives inside start-instance.sh, not the unit file.
install_systemd_template() {
    log_step "Installing systemd template unit"
    # This filename ends in "@.service" -- systemd's convention for a
    # TEMPLATE unit. Instead of writing a separate .service file for every
    # single instance, one template covers ALL of them: starting/enabling
    # "gameserver@myworld" or "gameserver@shard2" reuses this same file,
    # with systemd substituting the part after the @ (the "instance name,"
    # a systemd-specific concept distinct from -- though used here to mean
    # the same thing as -- this platform's own per-shard instance names)
    # everywhere the literal two characters "%i" appear below.
    cat > "$SYSTEMD_TEMPLATE_UNIT_PATH" << EOF
[Unit]
Description=Dedicated Game Server (instance: %i)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=${GS_USER}
Group=${GS_GROUP}
WorkingDirectory=${INSTANCES_DIR}/%i/server

# The leading "+" on ExecStartPre is systemd syntax meaning "run this one
# command as root, ignoring the unit's own User=/Group=" -- necessary
# because fix-permissions.sh needs root to chown files it doesn't already
# own, even though the real game server process (ExecStart, below) still
# runs as the unprivileged gameserver user like every other command in this
# unit that doesn't have a "+".
ExecStartPre=+${SCRIPTS_DIR}/fix-permissions.sh %i
ExecStart=${SCRIPTS_DIR}/start-instance.sh %i

Restart=always
RestartSec=10
KillSignal=SIGTERM
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

# enable_and_start_instance_service: enables and starts one instance's
# systemd unit, then polls for its port(s) to actually bind.
enable_and_start_instance_service() {
    local name="$1" base_port="$2"
    log_step "[$name] Starting service"

    systemctl enable "gameserver@${name}" >>"$LOG_FILE" 2>&1
    systemctl restart "gameserver@${name}"
    log_info "[$name] Waiting for the server to come up..."

    # Polling loop: checks every 5 seconds, up to max_wait seconds total,
    # for the service to both be active AND actually have its port bound --
    # a service can report "active" via systemd well before the game
    # process has finished initializing enough to start listening.
    local waited=0 max_wait=180 port_ready=0 ss_output
    while (( waited < max_wait )); do
        if systemctl is-active --quiet "gameserver@${name}"; then
            ss_output="$(ss -uln 2>/dev/null; ss -tln 2>/dev/null)"
            if grep -q ":${base_port}[[:space:]]" <<< "$ss_output"; then
                port_ready=1; break
            fi
        else
            log_err "[$name] Service is not active. Recent logs:"
            journalctl -u "gameserver@${name}" -n 40 --no-pager >> "$LOG_FILE" 2>&1
            die "[$name] Failed to start. See ${LOG_FILE} and: journalctl -u gameserver@${name} -n 100"
        fi
        sleep 5; waited=$(( waited + 5 )); echo -n "."
    done
    echo

    if [[ "$port_ready" -eq 1 ]]; then
        log_ok "[$name] Active and port ${base_port} is listening (after ~${waited}s)."
    else
        log_warn "[$name] Active, but port ${base_port} was not yet listening after ${max_wait}s (can be normal for a slow first load, especially through Wine). Check later with: status-instance.sh ${name}"
    fi
}

###############################################################################
# configure_firewall_base and remove_firewall_for_instance are provided by
# common.sh. configure_firewall_base takes the SSH port as its argument;
# remove_firewall_for_instance takes the instance's base port.
###############################################################################

# configure_firewall_for_instance: opens every port this instance's game
# profile declares via profile_port_specs (lines of "offset:protocol:desc").
configure_firewall_for_instance() {
    local name="$1" base_port="$2" offset proto desc port
    # profile_port_specs (defined by the active game profile) prints lines
    # of "offset:protocol:description", e.g. "0:udp:game" then "1:tcp:rcon"
    # -- IFS=: read splits each line on ':' into the three variables below.
    # See the process-substitution/while-read explanation in
    # write_service_wrapper_scripts above for why `< <(...)` is used here
    # instead of piping into the loop.
    while IFS=: read -r offset proto desc; do
        [[ -n "$offset" ]] || continue
        port=$(( base_port + offset )) # arithmetic context: (( )) evaluates offset as a number, not text
        # "${proto^^}" uppercases the whole string (bash's built-in
        # case-conversion expansion) -- purely cosmetic, so the log line
        # reads "Allowing UDP 25000" instead of "Allowing udp 25000".
        log_info "[$name] Allowing ${proto^^} ${port} (${desc})..."
        # `|| true` matters here: ufw is idempotent and normally exits 0
        # even for a rule that already exists, but if it ever DID fail
        # (e.g. a transient ufw/iptables hiccup), this is a firewall rule
        # for one port among several -- not something worth aborting the
        # entire instance setup over under `set -e`. Mirrors the same
        # defensive pattern common.sh's configure_firewall_ports() uses.
        ufw allow "${port}/${proto}" comment "gs:${name}:${desc}" >>"$LOG_FILE" 2>&1 || true
    done < <(profile_port_specs)
}

###############################################################################
# FAIL2BAN, LOG ROTATION, and JOURNALD CAP are provided by common.sh.
###############################################################################

###############################################################################
# CRON SCHEDULING
###############################################################################
schedule_cron_jobs() {
    log_step "Scheduling backups, updates, and health checks"

    cat > "$CRON_BACKUP_FILE" << EOF
# Managed by ${SCRIPT_NAME}. Runs every minute (cheap); each instance's own
# BACKUP_TIME decides whether now is actually its scheduled time.
* * * * * ${GS_USER} ${SCRIPTS_DIR}/cron-backup-dispatch.sh
EOF
    chmod 644 "$CRON_BACKUP_FILE"

    cat > "$CRON_UPDATE_FILE" << EOF
# Managed by ${SCRIPT_NAME}. Same dispatch pattern as backups, for updates.
* * * * * root ${SCRIPTS_DIR}/cron-update-dispatch.sh
EOF
    chmod 644 "$CRON_UPDATE_FILE"

    cat > "$CRON_HEALTHCHECK_FILE" << EOF
# Managed by ${SCRIPT_NAME} - health check / self-healing restart, all instances.
*/10 * * * * root ${SCRIPTS_DIR}/healthcheck-instance.sh all >> ${GS_BASE}/instances-healthcheck.log 2>&1
EOF
    chmod 644 "$CRON_HEALTHCHECK_FILE"

    cat > "$CRON_CAPACITY_FILE" << EOF
# Managed by ${SCRIPT_NAME} - host-wide CPU/RAM utilization monitor.
*/15 * * * * ${GS_USER} ${SCRIPTS_DIR}/host-capacity-monitor.sh
EOF
    chmod 644 "$CRON_CAPACITY_FILE"

    cat > "$CRON_IDLE_FILE" << EOF
# Managed by ${SCRIPT_NAME} - on-demand idle detection (auto-save + auto-stop).
* * * * * root ${SCRIPTS_DIR}/idle-monitor.sh >> ${GS_BASE}/idle-monitor.log 2>&1
EOF
    chmod 644 "$CRON_IDLE_FILE"

    systemctl reload cron >>"$LOG_FILE" 2>&1 || systemctl restart cron >>"$LOG_FILE" 2>&1 || true
    log_ok "Cron scheduling installed."
}

# write_cron_dispatch_scripts: writes the two dispatcher scripts cron
# actually calls every minute, each checking EVERY instance's own
# BACKUP_TIME/UPDATE_TIME against the current HH:MM.
write_cron_dispatch_scripts() {
    cat > "${SCRIPTS_DIR}/cron-backup-dispatch.sh" << 'EOF'
#!/usr/bin/env bash
set -uo pipefail
source /srv/gameservers/scripts/common.sh
now_hhmm="$(date '+%H:%M')"
while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    load_instance "$name"
    if [[ "${BACKUP_TIME:-}" == "$now_hhmm" ]]; then
        /srv/gameservers/scripts/backup-instance.sh "$name"
    fi
done < <(all_instance_names)
EOF
    cat > "${SCRIPTS_DIR}/cron-update-dispatch.sh" << 'EOF'
#!/usr/bin/env bash
set -uo pipefail
source /srv/gameservers/scripts/common.sh
now_hhmm="$(date '+%H:%M')"
while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    load_instance "$name"
    if [[ "${UPDATE_TIME:-}" == "$now_hhmm" ]]; then
        /srv/gameservers/scripts/update-instance.sh "$name"
    fi
done < <(all_instance_names)
EOF
    chmod 750 "${SCRIPTS_DIR}/cron-backup-dispatch.sh" "${SCRIPTS_DIR}/cron-update-dispatch.sh"
    chown "$GS_USER:$GS_GROUP" "${SCRIPTS_DIR}/cron-backup-dispatch.sh" "${SCRIPTS_DIR}/cron-update-dispatch.sh"
}

###############################################################################
# INSTANCE ORCHESTRATION: add / remove / list
###############################################################################

# add_instance: the full flow for bringing up one new shard of the given
# game -- gather input, allocate a port, sync from golden, write config,
# register it, wire up systemd/firewall, start it, print a summary.
add_instance() {
    local game_id="$1" suggested_name="${2:-}"

    load_game_profile "$game_id"

    gather_generic_instance_input "$suggested_name"

    # --- DRY RUN: show what WOULD happen, then stop -- deliberately
    # BEFORE any of ensure_wine_installed/ensure_java_installed/
    # ensure_xvfb_installed/install_or_update_golden below, since those
    # perform real apt-get/steamcmd operations. Nothing above this point
    # (profile loading, prompting) has any real side effect. ---
    if [[ "$DRY_RUN" -eq 1 ]]; then
        local dry_name="${INSTANCE_NAME}"
        local dry_port="${SERVER_PORT}"
        local dry_on_demand="${ON_DEMAND}"
        local dry_backup_dir="${BACKUP_DIR}"
        local dry_game_id="${game_id}"
        local avail_mb
        avail_mb="$(df --output=avail -m /srv 2>/dev/null | tail -n1 | tr -d '[:space:]')"
        echo
        echo -e "${C_BOLD}========== DRY RUN -- nothing has been changed ==========${C_RESET}"
        echo
        echo "  Instance name:     ${dry_name}"
        echo "  Game:              ${PROFILE_DISPLAY_NAME} (${dry_game_id})"
        echo "  Base port:         ${dry_port}"
        local dry_offset dry_proto dry_desc dry_p
        while IFS=: read -r dry_offset dry_proto dry_desc; do
            [[ -n "$dry_offset" ]] || continue
            dry_p=$(( dry_port + dry_offset ))
            echo "    - ${dry_p}/${dry_proto}  (${dry_desc})"
        done < <(profile_port_specs)
        echo "  On-demand:         $([ "$dry_on_demand" == "1" ] && echo "yes (sleep listener)" || echo "no (always running)")"
        echo "  Firewall:          ufw allow for each port above"
        echo "  Backup dir:        ${dry_backup_dir}"
        echo "  Backup schedule:   daily at ${BACKUP_TIME}, ${BACKUP_RETENTION_DAYS}-day retention"
        echo "  Update schedule:   daily at ${UPDATE_TIME}"
        echo "  Disk available:    ${avail_mb:-unknown} MB on /srv"
        echo
        echo -e "${C_BOLD}To proceed for real, re-run without --dry-run:${C_RESET}"
        echo "  ./${SCRIPT_NAME} --game ${game_id} --add-instance ${dry_name}"
        echo
        return 0
    fi
    # --- END DRY RUN ---

    if [[ "${PROFILE_REQUIRES_WINE}" == "1" ]]; then
        ensure_wine_installed
    fi
    if [[ "${PROFILE_REQUIRES_JAVA:-0}" == "1" ]]; then
        ensure_java_installed
    fi
    if [[ "${PROFILE_REQUIRES_XVFB:-0}" == "1" ]]; then
        ensure_xvfb_installed
    fi

    install_or_update_golden "$game_id"

    create_instance_directories "$INSTANCE_NAME"
    # From this point on, a directory exists for this instance name but
    # it isn't registered yet -- if anything below fails, on_error can
    # now safely recognize this as a half-created attempt, not a real,
    # already-in-use instance, and clean it up automatically.
    PARTIAL_INSTANCE_NAME="$INSTANCE_NAME"

    sync_instance_from_golden "$INSTANCE_NAME" "$game_id"

    write_instance_config "$INSTANCE_NAME" "$game_id"
    registry_add "$INSTANCE_NAME" "$game_id" "$SERVER_PORT"
    # The instance is now genuinely real and tracked -- from this point
    # forward, a failure should NOT delete its directory (a failure in,
    # say, starting the systemd service, is something to fix and retry,
    # not a reason to lose this instance's data).
    PARTIAL_INSTANCE_REGISTERED=1

    configure_firewall_for_instance "$INSTANCE_NAME" "$SERVER_PORT"

    if [[ "$ON_DEMAND" == "1" ]]; then
        log_step "[$INSTANCE_NAME] Enabling on-demand mode (sleeping until a player connects)"
        systemctl enable "gameserver@${INSTANCE_NAME}" >>"$LOG_FILE" 2>&1
        systemctl enable --now "gameserver-sleep@${INSTANCE_NAME}" >>"$LOG_FILE" 2>&1
        if systemctl is-active --quiet "gameserver-sleep@${INSTANCE_NAME}"; then
            log_ok "[$INSTANCE_NAME] Sleeping -- will wake automatically on the first connection to port ${SERVER_PORT}."
        else
            log_warn "[$INSTANCE_NAME] Sleep listener did not start; check 'systemctl status gameserver-sleep@${INSTANCE_NAME}'."
        fi
    else
        enable_and_start_instance_service "$INSTANCE_NAME" "$SERVER_PORT"
    fi

    print_instance_summary "$INSTANCE_NAME" "$game_id"
}

# remove_instance: stops/disables one instance's service, removes its
# firewall rules and registry entry, then asks (separately) whether to
# also delete its data.
remove_instance() {
    local name="$1"
    # Validate before this name is used inside grep/sed patterns in the
    # registry_* helpers below -- an unvalidated --remove-instance value
    # could otherwise contain regex metacharacters. A name like ".*" would
    # make registry_has() match any line (bypassing the "no such instance"
    # error right below) and make registry_remove()'s sed delete every
    # line in instances.registry, wiping the whole fleet's bookkeeping.
    validate_instance_name "$name" >/dev/null \
        || die "Instance name '${name}' is invalid: letters, numbers, '_', '-' only, 1-32 characters."
    registry_has "$name" || die "No instance named '${name}' is registered. Use --list-instances to see what exists."

    local port game_id
    port="$(registry_port_for "$name")"
    game_id="$(registry_game_for "$name")"

    # --- DRY RUN: show what WOULD happen, then stop -- no service is
    # touched, no firewall rule is removed, no registry entry is deleted,
    # and no data directory is examined for removal. ---
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo
        echo -e "${C_BOLD}========== DRY RUN -- nothing has been changed ==========${C_RESET}"
        echo
        echo "  Instance name:     ${name}"
        echo "  Game:              ${game_id:-unknown}"
        echo "  Port:              ${port:-unknown}"
        echo "  Would stop:        gameserver@${name}, gameserver-sleep@${name}"
        echo "  Would disable:     gameserver@${name}, gameserver-sleep@${name}"
        if [[ -n "$port" && -n "$game_id" ]]; then
            echo "  Would remove:      firewall rule(s) for port ${port}"
        fi
        echo "  Would remove:      registry entry for '${name}'"
        echo "  Data directory:    $(instance_dir "$name") (you would be asked before this is deleted)"
        echo
        echo -e "${C_BOLD}To proceed for real, re-run without --dry-run:${C_RESET}"
        echo "  ./${SCRIPT_NAME} --remove-instance ${name}"
        echo
        return 0
    fi
    # --- END DRY RUN ---

    log_step "Removing instance '${name}'"
    # Try to load the game profile so we know how to tear down firewall
    # rules. If the profile is missing (e.g. it was deleted), log a
    # warning but do NOT abort -- cleanup must still proceed.
    if [[ -n "$game_id" ]]; then
        if ! load_game_profile "$game_id" 2>/dev/null; then
            log_warn "Game profile '${game_id}' for instance '${name}' is missing; firewall rules may need manual cleanup."
        fi
    fi

    systemctl stop "gameserver@${name}" 2>>"$LOG_FILE" || true
    systemctl disable "gameserver@${name}" 2>>"$LOG_FILE" || true
    systemctl stop "gameserver-sleep@${name}" 2>>"$LOG_FILE" || true
    systemctl disable "gameserver-sleep@${name}" 2>>"$LOG_FILE" || true

    if [[ -n "$port" && -n "$game_id" ]]; then
        remove_firewall_for_instance "$port"
    fi
    registry_remove "$name"
    log_ok "Service, firewall rules, and registry entry removed for '${name}'."

    # In non-interactive mode, preserve data by default to avoid
    # accidental deletion. In interactive mode, ask the user.
    local confirm=""
    if [[ "${ASSUME_DEFAULTS:-0}" -eq 1 ]]; then
        log_info "Non-interactive mode: preserving data at $(instance_dir "$name")."
    else
        read -r -p "Also DELETE all data for '${name}' (world/save data, backups, logs)? Type 'yes' to confirm: " confirm < /dev/tty || true
    fi
    if [[ "$confirm" == "yes" ]]; then
        rm -rf "$(instance_dir "$name")"
        log_ok "Removed $(instance_dir "$name")."
    else
        log_ok "Data preserved at $(instance_dir "$name")."
    fi
}

# list_instances: prints a quick table of every registered instance.
# list_instances_verbose_row: prints one instance's disk/RAM/uptime line
# for `--list-instances --verbose`. Kept as its own function (rather than
# inlined into list_instances) so it's easy to reason about in isolation --
# every value here comes from a live check (systemctl/du), not the
# registry, so it reflects the instance's CURRENT state, not what was
# true when it was added.
list_instances_verbose_row() {
    local name="$1"
    local svc_status="stopped" uptime_text="-" mem_text="n/a" disk_text="N/A"

    if systemctl is-active --quiet "gameserver@${name}" 2>/dev/null; then
        svc_status="running"

        local active_since active_epoch now_epoch uptime_sec
        active_since="$(systemctl show "gameserver@${name}" --property=ActiveEnterTimestamp --value 2>/dev/null || true)"
        if [[ -n "$active_since" ]]; then
            active_epoch="$(date -d "$active_since" +%s 2>/dev/null || echo 0)"
            now_epoch="$(date +%s)"
            uptime_sec=$(( now_epoch - active_epoch ))
            if [[ "$active_epoch" -gt 0 && "$uptime_sec" -ge 0 ]]; then
                if [[ "$uptime_sec" -lt 60 ]]; then
                    uptime_text="<1m"
                elif [[ "$uptime_sec" -lt 3600 ]]; then
                    uptime_text="$(( uptime_sec / 60 ))m"
                elif [[ "$uptime_sec" -lt 86400 ]]; then
                    uptime_text="$(( uptime_sec / 3600 ))h $(( (uptime_sec % 3600) / 60 ))m"
                else
                    uptime_text="$(( uptime_sec / 86400 ))d $(( (uptime_sec % 86400) / 3600 ))h"
                fi
            fi
        fi

        # MemoryCurrent is systemd's cgroup memory accounting for this
        # service's processes; it reads "[not set]" if accounting is off
        # (e.g. cgroup v1 without memory controller enabled) -- fall back
        # to "n/a" rather than showing that raw systemd string.
        local mem_bytes
        mem_bytes="$(systemctl show "gameserver@${name}" --property=MemoryCurrent --value 2>/dev/null || true)"
        if [[ "$mem_bytes" =~ ^[0-9]+$ ]]; then
            mem_text="$(( mem_bytes / 1024 / 1024 )) MB"
        fi
    fi

    local inst_dir
    inst_dir="$(instance_dir "$name")"
    if [[ -d "$inst_dir" ]]; then
        disk_text="$(du -sh "$inst_dir" 2>/dev/null | awk '{print $1}')"
        [[ -n "$disk_text" ]] || disk_text="N/A"
    fi

    printf '  %-16s status=%-8s uptime=%-10s mem=%-8s disk=%s\n' \
        "$name" "$svc_status" "$uptime_text" "$mem_text" "$disk_text"
}

list_instances() {
    if ! registry_base_exists; then
        echo "Nothing installed yet. Run the installer first: ./${SCRIPT_NAME} --game <game>"
        return 0
    fi
    registry_ensure
    if [[ ! -s "$INSTANCE_REGISTRY" ]]; then
        echo "No instances configured yet. Add one with: ./${SCRIPT_NAME} --game <game> --add-instance <name>"
        return 0
    fi
    echo "Registered instances:"
    printf '%-16s %-14s %-8s %s\n' "NAME" "GAME" "PORT" "CREATED"
    awk -F: '{printf "%-16s %-14s %-8s %s\n", $1, $2, $3, $4}' "$INSTANCE_REGISTRY"

    if [[ "$VERBOSE_MODE" -eq 1 ]]; then
        echo
        echo "Live details (status/uptime/memory/disk):"
        local vname
        while IFS=: read -r vname _ _ _; do
            [[ -n "$vname" ]] || continue
            list_instances_verbose_row "$vname"
        done < "$INSTANCE_REGISTRY"
    fi

    echo
    echo "For live status: sudo ${SCRIPTS_DIR}/status-instance.sh"
}

# list_games: prints every installed game profile with its display name.
list_games() {
    if [[ ! -d "$PROFILES_DIR" ]]; then
        echo "Nothing installed yet. Run the installer first: ./${SCRIPT_NAME} --game <game>"
        return 0
    fi
    echo "Available game profiles:"
    local g
    for g in $(list_available_games); do
        load_game_profile "$g"
        local wine_note=""
        if [[ "$PROFILE_REQUIRES_WINE" == "1" ]]; then
            wine_note=" (Windows-only, runs via Wine)"
        fi
        printf '  %-16s %s%s\n' "$g" "$PROFILE_DISPLAY_NAME" "$wine_note"
    done
}

###############################################################################
# Network information gathering (gather_network_info) is provided by common.sh.
###############################################################################

###############################################################################
# PER-INSTANCE SUMMARY
###############################################################################

# print_instance_summary: the connection/status report for one just-added
# instance, including every port profile_port_specs declares.
print_instance_summary() {
    local name="$1" game_id="$2"
    local status_phrase="is up and running"
    if [[ "$ON_DEMAND" == "1" ]]; then
        status_phrase="is configured (sleeping until first connection)"
    fi
    echo
    echo -e "${C_BOLD}==============================================================="
    echo "  Instance '${name}' (${PROFILE_DISPLAY_NAME}) ${status_phrase}"
    echo -e "===============================================================${C_RESET}"
    echo
    echo "  Game:            ${PROFILE_DISPLAY_NAME} (${game_id})"
    echo "  Base port:       ${SERVER_PORT}"
    local offset proto desc port
    while IFS=: read -r offset proto desc; do
        [[ -n "$offset" ]] || continue
        port=$(( SERVER_PORT + offset ))
        echo "    - ${port}/${proto}  (${desc})"
    done < <(profile_port_specs)
    if [[ "$PROFILE_REQUIRES_WINE" == "1" ]]; then
        echo "  Runtime:         Windows binary via Wine (no native Linux build for this game)"
    fi
    if [[ "$ON_DEMAND" == "1" ]]; then
        echo "  On-demand:       yes -- sleeping now; wakes on first connection, auto-saves"
        echo "                   and stops after ${IDLE_MINUTES_THRESHOLD} idle minutes (first join attempt after"
        echo "                   waking may need a retry once the server finishes booting)"
    fi
    echo "  LAN IP:          ${LAN_IP}"
    if [[ -n "${PUBLIC_IP:-}" ]]; then
        echo "  Public IP:       ${PUBLIC_IP}  (requires port forwarding for remote players)"
    fi
    echo "  Backup schedule: daily at ${BACKUP_TIME}, ${BACKUP_RETENTION_DAYS}-day retention, in ${BACKUP_DIR}"
    echo "  Update schedule: daily check at ${UPDATE_TIME}"
    echo
    echo -e "${C_BOLD}Manage this instance:${C_RESET}"
    echo "  sudo systemctl status  gameserver@${name}"
    echo "  sudo systemctl restart gameserver@${name}"
    echo "  journalctl -u gameserver@${name} -f"
    echo "  sudo ${SCRIPTS_DIR}/status-instance.sh ${name}"
    echo
    echo "  Add another shard:  ./${SCRIPT_NAME} --game <game> --add-instance <name>"
    echo "  List all shards:    ./${SCRIPT_NAME} --list-instances"
    echo "  Full install log:   ${LOG_FILE}"
    echo
    if declare -F profile_post_start_notes >/dev/null; then
        profile_post_start_notes
    fi
}

###############################################################################
# BASE (SHARED) INSTALL
###############################################################################

# ensure_base_install: everything shared across every game/instance --
# packages, the 'gameserver' user, the base directory layout, game
# profiles, SteamCMD, every helper script, the systemd template, base
# firewall rules, fail2ban, logrotate, the journald cap, and cron. Runs
# (safely, idempotently) before every add_instance call.
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

    create_gameserver_user
    create_base_directory_layout
    install_profiles

    install_steamcmd

    write_all_helper_scripts
    write_cron_dispatch_scripts

    install_systemd_template
    install_systemd_sleep_template

    # Detect the SSH port to pass to the shared firewall setup function.
    local ssh_port=22 # default SSH port
    if [[ -r /etc/ssh/sshd_config ]]; then # if sshd_config is readable
        local configured_ssh_port # declare variable for the detected port
        configured_ssh_port="$(awk '/^[Pp]ort[ \t]+[0-9]+/{print $2; exit}' /etc/ssh/sshd_config || true)" # extract it
        if [[ -n "$configured_ssh_port" ]]; then # if a custom port was found
            ssh_port="$configured_ssh_port" # use the custom port
        fi # end of the custom-port check
    fi # end of the sshd_config check
    configure_firewall_base "$ssh_port"
    configure_fail2ban "$FAIL2BAN_JAIL_LOCAL" "$ssh_port"
    configure_logrotate
    configure_journald_limit
    schedule_cron_jobs

    gather_network_info
}

###############################################################################
# FULL UNINSTALL
###############################################################################
uninstall_everything() {
    require_root
    registry_ensure

    # --- DRY RUN: show what WOULD happen, then stop -- no service is
    # stopped/disabled, no firewall rule or cron file is removed, and no
    # data is touched. ---
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo
        echo -e "${C_BOLD}========== DRY RUN -- nothing has been changed ==========${C_RESET}"
        echo
        if [[ -f "$INSTANCE_REGISTRY" && -s "$INSTANCE_REGISTRY" ]]; then
            echo "  Would stop/disable the following instances:"
            while IFS=: read -r name game port _; do
                [[ -n "$name" ]] || continue
                echo "    - ${name} (${game:-unknown game}, port ${port:-unknown})"
            done < "$INSTANCE_REGISTRY"
        else
            echo "  No instances currently registered."
        fi
        echo "  Would remove:      systemd templates (${SYSTEMD_TEMPLATE_UNIT_PATH}, ${SYSTEMD_SLEEP_TEMPLATE_UNIT_PATH})"
        echo "  Would remove:      cron files (${CRON_BACKUP_FILE}, ${CRON_UPDATE_FILE}, ${CRON_HEALTHCHECK_FILE}, ${CRON_CAPACITY_FILE}, ${CRON_IDLE_FILE})"
        echo "  Would remove:      logrotate config (${LOGROTATE_CONF})"
        echo "  Would leave alone: fail2ban, Wine (not touched by uninstall)"
        echo "  Data under ${GS_BASE}: you would be asked before this is deleted"
        echo
        echo -e "${C_BOLD}To proceed for real, re-run without --dry-run:${C_RESET}"
        echo "  ./${SCRIPT_NAME} --uninstall"
        echo
        return 0
    fi
    # --- END DRY RUN ---

    init_logging "$LOG_FILE" "$SCRIPT_NAME"
    log_step "Uninstalling everything"

    if [[ -f "$INSTANCE_REGISTRY" ]]; then
        while IFS=: read -r name game port _; do
            [[ -n "$name" ]] || continue
            log_info "Stopping and disabling instance '${name}'..."
            systemctl stop "gameserver@${name}" 2>>"$LOG_FILE" || true
            systemctl disable "gameserver@${name}" 2>>"$LOG_FILE" || true
            systemctl stop "gameserver-sleep@${name}" 2>>"$LOG_FILE" || true
            systemctl disable "gameserver-sleep@${name}" 2>>"$LOG_FILE" || true
            if [[ -n "$game" && -f "${PROFILES_DIR}/${game}.profile.sh" ]]; then
                load_game_profile "$game"
                if [[ -n "$port" ]]; then
                    remove_firewall_for_instance "$port"
                fi
            fi
        done < "$INSTANCE_REGISTRY"
    fi

    rm -f "$SYSTEMD_TEMPLATE_UNIT_PATH" "$SYSTEMD_SLEEP_TEMPLATE_UNIT_PATH"
    systemctl daemon-reload
    rm -f "$CRON_BACKUP_FILE" "$CRON_UPDATE_FILE" "$CRON_HEALTHCHECK_FILE" "$CRON_CAPACITY_FILE" "$CRON_IDLE_FILE"
    rm -f "$LOGROTATE_CONF"
    log_ok "Services, schedules, and firewall rules removed for every instance."
    log_info "Note: fail2ban and its SSH jail (${FAIL2BAN_JAIL_LOCAL}) are left in place -- uninstalling shouldn't weaken your SSH protection. Remove it yourself with 'sudo apt remove fail2ban' if you no longer want it."
    log_info "Note: Wine (if installed) is also left in place -- remove with 'sudo apt remove wine64 wine32:i386' if desired."

    local confirm=""
    read -r -p "Also DELETE ALL data (every instance's saves/backups/logs, plus every game's shared install) under ${GS_BASE}? Type 'yes' to confirm: " confirm < /dev/tty || true
    if [[ "$confirm" == "yes" ]]; then
        rm -rf "$GS_BASE"
        log_ok "Removed ${GS_BASE}."
        local remove_user=""
        read -r -p "Also remove the '${GS_USER}' system user? [y/N]: " remove_user < /dev/tty || true
        if [[ "${remove_user,,}" =~ ^y ]]; then
            userdel "$GS_USER" 2>>"$LOG_FILE" || true
            groupdel "$GS_GROUP" 2>>"$LOG_FILE" || true
            log_ok "Removed user/group '${GS_USER}'."
        fi
    else
        log_ok "All instance data preserved under ${GS_BASE}."
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

First run for a game (installs shared prerequisites + your first instance):
  ./${SCRIPT_NAME} --game <game>

Not sure if this server is ready? Check first, without changing anything:
  ./${SCRIPT_NAME} --check [--game <game>]

Options:
  --check                     Check this server WITHOUT installing or
                               changing anything (OS, architecture, internet,
                               RAM, disk; add --game to also check that
                               game's specific recommendations). Safe to run
                               as many times as you like, doesn't need sudo.
  --game <game>              Which game profile to use (required with --add-instance).
  --add-instance <name>      Add a shard of --game (prompts for its settings).
  --remove-instance <name>   Stop and remove one shard (asks before deleting data).
  --list-instances           List every configured shard, across all games.
  --verbose                  With --list-instances, also show each shard's
                              live status/uptime/memory/disk usage.
  --list-games                List every available game profile.
  --validate-profile <game>   Check one profile file satisfies the platform's
                               contract (required variables/functions), and
                               exit. For contributors writing a new profile;
                               doesn't need sudo, installs nothing.
  --uninstall                 Remove everything (asks before deleting data).
  --status                    Show the health-check dashboard for all instances
                               (run status-dashboard.sh directly with --json
                               for machine-readable output).
  --dry-run                   Preview what --add-instance, --remove-instance,
                               or --uninstall WOULD do, without doing it.
  --version                   Print the script version and exit.
  -y, --yes                   Non-interactive: accept defaults / generate a
                               random password instead of prompting.
  -h, --help                  Show this help message and exit.
EOF
}

# run_environment_check: the --check dry-run mode. Confirms this machine
# meets the platform's basic requirements (and, if --game was also given,
# that specific game's own recommendations) WITHOUT installing or
# changing anything at all -- no packages, no users, no files written
# outside of this platform's own log. Deliberately does not require root,
# since it's entirely read-only, and is meant to be safe to run first,
# by anyone, before committing to a real install.
run_environment_check() {
    local requested_game="${1:-}"
    print_banner
    echo -e "${C_BOLD}Check-only mode: nothing will be installed or changed.${C_RESET}"
    echo

    local all_ok=1

    log_step "Checking operating system"
    if detect_os_release && [[ "$OS_ID" == "ubuntu" ]]; then
        log_ok "Ubuntu ${OS_VERSION_ID} detected."
        [[ "$OS_IS_LTS" -eq 1 ]] || log_warn "Not an LTS release -- should still work, but LTS is recommended."
    else
        log_err "This does not look like Ubuntu (detected: ${OS_ID:-unknown}). This platform requires Ubuntu."
        all_ok=0
    fi

    log_step "Checking CPU architecture"
    local arch; arch="$(uname -m)"
    if [[ "$arch" == "x86_64" ]]; then
        log_ok "Architecture: ${arch}"
    else
        log_err "Architecture is ${arch}; this platform requires x86_64 (64-bit Intel/AMD)."
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
        log_err "${ram_mb} MB RAM detected; at least ${MIN_RAM_MB_HARD} MB is required just for the platform itself."
        all_ok=0
    else
        log_ok "${ram_mb} MB RAM detected."
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

    if [[ -n "$requested_game" ]]; then
        echo
        log_step "Checking game-specific requirements: ${requested_game}"
        local profile_file="${SCRIPT_DIR}/profiles/${requested_game}.profile.sh"
        if [[ -f "$profile_file" ]]; then
            # shellcheck source=/dev/null
            source "$profile_file"
            log_ok "Profile found: ${PROFILE_DISPLAY_NAME}"

            if [[ -n "${PROFILE_RECOMMENDED_RAM_MB:-}" ]]; then
                if (( ram_mb >= PROFILE_RECOMMENDED_RAM_MB )); then
                    log_ok "RAM: ${ram_mb}MB meets ${PROFILE_DISPLAY_NAME}'s recommended ${PROFILE_RECOMMENDED_RAM_MB}MB."
                else
                    log_warn "RAM: ${ram_mb}MB is BELOW ${PROFILE_DISPLAY_NAME}'s recommended ${PROFILE_RECOMMENDED_RAM_MB}MB."
                    log_warn "It would likely still install, but may run poorly or crash under real load."
                fi
            fi

            if [[ "${PROFILE_REQUIRES_WINE:-0}" == "1" ]]; then
                log_warn "${PROFILE_DISPLAY_NAME} has no native Linux server -- it runs via Wine, a"
                log_warn "genuinely more fragile setup than a native game. Expect higher CPU overhead."
            fi
        else
            log_err "No profile found for game '${requested_game}'. Run --list-games to see what's available."
            all_ok=0
        fi
    fi

    echo
    if [[ "$all_ok" -eq 1 ]]; then
        echo -e "${C_GREEN}${C_BOLD}This server looks ready.${C_RESET} Nothing was changed by this check. When ready:"
        if [[ -n "$requested_game" ]]; then
            echo "  ./${SCRIPT_NAME} --game ${requested_game} --add-instance <name>"
        else
            echo "  ./${SCRIPT_NAME} --game <game> --add-instance <name>"
        fi
    else
        echo -e "${C_RED}${C_BOLD}One or more checks failed${C_RESET} -- see the [FAIL] lines above. Fix those before installing for real."
    fi
    exit $(( 1 - all_ok ))
}

GAME_ID=""
ADD_INSTANCE_NAME=""
REMOVE_INSTANCE_NAME=""
LIST_INSTANCES_MODE=0
LIST_GAMES_MODE=0
UNINSTALL_MODE=0
CHECK_MODE=0
STATUS_MODE=0
VERBOSE_MODE=0    # when set to 1 via --verbose, --list-instances also shows live disk/RAM/uptime per instance
VALIDATE_PROFILE_GAME=""  # set via --validate-profile <game>: standalone profile contract check, no install

# parse_args: interprets every CLI option above.
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes) ASSUME_DEFAULTS=1 ;;
            --dry-run) DRY_RUN=1 ;;
            --version) echo "${SCRIPT_NAME} v${SCRIPT_VERSION}"; exit 0 ;;
            --status) STATUS_MODE=1 ;;
            --game)
                # "${2:0:1}" is SUBSTRING expansion: "${var:OFFSET:LENGTH}"
                # extracts LENGTH characters starting at OFFSET. Here it
                # grabs just the first character of $2 -- if $2 is missing
                # entirely (":-" default kicks in as empty) OR starts with
                # "-", that means no real value followed --game (the user
                # probably typed another flag right after it by mistake),
                # so this reports a clear error instead of swallowing the
                # next flag as if it were a game id.
                if [[ -z "${2:-}" || "${2:0:1}" == "-" ]]; then
                    echo "Error: --game requires a game id, e.g. --game terraria" >&2
                    exit 1
                fi
                GAME_ID="$2"; shift # consume the value too (on top of the shift at the loop's end, this eats both --game and its value)
                ;;
            --add-instance)
                # --add-instance <name> is documented as required to add a
                # shard, but --game <game> alone (no --add-instance at all)
                # is also accepted and behaves identically -- the flag here
                # only exists to optionally capture the instance NAME that
                # follows it, not to gate whether an instance gets added.
                if [[ -n "${2:-}" && "${2:0:1}" != "-" ]]; then
                    ADD_INSTANCE_NAME="$2"; shift
                fi
                ;;
            --remove-instance)
                if [[ -z "${2:-}" || "${2:0:1}" == "-" ]]; then
                    echo "Error: --remove-instance requires a name, e.g. --remove-instance shard2" >&2
                    exit 1
                fi
                REMOVE_INSTANCE_NAME="$2"; shift
                ;;
            --list-instances) LIST_INSTANCES_MODE=1 ;;
            --verbose) VERBOSE_MODE=1 ;;
            --list-games) LIST_GAMES_MODE=1 ;;
            --uninstall) UNINSTALL_MODE=1 ;;
            --check) CHECK_MODE=1 ;;
            --validate-profile)
                if [[ -z "${2:-}" || "${2:0:1}" == "-" ]]; then
                    echo "Error: --validate-profile requires a game id, e.g. --validate-profile terraria" >&2
                    exit 1
                fi
                VALIDATE_PROFILE_GAME="$2"; shift
                ;;
            -h|--help) print_usage; exit 0 ;;
            *) echo "Unknown option: $1" >&2; print_usage; exit 1 ;;
        esac
        shift
    done
}

# main: orchestrates everything -- uninstall / list / remove / add-instance,
# in that order of precedence.
main() {
    ORIGINAL_ARGS_STRING="$*"
    parse_args "$@"

    if [[ "$CHECK_MODE" -eq 1 ]]; then
        run_environment_check "$GAME_ID"
        return
    fi

    if [[ -n "$VALIDATE_PROFILE_GAME" ]]; then
        validate_profile_standalone "$VALIDATE_PROFILE_GAME"
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

    if [[ "$LIST_GAMES_MODE" -eq 1 ]]; then
        if ! registry_base_exists; then
            log_info "Base platform not installed yet; listing bundled profiles from this script instead."
            local f
            for f in "${SCRIPT_DIR}/profiles"/*.profile.sh; do
                [[ -e "$f" ]] || continue
                basename "$f" .profile.sh
            done
        else
            list_games
        fi
        return
    fi

    if [[ "$STATUS_MODE" -eq 1 ]]; then
        if [[ -x "${SCRIPTS_DIR}/status-dashboard.sh" ]]; then
            exec "${SCRIPTS_DIR}/status-dashboard.sh"
        else
            die "Status dashboard not found at ${SCRIPTS_DIR}/status-dashboard.sh. Run the installer first."
        fi
    fi

    if [[ -n "$REMOVE_INSTANCE_NAME" ]]; then
        init_logging "$LOG_FILE" "$SCRIPT_NAME"
        remove_instance "$REMOVE_INSTANCE_NAME"
        return
    fi

    [[ -n "$GAME_ID" ]] || die "Please specify a game: ./${SCRIPT_NAME} --game <game> [--add-instance <name>]  (see --list-games)"

    print_banner
    init_logging "$LOG_FILE" "$SCRIPT_NAME"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_info "--dry-run: skipping ensure_base_install (packages, user, systemd, firewall, fail2ban, cron, etc.) -- nothing on this machine will be changed."
    else
        ensure_base_install
    fi
    add_instance "$GAME_ID" "$ADD_INSTANCE_NAME"
    log_line "Installer finished successfully (game: ${GAME_ID}, instance: ${INSTANCE_NAME})."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

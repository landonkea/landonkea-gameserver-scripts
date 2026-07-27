#!/usr/bin/env bash
###############################################################################
# common.sh -- Shared Bash library for all game-server installer scripts.
#
# This file is meant to be SOURCED (not executed directly) by other scripts:
#   source /path/to/lib/common.sh [BASE_DIR]
#
# It provides every duplicated function used across installer scripts:
# logging, validation, pre-flight checks, package management, network
# discovery, and path helpers. No functions are called automatically --
# callers pick exactly which functions they need.
#
# BASE_DIR can optionally be passed as the first argument when sourcing.
# If provided, instance path helpers will use $BASE_DIR/srv/gameservers
# as their root. If omitted, callers must set BASE_DIR before calling
# path helpers, or set INSTANCES_DIR/GS_BASE directly after sourcing.
###############################################################################

###############################################################################
# BASE DIRECTORY SETUP
# When this file is sourced with an argument, that argument becomes
# BASE_DIR so callers can override where files live on disk.
###############################################################################

# BASE_DIR is the project root the caller wants paths rooted under.
# If no argument was passed, default to the caller's own script directory.
# shellcheck disable=SC2034
if [[ -n "${1:-}" ]]; then # if the caller passed a base directory argument
    BASE_DIR="$1"         # set BASE_DIR to whatever they gave us
else                      # otherwise, if no argument was passed
    BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" # default to the repo root (parent of lib/)
fi                        # end of the BASE_DIR argument check

###############################################################################
# COLOR / LOGGING SETUP
# Detect whether stdout is a real terminal; if so, define ANSI escape codes
# for colored output. If not (e.g. output is piped to a file), define them
# as empty strings so no garbage characters appear in logs.
###############################################################################

# [[ -t 1 ]] tests if file descriptor 1 (stdout) is connected to a terminal.
# If it is, we can safely use color codes; if not, we skip them.
if [[ -t 1 ]]; then # check if stdout is an interactive terminal

    C_RESET='\033[0m'    # resets all text formatting back to default

    C_RED='\033[0;31m'   # red text for error messages (FAIL)

    C_GREEN='\033[0;32m' # green text for success messages (OK)

    C_YELLOW='\033[0;33m' # yellow text for warning messages (WARN)

    C_BLUE='\033[0;34m'  # blue text for informational messages (INFO)

    C_BOLD='\033[1m'     # bold text for section headers and emphasis

else # stdout is NOT a terminal (e.g. piped to a file or another command)

    C_RESET=''           # empty string -- no formatting when not a terminal

    C_RED=''             # empty string -- no red color when not a terminal

    C_GREEN=''           # empty string -- no green color when not a terminal

    C_YELLOW=''          # empty string -- no yellow color when not a terminal

    C_BLUE=''            # empty string -- no blue color when not a terminal

    C_BOLD=''            # empty string -- no bold formatting when not a terminal

fi                       # end of the terminal detection block

###############################################################################
# LOG_FILE -- path to the install log file.
# Each caller should set this BEFORE sourcing common.sh, or let it default
# to a sensible location. Every log_* function appends to this file.
###############################################################################

# LOG_FILE is the on-disk log where every timestamped message is recorded.
# If the caller hasn't set it yet, default to a well-known location.
: "${LOG_FILE:=/var/log/gameserver-install.log}" # set default only if LOG_FILE is empty/unset

###############################################################################
# LOGGING FUNCTIONS
# These functions print colored status messages to the terminal AND
# append plain-text (no color codes) timestamps lines to the log file.
###############################################################################

# ts(): generates the current timestamp in YYYY-MM-DD HH:MM:SS format.
# Used as a prefix for every log line so you can tell exactly when
# each thing happened during a long install or troubleshooting session.
ts() { # define the timestamp function
    date '+%Y-%m-%d %H:%M:%S' # format: year-month-day hour:minute:second
} # end of ts()

# log_line(): appends one plain-text line to the log file.
# The 2>/dev/null || true at the end silently swallows any error (like
# "Permission denied" if we haven't gained root yet) so the script
# doesn't crash just because it tried to log before it had permission.
log_line() { # define the log_line function
    { # group the append + error suppression together
        printf '%s %s\n' "$(ts)" "$1" # print timestamp, space, the message, newline
    } >> "$LOG_FILE" 2>/dev/null # append to the log file; swallow errors
} # end of log_line()

# log_info(): prints a blue [INFO] message to the terminal (stdout).
# Useful for general status updates the user should see while the
# install is running. Also records to the log file.
log_info() { # define the log_info function
    echo -e "${C_BLUE}[INFO]${C_RESET} $1" # print blue "[INFO]" + message to terminal
    log_line "INFO: $1"                     # also append to the log file
} # end of log_info()

# log_ok(): prints a green [ OK ] message to the terminal (stdout).
# Used when something succeeded -- a package installed, a check passed, etc.
# Also records to the log file.
log_ok() { # define the log_ok function
    echo -e "${C_GREEN}[ OK ]${C_RESET} $1" # print green "[ OK ]" + message to terminal
    log_line "OK: $1"                         # also append to the log file
} # end of log_ok()

# log_warn(): prints a yellow [WARN] message to stderr (not stdout).
# Warnings are things that might be a problem but won't stop the install.
# Going to stderr so downstream logic can distinguish warnings from info.
# Also records to the log file.
log_warn() { # define the log_warn function
    echo -e "${C_YELLOW}[WARN]${C_RESET} $1" >&2 # print yellow "[WARN]" to stderr
    log_line "WARN: $1"                            # also append to the log file
} # end of log_warn()

# log_err(): prints a red [FAIL] message to stderr.
# Errors are serious problems that will likely cause the install to abort.
# Going to stderr so they are not accidentally captured by command
# substitution or other stdout-reading logic. Also records to the log file.
log_err() { # define the log_err function
    echo -e "${C_RED}[FAIL]${C_RESET} $1" >&2 # print red "[FAIL]" to stderr
    log_line "ERROR: $1"                        # also append to the log file
} # end of log_err()

# log_step(): prints a bold section header like "==> Installing packages".
# Visually separates each major phase of the install so the user can
# easily scan the terminal for where things are. Also records to log file.
log_step() { # define the log_step function
    echo -e "\n${C_BOLD}==> $1${C_RESET}" # print a blank line + bold "==> section name"
    log_line "STEP: $1"                     # also append to the log file
} # end of log_step()

###############################################################################
# FATAL ERROR / COMMAND EXECUTION
###############################################################################

# die(): logs a fatal error, tells the user where the full log is, and
# exits the script. The optional second argument is a custom exit code
# (defaults to 1 if not provided). This is the "everything stops now"
# function -- called when something goes wrong that can't be recovered from.
die() { # define the die (fatal error + exit) function
    log_err "$1"                                          # log the fatal error message
    log_err "Aborted. Full details were logged to: ${LOG_FILE}" # tell the user where the log is
    exit "${2:-1}"                                        # exit with the provided code, or default to 1
} # end of die()

# run_logged(): runs a command but sends all its output to the log file
# instead of the terminal, keeping the screen clean and readable.
# The first argument is a human-readable description of what the command
# does (shown in error messages if it fails). All remaining arguments
# are the actual command to run. Returns the command's exit code.
run_logged() { # define the run_logged function
    local description="$1" # save the human-readable description for error messages
    shift                 # remove the description from the argument list; what's left is the real command
    log_line "RUN: $*"    # log the full command we're about to run
    if "$@" >> "$LOG_FILE" 2>&1; then # run the command, append all output (stdout+stderr) to the log file
        return 0                      # command succeeded -- return success (exit code 0)
    else                              # the command failed (returned a non-zero exit code)
        local rc=$?                   # capture the actual exit code before it gets overwritten
        log_err "${description} failed (exit ${rc}). See ${LOG_FILE} for the full command output." # tell the user what failed
        return "$rc"                  # return the same exit code the failed command returned
    fi # end of the command execution check
} # end of run_logged()

###############################################################################
# SMALL GENERAL-PURPOSE HELPERS
# Reusable utility functions used throughout every installer script.
###############################################################################

# has_forbidden_chars(): returns 0 (true) if the input string contains
# any character that is unsafe inside a double-quoted shell assignment:
# double-quote ("), single-quote ('), backtick (`), backslash (\), or
# dollar sign ($). These characters could cause shell injection when
# user input gets written into generated config files that are later
# sourced (loaded) by other scripts. This is a security guard.
has_forbidden_chars() { # define the has_forbidden_chars function
    local value="$1" # store the input string in a local variable
    case "$value" in # check the string against a pattern of dangerous characters
        *'"'*|*"'"*|*'`'*|*'\'*|*'$'*) return 0 ;; # if ANY of these chars are found, return 0 (true = forbidden)
        *) return 1 ;; # no forbidden characters found, return 1 (false = safe)
    esac # end of the case pattern match
} # end of has_forbidden_chars()

# command_exists(): returns 0 (true) if the given command name is
# available somewhere on the system's PATH. Uses `command -v`, which is
# more portable and reliable than `which`. The >/dev/null 2>&1 hides
# both normal output and any error messages.
command_exists() { # define the command_exists function
    command -v "$1" >/dev/null 2>&1 # check if the command exists; suppress all output
} # end of command_exists()

# curl_with_retry(): a drop-in replacement for `curl` that automatically
# retries up to 3 times with a 5-second delay between attempts. This
# handles transient network glitches that are common during server setup
# on flaky or overloaded connections -- far better to retry silently
# than to abort the entire install over one failed HTTP request.
curl_with_retry() { # define the curl_with_retry function
    local attempt=1       # start at attempt number 1
    local max_attempts=3  # give up after 3 total attempts
    local delay_seconds=5 # wait 5 seconds between retries
    while (( attempt <= max_attempts )); do # loop until we've tried max_attempts times
        if curl "$@"; then # run curl with whatever arguments the caller passed
            return 0       # curl succeeded -- return success immediately
        fi # end of the curl success check
        if (( attempt < max_attempts )); then # only log/retry if we haven't exhausted attempts yet
            log_warn "Network request failed (attempt ${attempt}/${max_attempts}); retrying in ${delay_seconds}s..." # warn the user
            sleep "$delay_seconds" # pause before the next attempt
        fi # end of the retry check
        attempt=$(( attempt + 1 )) # increment the attempt counter
    done # end of the retry loop
    log_err "Network request failed after ${max_attempts} attempts: curl $*" # all attempts failed -- report the error
    return 1 # return failure
} # end of curl_with_retry()

# require_root(): if the script is not running as root, it re-launches
# itself under sudo (preserving all arguments and environment variables
# via `exec sudo -E`). This means the user never has to remember to
# type `sudo` -- the script handles it automatically. If sudo is not
# available at all, it prints an error telling the user what to do.
require_root() { # define the require_root function
    if [[ "${EUID}" -ne 0 ]]; then # check if we are NOT root (EUID 0 = root)
        if command_exists sudo; then # check if sudo is available on this system
            log_warn "Not running as root; re-launching with sudo (you may be asked for your password)..." # warn the user
            exec sudo -E bash "$0" "$@" # replace this process with sudo + the same script + same arguments
        else # sudo is NOT installed
            die "This script must be run as root, and 'sudo' was not found. Try: su -c 'bash ${BASH_SOURCE[0]}'" # fatal error
        fi # end of the sudo availability check
    fi # end of the root check
} # end of require_root()

# init_logging(): creates (or touches) the log file, sets its permissions
# to 640 (readable by root and the owning group, not world-readable),
# and writes a visual separator line to mark the start of a new run.
# Takes LOG_FILE and SCRIPT_NAME as its arguments from the caller.
init_logging() { # define the init_logging function
    local log_file="$1"   # first argument: path to the log file
    local script_name="$2" # second argument: name of the calling script
    touch "$log_file"      # create the log file if it doesn't exist; update timestamp if it does
    chmod 640 "$log_file"  # set permissions: owner read+write, group read, others nothing
    LOG_FILE="$log_file"   # set the global LOG_FILE variable so all log_* functions use it
    log_line "====================================================================" # visual separator
    log_line "${script_name} started" # mark the start of this run in the log
} # end of init_logging()

###############################################################################
# APT / PACKAGE MANAGEMENT HELPERS
# Functions that interact with Ubuntu's package manager (apt), including
# lock-waiting and repository setup.
###############################################################################

# wait_for_apt_lock(): if another apt/dpkg process is running (common
# right after a fresh boot when unattended-upgrades kicks in), this
# waits up to APT_LOCK_WAIT_SECONDS for the lock to be released before
# letting our own apt-get call proceed. Without this, we'd get the
# dreaded "Could not get lock" error and the install would fail.
wait_for_apt_lock() { # define the wait_for_apt_lock function
    command_exists flock || return 0 # if flock isn't installed, skip this check entirely (can't wait anyway)
    local lock_file="/var/lib/dpkg/lock-frontend" # the standard apt/dpkg lock file path
    if ! ( exec 200>"$lock_file"; flock -w "$APT_LOCK_WAIT_SECONDS" 200 ) 2>/dev/null; then # try to acquire the lock with a timeout
        log_warn "Timed out after ${APT_LOCK_WAIT_SECONDS}s waiting for the apt/dpkg lock. Proceeding anyway; the next command may need a re-run." # warn but don't die -- sometimes apt still works
    fi # end of the lock acquisition attempt
} # end of wait_for_apt_lock()

###############################################################################
# PRE-FLIGHT CHECKS
# Functions that verify the system meets all requirements before the
# real install work begins. These run early and fail fast so the user
# doesn't waste time only to hit a fatal problem halfway through.
###############################################################################

# detect_os_release(): parses /etc/os-release (a standard Linux file)
# into the global variables OS_ID, OS_VERSION_ID, OS_CODENAME, and
# OS_IS_LTS. This works on any Ubuntu version without hardcoding
# specific release names or numbers -- the file is the source of truth.
detect_os_release() { # define the detect_os_release function
    [[ -r /etc/os-release ]] || die "Cannot find /etc/os-release; this does not look like Ubuntu." # abort if the file doesn't exist or isn't readable
    OS_ID="$(awk -F= '/^ID=/{gsub(/"/,"",$2); print $2}' /etc/os-release)"           # extract the OS ID (e.g. "ubuntu")
    OS_VERSION_ID="$(awk -F= '/^VERSION_ID=/{gsub(/"/,"",$2); print $2}' /etc/os-release)" # extract the version number (e.g. "24.04")
    OS_CODENAME="$(awk -F= '/^VERSION_CODENAME=/{gsub(/"/,"",$2); print $2}' /etc/os-release)" # extract the codename (e.g. "noble")
    local version_field # declare a local variable for the full VERSION string
    version_field="$(awk -F= '/^VERSION=/{gsub(/"/,"",$2); print $2}' /etc/os-release)" # extract the full VERSION field
    if [[ "$version_field" == *LTS* || "$version_field" == *lts* ]]; then # check if it contains "LTS" (case-insensitive)
        OS_IS_LTS=1 # set LTS flag to true
    else # it's not an LTS release
        OS_IS_LTS=0 # set LTS flag to false
    fi # end of the LTS check
} # end of detect_os_release()

# check_ubuntu_version(): calls detect_os_release() then verifies the
# OS is actually Ubuntu. Warns (but doesn't block) if it's not an LTS
# release, since non-LTS versions may reach end-of-support sooner.
check_ubuntu_version() { # define the check_ubuntu_version function
    log_step "Checking operating system" # print a section header
    detect_os_release # parse /etc/os-release into global variables
    if [[ "$OS_ID" != "ubuntu" ]]; then # if the OS is not Ubuntu
        die "This installer supports Ubuntu only (detected: ${OS_ID:-unknown})." # fatal error -- can't continue
    fi # end of the Ubuntu check
    if [[ "$OS_IS_LTS" -eq 1 ]]; then # if it IS an LTS release
        log_ok "Ubuntu ${OS_VERSION_ID} LTS (${OS_CODENAME:-unknown}) detected." # green success message
    else # it's Ubuntu, but NOT an LTS release
        log_warn "Ubuntu ${OS_VERSION_ID} (${OS_CODENAME:-unknown}) detected -- not an LTS release. Continuing anyway." # yellow warning, not fatal
    fi # end of the LTS status check
} # end of check_ubuntu_version()

# check_cpu_arch(): verifies the CPU architecture is x86_64 (also
# known as amd64). All supported game servers require 64-bit x86 --
# no ARM, no 32-bit. This catches the error early on cloud instances
# that might be ARM-based (like AWS Graviton).
check_cpu_arch() { # define the check_cpu_arch function
    log_step "Checking CPU architecture" # print a section header
    local arch # declare a local variable for the architecture string
    arch="$(uname -m)" # uname -m returns the machine hardware name (e.g. "x86_64")
    [[ "$arch" == "x86_64" ]] || die "This platform requires x86_64 (detected: ${arch})." # fatal if not x86_64
    log_ok "Architecture: ${arch}" # green success message with the detected architecture
} # end of check_cpu_arch()

# check_internet(): tries to reach a few HTTPS servers we'll need during
# the install (Ubuntu's package mirrors, Valve's CDN, and Cloudflare).
# If none are reachable, the install can't possibly work, so we abort.
check_internet() { # define the check_internet function
    log_step "Checking internet connectivity" # print a section header
    local host # declare a local variable for each host we'll try
    for host in "https://archive.ubuntu.com" "https://steamcdn-a.akamaihd.net" "https://1.1.1.1"; do # try three hosts in order
        if curl -fsS --max-time 8 -o /dev/null "$host" 2>>"$LOG_FILE"; then # attempt an HTTPS request (8 second timeout, silent, discard body)
            log_ok "Internet connectivity confirmed (reached ${host})." # green success -- at least one host is reachable
            return 0 # return success immediately
        fi # end of the connectivity check for this host
    done # end of the host loop
    die "No internet connectivity detected." # none of the hosts were reachable -- fatal error
} # end of check_internet()

# check_ram(): reads total system RAM from /proc/meminfo and enforces
# a hard minimum (below which game servers simply won't start) and a
# recommended amount (below which we warn the user). Stores the result
# in the global variable TOTAL_RAM_MB for later use by maybe_create_swap.
check_ram() { # define the check_ram function
    log_step "Checking available RAM" # print a section header
    local ram_kb # declare variable for RAM in kilobytes
    local ram_mb # declare variable for RAM in megabytes
    ram_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo)" # extract MemTotal (in kB) from /proc/meminfo
    ram_mb=$(( ram_kb / 1024 )) # convert kilobytes to megabytes (integer division)
    if (( ram_mb < MIN_RAM_MB_HARD )); then # if RAM is below the hard minimum
        die "Only ${ram_mb} MB RAM detected. At least ${MIN_RAM_MB_HARD} MB is required." # fatal error
    elif (( ram_mb < MIN_RAM_MB_RECOMMENDED )); then # if RAM is between hard minimum and recommended
        log_warn "${ram_mb} MB RAM detected. Note: RAM needs vary hugely by game/instance count -- check each profile's guidance." # warning, not fatal
    else # RAM is at or above the recommended amount
        log_ok "${ram_mb} MB RAM detected." # green success message
    fi # end of the RAM size checks
    TOTAL_RAM_MB="$ram_mb" # store the value globally for later use (e.g. maybe_create_swap)
} # end of check_ram()

# check_disk_space(): checks how much free space is available on the
# target filesystem (prefers /srv if it exists, otherwise /) and refuses
# to continue if there's less than MIN_DISK_MB free.
check_disk_space() { # define the check_disk_space function
    log_step "Checking free disk space" # print a section header
    local target # declare variable for the filesystem path to check
    local avail_mb # declare variable for available megabytes
    target="/srv"; [[ -d "$target" ]] || target="/" # use /srv if it exists, otherwise fall back to /
    avail_mb="$(df --output=avail -m "$target" | tail -n1 | tr -d '[:space:]')" # get available space in MB (df output, last line, strip spaces)
    if (( avail_mb < MIN_DISK_MB )); then # if free space is below the minimum
        die "Only ${avail_mb} MB free on ${target}. At least ${MIN_DISK_MB} MB is required." # fatal error
    fi # end of the disk space check
    log_ok "${avail_mb} MB free on ${target} (minimum: ${MIN_DISK_MB} MB)." # green success message
} # end of check_disk_space()

###############################################################################
# SWAP FILE CREATION
###############################################################################

# maybe_create_swap(): if no swap is configured and RAM is below the
# recommended threshold, creates a swap file to prevent out-of-memory
# crashes. Handles btrfs filesystems correctly (uses NOCOW attribute
# and dd instead of fallocate, which doesn't work on btrfs). If the
# user is running in non-interactive mode (-y), skips the prompt and
# creates the swap automatically.
maybe_create_swap() { # define the maybe_create_swap function
    log_step "Checking swap space" # print a section header
    if [[ -n "$(swapon --show 2>/dev/null)" ]]; then # if swapon shows any active swap devices
        log_ok "Swap is already configured. Skipping." # no need to create swap -- green success
        return 0 # return success
    fi # end of the swap existence check
    if (( TOTAL_RAM_MB >= MIN_RAM_MB_RECOMMENDED )); then # if RAM is above the recommended threshold
        log_ok "RAM is above the recommended threshold; a swap file is not required." # no swap needed -- green success
        return 0 # return success
    fi # end of the RAM threshold check
    local create_swap="yes" # default to creating swap
    if [[ "${ASSUME_DEFAULTS:-0}" -ne 1 ]]; then # if we're in interactive mode (not -y)
        local reply="" # declare variable for the user's response
        read -r -p "No swap detected and RAM is limited. Create a ${SWAP_SIZE_MB:-4096}MB swap file for stability? [Y/n]: " reply # prompt the user
        reply="${reply:-y}" # default to "y" if the user just pressed Enter
        [[ "$reply" =~ ^[Yy] ]] || create_swap="no" # if user said no, don't create swap
    fi # end of the interactive prompt
    [[ "$create_swap" == "no" ]] && { log_warn "Skipping swap file creation at your request."; return 0; } # respect the user's choice
    log_info "Creating a ${SWAP_SIZE_MB:-4096}MB swap file at ${SWAP_FILE_PATH:-/swapfile}..." # blue info: creating swap
    local fs_type # declare variable for the filesystem type
    fs_type="$(findmnt -no FSTYPE --target "$(dirname "${SWAP_FILE_PATH:-/swapfile}")" 2>/dev/null || echo unknown)" # detect filesystem type (btrfs, ext4, etc.)
    : > "${SWAP_FILE_PATH:-/swapfile}" # create an empty file (truncating if it already exists)
    chmod 600 "${SWAP_FILE_PATH:-/swapfile}" # restrict permissions -- swap files must not be world-readable
    if [[ "$fs_type" == "btrfs" ]]; then # btrfs requires special handling for swap files
        log_info "Detected btrfs; applying NOCOW attribute before writing the swap file..." # blue info about btrfs
        chattr +C "${SWAP_FILE_PATH:-/swapfile}" 2>/dev/null || true # set the NOCOW (no copy-on-write) attribute
        dd if=/dev/zero of="${SWAP_FILE_PATH:-/swapfile}" bs=1M count="${SWAP_SIZE_MB:-4096}" status=none # write zeros to fill the file (btrfs can't use fallocate)
    elif command_exists fallocate && fallocate -l "${SWAP_SIZE_MB:-4096}M" "${SWAP_FILE_PATH:-/swapfile}" 2>>"$LOG_FILE"; then # if fallocate exists and works, use it (fast, most filesystems)
        : # fallocate succeeded -- do nothing (the : is a no-op)
    else # fallocate failed or doesn't exist -- fall back to dd
        dd if=/dev/zero of="${SWAP_FILE_PATH:-/swapfile}" bs=1M count="${SWAP_SIZE_MB:-4096}" status=none # write zeros to fill the file (slow but reliable)
    fi # end of the filesystem-type branching
    mkswap "${SWAP_FILE_PATH:-/swapfile}" >>"$LOG_FILE" 2>&1 # format the file as swap space
    swapon "${SWAP_FILE_PATH:-/swapfile}" # activate the swap file
    grep -q "^${SWAP_FILE_PATH:-/swapfile} " /etc/fstab 2>/dev/null || echo "${SWAP_FILE_PATH:-/swapfile} none swap sw 0 0" >> /etc/fstab # add to /etc/fstab so swap persists across reboots
    log_ok "Swap file created and enabled." # green success message
} # end of maybe_create_swap()

###############################################################################
# INPUT VALIDATION FUNCTIONS
# Every function in this section prints an error message (captured by
# the caller via command substitution) and returns non-zero on invalid
# input, or returns 0 on valid input. These are designed to be plugged
# directly into prompt_and_validate()'s validator argument.
###############################################################################

# validate_instance_name(): ensures the value is 1-32 characters of
# letters, digits, underscores, or hyphens only. This string becomes a
# systemd service name, a directory name, and a registry key -- so it
# must be filesystem-safe, systemd-safe, and contain no spaces or
# special characters that could break shell commands.
validate_instance_name() { # define the validate_instance_name function
    local v="$1" # store the input value in a local variable
    if [[ ! "$v" =~ ^[A-Za-z0-9_-]{1,32}$ ]]; then # test against the regex: 1-32 chars of allowed characters
        echo "Instance name must be 1-32 characters: letters, numbers, '_', '-' (no spaces)." # print the error (captured by caller)
        return 1 # return failure
    fi # end of the regex check
    return 0 # the name is valid -- return success
} # end of validate_instance_name()

# validate_generic_safe_string(): ensures the value is 1-60 characters
# of letters, digits, spaces, dots, underscores, or hyphens -- plus a
# check for shell-unsafe characters. This is a safe default for server
# names and identities that don't have game-specific rules.
validate_generic_safe_string() { # define the validate_generic_safe_string function
    local v="$1" # store the input value in a local variable
    if has_forbidden_chars "$v"; then # check for shell-unsafe characters first
        echo "May not contain: \" ' \` \\ \$" # list the forbidden characters
        return 1 # return failure
    fi # end of the forbidden-chars check
    if [[ ! "$v" =~ ^[A-Za-z0-9._\ -]{1,60}$ ]]; then # test against the regex: 1-60 chars of allowed characters
        echo "Must be 1-60 characters: letters, numbers, spaces, '.', '_', '-'." # print the error
        return 1 # return failure
    fi # end of the regex check
    return 0 # the string is valid -- return success
} # end of validate_generic_safe_string()

# validate_generic_password(): ensures the value is 5-64 characters,
# contains no spaces, and has no shell-unsafe characters. This is a
# generic password validator -- game profiles that need extra rules
# (like Valheim's server-name-overlap check) should layer their own
# validator on top.
validate_generic_password() { # define the validate_generic_password function
    local v="$1" # store the input value in a local variable
    if has_forbidden_chars "$v"; then # check for shell-unsafe characters first
        echo "May not contain: \" ' \` \\ \$" # list the forbidden characters
        return 1 # return failure
    fi # end of the forbidden-chars check
    if [[ "${#v}" -lt 5 || "${#v}" -gt 64 ]]; then # check the string length (5 to 64 characters)
        echo "Must be between 5 and 64 characters." # print the error
        return 1 # return failure
    fi # end of the length check
    if [[ "$v" == *" "* ]]; then # check for spaces (passwords must not contain spaces)
        echo "May not contain spaces." # print the error
        return 1 # return failure
    fi # end of the space check
    return 0 # the password is valid -- return success
} # end of validate_generic_password()

# validate_yesno(): accepts y, yes, n, or no (case-insensitive).
# Used for simple yes/no prompts throughout the installer. The input
# is lowercased before comparison so "Y", "Yes", "YES" all work.
validate_yesno() { # define the validate_yesno function
    case "${1,,}" in # lower the input and match against patterns
        y|yes|n|no) return 0 ;; # y/yes/n/no are all acceptable -- return success
        *) echo "Please answer yes or no."; return 1 ;; # anything else is invalid -- return failure
    esac # end of the pattern match
} # end of validate_yesno()

# validate_port(): ensures the value is a whole number between 1024 and
# 65535 minus whatever headroom the active game profile needs. Games
# that use multiple consecutive ports (e.g. Valheim uses 3: N, N+1, N+2)
# set PROFILE_PORT_COUNT before calling this, and the upper limit is
# automatically adjusted so the last port doesn't overflow.
validate_port() { # define the validate_port function
    local v="$1" # store the input value in a local variable
    local needed="${PROFILE_PORT_COUNT:-1}" # how many consecutive ports this game needs (default: 1)
    if [[ ! "$v" =~ ^[0-9]+$ ]]; then # check that it's a whole number (digits only)
        echo "Port must be a whole number." # print the error
        return 1 # return failure
    fi # end of the whole-number check
    if (( v < 1024 || v + needed > 65535 )); then # check the valid range (1024 to 65535 minus headroom)
        echo "Port must be between 1024 and $((65535 - needed)) (this game uses ${needed} consecutive port(s))." # print the error with the actual range
        return 1 # return failure
    fi # end of the range check
    return 0 # the port is valid -- return success
} # end of validate_port()

# validate_retention_days(): ensures the value is a whole number
# between 1 and 365. Used for backup retention -- how many days of
# backup archives to keep before the oldest ones are deleted.
validate_retention_days() { # define the validate_retention_days function
    local v="$1" # store the input value in a local variable
    if [[ ! "$v" =~ ^[0-9]+$ ]] || (( v < 1 || v > 365 )); then # must be digits-only AND between 1 and 365
        echo "Retention must be a whole number of days between 1 and 365." # print the error
        return 1 # return failure
    fi # end of the range check
    return 0 # the value is valid -- return success
} # end of validate_retention_days()

# validate_time_hhmm(): ensures the value is in 24-hour HH:MM format.
# Hours must be 00-23, minutes must be 00-59. Used for scheduling
# daily backup and update times. The regex is strict: leading zeros
# are required (e.g. "3:00" is rejected, "03:00" is accepted).
validate_time_hhmm() { # define the validate_time_hhmm function
    local v="$1" # store the input value in a local variable
    if [[ ! "$v" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then # test against the strict HH:MM regex
        echo "Time must be in 24-hour HH:MM format, e.g. 03:30." # print the error with an example
        return 1 # return failure
    fi # end of the regex check
    return 0 # the time is valid -- return success
} # end of validate_time_hhmm()

###############################################################################
# YES/NO NORMALIZATION
###############################################################################

# normalize_yesno_bit(): converts a validated yes/no answer to 1/0.
# This is used after validate_yesno has already confirmed the input is
# valid, to produce a numeric value that can be stored in config files
# and used in arithmetic comparisons. "y" and "yes" become 1; everything
# else (which will only be "n" or "no" at this point) becomes 0.
normalize_yesno_bit() { # define the normalize_yesno_bit function
    case "${1,,}" in # lower the input and match against patterns
        y|yes) echo 1 ;; # "yes" equivalents produce 1
        *) echo 0 ;;     # "no" equivalents (the only other valid input) produce 0
    esac # end of the pattern match
} # end of normalize_yesno_bit()

###############################################################################
# INTERACTIVE PROMPT ENGINE
###############################################################################

# prompt_and_validate(): the core prompt loop used by every installer.
# Displays a prompt with a default value, reads input from the user,
# passes it to a validator function, and repeats until valid input is
# received. In non-interactive mode (ASSUME_DEFAULTS=1), it silently
# uses the default without prompting. Assigns the validated result into
# a global variable named by the fourth argument (via printf -v).
# Arguments: prompt_text, default_val, validator_function, variable_name, secret (optional, 0 or 1)
prompt_and_validate() { # define the prompt_and_validate function
    local prompt_text="$1" # the text to show the user (e.g. "Server name")
    local default_val="$2" # the default value (shown in [brackets], used if user presses Enter)
    local validator="$3"   # the name of a validation function to call (e.g. validate_instance_name)
    local varname="$4"     # the name of the global variable to assign the result into
    local secret="${5:-0}" # whether to hide input (for passwords); defaults to 0 (visible)
    local input # declare variable for the user's raw input
    local errmsg # declare variable for error messages from the validator
    while true; do # loop forever until valid input is received
        if [[ "${ASSUME_DEFAULTS:-0}" -eq 1 ]]; then # if we're in non-interactive mode (-y flag)
            input="$default_val" # silently use the default without prompting
        elif [[ "$secret" -eq 1 ]]; then # if this is a secret/password prompt
            read -r -s -p "${prompt_text}: " input < /dev/tty # read from the terminal without echoing (for passwords)
            echo # print a newline after the hidden input (the user pressed Enter)
            input="${input:-$default_val}" # if the user pressed Enter without typing anything, use the default
        else # normal (non-secret) interactive prompt
            read -r -p "${prompt_text} [${default_val}]: " input < /dev/tty # read from the terminal, showing the default
            input="${input:-$default_val}" # if the user pressed Enter without typing anything, use the default
        fi # end of the prompt type branching
        if errmsg="$("$validator" "$input" 2>&1)"; then # run the validator; capture its error output
            printf -v "$varname" '%s' "$input" # validation passed -- assign the value to the named variable
            return 0 # return success
        else # validation failed
            log_warn "$errmsg" # show the validator's error message as a warning
            if [[ "${ASSUME_DEFAULTS:-0}" -eq 1 ]]; then # if we're in non-interactive mode
                die "Default value for '${prompt_text}' failed validation; refusing to continue in non-interactive mode." # fatal -- can't fix it automatically
            fi # end of the non-interactive check
        fi # end of the validation result check
    done # end of the prompt loop
} # end of prompt_and_validate()

###############################################################################
# PACKAGE INSTALLATION
# The full stack: enabling Ubuntu repos, updating package lists, and
# installing core/32-bit/optional packages.
###############################################################################

# CORE_PACKAGES: the list of packages every game server install needs.
# These are installed as a batch; if any fail, the install aborts.
CORE_PACKAGES=( # define the core packages array
    curl wget unzip jq rsync zip tar cron ufw fail2ban socat conntrack # networking, archives, monitoring, firewall tools
    ca-certificates software-properties-common # HTTPS certs and add-apt-repository command
) # end of CORE_PACKAGES

# OPTIONAL_PACKAGES: nice-to-have tools installed one at a time in
# best-effort mode. If any package isn't available for the current
# Ubuntu release, it's skipped silently -- these are conveniences,
# not requirements.
OPTIONAL_PACKAGES=( # define the optional packages array
    git nano vim htop btop tmux screen lm-sensors smartmontools # editors, monitors, sensors
) # end of OPTIONAL_PACKAGES

# enable_required_repos(): enables the 'universe' and 'multiverse'
# Ubuntu package repositories (needed for some packages) and adds
# i386 (32-bit) architecture support (needed for SteamCMD's runtime
# libraries). This is a one-time setup step.
enable_required_repos() { # define the enable_required_repos function
    log_step "Enabling required package repositories" # print a section header
    wait_for_apt_lock # wait for any other apt process to finish
    # refresh package lists (ignore failure -- repos might not be fully set up yet)
    run_logged "apt-get update (initial)" apt-get update -y -qq || true # run update, ignore errors
    if ! command_exists add-apt-repository; then # if add-apt-repository isn't installed yet
        wait_for_apt_lock # wait for the apt lock again
        # install the package that provides add-apt-repository
        run_logged "install software-properties-common" env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq software-properties-common || die "Could not install software-properties-common." # fatal if this basic tool can't be installed
    fi # end of the add-apt-repository check
    wait_for_apt_lock # wait for the apt lock
    # enable the universe repository
    run_logged "add-apt-repository universe" add-apt-repository -y universe || die "Failed to enable the 'universe' repository." # fatal if it fails
    wait_for_apt_lock # wait for the apt lock
    # enable the multiverse repository
    run_logged "add-apt-repository multiverse" add-apt-repository -y multiverse || die "Failed to enable the 'multiverse' repository." # fatal if it fails
    dpkg --add-architecture i386 # enable 32-bit (i386) package architecture for SteamCMD
    log_ok "Repositories configured." # green success message
} # end of enable_required_repos()

# apt_update_upgrade(): refreshes the package lists (apt update) and
# then upgrades all currently installed packages to their latest
# versions (apt upgrade). Both steps are run non-interactively and
# their output goes to the log file to keep the terminal clean.
apt_update_upgrade() { # define the apt_update_upgrade function
    log_step "Updating and upgrading system packages (this may take a few minutes)" # print a section header
    wait_for_apt_lock # wait for any other apt process to finish
    run_logged "apt-get update" apt-get update -y -qq || die "apt-get update failed." # refresh package lists; fatal on failure
    log_ok "Package lists updated." # green success message
    export DEBIAN_FRONTEND=noninteractive # tell apt not to show interactive prompts (use defaults for everything)
    wait_for_apt_lock # wait for the apt lock
    run_logged "apt-get upgrade" apt-get upgrade -y -qq || die "apt-get upgrade failed." # upgrade all installed packages; fatal on failure
    log_ok "Existing packages upgraded." # green success message
} # end of apt_update_upgrade()

# install_packages(): installs three tiers of packages:
#   1. CORE_PACKAGES -- everything the platform needs (fatal on failure)
#   2. 32-bit compatibility libraries -- required by SteamCMD (with a
#      fallback package name for older Ubuntu versions)
#   3. OPTIONAL_PACKAGES -- nice-to-have tools, installed one at a
#      time in best-effort mode (never fatal)
# Also enables the cron daemon at the end.
install_packages() { # define the install_packages function
    log_step "Installing required packages" # print a section header
    export DEBIAN_FRONTEND=noninteractive # suppress interactive prompts for all apt commands
    log_info "Installing core packages: ${CORE_PACKAGES[*]}" # blue info: list what we're installing
    wait_for_apt_lock # wait for the apt lock
    # install all core packages at once
    run_logged "apt-get install (core)" apt-get install -y -qq "${CORE_PACKAGES[@]}" || die "Failed to install one or more CORE packages. See ${LOG_FILE}." # fatal on failure
    log_ok "Core packages installed." # green success message
    log_info "Installing 32-bit compatibility libraries for SteamCMD..." # blue info: next step
    wait_for_apt_lock # wait for the apt lock
    if apt-get install -y -qq lib32gcc-s1 lib32stdc++6 >>"$LOG_FILE" 2>&1; then # try the modern package name first
        log_ok "32-bit compatibility libraries installed (lib32gcc-s1)." # green success
    else # the modern name doesn't exist on this Ubuntu version
        log_warn "lib32gcc-s1 not found; trying the older package name (lib32gcc1)..." # warn about the fallback
        wait_for_apt_lock # wait for the apt lock
        # try the older package name as a fallback
        apt-get install -y -qq lib32gcc1 lib32stdc++6 >>"$LOG_FILE" 2>&1 || die "Could not install 32-bit compatibility libraries under either package name." # fatal if neither works
        log_ok "32-bit compatibility libraries installed (lib32gcc1)." # green success with the fallback name
    fi # end of the 32-bit library installation
    log_info "Installing optional convenience/monitoring tools: ${OPTIONAL_PACKAGES[*]}" # blue info: optional packages
    local pkg # declare variable for the loop
    for pkg in "${OPTIONAL_PACKAGES[@]}"; do # loop through each optional package one at a time
        wait_for_apt_lock # wait for the apt lock before each install
        if apt-get install -y -qq "$pkg" >>"$LOG_FILE" 2>&1; then # try to install the package
            log_ok "  ${pkg} installed." # green success for this package
        else # this package isn't available for this Ubuntu release
            log_warn "  ${pkg} is not available for this Ubuntu release; skipping (not required)." # yellow warning, not fatal
        fi # end of the single-package install attempt
    done # end of the optional packages loop
    log_info "Enabling and starting the cron service..." # blue info: enabling cron
    systemctl enable --now cron >>"$LOG_FILE" 2>&1 || log_warn "Could not enable/start cron (it may already be running)." # best-effort: warn if it fails
} # end of install_packages()

###############################################################################
# NETWORK INFORMATION
# Gathers hostname, LAN IP, and public IP once at install time. These
# values are stored in global variables for use by instance summaries,
# firewall rules, and other output.
###############################################################################

# gather_network_info(): determines the machine's hostname, LAN IP
# address (the private/internal IP), default gateway, and public/WAN
# IP address. The LAN IP is discovered by asking the kernel which
# source IP it would use to reach 1.1.1.1 (Cloudflare) -- this is
# more reliable than hostname -I on multi-homed machines. Falls back
# to hostname -I if the route-based method fails.
gather_network_info() { # define the gather_network_info function
    log_step "Gathering network information" # print a section header
    HOSTNAME_VALUE="$(hostname)" # get the machine's hostname (e.g. "gameserver")
    LAN_IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1)}')" # ask the kernel which IP it uses to reach the internet
    if [[ -z "$LAN_IP" ]]; then # if the route-based method didn't return anything
        LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')" # fallback: use hostname -I (first IP listed)
    fi # end of the LAN IP fallback
    if [[ -z "$LAN_IP" ]]; then # if even hostname -I failed
        LAN_IP="unknown" # give up and set to "unknown"
    fi # end of the LAN IP final fallback
    DEFAULT_GATEWAY="$(ip route show default 2>/dev/null | awk '/default/{print $3; exit}')" # get the default gateway IP
    if [[ -z "$DEFAULT_GATEWAY" ]]; then # if no gateway was found
        DEFAULT_GATEWAY="unknown" # set to "unknown"
    fi # end of the gateway fallback
    PUBLIC_IP="$(curl -fsS --max-time 5 https://icanhazip.com 2>/dev/null | tr -d '[:space:]' || true)" # fetch the public IP from an external service
    log_ok "Hostname: ${HOSTNAME_VALUE}  |  LAN IP: ${LAN_IP}  |  Public IP: ${PUBLIC_IP:-unknown}" # green success with all gathered info
} # end of gather_network_info()

###############################################################################
# INSTANCE PATH HELPERS
# Every other function computes an instance's paths through these, so
# the on-disk layout is decided in exactly one place. The INSTANCES_DIR
# variable (set by the caller or derived from BASE_DIR) is the root.
###############################################################################

# INSTANCES_DIR: the parent directory where all instances live.
# Callers should set this (or it gets derived from BASE_DIR) before
# calling any path helper function.
: "${INSTANCES_DIR:=${BASE_DIR}/srv/gameservers/instances}" # set default only if INSTANCES_DIR is empty/unset

# instance_dir(): prints the root directory for a named instance.
# Example: instance_dir "myworld" → "/srv/gameservers/instances/myworld"
instance_dir() { # define the instance_dir function
    echo "${INSTANCES_DIR}/$1" # concatenate the instances root with the instance name
} # end of instance_dir()

# instance_server_dir(): prints the path to an instance's game server
# files directory. Each instance gets its own copy (synced from the
# shared "golden" install) so configs and mods don't conflict.
instance_server_dir() { # define the instance_server_dir function
    echo "${INSTANCES_DIR}/$1/server" # the "server" subdirectory under the instance root
} # end of instance_server_dir()

# instance_data_dir(): prints the path to an instance's save/world data
# directory. This is what gets backed up -- each game profile is
# responsible for putting its world saves here.
instance_data_dir() { # define the instance_data_dir function
    echo "${INSTANCES_DIR}/$1/data" # the "data" subdirectory under the instance root
} # end of instance_data_dir()

# instance_logs_dir(): prints the path to an instance's log directory.
# Game server stdout/stderr and backup/update logs live here.
instance_logs_dir() { # define the instance_logs_dir function
    echo "${INSTANCES_DIR}/$1/logs" # the "logs" subdirectory under the instance root
} # end of instance_logs_dir()

# instance_tmp_dir(): prints the path to an instance's scratch/temp
# directory. Used for backup staging, BepInEx probe runs, and other
# temporary work that gets cleaned up after use.
instance_tmp_dir() { # define the instance_tmp_dir function
    echo "${INSTANCES_DIR}/$1/tmp" # the "tmp" subdirectory under the instance root
} # end of instance_tmp_dir()

# instance_default_backup_dir(): prints the default backup location
# for an instance. This is offered as the default in prompts, but
# the user can override it to point at a different disk/mount point.
instance_default_backup_dir() { # define the instance_default_backup_dir function
    echo "${INSTANCES_DIR}/$1/backups" # the "backups" subdirectory under the instance root
} # end of instance_default_backup_dir()

# instance_config_file(): prints the path to an instance's config.env.
# This file contains all instance-specific settings (port, game type,
# backup schedule, etc.) and is chmod 600 because it may contain
# passwords or secrets.
instance_config_file() { # define the instance_config_file function
    echo "${INSTANCES_DIR}/$1/config.env" # the "config.env" file under the instance root
} # end of instance_config_file()

###############################################################################
# END OF common.sh
# This file defines functions only -- nothing is executed when sourced.
# Callers pick which functions they need and call them explicitly.
###############################################################################

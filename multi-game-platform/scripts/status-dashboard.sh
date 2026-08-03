#!/usr/bin/env bash
###############################################################################
# status-dashboard.sh -- Unified health-check status dashboard
#
# Displays a single, easy-to-read view of ALL game server instances and the
# host system. Shows host resource usage, per-instance status (running/stopped,
# port listening, uptime, disk), and a summary line at the bottom.
#
# Usage:
#   status-dashboard.sh [instance-name] [--json]
#     No argument      → show all instances
#     With name → show only the matching instance
#     --json    → emit the same data as a single JSON object on stdout
#                 instead of the human-readable table (no colors, no
#                 boxes -- meant for scripts/monitoring, not eyeballs).
#                 Can be combined with an instance-name filter, in
#                 either argument order.
#
# Color coding (human mode only; --json never emits color codes):
#   Green  = healthy (service running, port listening)
#   Yellow = warning (recently started, within grace period)
#   Red    = critical (service down, port not listening)
#
# Reads from: /srv/gameservers/instances.registry (name:game:port:created)
# Checks:     systemctl is-active, ss -uln/-tln, du -sh
###############################################################################
set -uo pipefail  # -u: error on unset variables; -o pipefail: pipeline error propagation

###############################################################################
# ARGUMENT PARSING
# Accepts an optional instance-name filter and an optional --json flag, in
# either order (e.g. "status-dashboard.sh --json myserver" or
# "status-dashboard.sh myserver --json" both work).
###############################################################################
JSON_MODE=0   # 1 if --json was passed
FILTER=""     # instance-name filter, if any non-flag argument was passed
for arg in "$@"; do
    case "$arg" in
        --json) JSON_MODE=1 ;;
        *) FILTER="$arg" ;;
    esac
done

###############################################################################
# SOURCE SHARED LIBRARY
# common.sh provides color codes, logging helpers, load_instance(),
# all_instance_names(), and list_instance_names_to_stderr().
###############################################################################
source /srv/gameservers/scripts/common.sh  # load shared functions and color codes

###############################################################################
# COLOR DEFINITIONS (for dashboard-specific formatting)
# These ANSI escape sequences let us color-code output for quick visual scans.
# If stdout is NOT a terminal (e.g. piped to a file), OR we're in --json
# mode (JSON must never contain raw ANSI escapes), they become empty strings.
###############################################################################
if [[ -t 1 && "$JSON_MODE" -ne 1 ]]; then # real terminal AND not JSON mode
    CLR_RESET='\033[0m'       # reset all formatting back to default
    CLR_GREEN='\033[0;32m'    # green text for healthy/running status
    CLR_YELLOW='\033[0;33m'   # yellow text for warnings (recently started)
    CLR_RED='\033[0;31m'      # red text for critical/down status
    CLR_BOLD='\033[1m'        # bold text for headers and emphasis
    CLR_DIM='\033[2m'         # dim text for less important info
    CLR_CYAN='\033[0;36m'     # cyan text for host info header
else # stdout is NOT a terminal (piped to file or another command)
    CLR_RESET=''              # no color when not a terminal
    CLR_GREEN=''              # no color when not a terminal
    CLR_YELLOW=''             # no color when not a terminal
    CLR_RED=''                # no color when not a terminal
    CLR_BOLD=''               # no formatting when not a terminal
    CLR_DIM=''                # no formatting when not a terminal
    CLR_CYAN=''               # no color when not a terminal
fi # end of terminal detection

###############################################################################
# CONSTANTS
# These values control thresholds for color-coding host resource usage.
# Load thresholds are multiplied by CPU core count for fair comparison.
# RAM and disk percentages determine when to show yellow (warning) or red (critical).
###############################################################################
GRACE_PERIOD_SECONDS=180      # seconds after start before we expect port to be listening
RAM_WARN_PCT=70               # RAM usage above this % gets yellow (warning)
RAM_CRIT_PCT=90               # RAM usage above this % gets red (critical)
DISK_WARN_PCT=75              # disk usage above this % gets yellow (warning)
DISK_CRIT_PCT=90              # disk usage above this % gets red (critical)
HOSTNAME="$(hostname)"        # get the machine's hostname for the header

###############################################################################
# HELPER: format_uptime()
# Converts a number of seconds into a human-readable "Xd Xh Xm" string.
# Handles days, hours, and minutes. Seconds under 60 show as "<1m".
###############################################################################
format_uptime() { # define the format_uptime function
    local seconds="$1"  # the number of seconds to format
    if [[ "$seconds" -lt 60 ]]; then # less than one minute
        echo "<1m"                      # show as less than 1 minute
    elif [[ "$seconds" -lt 3600 ]]; then # less than one hour
        local mins=$(( seconds / 60 ))  # calculate minutes (integer division)
        echo "${mins}m"                  # show as e.g. "45m"
    elif [[ "$seconds" -lt 86400 ]]; then # less than one day
        local hours=$(( seconds / 3600 ))  # calculate full hours
        local mins=$(( (seconds % 3600) / 60 )) # calculate remaining minutes
        echo "${hours}h ${mins}m"          # show as e.g. "3h 15m"
    else # one day or more
        local days=$(( seconds / 86400 ))  # calculate full days
        local hours=$(( (seconds % 86400) / 3600 )) # calculate remaining hours
        echo "${days}d ${hours}h"          # show as e.g. "2d 5h"
    fi # end of the time formatting branches
} # end of format_uptime()

###############################################################################
# SECTION: HEADER
# Print the dashboard title with hostname, current date, and system uptime.
# This gives the operator instant context about which machine they're looking at.
###############################################################################
HOST_UPTIME="$(uptime -p 2>/dev/null || uptime | awk -F'up ' '{print $2}' | awk -F',' '{print $1}')" # human-readable host uptime

if [[ "$JSON_MODE" -ne 1 ]]; then # human-readable header (skipped entirely in --json mode)
echo ""  # print a blank line for visual spacing before the header
echo -e "${CLR_BOLD}${CLR_CYAN}╔══════════════════════════════════════════════════════════════╗${CLR_RESET}" # top border
echo -e "${CLR_BOLD}${CLR_CYAN}║           GAME SERVER PLATFORM — STATUS DASHBOARD           ║${CLR_RESET}" # title
echo -e "${CLR_BOLD}${CLR_CYAN}╚══════════════════════════════════════════════════════════════╝${CLR_RESET}" # bottom border
echo ""  # blank line after the title box

# Print the hostname on the left and the current date/time on the right
printf "${CLR_BOLD}Host:${CLR_RESET} %s   " "$HOSTNAME"  # print the hostname in bold
printf "${CLR_BOLD}Date:${CLR_RESET} %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"  # print current date/time
printf "${CLR_BOLD}Uptime:${CLR_RESET} %s\n" "$HOST_UPTIME"
fi # end of human-readable header

###############################################################################
# SECTION: HOST RESOURCE OVERVIEW
# Gather and display CPU load, RAM usage, and disk usage for the entire host.
# These give a quick snapshot of whether the machine is healthy overall.
###############################################################################
if [[ "$JSON_MODE" -ne 1 ]]; then # section header (skipped entirely in --json mode)
echo ""  # blank line before host resources section
echo -e "${CLR_BOLD}── Host Resources ──${CLR_RESET}"  # section header
fi # end of section header

# --- CPU LOAD ---
# Read the 1-minute load average from /proc/loadavg (field 1).
# Compare it to the number of CPU cores to determine health color.
# Load > cores means the CPU is overloaded; load < cores means it's fine.
CORES=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1) # count CPU cores
LOAD_1M=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "0") # get 1-minute load average
# Compare load to core count using bc for floating-point arithmetic; multiply by 100 to avoid decimals
LOAD_PCT=$(echo "$LOAD_1M $CORES" | awk '{printf "%d", ($1/$2)*100}') # load as percentage of cores

if [[ "$LOAD_PCT" -ge 100 ]]; then # load is >= 100% of capacity (overloaded)
    LOAD_COLOR="$CLR_RED"       # red = critical: CPU overloaded
elif [[ "$LOAD_PCT" -ge 70 ]]; then # load is >= 70% of capacity (high)
    LOAD_COLOR="$CLR_YELLOW"   # yellow = warning: CPU usage is high
else # load is below 70% (normal)
    LOAD_COLOR="$CLR_GREEN"    # green = healthy: CPU has headroom
fi # end of load color decision

if [[ "$JSON_MODE" -ne 1 ]]; then
printf "  CPU:  ${LOAD_COLOR}%s%%${CLR_RESET} (load %s / %s cores)\n" \
    "$LOAD_PCT" "$LOAD_1M" "$CORES" # print CPU load with color and context
fi

# --- RAM USAGE ---
# Parse /proc/meminfo for total and available memory, then compute usage %.
# "available" is more accurate than "free" because it includes reclaimable caches.
RAM_TOTAL_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo "1")  # total RAM in KB
RAM_AVAIL_KB=$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null || echo "$RAM_TOTAL_KB") # available RAM in KB
RAM_USED_KB=$(( RAM_TOTAL_KB - RAM_AVAIL_KB )) # used RAM = total minus available
RAM_USED_MB=$(( RAM_USED_KB / 1024 )) # convert used RAM to MB for display
RAM_TOTAL_MB=$(( RAM_TOTAL_KB / 1024 )) # convert total RAM to MB for display
RAM_PCT=$(( (RAM_USED_KB * 100) / RAM_TOTAL_KB )) # calculate usage percentage

if [[ "$RAM_PCT" -ge "$RAM_CRIT_PCT" ]]; then # RAM usage is at or above critical threshold
    RAM_COLOR="$CLR_RED"       # red = critical: system may OOM soon
elif [[ "$RAM_PCT" -ge "$RAM_WARN_PCT" ]]; then # RAM usage is at or above warning threshold
    RAM_COLOR="$CLR_YELLOW"   # yellow = warning: RAM is getting tight
else # RAM usage is below warning threshold
    RAM_COLOR="$CLR_GREEN"    # green = healthy: plenty of RAM available
fi # end of RAM color decision

if [[ "$JSON_MODE" -ne 1 ]]; then
printf "  RAM:  ${RAM_COLOR}%s%%${CLR_RESET} (%s MB / %s MB)\n" \
    "$RAM_PCT" "$RAM_USED_MB" "$RAM_TOTAL_MB" # print RAM usage with color and MB values
fi

# --- DISK USAGE ---
# Use df to get the usage percentage and used/total for the filesystem containing /srv.
# /srv is where game servers live, so that's the filesystem we care about most.
DISK_LINE=$(df --output=pcent,used,size /srv 2>/dev/null | tail -n1) # get disk stats for /srv filesystem
DISK_PCT=$(echo "$DISK_LINE" | awk '{gsub(/%/,"",$1); print $1}') # extract usage %, strip the % sign
DISK_USED=$(echo "$DISK_LINE" | awk '{print $2}') # extract used space (human-readable, e.g. "45G")
DISK_TOTAL=$(echo "$DISK_LINE" | awk '{print $3}') # extract total space (human-readable)
DISK_PCT="${DISK_PCT:-0}" # default to 0 if df returned nothing (safety fallback)

if [[ "$DISK_PCT" -ge "$DISK_CRIT_PCT" ]]; then # disk usage is at or above critical threshold
    DISK_COLOR="$CLR_RED"      # red = critical: disk nearly full, games may crash
elif [[ "$DISK_PCT" -ge "$DISK_WARN_PCT" ]]; then # disk usage is at or above warning threshold
    DISK_COLOR="$CLR_YELLOW"  # yellow = warning: disk filling up
else # disk usage is below warning threshold
    DISK_COLOR="$CLR_GREEN"   # green = healthy: plenty of disk space
fi # end of disk color decision

if [[ "$JSON_MODE" -ne 1 ]]; then
printf "  Disk: ${DISK_COLOR}%s%%${CLR_RESET} (%s used / %s total)\n" \
    "$DISK_PCT" "$DISK_USED" "$DISK_TOTAL" # print disk usage with color and space values
fi

###############################################################################
# SECTION: PER-INSTANCE STATUS TABLE
# Iterate over every instance in the registry and display its status.
# If an instance name was passed as $1, only show that one instance.
# Otherwise, show all instances.
###############################################################################
if [[ "$JSON_MODE" -ne 1 ]]; then
echo ""  # blank line before the instance table
echo -e "${CLR_BOLD}── Instance Status ──${CLR_RESET}"  # section header for the table

# Print the table column headers with fixed widths for clean alignment.
# %-22s = left-aligned, 22 chars wide (INSTANCE column)
# %-14s = left-aligned, 14 chars wide (GAME column)
# etc.
printf "${CLR_BOLD}%-22s %-14s %-10s %-8s %-10s %-12s %-10s${CLR_RESET}\n" \
    "INSTANCE" "GAME" "STATUS" "PORT" "LISTENING" "UPTIME" "DISK"  # column headers in bold

# Print a thin separator line under the headers using repeated dashes
printf "${CLR_DIM}%s${CLR_RESET}\n" "$(printf '%.0s─' {1..90})"  # 90 dash characters
fi

###############################################################################
# INSTANCE ITERATION
# Read instance names from the registry file. If a filter argument was given,
# only process the matching instance. Otherwise, process all instances.
# The registry format is: name:game:port:created_at (colon-separated).
# (FILTER itself was already parsed out of "$@" at the top of the script,
# alongside --json, so it isn't re-parsed here.)
###############################################################################

# JSON_INSTANCES accumulates one jq-built JSON object per instance (only
# used when JSON_MODE=1); combined into a single array right before output.
JSON_INSTANCES=()

# Counter variables for the summary line at the bottom
COUNT_RUNNING=0  # how many instances are currently running
COUNT_STOPPED=0  # how many instances are currently stopped
COUNT_TOTAL=0    # total number of instances processed

# Capture the full list of SS output once (instead of per-instance) for performance
# This gets both UDP and TCP listening sockets in one go
SS_OUTPUT=$(ss -uln 2>/dev/null; ss -tln 2>/dev/null) # UDP + TCP listening sockets

###############################################################################
# MAIN LOOP
# Read each line from the registry. Each line is: name:game:port:created_at
# For each instance, we check:
#   1. Service status via systemctl
#   2. Port listening via the pre-captured ss output
#   3. Uptime from the systemd ActiveEnterTimestamp property
#   4. Disk usage via du -sh on the instance directory
###############################################################################
while IFS=: read -r reg_name reg_game reg_port _; do # read registry fields (4th field, creation time, isn't used here)

    # Skip empty lines (trailing newlines, blank entries)
    [[ -n "$reg_name" ]] || continue  # if name is empty, skip to next line

    # If a filter was provided and this instance doesn't match, skip it
    if [[ -n "$FILTER" && "$reg_name" != "$FILTER" ]]; then # filter is set and names don't match
        continue # skip this instance
    fi # end of filter check

    # Increment the total counter for every instance we process
    COUNT_TOTAL=$(( COUNT_TOTAL + 1 ))

    # --- SERVICE STATUS ---
    # Check if the systemd service is active (running) for this instance.
    # The service name pattern is "gameserver@<instancename>".
    if systemctl is-active --quiet "gameserver@${reg_name}" 2>/dev/null; then # service is active
        SVC_STATUS="running"    # set status text to "running"
        SVC_COLOR="$CLR_GREEN"  # green = healthy: service is up
    else # service is NOT active (stopped, failed, etc.)
        SVC_STATUS="stopped"    # set status text to "stopped"
        SVC_COLOR="$CLR_RED"    # red = critical: service is down
    fi # end of service status check

    # --- PORT LISTENING ---
    # Check if the instance's port appears in the ss output we captured earlier.
    # We grep for ":PORT " (with a trailing space) to avoid matching partial ports
    # (e.g. port 27015 should not match 270150).
    if echo "$SS_OUTPUT" | grep -q ":${reg_port}[[:space:]]"; then # port is found in listening sockets
        PORT_STATUS="yes"       # port is listening
        PORT_COLOR="$CLR_GREEN" # green = healthy: port is bound
    else # port is NOT found in listening sockets
        PORT_STATUS="no"        # port is not listening
        PORT_COLOR="$CLR_RED"   # red = critical: port is not bound
    fi # end of port listening check

    # --- UPTIME ---
    # Query systemd for the ActiveEnterTimestamp of this instance's service.
    # This is the date/time when the service last entered the "active" state.
    # We convert it to epoch seconds and subtract from the current time.
    ACTIVE_SINCE_RAW=$(systemctl show "gameserver@${reg_name}" \
        --property=ActiveEnterTimestamp --value 2>/dev/null || true) # get the raw timestamp string
    ACTIVE_EPOCH=0 # default epoch to 0 (unknown/failed)
    if [[ -n "$ACTIVE_SINCE_RAW" ]]; then # if we got a non-empty timestamp
        ACTIVE_EPOCH=$(date -d "$ACTIVE_SINCE_RAW" +%s 2>/dev/null || echo 0) # convert to epoch seconds
    fi # end of timestamp parsing
    NOW_EPOCH=$(date +%s) # current time in epoch seconds
    UPTIME_SEC=$(( NOW_EPOCH - ACTIVE_EPOCH )) # uptime = now minus when it started

    # Determine uptime display color based on grace period and status
    if [[ "$SVC_STATUS" != "running" ]]; then # service is not running
        UPTIME_TEXT="-"            # show dash for stopped services
        UPTIME_COLOR="$CLR_DIM"   # dim text since it's not running
    elif [[ "$ACTIVE_EPOCH" -eq 0 || "$UPTIME_SEC" -lt "$GRACE_PERIOD_SECONDS" ]]; then # recently started
        UPTIME_TEXT="$(format_uptime "$UPTIME_SEC")" # format the short uptime
        UPTIME_COLOR="$CLR_YELLOW" # yellow = warning: still in grace period
    else # running and past the grace period
        UPTIME_TEXT="$(format_uptime "$UPTIME_SEC")" # format the uptime
        UPTIME_COLOR="$CLR_GREEN"  # green = healthy: been up for a while
    fi # end of uptime color decision

    # --- DISK USAGE ---
    # Get the total disk usage of this instance's directory tree using du -sh.
    # du -sh = disk usage, summary mode, human-readable (e.g. "1.2G").
    # The 2>/dev/null hides errors if the directory doesn't exist.
    INST_DIR="${INSTANCES_DIR}/${reg_name}" # full path to the instance directory
    if [[ -d "$INST_DIR" ]]; then # if the instance directory exists on disk
        DISK_USAGE=$(du -sh "$INST_DIR" 2>/dev/null | awk '{print $1}') # get human-readable disk usage
    else # instance directory doesn't exist (registry is stale or dir was deleted)
        DISK_USAGE="N/A"  # show "not available" if the directory is missing
    fi # end of disk usage check

    # Color the disk usage based on size (rough thresholds for a single instance)
    # These are simple heuristics: >5G is concerning, >10G is critical for one game instance
    DISK_USAGE_CLEAN=$(echo "$DISK_USAGE" | tr -d '[:space:]') # strip whitespace for comparison
    case "$DISK_USAGE_CLEAN" in # pattern match on the disk usage string
        *G) # usage is in gigabytes
            DISK_NUM="${DISK_USAGE_CLEAN%G}" # extract the numeric part (strip trailing "G")
            if [[ "$DISK_NUM" =~ ^[0-9]+$ ]] && [[ "$DISK_NUM" -ge 10 ]]; then # 10GB or more
                INST_DISK_COLOR="$CLR_RED"    # red = critical: very large instance
            elif [[ "$DISK_NUM" =~ ^[0-9]+$ ]] && [[ "$DISK_NUM" -ge 5 ]]; then # 5GB or more
                INST_DISK_COLOR="$CLR_YELLOW" # yellow = warning: getting large
            else # under 5GB
                INST_DISK_COLOR="$CLR_GREEN"  # green = healthy: reasonable size
            fi # end of GB size check
            ;;
        *) # usage is in MB, KB, or other units (small)
            INST_DISK_COLOR="$CLR_GREEN"  # green = healthy: small footprint
            ;;
    esac # end of disk usage color decision

    # Update the running/stopped counters for the summary line
    if [[ "$SVC_STATUS" == "running" ]]; then # service is running
        COUNT_RUNNING=$(( COUNT_RUNNING + 1 )) # increment running counter
    else # service is stopped
        COUNT_STOPPED=$(( COUNT_STOPPED + 1 )) # increment stopped counter
    fi # end of counter update

    if [[ "$JSON_MODE" -eq 1 ]]; then
        # --- ACCUMULATE JSON ---
        # Build one JSON object for this instance with jq -n (rather than
        # hand-written string concatenation) so every field is properly
        # escaped -- an instance/game name can't break the output no
        # matter what characters it contains.
        # uptime_seconds is only meaningful while running (ACTIVE_EPOCH
        # otherwise defaults to 0, which would make UPTIME_SEC a huge,
        # meaningless number of seconds since the epoch) -- report it as
        # JSON null for a stopped instance instead.
        json_uptime_seconds="null"
        [[ "$SVC_STATUS" == "running" ]] && json_uptime_seconds="$UPTIME_SEC"
        JSON_INSTANCES+=("$(jq -n \
            --arg name "$reg_name" \
            --arg game "$reg_game" \
            --arg status "$SVC_STATUS" \
            --argjson port "$reg_port" \
            --argjson listening "$([[ "$PORT_STATUS" == "yes" ]] && echo true || echo false)" \
            --argjson uptime_seconds "$json_uptime_seconds" \
            --arg uptime "$UPTIME_TEXT" \
            --arg disk_usage "$DISK_USAGE" \
            '{name:$name, game:$game, status:$status, port:$port, listening:$listening, uptime_seconds:$uptime_seconds, uptime:$uptime, disk_usage:$disk_usage}')")
    else
        # --- PRINT THE ROW ---
        # Use printf with fixed column widths to produce a clean table row.
        # Each color variable wraps only the value, not the padding, so columns stay aligned.
        # All args must be on lines joined by backslash so printf receives them all.
        printf "%-22s %-14s ${SVC_COLOR}%-10s${CLR_RESET} %-8s ${PORT_COLOR}%-10s${CLR_RESET} ${UPTIME_COLOR}%-12s${CLR_RESET} ${INST_DISK_COLOR}%-10s${CLR_RESET}\n" \
            "$reg_name" "$reg_game" "$SVC_STATUS" "$reg_port" "$PORT_STATUS" "$UPTIME_TEXT" "$DISK_USAGE"
    fi

done < "$INSTANCE_REGISTRY" # read lines from the registry file

if [[ "$JSON_MODE" -eq 1 ]]; then
    ###########################################################################
    # SECTION: JSON OUTPUT
    # Combine the host stats and every accumulated per-instance object into
    # one JSON document and print it as the ENTIRE output of the script (no
    # other stdout is produced in --json mode). "jq -s ." on the joined
    # per-instance objects turns them into a proper JSON array; an empty
    # array (no instances) is handled the same way.
    ###########################################################################
    instances_json="[]"
    if [[ "${#JSON_INSTANCES[@]}" -gt 0 ]]; then
        instances_json="$(printf '%s\n' "${JSON_INSTANCES[@]}" | jq -s '.')"
    fi
    jq -n \
        --arg hostname "$HOSTNAME" \
        --arg generated_at "$(date '+%Y-%m-%d %H:%M:%S')" \
        --arg uptime "$HOST_UPTIME" \
        --argjson cpu_pct "$LOAD_PCT" \
        --argjson cpu_load_1m "$LOAD_1M" \
        --argjson cpu_cores "$CORES" \
        --argjson ram_pct "$RAM_PCT" \
        --argjson ram_used_mb "$RAM_USED_MB" \
        --argjson ram_total_mb "$RAM_TOTAL_MB" \
        --argjson disk_pct "$DISK_PCT" \
        --arg disk_used "$DISK_USED" \
        --arg disk_total "$DISK_TOTAL" \
        --argjson instances "$instances_json" \
        --argjson running "$COUNT_RUNNING" \
        --argjson stopped "$COUNT_STOPPED" \
        --argjson total "$COUNT_TOTAL" \
        '{
            host: {
                hostname: $hostname,
                generated_at: $generated_at,
                uptime: $uptime,
                cpu: {pct: $cpu_pct, load_1m: $cpu_load_1m, cores: $cpu_cores},
                ram: {pct: $ram_pct, used_mb: $ram_used_mb, total_mb: $ram_total_mb},
                disk: {pct: $disk_pct, used: $disk_used, total: $disk_total}
            },
            instances: $instances,
            summary: {running: $running, stopped: $stopped, total: $total}
        }'
    if [[ "$COUNT_STOPPED" -gt 0 ]]; then
        exit 1
    else
        exit 0
    fi
fi

###############################################################################
# SECTION: SUMMARY LINE
# Print a count of running, stopped, and total instances at the bottom.
# This gives a quick "at a glance" health check without reading the table.
###############################################################################
echo ""  # blank line before the summary
printf "${CLR_BOLD}%s${CLR_RESET}\n" "$(printf '%.0s─' {1..90})"  # separator line (90 dashes)

# Print the summary with color-coded counts: green for running, red for stopped
# All args on the continuation line (joined by \) so printf receives them all.
printf "${CLR_BOLD}Summary:${CLR_RESET} ${CLR_GREEN}%d running${CLR_RESET}  ${CLR_RED}%d stopped${CLR_RESET}  %d total\n" \
    "$COUNT_RUNNING" "$COUNT_STOPPED" "$COUNT_TOTAL"

# Print an empty line at the end for clean terminal output
echo ""  # trailing blank line so the next shell prompt isn't jammed against our output

###############################################################################
# END OF status-dashboard.sh
# Exit with 0 if all instances are running, 1 if any are stopped.
# This lets the script be used in automated monitoring pipelines.
###############################################################################
if [[ "$COUNT_STOPPED" -gt 0 ]]; then # if any instances are stopped
    exit 1  # non-zero exit code indicates problems were found
else # all instances are running
    exit 0  # zero exit code means everything is healthy
fi # end of exit code decision

###############################################################################
# killingfloor2.profile.sh -- Killing Floor 2 dedicated server
#
# Confidence notes: App ID 232130 is the dedicated server (distinct from
# 232090, the base game) -- native Linux, Unreal Engine 3. Launch
# convention follows Unreal Engine's own long-standing "?options" URL-style
# map argument (similar in spirit to ARK's, though KF2's own specific
# flags are a bit less exhaustively documented across hosting guides than
# ARK's are) plus separate "-flag" style arguments for the rest.
###############################################################################

# PROFILE_GAME_ID: a short, unique identifier for this game -- used internally
# by the platform to name folders, log entries, and systemd services
PROFILE_GAME_ID="killingfloor2"
# PROFILE_DISPLAY_NAME: the human-readable name shown to users in menus and prompts
PROFILE_DISPLAY_NAME="Killing Floor 2"
# PROFILE_STEAM_APPID: the Steam "App ID" for the dedicated server --
# note this is 232130 (the server), NOT 232090 (the game itself)
PROFILE_STEAM_APPID="232130"
# PROFILE_STEAM_PLATFORM: which OS platform to download from Steam -- "linux"
# means there's a native Linux version
PROFILE_STEAM_PLATFORM="linux"
# PROFILE_REQUIRES_WINE: 0 means this game runs natively on Linux, no Wine needed
PROFILE_REQUIRES_WINE=0
# PROFILE_REQUIRES_JAVA: 0 means this game does NOT need Java
PROFILE_REQUIRES_JAVA=0
# PROFILE_PORT_COUNT: KF2 needs 3 ports (game, query, and web admin panel)
PROFILE_PORT_COUNT=3

# PROFILE_RECOMMENDED_RAM_MB: an optional, best-effort recommendation (moderate for its small player cap).
# This is a advisory floor, not a hard technical limit -- the platform warns
# clearly (and asks for confirmation interactively) if the host has less than
# this, but never blocks the install outright.
# 2048 MB = 2 GB -- KF2 is relatively modest in RAM needs
PROFILE_RECOMMENDED_RAM_MB=2048

# profile_port_specs(): declares which network ports this game needs
profile_port_specs() {
    # Port 0 is the main game port (UDP) -- where players connect to play
    echo "0:udp:game"
    # Port 1 is the query port (UDP) -- where server browsers get server info
    echo "1:udp:query"
    # Port 2 is the web admin panel (TCP) -- a web page you can open in a browser
    # to manage the server remotely
    echo "2:tcp:webadmin"
}

# profile_find_binary(): locates the KF2 server program on disk
profile_find_binary() {
    # search_dir: the directory to search in (first argument)
    local search_dir="$1"
    # Look for a file named KFGameServer (case-insensitive) up to 2 directories deep
    # -maxdepth 2: don't search more than 2 folders deep (performance)
    # -iname: case-insensitive name match
    # 2>/dev/null: hide error messages
    # head -n1: take only the first result
    find "$search_dir" -maxdepth 2 -iname 'KFGameServer' 2>/dev/null | head -n1
}

# profile_gather_prompts(): asks the user game-specific questions during setup
profile_gather_prompts() {
    # Ask for the server's display name -- default is "My KF2 Server"
    prompt_and_validate "Server name" "My KF2 Server" validate_generic_safe_string KF2_SERVER_NAME 0
    # Ask which map to start on -- "KF-BurningParis" is a classic KF2 map
    prompt_and_validate "Map" "KF-BurningParis" validate_generic_safe_string KF2_MAP 0
    # Ask for max players -- KF2 only supports up to 6 players
    prompt_and_validate "Max players (1-6)" "6" validate_kf2_max_players KF2_MAX_PLAYERS 0

    # Check if a join password was already set from a previous run
    if [[ -n "${KF2_EXISTING_PASSWORD:-}" ]]; then
        # Show existing password as default -- user can press Enter to keep it
        prompt_and_validate "Server password (blank keeps current)" "$KF2_EXISTING_PASSWORD" validate_generic_safe_string KF2_PASSWORD 0
    # Auto mode: skip the question and use an empty password (open server)
    elif [[ "$ASSUME_DEFAULTS" -eq 1 ]]; then
        # Empty password = anyone can join without entering a password
        KF2_PASSWORD=""
        # Warn the user that the server is open
        log_warn "Non-interactive mode: leaving the join password blank (open server)."
    else
        # First-time interactive setup: ask for a password
        prompt_and_validate "Server password (blank = no password)" "" validate_generic_safe_string KF2_PASSWORD 0
    fi

    # Now handle the WEB ADMIN password (for the web-based admin panel)
    if [[ -n "${KF2_EXISTING_ADMIN_PASSWORD:-}" ]]; then
        # Show existing web admin password as default
        prompt_and_validate "Web admin password (blank keeps current)" "$KF2_EXISTING_ADMIN_PASSWORD" validate_generic_safe_string KF2_ADMIN_PASSWORD 0
    elif [[ "$ASSUME_DEFAULTS" -eq 1 ]]; then
        # Generate a random 16-character alphanumeric password
        KF2_ADMIN_PASSWORD="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16 || true)"
        # Notify the user about the auto-generated password
        log_warn "Non-interactive mode: generated a random web admin password."
        # Show it in bold so the user can see it
        echo -e "${C_BOLD}    Generated web admin password: ${KF2_ADMIN_PASSWORD}${C_RESET}"
    else
        # Ask interactively -- hidden flag 1 means input is not shown on screen
        prompt_and_validate "Web admin password" "" validate_generic_password KF2_ADMIN_PASSWORD 1
    fi

    # Save these variables to the config file so they persist between restarts
    PROFILE_EXTRA_CONFIG_VARS=(KF2_SERVER_NAME KF2_MAP KF2_MAX_PLAYERS KF2_PASSWORD KF2_ADMIN_PASSWORD)
}

# validate_kf2_max_players: KF2's own real ceiling (6 for standard play;
# some private servers push higher via mutators, not covered here).
validate_kf2_max_players() {
    # Store the user's input in a local variable
    local v="$1"
    # ^[0-9]+$: regex that matches only digits -- must be a whole number
    # || { ... }: if it's NOT a whole number, print error and return 1 (failure)
    [[ "$v" =~ ^[0-9]+$ ]] || { echo "Must be a whole number."; return 1; }
    # Now check the range: KF2 supports 1-6 players
    if (( v < 1 || v > 6 )); then
        # Out of range: print an error message
        echo "Must be a whole number between 1 and 6."
        # Return 1 = failure (input was invalid)
        return 1
    fi
    # Return 0 = success (input is valid)
    return 0
}

# profile_build_launch_args(): builds the command-line arguments for starting
# the KF2 server
profile_build_launch_args() {
    # Create the data directory if it doesn't exist
    mkdir -p "$INSTANCE_DATA_DIR"
    # local: declares variables that only exist in this function
    # query_port: the port for server browser queries (game port + 1)
    local query_port=$(( SERVER_PORT + 1 ))
    # webadmin_port: the port for the web admin panel (game port + 2)
    local webadmin_port=$(( SERVER_PORT + 2 ))
    # map_arg: KF2 uses Unreal Engine's "?key=value" URL-style syntax --
    # this combines the map name with settings into one string
    # e.g. "KF-BurningParis?MaxPlayers=6?GamePassword=secret"
    local map_arg="${KF2_MAP}?MaxPlayers=${KF2_MAX_PLAYERS}?GamePassword=${KF2_PASSWORD}"

    # LAUNCH_ARGS: the array of command-line flags for the server
    LAUNCH_ARGS=(
        # The map argument (includes map name + player count + password)
        "$map_arg"
        # -log: enables logging output
        -log
        # -port: which port to listen on for player connections
        "-port=${SERVER_PORT}"
        # -QueryPort: which port for server browser queries
        "-QueryPort=${query_port}"
        # -WebAdminPort: which port for the web admin panel
        "-WebAdminPort=${webadmin_port}"
        # -AdminPassword: password for the web admin panel
        "-AdminPassword=${KF2_ADMIN_PASSWORD}"
        # -ServerName: the name shown in the server browser
        "-ServerName=${KF2_SERVER_NAME}"
    )
}

# profile_post_start_notes(): prints helpful tips AFTER the server is set up
profile_post_start_notes() {
    # Print a bold "Note:" label
    echo -e "${C_BOLD}Note:${C_RESET} Deeper settings (difficulty, game length, mutators, Workshop"
    # Tell the user where to find advanced config files
    echo "mods) live in this instance's own PCServer-KFEngine.ini and PCServer-KFGame.ini --"
    # Final instruction: edit those files and restart
    echo "edit those directly for anything beyond what was asked above."
}

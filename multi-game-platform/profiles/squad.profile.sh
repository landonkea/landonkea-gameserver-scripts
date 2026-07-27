###############################################################################
# squad.profile.sh -- Squad dedicated server
#
# Confidence notes: App ID 403240 (the dedicated server) and native Linux
# support are well-established -- Squad has had a genuine Linux dedicated
# server for a long time, commonly self-hosted by its community. Unreal
# Engine 4-based, similar general shape to this platform's other UE4
# games. Deeper settings (layer rotation, admin lists, bans) live in
# SquadGame/ServerConfig/*.cfg files rather than the command line.
###############################################################################

# PROFILE_GAME_ID: a short, unique identifier for this game -- used internally
# by the platform to name folders, log entries, and systemd services
PROFILE_GAME_ID="squad"
# PROFILE_DISPLAY_NAME: the human-readable name shown to users in menus and prompts
PROFILE_DISPLAY_NAME="Squad"
# PROFILE_STEAM_APPID: the Steam "App ID" for the dedicated server download
PROFILE_STEAM_APPID="403240"
# PROFILE_STEAM_PLATFORM: which OS platform to download from Steam
PROFILE_STEAM_PLATFORM="linux"
# PROFILE_REQUIRES_WINE: 0 means this game runs natively on Linux, no Wine needed
PROFILE_REQUIRES_WINE=0
# PROFILE_REQUIRES_JAVA: 0 means this game does NOT need Java installed
PROFILE_REQUIRES_JAVA=0
# PROFILE_PORT_COUNT: Squad needs 2 ports (game port + query port)
PROFILE_PORT_COUNT=2

# PROFILE_RECOMMENDED_RAM_MB: an optional, best-effort recommendation (well-known to be one of the heavier Unreal Engine titles, at its large player counts).
# This is a advisory floor, not a hard technical limit -- the platform warns
# clearly (and asks for confirmation interactively) if the host has less than
# this, but never blocks the install outright.
# 8192 MB = 8 GB -- Squad has up to 100 players and large maps, so it needs lots of RAM
PROFILE_RECOMMENDED_RAM_MB=8192

# profile_port_specs(): declares which network ports this game needs
profile_port_specs() {
    # Port 0 is the main game port (UDP) -- where players connect to play
    echo "0:udp:game"
    # Port 1 is the query port (UDP) -- where server browsers get server info
    echo "1:udp:query"
}

# profile_find_binary(): locates the Squad server program on disk
profile_find_binary() {
    # search_dir: the directory to search in
    local search_dir="$1"
    # Look for SquadGameServer.sh (the launch script) in the top-level directory
    # -maxdepth 1: only search the immediate directory, not subfolders
    # -iname: case-insensitive name match (finds it regardless of capitalization)
    find "$search_dir" -maxdepth 1 -iname 'SquadGameServer.sh' 2>/dev/null | head -n1
}

# profile_gather_prompts(): asks the user game-specific questions during setup
profile_gather_prompts() {
    # Ask for the server's display name -- default is "My Squad Server"
    prompt_and_validate "Server name" "My Squad Server" validate_generic_safe_string SQUAD_SERVER_NAME 0
    # Ask how many players can join -- default 80 (Squad supports up to 100)
    prompt_and_validate "Max players" "80" validate_squad_max_players SQUAD_MAX_PLAYERS 0

    # Check if an admin/RCON password was already set from a previous configuration
    if [[ -n "${SQUAD_EXISTING_ADMIN_PASSWORD:-}" ]]; then
        # Show existing password as default -- user can press Enter to keep it
        prompt_and_validate "RCON/admin password (blank keeps current)" "$SQUAD_EXISTING_ADMIN_PASSWORD" validate_generic_safe_string SQUAD_ADMIN_PASSWORD 0
    # Auto mode: generate a random admin password automatically
    elif [[ "$ASSUME_DEFAULTS" -eq 1 ]]; then
        # Generate a random 16-character alphanumeric password
        SQUAD_ADMIN_PASSWORD="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16 || true)"
        # Notify the user that an admin password was auto-generated
        log_warn "Non-interactive mode: generated a random admin/RCON password."
        # Show it in bold so the user can copy it
        echo -e "${C_BOLD}    Generated admin/RCON password: ${SQUAD_ADMIN_PASSWORD}${C_RESET}"
    else
        # Ask interactively for the RCON/admin password -- hidden flag 1
        # means input is masked (not shown on screen for security)
        prompt_and_validate "RCON/admin password (for remote admin access)" "" validate_generic_password SQUAD_ADMIN_PASSWORD 1
    fi

    # Save these variables to the config file for persistence between restarts
    PROFILE_EXTRA_CONFIG_VARS=(SQUAD_SERVER_NAME SQUAD_MAX_PLAYERS SQUAD_ADMIN_PASSWORD)
}

# validate_squad_max_players: Squad's own large-team-scale ceiling (up to
# 100 in some configurations; 80 is the far more common practical default).
validate_squad_max_players() {
    # Store the user's input in a local variable
    local v="$1"
    # ^[0-9]+$: regex that matches only digits -- must be a whole number
    # || { ... }: if it's NOT a whole number, print error and return 1 (failure)
    [[ "$v" =~ ^[0-9]+$ ]] || { echo "Must be a whole number."; return 1; }
    # Check the range: Squad supports 2-100 players
    if (( v < 2 || v > 100 )); then
        # Out of range: print an error message
        echo "Must be a whole number between 2 and 100."
        # Return 1 = failure
        return 1
    fi
    # Return 0 = success (input is valid)
    return 0
}

# profile_build_launch_args: writes Rcon.cfg (Squad's own RCON settings
# file -- a different mechanism from this platform's other RCON-using
# games, which mostly take the RCON password as a launch argument
# instead) and builds the launch arguments.
profile_build_launch_args() {
    # Create the data directory if it doesn't exist
    mkdir -p "$INSTANCE_DATA_DIR"
    # local: declares variables that only exist in this function
    # rcon_port: the port for remote admin connections (game port + 100)
    local rcon_port=$(( SERVER_PORT + 100 ))
    # rcon_dir: the path to Squad's config directory inside the server files
    local rcon_dir="${INSTANCE_SERVER_DIR}/SquadGame/ServerConfig"
    # Create the config directory if it doesn't exist
    mkdir -p "$rcon_dir"
    # Write Rcon.cfg (Squad's RCON settings file) using a heredoc
    cat > "${rcon_dir}/Rcon.cfg" << CFG
# Port: which port RCON connections come in on
Port=${rcon_port}
# Password: the password needed to connect via RCON
Password=${SQUAD_ADMIN_PASSWORD}
CFG

    # LAUNCH_ARGS: command-line flags for the Squad server
    LAUNCH_ARGS=(
        # Port: which port to listen on for player connections
        "Port=${SERVER_PORT}"
        # QueryPort: which port for server browser queries (game port + 1)
        "QueryPort=$(( SERVER_PORT + 1 ))"
        # Name: the name shown in the server browser
        "Name=${SQUAD_SERVER_NAME}"
        # MaxPlayers: maximum number of players allowed
        "MaxPlayers=${SQUAD_MAX_PLAYERS}"
        # -log: enables logging output
        -log
    )
}

# profile_post_start_notes(): prints helpful tips AFTER the server is set up
profile_post_start_notes() {
    # Tell the user where to find advanced config files
    echo -e "${C_BOLD}Note:${C_RESET} Layer rotation, admin lists, and bans are configured through"
    echo "files under SquadGame/ServerConfig/ inside this instance's server directory --"
    # Final instruction: edit those files directly for advanced settings
    echo "edit those directly for anything beyond what was asked above."
}

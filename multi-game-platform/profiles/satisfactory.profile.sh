###############################################################################
# satisfactory.profile.sh -- Satisfactory dedicated server
#
# Confidence notes: App ID 1690800 (the dedicated server, distinct from
# the game's own app id) and the FactoryServer.sh launcher were confirmed
# via research earlier in this project, not just general knowledge. Ports
# 7777 (game), 15000, and 15777 (all UDP) match official documentation.
#   - Satisfactory's dedicated server has an unusual extra step versus
#     most other profiles here: newer versions expose an HTTPS-based admin
#     API (on the game port) that needs to be used once to "claim"/configure
#     a brand-new server (set an admin password, etc.) before it's fully
#     usable -- this profile does NOT automate that claiming step, since it
#     requires a specific HTTPS API sequence I can't verify without a live
#     server to test against. After first start, check Satisfactory's own
#     current documentation for the claim-server step if the game doesn't
#     behave as expected on first connect.
###############################################################################

# PROFILE_GAME_ID: a short, unique identifier for this game -- used internally
# by the platform to name folders, log entries, and systemd services
PROFILE_GAME_ID="satisfactory"
# PROFILE_DISPLAY_NAME: the human-readable name shown to users in menus and prompts
PROFILE_DISPLAY_NAME="Satisfactory"
# PROFILE_STEAM_APPID: the Steam "App ID" for the dedicated server download --
# note this is different from the game client's App ID
PROFILE_STEAM_APPID="1690800"
# PROFILE_STEAM_PLATFORM: which OS platform to download from Steam
PROFILE_STEAM_PLATFORM="linux"
# PROFILE_REQUIRES_WINE: 0 means this game runs natively on Linux, no Wine needed
PROFILE_REQUIRES_WINE=0
# PROFILE_REQUIRES_JAVA: 0 means this game does NOT need Java installed
PROFILE_REQUIRES_JAVA=0
# PROFILE_PORT_COUNT: Satisfactory needs 3 ports (game, beacon, and query)
PROFILE_PORT_COUNT=3

# PROFILE_RECOMMENDED_RAM_MB: an optional, best-effort recommendation (well-documented as RAM-hungry, especially as a factory grows).
# This is a advisory floor, not a hard technical limit -- the platform warns
# clearly (and asks for confirmation interactively) if the host has less than
# this, but never blocks the install outright.
# 8192 MB = 8 GB -- Satisfactory simulates huge factories with lots of machines
PROFILE_RECOMMENDED_RAM_MB=8192

# profile_port_specs(): declares which network ports this game needs
profile_port_specs() {
    # Port 0 is the main game port (UDP) -- where players connect to play
    echo "0:udp:game"
    # Port 1 is the beacon port (UDP) -- used for server discovery on the LAN
    echo "1:udp:beacon"
    # Port 2 is the query port (UDP) -- where server browsers get server info
    echo "2:udp:query"
}

# profile_find_binary(): locates the Satisfactory server program on disk
profile_find_binary() {
    # search_dir: the directory to search in
    local search_dir="$1"
    # Look for FactoryServer.sh (the launch script) in the top-level directory
    # -maxdepth 1: only search the immediate directory
    # -iname: case-insensitive name match
    find "$search_dir" -maxdepth 1 -iname 'FactoryServer.sh' 2>/dev/null | head -n1
}

# profile_gather_prompts(): asks the user game-specific questions during setup
# Satisfactory only asks about max players (no server name prompt -- the game
# handles naming differently than most other games here)
profile_gather_prompts() {
    # Ask how many players can join -- default 4
    prompt_and_validate "Max players" "4" validate_sat_max_players SAT_MAX_PLAYERS 0
    # Save this variable to the config file for persistence
    PROFILE_EXTRA_CONFIG_VARS=(SAT_MAX_PLAYERS)
}

# validate_sat_max_players(): checks that the user entered a valid player count
# for Satisfactory -- must be 1-16
validate_sat_max_players() {
    # Store the user's input in a local variable
    local v="$1"
    # ^[0-9]+$: regex that matches only digits (whole numbers)
    # v >= 1 && v <= 16: must be in Satisfactory's supported range
    [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 1 && v <= 16 )) || { echo "Must be a whole number between 1 and 16."; return 1; }
    # Return 0 = success
    return 0
}

# profile_build_launch_args: points save data at this instance's own data
# directory via -SaveDataFolder, a documented flag for exactly this
# purpose (unlike Rust, Satisfactory does support redirecting save data
# via an argument rather than needing a symlink workaround).
profile_build_launch_args() {
    # Create the data directory if it doesn't exist
    mkdir -p "$INSTANCE_DATA_DIR"
    # LAUNCH_ARGS: command-line flags for the Satisfactory server
    LAUNCH_ARGS=(
        # -unattended: run without showing a GUI window (headless mode)
        -unattended
        # -log: enables logging output
        -log
        # -Port: which port to listen on for player connections
        -Port="${SERVER_PORT}"
        # -ServerQueryPort: which port for server browser queries (game port + 2)
        -ServerQueryPort="$(( SERVER_PORT + 2 ))"
        # -SaveDataFolder: where to store world save data
        -SaveDataFolder="${INSTANCE_DATA_DIR}"
    )
}

# profile_post_start_notes(): prints helpful tips AFTER the server is set up
profile_post_start_notes() {
    # Warn the user about the "claim" step that's required on first connect
    echo -e "${C_BOLD}Note:${C_RESET} A brand-new Satisfactory server needs to be \"claimed\" (set an"
    # Explain what "claiming" means
    echo "admin password and initial settings) the first time you connect, via the game's own"
    # Explain why this script doesn't automate it
    echo "server manager UI -- this isn't something this script automates (it would require"
    # Explain the technical limitation
    echo "scripting an HTTPS API sequence that isn't practical to verify without a live"
    # Give clear next-step instructions
    echo "server). Connect once with the game client and follow its prompts before inviting"
    echo "other players."
}

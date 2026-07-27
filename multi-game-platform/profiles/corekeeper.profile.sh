###############################################################################
# corekeeper.profile.sh -- Core Keeper dedicated server
#
# Confidence notes: researched and confirmed (not just general knowledge)
# -- App ID 1963720 is the DEDICATED SERVER (distinct from 1621690, the
# game client), the binary is CoreKeeperServer.x86_64, it needs xvfb
# despite being a native Linux binary (a Unity headless-mode quirk, hence
# PROFILE_REQUIRES_XVFB=1, NOT Wine), and it uses UDP ports 27015-27016.
# Officially supports up to 8 players; community reports note performance
# drops past that regardless of hardware. Config is ServerConfig.json.
#
# WHAT "XVFB" MEANS: some games built with the Unity game engine
# (Core Keeper is one) insist on having a graphics display available to
# talk to, even when running in a mode that's not supposed to show
# anything on screen at all. Since this is a real dedicated server with
# no monitor plugged in, xvfb ("X Virtual FrameBuffer") creates a
# completely fake, invisible display purely in memory, just so the game
# stops complaining that there's no screen -- this is DIFFERENT from Wine
# (used by enshrouded.profile.sh): the game itself is still a genuine,
# native Linux program here, it just has this one extra quirky
# requirement.
###############################################################################

# PROFILE_GAME_ID: a short, unique identifier for this game -- used internally
# by the platform to name folders, log entries, and systemd services
PROFILE_GAME_ID="corekeeper"
# PROFILE_DISPLAY_NAME: the human-readable name shown to users in menus and prompts
PROFILE_DISPLAY_NAME="Core Keeper"
# PROFILE_STEAM_APPID: the Steam "App ID" for the dedicated server download --
# note this is different from 1621690, which is the game CLIENT
PROFILE_STEAM_APPID="1963720"
# PROFILE_STEAM_PLATFORM: which OS platform to download from Steam
PROFILE_STEAM_PLATFORM="linux"
# PROFILE_REQUIRES_WINE: 0 means this game runs natively on Linux, no Wine needed
PROFILE_REQUIRES_WINE=0
# PROFILE_REQUIRES_JAVA: 0 means this game does NOT need Java
PROFILE_REQUIRES_JAVA=0
# PROFILE_REQUIRES_XVFB: 1 means this game needs a virtual display (xvfb)
# to run -- this is a Unity engine quirk where the game needs "a screen"
# even though nothing is displayed. xvfb creates a fake invisible display
# in memory just to satisfy this requirement
PROFILE_REQUIRES_XVFB=1
# PROFILE_PORT_COUNT: Core Keeper needs 2 ports (game port + query port)
PROFILE_PORT_COUNT=2

# PROFILE_RECOMMENDED_RAM_MB: an optional, best-effort recommendation (lightweight for its player cap).
# This is a advisory floor, not a hard technical limit -- the platform warns
# clearly (and asks for confirmation interactively) if the host has less than
# this, but never blocks the install outright.
# 1024 MB = 1 GB -- Core Keeper is a simple 2D game, doesn't need much RAM
PROFILE_RECOMMENDED_RAM_MB=1024

# profile_port_specs(): declares which network ports this game needs
profile_port_specs() {
    # Port 0 is the main game port (UDP) -- where players connect to play
    echo "0:udp:game"
    # Port 1 is the query port (UDP) -- where server browsers get server info
    echo "1:udp:query"
}

# profile_find_binary(): locates the Core Keeper server program on disk
profile_find_binary() {
    # search_dir: the directory to search in
    local search_dir="$1"
    # Look for CoreKeeperServer.x86_64 -- the native Linux server binary
    # "x86_64" means it's compiled for 64-bit Intel/AMD processors
    find "$search_dir" -maxdepth 1 -iname 'CoreKeeperServer.x86_64' 2>/dev/null | head -n1
}

# profile_gather_prompts(): asks the user game-specific questions during setup
profile_gather_prompts() {
    # Ask for the world name -- "CoreKeeperWorld" is the default
    prompt_and_validate "World name" "CoreKeeperWorld" validate_generic_safe_string CK_WORLD_NAME 0
    # Ask for max players -- Core Keeper officially supports 1-8 players
    # The prompt includes a warning not to exceed 8 due to performance issues
    prompt_and_validate "Max players (1-8; official cap, community reports say don't push past it)" "8" validate_ck_max_players CK_MAX_PLAYERS 0

    # Check if a join password was already set from a previous configuration
    if [[ -n "${CK_EXISTING_PASSWORD:-}" ]]; then
        # Show existing password as default -- user can press Enter to keep it
        prompt_and_validate "Server password (blank keeps current)" "$CK_EXISTING_PASSWORD" validate_generic_safe_string CK_PASSWORD 0
    # Auto mode: generate a random password automatically
    elif [[ "$ASSUME_DEFAULTS" -eq 1 ]]; then
        # Generate a random 16-character alphanumeric password
        CK_PASSWORD="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16 || true)"
        # Notify the user
        log_warn "Non-interactive mode: generated a random password."
        # Show it in bold so the user can copy it
        echo -e "${C_BOLD}    Generated password: ${CK_PASSWORD}${C_RESET}"
    else
        # First-time setup: ask for a join password
        prompt_and_validate "Server password (blank = no password)" "" validate_generic_safe_string CK_PASSWORD 0
    fi

    # Save these variables to the config file for persistence
    PROFILE_EXTRA_CONFIG_VARS=(CK_WORLD_NAME CK_MAX_PLAYERS CK_PASSWORD)
}

# validate_ck_max_players(): checks that the user entered a valid player count
# for Core Keeper -- must be 1-8 (official cap)
validate_ck_max_players() {
    # Store the user's input in a local variable
    local v="$1"
    # ^[0-9]+$: regex that matches only digits (whole numbers)
    # v >= 1 && v <= 8: must be in Core Keeper's official range
    [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 1 && v <= 8 )) || { echo "Must be a whole number between 1 and 8 (official cap)."; return 1; }
    # Return 0 = success
    return 0
}

# profile_build_launch_args: writes ServerConfig.json into the instance's
# data directory and points the binary at it and at the world-save
# location via -logFile/-world args and the config's own worldName.
profile_build_launch_args() {
    # Create the worlds directory to store save data
    mkdir -p "${INSTANCE_DATA_DIR}/worlds"
    # cfg: the path to Core Keeper's JSON config file
    local cfg="${INSTANCE_DATA_DIR}/ServerConfig.json"
    # Write the JSON config file using a heredoc
    # JSON format uses curly braces { } and "key": value pairs
    cat > "$cfg" << CFG
{
  "serverName": "${INSTANCE_NAME}",
  "worldName": "${CK_WORLD_NAME}",
  "maxPlayers": ${CK_MAX_PLAYERS},
  "port": ${SERVER_PORT},
  "password": "${CK_PASSWORD}",
  "lanOnly": false
}
CFG
    # LAUNCH_ARGS: command-line flags for the Core Keeper server
    LAUNCH_ARGS=(
        # -batchmode: run without a GUI (headless mode for dedicated servers)
        -batchmode
        # -nographics: don't try to render graphics (no monitor attached)
        -nographics
        # -logFile: path to the server's log file
        -logFile "${INSTANCE_LOG_DIR}/corekeeper_server.log"
        # -serverConfigPath: path to the JSON config file we wrote above
        -serverConfigPath "$cfg"
        # -saveDirectory: where to store world save data
        -saveDirectory "${INSTANCE_DATA_DIR}/worlds"
    )
}

# profile_post_start_notes(): prints helpful tips AFTER the server is set up
profile_post_start_notes() {
    # Explain that this runs under xvfb (virtual display), not Wine
    echo -e "${C_BOLD}Note:${C_RESET} Runs under xvfb (a virtual display), not Wine -- this is a"
    # Explain the Unity engine quirk about needing a graphics context
    echo "native Linux binary that happens to need a graphics context even headless, a known"
    # Warn about a common startup error
    echo "Unity quirk. If it fails to start, check for a steamclient.so-related error in"
    # Tell them where to look for more info
    echo "logs-instance.sh, a commonly-reported issue with this specific server tool."
}

###############################################################################
# palworld.profile.sh -- Palworld dedicated server
#
# Confidence notes: App ID 2394010 (the dedicated server, added some time
# after launch specifically for Linux support -- distinct from the base
# game's own app id) and the PalServer.sh launcher are well-documented.
# Unreal Engine-based, same general shape as ARK/Conan: command line for
# the essentials, PalWorldSettings.ini for the deep configuration surface.
# A REST API for admin management also exists in newer versions but isn't
# used here to keep this profile's surface simple and predictable.
###############################################################################

# PROFILE_GAME_ID: a short, unique identifier for this game -- used internally
# by the platform to name folders, log entries, and systemd services
PROFILE_GAME_ID="palworld"
# PROFILE_DISPLAY_NAME: the human-readable name shown to users in menus and prompts
PROFILE_DISPLAY_NAME="Palworld"
# PROFILE_STEAM_APPID: the Steam "App ID" for the dedicated server download --
# note this is different from the game client's App ID -- 2394010 is specifically
# the dedicated server tool
PROFILE_STEAM_APPID="2394010"
# PROFILE_STEAM_PLATFORM: which OS platform to download from Steam -- "linux"
# means the native Linux version is available
PROFILE_STEAM_PLATFORM="linux"
# PROFILE_REQUIRES_WINE: 0 means this game runs natively on Linux, no Wine needed
PROFILE_REQUIRES_WINE=0
# PROFILE_REQUIRES_JAVA: 0 means this game does NOT need Java installed to run
PROFILE_REQUIRES_JAVA=0
# PROFILE_PORT_COUNT: how many network ports this game server needs --
# Palworld only needs 1 port (it handles game and query on the same port)
PROFILE_PORT_COUNT=1

# PROFILE_RECOMMENDED_RAM_MB: an optional, best-effort recommendation (known to be RAM-hungry, especially with more players/creatures).
# This is a advisory floor, not a hard technical limit -- the platform warns
# clearly (and asks for confirmation interactively) if the host has less than
# this, but never blocks the install outright.
# 8192 MB = 8 GB -- Palworld needs a lot of RAM because it simulates many creatures
PROFILE_RECOMMENDED_RAM_MB=8192

# profile_port_specs(): declares which network ports this game needs --
# Palworld only needs one UDP port for everything
profile_port_specs() {
    # Port 0 is the only port -- it handles both player connections AND server queries
    echo "0:udp:game"
}

# profile_find_binary(): locates the server program on disk -- Palworld has
# two possible locations, so we check both
profile_find_binary() {
    # local: creates variables that only exist inside this function
    # search_dir: the directory to search in (first argument $1)
    # found: will hold the result of our search (initialized empty)
    local search_dir="$1" found
    # First, look for the "real" binary (the Unreal Engine shipping binary)
    # -ipath: case-insensitive path search -- matches regardless of uppercase/lowercase
    # 2>/dev/null: suppresses any error messages from find
    # head -n1: takes only the first match found
    found="$(find "$search_dir" -ipath '*Pal/Binaries/Linux/PalServer-Linux-Shipping' 2>/dev/null | head -n1)"
    # If the first search found something, print its path and we're done
    if [[ -n "$found" ]]; then
        # -n: tests if the string is NOT empty -- so this means "if we found something"
        echo "$found"
    else
        # Fallback: look for PalServer.sh (a shell script launcher) instead
        # -maxdepth 1: only look in the top-level directory, don't go into subfolders
        # -iname: case-insensitive name match (matches PalServer.sh, PALSERVER.SH, etc.)
        # -type f: only match regular files (not directories or symlinks)
        find "$search_dir" -maxdepth 1 -iname 'PalServer.sh' 2>/dev/null | head -n1
    fi
}

# profile_gather_prompts(): asks the user game-specific questions during setup
# and stores their answers in variables -- Palworld needs name, players, password,
# and an admin password
profile_gather_prompts() {
    # Ask the user what to call their server -- default is "My Palworld Server"
    # validate_generic_safe_string: checks that the input only has safe characters
    # (no shell-injection-friendly symbols like ; | & etc.)
    prompt_and_validate "Server name" "My Palworld Server" validate_generic_safe_string PAL_SERVER_NAME 0
    # Ask how many players can join -- default 16, max 32 for Palworld
    prompt_and_validate "Max players" "16" validate_pal_max_players PAL_MAX_PLAYERS 0

    # Check if a join password was already set from a previous configuration run
    if [[ -n "${PAL_EXISTING_PASSWORD:-}" ]]; then
        # Show the existing password as the default so user can press Enter to keep it
        prompt_and_validate "Server password (blank keeps current)" "$PAL_EXISTING_PASSWORD" validate_generic_safe_string PAL_PASSWORD 0
    # If running in non-interactive/auto mode, generate a random password automatically
    elif [[ "$ASSUME_DEFAULTS" -eq 1 ]]; then
        # tr -dc 'A-Za-z0-9': takes random bytes and keeps ONLY letters and digits
        # < /dev/urandom: feeds random data into tr -- /dev/urandom is the system's
        # random number generator, head -c 16: takes the first 16 characters
        # || true: if anything goes wrong, don't crash -- just continue
        PAL_PASSWORD="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16 || true)"
        # Log a warning so the user knows a random password was generated
        log_warn "Non-interactive mode: generated a random password."
        # Print the generated password in bold so the user can see and save it
        echo -e "${C_BOLD}    Generated password: ${PAL_PASSWORD}${C_RESET}"
    else
        # First-time interactive setup: ask for a join password (blank = open server)
        prompt_and_validate "Server password (blank = no password)" "" validate_generic_safe_string PAL_PASSWORD 0
    fi

    # Now handle the ADMIN password (separate from the join password --
    # the admin password lets you use in-game admin commands)
    if [[ -n "${PAL_EXISTING_ADMIN_PASSWORD:-}" ]]; then
        # Show existing admin password as default
        prompt_and_validate "Admin password (blank keeps current)" "$PAL_EXISTING_ADMIN_PASSWORD" validate_generic_safe_string PAL_ADMIN_PASSWORD 0
    elif [[ "$ASSUME_DEFAULTS" -eq 1 ]]; then
        # Generate a random 16-character alphanumeric admin password
        PAL_ADMIN_PASSWORD="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16 || true)"
        # Notify the user that an admin password was auto-generated
        log_warn "Non-interactive mode: generated a random admin password."
        # Show the generated password in bold so the user can copy it
        echo -e "${C_BOLD}    Generated admin password: ${PAL_ADMIN_PASSWORD}${C_RESET}"
    else
        # Ask interactively for the admin password -- hidden flag is 1 so
        # the input is NOT shown on screen (like typing a password in a terminal)
        prompt_and_validate "Admin password (in-game admin commands)" "" validate_generic_password PAL_ADMIN_PASSWORD 1
    fi

    # Tell the platform which variables to save to the config file for persistence
    PROFILE_EXTRA_CONFIG_VARS=(PAL_SERVER_NAME PAL_MAX_PLAYERS PAL_PASSWORD PAL_ADMIN_PASSWORD)
}

# validate_pal_max_players(): checks that the user's input is a valid player
# count for Palworld -- must be 1-32
validate_pal_max_players() {
    # Store the user's input in a local variable
    local v="$1"
    # ^[0-9]+$: regex that matches only digits -- must be a whole number
    # v >= 1 && v <= 32: must be in Palworld's supported range
    # || { ... }: if the test fails, print error and return 1 (failure)
    [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 1 && v <= 32 )) || { echo "Must be a whole number between 1 and 32."; return 1; }
    # Return 0 = success (the input is valid)
    return 0
}

# profile_build_launch_args(): builds the command-line arguments for starting
# the Palworld server -- these tell the server how to run
profile_build_launch_args() {
    # Create the data directory if it doesn't exist (-p = don't error if it exists)
    mkdir -p "$INSTANCE_DATA_DIR"
    # LAUNCH_ARGS: a Bash array of all command-line flags for the server
    LAUNCH_ARGS=(
        # Port: which port to listen on for player connections
        "Port=${SERVER_PORT}"
        # ServerName: the name shown in the server browser
        "ServerName=${PAL_SERVER_NAME}"
        # ServerPassword: the password players need to join
        "ServerPassword=${PAL_PASSWORD}"
        # AdminPassword: the password for in-game admin commands
        "AdminPassword=${PAL_ADMIN_PASSWORD}"
        # -players: sets the maximum player count (note the dash prefix)
        "-players=${PAL_MAX_PLAYERS}"
        # These three flags enable multi-threading for better performance --
        # they tell the Unreal Engine to use multiple CPU threads
        -useperfthreads -NoAsyncLoadingThread -UseMultithreadForDS
        # -log: enables logging output so you can see what the server is doing
        -log
        # -SaveDirectoryOverride: tells the server to save world data in our
        # instance directory instead of the default location
        -SaveDirectoryOverride="${INSTANCE_DATA_DIR}"
    )
}

# profile_post_start_notes(): prints helpful tips AFTER the server is set up
profile_post_start_notes() {
    # Print a bold "Note:" label followed by normal text
    echo -e "${C_BOLD}Note:${C_RESET} A fresh Palworld server can take a couple of minutes to fully"
    # Explain that first-time startup is slow (this is normal)
    echo "initialize on first start. Deeper settings (rates, difficulty) live in"
    # Tell them where to find advanced config files
    echo "PalWorldSettings.ini under this instance's server directory."
}

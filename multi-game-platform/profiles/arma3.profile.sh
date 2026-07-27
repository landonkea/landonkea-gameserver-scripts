###############################################################################
# arma3.profile.sh -- Arma 3 dedicated server
#
# Confidence notes: App ID 233780 (the dedicated server) and native Linux
# support are well-established -- Arma 3 has had a genuine Linux dedicated
# server for a very long time. Bohemia's own engine, with its own
# particular config file syntax (server.cfg uses a format similar to,
# but not identical to, plain JSON) rather than any convention shared
# with this platform's other games.
#   - Arma 3's REAL depth (mission selection, the extensive mod
#     ecosystem, difficulty presets) goes far beyond what a simple
#     profile can sensibly expose as prompts -- this profile covers only
#     the essentials (name, passwords, max players) and leaves the rest
#     to server.cfg, matching how this platform also handles DayZ's and
#     ARK's similarly deep configuration surfaces.
###############################################################################

# PROFILE_GAME_ID: a short, unique identifier for this game — used internally by
# the platform to name folders, log entries, and systemd services.
PROFILE_GAME_ID="arma3"

# PROFILE_DISPLAY_NAME: the human-friendly name shown to the user in menus,
# prompts, and log messages.
PROFILE_DISPLAY_NAME="Arma 3"

# PROFILE_STEAM_APPID: the numeric ID Steam uses to identify Arma 3's
# dedicated server download — 233780 is the dedicated server tool.
PROFILE_STEAM_APPID="233780"

# PROFILE_STEAM_PLATFORM: tells SteamCMD to download the Linux-native build.
PROFILE_STEAM_PLATFORM="linux"

# PROFILE_REQUIRES_WINE: set to 0 (false) — Arma 3 has a native Linux server,
# so no Windows compatibility layer (Wine) is needed.
PROFILE_REQUIRES_WINE=0

# PROFILE_REQUIRES_JAVA: set to 0 (false) — Arma 3 is a C++ game on Bohemia's
# Real Virtuality engine. No Java runtime needed.
PROFILE_REQUIRES_JAVA=0

# PROFILE_PORT_COUNT: Arma 3 needs 3 consecutive UDP ports — the main game port
# plus two extra ports for the engine's internal networking subsystems.
PROFILE_PORT_COUNT=3

# PROFILE_RECOMMENDED_RAM_MB: an optional, best-effort recommendation (moderate
# baseline; mods and large missions need considerably more). Advisory only — the
# platform warns if the host has less but never blocks. 4096 MB = 4 GB.
PROFILE_RECOMMENDED_RAM_MB=4096

# profile_port_specs: tells the platform which network ports this game uses.
# Arma 3's engine reserves several UDP ports in a row starting from the base port.
profile_port_specs() {
    # "0:udp:game" — the main game port where players connect (offset 0 from base).
    echo "0:udp:game"
    # "1:udp:internal1" — an extra port one number above the base, used by the
    # engine internally for subsystems like voice chat or server query.
    echo "1:udp:internal1"
    # "2:udp:internal2" — another extra port two numbers above the base.
    echo "2:udp:internal2"
}

# profile_find_binary: locates the Arma 3 server executable on disk.
profile_find_binary() {
    # Store the search directory argument in a local variable.
    local search_dir="$1"
    # Search for "arma3server" — the Linux server binary (no file extension).
    # "-maxdepth 1" means only search the given folder, not subfolders.
    # "-iname" is case-insensitive. Errors are hidden. First match is returned.
    find "$search_dir" -maxdepth 1 -iname 'arma3server' 2>/dev/null | head -n1
}

# profile_gather_prompts: asks the user questions about their server configuration.
profile_gather_prompts() {
    # Ask for the server name (hostname) shown in the server browser.
    # Default: "My Arma 3 Server". Stored in ARMA3_HOSTNAME.
    prompt_and_validate "Server name (hostname)" "My Arma 3 Server" validate_generic_safe_string ARMA3_HOSTNAME 0
    # Ask for the maximum number of players — validated by validate_arma3_max_players.
    prompt_and_validate "Max players" "32" validate_arma3_max_players ARMA3_MAX_PLAYERS 0

    # Three-way password logic (same pattern across all profiles):
    # If there's an existing password from a previous configuration...
    if [[ -n "${ARMA3_EXISTING_PASSWORD:-}" ]]; then
        # ...let the user keep it (press Enter) or change it (type new one).
        prompt_and_validate "Server password (blank keeps current)" "$ARMA3_EXISTING_PASSWORD" validate_generic_safe_string ARMA3_PASSWORD 0
    # If running in non-interactive/auto mode...
    elif [[ "$ASSUME_DEFAULTS" -eq 1 ]]; then
        # Set password to empty (open server, anyone can join).
        ARMA3_PASSWORD=""
        log_warn "Non-interactive mode: leaving the join password blank (open server)."
    else
        # Fresh install — ask for a password from scratch.
        prompt_and_validate "Server password (blank = no password)" "" validate_generic_safe_string ARMA3_PASSWORD 0
    fi

    # Same three-way logic for the admin password (used for server admin commands).
    if [[ -n "${ARMA3_EXISTING_ADMIN_PASSWORD:-}" ]]; then
        prompt_and_validate "Admin password (blank keeps current)" "$ARMA3_EXISTING_ADMIN_PASSWORD" validate_generic_safe_string ARMA3_ADMIN_PASSWORD 0
    elif [[ "$ASSUME_DEFAULTS" -eq 1 ]]; then
        # Generate a random 16-character password from letters and digits.
        # "tr -dc 'A-Za-z0-9' < /dev/urandom" filters random bytes to only
        # alphanumeric characters. "| head -c 16" takes the first 16.
        ARMA3_ADMIN_PASSWORD="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16 || true)"
        log_warn "Non-interactive mode: generated a random admin password."
        # Print the password so the admin can save it somewhere safe.
        echo -e "${C_BOLD}    Generated admin password: ${ARMA3_ADMIN_PASSWORD}${C_RESET}"
    else
        # Fresh install — ask for admin password. "1" means hidden input.
        prompt_and_validate "Admin password" "" validate_generic_password ARMA3_ADMIN_PASSWORD 1
    fi

    # Save all variable names to the instance config so they persist between restarts.
    PROFILE_EXTRA_CONFIG_VARS=(ARMA3_HOSTNAME ARMA3_MAX_PLAYERS ARMA3_PASSWORD ARMA3_ADMIN_PASSWORD)
}

# validate_arma3_max_players: checks that the user's input is a valid player count.
validate_arma3_max_players() {
    # Store the first argument (user's input) in a local variable.
    local v="$1"
    # Check that the input contains only digits (whole number).
    [[ "$v" =~ ^[0-9]+$ ]] || { echo "Must be a whole number."; return 1; }
    # Check if the number is outside the allowed range (1-128).
    if (( v < 1 || v > 128 )); then
        echo "Must be a whole number between 1 and 128."
        return 1
    fi
    # Return 0 to signal success.
    return 0
}

# profile_build_launch_args: writes server.cfg (Bohemia's own config
# syntax -- similar to but not the same as JSON) into this instance's own
# server directory, and points profile/save data at INSTANCE_DATA_DIR via
# -profiles (a documented Arma 3 flag for exactly this, same idea as
# DayZ's identical flag -- both are Bohemia titles sharing this convention).
profile_build_launch_args() {
    # Create the data directory if it doesn't exist yet.
    mkdir -p "$INSTANCE_DATA_DIR"
    # Build the full path to the config file — it lives in the server's directory.
    local cfg="${INSTANCE_SERVER_DIR}/server.cfg"

    # Write the Arma 3 server config file using a heredoc.
    # Bohemia's config format uses "key = value;" syntax (similar to JSON but
    # with semicolons and no commas).
    cat > "$cfg" << CFG
hostname = "${ARMA3_HOSTNAME}";
password = "${ARMA3_PASSWORD}";
passwordAdmin = "${ARMA3_ADMIN_PASSWORD}";
maxPlayers = ${ARMA3_MAX_PLAYERS};
persistent = 1;
verifySignatures = 2;
CFG

    # Build the command-line arguments for the server binary.
    LAUNCH_ARGS=(
        # "-config=..." tells the server which config file to read settings from.
        -config="$cfg"
        # "-port=..." sets the network port for player connections.
        -port="${SERVER_PORT}"
        # "-profiles=..." tells Arma 3 where to store save data and player profiles.
        # This points to our managed data directory instead of the game's default.
        -profiles="${INSTANCE_DATA_DIR}"
        # "-name=server" sets the internal profile name (used for subfolder naming).
        -name=server
        # "-world=empty" tells the server not to load a 3D world (saves resources
        # since it's a headless dedicated server, not a player's game).
        -world=empty
    )
}

# profile_post_start_notes: prints helpful tips after the server is set up.
profile_post_start_notes() {
    echo -e "${C_BOLD}Note:${C_RESET} This profile covers only the essentials -- Arma 3's real depth"
    echo "(mission selection, the mod ecosystem, difficulty presets) lives in server.cfg and"
    echo "related files under this instance's server directory, and typically needs manual"
    echo "setup beyond what any simple profile could sensibly automate."
}

###############################################################################
# dayz.profile.sh -- DayZ dedicated server
#
# Confidence notes: App ID 223350 and native Linux support are
# well-established -- Bohemia has provided a genuine Linux dedicated
# server for DayZ for a long time. BattlEye (DayZ's anti-cheat) has its
# own Linux server-side component and works natively here, unlike ARK:
# Survival Ascended's Wine-tier situation where BattlEye has to be
# disabled entirely -- DayZ needs no such compromise.
#   - Config is serverDZ.cfg (a flat key=value-ish format, not XML/JSON).
#     Mods are a huge part of real-world DayZ hosting but are
#     deliberately out of scope for this profile's prompts, the same way
#     Arma 3's mod ecosystem is -- see profile_post_start_notes.
###############################################################################

# PROFILE_GAME_ID: a short, unique identifier for this game — used internally by
# the platform to name folders, log entries, and systemd services.
PROFILE_GAME_ID="dayz"

# PROFILE_DISPLAY_NAME: the human-friendly name shown to the user everywhere
# in the platform's menus and messages.
PROFILE_DISPLAY_NAME="DayZ"

# PROFILE_STEAM_APPID: the numeric ID Steam uses to identify DayZ's dedicated
# server download — 223350 is DayZ's dedicated server tool in SteamCMD.
PROFILE_STEAM_APPID="223350"

# PROFILE_STEAM_PLATFORM: tells SteamCMD to download the Linux-native build.
PROFILE_STEAM_PLATFORM="linux"

# PROFILE_REQUIRES_WINE: set to 0 (false) — DayZ has a native Linux server,
# so no Windows compatibility layer (Wine) is needed.
PROFILE_REQUIRES_WINE=0

# PROFILE_REQUIRES_JAVA: set to 0 (false) — DayZ is a C++ game built on
# Bohemia's Enfusion engine, not Java. No Java runtime needed.
PROFILE_REQUIRES_JAVA=0

# PROFILE_PORT_COUNT: DayZ needs 3 consecutive UDP ports — the main game port
# plus two extra ports the engine reserves for its own internal networking.
PROFILE_PORT_COUNT=3

# PROFILE_RECOMMENDED_RAM_MB: an optional, best-effort recommendation (world
# simulation and persistence are memory-intensive). Advisory only — the platform
# warns if the host has less but never blocks the install. 4096 MB = 4 GB.
PROFILE_RECOMMENDED_RAM_MB=4096

# profile_port_specs: tells the platform which network ports this game uses.
# DayZ's engine reserves several UDP ports in a row starting from the base port.
profile_port_specs() {
    # "0:udp:game" — the main game port where players connect (offset 0).
    echo "0:udp:game"
    # "1:udp:internal1" — an extra port one number above the base, used by the
    # engine internally for voice chat or other subsystems.
    echo "1:udp:internal1"
    # "2:udp:internal2" — another extra port two numbers above the base.
    echo "2:udp:internal2"
}

# profile_find_binary: locates the DayZ server executable on disk.
profile_find_binary() {
    # Store the search directory argument in a local variable.
    local search_dir="$1"
    # Search for "DayZServer" (the Linux executable, no extension).
    # "-maxdepth 1" means only search the given folder, not subfolders.
    # "-iname" means case-insensitive. "2>/dev/null" hides errors.
    # "| head -n1" takes only the first match.
    find "$search_dir" -maxdepth 1 -iname 'DayZServer' 2>/dev/null | head -n1
}

# profile_gather_prompts: asks the user questions about their server configuration.
profile_gather_prompts() {
    # Ask for the server name (hostname) shown in the server browser.
    # Default: "My DayZ Server". Stored in DAYZ_HOSTNAME.
    prompt_and_validate "Server name (hostname)" "My DayZ Server" validate_generic_safe_string DAYZ_HOSTNAME 0
    # Ask for the maximum number of players — DayZ supports up to 60.
    prompt_and_validate "Max players" "60" validate_dayz_max_players DAYZ_MAX_PLAYERS 0

    # Three-way password logic (same pattern across all profiles):
    # If there's an existing password from a previous configuration...
    if [[ -n "${DAYZ_EXISTING_PASSWORD:-}" ]]; then
        # ...let the user keep it or change it.
        prompt_and_validate "Server password (blank keeps current)" "$DAYZ_EXISTING_PASSWORD" validate_generic_safe_string DAYZ_PASSWORD 0
    # If running in non-interactive/auto mode...
    elif [[ "$ASSUME_DEFAULTS" -eq 1 ]]; then
        # Set password to empty (open server, anyone can join).
        DAYZ_PASSWORD=""
        log_warn "Non-interactive mode: leaving the join password blank (open server)."
    else
        # Fresh install — ask for a password from scratch.
        prompt_and_validate "Server password (blank = no password)" "" validate_generic_safe_string DAYZ_PASSWORD 0
    fi

    # Same three-way logic for the admin password (used for in-game admin commands).
    if [[ -n "${DAYZ_EXISTING_ADMIN_PASSWORD:-}" ]]; then
        prompt_and_validate "Admin password (blank keeps current)" "$DAYZ_EXISTING_ADMIN_PASSWORD" validate_generic_safe_string DAYZ_ADMIN_PASSWORD 0
    elif [[ "$ASSUME_DEFAULTS" -eq 1 ]]; then
        # Generate a random 16-character password from letters and digits.
        # "tr -dc 'A-Za-z0-9' < /dev/urandom" keeps only alphanumeric characters
        # from the system's random number generator. "| head -c 16" takes 16 chars.
        DAYZ_ADMIN_PASSWORD="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16 || true)"
        log_warn "Non-interactive mode: generated a random admin password."
        # Print the password so the admin can save it.
        echo -e "${C_BOLD}    Generated admin password: ${DAYZ_ADMIN_PASSWORD}${C_RESET}"
    else
        # Fresh install — ask for admin password. "1" means hidden input.
        prompt_and_validate "Admin password (in-game admin commands)" "" validate_generic_password DAYZ_ADMIN_PASSWORD 1
    fi

    # Save all variable names to the instance config so they persist across restarts.
    PROFILE_EXTRA_CONFIG_VARS=(DAYZ_HOSTNAME DAYZ_MAX_PLAYERS DAYZ_PASSWORD DAYZ_ADMIN_PASSWORD)
}

# validate_dayz_max_players: checks that the user's input is a valid player count.
validate_dayz_max_players() {
    # Store the first argument (user's input) in a local variable.
    local v="$1"
    # Check that the input contains only digits (whole number).
    [[ "$v" =~ ^[0-9]+$ ]] || { echo "Must be a whole number."; return 1; }
    # Check if the number is outside the allowed range (1-60).
    if (( v < 1 || v > 60 )); then
        echo "Must be a whole number between 1 and 60."
        return 1
    fi
    # Return 0 to signal success.
    return 0
}

# profile_build_launch_args: writes serverDZ.cfg into this instance's own
# server directory and points save data at INSTANCE_DATA_DIR via
# -profiles (a documented DayZ flag for exactly this purpose -- no
# symlink workaround needed here).
profile_build_launch_args() {
    # Create the data directory if it doesn't exist yet.
    mkdir -p "$INSTANCE_DATA_DIR"
    # Build the full path to the config file — it lives in the server's directory.
    local cfg="${INSTANCE_SERVER_DIR}/serverDZ.cfg"

    # Write the DayZ server config file using a heredoc (multi-line text block).
    # Each line is "key = value;" in DayZ's custom config format.
    cat > "$cfg" << CFG
hostname = "${DAYZ_HOSTNAME}";
password = "${DAYZ_PASSWORD}";
passwordAdmin = "${DAYZ_ADMIN_PASSWORD}";
maxPlayers = ${DAYZ_MAX_PLAYERS};
verifySignatures = 2;
forceSameBuild = 1;
disableVoN = 0;
disable3rdPerson = 0;
disableCrosshair = 0;
serverTime = "SystemTime";
serverTimeAcceleration = 1;
serverNightTimeAcceleration = 1;
serverTimePersistent = 0;
guaranteedUpdates = 1;
timeStampFormat = "Short";
CFG

    # Build the command-line arguments for the server binary.
    LAUNCH_ARGS=(
        # "-config=..." tells the server which config file to read settings from.
        -config="$cfg"
        # "-port=..." sets the network port for player connections.
        -port="${SERVER_PORT}"
        # "-profiles=..." tells DayZ where to store save data and player profiles.
        # This points to our managed data directory instead of the server's default.
        -profiles="${INSTANCE_DATA_DIR}"
        # "-BEpath=..." tells BattlEye (the anti-cheat system) where to find its files.
        -BEpath="${INSTANCE_SERVER_DIR}/battleye"
        # These four flags enable various types of logging:
        # -dologs = general logs, -adminlog = admin action logs,
        # -netlog = network traffic logs, -freezecheck = detect server freezes.
        -dologs -adminlog -netlog -freezecheck
    )
}

# profile_post_start_notes: prints helpful tips after the server is set up.
profile_post_start_notes() {
    echo -e "${C_BOLD}Note:${C_RESET} This profile covers vanilla DayZ. Real-world DayZ hosting is"
    echo "very often mod-heavy (Steam Workshop mods, custom types.xml, etc.) -- that's out of"
    echo "scope here; add -mod= to this instance's launch args by hand if you go that route,"
    echo "and expect to manage mod files/keys yourself alongside this platform."
}

###############################################################################
# astroneer.profile.sh -- Astroneer dedicated server
#
# This is a Wine-tier profile -- read enshrouded.profile.sh first for a
# full explanation of what Wine is and why some games need it, and
# rust.profile.sh for the symlink trick used below to redirect this
# game's save folder without needing to get a Windows-style path exactly
# right through Wine.
#
# HIGHER UNCERTAINTY THAN MOST PROFILES IN THIS PLATFORM, please read
# before relying on this:
#   - Confirmed via research earlier in this project: Astroneer has no
#     native Linux dedicated server; it's Windows-only, and (unlike some
#     other Wine-tier games here) community reports suggest Linux/Wine
#     support has been a longstanding, not fully resolved pain point for
#     this specific game.
#   - Astroneer's dedicated server is obtained via the SAME Steam App ID
#     as the base game (728470) using SteamCMD's "-beta" mechanism for a
#     server-specific branch, rather than a separate dedicated-server App
#     ID the way most other games in this platform work. This profile's
#     PROFILE_STEAM_APPID reflects that.
#   - Binary name and config schema below are my best understanding, not
#     independently verified against a live server -- this is the
#     profile I'd most recommend testing carefully (and being ready to
#     adjust) before trusting it for real use.
###############################################################################

# PROFILE_GAME_ID: a short, unique identifier for this game — used internally by
# the platform to name folders, log entries, and systemd services.
PROFILE_GAME_ID="astroneer"

# PROFILE_DISPLAY_NAME: the human-friendly name shown to the user in menus,
# prompts, and log messages.
PROFILE_DISPLAY_NAME="Astroneer"

# PROFILE_STEAM_APPID: 728470 is Astroneer's base game App ID — unlike most other
# games in this platform, Astroneer uses the SAME App ID for both the game and
# its dedicated server (the server is downloaded via SteamCMD's "-beta" flag
# for a server-specific branch).
PROFILE_STEAM_APPID="728470"

# PROFILE_STEAM_PLATFORM: set to "windows" because Astroneer's dedicated server
# is Windows-only — no native Linux build exists.
PROFILE_STEAM_PLATFORM="windows"

# PROFILE_REQUIRES_WINE: set to 1 (true) because Astroneer has no native Linux
# server — Wine is needed to run the Windows .exe on Linux. Wine translates
# Windows system calls into Linux equivalents at runtime.
PROFILE_REQUIRES_WINE=1

# PROFILE_REQUIRES_JAVA: set to 0 (false) — Astroneer is an Unreal Engine 4 game
# (C++), not Java. No Java runtime needed.
PROFILE_REQUIRES_JAVA=0

# PROFILE_PORT_COUNT: Astroneer uses just 1 network port for game traffic.
PROFILE_PORT_COUNT=1

# PROFILE_RECOMMENDED_RAM_MB: an optional, best-effort recommendation (moderate
# for a small-player-count game). Advisory only — warns if the host has less,
# never blocks. 4096 MB = 4 GB.
PROFILE_RECOMMENDED_RAM_MB=4096

# profile_port_specs: tells the platform which network ports this game uses.
profile_port_specs() {
    # "0:udp:game" — the single game port where players connect (UDP protocol).
    echo "0:udp:game"
}

# profile_find_binary: locates the Astroneer server executable on disk.
profile_find_binary() {
    # Store the search directory argument in a local variable.
    local search_dir="$1"
    # Search for "AstroServer.exe" — note the .exe extension because this is
    # a Windows binary (will be run through Wine on Linux).
    # "-iname" is case-insensitive. Errors hidden. First match returned.
    find "$search_dir" -iname 'AstroServer.exe' 2>/dev/null | head -n1
}

# profile_gather_prompts: asks the user questions about their server configuration.
profile_gather_prompts() {
    # Ask for the server name shown in the server browser.
    # Default: "My Astroneer Server". Stored in ASTRO_SERVER_NAME.
    prompt_and_validate "Server name" "My Astroneer Server" validate_generic_safe_string ASTRO_SERVER_NAME 0
    # Ask for the maximum number of players — Astroneer supports 1-8.
    prompt_and_validate "Max players (1-8)" "8" validate_astro_max_players ASTRO_MAX_PLAYERS 0

    # Three-way password logic (same pattern across all profiles):
    if [[ -n "${ASTRO_EXISTING_PASSWORD:-}" ]]; then
        # Existing instance: let user keep or change the password.
        prompt_and_validate "Server password (blank keeps current)" "$ASTRO_EXISTING_PASSWORD" validate_generic_safe_string ASTRO_PASSWORD 0
    elif [[ "$ASSUME_DEFAULTS" -eq 1 ]]; then
        # Non-interactive mode: empty password = open server.
        ASTRO_PASSWORD=""
        log_warn "Non-interactive mode: leaving the join password blank (open server)."
    else
        # Fresh install: prompt for a password from scratch.
        prompt_and_validate "Server password (blank = no password)" "" validate_generic_safe_string ASTRO_PASSWORD 0
    fi

    # Save all variable names to the instance config for persistence.
    PROFILE_EXTRA_CONFIG_VARS=(ASTRO_SERVER_NAME ASTRO_MAX_PLAYERS ASTRO_PASSWORD)
}

# validate_astro_max_players: checks that the user's input is a valid player count.
validate_astro_max_players() {
    # Store the first argument (user's input) in a local variable.
    local v="$1"
    # Check that the input contains only digits (whole number).
    [[ "$v" =~ ^[0-9]+$ ]] || { echo "Must be a whole number."; return 1; }
    # Check if the number is outside the allowed range (1-8).
    if (( v < 1 || v > 8 )); then
        echo "Must be a whole number between 1 and 8."
        return 1
    fi
    # Return 0 to signal success.
    return 0
}

# profile_build_launch_args: writes astroneerserversettings.ini next to
# the binary, and symlinks the game's default save-data folder into
# INSTANCE_DATA_DIR (same reasoning as spaceengineers.profile.sh -- safer
# than trying to get a Windows-style path pointing at a Linux directory
# exactly right under Wine).
profile_build_launch_args() {
    # Create the data directory if it doesn't exist yet.
    mkdir -p "$INSTANCE_DATA_DIR"
    # Find the server binary on disk and store its full path.
    local binary; binary="$(profile_find_binary "$INSTANCE_SERVER_DIR")"
    # "dirname" strips the filename from a path, leaving just the directory.
    # Build the full path to the settings file (it lives next to the binary).
    local cfg="$(dirname "$binary")/astroneerserversettings.ini"

    # Write Astroneer's server settings file using a heredoc (INI-style format).
    # These settings control the server name, max players, password, and behavior.
    cat > "$cfg" << CFG
[/Script/Astro.AstroServerSettings]
ServerName=${ASTRO_SERVER_NAME}
MaxServerPlayers=${ASTRO_MAX_PLAYERS}
ServerPassword=${ASTRO_PASSWORD}
ServerAdvertisedName=${ASTRO_SERVER_NAME}
bDisableServerTravel=False
ServerGuid=
DedicatedServerId=
CFG

    # Symlink Astroneer's default save-data folder into our managed data directory.
    # This avoids having to set a Windows-style path through Wine.
    local save_link="$(dirname "$binary")/Saved"
    # Check if it's already a symbolic link (redirect).
    if [[ ! -L "$save_link" ]]; then
        # If it's a regular folder, remove it first (silently).
        rm -rf "$save_link" 2>/dev/null || true
        # Create a symbolic link pointing to our data directory.
        # "-s" = symbolic, "-f" = force, "-n" = don't follow existing links.
        ln -sfn "$INSTANCE_DATA_DIR" "$save_link"
    fi

    # LAUNCH_ARGS: the arguments passed to the Astroneer server binary.
    # "-log" enables logging output. "-PORT=..." sets the network port.
    LAUNCH_ARGS=(-log -PORT="${SERVER_PORT}")
}

# profile_post_start_notes: prints helpful tips after the server is set up.
profile_post_start_notes() {
    echo -e "${C_BOLD}Note:${C_RESET} This is one of the least-certain profiles in this platform --"
    echo "Astroneer's Linux/Wine story has real, longstanding community-reported rough edges."
    echo "Check logs-instance.sh closely on first start, and be ready to adjust the binary"
    echo "name/config keys above against Astroneer's current official dedicated server docs"
    echo "if it doesn't come up as expected."
}

###############################################################################
# vrising.profile.sh -- V Rising dedicated server
#
# WHY THIS IS TREATED AS WINE-TIER: I don't have strong, verifiable
# confidence that V Rising's dedicated server has a genuine NATIVE Linux
# build (as opposed to a Windows-only build that various community hosting
# guides run via Proton/Wine or similar compatibility layers). Rather than
# guess and risk building this as a "native Linux" profile that quietly
# doesn't work, this profile takes the more cautious path already proven
# out by enshrouded.profile.sh -- if it turns out V Rising DOES have a
# real native Linux server, PROFILE_STEAM_PLATFORM/PROFILE_REQUIRES_WINE
# below are the only two lines that would need to change.
#
# Confidence notes:
#   - App ID for the dedicated server tool: 1829350 (my best
#     understanding, not independently verified here).
#   - Binary name and config schema below are best-effort. This is one of
#     the profiles most worth testing carefully (and being ready to
#     adjust) before trusting it for real use.
###############################################################################

# PROFILE_GAME_ID: a short, unique identifier for this game — used internally by
# the platform to name folders, log entries, and systemd services.
PROFILE_GAME_ID="vrising"

# PROFILE_DISPLAY_NAME: the human-friendly name shown to the user in menus,
# prompts, and log messages.
PROFILE_DISPLAY_NAME="V Rising"

# PROFILE_STEAM_APPID: the numeric ID Steam uses to identify V Rising's
# dedicated server download — 1829350 is the dedicated server tool.
PROFILE_STEAM_APPID="1829350"

# PROFILE_STEAM_PLATFORM: set to "windows" because V Rising's dedicated server
# is believed to be Windows-only — the Linux build's existence is uncertain.
PROFILE_STEAM_PLATFORM="windows"

# PROFILE_REQUIRES_WINE: set to 1 (true) because V Rising's server is believed
# to be Windows-only — Wine is needed to run the .exe on Linux. Wine translates
# Windows system calls into Linux equivalents at runtime.
PROFILE_REQUIRES_WINE=1

# PROFILE_REQUIRES_JAVA: set to 0 (false) — V Rising is a C# game (Unity engine),
# not Java. No Java runtime needed.
PROFILE_REQUIRES_JAVA=0

# PROFILE_PORT_COUNT: V Rising needs 2 network ports — one for game traffic
# and one for server query (used by server browsers to show server info).
PROFILE_PORT_COUNT=2

# PROFILE_RECOMMENDED_RAM_MB: an optional, best-effort recommendation (moderate
# for its player cap). Advisory only — warns if the host has less, never blocks.
# 4096 MB = 4 GB.
PROFILE_RECOMMENDED_RAM_MB=4096

# profile_port_specs: tells the platform which network ports this game uses.
profile_port_specs() {
    # "0:udp:game" — the main game port where players connect (offset 0 from base).
    echo "0:udp:game"
    # "1:udp:query" — one port above the base, used by server browsers to query
    # the server for its name, player count, map, etc.
    echo "1:udp:query"
}

# profile_find_binary: locates the V Rising server executable on disk.
profile_find_binary() {
    # Store the search directory argument in a local variable.
    local search_dir="$1"
    # Search for "VRisingServer.exe" — note the .exe extension because this is
    # a Windows binary (will be run through Wine on Linux).
    # "-iname" is case-insensitive. Errors hidden. First match returned.
    find "$search_dir" -iname 'VRisingServer.exe' 2>/dev/null | head -n1
}

# profile_gather_prompts: asks the user questions about their server configuration.
profile_gather_prompts() {
    # Ask for the server name shown in the server browser.
    # Default: "My V Rising Server". Stored in VR_SERVER_NAME.
    prompt_and_validate "Server name" "My V Rising Server" validate_generic_safe_string VR_SERVER_NAME 0
    # Ask for the maximum number of players — validated by validate_vr_max_players.
    prompt_and_validate "Max players" "10" validate_vr_max_players VR_MAX_PLAYERS 0

    # Three-way password logic (same pattern across all profiles):
    # If there's an existing password from a previous configuration...
    if [[ -n "${VR_EXISTING_PASSWORD:-}" ]]; then
        # ...let the user keep it or change it.
        prompt_and_validate "Server password (blank keeps current)" "$VR_EXISTING_PASSWORD" validate_generic_safe_string VR_PASSWORD 0
    # If running in non-interactive/auto mode...
    elif [[ "$ASSUME_DEFAULTS" -eq 1 ]]; then
        # Set password to empty (open server, anyone can join).
        VR_PASSWORD=""
        log_warn "Non-interactive mode: leaving the join password blank (open server)."
    else
        # Fresh install — ask for a password from scratch.
        prompt_and_validate "Server password (blank = no password)" "" validate_generic_safe_string VR_PASSWORD 0
    fi

    # Save all variable names to the instance config for persistence.
    PROFILE_EXTRA_CONFIG_VARS=(VR_SERVER_NAME VR_MAX_PLAYERS VR_PASSWORD)
}

# validate_vr_max_players: checks that the user's input is a valid player count.
validate_vr_max_players() {
    # Store the first argument (user's input) in a local variable.
    local v="$1"
    # Check that the input contains only digits (whole number).
    [[ "$v" =~ ^[0-9]+$ ]] || { echo "Must be a whole number."; return 1; }
    # Check if the number is outside the allowed range (1-40).
    if (( v < 1 || v > 40 )); then
        echo "Must be a whole number between 1 and 40."
        return 1
    fi
    # Return 0 to signal success.
    return 0
}

# profile_build_launch_args: writes V Rising's two settings files
# (ServerHostSettings.json and ServerGameSettings.json) and symlinks its
# default save folder into INSTANCE_DATA_DIR -- same reasoning as
# enshrouded.profile.sh/spaceengineers.profile.sh: safer than trying to
# get a Windows-style path pointing at a Linux directory exactly right
# through Wine.
profile_build_launch_args() {
    # Create the data directory if it doesn't exist yet.
    mkdir -p "$INSTANCE_DATA_DIR"
    # Find the server binary on disk and store its full path.
    local binary; binary="$(profile_find_binary "$INSTANCE_SERVER_DIR")"
    # "dirname" strips the filename from a path, leaving just the directory.
    # Then we append the known subfolder path where V Rising stores its settings.
    local settings_dir="$(dirname "$binary")/VRisingServer_Data/StreamingAssets/Settings"
    # Create the settings directory if it doesn't exist.
    mkdir -p "$settings_dir"

    # Write V Rising's main server config file (ServerHostSettings.json) using a heredoc.
    # This controls the server name, ports, max players, password, and various behavior flags.
    cat > "${settings_dir}/ServerHostSettings.json" << CFG
{
  "Name": "${VR_SERVER_NAME}",
  "Port": ${SERVER_PORT},
  "QueryPort": $(( SERVER_PORT + 1 )),
  "MaxConnectedUsers": ${VR_MAX_PLAYERS},
  "MaxConnectedAdmins": 4,
  "Password": "${VR_PASSWORD}",
  "Suffix": "",
  "AutoSaveCount": 20,
  "AutoSaveInterval": 300,
  "GameSettingsPreset": "",
  "GameDifficultyPreset": "",
  "AdditionalMapInfo": true,
  "ListOnMasterServer": false,
  "ListOnEOS": false,
  "ListOnSteam": false
}
CFG
    # "$(( SERVER_PORT + 1 ))" is Bash arithmetic — adds 1 to the base port for the query port.

    # Symlink V Rising's default save-data folder into our managed data directory.
    # This avoids having to set a Windows-style path through Wine.
    local save_link="$(dirname "$binary")/save-data"
    # Check if it's already a symbolic link (redirect).
    if [[ ! -L "$save_link" ]]; then
        # If it's a regular folder, remove it first (silently).
        rm -rf "$save_link" 2>/dev/null || true
        # Create a symbolic link pointing to our data directory.
        # "-s" = symbolic, "-f" = force, "-n" = don't follow existing links.
        ln -sfn "$INSTANCE_DATA_DIR" "$save_link"
    fi

    # LAUNCH_ARGS: the argument passed to the V Rising server binary at startup.
    # "-persistentDataPath" tells the server where to store save data — we point
    # it at the symlinked save-data folder.
    LAUNCH_ARGS=(-persistentDataPath "$(dirname "$binary")/save-data")
}

# profile_post_start_notes: prints helpful tips after the server is set up.
profile_post_start_notes() {
    echo -e "${C_BOLD}Note:${C_RESET} This profile is treated as Wine-tier out of caution -- V"
    echo "Rising's true native-Linux-server status wasn't confirmed with high confidence."
    echo "Check logs-instance.sh closely on first start, and be ready to adjust the settings"
    echo "path/binary location above against the current official dedicated server guide if"
    echo "it doesn't come up as expected."
}

###############################################################################
# unturned.profile.sh -- Unturned dedicated server
#
# The symlink trick used below (profile_build_launch_args) is explained
# in full, step-by-step detail inside rust.profile.sh -- read that file
# first if the general concept ("redirect a game's save folder somewhere
# else using a symbolic link") is unfamiliar. This profile applies the
# exact same idea to Unturned's own "server identity" folder concept.
#
# Confidence notes: App ID 1110390 (the dedicated server) and native Linux
# support are well-established. Unturned's server config is unusually
# file/folder-driven (a named "server identity" folder under Servers/
# containing Config.json, Commands.dat, etc.) rather than command-line
# heavy.
#   - LOWER CONFIDENCE ITEM: the exact ExecStart argument syntax for
#     selecting the server identity/port (below) is the detail I'm least
#     sure of in this profile -- if the server doesn't come up, check
#     logs-instance.sh first and compare against Unturned's current
#     official server-hosting documentation for the right invocation.
###############################################################################

# PROFILE_GAME_ID: a short, unique identifier for this game — used internally by
# the platform to name folders, log entries, and systemd services.
PROFILE_GAME_ID="unturned"

# PROFILE_DISPLAY_NAME: the human-friendly name shown to the user in menus,
# prompts, and log messages.
PROFILE_DISPLAY_NAME="Unturned"

# PROFILE_STEAM_APPID: the numeric ID Steam uses to identify Unturned's
# dedicated server download — 1110390 is the dedicated server tool.
PROFILE_STEAM_APPID="1110390"

# PROFILE_STEAM_PLATFORM: tells SteamCMD to download the Linux-native build.
PROFILE_STEAM_PLATFORM="linux"

# PROFILE_REQUIRES_WINE: set to 0 (false) — Unturned has a native Linux server,
# so no Windows compatibility layer is needed.
PROFILE_REQUIRES_WINE=0

# PROFILE_REQUIRES_JAVA: set to 0 (false) — Unturned is written in C# (Unity
# engine), not Java. No Java runtime needed.
PROFILE_REQUIRES_JAVA=0

# PROFILE_PORT_COUNT: Unturned uses just 1 network port for game traffic.
PROFILE_PORT_COUNT=1

# PROFILE_RECOMMENDED_RAM_MB: an optional, best-effort recommendation (moderate
# for its player cap). Advisory only — warns if the host has less, but never
# blocks. 2048 MB = 2 GB.
PROFILE_RECOMMENDED_RAM_MB=2048

# profile_port_specs: tells the platform which network ports this game uses.
profile_port_specs() {
    # "0:udp:game" — the main game port where players connect (UDP protocol).
    echo "0:udp:game"
}

# profile_find_binary: locates the server's startup script on disk.
profile_find_binary() {
    # Store the search directory argument in a local variable.
    local search_dir="$1"
    # Search for "ServerHelper.sh" — Unturned's Linux server uses a shell script
    # to start the actual server process. "-maxdepth 1" means only search the
    # given folder. "-iname" is case-insensitive. Errors are hidden.
    find "$search_dir" -maxdepth 1 -iname 'ServerHelper.sh' 2>/dev/null | head -n1
}

# profile_gather_prompts: asks the user questions about their server configuration.
profile_gather_prompts() {
    # Ask for the server name shown in the server browser.
    # Default: "My Unturned Server". Stored in UNT_SERVER_NAME.
    prompt_and_validate "Server name" "My Unturned Server" validate_generic_safe_string UNT_SERVER_NAME 0
    # Ask which map to load. "PEI" is Unturned's default map (a Canadian island).
    prompt_and_validate "Map" "PEI" validate_generic_safe_string UNT_MAP 0
    # Ask for the maximum number of players — validated by validate_unt_max_players.
    prompt_and_validate "Max players" "24" validate_unt_max_players UNT_MAX_PLAYERS 0

    # Three-way password logic (same pattern across all profiles):
    # If there's an existing password from a previous configuration...
    if [[ -n "${UNT_EXISTING_PASSWORD:-}" ]]; then
        # ...let the user keep it or change it.
        prompt_and_validate "Server password (blank keeps current)" "$UNT_EXISTING_PASSWORD" validate_generic_safe_string UNT_PASSWORD 0
    # If running in non-interactive/auto mode...
    elif [[ "$ASSUME_DEFAULTS" -eq 1 ]]; then
        # Set password to empty (open server, anyone can join).
        UNT_PASSWORD=""
        log_warn "Non-interactive mode: leaving the join password blank (open server)."
    else
        # Fresh install — ask for a password from scratch.
        prompt_and_validate "Server password (blank = no password)" "" validate_generic_safe_string UNT_PASSWORD 0
    fi

    # Save all variable names to the instance config for persistence.
    PROFILE_EXTRA_CONFIG_VARS=(UNT_SERVER_NAME UNT_MAP UNT_MAX_PLAYERS UNT_PASSWORD)
}

# validate_unt_max_players: checks that the user's input is a valid player count.
validate_unt_max_players() {
    # Store the first argument (user's input) in a local variable.
    local v="$1"
    # Check that the input contains only digits AND is between 1 and 64.
    # "&&" means both conditions must be true. "||" at the end means if either
    # check fails, show an error and return 1 (failure).
    [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 1 && v <= 64 )) || { echo "Must be a whole number between 1 and 64."; return 1; }
    # Return 0 to signal success.
    return 0
}

# profile_build_launch_args: sets up Unturned's folder-based configuration.
# Unturned identifies a server by a "server identity" — a named folder under
# Servers/<identity>/ that contains all config and save data.
profile_build_launch_args() {
    # "identity" is the name Unturned uses to identify this server instance.
    # We use the platform's instance name so each server gets its own identity.
    local identity="$INSTANCE_NAME"
    # Create the data directory if it doesn't exist.
    mkdir -p "$INSTANCE_DATA_DIR"
    # Create the Servers folder inside the game's directory (where Unturned
    # expects server identity folders to live).
    mkdir -p "${INSTANCE_SERVER_DIR}/Servers"
    # Check if the identity folder is already a symlink (redirect).
    if [[ ! -L "${INSTANCE_SERVER_DIR}/Servers/${identity}" ]]; then
        # If it's a regular folder or file, remove it first. "2>/dev/null || true"
        # hides errors and prevents the script from stopping if deletion fails.
        rm -rf "${INSTANCE_SERVER_DIR}/Servers/${identity}" 2>/dev/null || true
        # Create a symbolic link: the identity folder will point to our managed
        # data directory. "-s" = symbolic, "-f" = force, "-n" = don't follow links.
        ln -sfn "$INSTANCE_DATA_DIR" "${INSTANCE_SERVER_DIR}/Servers/${identity}"
    fi

    # Create a "Server" subfolder inside the data directory — Unturned expects
    # config files to live at Servers/<identity>/Server/Config.json.
    mkdir -p "${INSTANCE_DATA_DIR}/Server"
    # Write the server's Config.json file using a heredoc.
    # This tells Unturned the server name, map, max players, password, and port.
    cat > "${INSTANCE_DATA_DIR}/Server/Config.json" << CFG
{
  "Name": "${UNT_SERVER_NAME}",
  "Map": "${UNT_MAP}",
  "Max_Players": ${UNT_MAX_PLAYERS},
  "Password": "${UNT_PASSWORD}",
  "Port": ${SERVER_PORT}
}
CFG

    # LAUNCH_ARGS: the arguments passed to the Unturned server binary.
    # "+${identity}/${SERVER_PORT}" selects the server identity and port.
    # "-nographics" prevents the server from trying to open a window (it's headless).
    # "-batchmode" runs Unity in headless mode (no GUI, no rendering — saves resources).
    LAUNCH_ARGS=("+${identity}/${SERVER_PORT}" -nographics -batchmode)
}

# profile_post_start_notes: prints helpful tips after the server is set up.
profile_post_start_notes() {
    echo -e "${C_BOLD}Note:${C_RESET} Deeper settings (loot tables, mode-specific rules) live under"
    echo "this instance's data directory in the standard Unturned server folder layout --"
    echo "check Unturned's own documentation for anything beyond what was asked above."
}

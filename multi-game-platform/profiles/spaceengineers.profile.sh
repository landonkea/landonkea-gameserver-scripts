###############################################################################
# spaceengineers.profile.sh -- Space Engineers dedicated server
#
# This is a Wine-tier profile -- read enshrouded.profile.sh first for a
# full explanation of what Wine is and why some games need it. This file
# adds one more wrinkle worth understanding: its config file (below)
# writes a Windows-style path (using backslashes) is deliberately AVOIDED
# here in favor of a symbolic-link redirect instead (see rust.profile.sh
# for how that trick works) -- getting a Windows path to correctly point
# at a Linux folder through Wine's own internal path-translation is easy
# to get subtly wrong, so the symlink approach sidesteps that risk
# entirely.
#
# Confidence notes: confirmed via research earlier in this project --
# Space Engineers has no native Linux dedicated server; it's Windows-only
# and needs Wine (community reports describe it as fiddly under Wine,
# more so than Enshrouded). App ID for the dedicated server tool: 298740.
#   - Config is SpaceEngineers-Dedicated.cfg (XML) -- the schema below
#     reflects long-documented keys; if a future update changes them, the
#     server's own log (via logs-instance.sh) should show a clear error.
###############################################################################

# PROFILE_GAME_ID: a short, unique identifier for this game — used internally by
# the platform to name folders, log entries, and systemd services.
PROFILE_GAME_ID="spaceengineers"

# PROFILE_DISPLAY_NAME: the human-friendly name shown to the user in menus,
# prompts, and log messages.
PROFILE_DISPLAY_NAME="Space Engineers"

# PROFILE_STEAM_APPID: the numeric ID Steam uses to identify this game's
# dedicated server download — 298740 is Space Engineers' dedicated server tool.
PROFILE_STEAM_APPID="298740"

# PROFILE_STEAM_PLATFORM: tells SteamCMD which OS files to download — "windows"
# means this game only has a Windows server binary, so Wine is needed on Linux.
PROFILE_STEAM_PLATFORM="windows"

# PROFILE_REQUIRES_WINE: set to 1 (true) because Space Engineers has NO native
# Linux server — Wine is required to run the Windows .exe on Linux.
# Wine translates Windows system calls into Linux equivalents at runtime.
PROFILE_REQUIRES_WINE=1

# PROFILE_REQUIRES_JAVA: set to 0 (false) — Space Engineers is a C++ game,
# not a Java game. No Java runtime is needed.
PROFILE_REQUIRES_JAVA=0

# PROFILE_PORT_COUNT: tells the platform how many network ports to reserve.
# Space Engineers uses just 1 port for game traffic.
PROFILE_PORT_COUNT=1

# PROFILE_RECOMMENDED_RAM_MB: an optional, best-effort recommendation
# (voxel/physics simulation is memory-intensive). This is advisory only — the
# platform warns if the host has less but never blocks the install.
# 8192 MB = 8 GB recommended.
PROFILE_RECOMMENDED_RAM_MB=8192

# profile_port_specs: tells the platform which network ports this game uses.
profile_port_specs() {
    # "0:udp:game" means offset 0 from the base port, UDP protocol — the main
    # game port where players connect and gameplay data flows.
    echo "0:udp:game"
}

# profile_find_binary: locates the server's main executable program on disk.
profile_find_binary() {
    # Store the first argument (the directory to search) in a local variable.
    local search_dir="$1"
    # Search for "SpaceEngineersDedicated.exe" — note the .exe extension because
    # this is a Windows binary (it will be run through Wine on Linux).
    # "-iname" means case-insensitive search. "2>/dev/null" hides errors.
    # "| head -n1" takes only the first match found.
    find "$search_dir" -iname 'SpaceEngineersDedicated.exe' 2>/dev/null | head -n1
}

# profile_gather_prompts: asks the user questions about their server configuration.
profile_gather_prompts() {
    # Ask for the world name — this is what Space Engineers calls a save file.
    # Default: "MySpaceEngineersWorld". Stored in SE_WORLD_NAME.
    prompt_and_validate "World name" "MySpaceEngineersWorld" validate_generic_safe_string SE_WORLD_NAME 0
    # Ask for the maximum number of players (1-16 for Space Engineers).
    prompt_and_validate "Max players" "8" validate_se_max_players SE_MAX_PLAYERS 0

    # Three-way password logic (same pattern as other profiles):
    # Check if there's an existing password from a previous config.
    if [[ -n "${SE_EXISTING_PASSWORD:-}" ]]; then
        # Let the user keep it (press Enter) or change it (type a new one).
        prompt_and_validate "Server password (blank keeps current)" "$SE_EXISTING_PASSWORD" validate_generic_safe_string SE_PASSWORD 0
    # Non-interactive mode: use defaults without asking.
    elif [[ "$ASSUME_DEFAULTS" -eq 1 ]]; then
        # Empty password = open server anyone can join.
        SE_PASSWORD=""
        log_warn "Non-interactive mode: leaving the join password blank (open server)."
    else
        # Fresh install: prompt for password from scratch.
        prompt_and_validate "Server password (blank = no password)" "" validate_generic_safe_string SE_PASSWORD 0
    fi

    # PROFILE_EXTRA_CONFIG_VARS: list all variables to save for this instance
    # so they're remembered between restarts.
    PROFILE_EXTRA_CONFIG_VARS=(SE_WORLD_NAME SE_MAX_PLAYERS SE_PASSWORD)
}

# validate_se_max_players: checks that the user's input is a valid player count.
validate_se_max_players() {
    # Store the first argument (the user's input) in a local variable.
    local v="$1"
    # Check that the input contains only digits (is a whole number).
    # If not, show an error message and return 1 (failure).
    [[ "$v" =~ ^[0-9]+$ ]] || { echo "Must be a whole number."; return 1; }
    # Check if the number is outside the allowed range (1-16).
    if (( v < 1 || v > 16 )); then
        echo "Must be a whole number between 1 and 16."
        return 1
    fi
    # Return 0 to signal validation passed.
    return 0
}

# profile_build_launch_args: writes the config file and builds the launch command.
# Space Engineers uses an XML config file instead of command-line arguments.
profile_build_launch_args() {
    # Create the data directory if it doesn't exist.
    mkdir -p "$INSTANCE_DATA_DIR"
    # Find the server binary on disk and store its full path.
    local binary; binary="$(profile_find_binary "$INSTANCE_SERVER_DIR")"
    # "dirname" strips the filename from a path, leaving just the directory.
    # So if binary is ".../SpaceEngineersDedicated.exe", cfg becomes
    # ".../SpaceEngineers-Dedicated.cfg" (in the same folder as the binary).
    local cfg="$(dirname "$binary")/SpaceEngineers-Dedicated.cfg"

    # "cat > "$cfg" << CFG" writes everything between CFG and CFG into the config file.
    # This is called a "heredoc" — it's a way to write multi-line text to a file.
    # The ${VAR} references are replaced with actual values when the file is written.
    cat > "$cfg" << CFG
<?xml version="1.0"?>
<MyConfigDedicated>
  <SessionName>${SE_WORLD_NAME}</SessionName>
  <WorldName>${SE_WORLD_NAME}</WorldName>
  <MaxPlayers>${SE_MAX_PLAYERS}</MaxPlayers>
  <ServerPort>${SERVER_PORT}</ServerPort>
  <Password>${SE_PASSWORD}</Password>
  <PauseGameWhenEmpty>true</PauseGameWhenEmpty>
</MyConfigDedicated>
CFG

    # Space Engineers saves under a folder relative to the binary by
    # default -- rather than trying to get a Windows-style path pointing
    # at a Linux directory exactly right inside the XML above (Wine's
    # path translation is easy to get subtly wrong), symlink its default
    # "Saves" folder into our own INSTANCE_DATA_DIR instead, same
    # approach as enshrouded.profile.sh's savegame symlink.
    local save_link="$(dirname "$binary")/Saves"
    # "-L" checks if the path is already a symbolic link (a redirect).
    if [[ ! -L "$save_link" ]]; then
        # "rm -rf" deletes the target. "2>/dev/null || true" hides errors
        # and prevents the script from stopping if the delete fails.
        rm -rf "$save_link" 2>/dev/null || true
        # "ln -sfn" creates a symbolic link: $save_link will now point to
        # INSTANCE_DATA_DIR. "-s" means symbolic, "-f" means force (replace
        # if it exists), "-n" means don't follow existing links.
        ln -sfn "$INSTANCE_DATA_DIR" "$save_link"
    fi

    # LAUNCH_ARGS: the arguments passed to the Wine binary at startup.
    # "-noconsole" hides the Windows console window.
    # "-ignorelastsession" prevents the server from trying to reload the
    # previous session's settings (we want it to use our config file instead).
    LAUNCH_ARGS=(-noconsole -ignorelastsession)
}

# profile_post_start_notes: prints helpful tips after the server is set up.
profile_post_start_notes() {
    echo -e "${C_BOLD}Note:${C_RESET} Space Engineers has no native Linux server -- this instance"
    echo "runs the Windows binary through Wine. Community reports describe this as more"
    echo "fragile than most Wine-based games here; check logs-instance.sh first if it"
    echo "doesn't come up."
}

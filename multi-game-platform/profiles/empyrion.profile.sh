###############################################################################
# empyrion.profile.sh -- Empyrion - Galactic Survival dedicated server
#
# Confidence notes: confirmed via research earlier in this project --
# Empyrion has NO native Linux dedicated server at all (Windows-only), and
# even the community LinuxGSM project (which specializes in exactly this
# kind of Linux game-server management) explicitly declined to support it
# because it would require Wine, which that project doesn't support. This
# is a genuine signal that this game's Wine story is rougher than most of
# the other Wine-tier games in this platform -- treat this as one of the
# more fragile profiles here.
#   - App ID 530870 (the dedicated server) is my best understanding.
#   - Binary name and config schema below are best-effort, not
#     independently verified against a live server.
###############################################################################

# PROFILE_GAME_ID: a short, unique identifier for this game -- used internally
# by the platform to name folders, log entries, and systemd services
PROFILE_GAME_ID="empyrion"
# PROFILE_DISPLAY_NAME: the human-readable name shown to users in menus and prompts
PROFILE_DISPLAY_NAME="Empyrion - Galactic Survival"
# PROFILE_STEAM_APPID: the Steam "App ID" for the dedicated server download
PROFILE_STEAM_APPID="530870"
# PROFILE_STEAM_PLATFORM: "windows" because Empyrion only has a Windows server --
# this means Wine (a Windows compatibility layer) is required to run it on Linux
PROFILE_STEAM_PLATFORM="windows"
# PROFILE_REQUIRES_WINE: 1 means this game DOES need Wine to run on Linux --
# Wine translates Windows programs to run on Linux
PROFILE_REQUIRES_WINE=1
# PROFILE_REQUIRES_JAVA: 0 means this game does NOT need Java
PROFILE_REQUIRES_JAVA=0
# PROFILE_PORT_COUNT: Empyrion only needs 1 network port
PROFILE_PORT_COUNT=1

# PROFILE_RECOMMENDED_RAM_MB: an optional, best-effort recommendation (voxel/physics simulation is memory-intensive).
# This is a advisory floor, not a hard technical limit -- the platform warns
# clearly (and asks for confirmation interactively) if the host has less than
# this, but never blocks the install outright.
# 8192 MB = 8 GB -- Empyrion simulates lots of 3D blocks and physics
PROFILE_RECOMMENDED_RAM_MB=8192

# profile_port_specs(): declares which network ports this game needs
profile_port_specs() {
    # Port 0 is the only port (UDP) -- handles both game and query traffic
    echo "0:udp:game"
}

# profile_find_binary(): locates the Empyrion server program on disk
# NOTE: this looks for a .exe file because Empyrion is a Windows-only server
profile_find_binary() {
    # search_dir: the directory to search in
    local search_dir="$1"
    # Look for EmpyrionDedicated.exe -- a Windows executable that will
    # need Wine to run on Linux
    find "$search_dir" -iname 'EmpyrionDedicated.exe' 2>/dev/null | head -n1
}

# profile_gather_prompts(): asks the user game-specific questions during setup
profile_gather_prompts() {
    # Ask for the server's display name
    prompt_and_validate "Server name" "My Empyrion Server" validate_generic_safe_string EMP_SERVER_NAME 0
    # Ask how many players can join -- default 8
    prompt_and_validate "Max players" "8" validate_emp_max_players EMP_MAX_PLAYERS 0

    # Check if a join password was already set from a previous configuration
    if [[ -n "${EMP_EXISTING_PASSWORD:-}" ]]; then
        # Show existing password as default -- user can press Enter to keep it
        prompt_and_validate "Server password (blank keeps current)" "$EMP_EXISTING_PASSWORD" validate_generic_safe_string EMP_PASSWORD 0
    # Auto mode: skip the question and leave the server open
    elif [[ "$ASSUME_DEFAULTS" -eq 1 ]]; then
        # Empty password = anyone can join
        EMP_PASSWORD=""
        # Warn the user
        log_warn "Non-interactive mode: leaving the join password blank (open server)."
    else
        # First-time setup: ask for a join password
        prompt_and_validate "Server password (blank = no password)" "" validate_generic_safe_string EMP_PASSWORD 0
    fi

    # Save these variables to the config file for persistence
    PROFILE_EXTRA_CONFIG_VARS=(EMP_SERVER_NAME EMP_MAX_PLAYERS EMP_PASSWORD)
}

# validate_emp_max_players(): checks that the user entered a valid player count
# for Empyrion -- must be 1-16
validate_emp_max_players() {
    # Store the user's input in a local variable
    local v="$1"
    # ^[0-9]+$: regex that matches only digits -- must be a whole number
    # || { ... }: if it's NOT a whole number, print error and return 1
    [[ "$v" =~ ^[0-9]+$ ]] || { echo "Must be a whole number."; return 1; }
    # Check the range: Empyrion supports 1-16 players
    if (( v < 1 || v > 16 )); then
        # Out of range: print error
        echo "Must be a whole number between 1 and 16."
        # Return 1 = failure
        return 1
    fi
    # Return 0 = success
    return 0
}

# profile_build_launch_args: writes dedicated.yaml (Empyrion's own
# settings file) and symlinks its default save location into
# INSTANCE_DATA_DIR, same reasoning as this platform's other Wine-tier
# profiles.
profile_build_launch_args() {
    # Create the data directory if it doesn't exist
    mkdir -p "$INSTANCE_DATA_DIR"
    # local binary: find the server .exe file path
    # The semicolon after binary tells Bash "this is a new command on the same line"
    # profile_find_binary: calls our function above to locate the .exe file
    local binary; binary="$(profile_find_binary "$INSTANCE_SERVER_DIR")"
    # local cfg: the path to Empyrion's config file (dedicated.yaml)
    # dirname "$binary": gets the folder containing the binary (removes the filename)
    local cfg="$(dirname "$binary")/dedicated.yaml"

    # Write the YAML config file using a heredoc
    cat > "$cfg" << CFG
GameConfig:
  # GameName: the name of this game world
  GameName: ${EMP_SERVER_NAME}
  # MaxPlayers: maximum number of players allowed to connect
  MaxPlayers: ${EMP_MAX_PLAYERS}
ServerConfig:
  # Srv_Port: which port to listen on for player connections
  Srv_Port: ${SERVER_PORT}
  # Srv_Password: password needed to join (empty = no password)
  Srv_Password: ${EMP_PASSWORD}
  # Srv_Name: the name shown in the server browser
  Srv_Name: ${EMP_SERVER_NAME}
CFG

    # local save_link: the path to the "Saves" folder where Empyrion expects
    # to find world save data
    local save_link="$(dirname "$binary")/Saves"
    # Check if the symlink doesn't already exist
    if [[ ! -L "$save_link" ]]; then
        # -L: tests if something is a symbolic link (a shortcut to another location)
        # If it's NOT a symlink, we need to set it up
        # First, remove any existing folder/file at that location
        rm -rf "$save_link" 2>/dev/null || true
        # rm -rf: force-remove a directory and everything inside it
        # 2>/dev/null: hide errors, || true: don't crash if it fails
        # ln -sfn: create a symbolic link (shortcut)
        # -s: make it a symlink (not a copy), -f: force (overwrite if exists),
        # -n: treat the link as a regular file if it points to a directory
        ln -sfn "$INSTANCE_DATA_DIR" "$save_link"
    fi

    # LAUNCH_ARGS: command-line flags for the Empyrion server
    LAUNCH_ARGS=(
        # -dedicated: run in dedicated server mode (no game window)
        -dedicated
        # "$cfg": path to the config file we wrote above
        "$cfg"
    )
}

# profile_post_start_notes(): prints helpful tips AFTER the server is set up
profile_post_start_notes() {
    # Warn the user that this is a fragile profile (Wine-based, less tested)
    echo -e "${C_BOLD}Note:${C_RESET} This is one of the more fragile Wine-tier profiles in this"
    # Explain that even the LinuxGSM community project doesn't support this
    echo "platform -- even the community LinuxGSM project declined to support Empyrion via"
    # Advise the user to watch logs closely
    echo "Wine. Check logs-instance.sh closely, and treat this as the profile most likely to"
    # Warn that troubleshooting may be needed on first deployment
    echo "need real troubleshooting on first deployment."
}

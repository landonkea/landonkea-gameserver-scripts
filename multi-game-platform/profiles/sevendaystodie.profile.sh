###############################################################################
# sevendaystodie.profile.sh -- 7 Days to Die dedicated server
#
# Confidence notes: App ID 294420 and the startserver.sh launcher are
# well-established, long-documented facts. Config is via an XML file
# passed with -configfile= -- the exact set of supported XML keys has
# grown over time; the keys below (name, port, players, password,
# game world/name) have been stable for a long time.
###############################################################################

# PROFILE_GAME_ID: a short, unique identifier for this game -- used internally
# by the platform to name folders, log entries, and systemd services
PROFILE_GAME_ID="sevendaystodie"
# PROFILE_DISPLAY_NAME: the human-readable name shown to users in menus and prompts
# "7 Days to Die" is the official game title
PROFILE_DISPLAY_NAME="7 Days to Die"
# PROFILE_STEAM_APPID: the Steam "App ID" for the dedicated server download
PROFILE_STEAM_APPID="294420"
# PROFILE_STEAM_PLATFORM: which OS platform to download from Steam
PROFILE_STEAM_PLATFORM="linux"
# PROFILE_REQUIRES_WINE: 0 means this game runs natively on Linux, no Wine needed
PROFILE_REQUIRES_WINE=0
# PROFILE_REQUIRES_JAVA: 0 means this game does NOT need Java (despite being
# written in C++, not Java)
PROFILE_REQUIRES_JAVA=0
# PROFILE_PORT_COUNT: how many network ports this game server needs --
# 7DTD needs 2 (game port + query port)
PROFILE_PORT_COUNT=2

# PROFILE_RECOMMENDED_RAM_MB: an optional, best-effort recommendation (world generation and simulation are memory-intensive).
# This is a advisory floor, not a hard technical limit -- the platform warns
# clearly (and asks for confirmation interactively) if the host has less than
# this, but never blocks the install outright.
# 4096 MB = 4 GB -- 7DTD generates huge worlds that use a lot of RAM
PROFILE_RECOMMENDED_RAM_MB=4096

# profile_port_specs(): declares which network ports this game needs
profile_port_specs() {
    # Port 0 is the main game port (UDP) -- where players connect to play
    echo "0:udp:game"
    # Port 1 is the query port (UDP) -- where server browsers get server info
    echo "1:udp:query"
}

# profile_find_binary(): locates the 7DTD server program on disk
profile_find_binary() {
    # search_dir: the directory to search in (first argument)
    local search_dir="$1"
    # Look for startserver.sh (the game's launch script) in the top-level directory
    # -maxdepth 1: only search the immediate directory, not subfolders
    # -iname: case-insensitive name match
    find "$search_dir" -maxdepth 1 -iname 'startserver.sh' 2>/dev/null | head -n1
}

# profile_gather_prompts(): asks the user game-specific questions during setup
profile_gather_prompts() {
    # Ask for the server's display name
    prompt_and_validate "Server name" "My 7DTD Server" validate_generic_safe_string SDTD_SERVER_NAME 0
    # Ask for the world/map name -- "RWG" stands for "Randomly Generated World"
    prompt_and_validate "World/map name" "RWG" validate_generic_safe_string SDTD_WORLD_NAME 0
    # Ask how many players can join -- default 8
    prompt_and_validate "Max players" "8" validate_sdtd_max_players SDTD_MAX_PLAYERS 0

    # Check if a join password was already set from a previous configuration
    if [[ -n "${SDTD_EXISTING_PASSWORD:-}" ]]; then
        # Show existing password as default -- user can press Enter to keep it
        prompt_and_validate "Server password (blank keeps current)" "$SDTD_EXISTING_PASSWORD" validate_generic_safe_string SDTD_PASSWORD 0
    # Auto mode: skip the question and leave the server open (no password)
    elif [[ "$ASSUME_DEFAULTS" -eq 1 ]]; then
        # Empty password means anyone can join
        SDTD_PASSWORD=""
        # Warn the user the server is open
        log_warn "Non-interactive mode: leaving the join password blank (open server)."
    else
        # First-time setup: ask for a join password
        prompt_and_validate "Server password (blank = no password)" "" validate_generic_safe_string SDTD_PASSWORD 0
    fi

    # Now handle the TELNET ADMIN password (for remote console access --
    # you can telnet into the server to run admin commands)
    if [[ -n "${SDTD_EXISTING_ADMIN_PASSWORD:-}" ]]; then
        # Show existing admin password as default
        prompt_and_validate "Telnet admin password (blank keeps current)" "$SDTD_EXISTING_ADMIN_PASSWORD" validate_generic_safe_string SDTD_ADMIN_PASSWORD 0
    elif [[ "$ASSUME_DEFAULTS" -eq 1 ]]; then
        # Generate a random 16-character alphanumeric admin password
        SDTD_ADMIN_PASSWORD="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16 || true)"
        # Notify the user about the auto-generated password
        log_warn "Non-interactive mode: generated a random telnet admin password."
        # Show it in bold so the user can copy it
        echo -e "${C_BOLD}    Generated admin password: ${SDTD_ADMIN_PASSWORD}${C_RESET}"
    else
        # Ask interactively -- hidden flag 1 means input is masked (not shown on screen)
        prompt_and_validate "Telnet admin password (for remote console access)" "" validate_generic_password SDTD_ADMIN_PASSWORD 1
    fi

    # Save these variables to the config file for persistence between restarts
    PROFILE_EXTRA_CONFIG_VARS=(SDTD_SERVER_NAME SDTD_WORLD_NAME SDTD_MAX_PLAYERS SDTD_PASSWORD SDTD_ADMIN_PASSWORD)
}

# validate_sdtd_max_players(): checks that the user entered a valid player count
# for 7 Days to Die -- must be 1-64
validate_sdtd_max_players() {
    # Store the user's input in a local variable
    local v="$1"
    # ^[0-9]+$: regex that matches only digits (whole numbers)
    # v >= 1 && v <= 64: must be in 7DTD's supported range
    # || { ... }: if the test fails, print error and return 1
    [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 1 && v <= 64 )) || { echo "Must be a whole number between 1 and 64."; return 1; }
    # Return 0 = success (input is valid)
    return 0
}

# profile_build_launch_args: writes a minimal serverconfig.xml into this
# instance's own data directory, pointing save data at the same place via
# UserDataFolder/SaveGameFolder (documented 7DTD config keys for exactly
# this purpose).
profile_build_launch_args() {
    # Create the data directory and a "saves" subfolder for world save data
    mkdir -p "${INSTANCE_DATA_DIR}/saves"
    # local cfg: the path to the XML config file we're about to write
    local cfg="${INSTANCE_DATA_DIR}/serverconfig.xml"
    # cat > "$cfg" << CFG: creates the config file using a "heredoc" --
    # everything between << CFG and the final CFG is written to the file
    # The backslash-dollar-sign variables (like ${SDTD_SERVER_NAME}) are
    # replaced with their actual values when the file is written
    cat > "$cfg" << CFG
<?xml version="1.0"?>
<ServerSettings>
  <!-- ServerName: the name shown in the server browser -->
  <property name="ServerName" value="${SDTD_SERVER_NAME}"/>
  <!-- ServerPort: which port players connect to -->
  <property name="ServerPort" value="${SERVER_PORT}"/>
  <!-- ServerMaxPlayerCount: maximum number of players -->
  <property name="ServerMaxPlayerCount" value="${SDTD_MAX_PLAYERS}"/>
  <!-- ServerPassword: password needed to join (empty = no password) -->
  <property name="ServerPassword" value="${SDTD_PASSWORD}"/>
  <!-- GameWorld: the name of the world/map to generate or load -->
  <property name="GameWorld" value="${SDTD_WORLD_NAME}"/>
  <!-- GameName: a unique name for this game save -->
  <property name="GameName" value="${INSTANCE_NAME}"/>
  <!-- UserDataFolder: where the server stores its data files -->
  <property name="UserDataFolder" value="${INSTANCE_DATA_DIR}"/>
  <!-- SaveGameFolder: where world save files are stored -->
  <property name="SaveGameFolder" value="${INSTANCE_DATA_DIR}/saves"/>
  <!-- TelnetEnabled: allows remote admin access via telnet -->
  <property name="TelnetEnabled" value="true"/>
  <!-- TelnetPort: the port for telnet admin connections (game port + 100) -->
  <property name="TelnetPort" value="$(( SERVER_PORT + 100 ))"/>
  <!-- TelnetPassword: password for telnet admin access -->
  <property name="TelnetPassword" value="${SDTD_ADMIN_PASSWORD}"/>
</ServerSettings>
CFG
    # LAUNCH_ARGS: command-line flags for the 7DTD server
    LAUNCH_ARGS=(
        # -configfile: path to our XML config file
        -configfile="$cfg"
        # -logfile: path to the server's log file
        -logfile "${INSTANCE_LOG_DIR}/7dtd_server.log"
        # -quit: exit the server process when it receives a quit signal
        -quit
        # -batchmode: run without a GUI (headless mode for dedicated servers)
        -batchmode
        # -nographics: don't try to render graphics (no monitor attached)
        -nographics
        # -dedicated: run in dedicated server mode (not as a game client)
        -dedicated
    )
}

# profile_post_start_notes(): prints helpful tips AFTER the server is set up
profile_post_start_notes() {
    # Warn the user that first startup can be slow
    echo -e "${C_BOLD}Note:${C_RESET} A new random-generated world (RWG) can take several minutes to"
    # Explain this is normal for 7DTD specifically
    echo "generate on first start -- this is normal for this game specifically, more so than"
    # Reassure them that other games are faster
    echo "most others in this platform."
}

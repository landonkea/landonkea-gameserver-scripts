###############################################################################
# conanexiles.profile.sh -- Conan Exiles dedicated server
#
# Confidence notes: App ID 443030 and the ConanSandboxServer binary/Unreal
# Engine launch convention are well-established. Like most Unreal Engine
# dedicated servers, deeper settings (difficulty, rates, mods) live in
# ServerSettings.ini/Engine.ini rather than the command line -- this
# profile covers what's commonly exposed via CLI flags and leaves the rest
# to those files, same approach as arksurvivalevolved.profile.sh.
###############################################################################

# PROFILE_GAME_ID: a short, unique identifier for this game -- used internally
# by the platform to name folders, log entries, and systemd services
PROFILE_GAME_ID="conanexiles"
# PROFILE_DISPLAY_NAME: the human-readable name shown to users in menus and prompts
PROFILE_DISPLAY_NAME="Conan Exiles"
# PROFILE_STEAM_APPID: the Steam "App ID" for the dedicated server download --
# Steam uses these numbers to identify every game/tool in its catalog
PROFILE_STEAM_APPID="443030"
# PROFILE_STEAM_PLATFORM: which OS platform to download from Steam -- "linux"
# means the native Linux version is available
PROFILE_STEAM_PLATFORM="linux"
# PROFILE_REQUIRES_WINE: 0 means this game runs natively on Linux, no Wine needed
# (Wine is a compatibility layer for running Windows programs on Linux)
PROFILE_REQUIRES_WINE=0
# PROFILE_REQUIRES_JAVA: 0 means this game does NOT need Java installed to run
PROFILE_REQUIRES_JAVA=0
# PROFILE_PORT_COUNT: how many network ports this game server needs --
# the platform will allocate that many consecutive ports from a pool
PROFILE_PORT_COUNT=2

# PROFILE_RECOMMENDED_RAM_MB: an optional, best-effort recommendation (a moderately heavy Unreal Engine title).
# This is a advisory floor, not a hard technical limit -- the platform warns
# clearly (and asks for confirmation interactively) if the host has less than
# this, but never blocks the install outright.
# 6144 MB = 6 GB of RAM -- this is how much memory the platform suggests you have
PROFILE_RECOMMENDED_RAM_MB=6144

# profile_port_specs(): declares which network ports this game needs and their
# protocol (UDP vs TCP) and purpose -- the platform uses this to open firewall
# rules and assign port numbers automatically
profile_port_specs() {
    # Port 0 is the main game port (UDP) -- this is where players connect
    echo "0:udp:game"
    # Port 1 is the query port (UDP) -- this is where server browsers ask
    # "how many players are online?" and get server info
    echo "1:udp:query"
}

# profile_find_binary(): given a directory to search in, locates the actual
# server program file on disk -- the platform calls this to know what to execute
profile_find_binary() {
    # local: creates a variable that only exists inside this function
    # search_dir: stores the first argument ($1) which is the directory to search
    local search_dir="$1"
    # find: searches for the server binary by its known file path pattern inside
    # the Steam download -- -ipath means case-insensitive path match,
    # 2>/dev/null hides errors, head -n1 takes only the first match
    find "$search_dir" -ipath '*ConanSandbox/Binaries/Linux/ConanSandboxServer' 2>/dev/null | head -n1
}

# profile_gather_prompts(): asks the user game-specific questions during setup
# and stores their answers in variables -- this is the interactive "setup wizard"
# part of the profile
profile_gather_prompts() {
    # prompt_and_validate: asks the user a question, validates their answer using
    # the given function, and stores the result in the named variable --
    # arguments are: prompt text, default value, validator function, variable name,
    # hidden flag (0=visible, user sees what they type; 1=hidden, like a password)
    # Here we ask for the server's display name
    prompt_and_validate "Server name" "My Conan Exiles Server" validate_generic_safe_string CONAN_SERVER_NAME 0
    # Ask how many players can join at once (max 100 for Conan)
    prompt_and_validate "Max players" "40" validate_conan_max_players CONAN_MAX_PLAYERS 0

    # Check if a password was already set from a previous run (for reconfiguration)
    if [[ -n "${CONAN_EXISTING_PASSWORD:-}" ]]; then
        # If there IS an existing password, offer it as the default so the user
        # can just press Enter to keep it -- the :-} syntax means "use empty string
        # if the variable doesn't exist" to avoid errors
        prompt_and_validate "Server password (blank keeps current)" "$CONAN_EXISTING_PASSWORD" validate_generic_safe_string CONAN_PASSWORD 0
    # If we're in non-interactive/auto mode (ASSUME_DEFAULTS=1), don't ask questions
    elif [[ "$ASSUME_DEFAULTS" -eq 1 ]]; then
        # Set password to empty string = no password = anyone can join
        CONAN_PASSWORD=""
        # log_warn: prints a yellow/orange warning message so the user notices it
        log_warn "Non-interactive mode: leaving the join password blank (open server)."
    else
        # First-time interactive setup: ask for a password, empty means no password
        prompt_and_validate "Server password (blank = no password)" "" validate_generic_safe_string CONAN_PASSWORD 0
    fi

    # PROFILE_EXTRA_CONFIG_VARS: tells the platform which variables to save to
    # the config file so they persist between restarts -- this is a Bash array
    # (list) of variable names
    PROFILE_EXTRA_CONFIG_VARS=(CONAN_SERVER_NAME CONAN_MAX_PLAYERS CONAN_PASSWORD)
}

# validate_conan_max_players(): checks that the user entered a valid player count
# for Conan Exiles specifically -- must be 1-100
validate_conan_max_players() {
    # local v: stores the first argument (the user's input) in a short variable name
    local v="$1"
    # ^[0-9]+$: a regex (regular expression) that matches only digits (0-9) --
    # ^ means "start of string", + means "one or more", $ means "end of string"
    # v >= 1 && v <= 100: also checks the number is in the valid range
    # || means "if the test fails, then..." -- the curly braces run multiple commands
    # { echo "error message"; return 1; } prints an error and exits the function
    # with a failure code (1 means failure in Bash)
    [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 1 && v <= 100 )) || { echo "Must be a whole number between 1 and 100."; return 1; }
    # return 0: success! 0 means "no error" in Bash
    return 0
}

# profile_build_launch_args(): builds the list of command-line arguments that
# will be passed to the server program when it starts -- these tell the server
# its name, port, max players, etc.
profile_build_launch_args() {
    # mkdir -p: creates the data directory (and any missing parent directories)
    # if it doesn't already exist -- -p means "don't error if it already exists"
    mkdir -p "$INSTANCE_DATA_DIR"
    # local: declares a variable that only exists in this function
    # query_port: the query port is always 1 higher than the game port --
    # $(( ... )) is Bash math -- this calculates SERVER_PORT + 1
    local query_port=$(( SERVER_PORT + 1 ))
    # LAUNCH_ARGS: a Bash array that holds all the command-line flags --
    # each entry becomes one argument when the server is started
    LAUNCH_ARGS=(
        # -log: tells the Unreal Engine server to write log output
        -log
        # -Port: tells the server which port to listen on for player connections
        -Port="${SERVER_PORT}"
        # -QueryPort: tells the server which port to use for server browser queries
        -QueryPort="${query_port}"
        # -ServerName: the name that appears in the server browser
        -ServerName="${CONAN_SERVER_NAME}"
        # -MaxPlayers: the maximum number of players allowed to connect
        -MaxPlayers="${CONAN_MAX_PLAYERS}"
    )
    # Only add the password argument if the user actually set one --
    # an empty password means the server is open to everyone
    if [[ -n "$CONAN_PASSWORD" ]]; then
        # LAUNCH_ARGS+=(...): appends a new item to the end of the array
        LAUNCH_ARGS+=(-Password="${CONAN_PASSWORD}")
    fi
}

# profile_post_start_notes(): prints helpful tips to the user AFTER the server
# has been installed/started -- this tells them what to do next
profile_post_start_notes() {
    # echo -e: prints text, and -e enables special characters like color codes
    # ${C_BOLD}...${C_RESET}: these are color variables -- bold text, then reset
    # back to normal so the rest of the terminal isn't bold
    echo -e "${C_BOLD}Note:${C_RESET} Deeper settings (difficulty, rates, mods) live in"
    # echo: prints a plain line of text to the terminal
    echo "ServerSettings.ini and Engine.ini under this instance's server directory --"
    # The final tip: edit those files directly, then restart the server
    echo "edit those directly for anything beyond what was asked above, then restart."
}

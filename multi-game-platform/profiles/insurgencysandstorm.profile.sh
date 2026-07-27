###############################################################################
# insurgencysandstorm.profile.sh -- Insurgency: Sandstorm dedicated server
#
# NOTE: despite being from the same studio lineage as the original
# Insurgency (a Source engine mod), Sandstorm is built on Unreal Engine 4
# instead -- it does NOT use this platform's Source-engine template
# (teamfortress2.profile.sh). Its shape is closer to this platform's other
# UE4 games (arksurvivalevolved.profile.sh, conanexiles.profile.sh,
# palworld.profile.sh): a native Linux binary, "-flag" style launch
# arguments, and Game.ini/Engine.ini for deeper settings.
#
# Confidence notes: App ID 581330 (the dedicated server) is my best
# understanding, and the general UE4 launch shape below follows the same
# pattern as this platform's other UE4 games -- but this profile is less
# independently verified than most others here. Watch logs-instance.sh
# closely on first deployment.
###############################################################################

# PROFILE_GAME_ID: a short, unique identifier for this game — used internally by
# the platform to name folders, log entries, and systemd services.
PROFILE_GAME_ID="insurgencysandstorm"

# PROFILE_DISPLAY_NAME: the human-friendly name shown to the user in menus,
# prompts, and log messages — this is what the player actually recognizes.
PROFILE_DISPLAY_NAME="Insurgency: Sandstorm"

# PROFILE_STEAM_APPID: the numeric ID Steam uses to identify this game's
# dedicated server download — SteamCMD needs this number to fetch the right files.
# 581330 is the Insurgency: Sandstorm dedicated server tool.
PROFILE_STEAM_APPID="581330"

# PROFILE_STEAM_PLATFORM: tells SteamCMD which operating system's files to
# download — "linux" means Linux-native binaries are available.
PROFILE_STEAM_PLATFORM="linux"

# PROFILE_REQUIRES_WINE: set to 0 (false) because Insurgency: Sandstorm has a
# native Linux server — no Windows compatibility layer is needed.
PROFILE_REQUIRES_WINE=0

# PROFILE_REQUIRES_JAVA: set to 0 (false) because this game is built on
# Unreal Engine 4 (C++), not Java — no Java runtime is needed.
PROFILE_REQUIRES_JAVA=0

# PROFILE_PORT_COUNT: tells the platform how many network ports this game needs
# to reserve — Insurgency: Sandstorm uses 2 ports (game traffic + query port).
PROFILE_PORT_COUNT=2

# PROFILE_RECOMMENDED_RAM_MB: an optional, best-effort recommendation (a
# moderately heavy Unreal Engine title). This is an advisory floor, not a hard
# technical limit — the platform warns clearly if the host has less, but never
# blocks the install outright. 4096 MB = 4 GB recommended.
PROFILE_RECOMMENDED_RAM_MB=4096

# profile_port_specs: a function that tells the platform which network ports
# this game uses and what protocol each one talks.
profile_port_specs() {
    # "0:udp:game" means offset 0 from the base port, using UDP protocol, labeled
    # "game" — this is the main port players connect to for gameplay.
    echo "0:udp:game"
    # "1:udp:query" means offset 1 from the base port (base + 1), using UDP
    # protocol, labeled "query" — this port is used by server browsers to get
    # status info about the server (player count, map name, etc.).
    echo "1:udp:query"
}

# profile_find_binary: a function that searches the server's installed files to
# locate the main executable program that starts the game server.
profile_find_binary() {
    # "local search_dir="$1"" stores the first argument (where to search).
    local search_dir="$1"
    # "find" searches for the server binary.
    # "-ipath '*Insurgency/Binaries/Linux/InsurgencyServer-Linux-Shipping'" looks for
    # the exact path structure Unreal Engine 4 uses on Linux — this is the dedicated
    # server binary's known location inside the game's files.
    # "-iname" makes the search case-insensitive. "2>/dev/null" hides errors.
    # "| head -n1" takes only the first match.
    find "$search_dir" -ipath '*Insurgency/Binaries/Linux/InsurgencyServer-Linux-Shipping' 2>/dev/null | head -n1
}

# profile_gather_prompts: a function that asks the user a series of questions
# about how they want their server configured.
# "prompt_and_validate" shows a question, validates the answer using the given
# function, and stores the result in the named variable.
profile_gather_prompts() {
    # Ask for the server name shown in the server browser.
    # Default: "My Sandstorm Server". Stored in INS_SERVER_NAME.
    prompt_and_validate "Server name" "My Sandstorm Server" validate_generic_safe_string INS_SERVER_NAME 0
    # Ask which map (level) to load first. Default: "Canyon".
    prompt_and_validate "Map" "Canyon" validate_generic_safe_string INS_MAP 0
    # Ask which scenario/game mode to play. Default: "Skirmish".
    prompt_and_validate "Scenario/game mode" "Skirmish" validate_generic_safe_string INS_SCENARIO 0
    # Ask for the maximum number of players — validated by validate_ins_max_players.
    prompt_and_validate "Max players" "16" validate_ins_max_players INS_MAX_PLAYERS 0

    # Check if this is an existing instance that already has a password set.
    # "${INS_EXISTING_PASSWORD:-}" uses Bash's default-value syntax — if the
    # variable is unset, it becomes empty instead of causing an error.
    if [[ -n "${INS_EXISTING_PASSWORD:-}" ]]; then
        # Existing instance: let the user keep or change the password.
        prompt_and_validate "Server password (blank keeps current)" "$INS_EXISTING_PASSWORD" validate_generic_safe_string INS_PASSWORD 0
    # Non-interactive mode: use defaults without asking questions.
    elif [[ "$ASSUME_DEFAULTS" -eq 1 ]]; then
        # Empty password means the server is open to anyone.
        INS_PASSWORD=""
        log_warn "Non-interactive mode: leaving the join password blank (open server)."
    else
        # Fresh install: prompt for a password from scratch.
        prompt_and_validate "Server password (blank = no password)" "" validate_generic_safe_string INS_PASSWORD 0
    fi

    # Same three-way logic as above, but for the admin password (used for in-game admin commands).
    if [[ -n "${INS_EXISTING_ADMIN_PASSWORD:-}" ]]; then
        prompt_and_validate "Admin password (blank keeps current)" "$INS_EXISTING_ADMIN_PASSWORD" validate_generic_safe_string INS_ADMIN_PASSWORD 0
    elif [[ "$ASSUME_DEFAULTS" -eq 1 ]]; then
        # "tr -dc 'A-Za-z0-9' < /dev/urandom" reads random bytes, keeping only
        # letters and digits. "| head -c 16" takes the first 16 characters.
        # "$(...)" captures the output into the variable.
        INS_ADMIN_PASSWORD="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16 || true)"
        log_warn "Non-interactive mode: generated a random admin password."
        # Print the generated password so the admin can save it somewhere safe.
        echo -e "${C_BOLD}    Generated admin password: ${INS_ADMIN_PASSWORD}${C_RESET}"
    else
        # Fresh install — ask for admin password. The "1" means hidden input.
        prompt_and_validate "Admin password" "" validate_generic_password INS_ADMIN_PASSWORD 1
    fi

    # PROFILE_EXTRA_CONFIG_VARS: a Bash array listing all variable names that
    # should be saved to the instance's config file so they persist between restarts.
    PROFILE_EXTRA_CONFIG_VARS=(INS_SERVER_NAME INS_MAP INS_SCENARIO INS_MAX_PLAYERS INS_PASSWORD INS_ADMIN_PASSWORD)
}

# validate_ins_max_players: a custom validation function that checks whether
# the user's input is a valid player count for Insurgency: Sandstorm.
validate_ins_max_players() {
    # "local v="$1"" stores the user's input in a local variable called v.
    local v="$1"
    # "^[0-9]+$" is a regex that matches ONLY digits — checks the input is a number.
    # "|| { echo "..."; return 1; }" means if it's NOT a number, show error and fail.
    [[ "$v" =~ ^[0-9]+$ ]] || { echo "Must be a whole number."; return 1; }
    # "(( v < 2 || v > 32 ))" checks if v is outside the valid range (2-32 players).
    # "||" means "or" — if either condition is true, the input is invalid.
    if (( v < 2 || v > 32 )); then
        echo "Must be a whole number between 2 and 32."
        return 1
    fi
    # "return 0" means "validation passed" — 0 is Bash's success code.
    return 0
}

# profile_build_launch_args: builds the list of command-line arguments that will
# be passed to the server binary when it starts. Also writes the config file.
profile_build_launch_args() {
    # "mkdir -p" creates the data directory (and any parent directories) if it
    # doesn't already exist. "-p" means "don't error if it already exists".
    mkdir -p "$INSTANCE_DATA_DIR"
    # Build a combined map+scenario+players+password string using Unreal Engine 4's
    # query-parameter style. This is how Insurgency: Sandstorm encodes its startup
    # settings in a single argument. For example:
    # "Canyon?Scenario=Scenario_Canyon_Skirmish?MaxPlayers=16?Password=mypass"
    local map_arg="${INS_MAP}?Scenario=Scenario_${INS_MAP}_${INS_SCENARIO}?MaxPlayers=${INS_MAX_PLAYERS}?Password=${INS_PASSWORD}"

    # LAUNCH_ARGS is a Bash array of all the arguments passed to the server binary.
    LAUNCH_ARGS=(
        # The map argument built above — tells the server which map, scenario, etc.
        "$map_arg"
        # "-log" tells the server to write log output to the console.
        -log
        # "-Port=27015" sets the main game port (the port players connect to).
        "-Port=${SERVER_PORT}"
        # "-QueryPort=27016" sets the query port (base port + 1), used by server browsers.
        "-QueryPort=$(( SERVER_PORT + 1 ))"
        # "$(( SERVER_PORT + 1 ))" is Bash arithmetic — it adds 1 to the base port.
        # "-AdminPassword=secret" sets the password for admin commands in-game.
        "-AdminPassword=${INS_ADMIN_PASSWORD}"
        # "-Hostname=My Sandstorm Server" sets the name shown in the server browser.
        "-Hostname=${INS_SERVER_NAME}"
    )
}

# profile_post_start_notes: prints helpful tips after the server is set up.
profile_post_start_notes() {
    echo -e "${C_BOLD}Note:${C_RESET} The scenario name built from your map/mode answers above"
    echo "follows Sandstorm's common naming convention (Scenario_<Map>_<Mode>), but exact"
    echo "scenario names vary per map -- check logs-instance.sh if the server starts but the"
    echo "wrong (or no) scenario loads, and adjust to the exact scenario name for your chosen"
    echo "map from the game's own scenario list."
}

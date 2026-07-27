###############################################################################
# arksurvivalascended.profile.sh -- ARK: Survival Ascended dedicated server
#
# This profile combines two patterns explained fully elsewhere: the
# unusual "?key=value" launch-argument style is explained in detail
# inside arksurvivalevolved.profile.sh, and the Wine tier (needed because
# this game has no native Linux server at all) is explained in detail
# inside enshrouded.profile.sh. Read both if either concept is unfamiliar.
#
# Confidence notes:
#   - Confirmed via research earlier in this project: ARK: Survival
#     Ascended (ASA) has no native Linux server at all -- Windows-only,
#     needs Wine, needs 24GB+ RAM as a realistic minimum, and BattlEye
#     (its anti-cheat) does NOT work under Wine -- it must be explicitly
#     disabled (-NoBattlEye) for the server to run on Linux at all. This
#     is a real security/fair-play trade-off, not a minor detail: an
#     ASA server on this platform is running without anti-cheat.
#   - This is ARK 2 in spirit (a full remake on Unreal Engine 5), NOT the
#     same server/save-compatible product as ARK: Survival Evolved --
#     see arksurvivalevolved.profile.sh for the original game, a
#     completely separate, native-Linux, non-Wine profile.
#   - Dedicated server App ID: 2430930. Launch convention is the same
#     map"?key=value" style as ARK: Survival Evolved, with some
#     ASA-specific additions (-NoBattlEye, -culture=en).
###############################################################################

# PROFILE_GAME_ID: a short, unique identifier for this game -- used
# internally by the platform to name folders, log entries, and systemd
# services. Must match this file's own name (arksurvivalascended).
PROFILE_GAME_ID="arksurvivalascended"

# PROFILE_DISPLAY_NAME: the human-readable name shown in menus, summaries,
# and log messages -- this can have spaces and punctuation unlike the ID.
PROFILE_DISPLAY_NAME="ARK: Survival Ascended"

# PROFILE_STEAM_APPID: Valve's unique ID number for this game's dedicated
# server files -- SteamCMD (the download tool) uses this to know what to
# fetch. 2430930 is ASA's own dedicated server App ID.
PROFILE_STEAM_APPID="2430930"

# PROFILE_STEAM_PLATFORM="windows": tells SteamCMD to download the
# WINDOWS version of the files -- there simply is no Linux version
# available for this game's server at all.
PROFILE_STEAM_PLATFORM="windows"

# PROFILE_REQUIRES_WINE=1: tells the shared platform script to install
# Wine (a Windows-compatibility layer) and run this game through it,
# since there's no native Linux binary. Each Wine game gets its own
# private "Wine prefix" so multiple instances don't interfere.
PROFILE_REQUIRES_WINE=1

# PROFILE_REQUIRES_JAVA=0: this game does NOT need a Java Virtual
# Machine to run -- 0 means "no Java needed."
PROFILE_REQUIRES_JAVA=0

# PROFILE_PORT_COUNT=2: this game needs 2 network ports in a row
# (one for game traffic, one for Steam query lookups).
PROFILE_PORT_COUNT=2

# PROFILE_RECOMMENDED_RAM_MB: an optional, best-effort recommendation
# (extensively documented as needing this much -- see this profile's
# own header notes above about 24GB+ being a realistic minimum).
# This is an advisory floor, not a hard technical limit -- the platform
# warns clearly (and asks for confirmation interactively) if the host
# has less than this, but never blocks the install outright.
PROFILE_RECOMMENDED_RAM_MB=24576

# profile_port_specs: tells the platform which ports to open in the
# firewall and what to call each one. Each line is "offset:protocol:desc"
# where offset is added to the base port the admin chose.
profile_port_specs() {
    # offset 0 (the base port itself), UDP protocol, labeled "game"
    echo "0:udp:game"
    # offset 1 (one port higher), UDP protocol, labeled "query"
    echo "1:udp:query"
}

# profile_find_binary: given a folder path ($1), searches for the actual
# ASA server executable inside it and prints its full path.
profile_find_binary() {
    # local: makes this variable exist only inside this function
    local search_dir="$1"
    # find: searches for the Windows .exe file -- -ipath means case-
    # insensitive path match, 2>/dev/null hides permission errors,
    # head -n1 takes only the first match found
    find "$search_dir" -ipath '*ShooterGame/Binaries/Win64/ArkAscendedServer.exe' 2>/dev/null | head -n1
}

# profile_gather_prompts: asks the person setting up this instance
# whatever ASA-specific questions it needs (map, name, passwords, etc.)
# -- on top of the generic questions the platform already asks.
profile_gather_prompts() {
    # Warn the admin about the two big caveats for this game: it needs
    # a LOT of RAM, and anti-cheat won't work under Wine at all.
    log_warn "ARK: Survival Ascended realistically needs 24GB+ RAM per instance, and BattlEye"
    log_warn "anti-cheat does NOT work under Wine -- this instance will run WITHOUT BattlEye."

    # Ask which map to load -- "TheIsland_WP" is ASA's default map.
    # prompt_and_validate takes: prompt text, default value, validator
    # function name, variable name to store result in, hidden flag (0=visible).
    prompt_and_validate "Map" "TheIsland_WP" validate_generic_safe_string ASA_MAP 0
    # Ask for the session name that players will see in the server browser.
    prompt_and_validate "Session name (shown to players)" "My ASA Server" validate_generic_safe_string ASA_SESSION_NAME 0
    # Ask for the maximum number of players allowed -- uses a custom
    # validator specific to ASA's limits (defined below in this file).
    prompt_and_validate "Max players" "20" validate_asa_max_players ASA_MAX_PLAYERS 0

    # Password handling: three different cases depending on the situation.
    # ${VAR:-} means "VAR's value, or empty text if VAR isn't set yet."
    if [[ -n "${ASA_EXISTING_PASSWORD:-}" ]]; then
        # Case 1: instance already exists with a password -- offer to
        # keep the current one as the default instead of forcing a new one.
        prompt_and_validate "Server password (blank keeps current)" "$ASA_EXISTING_PASSWORD" validate_generic_safe_string ASA_PASSWORD 0
    elif [[ "$ASSUME_DEFAULTS" -eq 1 ]]; then
        # Case 2: fully-automatic mode (-y flag) -- no human present,
        # so leave password blank (open server) and warn about it.
        ASA_PASSWORD=""
        log_warn "Non-interactive mode: leaving the join password blank (open server)."
    else
        # Case 3: a real person is at the keyboard -- ask directly,
        # defaulting to "no password" if they just press Enter.
        prompt_and_validate "Server password (blank = no password)" "" validate_generic_safe_string ASA_PASSWORD 0
    fi

    # Admin password: same three-case pattern as the join password above,
    # but this one controls in-game admin commands (cheat commands, etc.).
    if [[ -n "${ASA_EXISTING_ADMIN_PASSWORD:-}" ]]; then
        # Case 1: reuse the existing admin password if one is saved.
        prompt_and_validate "Admin password (blank keeps current)" "$ASA_EXISTING_ADMIN_PASSWORD" validate_generic_safe_string ASA_ADMIN_PASSWORD 0
    elif [[ "$ASSUME_DEFAULTS" -eq 1 ]]; then
        # Case 2: auto-generate a random 16-character password since
        # no one is here to type one. "tr -dc 'A-Za-z0-9'" keeps only
        # letters and digits from /dev/urandom's random byte stream.
        ASA_ADMIN_PASSWORD="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16 || true)"
        log_warn "Non-interactive mode: generated a random admin password."
        # Show the generated password on screen so the admin can save it.
        echo -e "${C_BOLD}    Generated admin password: ${ASA_ADMIN_PASSWORD}${C_RESET}"
    else
        # Case 3: ask a real person, hiding the typed characters (flag=1).
        prompt_and_validate "Admin password (in-game admin commands)" "" validate_generic_password ASA_ADMIN_PASSWORD 1
    fi

    # PROFILE_EXTRA_CONFIG_VARS: tells the platform which variable names
    # to permanently save to disk for this instance -- everything above
    # that we want to remember across restarts.
    PROFILE_EXTRA_CONFIG_VARS=(ASA_MAP ASA_SESSION_NAME ASA_MAX_PLAYERS ASA_PASSWORD ASA_ADMIN_PASSWORD)
}

# validate_asa_max_players: checks that the answer is a whole number
# between 1 and 200 (ASA's supported player-count range).
validate_asa_max_players() {
    # local v="$1" stores the answer being checked into a short variable.
    local v="$1"
    # =~ ^[0-9]+$ is a regex meaning "entirely made of digits, nothing else"
    [[ "$v" =~ ^[0-9]+$ ]] || { echo "Must be a whole number."; return 1; }
    # (( )) does arithmetic -- checks the number is within ASA's range.
    if (( v < 1 || v > 200 )); then
        echo "Must be a whole number between 1 and 200."
        return 1
    fi
    # return 0 means "this answer is valid."
    return 0
}

# profile_build_launch_args: runs right before the server starts every
# time -- builds the command-line arguments that tell ASA what map to
# load, what to call itself, and how to run.
profile_build_launch_args() {
    # Make sure the instance's data folder exists before writing into it.
    mkdir -p "$INSTANCE_DATA_DIR"
    # ASA uses a "query port" for Steam browser lookups -- it's always
    # the game port + 1.
    local query_port=$(( SERVER_PORT + 1 ))
    # ASA's launch style is a single long string: "MapName?listen?Key=value"
    # pairs, each separated by "?" -- this is explained in detail in
    # arksurvivalevolved.profile.sh's header comment block.
    local map_arg="${ASA_MAP}?listen?SessionName=${ASA_SESSION_NAME}?ServerPassword=${ASA_PASSWORD}?ServerAdminPassword=${ASA_ADMIN_PASSWORD}?Port=${SERVER_PORT}?QueryPort=${query_port}?MaxPlayers=${ASA_MAX_PLAYERS}"

    # LAUNCH_ARGS is the array of words handed to the server program.
    LAUNCH_ARGS=(
        "$map_arg"                          # the big map?settings string
        -server                             # tells the binary "run as a dedicated server"
        -log                                # tells it to write detailed log output
        -NoBattlEye                         # disables BattlEye anti-cheat (required under Wine)
        -culture=en                         # forces English language
        -AltSaveDirectoryName="${INSTANCE_DATA_DIR}"  # redirect save data into our instance folder
    )
}

# profile_post_start_notes: extra plain-English tips shown after setup
# finishes, specific to anything worth knowing about this game.
profile_post_start_notes() {
    # Remind the admin about the two big caveats: no anti-cheat, and
    # high RAM requirements.
    echo -e "${C_BOLD}Note:${C_RESET} This instance is running WITHOUT BattlEye anti-cheat (required"
    echo "for it to run under Wine at all) -- factor that into who you invite. Also confirm"
    echo "this machine actually has the RAM ASA needs (24GB+ is a realistic minimum per"
    echo "instance) before adding more shards of this specific game."
}

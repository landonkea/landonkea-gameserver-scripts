###############################################################################
# arksurvivalevolved.profile.sh -- ARK: Survival Evolved dedicated server
#
# Confidence notes:
#   - App ID 376030 (native Linux dedicated server) confirmed via research
#     earlier in this project.
#   - THE UNUSUAL PART: ARK's launch convention is a URL-query-string-like
#     single argument (map name, then "?key=value" pairs), followed by
#     separate "-flag" style arguments -- this profile reflects that
#     long-documented convention, but ARK has a large, sprawling
#     configuration surface (GameUserSettings.ini/Game.ini for anything
#     not covered by the command line), and exact behavior can shift
#     between updates more than most other profiles here. This is one of
#     the higher-uncertainty profiles in this platform -- verify the
#     launch actually works as expected before relying on it.
#   - Map name defaults to "TheIsland" (the original, always-available map).
#   - This is ARK 1 (Survival Evolved), NOT ARK: Survival Ascended -- the
#     two are entirely separate games/server binaries. See
#     arksurvivalascended.profile.sh for the other one (Wine-tier).
###############################################################################

# PROFILE_GAME_ID: a short, unique identifier for this game -- used
# internally by the platform to name folders, log entries, and systemd
# services. Must match this file's own name.
PROFILE_GAME_ID="arksurvivalevolved"

# PROFILE_DISPLAY_NAME: the human-readable name shown in menus, summaries,
# and log messages -- this can have spaces and punctuation unlike the ID.
PROFILE_DISPLAY_NAME="ARK: Survival Evolved"

# PROFILE_STEAM_APPID: Valve's unique ID number for this game's server
# files -- SteamCMD uses this to know what to download. 376030 is ARK:SE's
# native Linux dedicated server App ID.
PROFILE_STEAM_APPID="376030"

# PROFILE_STEAM_PLATFORM="linux": tells SteamCMD to download the native
# Linux version of the server files -- unlike ASA, this game actually
# HAS a real Linux server binary, so no Wine is needed.
PROFILE_STEAM_PLATFORM="linux"

# PROFILE_REQUIRES_WINE=0: this game does NOT need Wine -- 0 means "no,
# this is a native Linux program, run it directly."
PROFILE_REQUIRES_WINE=0

# PROFILE_REQUIRES_JAVA=0: this game does NOT need a Java Virtual
# Machine to run -- 0 means "no Java needed."
PROFILE_REQUIRES_JAVA=0

# PROFILE_PORT_COUNT=3: this game needs 3 network ports in a row
# (one for game traffic, one for raw/unfiltered traffic, one for
# Steam query lookups).
PROFILE_PORT_COUNT=3

# PROFILE_RECOMMENDED_RAM_MB: an optional, best-effort recommendation
# (well-known to be a heavy engine -- 8GB is a realistic floor).
# This is an advisory floor, not a hard technical limit -- the platform
# warns clearly (and asks for confirmation interactively) if the host
# has less than this, but never blocks the install outright.
PROFILE_RECOMMENDED_RAM_MB=8192

# profile_port_specs: tells the platform which ports to open in the
# firewall and what to call each one. Each line is "offset:protocol:desc"
# where offset is added to the base port the admin chose.
profile_port_specs() {
    # offset 0 (the base port itself), UDP protocol, labeled "game"
    echo "0:udp:game"
    # offset 1 (one port higher), UDP protocol, labeled "raw"
    echo "1:udp:raw"
    # offset 2 (two ports higher), UDP protocol, labeled "query"
    echo "2:udp:query"
}

# profile_find_binary: given a folder path ($1), searches for the actual
# ARK:SE server executable inside it and prints its full path.
profile_find_binary() {
    # local: makes this variable exist only inside this function
    local search_dir="$1"
    # find: searches for the Linux server binary -- -ipath means case-
    # insensitive path match, 2>/dev/null hides permission errors,
    # head -n1 takes only the first match found
    find "$search_dir" -ipath '*ShooterGame/Binaries/Linux/ShooterGameServer' 2>/dev/null | head -n1
}

# profile_gather_prompts: asks the person setting up this instance
# whatever ARK:SE-specific questions it needs (map, name, passwords, etc.)
# -- on top of the generic questions the platform already asks.
profile_gather_prompts() {
    # Ask which map to load -- "TheIsland" is the original, always-
    # available map. prompt_and_validate takes: prompt text, default value,
    # validator function name, variable name to store result in, hidden
    # flag (0=visible, 1=hidden like a password).
    prompt_and_validate "Map" "TheIsland" validate_generic_safe_string ARKSE_MAP 0
    # Ask for the session name that players will see in the server browser.
    prompt_and_validate "Session name (shown to players)" "My ARK Server" validate_generic_safe_string ARKSE_SESSION_NAME 0
    # Ask for the maximum number of players -- uses a custom validator
    # specific to ARK:SE's limits (defined below in this file).
    prompt_and_validate "Max players" "70" validate_arkse_max_players ARKSE_MAX_PLAYERS 0

    # Password handling: three different cases depending on the situation.
    # ${VAR:-} means "VAR's value, or empty text if VAR isn't set yet."
    if [[ -n "${ARKSE_EXISTING_PASSWORD:-}" ]]; then
        # Case 1: instance already exists with a password -- offer to
        # keep the current one as the default instead of forcing a new one.
        prompt_and_validate "Server password (blank keeps current)" "$ARKSE_EXISTING_PASSWORD" validate_generic_safe_string ARKSE_PASSWORD 0
    elif [[ "$ASSUME_DEFAULTS" -eq 1 ]]; then
        # Case 2: fully-automatic mode (-y flag) -- no human present,
        # so leave password blank (open server) and warn about it.
        ARKSE_PASSWORD=""
        log_warn "Non-interactive mode: leaving the join password blank (open server)."
    else
        # Case 3: a real person is at the keyboard -- ask directly,
        # defaulting to "no password" if they just press Enter.
        prompt_and_validate "Server password (blank = no password)" "" validate_generic_safe_string ARKSE_PASSWORD 0
    fi

    # Admin password: same three-case pattern as the join password above,
    # but this one controls in-game admin/cheat commands.
    if [[ -n "${ARKSE_EXISTING_ADMIN_PASSWORD:-}" ]]; then
        # Case 1: reuse the existing admin password if one is saved.
        prompt_and_validate "Admin password (blank keeps current)" "$ARKSE_EXISTING_ADMIN_PASSWORD" validate_generic_safe_string ARKSE_ADMIN_PASSWORD 0
    elif [[ "$ASSUME_DEFAULTS" -eq 1 ]]; then
        # Case 2: auto-generate a random 16-character password since
        # no one is here to type one. "tr -dc 'A-Za-z0-9'" keeps only
        # letters and digits from /dev/urandom's random byte stream.
        ARKSE_ADMIN_PASSWORD="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16 || true)"
        log_warn "Non-interactive mode: generated a random admin password."
        # Show the generated password on screen so the admin can save it.
        echo -e "${C_BOLD}    Generated admin password: ${ARKSE_ADMIN_PASSWORD}${C_RESET}"
    else
        # Case 3: ask a real person, hiding the typed characters (flag=1).
        prompt_and_validate "Admin password (in-game admin commands)" "" validate_generic_password ARKSE_ADMIN_PASSWORD 1
    fi

    # PROFILE_EXTRA_CONFIG_VARS: tells the platform which variable names
    # to permanently save to disk for this instance -- everything above
    # that we want to remember across restarts.
    PROFILE_EXTRA_CONFIG_VARS=(ARKSE_MAP ARKSE_SESSION_NAME ARKSE_MAX_PLAYERS ARKSE_PASSWORD ARKSE_ADMIN_PASSWORD)
}

# validate_arkse_max_players: checks that the answer is a whole number
# between 1 and 200 (ARK:SE's supported player-count range).
validate_arkse_max_players() {
    # local v="$1" stores the answer being checked into a short variable.
    local v="$1"
    # =~ ^[0-9]+$ is a regex meaning "entirely made of digits, nothing
    # else." && (( v >= 1 && v <= 200 )) then checks the numeric range.
    # If either test fails, || triggers the error message and return 1.
    [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 1 && v <= 200 )) || { echo "Must be a whole number between 1 and 200."; return 1; }
    # return 0 means "this answer is valid."
    return 0
}

# profile_build_launch_args: ARK's map/session args are a single
# "?"-joined string, not separate CLI flags -- this is the well-documented
# but unusual convention noted above. To understand WHY it looks like
# this: it's literally borrowed from how web addresses attach extra
# information after a "?" (like "search?query=cats&sort=new" in a URL) --
# ARK's engine reuses that exact same idea for its own startup options,
# rather than using the more common "-flag value" style most other games
# (including most others in this platform) use. Everything after the
# first "?" is one "key=value" pair after another, each separated by
# another "?" instead of the "&" a real web address would use. Save data
# is redirected via -AltSaveDirectoryName into this instance's own data
# directory (a documented ARK flag for exactly this purpose -- no symlink
# trick needed here, unlike Rust/Unturned/the Wine-tier games).
profile_build_launch_args() {
    # Make sure the instance's data folder exists before writing into it.
    mkdir -p "$INSTANCE_DATA_DIR"
    # ARK:SE uses a "query port" for Steam browser lookups -- it's always
    # the game port + 2 (one higher is the "raw" port, two higher is query).
    local query_port=$(( SERVER_PORT + 2 ))
    # Building this single long text value piece by piece: the map name
    # first, then "?listen" (a fixed keyword ARK expects), then each
    # "SettingName=value" pair, each one separated by another "?".
    local map_arg="${ARKSE_MAP}?listen?SessionName=${ARKSE_SESSION_NAME}?ServerPassword=${ARKSE_PASSWORD}?ServerAdminPassword=${ARKSE_ADMIN_PASSWORD}?Port=${SERVER_PORT}?QueryPort=${query_port}?MaxPlayers=${ARKSE_MAX_PLAYERS}"

    # LAUNCH_ARGS is the array of words handed to the server program.
    LAUNCH_ARGS=(
        "$map_arg"                          # the big map?settings string
        -server                             # tells the binary "run as a dedicated server"
        -log                                # tells it to write detailed log output
        -AltSaveDirectoryName="${INSTANCE_DATA_DIR}"  # redirect save data into our instance folder
    )
}

# profile_post_start_notes: extra plain-English tips shown after setup
# finishes, specific to anything worth knowing about this game.
profile_post_start_notes() {
    # Remind the admin that ARK has lots of extra settings not exposed
    # through prompts -- they'll need to edit config files by hand.
    echo -e "${C_BOLD}Note:${C_RESET} ARK has a much larger configuration surface than most games here"
    echo "(difficulty, taming rates, mods, etc.) that this profile doesn't expose as prompts --"
    echo "edit GameUserSettings.ini/Game.ini directly under this instance's server directory"
    echo "for anything beyond what was asked above, then restart the instance."
}

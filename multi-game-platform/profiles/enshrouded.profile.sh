###############################################################################
# enshrouded.profile.sh -- Enshrouded dedicated server
#
# THIS IS THE WINE-TIER TEMPLATE PROFILE. Some games (Enshrouded among
# them) were only ever built to run on Windows -- there's no version of
# their server program that runs on Linux directly at all. The only way
# to run one on a Linux computer is with a tool called "Wine," which
# creates a fake, translated Windows-like environment that Windows
# programs can run inside, even though the actual computer underneath is
# running Linux. This is genuinely a more fragile setup than a real,
# native Linux program -- expect a bit more CPU usage and the occasional
# rough edge, since the program is technically running through a
# translation layer rather than natively. This profile is the template to
# copy for the other Wine-based games in this platform (Space Engineers,
# Astroneer, ARK: Survival Ascended) -- notice that NONE of the actual
# Wine-handling logic lives here in this file; it's entirely handled once,
# generically, by the shared platform script, triggered just by setting
# PROFILE_REQUIRES_WINE=1 below. This profile only has to describe
# Enshrouded itself.
#
# Confidence notes:
#   - App ID 2278520, the Windows-only platform requirement, and the
#     default ports (15636, 15637, both UDP) are confirmed against current
#     hosting documentation as of this writing.
#   - The enshrouded_server.json schema below reflects commonly-documented
#     keys, but Enshrouded is still in active development and has changed
#     its config format before -- if the server fails to start, check
#     `logs-instance.sh <name> service` for a JSON/config parse error and
#     compare against the current file the game itself generates on a
#     manual first run.
#   - Community reports describe real CPU overhead and occasional
#     stability issues running this under Wine, worse than a native binary
#     would be. This is a genuine, inherent limitation of the Wine
#     approach, not something this profile can fully paper over.
###############################################################################

# PROFILE_GAME_ID: a short, unique identifier for this game -- used
# internally by the platform to name folders, log entries, and systemd
# services. Must match this file's own name.
PROFILE_GAME_ID="enshrouded"

# PROFILE_DISPLAY_NAME: the human-readable name shown in menus, summaries,
# and log messages -- this can have spaces and punctuation unlike the ID.
PROFILE_DISPLAY_NAME="Enshrouded"

# PROFILE_STEAM_APPID: Valve's unique ID number for this game's server
# files -- SteamCMD uses this to know what to download. 2278520 is
# Enshrouded's App ID.
PROFILE_STEAM_APPID="2278520"

# PROFILE_STEAM_PLATFORM="windows": this tells SteamCMD (the download
# tool) to fetch the WINDOWS version of the game's files -- there simply
# is no Linux version to ask for instead.
PROFILE_STEAM_PLATFORM="windows"

# PROFILE_REQUIRES_WINE=1: this single line is doing a lot of work. It
# tells the shared platform script three things, automatically, with
# nothing more needed in this file: (1) install Wine the first time it's
# actually needed, (2) when starting this game, run it through Wine
# instead of running it directly, and (3) give this instance its own
# private, separate "Wine prefix" (Wine's equivalent of a fresh Windows
# install) so that multiple different Wine-based game instances running
# on the same computer never interfere with each other.
PROFILE_REQUIRES_WINE=1

# PROFILE_REQUIRES_JAVA=0: this game does NOT need a Java Virtual
# Machine to run -- 0 means "no Java needed."
PROFILE_REQUIRES_JAVA=0

# PROFILE_PORT_COUNT=2: this game needs 2 network ports in a row
# (one for game traffic, one for Steam query lookups).
PROFILE_PORT_COUNT=2

# PROFILE_RECOMMENDED_RAM_MB: an optional, best-effort recommendation
# (documented as needing substantial RAM -- 8GB is a realistic floor).
# This is an advisory floor, not a hard technical limit -- the platform
# warns clearly (and asks for confirmation interactively) if the host
# has less than this, but never blocks the install outright.
PROFILE_RECOMMENDED_RAM_MB=8192

# profile_port_specs: tells the platform which ports to open in the
# firewall and what to call each one. Enshrouded's own two default ports,
# both UDP. Each line is "offset:protocol:desc" where offset is added to
# the base port the admin chose.
profile_port_specs() {
    # offset 0 (the base port itself), UDP protocol, labeled "game"
    echo "0:udp:game"
    # offset 1 (one port higher), UDP protocol, labeled "query"
    echo "1:udp:query"
}

# profile_find_binary: given a folder path ($1), searches for the actual
# WINDOWS .exe server executable inside it and prints its full path.
# This profile itself never mentions Wine directly anywhere -- the shared
# platform script is the part that actually knows to wrap this .exe with
# Wine before running it, based purely on the PROFILE_REQUIRES_WINE=1
# flag set above.
profile_find_binary() {
    # local: makes this variable exist only inside this function
    local search_dir="$1"
    # find: searches for the Windows .exe file -- -iname means case-
    # insensitive name match, 2>/dev/null hides permission errors,
    # head -n1 takes only the first match found
    find "$search_dir" -iname 'enshrouded_server.exe' 2>/dev/null | head -n1
}

# profile_gather_prompts: asks the person setting up this instance
# whatever Enshrouded-specific questions it needs (server name, player
# count, password, etc.) -- on top of the generic questions the platform
# already asks.
profile_gather_prompts() {
    # Ask for the server name shown to players in the server browser.
    # prompt_and_validate takes: prompt text, default value, validator
    # function name, variable name to store result in, hidden flag (0=visible).
    prompt_and_validate "Server name" "My Enshrouded Server" validate_generic_safe_string ENS_SERVER_NAME 0
    # Ask for the maximum number of players -- uses a custom validator
    # specific to Enshrouded's limits (defined below in this file).
    prompt_and_validate "Max players (1-16)" "8" validate_ens_max_players ENS_MAX_PLAYERS 0

    # Password handling: three different cases depending on the situation.
    # ${VAR:-} means "VAR's value, or empty text if VAR isn't set yet."
    if [[ -n "${ENS_EXISTING_PASSWORD:-}" ]]; then
        # Case 1: instance already exists with a password -- offer to
        # keep the current one as the default instead of forcing a new one.
        prompt_and_validate "Server password (blank keeps current)" "$ENS_EXISTING_PASSWORD" validate_generic_safe_string ENS_PASSWORD 0
    elif [[ "$ASSUME_DEFAULTS" -eq 1 ]]; then
        # Case 2: auto-generate a random 16-character password since
        # no human is present to type one. "tr -dc 'A-Za-z0-9'" keeps only
        # letters and digits from /dev/urandom's random byte stream.
        ENS_PASSWORD="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16 || true)"
        log_warn "Non-interactive mode: generated a random Enshrouded password."
        # Show the generated password on screen so the admin can save it.
        echo -e "${C_BOLD}    Generated password: ${ENS_PASSWORD}${C_RESET}"
    else
        # Case 3: a real person is at the keyboard -- ask directly,
        # hiding the typed characters (flag=1) since it's a password.
        prompt_and_validate "Server password" "" validate_generic_password ENS_PASSWORD 1
    fi

    # PROFILE_EXTRA_CONFIG_VARS: tells the platform which variable names
    # to permanently save to disk for this instance -- everything above
    # that we want to remember across restarts.
    PROFILE_EXTRA_CONFIG_VARS=(ENS_SERVER_NAME ENS_MAX_PLAYERS ENS_PASSWORD)
}

# validate_ens_max_players: checks that the answer is a whole number
# between 1 and 16 (Enshrouded's current documented player cap).
validate_ens_max_players() {
    # local v="$1" stores the answer being checked into a short variable.
    local v="$1"
    # =~ ^[0-9]+$ is a regex meaning "entirely made of digits, nothing
    # else." && (( v >= 1 && v <= 16 )) then checks the numeric range.
    # If either test fails, || triggers the error message and return 1.
    [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 1 && v <= 16 )) || { echo "Must be a whole number between 1 and 16."; return 1; }
    # return 0 means "this answer is valid."
    return 0
}

# profile_build_launch_args: writes Enshrouded's settings file (a format
# called JSON -- a structured, computer-readable way of writing out
# labeled information) and sets up a symbolic-link redirect for its save
# folder, following the same reasoning explained in detail inside
# rust.profile.sh -- games that don't offer a "save your data over here
# instead" option get their default save location transparently
# redirected into this instance's own permanent, backed-up data folder
# via a symbolic link instead.
profile_build_launch_args() {
    # Make sure the instance's data folder exists before writing into it.
    mkdir -p "$INSTANCE_DATA_DIR"
    # Find the path to the .exe file so we know where to write the config.
    local binary; binary="$(profile_find_binary "$INSTANCE_SERVER_DIR")"
    # "$(dirname "$binary")" means "the folder that this file sits
    # inside" -- so the settings file gets written right next to the
    # actual .exe, which is where Enshrouded expects to find it.
    local json_path="$(dirname "$binary")/enshrouded_server.json"

    # Write the JSON settings file -- everything between "<< CFG" and the
    # closing "CFG" gets written into the file, with ${variables} filled
    # in first since we didn't put quotes around CFG.
    cat > "$json_path" << CFG
{
  "name": "${ENS_SERVER_NAME}",
  "saveDirectory": "./savegame",
  "logDirectory": "./logs",
  "ip": "0.0.0.0",
  "queryPort": $(( SERVER_PORT + 1 )),
  "slotCount": ${ENS_MAX_PLAYERS},
  "userGroups": [
    {
      "name": "Admin",
      "password": "${ENS_PASSWORD}",
      "canKickBan": true,
      "canAccessInventories": true,
      "canEditBase": true,
      "canExtendBase": true
    },
    {
      "name": "Player",
      "password": "",
      "canKickBan": false,
      "canAccessInventories": true,
      "canEditBase": true,
      "canExtendBase": true
    }
  ]
}
CFG

    # Set up a symbolic link for the save folder -- Enshrouded always
    # saves into "./savegame" relative to its own installation folder.
    # A symbolic link makes that folder transparently point to our
    # instance's own permanent, backed-up data directory instead.
    local save_link="$(dirname "$binary")/savegame"
    # -L checks "is this already a symbolic link?" -- if it's NOT
    # (meaning this is the first time), set it up.
    if [[ ! -L "$save_link" ]]; then
        # Clear out anything unexpected that might already be there,
        # then create the shortcut.
        rm -rf "$save_link" 2>/dev/null || true
        ln -sfn "$INSTANCE_DATA_DIR" "$save_link"
    fi

    # LAUNCH_ARGS is the array of words handed to the server program.
    LAUNCH_ARGS=(-port "$SERVER_PORT")
}

# profile_post_start_notes: extra plain-English tips shown after setup
# finishes, specific to anything worth knowing about this game.
profile_post_start_notes() {
    # Remind the admin that this game runs through Wine, not natively --
    # expect higher CPU usage and check logs if it doesn't start.
    echo -e "${C_BOLD}Note:${C_RESET} Enshrouded has no native Linux server -- this instance runs the"
    echo "Windows binary through Wine. Expect higher CPU overhead than a native game, and"
    echo "check logs-instance.sh if it doesn't come up -- Wine-related issues are the most"
    echo "likely failure point for this particular game."
}

###############################################################################
# projectzomboid.profile.sh -- Project Zomboid dedicated server
#
# NEW TO CODE? Read ../BASH-BASICS-PRIMER.md first -- it explains every
# recurring pattern below (variables, functions, $1, [[ ]], etc.) in plain
# English, once, instead of re-explaining them every time they appear.
#
# WHAT THIS FILE IS: a "profile" -- a small plug-in telling the shared
# platform (install-game-server.sh) everything it needs to run Project
# Zomboid specifically. The platform calls these functions at the right
# moments; you don't need to read the platform's own code to follow this.
#
# Confidence notes:
#   - App ID 380870 and the start-server.sh launcher are well-established.
#   - Redirecting PZ's save/config data into our own instance_data_dir uses
#     `-cachedir`, the modern, documented mechanism for this. If a future
#     PZ version changes this flag, saves would fall back to the
#     'gameserver' system user's home directory instead of INSTANCE_DATA_DIR
#     -- check `logs-instance.sh <name> service` if backups look empty
#     after first boot, and verify this flag against the current PZ
#     dedicated server docs.
#   - Port numbers: the primary game port (UDP) is well-established. The
#     exact secondary/RCON port conventions can vary by version; verify
#     against current PZ docs before assuming the offsets below are
#     complete for your setup.
###############################################################################

# --- Identity and basic facts about this game -------------------------------
# Plain variables (see the primer) that the platform reads after loading
# this file, to know how to treat this specific game.

# PROFILE_GAME_ID: a short, unique identifier for this game -- used
# internally by the platform to name folders, log entries, and systemd
# services. Must match this file's own name.
PROFILE_GAME_ID="projectzomboid"

# PROFILE_DISPLAY_NAME: the human-readable name shown in menus, summaries,
# and log messages -- this can have spaces and punctuation unlike the ID.
PROFILE_DISPLAY_NAME="Project Zomboid"

# PROFILE_STEAM_APPID: Valve's unique ID number for this game's server
# files -- SteamCMD uses this to know what to download. 380870 is
# Project Zomboid's dedicated server App ID.
PROFILE_STEAM_APPID="380870"

# PROFILE_STEAM_PLATFORM="linux": tells SteamCMD to download the native
# Linux version of the server files -- PZ has a real Linux server.
PROFILE_STEAM_PLATFORM="linux"

# PROFILE_REQUIRES_WINE=0: this game does NOT need Wine -- 0 means "no,
# this is a native Linux program, run it directly."
PROFILE_REQUIRES_WINE=0

# PROFILE_PORT_COUNT=2: this game needs 2 network ports in a row
# (one for game traffic, one for the remote admin console).
PROFILE_PORT_COUNT=2

# PROFILE_RECOMMENDED_RAM_MB: an optional, best-effort recommendation
# (moderate for its player cap -- 2GB is a comfortable floor).
# This is an advisory floor, not a hard technical limit -- the platform
# warns clearly (and asks for confirmation interactively) if the host
# has less than this, but never blocks the install outright.
PROFILE_RECOMMENDED_RAM_MB=2048

# --- profile_port_specs: which ports, and what kind of network traffic ------
# A function (see the primer) that just prints out one line per port this
# game needs, as "offset:protocol:description". "offset" is added to
# whatever base port number the admin picked; "protocol" is either "udp"
# or "tcp" (the two basic ways computers send data over a network).
profile_port_specs() {
    echo "0:udp:game"    # the main game traffic, on the base port itself
    echo "1:tcp:rcon"    # the remote-admin-console port, one number higher
}

# --- profile_find_binary: where's the actual program to run? ---------------
# Given a folder ($1), find and print the path to Project Zomboid's own
# start-up script inside it.
profile_find_binary() {
    local search_dir="$1"   # local = only exists inside this function (see primer)

    # find: search inside $search_dir, at most 2 folders deep (-maxdepth 2),
    #   for a file named "start-server.sh", ignoring uppercase/lowercase
    #   differences (-iname).
    # 2>/dev/null: throw away any "permission denied"-type error messages.
    # | head -n1: if more than one match somehow turns up, keep just the first.
    find "$search_dir" -maxdepth 2 -iname 'start-server.sh' 2>/dev/null | head -n1
}

# --- profile_gather_prompts: ask the admin what THIS game needs ------------
# The shared platform already asks generic questions (instance name, port,
# backup schedule). This function asks whatever else is specific to
# Project Zomboid.
profile_gather_prompts() {
    # prompt_and_validate (provided by the platform, not this file) takes:
    #   1. the question to show,  2. the default answer,
    #   3. the name of a "is this valid?" checker function (below),
    #   4. the variable name to store the answer in,
    #   5. whether to hide typed characters like a password (1) or not (0).
    prompt_and_validate "Server name" "MyPZServer" validate_generic_safe_string PZ_SERVER_NAME 0
    prompt_and_validate "Max players (1-64)" "16" validate_pz_max_players PZ_MAX_PLAYERS 0

    # The join-password question has extra logic: reuse a password from a
    # previous run if one exists, generate a random one automatically in
    # fully-automatic mode, or otherwise actually ask.
    # ${VAR:-} means "VAR's value, or empty text if VAR isn't set yet" --
    # this avoids errors from strict mode (see the primer) when checking a
    # variable that might not exist the first time this ever runs.
    if [[ -n "${PZ_EXISTING_PASSWORD:-}" ]]; then
        prompt_and_validate "Server password (blank keeps current)" "$PZ_EXISTING_PASSWORD" validate_generic_safe_string PZ_PASSWORD 0
    elif [[ "$ASSUME_DEFAULTS" -eq 1 ]]; then
        # tr -dc 'A-Za-z0-9' throws away every character that ISN'T a
        # letter or digit; < /dev/urandom feeds it a stream of random
        # bytes to filter; head -c 16 keeps only the first 16 characters
        # that come out. End result: a random 16-character password.
        # "|| true" at the very end stops a harmless internal plumbing
        # quirk (the /dev/urandom stream never truly "runs out", so the
        # pipeline can report a technical error even though we got exactly
        # the 16 characters we wanted) from being treated as a real failure.
        PZ_PASSWORD="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16 || true)"
        log_warn "Non-interactive mode: generated a random Project Zomboid password."
        echo -e "${C_BOLD}    Generated password: ${PZ_PASSWORD}${C_RESET}"
    else
        prompt_and_validate "Server password" "" validate_generic_password PZ_PASSWORD 1
    fi

    # The remote-admin-console (RCON) password is always freshly generated
    # or re-asked -- separate from the player join password above.
    prompt_and_validate "RCON password (for remote admin console)" "$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 12 || true)" validate_generic_safe_string PZ_RCON_PASSWORD 0

    # PROFILE_EXTRA_CONFIG_VARS is a list (array -- see the primer) of
    # variable NAMES the platform should remember by saving them to disk.
    # Anything created above that we want to keep needs to be listed here.
    PROFILE_EXTRA_CONFIG_VARS=(PZ_SERVER_NAME PZ_MAX_PLAYERS PZ_PASSWORD PZ_RCON_PASSWORD)
}

# --- Validator functions: "is this answer actually acceptable?" ------------
# Takes the typed answer ($1), prints an error and "return"s 1 (fail) if
# it's bad, or silently "return"s 0 (success) if it's fine. Called
# repeatedly by prompt_and_validate until an answer passes.

# validate_pz_max_players: must be a whole number from 1 to 64 (a
# practical, commonly-cited ceiling -- verify against your own hardware).
validate_pz_max_players() {
    local v="$1"
    # =~ ^[0-9]+$ means "the entire text is one or more digits, nothing else."
    # (( )) then checks the numeric range.
    if [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 1 && v <= 64 )); then
        return 0
    fi
    echo "Must be a whole number between 1 and 64."
    return 1
}

# --- profile_build_launch_args: how do we actually start the server? ------
# Called right before launch, with every setting above already loaded.
# Writes out Project Zomboid's own settings file, and fills in the
# LAUNCH_ARGS list (an array -- see the primer) with the exact
# command-line words to hand to its start-up script.
profile_build_launch_args() {
    # Project Zomboid keeps its settings inside a "Server" subfolder of
    # wherever -cachedir points -- we point that at our own per-instance
    # data folder, so save data ends up somewhere we control and back up.
    local ini_dir="${INSTANCE_DATA_DIR}/Server"
    mkdir -p "$ini_dir"   # -p: also create parent folders, don't error if it exists

    # A "heredoc" (see the primer): everything between "<< CFG" and the
    # closing "CFG" gets written into the file, with ${variables} filled
    # in first since we didn't put quotes around CFG.
    cat > "${ini_dir}/${PZ_SERVER_NAME}.ini" << CFG
PublicName=${PZ_SERVER_NAME}
Public=false
MaxPlayers=${PZ_MAX_PLAYERS}
Password=${PZ_PASSWORD}
DefaultPort=${SERVER_PORT}
RCONPort=$(( SERVER_PORT + 1 ))
RCONPassword=${PZ_RCON_PASSWORD}
CFG

    # The actual words handed to start-server.sh when launching -- as if
    # you'd typed: ./start-server.sh -cachedir=... -servername ... -adminpassword ...
    LAUNCH_ARGS=(-cachedir="${INSTANCE_DATA_DIR}" -servername "$PZ_SERVER_NAME" -adminpassword "$PZ_RCON_PASSWORD")
}

# --- profile_post_start_notes: extra advice shown after setup finishes ----
# Optional -- a helpful reminder specific to this game, tacked onto the
# platform's own "you're all set" summary screen.
profile_post_start_notes() {
    echo -e "${C_BOLD}Note:${C_RESET} If this is a fresh save, Project Zomboid can take a couple of"
    echo "minutes to finish generating the world on first boot before the port opens."
}

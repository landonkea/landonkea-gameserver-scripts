###############################################################################
# terraria.profile.sh -- Terraria dedicated server
#
# WHAT THIS FILE IS: a "profile" is the one file that tells the shared
# platform (install-game-server.sh) everything it needs to know to run
# THIS specific game. The platform itself doesn't know anything about
# Terraria -- it just knows "load a profile, then call a few specific
# functions this profile promises to define." That's the whole design:
# one small file per game, plugging into one shared, reusable engine.
#
# Confidence notes (read before relying on this in production):
#   - App ID 105600 and TCP-only networking are well-established, long-
#     standing facts about Terraria's dedicated server.
#   - The exact binary name/location is discovered defensively (see
#     profile_find_binary below) rather than hardcoded, since Steam depot
#     layouts can shift between versions.
#   - The serverconfig.txt key names below reflect the long-standing,
#     widely-documented format; if a future Terraria update changes them,
#     the server will simply fail to start with its own config error in
#     the instance's log -- check `logs-instance.sh <name> service`.
###############################################################################

# ---------------------------------------------------------------------------
# SECTION 1: Basic facts about this game.
# These are plain variables (not functions) -- the platform reads them
# directly to know how to treat this game. Every profile must set all of
# these, even if some values are empty strings (see minecraft.profile.sh
# for an example of a game that isn't on Steam at all, where
# PROFILE_STEAM_APPID is deliberately left empty).
# ---------------------------------------------------------------------------

# PROFILE_GAME_ID: the short internal name for this game. Must match this
# file's own name (terraria.profile.sh -> "terraria"). This is what
# appears after --game on the command line, and what's stored in each
# instance's own config.env so the platform knows which profile to load
# for that instance later.
PROFILE_GAME_ID="terraria"

# PROFILE_DISPLAY_NAME: the human-readable name shown in menus, summaries,
# and log messages. This can have spaces/punctuation, unlike PROFILE_GAME_ID.
PROFILE_DISPLAY_NAME="Terraria"

# PROFILE_STEAM_APPID: Valve (the company behind Steam) gives every
# downloadable game/tool a unique ID number. SteamCMD (the tool this
# platform uses to download game server files) needs this number to know
# what to download. 105600 is Terraria's own App ID -- unusually, the
# dedicated server files are included in the same download as the game
# itself, inside a "server" sub-folder, rather than having a totally
# separate App ID the way some other games do.
PROFILE_STEAM_APPID="105600"

# PROFILE_STEAM_PLATFORM: tells SteamCMD which version of the files to
# download -- "linux" for a native Linux program, or "windows" for a
# Windows program (which then needs Wine, a Windows-compatibility layer,
# to run on Linux at all -- see enshrouded.profile.sh for an example of
# that). Terraria has a genuine native Linux server, so this is "linux".
PROFILE_STEAM_PLATFORM="linux"

# PROFILE_REQUIRES_WINE: 0 means "no, this is a native Linux program, run
# it directly." 1 would mean "this is actually a Windows program -- wrap
# it with Wine before running it." Terraria doesn't need this.
PROFILE_REQUIRES_WINE=0

# PROFILE_PORT_COUNT: how many network ports (in a row, starting from
# whatever port the person setting up this server chooses) this game
# needs in total. Terraria only needs one single port for everything, so
# this is 1. Compare to rust.profile.sh, which needs 3 (one for the game
# itself, one for server-browser lookups, one for remote admin access).
PROFILE_PORT_COUNT=1

# PROFILE_RECOMMENDED_RAM_MB: an optional, best-effort recommendation (extremely lightweight engine).
# This is a advisory floor, not a hard technical limit -- the platform warns
# clearly (and asks for confirmation interactively) if the host has less than
# this, but never blocks the install outright.
PROFILE_RECOMMENDED_RAM_MB=512

# ---------------------------------------------------------------------------
# SECTION 2: Functions the platform will call.
# Every profile MUST define these exact function names -- the platform
# looks for them by name after loading this file. If one is missing, the
# platform refuses to use this profile at all, with a clear error message
# explaining exactly which function is missing, rather than failing in a
# more confusing way later.
# ---------------------------------------------------------------------------

# profile_port_specs: tells the platform exactly which ports to open in
# the firewall, and what to call each one in summaries. It works by
# PRINTING lines of text (using "echo"), not by returning a value the way
# some other programming languages work -- the platform reads whatever
# this function prints, one line at a time.
#
# Each line has 3 pieces separated by colons: "offset:protocol:description"
#   - "offset" is added to whatever base port number the person chose.
#     An offset of 0 means "use their chosen port number exactly."
#   - "protocol" is either "tcp" or "udp" -- two different ways computers
#     send data over a network. Most games in this whole platform use UDP;
#     Terraria is one of the few exceptions that uses TCP instead.
#   - "description" is just a short label shown to the person running the
#     server, so they understand what each opened port is actually for.
profile_port_specs() {
    echo "0:tcp:game"
}

# profile_find_binary: given a folder path (the $1 below means "the first
# thing passed into this function"), this must PRINT the exact full path
# to the actual game server program inside that folder, so the platform
# knows what to run.
#
# Rather than assuming a fixed path like "$1/Linux/TerrariaServer.bin.x86_64"
# (which could break if a future Terraria update reorganizes its files),
# this uses the "find" command to SEARCH for a file with that exact name,
# anywhere inside the given folder. This is safer/more future-proof.
profile_find_binary() {
    local search_dir="$1"
    # "find" searches a folder tree for files matching a pattern.
    #   -iname means "match this name, ignoring uppercase/lowercase differences"
    #   2>/dev/null means "if 'find' prints any error messages, throw them away"
    #     (for example, if it hits a folder it doesn't have permission to look in)
    #   "| head -n1" means "if find lists more than one match, just take the first one"
    find "$search_dir" -iname 'TerrariaServer.bin.x86_64' 2>/dev/null | head -n1
}

# profile_gather_prompts: asks the person setting up this specific
# instance whatever game-specific questions it needs (world name, size,
# password, etc.) -- on top of the generic questions the platform ALREADY
# asks every game (like which port to use, and backup schedule), which
# this function doesn't need to worry about at all.
profile_gather_prompts() {
    # prompt_and_validate is a function defined once in the main platform
    # script and reused by every single profile. Its five pieces of
    # information are, in order: the question to ask, the default answer,
    # the name of a function to use for checking the answer is valid, the
    # variable name to save the final answer into, and a 0/1 flag for
    # whether this is a secret (a password) that shouldn't be shown on
    # screen while it's being typed.
    prompt_and_validate "World name" "MyWorld" validate_generic_safe_string TR_WORLD_NAME 0

    # This next one uses a validator specific to THIS profile (defined
    # further down in this same file), since "must be 1, 2, or 3" isn't a
    # rule any other game needs -- so it doesn't belong in the shared,
    # generic validator list every profile can already use.
    prompt_and_validate "World size (1=Small, 2=Medium, 3=Large)" "2" validate_tr_world_size TR_WORLD_SIZE 0
    prompt_and_validate "Max players (1-255)" "8" validate_tr_max_players TR_MAX_PLAYERS 0

    # Password handling has three different cases, depending on the
    # situation this function is being called in:
    if [[ -n "${TR_EXISTING_PASSWORD:-}" ]]; then
        # Case 1: this instance already exists and already has a password
        # saved (this happens if a profile update or an admin adds a
        # feature that re-runs prompts later) -- offer to keep it as the
        # default rather than forcing a brand new one to be typed.
        prompt_and_validate "Server password (blank keeps current)" "$TR_EXISTING_PASSWORD" validate_generic_safe_string TR_PASSWORD 0
    elif [[ "$ASSUME_DEFAULTS" -eq 1 ]]; then
        # Case 2: the platform is running in fully-automatic mode (the
        # person setting this up passed the -y flag, meaning "don't ask
        # me anything, just use sensible defaults"). There's no one
        # watching to type a password, so this leaves it blank (an open
        # server) and clearly warns about that choice in the log output.
        TR_PASSWORD=""
        log_warn "Non-interactive mode: leaving Terraria password blank (open server). Set one later by editing serverconfig.txt if desired."
    else
        # Case 3: a real person is sitting at the keyboard right now --
        # ask them directly, defaulting to "no password" if they just
        # press Enter without typing anything.
        prompt_and_validate "Server password (blank = no password)" "" validate_generic_safe_string TR_PASSWORD 0
    fi

    # PROFILE_EXTRA_CONFIG_VARS: this is a list (an array -- see the
    # beginner's guide, HOW-TO-READ-THIS-CODE.md, section 8, for what that
    # means) of every variable name this function just set, that need to
    # be permanently saved to disk for this instance. The platform reads
    # this list and writes each variable's current value into that
    # instance's own settings file automatically -- this profile doesn't
    # need to write that file itself.
    PROFILE_EXTRA_CONFIG_VARS=(TR_WORLD_NAME TR_WORLD_SIZE TR_MAX_PLAYERS TR_PASSWORD)
}

# validate_tr_world_size: a validator function -- given one piece of text
# (whatever the person typed, or the default value), it must either do
# nothing and implicitly succeed (meaning "this answer is fine"), or print
# an error message explaining what's wrong AND explicitly fail (return 1),
# which makes the platform automatically re-ask the same question.
validate_tr_world_size() {
    # "case" is like a cleaner, more readable version of a chain of
    # if/elseif/elseif -- it checks the value of $1 (the answer being
    # checked) against each listed pattern in turn.
    case "$1" in
        1|2|3) return 0 ;;   # any of these three exact values: accept it (0 = success)
        *) echo "Must be 1 (Small), 2 (Medium), or 3 (Large)."; return 1 ;;  # anything else: reject it
    esac
}

# validate_tr_max_players: checks the answer is a whole number (no
# letters, no decimal point) between 1 and 255 inclusive (255 is
# Terraria's own actual hard limit, not a number this project invented).
validate_tr_max_players() {
    local v="$1"
    # The strange-looking "^[0-9]+$" is a regular expression (a compact
    # pattern-matching language) meaning "the ENTIRE value, start to
    # finish, must be made up of one or more digit characters" -- so
    # "42" matches, but "42.5", "-1", and "forty" do not.
    [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 1 && v <= 255 )) || { echo "Must be a whole number between 1 and 255."; return 1; }
    return 0
}

# profile_build_launch_args: this runs immediately before the server
# actually starts (every single time it starts, not just the first time)
# -- it's responsible for writing any config file(s) the game needs, and
# for filling in LAUNCH_ARGS, a list of words that get handed to the
# actual game program on the command line to start it up correctly.
#
# By the time this function runs, every variable this profile saved
# earlier via PROFILE_EXTRA_CONFIG_VARS (TR_WORLD_NAME, TR_MAX_PLAYERS,
# etc.) has already been automatically loaded back from disk and is ready
# to use here -- along with a handful of platform-wide variables like
# SERVER_PORT (which port number was chosen) and INSTANCE_DATA_DIR (this
# specific instance's own private folder for save data).
profile_build_launch_args() {
    # Make sure the folder that will hold the actual Terraria world file
    # exists before Terraria tries to create the world inside it.
    mkdir -p "${INSTANCE_DATA_DIR}/Worlds"

    # Terraria supports being told "load your settings from this file"
    # instead of listing every single setting on the command line --
    # that's cleaner, so this builds that file's full path here.
    local cfg="${INSTANCE_DATA_DIR}/serverconfig.txt"

    # This next block writes several lines of text into that file all at
    # once (a "heredoc" -- see the beginner's guide, section 11). Every
    # $VARIABLE inside it gets automatically replaced with that variable's
    # actual current value before being written.
    cat > "$cfg" << CFG
world=${INSTANCE_DATA_DIR}/Worlds/${TR_WORLD_NAME}.wld
autocreate=${TR_WORLD_SIZE}
worldname=${TR_WORLD_NAME}
port=${SERVER_PORT}
maxplayers=${TR_MAX_PLAYERS}
password=${TR_PASSWORD}
motd=Welcome to ${TR_WORLD_NAME}!
secure=1
upnp=0
language=en-US
CFG

    # LAUNCH_ARGS is the list of words that gets handed to the Terraria
    # server program to actually start it. Here it's simple: just tell it
    # which config file to read (the one just written above).
    LAUNCH_ARGS=(-config "$cfg")
}

# profile_post_start_notes: OPTIONAL (unlike everything above, the
# platform works fine if a profile doesn't define this one at all) --
# extra plain-English text shown to the person right after this instance
# successfully starts, for anything specific to this game worth knowing.
profile_post_start_notes() {
    echo -e "${C_BOLD}Note:${C_RESET} Terraria uses TCP (not UDP) -- if you're used to UDP-based"
    echo "games in this platform, remember to forward/allow the TCP port specifically."
}

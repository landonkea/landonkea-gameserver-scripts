###############################################################################
# rust.profile.sh -- Rust dedicated server
#
# WHAT MAKES THIS PROFILE WORTH READING CLOSELY: Rust's server program
# does NOT let you tell it "save your world data over here in this other
# folder" the way most games do -- it always saves inside its own
# installation folder, in a sub-folder named after whatever "identity"
# name you give it. Since this platform's backup system always looks in
# ONE predictable place (this instance's own INSTANCE_DATA_DIR) no matter
# which game is running, this profile uses a "symbolic link" (see the
# explanation inside profile_build_launch_args below) to bridge that gap
# -- a trick reused later by unturned.profile.sh for the exact same
# reason.
#
# Confidence notes: App ID 258550 and the RustDedicated binary/`+key
# value` console command launch convention are well-established.
###############################################################################

PROFILE_GAME_ID="rust"
PROFILE_DISPLAY_NAME="Rust"
PROFILE_STEAM_APPID="258550"
PROFILE_STEAM_PLATFORM="linux"
PROFILE_REQUIRES_WINE=0
PROFILE_REQUIRES_JAVA=0

# PROFILE_PORT_COUNT=3: Rust needs three SEPARATE port numbers in a row --
# one for the actual game traffic, one for Steam's "server browser" to be
# able to look up basic info about this server, and one for RCON (remote
# admin access). This is different from Team Fortress 2's profile, where
# RCON reuses the SAME port number as the game itself -- every game
# decides this differently, which is exactly why PROFILE_PORT_COUNT and
# profile_port_specs exist as something each profile states for itself.
PROFILE_PORT_COUNT=3

# PROFILE_RECOMMENDED_RAM_MB: an optional, best-effort recommendation (well-known to be RAM-hungry, especially at larger map sizes).
# This is a advisory floor, not a hard technical limit -- the platform warns
# clearly (and asks for confirmation interactively) if the host has less than
# this, but never blocks the install outright.
PROFILE_RECOMMENDED_RAM_MB=4096

# profile_port_specs: three lines this time, one per port, each getting
# its own "offset" added to whatever base port number was chosen (offset
# 0 = that exact port, offset 1 = one higher, offset 2 = two higher).
profile_port_specs() {
    echo "0:udp:game"
    echo "1:udp:query"
    echo "2:tcp:rcon"
}

# profile_find_binary: RustDedicated should always sit right at the top
# level of the downloaded files, but "find" is still used (rather than
# assuming a fixed path) as a small safety margin against Steam
# reorganizing its download layout in some future update.
profile_find_binary() {
    local search_dir="$1"
    find "$search_dir" -maxdepth 2 -iname 'RustDedicated' 2>/dev/null | head -n1
}

# profile_gather_prompts: asks every Rust-specific question. See
# terraria.profile.sh for a full explanation of prompt_and_validate and
# the standard three-case password-handling pattern used below.
profile_gather_prompts() {
    prompt_and_validate "Server name (shown to players)" "My Rust Server" validate_generic_safe_string RUST_SERVER_NAME 0
    prompt_and_validate "Map seed (any whole number)" "12345" validate_rust_seed RUST_SEED 0
    prompt_and_validate "Map size (1000-6000)" "3000" validate_rust_worldsize RUST_WORLDSIZE 0
    prompt_and_validate "Max players" "50" validate_rust_max_players RUST_MAX_PLAYERS 0

    if [[ -n "${RUST_EXISTING_RCON_PASSWORD:-}" ]]; then
        prompt_and_validate "RCON password (blank keeps current)" "$RUST_EXISTING_RCON_PASSWORD" validate_generic_safe_string RUST_RCON_PASSWORD 0
    elif [[ "$ASSUME_DEFAULTS" -eq 1 ]]; then
        RUST_RCON_PASSWORD="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16 || true)"
        log_warn "Non-interactive mode: generated a random RCON password."
        echo -e "${C_BOLD}    Generated RCON password: ${RUST_RCON_PASSWORD}${C_RESET}"
    else
        prompt_and_validate "RCON password" "" validate_generic_password RUST_RCON_PASSWORD 1
    fi

    PROFILE_EXTRA_CONFIG_VARS=(RUST_SERVER_NAME RUST_SEED RUST_WORLDSIZE RUST_MAX_PLAYERS RUST_RCON_PASSWORD)
}

# validate_rust_seed: a "seed" is just a starting number Rust uses to
# generate the map's terrain -- any whole number works, so this only
# checks it's made up entirely of digits.
validate_rust_seed() { [[ "$1" =~ ^[0-9]+$ ]] || { echo "Must be a whole number."; return 1; }; return 0; }

# validate_rust_worldsize: Rust's own practical map-size range, in
# in-game map units (not a real-world unit of measurement).
validate_rust_worldsize() {
    local v="$1"
    [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 1000 && v <= 6000 )) || { echo "Must be a whole number between 1000 and 6000."; return 1; }
    return 0
}

validate_rust_max_players() {
    local v="$1"
    [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 1 && v <= 500 )) || { echo "Must be a whole number between 1 and 500."; return 1; }
    return 0
}

# profile_build_launch_args: builds the list of "+setting value" pairs
# Rust's server reads on startup (its own particular style, different
# from most other games' plain "-flag value" style), and sets up the
# symbolic-link workaround explained at the top of this file.
profile_build_launch_args() {
    # Rust identifies which "save" to use by a short name called its
    # "identity" -- using this instance's own name guarantees every
    # instance on this machine automatically gets its own separate,
    # non-conflicting identity, with zero extra typing needed.
    local identity="$INSTANCE_NAME"

    mkdir -p "$INSTANCE_DATA_DIR"
    # Rust expects to find (or create) a folder structure like
    # "server/<identity>/" sitting right inside its own installation
    # folder -- this line makes sure the "server" part of that path
    # exists first, before the symbolic link (the actual redirect) is
    # created just below.
    mkdir -p "${INSTANCE_SERVER_DIR}/server"

    # THE KEY TRICK: rather than letting Rust create and use a real,
    # ordinary folder at "server/<identity>/" (which would then live
    # inside INSTANCE_SERVER_DIR -- a folder this platform treats as
    # disposable, since it's just a copy that gets re-synced from the
    # shared downloaded game files whenever this game gets updated), a
    # SYMBOLIC LINK is put there instead. A symbolic link looks like a
    # normal folder to Rust, but it's actually just a labeled pointer/
    # shortcut to a COMPLETELY DIFFERENT real location -- in this case,
    # this instance's own permanent, backed-up INSTANCE_DATA_DIR folder.
    # Rust never knows the difference; it just saves and loads files
    # exactly like normal, and those files transparently end up
    # somewhere the platform will actually keep safe.
    if [[ ! -L "${INSTANCE_SERVER_DIR}/server/${identity}" ]]; then
        # "-L" checks whether the symbolic link ALREADY exists (so this
        # only needs to be set up once, the very first time this
        # instance ever starts) -- if it's not there yet, clear out
        # anything unexpected that might already be sitting at that
        # exact spot, then create the link.
        rm -rf "${INSTANCE_SERVER_DIR}/server/${identity}" 2>/dev/null || true
        ln -sfn "$INSTANCE_DATA_DIR" "${INSTANCE_SERVER_DIR}/server/${identity}"
    fi

    # Rust's own command-line style is unusual: instead of "-flag value"
    # (like most other programs, including most other games in this
    # platform), it uses "+setting.name value" for almost everything.
    # This whole list gets handed, word by word, to the actual
    # RustDedicated program when it starts.
    LAUNCH_ARGS=(
        -batchmode                              # don't try to open a graphical window
        +server.port "$SERVER_PORT"
        +server.queryport "$(( SERVER_PORT + 1 ))"
        +rcon.port "$(( SERVER_PORT + 2 ))"
        +server.identity "$identity"             # this is what makes the symlink trick above actually matter
        +server.hostname "$RUST_SERVER_NAME"
        +server.seed "$RUST_SEED"
        +server.worldsize "$RUST_WORLDSIZE"
        +server.maxplayers "$RUST_MAX_PLAYERS"
        +rcon.password "$RUST_RCON_PASSWORD"
        +rcon.web true
        +server.saveinterval 300                 # auto-save every 300 seconds (5 minutes)
    )
}

profile_post_start_notes() {
    echo -e "${C_BOLD}Note:${C_RESET} Rust map generation on first boot can take several minutes,"
    echo "especially for larger worldsize values -- don't be alarmed if the port takes"
    echo "a while to open the very first time this instance starts."
}

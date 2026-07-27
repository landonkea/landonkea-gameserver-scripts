###############################################################################
# teamfortress2.profile.sh -- Team Fortress 2 dedicated server
#
# THIS IS THE TEMPLATE PROFILE for every "Source engine" game in this
# platform (Garry's Mod, Left 4 Dead 2, and any future addition like
# Counter-Strike 2 or Insurgency: Sandstorm). "Source" is the name of the
# game engine (the underlying software foundation) that Valve, the
# company behind Steam, built many of their own games on top of --
# because they all share the same engine, they also all share almost
# exactly the same command-line launch style and the same remote-admin
# (RCON) protocol, which is why copying this file is the fastest way to
# add another Source-engine game to this platform.
#
# Confidence notes:
#   - App ID 232250, srcds_run, and the +cvar-style launch argument
#     convention have been stable and extremely well-documented for
#     Source engine dedicated servers for two decades. This is about
#     as high-confidence as a profile in this platform gets.
#   - Source engine's RCON protocol is the SAME wire protocol Minecraft's
#     RCON is modeled on, so this profile reuses that approach for
#     profile_get_player_count() via the "status" console command.
#   - No profile_trigger_save(): TF2 is a multiplayer FPS with no
#     persistent per-round world state to save, so there's nothing
#     meaningful for that hook to do here.
###############################################################################

# PROFILE_GAME_ID: a short, unique identifier for this game -- used
# internally by the platform to name folders, log entries, and systemd
# services. Must match this file's own name.
PROFILE_GAME_ID="teamfortress2"

# PROFILE_DISPLAY_NAME: the human-readable name shown in menus, summaries,
# and log messages -- this can have spaces and punctuation unlike the ID.
PROFILE_DISPLAY_NAME="Team Fortress 2"

# PROFILE_STEAM_APPID: Valve's unique ID number for this game's server
# files -- SteamCMD uses this to know what to download. 232250 is TF2's
# dedicated server App ID.
PROFILE_STEAM_APPID="232250"

# PROFILE_STEAM_PLATFORM="linux": tells SteamCMD to download the native
# Linux version of the server files -- TF2 has a real Linux server.
PROFILE_STEAM_PLATFORM="linux"

# PROFILE_REQUIRES_WINE=0: this game does NOT need Wine -- 0 means "no,
# this is a native Linux program, run it directly."
PROFILE_REQUIRES_WINE=0

# PROFILE_REQUIRES_JAVA=0: this game does NOT need a Java Virtual
# Machine to run -- 0 means "no Java needed."
PROFILE_REQUIRES_JAVA=0

# PROFILE_PORT_COUNT=1: even though this profile opens BOTH a UDP port
# (for the actual game) and a TCP port (for RCON) below, they both use
# the SAME port NUMBER (just two different ways of talking over that
# same number) -- Source engine's own long-standing convention -- so only
# one distinct port number needs to be reserved in total, unlike Rust
# (which genuinely needs three separate numbers).
PROFILE_PORT_COUNT=1

# PROFILE_RECOMMENDED_RAM_MB: an optional, best-effort recommendation
# (Source engine is generally light -- 1GB is a comfortable floor).
# This is an advisory floor, not a hard technical limit -- the platform
# warns clearly (and asks for confirmation interactively) if the host
# has less than this, but never blocks the install outright.
PROFILE_RECOMMENDED_RAM_MB=1024

# profile_port_specs: tells the platform which ports to open in the
# firewall and what to call each one. Notice both lines use offset 0 --
# meaning "the exact same port number the person chose," just once
# labeled as UDP (for gameplay) and once as TCP (for RCON).
profile_port_specs() {
    # offset 0 (the base port itself), UDP protocol, labeled "game"
    echo "0:udp:game"
    # offset 0 (SAME port number), TCP protocol, labeled "rcon" -- two
    # protocols sharing one port number, which is Source engine's convention
    echo "0:tcp:rcon"
}

# profile_find_binary: given a folder path ($1), searches for Valve's
# official launcher script "srcds_run" inside it and prints its full path.
# srcds_run is a wrapper that itself starts the real underlying game
# engine, additionally handling low-level details like auto-restarting
# if the engine crashes.
profile_find_binary() {
    # local: makes this variable exist only inside this function
    local search_dir="$1"
    # find: searches for srcds_run -- -maxdepth 1 means only look at the
    # top level (don't go into sub-folders), -iname means case-insensitive
    # name match, 2>/dev/null hides permission errors, head -n1 takes
    # only the first match
    find "$search_dir" -maxdepth 1 -iname 'srcds_run' 2>/dev/null | head -n1
}

# profile_gather_prompts: asks the person setting up this instance
# whatever TF2-specific questions it needs (hostname, map, passwords, etc.)
# -- unlike Minecraft/Mindustry, Source engine games DO have a genuine
# player-facing join password (sv_password) entirely separate from the
# RCON admin password used for remote console access.
profile_gather_prompts() {
    # Ask for the server name (hostname) shown in the server browser.
    # prompt_and_validate takes: prompt text, default value, validator
    # function name, variable name to store result in, hidden flag (0=visible).
    prompt_and_validate "Server name (hostname)" "My TF2 Server" validate_generic_safe_string TF2_HOSTNAME 0
    # Ask which map to load -- "ctf_2fort" is TF2's most iconic map.
    prompt_and_validate "Map" "ctf_2fort" validate_generic_safe_string TF2_MAP 0
    # Ask for the maximum number of players -- uses a custom validator
    # specific to TF2's limits (defined below in this file).
    prompt_and_validate "Max players (2-32)" "24" validate_tf2_max_players TF2_MAX_PLAYERS 0

    # Join-password handling: three different cases depending on the
    # situation. ${VAR:-} means "VAR's value, or empty text if VAR
    # isn't set yet."
    if [[ -n "${TF2_EXISTING_PASSWORD:-}" ]]; then
        # Case 1: instance already exists with a password -- offer to
        # keep the current one as the default instead of forcing a new one.
        prompt_and_validate "Server password (blank keeps current, blank also allowed for no password)" "$TF2_EXISTING_PASSWORD" validate_generic_safe_string TF2_PASSWORD 0
    elif [[ "$ASSUME_DEFAULTS" -eq 1 ]]; then
        # Case 2: fully-automatic mode (-y flag) -- no human present,
        # so leave password blank (open server) and warn about it.
        TF2_PASSWORD=""
        log_warn "Non-interactive mode: leaving the join password blank (open server)."
    else
        # Case 3: a real person is at the keyboard -- ask directly,
        # defaulting to "no password" if they just press Enter.
        prompt_and_validate "Server password (blank = no password)" "" validate_generic_safe_string TF2_PASSWORD 0
    fi

    # RCON password: used for remote admin console access -- completely
    # separate from the join password above. Same three-case pattern.
    if [[ -n "${TF2_EXISTING_RCON_PASSWORD:-}" ]]; then
        # Case 1: reuse the existing RCON password if one is saved.
        prompt_and_validate "RCON password (blank keeps current)" "$TF2_EXISTING_RCON_PASSWORD" validate_generic_safe_string TF2_RCON_PASSWORD 0
    elif [[ "$ASSUME_DEFAULTS" -eq 1 ]]; then
        # Case 2: auto-generate a random 16-character password since
        # no one is here to type one. "tr -dc 'A-Za-z0-9'" keeps only
        # letters and digits from /dev/urandom's random byte stream.
        TF2_RCON_PASSWORD="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16 || true)"
        log_warn "Non-interactive mode: generated a random RCON password."
        # Show the generated password on screen so the admin can save it.
        echo -e "${C_BOLD}    Generated RCON password: ${TF2_RCON_PASSWORD}${C_RESET}"
    else
        # Case 3: ask a real person, hiding the typed characters (flag=1).
        prompt_and_validate "RCON password (for admin console access)" "" validate_generic_password TF2_RCON_PASSWORD 1
    fi

    # PROFILE_EXTRA_CONFIG_VARS: tells the platform which variable names
    # to permanently save to disk for this instance -- everything above
    # that we want to remember across restarts.
    PROFILE_EXTRA_CONFIG_VARS=(TF2_HOSTNAME TF2_MAP TF2_MAX_PLAYERS TF2_PASSWORD TF2_RCON_PASSWORD)
}

# validate_tf2_max_players: checks that the answer is a whole number
# between 2 and 32 (vanilla TF2's practical player-count range).
validate_tf2_max_players() {
    # local v="$1" stores the answer being checked into a short variable.
    local v="$1"
    # =~ ^[0-9]+$ is a regex meaning "entirely made of digits, nothing
    # else." && (( v >= 2 && v <= 32 )) then checks the numeric range.
    # If either test fails, || triggers the error message and return 1.
    [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 2 && v <= 32 )) || { echo "Must be a whole number between 2 and 32."; return 1; }
    # return 0 means "this answer is valid."
    return 0
}

# profile_build_launch_args: Source engine's own "+cvar value" launch
# style -- passed directly as command-line words, rather than writing a
# separate settings file first, since the exact settings-file location
# and format varies more across different Source engine games than the
# command-line convention does.
profile_build_launch_args() {
    # LAUNCH_ARGS is the array of words handed to the server program.
    LAUNCH_ARGS=(
        -game tf                     # tells the shared engine WHICH specific game to actually run
        +map "$TF2_MAP"              # which map to load on startup
        +maxplayers "$TF2_MAX_PLAYERS"  # maximum concurrent players
        -port "$SERVER_PORT"         # which port to listen on for game traffic
        +hostname "$TF2_HOSTNAME"    # the server name shown in the browser list
        +rcon_password "$TF2_RCON_PASSWORD"  # password for remote admin access
        -secure                      # enables Valve Anti-Cheat (VAC) for this server
    )
    # Only add the join-password setting at all if one was actually
    # provided -- an empty sv_password setting is Source engine's own way
    # of meaning "no password required."
    if [[ -n "$TF2_PASSWORD" ]]; then
        LAUNCH_ARGS+=(+sv_password "$TF2_PASSWORD")
    fi
}

# tf2_rcon: implements the exact same RCON network protocol explained in
# full detail inside minecraft.profile.sh's mc_rcon function -- Minecraft's
# RCON was modeled on this very protocol, so the same approach works for
# both games, just aimed at a different port here (Source engine's RCON
# shares the main game port, rather than using a separate one).
tf2_rcon() {
    # local: stores the command to send into a short variable
    local command="$1"
    # python3 - means "run this Python program, treating the rest of the
    # line as arguments (sys.argv)." The heredoc between << 'PYEOF' and
    # PYEOF is the actual Python code, passed as plain text to python3.
    python3 - "$SERVER_PORT" "$TF2_RCON_PASSWORD" "$command" << 'PYEOF' 2>/dev/null
import socket, struct, sys

def send_packet(sock, pkt_id, pkt_type, body):
    payload = struct.pack('<ii', pkt_id, pkt_type) + body.encode() + b'\x00\x00'
    sock.sendall(struct.pack('<i', len(payload)) + payload)

def read_packet(sock):
    length_bytes = sock.recv(4)
    if len(length_bytes) < 4:
        return None, None, ""
    length = struct.unpack('<i', length_bytes)[0]
    data = b''
    while len(data) < length:
        chunk = sock.recv(length - len(data))
        if not chunk:
            break
        data += chunk
    if len(data) < 8:
        return None, None, ""
    pkt_id, pkt_type = struct.unpack('<ii', data[:8])
    body = data[8:-2].decode(errors='replace')
    return pkt_id, pkt_type, body

port, password, command = int(sys.argv[1]), sys.argv[2], sys.argv[3]
try:
    sock = socket.create_connection(("127.0.0.1", port), timeout=5)
    send_packet(sock, 1, 3, password)
    auth_id, _, _ = read_packet(sock)
    if auth_id == -1:
        sys.exit(1)
    send_packet(sock, 2, 2, command)
    _, _, body = read_packet(sock)
    print(body.strip())
    sock.close()
except Exception:
    sys.exit(1)
PYEOF
}

# profile_get_player_count: Source engine's own "status" console command
# replies with several lines of server info, including one that looks
# like "players : 3 humans, 0 bots (24 max)" -- this pulls just the "3"
# out of that line using a regex pattern.
profile_get_player_count() {
    # local: stores the command output into a short variable
    local output
    # Send the "status" command via RCON and capture the full output.
    # 2>/dev/null hides error messages, || return 1 means "if the RCON
    # call fails entirely, give up and return failure."
    output="$(tf2_rcon "status" 2>/dev/null)" || return 1
    # grep -oP uses a Perl-compatible regex to find digits that come
    # right after "players : " -- pulling just the number out of the
    # whole status output. || echo "" means "if grep finds nothing,
    # return an empty string instead of an error."
    grep -oP '(?<=players : )\d+' <<< "$output" || echo ""
}

# profile_post_start_notes: extra plain-English tips shown after setup
# finishes, specific to anything worth knowing about this game.
profile_post_start_notes() {
    # Let the admin know this file is the template for all Source-engine
    # games -- copying it is the fastest way to add a new one.
    echo -e "${C_BOLD}Note:${C_RESET} This is the template profile for the other Source-engine games"
    echo "(Garry's Mod, Left 4 Dead 2, Counter-Strike 2, Insurgency: Sandstorm) -- copying"
    echo "this file and changing the App ID, -game directory, and default map covers most"
    echo "of the work for any of them."
}

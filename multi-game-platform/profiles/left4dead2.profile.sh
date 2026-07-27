###############################################################################
# left4dead2.profile.sh -- Left 4 Dead 2 dedicated server
#
# This file shares its entire structure with teamfortress2.profile.sh --
# read that file first for a full, line-by-line explanation of every
# pattern used here. This file only calls out what's actually DIFFERENT
# about Left 4 Dead 2 specifically: it's a small-team co-op game (max 8
# players total, not the larger free-for-all lobby size TF2/GMod allow),
# and its own cvars for controlling private-lobby matchmaking are less
# universally documented than TF2's -- sv_password (used below) remains
# the standard, reliable access-control mechanism regardless.
#
# Confidence notes: same tier/template as teamfortress2.profile.sh --
# App ID 222860, srcds_run, +cvar launch convention.
###############################################################################

# PROFILE_GAME_ID: a short, unique identifier for this game -- used internally
# by the platform to name folders, log entries, and systemd services
PROFILE_GAME_ID="left4dead2"
# PROFILE_DISPLAY_NAME: the human-readable name shown to users in menus and prompts
PROFILE_DISPLAY_NAME="Left 4 Dead 2"
# PROFILE_STEAM_APPID: the Steam "App ID" for the dedicated server download
PROFILE_STEAM_APPID="222860"
# PROFILE_STEAM_PLATFORM: which OS platform to download from Steam
PROFILE_STEAM_PLATFORM="linux"
# PROFILE_REQUIRES_WINE: 0 means this game runs natively on Linux, no Wine needed
PROFILE_REQUIRES_WINE=0
# PROFILE_REQUIRES_JAVA: 0 means this game does NOT need Java installed
PROFILE_REQUIRES_JAVA=0
# PROFILE_PORT_COUNT: L4D2 only needs 1 port (it handles game + RCON on one port)
PROFILE_PORT_COUNT=1

# PROFILE_RECOMMENDED_RAM_MB: an optional, best-effort recommendation (Source engine is generally light).
# This is a advisory floor, not a hard technical limit -- the platform warns
# clearly (and asks for confirmation interactively) if the host has less than
# this, but never blocks the install outright.
# 1024 MB = 1 GB -- Left 4 Dead 2 uses Valve's Source engine, which is lightweight
PROFILE_RECOMMENDED_RAM_MB=1024

# profile_port_specs(): declares which network ports this game needs
profile_port_specs() {
    # Port 0 is the only port -- it handles both game traffic (UDP) and
    # RCON admin connections (TCP) on the same port number
    echo "0:udp:game"
    echo "0:tcp:rcon"
}

# profile_find_binary(): locates the L4D2 server program on disk
profile_find_binary() {
    # search_dir: the directory to search in
    local search_dir="$1"
    # Look for srcds_run (Source Dedicated Server runner) -- this is the
    # standard launcher for all Source engine games (TF2, L4D2, CS:S, etc.)
    find "$search_dir" -maxdepth 1 -iname 'srcds_run' 2>/dev/null | head -n1
}

# profile_gather_prompts(): asks the user game-specific questions during setup
profile_gather_prompts() {
    # Ask for the server's hostname (display name) -- default "My L4D2 Server"
    prompt_and_validate "Server name (hostname)" "My L4D2 Server" validate_generic_safe_string L4D2_HOSTNAME 0
    # Ask which map to start on -- "c1m1_hotel" is the first map in the
    # "No Mercy" campaign (a classic L4D2 campaign)
    prompt_and_validate "Map" "c1m1_hotel" validate_generic_safe_string L4D2_MAP 0
    # Ask how many players can join -- L4D2 supports 2-8 players
    prompt_and_validate "Max players (2-8)" "8" validate_l4d2_max_players L4D2_MAX_PLAYERS 0

    # Check if a join password was already set from a previous configuration
    if [[ -n "${L4D2_EXISTING_PASSWORD:-}" ]]; then
        # Show existing password as default -- user can press Enter to keep it
        prompt_and_validate "Server password (blank keeps current)" "$L4D2_EXISTING_PASSWORD" validate_generic_safe_string L4D2_PASSWORD 0
    # Auto mode: skip the question and leave the server open (no password)
    elif [[ "$ASSUME_DEFAULTS" -eq 1 ]]; then
        # Empty password = anyone can join
        L4D2_PASSWORD=""
        # Warn the user
        log_warn "Non-interactive mode: leaving the join password blank (open server)."
    else
        # First-time setup: ask for a join password
        prompt_and_validate "Server password (blank = no password)" "" validate_generic_safe_string L4D2_PASSWORD 0
    fi

    # Now handle the RCON password (for remote admin commands via command line)
    if [[ -n "${L4D2_EXISTING_RCON_PASSWORD:-}" ]]; then
        # Show existing RCON password as default
        prompt_and_validate "RCON password (blank keeps current)" "$L4D2_EXISTING_RCON_PASSWORD" validate_generic_safe_string L4D2_RCON_PASSWORD 0
    elif [[ "$ASSUME_DEFAULTS" -eq 1 ]]; then
        # Generate a random 16-character alphanumeric RCON password
        L4D2_RCON_PASSWORD="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16 || true)"
        # Notify the user
        log_warn "Non-interactive mode: generated a random RCON password."
        # Show it in bold so the user can copy it
        echo -e "${C_BOLD}    Generated RCON password: ${L4D2_RCON_PASSWORD}${C_RESET}"
    else
        # Ask interactively -- hidden flag 1 means input is masked on screen
        prompt_and_validate "RCON password" "" validate_generic_password L4D2_RCON_PASSWORD 1
    fi

    # Save these variables to the config file for persistence
    PROFILE_EXTRA_CONFIG_VARS=(L4D2_HOSTNAME L4D2_MAP L4D2_MAX_PLAYERS L4D2_PASSWORD L4D2_RCON_PASSWORD)
}

# validate_l4d2_max_players: whole number, 2-8 (L4D2's co-op/versus ceiling).
validate_l4d2_max_players() {
    # Store the user's input in a local variable
    local v="$1"
    # ^[0-9]+$: regex that matches only digits (whole numbers)
    # v >= 2 && v <= 8: L4D2 needs at least 2 players (co-op game)
    [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 2 && v <= 8 )) || { echo "Must be a whole number between 2 and 8."; return 1; }
    # Return 0 = success
    return 0
}

# profile_build_launch_args(): builds the command-line arguments for starting
# the L4D2 server -- uses Valve's Source engine "+cvar" convention
profile_build_launch_args() {
    # LAUNCH_ARGS: command-line flags for the L4D2 server
    LAUNCH_ARGS=(
        # -game left4dead2: tells srcds which Source engine game to load
        -game left4dead2
        # +map: tells the server which map to start on
        # The "+" prefix is Valve's convention for setting console variables
        +map "$L4D2_MAP"
        # +maxplayers: sets the maximum number of players
        +maxplayers "$L4D2_MAX_PLAYERS"
        # -port: which port to listen on for player connections
        -port "$SERVER_PORT"
        # +hostname: the name shown in the server browser
        +hostname "$L4D2_HOSTNAME"
        # +rcon_password: password for remote admin commands (RCON)
        +rcon_password "$L4D2_RCON_PASSWORD"
        # -secure: enables VAC (Valve Anti-Cheat) on the server
        -secure
    )
    # Only add the password argument if the user actually set one
    if [[ -n "$L4D2_PASSWORD" ]]; then
        # +sv_password: sets the password players need to join the server
        LAUNCH_ARGS+=(+sv_password "$L4D2_PASSWORD")
    fi
}

# l4d2_rcon(): sends a command to the L4D2 server via RCON (Remote Console)
# This function uses Python to implement the Source RCON protocol
l4d2_rcon() {
    # command: the admin command to send (like "status", "kick", "changelevel")
    local command="$1"
    # python3: run Python 3 to implement the RCON protocol
    # - "$SERVER_PORT" "$L4D2_RCON_PASSWORD" "$command": these become sys.argv[1], [2], [3]
    # << 'PYEOF': a heredoc that feeds Python code into python3's stdin
    # 2>/dev/null: hide any Python error output
    python3 - "$SERVER_PORT" "$L4D2_RCON_PASSWORD" "$command" << 'PYEOF' 2>/dev/null
# Import Python modules: socket for networking, struct for packing binary data,
# sys for reading command-line arguments
import socket, struct, sys
# send_packet(): sends an RCON packet to the server
# sock: the network connection, pkt_id: packet ID number, pkt_type: type of packet,
# body: the text content to send
def send_packet(sock, pkt_id, pkt_type, body):
    # Pack the packet ID and type as two 32-bit integers (little-endian)
    # then add the text body plus two null bytes as terminator
    payload = struct.pack('<ii', pkt_id, pkt_type) + body.encode() + b'\x00\x00'
    # Pack the total length as a 32-bit integer, then send the full packet
    sock.sendall(struct.pack('<i', len(payload)) + payload)
# read_packet(): reads one RCON response packet from the server
def read_packet(sock):
    # Read 4 bytes (the packet length)
    lb = sock.recv(4)
    # If we got less than 4 bytes, the connection is broken -- return None
    if len(lb) < 4: return None, None, ""
    # Unpack the length from the 4 bytes we read
    length = struct.unpack('<i', lb)[0]
    # Read the rest of the packet (the full payload)
    data = b''
    # Keep reading until we have the full packet
    while len(data) < length:
        # recv() returns some bytes; subtract what we already have
        c = sock.recv(length - len(data))
        # If recv returns nothing, the connection closed
        if not c: break
        # Append the bytes we just read
        data += c
    # If we didn't get enough data for a valid packet, return empty
    if len(data) < 8: return None, None, ""
    # Unpack the packet ID and type from the first 8 bytes
    pid, pt = struct.unpack('<ii', data[:8])
    # Return the ID, type, and body text (everything after byte 8, minus the
    # 2 null terminator bytes). errors='replace' handles bad UTF-8 gracefully
    return pid, pt, data[8:-2].decode(errors='replace')
# Read the command-line arguments: port, password, and command to execute
port, password, command = int(sys.argv[1]), sys.argv[2], sys.argv[3]
try:
    # Connect to the RCON server on localhost (127.0.0.1) with a 5-second timeout
    sock = socket.create_connection(("127.0.0.1", port), timeout=5)
    # Send an AUTH packet (type 3) with the password to authenticate
    send_packet(sock, 1, 3, password)
    # Read the server's response to our auth attempt
    auth_id, _, _ = read_packet(sock)
    # If auth_id is -1, the password was wrong -- exit with failure
    if auth_id == -1: sys.exit(1)
    # Send the actual command as an EXECUTED_COMMAND packet (type 2)
    send_packet(sock, 2, 2, command)
    # Read the server's response to our command
    _, _, body = read_packet(sock)
    # Print the response (strip removes extra whitespace/newlines)
    print(body.strip())
    # Close the network connection
    sock.close()
# If anything goes wrong (network error, timeout, etc.), exit with failure
except Exception:
    sys.exit(1)
PYEOF
}

# profile_get_player_count(): returns the number of players currently on the server
# Uses RCON to query the server's "status" command
profile_get_player_count() {
    # local output: will hold the response from the RCON status command
    local output
    # Send the "status" command via RCON and capture the output
    # 2>/dev/null: hide errors, || return 1: if RCON fails, return failure
    output="$(l4d2_rcon "status" 2>/dev/null)" || return 1
    # grep: searches the output for the player count
    # -oP: output only text matching the pattern (Perl regex)
    # (?<=players : )\d+: look behind for "players : " then grab the digits after it
    # <<< "$output": feeds the status output into grep as input
    # || echo "": if grep finds nothing, return an empty string instead of an error
    grep -oP '(?<=players : )\d+' <<< "$output" || echo ""
}

# profile_post_start_notes(): prints helpful tips AFTER the server is set up
profile_post_start_notes() {
    # Explain that campaign selection is done in-game, not at launch
    echo -e "${C_BOLD}Note:${C_RESET} Campaign progression/chapter selection isn't set via these"
    # Tell the user how campaign selection actually works
    echo "launch args -- players choose or vote on the campaign from the in-game menu after"
    # Clarify that the map argument is just for the initial spawn point
    echo "connecting; the map given here is just the initial one loaded at server start."
}

###############################################################################
# counterstrike2.profile.sh -- Counter-Strike 2 dedicated server
#
# IMPORTANT DISTINCTION FROM THIS PLATFORM'S OTHER SOURCE-ENGINE GAMES:
# Team Fortress 2, Garry's Mod, and Left 4 Dead 2 all run on the original
# "Source" engine (Source 1). CS2 is built on "Source 2" -- a genuinely
# different, newer engine Valve built, even though it's a spiritual
# successor to the same company's earlier games. Source 2's dedicated
# server tooling is similar in SPIRIT (still SteamCMD-based, still has
# RCON using the same protocol) but its own binary/launch details are
# less uniform with the Source 1 template than Garry's Mod/Left 4 Dead 2
# are -- this profile is a reasonable-confidence best effort, not the
# same "extremely stable, decades-documented" tier as the Source 1 trio.
#
# Confidence notes:
#   - App ID 730 is confirmed (the same ID historically used for CS:GO's
#     dedicated server, now serving CS2's).
#   - The cs2 binary/launch-argument details below are my best
#     understanding, not independently verified against a live server --
#     check logs-instance.sh closely on first deployment.
#   - No native macOS client exists for CS2 at all (confirmed via
#     research) -- worth knowing if you're planning who can play,
#     independent of anything server-side.
###############################################################################

# PROFILE_GAME_ID: a short, unique identifier for this game — used internally by
# the platform to name folders, log entries, and systemd services.
PROFILE_GAME_ID="counterstrike2"

# PROFILE_DISPLAY_NAME: the human-friendly name shown to the user in menus,
# prompts, and log messages.
PROFILE_DISPLAY_NAME="Counter-Strike 2"

# PROFILE_STEAM_APPID: the numeric ID Steam uses to identify CS2's dedicated
# server download — 730 is the same ID that CS:GO's server historically used,
# now serving CS2 after the transition.
PROFILE_STEAM_APPID="730"

# PROFILE_STEAM_PLATFORM: tells SteamCMD to download the Linux-native build.
PROFILE_STEAM_PLATFORM="linux"

# PROFILE_REQUIRES_WINE: set to 0 (false) — CS2 has a native Linux server,
# so no Windows compatibility layer is needed.
PROFILE_REQUIRES_WINE=0

# PROFILE_REQUIRES_JAVA: set to 0 (false) — CS2 is built on Source 2 (C++),
# not Java. No Java runtime needed.
PROFILE_REQUIRES_JAVA=0

# PROFILE_PORT_COUNT: CS2 uses just 1 port — game traffic and RCON share the
# same port number but use different protocols (UDP vs TCP).
PROFILE_PORT_COUNT=1

# PROFILE_RECOMMENDED_RAM_MB: an optional, best-effort recommendation (Source 2
# is somewhat heavier than Source 1). Advisory only — warns if the host has
# less, never blocks. 2048 MB = 2 GB.
PROFILE_RECOMMENDED_RAM_MB=2048

# profile_port_specs: tells the platform which network ports this game uses.
# CS2 follows the same Source-engine convention as Team Fortress 2 and Garry's Mod —
# RCON shares the game's own port number rather than using a separate one.
profile_port_specs() {
    # "0:udp:game" — the main game port where players connect (UDP protocol).
    echo "0:udp:game"
    # "0:tcp:rcon" — the same port number but TCP protocol, used for remote
    # admin commands (RCON). TCP guarantees delivery; UDP doesn't (and that's
    # fine for gameplay where speed matters more).
    echo "0:tcp:rcon"
}

# profile_find_binary: locates the CS2 server executable on disk.
profile_find_binary() {
    # Store the search directory argument in a local variable.
    local search_dir="$1"
    # Search for "cs2" — the Source 2 dedicated server binary on Linux.
    # "-maxdepth 3" searches up to 3 folder levels deep (deeper than other
    # profiles because CS2's binary may be nested inside game folders).
    # "-iname" is case-insensitive. "-type f" means only match regular files
    # (not directories). Errors hidden. First match returned.
    find "$search_dir" -maxdepth 3 -iname 'cs2' -type f 2>/dev/null | head -n1
}

# profile_gather_prompts: asks the user questions about their server configuration.
profile_gather_prompts() {
    # Ask for the server name (hostname) shown in the server browser.
    # Default: "My CS2 Server". Stored in CS2_HOSTNAME.
    prompt_and_validate "Server name (hostname)" "My CS2 Server" validate_generic_safe_string CS2_HOSTNAME 0
    # Ask which map to load. "de_dust2" is one of CS2's most iconic maps.
    prompt_and_validate "Map" "de_dust2" validate_generic_safe_string CS2_MAP 0
    # Ask for the maximum number of players — validated by validate_cs2_max_players.
    prompt_and_validate "Max players (2-64)" "10" validate_cs2_max_players CS2_MAX_PLAYERS 0

    # Three-way password logic (same pattern across all profiles):
    if [[ -n "${CS2_EXISTING_PASSWORD:-}" ]]; then
        prompt_and_validate "Server password (blank keeps current)" "$CS2_EXISTING_PASSWORD" validate_generic_safe_string CS2_PASSWORD 0
    elif [[ "$ASSUME_DEFAULTS" -eq 1 ]]; then
        CS2_PASSWORD=""
        log_warn "Non-interactive mode: leaving the join password blank (open server)."
    else
        prompt_and_validate "Server password (blank = no password)" "" validate_generic_safe_string CS2_PASSWORD 0
    fi

    # Same three-way logic for the RCON password (remote admin commands).
    if [[ -n "${CS2_EXISTING_RCON_PASSWORD:-}" ]]; then
        prompt_and_validate "RCON password (blank keeps current)" "$CS2_EXISTING_RCON_PASSWORD" validate_generic_safe_string CS2_RCON_PASSWORD 0
    elif [[ "$ASSUME_DEFAULTS" -eq 1 ]]; then
        # Generate a random 16-character password from letters and digits.
        # "tr -dc 'A-Za-z0-9' < /dev/urandom" filters random bytes to only
        # alphanumeric characters. "| head -c 16" takes the first 16.
        CS2_RCON_PASSWORD="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16 || true)"
        log_warn "Non-interactive mode: generated a random RCON password."
        # Print the password so the admin can save it somewhere safe.
        echo -e "${C_BOLD}    Generated RCON password: ${CS2_RCON_PASSWORD}${C_RESET}"
    else
        # Fresh install — ask for RCON password. "1" means hidden input.
        prompt_and_validate "RCON password" "" validate_generic_password CS2_RCON_PASSWORD 1
    fi

    # Save all variable names to the instance config for persistence.
    PROFILE_EXTRA_CONFIG_VARS=(CS2_HOSTNAME CS2_MAP CS2_MAX_PLAYERS CS2_PASSWORD CS2_RCON_PASSWORD)
}

# validate_cs2_max_players: checks that the user's input is a valid player count.
validate_cs2_max_players() {
    # Store the first argument (user's input) in a local variable.
    local v="$1"
    # Check that input contains only digits AND is between 2 and 64 inclusive.
    [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 2 && v <= 64 )) || { echo "Must be a whole number between 2 and 64."; return 1; }
    # Return 0 to signal success.
    return 0
}

# profile_build_launch_args: builds the list of command-line arguments for
# starting the CS2 server binary.
profile_build_launch_args() {
    # LAUNCH_ARGS is a Bash array — each line adds one argument for the server.
    LAUNCH_ARGS=(
        # "-dedicated" tells CS2 to run as a dedicated server (headless, no GUI).
        -dedicated
        # "-game cs2" tells Source 2 to load the CS2 game data.
        -game cs2
        # "+map de_dust2" tells the server which map (level) to load first.
        +map "$CS2_MAP"
        # "+maxplayers 10" sets the maximum number of player slots.
        +maxplayers "$CS2_MAX_PLAYERS"
        # "-port 27015" sets the network port number for player connections.
        -port "$SERVER_PORT"
        # "+hostname My CS2 Server" sets the name shown in the server browser.
        +hostname "$CS2_HOSTNAME"
        # "+rcon_password secret" sets the password for remote admin access.
        +rcon_password "$CS2_RCON_PASSWORD"
    )
    # If a server password was set (non-empty), add it to the launch arguments.
    if [[ -n "$CS2_PASSWORD" ]]; then
        # "+sv_password" makes the server require a password to join.
        LAUNCH_ARGS+=(+sv_password "$CS2_PASSWORD")
    fi
}

# cs2_rcon: sends remote admin commands (RCON) to the running CS2 server.
# Uses Python to implement the Source RCON network protocol. This is the same
# implementation as Team Fortress 2 and Garry's Mod — Source 2 kept the same
# RCON protocol as Source 1.
cs2_rcon() {
    # Store the command to send in a local variable.
    local command="$1"
    # Run a Python script via stdin ("python3 -") with port, password, and
    # command as arguments. The << 'PYEOF' heredoc feeds code to Python.
    python3 - "$SERVER_PORT" "$CS2_RCON_PASSWORD" "$command" << 'PYEOF' 2>/dev/null
import socket, struct, sys
# send_packet: builds a Source RCON network packet and sends it.
# "sock" = network connection, "pkt_id" = unique packet number,
# "pkt_type" = what kind (3=auth, 2=command), "body" = the text payload.
def send_packet(sock, pkt_id, pkt_type, body):
    # struct.pack('<ii', ...) converts two integers to raw bytes (little-endian).
    payload = struct.pack('<ii', pkt_id, pkt_type) + body.encode() + b'\x00\x00'
    # Prepend the packet length as a 4-byte integer, then send everything.
    sock.sendall(struct.pack('<i', len(payload)) + payload)
# read_packet: reads and parses one RCON response from the server.
def read_packet(sock):
    # Read the first 4 bytes (packet length).
    lb = sock.recv(4)
    if len(lb) < 4: return None, None, ""
    # Convert those 4 bytes into an integer (total bytes to read).
    length = struct.unpack('<i', lb)[0]
    # Read the rest of the packet, potentially in multiple chunks.
    data = b''
    while len(data) < length:
        c = sock.recv(length - len(data))
        if not c: break
        data += c
    # If the data is too short to be valid, return empty.
    if len(data) < 8: return None, None, ""
    # Unpack the packet ID and type from the first 8 bytes.
    pid, pt = struct.unpack('<ii', data[:8])
    # Return packet ID, type, and the text body (minus trailing null bytes).
    return pid, pt, data[8:-2].decode(errors='replace')
# Get the port, password, and command from command-line arguments.
port, password, command = int(sys.argv[1]), sys.argv[2], sys.argv[3]
try:
    # Open a TCP connection to the server on localhost at the given port.
    sock = socket.create_connection(("127.0.0.1", port), timeout=5)
    # Send an authentication packet (type 3) with the RCON password.
    send_packet(sock, 1, 3, password)
    # Read the server's response to see if auth succeeded.
    auth_id, _, _ = read_packet(sock)
    # If auth_id is -1, the password was wrong — exit with error code 1.
    if auth_id == -1: sys.exit(1)
    # Auth succeeded — send the actual command (type 2).
    send_packet(sock, 2, 2, command)
    # Read and print the server's response.
    _, _, body = read_packet(sock)
    print(body.strip())
    sock.close()
# Catch any exception (connection refused, timeout, etc.)
except Exception:
    sys.exit(1)
PYEOF
}

# profile_get_player_count: asks the server "how many players are connected?"
# by sending the "status" command via RCON.
profile_get_player_count() {
    # Declare a variable to hold the RCON output.
    local output
    # Send the "status" command via RCON and capture the output.
    # "|| return 1" means if RCON fails, return failure immediately.
    output="$(cs2_rcon "status" 2>/dev/null)" || return 1
    # grep -oP uses a lookbehind regex to find the number after "players : ".
    # For example, if the output says "players : 5", this extracts just "5".
    # "|| echo ''" returns an empty string if no match is found.
    grep -oP '(?<=players : )\d+' <<< "$output" || echo ""
}

# profile_post_start_notes: prints helpful tips after the server is set up.
profile_post_start_notes() {
    echo -e "${C_BOLD}Note:${C_RESET} CS2 runs on Source 2, a different engine generation from this"
    echo "platform's other Source-engine games -- if this instance doesn't come up as"
    echo "expected, check logs-instance.sh first; this is one of the less battle-tested"
    echo "profiles in this platform. Also: CS2 has no native macOS client at all (Valve has"
    echo "said this is unlikely to ever change), independent of anything on the server side."
}

###############################################################################
# garrysmod.profile.sh -- Garry's Mod dedicated server
#
# This file shares its entire structure with teamfortress2.profile.sh --
# read that file first for a full, line-by-line explanation of every
# pattern used here (the launch arguments, the RCON protocol
# implementation, the port setup). This file only calls out what's
# actually DIFFERENT about Garry's Mod specifically.
#
# Confidence notes: same tier as teamfortress2.profile.sh -- App ID 4020,
# srcds_run, and the +cvar launch convention are long-established Source
# engine facts.
###############################################################################

# PROFILE_GAME_ID: a short, unique identifier for this game — used internally by
# the platform to name folders, log entries, and systemd services.
# "garrysmod" is the lowercase no-spaces ID the platform will use everywhere.
PROFILE_GAME_ID="garrysmod"

# PROFILE_DISPLAY_NAME: the human-friendly name shown to the user in menus,
# prompts, and log messages — this is what the player actually recognizes.
PROFILE_DISPLAY_NAME="Garry's Mod"

# PROFILE_STEAM_APPID: the numeric ID Steam uses to identify this game's
# dedicated server download — SteamCMD needs this number to fetch the right files.
# 4020 is Garry's Mod dedicated server, a Source 1 engine game.
PROFILE_STEAM_APPID="4020"

# PROFILE_STEAM_PLATFORM: tells SteamCMD which operating system's files to
# download — "linux" means Linux-native binaries (no Wine or compatibility layer needed).
PROFILE_STEAM_PLATFORM="linux"

# PROFILE_REQUIRES_WINE: set to 0 (false) because Garry's Mod has a native
# Linux server — Wine is a tool that lets Linux run Windows programs, but it's
# not needed here since Valve provides a real Linux build.
PROFILE_REQUIRES_WINE=0

# PROFILE_REQUIRES_JAVA: set to 0 (false) because Garry's Mod is written in
# C++ (Source engine), not Java — no Java runtime is needed to run this server.
PROFILE_REQUIRES_JAVA=0

# PROFILE_PORT_COUNT: tells the platform how many network ports this game needs
# to reserve — Garry's Mod uses just 1 base port (game traffic + RCON share it,
# just on different protocols UDP vs TCP).
PROFILE_PORT_COUNT=1

# PROFILE_RECOMMENDED_RAM_MB: an optional, best-effort recommendation (Source
# engine is generally light). This is an advisory floor, not a hard technical
# limit — the platform warns clearly (and asks for confirmation interactively) if
# the host has less than this, but never blocks the install outright.
# 1024 MB = 1 GB is recommended for Garry's Mod.
PROFILE_RECOMMENDED_RAM_MB=1024

# profile_port_specs: a function that tells the platform which network ports
# this game uses and what protocol each one talks. Each line is formatted as
# "offset:protocol:label" — offset is added to the base port number.
# Source engine RCON shares the game's own port number (UDP for gameplay,
# TCP for RCON), not a separate one.
profile_port_specs() {
    # "0:udp:game" means offset 0 from the base port, using UDP protocol, labeled "game"
    # — this is the main port players connect to for gameplay.
    echo "0:udp:game"
    # "0:tcp:rcon" means offset 0 from the base port (same port number), using TCP
    # protocol, labeled "rcon" — this is for remote admin commands.
    echo "0:tcp:rcon"
}

# profile_find_binary: a function that searches the server's installed files to
# locate the main executable program that starts the game server.
# The Source engine's server launcher on Linux is called "srcds_run".
profile_find_binary() {
    # "local search_dir="$1"" creates a local variable called search_dir and
    # assigns it the first argument passed to this function ($1).
    local search_dir="$1"
    # "find" searches the filesystem for files matching a pattern.
    # "$search_dir" is where to start searching.
    # "-maxdepth 1" means only look in that exact folder, not subfolders.
    # "-iname 'srcds_run'" means find a file named "srcds_run" (case-insensitive).
    # "2>/dev/null" hides any "permission denied" or "not found" error messages.
    # "| head -n1" pipes the results to head, which takes only the first match.
    find "$search_dir" -maxdepth 1 -iname 'srcds_run' 2>/dev/null | head -n1
}

# profile_gather_prompts: a function that asks the user a series of questions
# about how they want their server configured. Each question collects one setting.
# "prompt_and_validate" is a helper function that: shows a question, validates the
# answer, and stores it in a variable. Arguments: prompt text, default value,
# validator function name, variable name to store the answer, hidden flag (0=visible).
profile_gather_prompts() {
    # Asks for the server name (hostname) that players see in the server browser.
    # Default is "My GMod Server". Uses validate_generic_safe_string to ensure the
    # name has no dangerous characters. Stores the answer in GMOD_HOSTNAME.
    prompt_and_validate "Server name (hostname)" "My GMod Server" validate_generic_safe_string GMOD_HOSTNAME 0
    # "Gamemode" is Garry's Mod's own concept, on top of Source engine's
    # usual "map" — it's a separate add-on that decides WHAT KIND of
    # game is actually being played on that map (the default, "sandbox,"
    # has no real objective at all; others like "TTT" or "DarkRP" turn it
    # into a completely different style of game).
    prompt_and_validate "Gamemode" "sandbox" validate_generic_safe_string GMOD_GAMEMODE 0
    # Asks which map (level/layout) to load — "gm_construct" is Garry's Mod's
    # classic default map. Stored in GMOD_MAP.
    prompt_and_validate "Map" "gm_construct" validate_generic_safe_string GMOD_MAP 0
    # Asks for the maximum number of players — must be between 2 and 128.
    # Uses the custom validator validate_gmod_max_players defined below.
    prompt_and_validate "Max players (2-128)" "16" validate_gmod_max_players GMOD_MAX_PLAYERS 0

    # Check if this is an existing instance that already has a password set.
    # "${GMOD_EXISTING_PASSWORD:-}" uses Bash's "default value" syntax — if the
    # variable is unset, it becomes an empty string instead of causing an error.
    if [[ -n "${GMOD_EXISTING_PASSWORD:-}" ]]; then
        # If there's an existing password, show it as the default and let the
        # user keep it by pressing Enter, or change it by typing a new one.
        prompt_and_validate "Server password (blank keeps current)" "$GMOD_EXISTING_PASSWORD" validate_generic_safe_string GMOD_PASSWORD 0
    # If the user is running in non-interactive/auto mode (ASSUME_DEFAULTS=1),
    # skip the prompt and use sensible defaults.
    elif [[ "$ASSUME_DEFAULTS" -eq 1 ]]; then
        # Set the password to empty (no password = open server anyone can join).
        GMOD_PASSWORD=""
        # Show a warning so the user knows what happened.
        log_warn "Non-interactive mode: leaving the join password blank (open server)."
    else
        # Otherwise, this is a fresh install — prompt for a password from scratch.
        # An empty answer means no password (open server).
        prompt_and_validate "Server password (blank = no password)" "" validate_generic_safe_string GMOD_PASSWORD 0
    fi

    # Same three-way logic as above, but for the RCON password (remote admin password).
    # RCON lets admins run commands on the server from inside the game or a tool.
    if [[ -n "${GMOD_EXISTING_RCON_PASSWORD:-}" ]]; then
        prompt_and_validate "RCON password (blank keeps current)" "$GMOD_EXISTING_RCON_PASSWORD" validate_generic_safe_string GMOD_RCON_PASSWORD 0
    elif [[ "$ASSUME_DEFAULTS" -eq 1 ]]; then
        # "tr -dc 'A-Za-z0-9' < /dev/urandom" reads random bytes and keeps only
        # letters and digits. "| head -c 16" takes the first 16 characters.
        # "$(...)" captures the output into the variable.
        GMOD_RCON_PASSWORD="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16 || true)"
        log_warn "Non-interactive mode: generated a random RCON password."
        # Print the generated password so the admin can see and save it.
        echo -e "${C_BOLD}    Generated RCON password: ${GMOD_RCON_PASSWORD}${C_RESET}"
    else
        # Fresh install — ask for RCON password. The "1" at the end means
        # "hidden" — the input won't be shown on screen (like typing a password).
        prompt_and_validate "RCON password" "" validate_generic_password GMOD_RCON_PASSWORD 1
    fi

    # PROFILE_EXTRA_CONFIG_VARS: a Bash array listing all variable names that
    # should be saved to the instance's config file so they persist between restarts.
    PROFILE_EXTRA_CONFIG_VARS=(GMOD_HOSTNAME GMOD_GAMEMODE GMOD_MAP GMOD_MAX_PLAYERS GMOD_PASSWORD GMOD_RCON_PASSWORD)
}

# validate_gmod_max_players: a custom validation function that checks whether
# the user's input is a valid player count for Garry's Mod.
validate_gmod_max_players() {
    # "local v="$1"" creates a local variable v and assigns it the first
    # argument (the value the user typed).
    local v="$1"
    # "[[ "$v" =~ ^[0-9]+$ ]]" checks if v contains ONLY digits (0-9).
    # "&&" means "and also" — both conditions must be true.
    # "(( v >= 2 && v <= 128 ))" checks if v is between 2 and 128 inclusive.
    # If both are true, return 0 (success). Otherwise, show an error and return 1 (failure).
    [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 2 && v <= 128 )) || { echo "Must be a whole number between 2 and 128."; return 1; }
    # "return 0" means "this validation passed" — 0 is Bash's success code.
    return 0
}

# profile_build_launch_args: builds the list of command-line arguments that will
# be passed to the server binary when it starts. These arguments tell the server
# what game to run, what map, how many players, what port, etc.
profile_build_launch_args() {
    # LAUNCH_ARGS is a Bash array — it holds all the arguments as a list.
    # Each line adds one argument that will be passed to srcds_run at startup.
    LAUNCH_ARGS=(
        # "-game garrysmod" tells Source engine to load the Garry's Mod game files.
        -game garrysmod
        # "+gamemode sandbox" sets the game mode to sandbox (players build freely).
        +gamemode "$GMOD_GAMEMODE"
        # "+map gm_construct" tells the server which map (level) to load first.
        +map "$GMOD_MAP"
        # "+maxplayers 16" sets the maximum number of player slots.
        +maxplayers "$GMOD_MAX_PLAYERS"
        # "-port 27015" sets the network port number for players to connect to.
        -port "$SERVER_PORT"
        # "+hostname My GMod Server" sets the name shown in the server browser.
        +hostname "$GMOD_HOSTNAME"
        # "+rcon_password secret" sets the password for remote admin access.
        +rcon_password "$GMOD_RCON_PASSWORD"
        # "-secure" enables Valve Anti-Cheat (VAC) on the server.
        -secure
    )
    # "if" checks a condition — here we check if a password was actually set
    # (non-empty string). "-n" tests that a string is NOT empty.
    if [[ -n "$GMOD_PASSWORD" ]]; then
        # If a password exists, add the "+sv_password" argument to the array.
        # "+sv_password" makes the server require a password to join.
        LAUNCH_ARGS+=(+sv_password "$GMOD_PASSWORD")
    fi
}

# gmod_rcon: a function that sends remote admin commands (RCON) to the running
# server. It uses Python to implement the Source engine's RCON network protocol.
# This is the same RCON client as teamfortress2.profile.sh (both use Source 1).
gmod_rcon() {
    # "local command="$1"" stores the first argument (the RCON command to send).
    local command="$1"
    # "python3 -" tells Python to run code passed via stdin (the << 'PYEOF' part).
    # "$SERVER_PORT" "$GMOD_RCON_PASSWORD" "$command" are passed as command-line
    # arguments to the Python script (accessed as sys.argv[1], [2], [3]).
    # "2>/dev/null" hides any Python error messages.
    python3 - "$SERVER_PORT" "$GMOD_RCON_PASSWORD" "$command" << 'PYEOF' 2>/dev/null
import socket, struct, sys
# send_packet: builds a network packet in the Source RCON format and sends it.
# "sock" is the network connection, "pkt_id" is a unique number for this packet,
# "pkt_type" says what kind of packet it is (3=auth, 2=command), "body" is the text.
def send_packet(sock, pkt_id, pkt_type, body):
    # struct.pack('<ii', pkt_id, pkt_type) converts two integers into raw bytes
    # in little-endian byte order (the format Source RCON expects).
    payload = struct.pack('<ii', pkt_id, pkt_type) + body.encode() + b'\x00\x00'
    # struct.pack('<i', len(payload)) prepends the total packet length as a 4-byte integer.
    sock.sendall(struct.pack('<i', len(payload)) + payload)
# read_packet: reads one RCON response packet from the server and parses it.
def read_packet(sock):
    # Read the first 4 bytes — they tell us how many more bytes to expect.
    lb = sock.recv(4)
    # If we got fewer than 4 bytes, the connection dropped — return empty.
    if len(lb) < 4: return None, None, ""
    # Convert those 4 bytes into an integer (the packet length).
    length = struct.unpack('<i', lb)[0]
    # Read the rest of the packet, potentially in multiple chunks.
    data = b''
    while len(data) < length:
        c = sock.recv(length - len(data))
        if not c: break
        data += c
    # If what we got is too short to be a valid packet, return empty.
    if len(data) < 8: return None, None, ""
    # Unpack the packet ID and packet type from the first 8 bytes.
    pid, pt = struct.unpack('<ii', data[:8])
    # Return the packet ID, packet type, and the text body (minus trailing null bytes).
    return pid, pt, data[8:-2].decode(errors='replace')
# Get the port, password, and command from the command-line arguments.
port, password, command = int(sys.argv[1]), sys.argv[2], sys.argv[3]
try:
    # Open a TCP connection to the server on localhost (127.0.0.1) at the given port.
    sock = socket.create_connection(("127.0.0.1", port), timeout=5)
    # Send an authentication packet (type 3) with the RCON password.
    send_packet(sock, 1, 3, password)
    # Read the server's response to see if authentication succeeded.
    auth_id, _, _ = read_packet(sock)
    # If auth_id is -1, the password was wrong — exit with error code 1.
    if auth_id == -1: sys.exit(1)
    # Send the actual command (type 2) now that we're authenticated.
    send_packet(sock, 2, 2, command)
    # Read the server's response to the command.
    _, _, body = read_packet(sock)
    # Print the response text to the terminal (stripping leading/trailing whitespace).
    print(body.strip())
    # Close the network connection.
    sock.close()
# "except Exception" catches any error that happened above (connection refused, etc.)
except Exception:
    # Exit with error code 1 to signal failure to the calling script.
    sys.exit(1)
PYEOF
}

# profile_get_player_count: a function that asks the server "how many players are
# currently connected?" by using RCON to send the "status" command.
profile_get_player_count() {
    # "local output" declares a variable to hold the RCON command's response.
    local output
    # Send the "status" command via RCON and capture the output.
    # "2>/dev/null" hides errors. "|| return 1" means if RCON fails, return failure.
    output="$(gmod_rcon "status" 2>/dev/null)" || return 1
    # grep -oP uses a "lookbehind" regex to find the number after "players : ".
    # For example, if the output says "players : 5", this extracts just "5".
    # "|| echo ''" means if no match is found, return an empty string instead of an error.
    grep -oP '(?<=players : )\d+' <<< "$output" || echo ""
}

# profile_post_start_notes: prints helpful tips and information after the server
# has been set up and started. These are things the user should know.
profile_post_start_notes() {
    # "echo -e" prints text with special formatting codes interpreted.
    # "${C_BOLD}Note:${C_RESET}" makes "Note:" appear in bold, then resets to normal.
    echo -e "${C_BOLD}Note:${C_RESET} Default gamemode/map are sandbox/gm_construct; both are commonly"
    echo "workshop-addon-dependent in practice -- if you plan to run a specific gamemode"
    echo "(TTT, DarkRP, etc.), you'll likely want to add workshop content separately."
}

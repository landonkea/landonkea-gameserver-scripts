###############################################################################
# minecraft.profile.sh -- Minecraft Java Edition dedicated server
#
# WHAT MAKES THIS PROFILE DIFFERENT FROM MOST OTHERS IN THIS PLATFORM:
#   1. Minecraft is NOT distributed through Steam at all -- most profiles
#      in this platform use a tool called SteamCMD to download a game's
#      server files, but Minecraft has to be downloaded directly from its
#      publisher, Mojang, instead. See profile_custom_download() below.
#   2. Minecraft's server is a ".jar" file, which needs a program called a
#      "Java Virtual Machine" (JVM) installed to run it -- it's not a
#      normal, directly-runnable program the way most of this platform's
#      games are.
#   3. Minecraft has a real, in-game remote-control feature called RCON,
#      which this profile uses to ask the running server "how many
#      players are connected right now?" and to tell it "please save the
#      world to disk right now" -- most profiles in this platform can't do
#      either of these things precisely, and fall back to guessing.
#
# Confidence notes (read before relying on this in production):
#   - Minecraft is NOT distributed via Steam/SteamCMD at all -- it's
#     downloaded directly from Mojang. This profile uses
#     profile_custom_download() (not SteamCMD) via Mojang's official
#     version-manifest API, which is a stable, long-documented mechanism.
#   - Requires a JVM (PROFILE_REQUIRES_JAVA=1) -- the core installs
#     OpenJDK automatically. Which Java version a given Minecraft release
#     needs can change over time -- if the server's own log complains
#     about a Java version mismatch, install a newer/older JDK by hand.
#   - Vanilla Minecraft has NO join password / shared-secret concept --
#     access control is via whitelist.json and Mojang-account verification
#     (online-mode), not a server password. This profile deliberately has
#     no password prompt; that's correct, not an oversight.
#   - RCON is built into vanilla Minecraft, so this profile implements
#     REAL profile_get_player_count()/profile_trigger_save() hooks (via a
#     small hand-written RCON client -- there's no standard apt package for
#     an RCON client, and the protocol is simple enough to implement
#     directly rather than pull in a third download source). This has
#     actually been tested against a matching hand-written test RCON
#     server during development (not just reasoned about), though that's
#     still not the same as testing against a real Minecraft server.
#   - Only ever installs the latest RELEASE (not snapshots).
#   - This is Java Edition. Bedrock Edition (used by consoles/mobile) is a
#     completely different server binary and is not covered here.
###############################################################################

# --- Basic facts about this game (see terraria.profile.sh for a
#     line-by-line explanation of what each of these means) ---
PROFILE_GAME_ID="minecraft"
PROFILE_DISPLAY_NAME="Minecraft (Java Edition)"

# PROFILE_STEAM_APPID is deliberately an EMPTY string here, on purpose --
# this is how a profile tells the platform "this game isn't on Steam at
# all, don't try to use SteamCMD for it." When this is empty, the
# platform requires this file to instead define a function called
# profile_custom_download (see below) and calls that instead.
PROFILE_STEAM_APPID=""
PROFILE_STEAM_PLATFORM="linux"
PROFILE_REQUIRES_WINE=0

# PROFILE_REQUIRES_JAVA: sets to 1 (true) tells the platform two things:
# first, to automatically install a Java Virtual Machine (a program that
# knows how to run ".jar" files) the first time it's actually needed --
# most people running only OTHER games never end up with Java installed
# at all, keeping their setup lighter. Second, it tells the platform to
# start this game using "java -jar <file>" instead of running the file
# directly the normal way.
PROFILE_REQUIRES_JAVA=1

# PROFILE_PORT_COUNT: Minecraft needs 2 ports -- one for the actual game,
# and a second one for RCON (remote admin access).
PROFILE_PORT_COUNT=2

# PROFILE_RECOMMENDED_RAM_MB: an optional, best-effort recommendation (vanilla server, modest player counts).
# This is a advisory floor, not a hard technical limit -- the platform warns
# clearly (and asks for confirmation interactively) if the host has less than
# this, but never blocks the install outright.
PROFILE_RECOMMENDED_RAM_MB=2048

# This is a "constant" -- a variable that's set once here and never
# changed afterward (by convention, constants are written in ALL CAPS).
# It's the web address of Mojang's official, publicly documented list of
# every Minecraft version ever released, and where to download each one.
readonly MC_VERSION_MANIFEST_URL="https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"

# profile_port_specs: see terraria.profile.sh for a full explanation of
# this function's job. Both of Minecraft's ports use TCP (not UDP).
profile_port_specs() {
    echo "0:tcp:game"
    echo "1:tcp:rcon"
}

# profile_find_binary: unlike most profiles (which have to SEARCH for the
# server program, since SteamCMD's download layout can vary), this
# profile fully controls the download itself (see
# profile_custom_download below) and always saves the file under this
# exact, predictable name -- so there's no need to search for it, this
# function can just state where it knows the file already is.
profile_find_binary() {
    echo "$1/server.jar"
}

# profile_custom_download: this is what makes Minecraft possible on this
# platform despite not being on Steam. Downloading it correctly is a
# two-step process:
#   Step 1: ask Mojang's "version manifest" web address (above) which
#           version is the current, official "release" (as opposed to an
#           experimental "snapshot" version).
#   Step 2: that same manifest also gives a SEPARATE web address, specific
#           to that one version, which finally contains the actual
#           download link for that version's server.jar file.
# Two steps are needed because Mojang's system is designed so the main
# manifest file stays small and simple, while still supporting hundreds of
# different versions, each with their own separate, detailed information
# page.
profile_custom_download() {
    local golden_dir="$1"
    local manifest latest_release version_url server_url

    log_info "[minecraft] Looking up the latest release from Mojang's version manifest..."

    # "curl" is a tool for downloading things from the internet. -fsS
    # means "fail cleanly and quietly on an error, but still show real
    # error messages if something goes wrong" (as opposed to just hanging
    # or printing a giant progress bar). --max-time 20 means "give up
    # after 20 seconds if there's no response, rather than waiting
    # forever." The whole line downloads the manifest's TEXT CONTENT
    # (which is in a format called JSON) into the "manifest" variable.
    manifest="$(curl_with_retry -fsS --max-time 20 "$MC_VERSION_MANIFEST_URL")" || {
        log_err "[minecraft] Could not reach Mojang's version manifest."
        return 1
    }

    # "jq" is a tool specifically for reading JSON-formatted text and
    # pulling out one specific piece of it -- here, ".latest.release"
    # means "look inside the object called 'latest', and get the value
    # named 'release' from inside that." The "// empty" part means "if
    # that piece isn't there for some reason, treat it as an empty
    # answer instead of causing an error."
    latest_release="$(jq -r '.latest.release // empty' <<< "$manifest")"
    [[ -n "$latest_release" ]] || { log_err "[minecraft] Manifest had no latest release id (API shape may have changed)."; return 1; }
    log_info "[minecraft] Latest release: ${latest_release}"

    # This jq command is more advanced: it looks through the manifest's
    # long LIST of every version ("versions[]" means "for each entry in
    # that list"), finds the one whose "id" exactly matches the release
    # version found above, and gets that specific entry's own "url" field
    # -- the address of the detailed, per-version manifest mentioned above.
    version_url="$(jq -r --arg id "$latest_release" '.versions[] | select(.id == $id) | .url // empty' <<< "$manifest")"
    [[ -n "$version_url" ]] || { log_err "[minecraft] No manifest URL found for version ${latest_release}."; return 1; }

    local version_manifest
    version_manifest="$(curl_with_retry -fsS --max-time 20 "$version_url")" || { log_err "[minecraft] Could not fetch the version-specific manifest."; return 1; }

    # Finally: dig into THIS version's own manifest to find the actual
    # download web address for the server program itself.
    server_url="$(jq -r '.downloads.server.url // empty' <<< "$version_manifest")"
    [[ -n "$server_url" ]] || { log_err "[minecraft] Version manifest had no server download URL (API shape may have changed)."; return 1; }

    log_info "[minecraft] Downloading server.jar (version ${latest_release})..."
    # -L means "follow the link if it redirects somewhere else first"
    # (common for file downloads). -o names the exact file to save into.
    curl_with_retry -fsSL --max-time 300 "$server_url" -o "${golden_dir}/server.jar" || { log_err "[minecraft] Download failed."; return 1; }

    # -s (in this context, as a file-test) checks "does this file exist
    # AND is it bigger than zero bytes" -- catching the case where the
    # download technically succeeded but produced an empty, broken file.
    [[ -s "${golden_dir}/server.jar" ]] || { log_err "[minecraft] Downloaded file is empty."; return 1; }

    log_ok "[minecraft] server.jar (version ${latest_release}) downloaded."
}

# validate_mc_max_players: see terraria.profile.sh's validate_tr_max_players
# for a full explanation of how validator functions work in general.
validate_mc_max_players() {
    local v="$1"
    [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 1 && v <= 200 )) || { echo "Must be a whole number between 1 and 200."; return 1; }
    return 0
}

# validate_mc_difficulty: only accepts one of Minecraft's own four real
# difficulty names -- anything else is rejected with a clear message.
validate_mc_difficulty() {
    # "${1,,}" means "the first argument, converted entirely to lowercase
    # first" -- so someone typing "Easy" or "EASY" is still accepted.
    case "${1,,}" in peaceful|easy|normal|hard) return 0 ;; *) echo "Must be one of: peaceful, easy, normal, hard."; return 1 ;; esac
}

# validate_mc_gamemode: same idea, for Minecraft's four real game modes.
validate_mc_gamemode() {
    case "${1,,}" in survival|creative|adventure|spectator) return 0 ;; *) echo "Must be one of: survival, creative, adventure, spectator."; return 1 ;; esac
}

# validate_mc_heap_gb: checks the requested amount of memory (RAM) to
# give the Java program is a sensible whole number of gigabytes.
validate_mc_heap_gb() {
    local v="$1"
    [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 1 && v <= 64 )) || { echo "Must be a whole number between 1 and 64."; return 1; }
    return 0
}

# profile_gather_prompts: asks every Minecraft-specific question. The
# EULA (End User License Agreement) question at the top is handled very
# differently from every other prompt in this whole platform -- it's a
# real legal agreement with Mojang, so declining it must actually CANCEL
# setting up this server, not just quietly default to "yes" the way
# other settings safely can.
profile_gather_prompts() {
    echo
    echo "Minecraft requires accepting Mojang's End User License Agreement to run a server:"
    echo "  https://www.minecraft.net/eula"

    if [[ "$ASSUME_DEFAULTS" -eq 1 ]]; then
        # Automatic ("-y") mode: there's no person present to ask, so
        # this treats running the command AT ALL as an implicit
        # confirmation that the EULA was already read and accepted --
        # while still saying so out loud in the log, rather than silently
        # assuming it.
        log_warn "Non-interactive mode: proceeding assumes you have already read and agree to Mojang's EULA (https://www.minecraft.net/eula)."
        MC_EULA_ACCEPTED="yes"
    else
        # Interactive mode: a real person is present. Ask directly, and
        # if they type anything OTHER than exactly "yes", stop entirely
        # -- "die" is a function (defined once, in the main platform
        # script) that prints an error message and immediately ends the
        # whole setup process for this instance.
        local eula_reply=""
        read -r -p "Type 'yes' to accept, anything else to cancel this instance: " eula_reply < /dev/tty || true
        if [[ "${eula_reply,,}" != "yes" ]]; then
            die "Minecraft EULA not accepted; cancelling this instance. Re-run when ready to accept."
        fi
        MC_EULA_ACCEPTED="yes"
    fi

    prompt_and_validate "World name (level-name)" "world" validate_generic_safe_string MC_LEVEL_NAME 0
    prompt_and_validate "Max players" "20" validate_mc_max_players MC_MAX_PLAYERS 0
    prompt_and_validate "Message of the day" "A Minecraft Server" validate_generic_safe_string MC_MOTD 0
    prompt_and_validate "Difficulty (peaceful/easy/normal/hard)" "easy" validate_mc_difficulty MC_DIFFICULTY 0
    prompt_and_validate "Game mode (survival/creative/adventure/spectator)" "survival" validate_mc_gamemode MC_GAMEMODE 0
    prompt_and_validate "Java heap size in GB" "2" validate_mc_heap_gb MC_HEAP_GB 0

    # RCON password handling follows the same three-case pattern
    # explained in detail in terraria.profile.sh's password-handling block
    # (existing instance / automatic mode / real person typing).
    if [[ -n "${MC_EXISTING_RCON_PASSWORD:-}" ]]; then
        prompt_and_validate "RCON password (blank keeps current)" "$MC_EXISTING_RCON_PASSWORD" validate_generic_safe_string MC_RCON_PASSWORD 0
    elif [[ "$ASSUME_DEFAULTS" -eq 1 ]]; then
        # "tr -dc 'A-Za-z0-9'" reads random bytes and keeps only letters
        # and numbers, throwing away anything else -- combined with
        # "head -c 16", this is how this platform generates a random,
        # reasonably strong 16-character password automatically when no
        # human is present to type one themselves.
        MC_RCON_PASSWORD="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16 || true)"
        log_warn "Non-interactive mode: generated a random RCON password."
        echo -e "${C_BOLD}    Generated RCON password: ${MC_RCON_PASSWORD}${C_RESET}"
    else
        prompt_and_validate "RCON password (for admin console access -- NOT a player join password)" "" validate_generic_password MC_RCON_PASSWORD 1
    fi

    PROFILE_EXTRA_CONFIG_VARS=(MC_EULA_ACCEPTED MC_LEVEL_NAME MC_MAX_PLAYERS MC_MOTD MC_DIFFICULTY MC_GAMEMODE MC_HEAP_GB MC_RCON_PASSWORD)
}

# profile_build_launch_args: writes Minecraft's two required settings
# files (eula.txt and server.properties) and prepares the JVM's memory
# settings. Note this writes into THIS INSTANCE's own private server
# folder (INSTANCE_SERVER_DIR), never into the shared golden download --
# every instance gets its own independent settings, even though they all
# share the same downloaded server.jar file underneath.
profile_build_launch_args() {
    # Writing "eula=true" into this exact file, with this exact filename,
    # is literally how Mojang's own server software checks that its EULA
    # was accepted -- it looks for this file and this line before it will
    # even start.
    echo "eula=true" > "${INSTANCE_SERVER_DIR}/eula.txt"

    # server.properties is Minecraft's main settings file -- a plain list
    # of "key=value" lines, one setting per line.
    cat > "${INSTANCE_SERVER_DIR}/server.properties" << CFG
server-port=${SERVER_PORT}
level-name=${MC_LEVEL_NAME}
max-players=${MC_MAX_PLAYERS}
motd=${MC_MOTD}
difficulty=${MC_DIFFICULTY}
gamemode=${MC_GAMEMODE}
online-mode=true
white-list=false
enable-rcon=true
rcon.port=$(( SERVER_PORT + 1 ))
rcon.password=${MC_RCON_PASSWORD}
enable-command-block=false
CFG

    # Minecraft saves its world as a FOLDER (not a single file) named
    # after "level-name", normally created right next to server.jar.
    # Rather than let it save inside the game's own folder (which this
    # platform treats as disposable/replaceable, since it's just a copy
    # synced from the shared download), a "symbolic link" (a shortcut,
    # essentially) is created so that when Minecraft thinks it's saving
    # into its own local "world" folder, it's actually transparently
    # saving into this instance's own dedicated, permanent data folder
    # instead -- which is what actually gets backed up.
    mkdir -p "${INSTANCE_DATA_DIR}/${MC_LEVEL_NAME}"
    if [[ ! -L "${INSTANCE_SERVER_DIR}/${MC_LEVEL_NAME}" ]]; then
        # "-L" checks "is this already a symbolic link" -- if it's NOT
        # (meaning this is either the very first time starting this
        # instance, or somehow a real folder ended up there instead),
        # clear out whatever's there first, then create the shortcut.
        rm -rf "${INSTANCE_SERVER_DIR:?}/${MC_LEVEL_NAME}" 2>/dev/null || true
        ln -sfn "${INSTANCE_DATA_DIR}/${MC_LEVEL_NAME}" "${INSTANCE_SERVER_DIR}/${MC_LEVEL_NAME}"
    fi

    # -Xms and -Xmx tell Java the minimum and maximum amount of memory to
    # use -- setting both to the same value (as done here) is a common,
    # recommended practice for server software, since it avoids Java
    # spending extra effort growing/shrinking its memory usage while
    # running. --nogui tells Minecraft's server not to try to open its
    # own separate graphical window (which wouldn't work on a headless
    # server with no screen attached anyway).
    LAUNCH_ARGS=("-Xms${MC_HEAP_GB}G" "-Xmx${MC_HEAP_GB}G" "--nogui")
}

# mc_rcon: this is a genuinely advanced piece of this file, so it's worth
# explaining what RCON even IS first. Minecraft's server has a hidden,
# separate "back door" network connection (RCON) meant only for
# administrators, completely separate from the normal player connection.
# Through it, you can send the exact same commands you'd type in-game
# (like "list" to see who's online, or "save-all" to force a save) and get
# back whatever text response the server would normally show. There's no
# ready-made command-line tool for this included with Ubuntu, and the
# ones that DO exist aren't part of Ubuntu's standard software library
# (apt), so rather than depending on a third, less-common download source,
# this project speaks the RCON network protocol directly, using Python
# (which IS already included with Ubuntu).
#
# The weird-looking indented block between "<< 'PYEOF'" and "PYEOF" is a
# Python program, not Bash -- Bash is handing it, as plain text, straight
# to the "python3" program to run.
mc_rcon() {
    local command="$1"
    python3 - "$SERVER_PORT" "$MC_RCON_PASSWORD" "$command" << 'PYEOF' 2>/dev/null
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

port, password, command = int(sys.argv[1]) + 1, sys.argv[2], sys.argv[3]
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

# profile_get_player_count: this is an OPTIONAL function -- most profiles
# in this platform don't define it at all, because most games don't offer
# a reliable way to ask "how many players are connected right now?" from
# the outside. When a profile DOES define this, the platform's automatic
# "put the server to sleep after nobody's played for a while" feature can
# use a real, precise count instead of guessing based on network traffic.
profile_get_player_count() {
    local output
    # Minecraft's own "list" command replies with a sentence like:
    # "There are 2 of a max of 20 players online: Alice, Bob"
    output="$(mc_rcon "list" 2>/dev/null)" || return 1
    # "grep -oP '(?<=There are )\d+'" finds the digits that come right
    # after the exact phrase "There are ", pulling just the number "2"
    # out of that whole sentence.
    grep -oP '(?<=There are )\d+' <<< "$output" || echo ""
}

# profile_trigger_save: another OPTIONAL function -- called automatically
# right before the platform puts an idle server to sleep, giving this
# profile a chance to force a save first if the game supports one.
profile_trigger_save() {
    mc_rcon "save-all" >/dev/null 2>&1 || true
}

profile_post_start_notes() {
    echo -e "${C_BOLD}Note:${C_RESET} Minecraft has no join password -- players connect by IP:port"
    echo "alone. To restrict who can join, use the whitelist (RCON: whitelist add <name>,"
    echo "whitelist on) or rely on online-mode's Mojang-account verification."
}

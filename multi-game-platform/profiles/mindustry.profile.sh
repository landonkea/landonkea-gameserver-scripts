###############################################################################
# mindustry.profile.sh -- Mindustry dedicated server
#
# WHAT MAKES THIS THE MOST UNUSUAL PROFILE IN THE WHOLE PLATFORM:
# every other game here starts up already knowing what to do, either from
# command-line flags or a settings file written before it starts.
# Mindustry's server is different: it starts up and just sits there
# showing a ">" prompt, waiting for someone to TYPE commands to it, like
# "host" (meaning "start hosting a game now") -- the same way you'd type
# commands into a Linux terminal. Since there's no real person sitting
# there to type anything, this profile has to fake having a person type
# those commands automatically. How that's done is explained step by step
# inside profile_pre_launch_setup below -- it's genuinely one of the more
# advanced pieces of shell scripting in this whole project, so it's worth
# reading slowly.
#
# Confidence notes:
#   - Mindustry is open-source and NOT on Steam -- reuses the same
#     non-Steam pattern as minecraft.profile.sh, but downloads from GitHub
#     Releases (github.com/Anuken/Mindustry) instead of Mojang. The asset
#     naming convention ("server-release.jar") has been stable for a long
#     time but is the one thing most likely to need adjusting if a future
#     release renames it.
#   - Requires a JVM (PROFILE_REQUIRES_JAVA=1), same as Minecraft.
#   - The exact console command syntax below ("host <map> <mode>",
#     "config port/name") reflects long-standing Mindustry server
#     documentation, but I can't verify it against a live server from this
#     sandbox -- if the server starts but never actually hosts a game,
#     this is the first place to check.
#   - No profile_get_player_count/profile_trigger_save implemented here --
#     capturing command *output* back through the one-way setup below is
#     substantially more complex than sending commands, so on-demand idle
#     detection for this profile falls back to the generic traffic
#     heuristic. A precise version could parse the server's own log file
#     for join/leave messages as a future improvement.
###############################################################################

PROFILE_GAME_ID="mindustry"
PROFILE_DISPLAY_NAME="Mindustry"
PROFILE_STEAM_APPID=""
PROFILE_STEAM_PLATFORM="linux"
PROFILE_REQUIRES_WINE=0
PROFILE_REQUIRES_JAVA=1
PROFILE_PORT_COUNT=1

# PROFILE_RECOMMENDED_RAM_MB: an optional, best-effort recommendation (lightweight despite running on a JVM).
# This is a advisory floor, not a hard technical limit -- the platform warns
# clearly (and asks for confirmation interactively) if the host has less than
# this, but never blocks the install outright.
PROFILE_RECOMMENDED_RAM_MB=512

# GitHub (the website that hosts this open-source project's code) offers
# a free, public web address that always answers with information about
# whatever the CURRENT latest release is -- this is how the download
# function below finds the right file without this profile needing to be
# manually updated every time a new Mindustry version comes out.
readonly MDX_RELEASES_API_URL="https://api.github.com/repos/Anuken/Mindustry/releases/latest"

profile_port_specs() {
    echo "0:udp:game"
}

# profile_find_binary: since profile_custom_download (below) always saves
# the file under this exact name, there's no need to search for it.
profile_find_binary() {
    echo "$1/server-release.jar"
}

# profile_custom_download: asks GitHub's API "what is the latest release
# of this project, and what files (assets) does it include?", finds the
# one specifically named "server-release.jar" among possibly several
# files offered, and downloads just that one.
profile_custom_download() {
    local golden_dir="$1"
    local release_json asset_url

    log_info "[mindustry] Looking up the latest release from GitHub..."
    release_json="$(curl_with_retry -fsS --max-time 20 -H "Accept: application/vnd.github+json" "$MDX_RELEASES_API_URL")" || {
        log_err "[mindustry] Could not reach the GitHub releases API."
        return 1
    }

    # This asks "jq" (a tool for reading JSON-formatted text) to look
    # through the list of files ("assets") attached to this release, find
    # the one whose name is EXACTLY "server-release.jar", and give back
    # its direct download web address.
    asset_url="$(jq -r '.assets[] | select(.name == "server-release.jar") | .browser_download_url // empty' <<< "$release_json")"
    [[ -n "$asset_url" ]] || { log_err "[mindustry] No 'server-release.jar' asset found on the latest release (naming may have changed)."; return 1; }

    log_info "[mindustry] Downloading server-release.jar..."
    curl_with_retry -fsSL --max-time 300 "$asset_url" -o "${golden_dir}/server-release.jar" || { log_err "[mindustry] Download failed."; return 1; }
    [[ -s "${golden_dir}/server-release.jar" ]] || { log_err "[mindustry] Downloaded file is empty."; return 1; }
    log_ok "[mindustry] server-release.jar downloaded."
}

# profile_gather_prompts: notice there's no password question here at
# all -- like Minecraft, vanilla Mindustry doesn't have a join-password
# feature built in.
profile_gather_prompts() {
    prompt_and_validate "Server name" "My Mindustry Server" validate_generic_safe_string MDX_SERVER_NAME 0
    prompt_and_validate "Map name (must exist on the server, case-sensitive)" "groundZero" validate_generic_safe_string MDX_MAP 0
    prompt_and_validate "Game mode (survival/sandbox/attack/pvp/hexed)" "survival" validate_mdx_mode MDX_MODE 0
    prompt_and_validate "Java heap size in GB" "1" validate_mdx_heap_gb MDX_HEAP_GB 0
    PROFILE_EXTRA_CONFIG_VARS=(MDX_SERVER_NAME MDX_MAP MDX_MODE MDX_HEAP_GB)
}

validate_mdx_mode() {
    case "${1,,}" in survival|sandbox|attack|pvp|hexed) return 0 ;; *) echo "Must be one of: survival, sandbox, attack, pvp, hexed."; return 1 ;; esac
}

validate_mdx_heap_gb() {
    local v="$1"
    [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 1 && v <= 32 )) || { echo "Must be a whole number between 1 and 32."; return 1; }
    return 0
}

# profile_build_launch_args: just the JVM's memory settings this time --
# unlike almost every other profile, there's no settings FILE being
# written here at all. Everything Mindustry needs to know is instead sent
# to it as typed console commands, over in profile_pre_launch_setup below,
# once the server has actually started up and is ready to listen for them.
profile_build_launch_args() {
    LAUNCH_ARGS=("-Xms${MDX_HEAP_GB}G" "-Xmx${MDX_HEAP_GB}G")
}

# profile_pre_launch_setup: THIS IS THE ADVANCED PART. Read this slowly.
#
# Every running program has an invisible "stdin" (standard input) --
# think of it as a mail slot the program checks for new typed commands.
# Normally, stdin is connected to whatever's physically typed on a
# keyboard. But since nobody's sitting at a keyboard when a game server
# starts automatically, this function creates a FAKE mail slot instead,
# quietly pre-loaded with exactly the commands Mindustry needs, timed to
# arrive right after it's finished starting up.
#
# The tool used to build this fake mail slot is called a "named pipe" (or
# FIFO, short for "First In, First Out") -- it's a special kind of file
# that doesn't actually store any data on disk. Instead, whatever one
# program writes into it, another program reading from it receives,
# almost instantly, as if they were connected by a real pipe.
#
# There's one tricky part: a named pipe automatically tells its reader
# "there's nothing more coming, I'm done" (this is called reaching "EOF",
# end of file) the moment there's no longer ANY program still holding it
# open for writing. Since this profile only wants to send three short
# commands and then let the connection sit open indefinitely afterward
# (waiting for the ADMIN to possibly type more commands manually later,
# through other means), an extra small background helper process is
# started whose entire job is to hold the pipe open forever, so
# Mindustry's own reading side never mistakenly thinks "nothing more is
# coming" and gives up.
profile_pre_launch_setup() {
    # Build the exact file path for this instance's own private named
    # pipe, inside its own instance folder.
    local fifo="${INSTANCE_DIR}/mindustry.fifo"

    # Clear out any old, leftover pipe from a previous run, then create a
    # brand new one. "mkfifo" is the actual Linux command that creates
    # this special kind of file.
    rm -f "$fifo"
    mkfifo "$fifo"
    chmod 600 "$fifo"

    # This next line is genuinely a bit clever, so here it is broken down
    # piece by piece:
    #   "( ... ) &" runs everything inside the parentheses in the
    #     BACKGROUND -- meaning this script doesn't wait around for it to
    #     finish before moving on to the next line. It keeps running
    #     independently, alongside everything else.
    #   "exec 3>"$fifo"" opens the pipe FOR WRITING, and keeps that
    #     connection assigned to file-descriptor slot number 3 (an
    #     internal bookkeeping number Bash uses; the exact number doesn't
    #     matter here, it just needs to be a free one).
    #   "exec sleep infinity" then replaces this whole background
    #     process with a command that does absolutely nothing, forever --
    #     its entire purpose is to just sit there, keeping that
    #     file-descriptor-3 connection to the pipe open, which is exactly
    #     what stops the pipe from ever reaching "EOF."
    ( exec 3>"$fifo"; exec sleep infinity ) &
    # "disown" tells Bash "don't consider this background job part of
    # this script anymore" -- without it, some cleanup logic elsewhere
    # might try to wait for or stop it in ways that aren't wanted here;
    # this background helper is deliberately meant to keep running
    # independently for as long as the server itself runs.
    disown

    # This second background job is the one that ACTUALLY sends the
    # startup commands. It's also backgrounded (again using "&") so this
    # function can finish immediately and let the real Mindustry server
    # program start right away, rather than sitting around waiting.
    (
        # Wait 10 seconds first, giving the Mindustry server program
        # itself time to fully start up and be ready to actually receive
        # commands -- sending them too early could mean they're ignored.
        sleep 10
        {
            echo "config port ${SERVER_PORT}"
            echo "config name ${MDX_SERVER_NAME}"
            echo "host ${MDX_MAP} ${MDX_MODE}"
        } > "$fifo"
    ) &
    disown

    # Finally: redirect THIS SCRIPT's own stdin (its own "mail slot") to
    # read from the pipe instead of the normal keyboard/terminal. This
    # matters because in just a moment, the code that called this
    # function is going to "exec" (start) the real Mindustry server
    # program -- and a freshly-started program automatically inherits
    # whatever its stdin was already set to, right before it started.
    # So this one line is what makes Mindustry's server end up reading
    # from this fake pipe instead of a real, empty keyboard connection.
    exec 0< "$fifo"
}

profile_post_start_notes() {
    echo -e "${C_BOLD}Note:${C_RESET} Mindustry's server is console-driven, not config-file-driven --"
    echo "this instance is started by feeding it 'host ${MDX_MAP:-<map>} ...' automatically"
    echo "about 10 seconds after launch. If players can't connect, check"
    echo "'logs-instance.sh <name> service' to confirm hosting actually started, and that"
    echo "'${MDX_MAP:-<map>}' is a real map name on this server (map names are case-sensitive)."
    echo "Also: Mindustry has no join password; anyone with the address can connect."
}

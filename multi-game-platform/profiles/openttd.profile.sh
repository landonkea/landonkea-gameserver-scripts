###############################################################################
# openttd.profile.sh -- OpenTTD dedicated server
#
# Confidence notes: open-source, cross-platform, and one of the simplest
# profiles in this platform. Uses the direct binary release from
# openttd.org rather than Steam (OpenTTD is also on Steam, but the direct
# tarball needs no account and is simpler to script against reliably).
# Dedicated-server mode (-D) and openttd.cfg's key names have been stable
# for a very long time.
###############################################################################

# PROFILE_GAME_ID: a short, unique identifier for this game -- used internally
# by the platform to name folders, log entries, and systemd services
PROFILE_GAME_ID="openttd"
# PROFILE_DISPLAY_NAME: the human-readable name shown to users in menus and prompts
PROFILE_DISPLAY_NAME="OpenTTD"
# PROFILE_STEAM_APPID: empty string because OpenTTD is NOT downloaded from Steam --
# it's downloaded directly from openttd.org (the official website)
# This makes it a "non-Steam" profile
PROFILE_STEAM_APPID=""
# PROFILE_STEAM_PLATFORM: which OS platform to download -- "linux" even though
# it's not from Steam, this field still tells the platform which OS to target
PROFILE_STEAM_PLATFORM="linux"
# PROFILE_REQUIRES_WINE: 0 means no Wine needed -- OpenTTD is fully native on Linux
PROFILE_REQUIRES_WINE=0
# PROFILE_REQUIRES_JAVA: 0 means Java is not needed
PROFILE_REQUIRES_JAVA=0
# PROFILE_PORT_COUNT: OpenTTD only needs 1 port
PROFILE_PORT_COUNT=1

# PROFILE_RECOMMENDED_RAM_MB: an optional, best-effort recommendation (extremely lightweight engine).
# This is a advisory floor, not a hard technical limit -- the platform warns
# clearly (and asks for confirmation interactively) if the host has less than
# this, but never blocks the install outright.
# 512 MB = 0.5 GB -- OpenTTD is extremely lightweight, a very old and simple game
PROFILE_RECOMMENDED_RAM_MB=512

# readonly: makes this variable CONSTANT -- it cannot be changed later in the script
# OPENTTD_VERSION: the exact version number of OpenTTD to download
readonly OPENTTD_VERSION="14.1"
# OPENTTD_DOWNLOAD_URL: the full web address to download this specific version
# The ${OPENTTD_VERSION} part inserts the version number into the URL dynamically
readonly OPENTTD_DOWNLOAD_URL="https://cdn.openttd.org/openttd-releases/${OPENTTD_VERSION}/openttd-${OPENTTD_VERSION}-linux-generic-amd64.tar.xz"

# profile_port_specs(): declares which network ports this game needs
profile_port_specs() {
    # Port 0 needs BOTH UDP and TCP -- OpenTTD uses both protocols
    # UDP for fast game data, TCP for reliable connections
    echo "0:udp:game"
    echo "0:tcp:game"
}

# profile_find_binary(): locates the OpenTTD program on disk
profile_find_binary() {
    # search_dir: the directory to search in
    local search_dir="$1"
    # Look for a file named "openttd" (the main binary) -- up to 2 levels deep
    # -type f: only match regular files, not directories
    find "$search_dir" -maxdepth 2 -iname 'openttd' -type f 2>/dev/null | head -n1
}

# profile_custom_download(): downloads OpenTTD from the official website
# instead of Steam -- this function is called INSTEAD of SteamCMD when
# the game doesn't have a Steam App ID
# profile_custom_download: fetches a specific known-good OpenTTD release
# tarball directly from the project's own CDN. Pinned to a specific
# version (rather than "latest") since OpenTTD doesn't publish a stable
# "latest" API the way Mojang/Anuken's projects do -- update
# OPENTTD_VERSION above periodically if you want newer releases.
profile_custom_download() {
    # golden_dir: the directory where the downloaded files should be extracted
    local golden_dir="$1"
    # Log an info message so the user knows the download is starting
    log_info "[openttd] Downloading OpenTTD ${OPENTTD_VERSION}..."
    # curl_with_retry: downloads a file from a URL with automatic retries
    # -f: fail silently on HTTP errors, -s: silent mode, -S: show errors,
    # -L: follow redirects, --max-time 300: give up after 5 minutes
    # -o: save the downloaded file to this path
    # If the download fails, print an error and exit the function with failure
    curl_with_retry -fsSL --max-time 300 "$OPENTTD_DOWNLOAD_URL" -o "${BASE_TMP_DIR}/openttd.tar.xz" \
        || { log_err "[openttd] Download failed (check OPENTTD_VERSION is still a valid published release)."; return 1; }
    # tar -xJf: extracts a .tar.xz compressed archive
    # -x: extract files, -J: decompress with xz, -f: the file to extract from
    # -C "$golden_dir": extract into this directory
    # --strip-components=1: remove the top-level folder from the archive
    # If extraction fails, clean up the downloaded file and exit with failure
    tar -xJf "${BASE_TMP_DIR}/openttd.tar.xz" -C "$golden_dir" --strip-components=1 \
        || { log_err "[openttd] Extraction failed."; rm -f "${BASE_TMP_DIR}/openttd.tar.xz"; return 1; }
    # Clean up: delete the downloaded archive since we've already extracted it
    rm -f "${BASE_TMP_DIR}/openttd.tar.xz"
    # Verify: check that the expected binary file exists and is executable
    # -x: tests if a file exists AND is executable (has permission to run)
    [[ -x "${golden_dir}/openttd" ]] || { log_err "[openttd] Expected binary not found after extraction."; return 1; }
    # Log a success message
    log_ok "[openttd] OpenTTD ${OPENTTD_VERSION} downloaded and extracted."
}

# profile_gather_prompts(): asks the user game-specific questions during setup
profile_gather_prompts() {
    # Ask for the server's display name
    prompt_and_validate "Server name" "My OpenTTD Server" validate_generic_safe_string TTD_SERVER_NAME 0
    # Ask how many players can connect -- OpenTTD supports up to 255
    prompt_and_validate "Max players" "8" validate_ttd_max_players TTD_MAX_PLAYERS 0

    # Check if a password was already set from a previous configuration
    if [[ -n "${TTD_EXISTING_PASSWORD:-}" ]]; then
        # Show existing password as default -- user can press Enter to keep it
        prompt_and_validate "Server password (blank keeps current)" "$TTD_EXISTING_PASSWORD" validate_generic_safe_string TTD_PASSWORD 0
    # Auto mode: skip the question and leave the server open
    elif [[ "$ASSUME_DEFAULTS" -eq 1 ]]; then
        # Empty password = anyone can join
        TTD_PASSWORD=""
        # Warn the user
        log_warn "Non-interactive mode: leaving the join password blank (open server)."
    else
        # First-time setup: ask for a join password
        prompt_and_validate "Server password (blank = no password)" "" validate_generic_safe_string TTD_PASSWORD 0
    fi

    # Save these variables to the config file for persistence
    PROFILE_EXTRA_CONFIG_VARS=(TTD_SERVER_NAME TTD_MAX_PLAYERS TTD_PASSWORD)
}

# validate_ttd_max_players(): checks that the user entered a valid player count
# for OpenTTD -- must be 1-255
validate_ttd_max_players() {
    # Store the user's input in a local variable
    local v="$1"
    # ^[0-9]+$: regex that matches only digits (whole numbers)
    # v >= 1 && v <= 255: must be in OpenTTD's supported range
    [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 1 && v <= 255 )) || { echo "Must be a whole number between 1 and 255."; return 1; }
    # Return 0 = success
    return 0
}

# profile_build_launch_args(): writes a config file and builds command-line flags
# for starting the OpenTTD server
profile_build_launch_args() {
    # Create the save and autosave directories (-p = don't error if they exist)
    mkdir -p "${INSTANCE_DATA_DIR}/save" "${INSTANCE_DATA_DIR}/autosave"
    # cfg: the path to OpenTTD's config file (openttd.cfg)
    local cfg="${INSTANCE_DATA_DIR}/openttd.cfg"
    # Write the config file using a heredoc -- everything between << CFG and CFG
    # is written to the file, with variables replaced by their values
    cat > "$cfg" << CFG
[network]
# server_name: the name shown in the server browser
server_name = ${TTD_SERVER_NAME}
# server_port: which port to listen on
server_port = ${SERVER_PORT}
# max_clients: maximum number of players that can connect
max_clients = ${TTD_MAX_PLAYERS}
# server_password: password needed to join (empty = no password)
server_password = ${TTD_PASSWORD}
CFG
    # LAUNCH_ARGS: command-line flags for the OpenTTD server.
    # BUG FIX: this used to also pass "-d <path>" and "-M <path>", but those
    # are NOT save-directory flags -- "-d" actually sets OpenTTD's debug
    # verbosity level (0-9), and "-M" forces which music SET to load, not a
    # folder. Passing a filesystem path to either would have been silently
    # wrong (misread as a debug-level spec / an unknown music set), not an
    # actual save-directory redirect. OpenTTD doesn't need a CLI flag for
    # this at all: it automatically saves games/autosaves/screenshots next
    # to whatever config file it's using (see -c below), which is already
    # this instance's own INSTANCE_DATA_DIR -- so the save/autosave folders
    # created above are picked up on their own, no extra flag required.
    LAUNCH_ARGS=(
        # -D: run in dedicated server mode (no game window)
        -D
        # -c: path to the config file we just wrote -- OpenTTD also uses
        # this file's directory as the base for its save/autosave folders
        -c "$cfg"
    )
}

# profile_post_start_notes(): prints helpful tips AFTER the server is set up
profile_post_start_notes() {
    # Explain that the version is pinned (locked to a specific release)
    echo -e "${C_BOLD}Note:${C_RESET} Pinned to OpenTTD ${OPENTTD_VERSION} -- edit OPENTTD_VERSION near"
    # Tell the user how to update to a newer version if one becomes available
    echo "the top of openttd.profile.sh and re-run update-instance.sh to move to a newer"
    echo "release once one is available."
}

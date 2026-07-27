###############################################################################
# factorio.profile.sh -- Factorio headless dedicated server
#
# This profile's download mechanism (profile_custom_download) uses the
# same non-Steam approach explained in full detail inside
# minecraft.profile.sh -- read that file first if the general "how does a
# non-Steam game even get downloaded" concept is unfamiliar. Factorio's
# own version is simpler: no version-lookup step is needed since this
# always fetches whatever factorio.com currently calls "stable."
#
# Confidence notes:
#   - Factorio publishes a free headless Linux server tarball directly
#     from factorio.com, independent of owning the game on Steam -- this
#     has been a stable, long-documented distribution method for years.
#     PROFILE_STEAM_APPID is deliberately empty; see profile_custom_download().
#   - Native Linux binary (bin/x64/factorio) -- no Wine, no JVM.
#   - Uses UDP, a single port.
#   - Always downloads the current STABLE release (not experimental).
#   - server-settings.json schema below reflects long-stable, documented
#     keys; if a future version changes them, the server's own log
#     (via logs-instance.sh) will show a clear parse error.
###############################################################################

# PROFILE_GAME_ID: a short, unique identifier for this game — used internally by
# the platform to name folders, log entries, and systemd services.
PROFILE_GAME_ID="factorio"

# PROFILE_DISPLAY_NAME: the human-friendly name shown to the user in menus,
# prompts, and log messages.
PROFILE_DISPLAY_NAME="Factorio"

# PROFILE_STEAM_APPID: deliberately empty because Factorio's headless server
# is NOT downloaded through Steam — it's fetched directly from factorio.com.
# An empty string tells the platform to use profile_custom_download() instead.
PROFILE_STEAM_APPID=""

# PROFILE_STEAM_PLATFORM: even though we don't use SteamCMD, this tells the
# platform that the game targets Linux — "linux" means a native Linux binary.
PROFILE_STEAM_PLATFORM="linux"

# PROFILE_REQUIRES_WINE: set to 0 (false) — Factorio has a native Linux binary,
# so no Windows compatibility layer is needed.
PROFILE_REQUIRES_WINE=0

# PROFILE_REQUIRES_JAVA: set to 0 (false) — Factorio is written in C++, not Java.
# No Java runtime needed.
PROFILE_REQUIRES_JAVA=0

# PROFILE_PORT_COUNT: Factorio uses just 1 network port for game traffic.
PROFILE_PORT_COUNT=1

# PROFILE_RECOMMENDED_RAM_MB: an optional, best-effort recommendation (Factorio's
# engine is efficient even at scale). Advisory only — warns if the host has less,
# never blocks. 1024 MB = 1 GB.
PROFILE_RECOMMENDED_RAM_MB=1024

# FACTORIO_DOWNLOAD_URL: the direct download link for Factorio's current stable
# headless Linux server. This URL always points to whatever version Factorio
# considers "stable" — it doesn't need manual updating.
readonly FACTORIO_DOWNLOAD_URL="https://factorio.com/get-download/stable/headless/linux64"
# "readonly" means this variable cannot be changed later in the script — it's a
# safety measure to prevent accidental modification of the download URL.

# profile_port_specs: tells the platform which network ports this game uses.
profile_port_specs() {
    # "0:udp:game" — the single game port where players connect (UDP protocol).
    echo "0:udp:game"
}

# profile_find_binary: locates the Factorio server executable on disk.
# Unlike other profiles that search for the binary, Factorio has a known
# fixed path inside its extracted directory structure.
profile_find_binary() {
    # "echo" simply prints the expected path — no search needed because Factorio's
    # folder structure is always the same after extraction: factorio/bin/x64/factorio.
    echo "$1/factorio/bin/x64/factorio"
    # $1 is the search directory passed in, and we append the known relative path.
}

# profile_custom_download: downloads the Factorio server directly from factorio.com
# (not through SteamCMD). This is needed because Factorio's headless server is
# freely available without a Steam account.
profile_custom_download() {
    # "golden_dir" is where the downloaded files should be extracted to.
    local golden_dir="$1"
    log_info "[factorio] Downloading the current stable headless Linux server..."
    # "curl_with_retry" is a helper that downloads a URL to a file, with automatic
    # retries on failure. "-fsSL" means: -f = fail on HTTP errors, -s = silent
    # (no progress bar), -S = show errors even in silent mode, -L = follow redirects.
    # "--max-time 300" = give up after 300 seconds (5 minutes).
    # "-o ${BASE_TMP_DIR}/factorio.tar.xz" = save the download to a temp file.
    curl_with_retry -fsSL --max-time 300 "$FACTORIO_DOWNLOAD_URL" -o "${BASE_TMP_DIR}/factorio.tar.xz" \
        || { log_err "[factorio] Download failed."; return 1; }
    # "||" means "if the previous command failed, then..." — if the download failed,
    # log an error message and return 1 (failure) to stop the function early.
    # "tar" unpacks a compressed archive file (like a zip file, but a
    # different, common Linux format). The letters mean: x = extract,
    # J = the archive uses ".xz" compression specifically, f = the next
    # word is the filename to read from.
    tar -xJf "${BASE_TMP_DIR}/factorio.tar.xz" -C "$golden_dir" \
        || { log_err "[factorio] Extraction failed."; rm -f "${BASE_TMP_DIR}/factorio.tar.xz"; return 1; }
    # "-C $golden_dir" tells tar to extract files into the target directory.
    # If extraction fails, clean up the downloaded archive and return failure.
    rm -f "${BASE_TMP_DIR}/factorio.tar.xz"
    # "-x" checks if a file exists and is executable — verify the binary is there.
    [[ -x "${golden_dir}/factorio/bin/x64/factorio" ]] || { log_err "[factorio] Expected binary not found after extraction."; return 1; }
    log_ok "[factorio] Headless server downloaded and extracted."
}

# profile_gather_prompts: asks the user questions about their server configuration.
profile_gather_prompts() {
    # Ask for the save/world name — this is the filename of the save game.
    # Default: "world". Stored in FAC_SAVE_NAME.
    prompt_and_validate "Save/instance name" "world" validate_generic_safe_string FAC_SAVE_NAME 0
    # Ask for the server name visible in the server browser (if the server is public).
    # Default: "My Factorio Server". Stored in FAC_SERVER_NAME.
    prompt_and_validate "Server name (visible in server browser, if public)" "My Factorio Server" validate_generic_safe_string FAC_SERVER_NAME 0
    # Ask for the maximum number of players — 0 means unlimited (up to 255).
    prompt_and_validate "Max players (0 = unlimited)" "0" validate_fac_max_players FAC_MAX_PLAYERS 0

    # Three-way password logic (same pattern across all profiles):
    if [[ -n "${FAC_EXISTING_PASSWORD:-}" ]]; then
        prompt_and_validate "Server password (blank keeps current)" "$FAC_EXISTING_PASSWORD" validate_generic_safe_string FAC_PASSWORD 0
    elif [[ "$ASSUME_DEFAULTS" -eq 1 ]]; then
        FAC_PASSWORD=""
        log_warn "Non-interactive mode: leaving the join password blank (open server)."
    else
        prompt_and_validate "Server password (blank = no password)" "" validate_generic_safe_string FAC_PASSWORD 0
    fi

    # Save all variable names to the instance config for persistence.
    PROFILE_EXTRA_CONFIG_VARS=(FAC_SAVE_NAME FAC_SERVER_NAME FAC_MAX_PLAYERS FAC_PASSWORD)
}

# validate_fac_max_players: checks that the user's input is a valid player count.
# Whole number, 0 (unlimited) up to 255.
validate_fac_max_players() {
    # Store the first argument (user's input) in a local variable.
    local v="$1"
    # Check that input contains only digits AND is 255 or less.
    # 0 is allowed (means unlimited). "||" at end means show error if either check fails.
    [[ "$v" =~ ^[0-9]+$ ]] && (( v <= 255 )) || { echo "Must be a whole number (0 = unlimited, up to 255)."; return 1; }
    # Return 0 to signal success.
    return 0
}

# profile_build_launch_args: writes server-settings.json into the
# instance's data directory, creates the save file on first run if it
# doesn't already exist (--create), and always launches with --start-server.
profile_build_launch_args() {
    # Create the data directory if it doesn't exist yet.
    mkdir -p "$INSTANCE_DATA_DIR"
    # Build the full path to the settings file inside the data directory.
    local settings_path="${INSTANCE_DATA_DIR}/server-settings.json"
    # Build the full path to the save file — the filename is the user-chosen name + .zip.
    local save_path="${INSTANCE_DATA_DIR}/${FAC_SAVE_NAME}.zip"

    # Write Factorio's server settings file using a heredoc (JSON format).
    # These settings control the server name, player limits, passwords, and behavior.
    cat > "$settings_path" << CFG
{
  "name": "${FAC_SERVER_NAME}",
  "description": "",
  "tags": [],
  "max_players": ${FAC_MAX_PLAYERS},
  "visibility": {"public": false, "lan": true},
  "password": "${FAC_PASSWORD}",
  "game_password": "${FAC_PASSWORD}",
  "require_user_verification": true,
  "max_upload_in_kilobytes_per_second": 0,
  "minimum_latency_in_ticks": 0,
  "ignore_player_limit_for_returning_players": true,
  "allow_commands": "admins-only",
  "autosave_interval": 10,
  "autosave_slots": 5,
  "afk_autokick_interval": 0,
  "auto_pause": false
}
CFG

    # "-f" checks if a file exists — only create a new map if there's no save yet.
    if [[ ! -f "$save_path" ]]; then
        log_info "[$INSTANCE_NAME] No existing save found; creating a new map '${FAC_SAVE_NAME}'..."
        # "$binary --create" tells Factorio to generate a new map and save it.
        # Output goes to a log file. "|| true" prevents the script from stopping
        # if the map creation fails (it's not fatal).
        "$binary" --create "$save_path" >> "${INSTANCE_LOG_DIR}/factorio-create.log" 2>&1 || true
    fi

    # LAUNCH_ARGS: the arguments passed to the Factorio binary at startup.
    # "--start-server <save>" loads the given save file and starts the server.
    # "--server-settings <file>" points to the JSON settings file we wrote above.
    # "--port <number>" sets the network port for player connections.
    LAUNCH_ARGS=(--start-server "$save_path" --server-settings "$settings_path" --port "$SERVER_PORT")
}

# profile_post_start_notes: prints helpful tips after the server is set up.
profile_post_start_notes() {
    echo -e "${C_BOLD}Note:${C_RESET} The map is created automatically on first start if it doesn't"
    echo "already exist, using Factorio's own default map generation settings. To use custom"
    echo "map generation, place a map-gen-settings.json in this instance's data directory"
    echo "before first start and add --map-gen-settings to the launch args yourself."
}

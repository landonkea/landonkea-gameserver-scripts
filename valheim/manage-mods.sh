#!/usr/bin/env bash
###############################################################################
# manage-mods.sh -- Thunderstore mod manager for Valheim shards created by
# install-valheim-server.sh.
#
# install-valheim-server.sh already installs BepInEx + MaxPlayerCount
# automatically, but only as a means to raise the player cap above 10 --
# it never touches the rest of Thunderstore's mod catalog. This script
# covers everything else: searching Thunderstore, installing/removing any
# mod by <namespace>/<name>, and listing what's installed on a shard. It
# installs BepInEx itself first if a shard doesn't have it yet (e.g. a
# vanilla, max-players-10 shard that never triggered the installer's own
# BepInEx path).
#
# USAGE:
#   ./manage-mods.sh search <query>
#   ./manage-mods.sh install <namespace/name> <instance> [version]
#   ./manage-mods.sh list <instance>
#   ./manage-mods.sh remove <namespace/name> <instance>
#   ./manage-mods.sh list-instances
#   ./manage-mods.sh --help
#
# 'search' is read-only (Thunderstore API only) and never needs root.
# install/list/remove touch /srv/valheim (owned by the 'valheim' system
# user) and auto-elevate with sudo, same as every other script here.
#
# VALHEIM_BASE can be overridden in the environment (e.g. for testing
# against a throwaway sandbox directory instead of the real /srv/valheim)
# -- every path below is derived from it. Production use never needs to
# set this; it defaults to /srv/valheim like every other Valheim script.
###############################################################################

if [ -z "${BASH_VERSION:-}" ]; then
    echo "ERROR: This script must be run with bash, e.g.: sudo bash manage-mods.sh ..." >&2
    exit 1
fi

set -Eeuo pipefail
IFS=$'\n\t'

# --- Load shared library with common functions ---
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BASE_DIR
source "${BASE_DIR}/../lib/common.sh" "${BASE_DIR}"

###############################################################################
# GLOBAL CONSTANTS
###############################################################################
readonly SCRIPT_VERSION="1.0.0"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
LOG_FILE="/var/log/valheim-mods.log"   # not readonly -- init_logging may adjust it

: "${VALHEIM_BASE:=/srv/valheim}"
readonly VALHEIM_BASE
readonly VALHEIM_USER="valheim"
readonly VALHEIM_GROUP="valheim"
readonly INSTANCES_DIR="${VALHEIM_BASE}/instances"
readonly INSTANCE_REGISTRY="${VALHEIM_BASE}/instances.registry"
readonly BASE_TMP_DIR="${VALHEIM_BASE}/tmp"

readonly THUNDERSTORE_PACKAGE_API="https://thunderstore.io/api/experimental/package"
# The community-scoped v1 listing is the only endpoint that returns every
# Valheim package (with description + download stats) in one response, so
# it's what powers 'search'. It's a large (~150MB+) JSON array, so it's
# cached on disk and only re-downloaded once the cache is older than
# MOD_LIST_CACHE_TTL_SECONDS -- not on every search.
readonly THUNDERSTORE_COMMUNITY_LIST_URL="https://thunderstore.io/c/valheim/api/v1/package/"
readonly MOD_LIST_CACHE_FILE="${BASE_TMP_DIR}/thunderstore-valheim-packages.json"
readonly MOD_LIST_CACHE_TTL_SECONDS=86400
readonly BEPINEX_NAMESPACE="denikson"
readonly BEPINEX_NAME="BepInExPack_Valheim"
readonly SEARCH_RESULT_LIMIT=20

###############################################################################
# ERROR HANDLING / TRAPS
###############################################################################
on_error() {
    local line="$1" cmd="$2" rc="$3"
    log_err "Unexpected failure at line ${line} (exit code ${rc}): ${cmd}"
    log_err "Nothing further will be changed. Full log: ${LOG_FILE}"
    exit "$rc"
}
trap 'on_error "$LINENO" "$BASH_COMMAND" "$?"' ERR
trap 'echo; log_warn "Interrupted by user (Ctrl+C)."; exit 130' INT TERM

###############################################################################
# INSTANCE HELPERS
# instances are created by install-valheim-server.sh; this script never
# creates or removes one, only reads/writes into an existing shard's
# server directory.
###############################################################################

# list_instance_names: prints every registered instance name, one per line.
list_instance_names() {
    [[ -f "$INSTANCE_REGISTRY" ]] || return 0
    awk -F: '{print $1}' "$INSTANCE_REGISTRY" 2>/dev/null
}

# known_instances_hint: prints an indented "  name" line per known
# instance, for embedding in error messages -- pulled out into its own
# function so callers never need an unquoted, word-splitting command
# substitution inline.
known_instances_hint() {
    local names
    names="$(list_instance_names)"
    [[ -n "$names" ]] && sed 's/^/  /' <<< "$names" || echo "  (none configured yet)"
}

# require_instance: validates instance name $1 exists and populates the
# global path variables every other function needs. Dies with a helpful
# "known instances" list on any mismatch, exactly like the installer's own
# generated scripts do.
require_instance() {
    local name="$1"
    if [[ -z "$name" ]]; then
        die "An instance name is required. Known instances:
$(known_instances_hint)"
    fi
    INSTANCE_NAME="$name"
    INSTANCE_DIR="${INSTANCES_DIR}/${name}"
    INSTANCE_SERVER_DIR="${INSTANCE_DIR}/server"
    INSTANCE_TMP_DIR="${INSTANCE_DIR}/tmp"
    PLUGINS_DIR="${INSTANCE_SERVER_DIR}/BepInEx/plugins"
    MODS_REGISTRY="${INSTANCE_DIR}/mods.registry"
    if [[ ! -d "$INSTANCE_SERVER_DIR" ]]; then
        die "No instance named '${name}' (looked for ${INSTANCE_SERVER_DIR}). Known instances:
$(known_instances_hint)"
    fi
}

###############################################################################
# THUNDERSTORE API
###############################################################################

# fetch_thunderstore_download_url: prints the download URL for a package's
# latest version (or a specific $3 version, if given) and returns 1 on any
# failure (network, missing package, unexpected response shape). The
# experimental per-package endpoint only ever exposes the LATEST version's
# metadata directly; for an older version we fall back to Thunderstore's
# own well-known, stable download URL pattern instead (verified against
# the real API -- see README.md).
fetch_thunderstore_download_url() {
    local namespace="$1" name="$2" version="${3:-}"
    if [[ -n "$version" ]]; then
        echo "https://thunderstore.io/package/download/${namespace}/${name}/${version}/"
        return 0
    fi
    local json url
    json="$(curl -fsS --max-time 20 "${THUNDERSTORE_PACKAGE_API}/${namespace}/${name}/" 2>>"$LOG_FILE")" || return 1
    url="$(printf '%s' "$json" | jq -r '.latest.download_url // empty' 2>>"$LOG_FILE")"
    [[ -n "$url" && "$url" != "null" ]] || return 1
    echo "$url"
}

# fetch_thunderstore_latest_version: prints the latest version_number for
# a package (used to record what actually got installed when the caller
# didn't pin a version). Returns 1 on any failure.
fetch_thunderstore_latest_version() {
    local namespace="$1" name="$2" json v
    json="$(curl -fsS --max-time 20 "${THUNDERSTORE_PACKAGE_API}/${namespace}/${name}/" 2>>"$LOG_FILE")" || return 1
    v="$(printf '%s' "$json" | jq -r '.latest.version_number // empty' 2>>"$LOG_FILE")"
    [[ -n "$v" && "$v" != "null" ]] || return 1
    echo "$v"
}

# refresh_mod_list_cache: (re)downloads the full Valheim package listing if
# the cache is missing or older than MOD_LIST_CACHE_TTL_SECONDS. This file
# is large (100MB+), so it's deliberately not fetched on every search.
refresh_mod_list_cache() {
    mkdir -p "$BASE_TMP_DIR"
    local age=999999999
    if [[ -f "$MOD_LIST_CACHE_FILE" ]]; then
        local mtime now
        mtime="$(stat -c %Y "$MOD_LIST_CACHE_FILE" 2>/dev/null || stat -f %m "$MOD_LIST_CACHE_FILE" 2>/dev/null || echo 0)"
        now="$(date +%s)"
        age=$(( now - mtime ))
    fi
    if [[ ! -s "$MOD_LIST_CACHE_FILE" || "$age" -gt "$MOD_LIST_CACHE_TTL_SECONDS" ]]; then
        log_info "Downloading the Valheim mod catalog from Thunderstore (first run, or cache older than $((MOD_LIST_CACHE_TTL_SECONDS / 3600))h)..."
        local tmp_file="${MOD_LIST_CACHE_FILE}.tmp.$$"
        if curl -fsS --max-time 120 "$THUNDERSTORE_COMMUNITY_LIST_URL" -o "$tmp_file" 2>>"$LOG_FILE" \
           && jq -e 'type == "array"' "$tmp_file" >/dev/null 2>&1; then
            mv -f "$tmp_file" "$MOD_LIST_CACHE_FILE"
            log_ok "Mod catalog cached at ${MOD_LIST_CACHE_FILE} ($(jq 'length' "$MOD_LIST_CACHE_FILE") packages)."
        else
            rm -f "$tmp_file"
            if [[ -s "$MOD_LIST_CACHE_FILE" ]]; then
                log_warn "Could not refresh the mod catalog (network issue?); using the existing (possibly stale) cache."
            else
                die "Could not download the Thunderstore mod catalog and no cache exists. Check your internet connection."
            fi
        fi
    fi
}

###############################################################################
# SEARCH
###############################################################################

# cmd_search: case-insensitive substring search across every Valheim
# package's name and description, ranked by download count, top
# SEARCH_RESULT_LIMIT shown.
cmd_search() {
    local query="$1"
    [[ -n "$query" ]] || die "Usage: ${SCRIPT_NAME} search <query>"
    refresh_mod_list_cache
    log_step "Thunderstore search: \"${query}\""
    local results
    results="$(jq -r --arg q "${query,,}" --argjson limit "$SEARCH_RESULT_LIMIT" '
        [ .[] | select(.is_deprecated | not)
          | select( (.name // "" | ascii_downcase | contains($q))
                 or ((.versions[0].description // "") | ascii_downcase | contains($q)) )
          | { full_name: ("\(.owner)/\(.name)"),
              version: (.versions[0].version_number // "?"),
              downloads: ([.versions[].downloads] | add // 0),
              description: (.versions[0].description // "") } ]
        | sort_by(-.downloads) | .[:$limit]
        | .[] | "\(.full_name)\t\(.version)\t\(.downloads)\t\(.description)"
    ' "$MOD_LIST_CACHE_FILE" 2>>"$LOG_FILE")" || die "Search failed while reading the cached catalog. See ${LOG_FILE}."

    if [[ -z "$results" ]]; then
        log_warn "No matches for \"${query}\"."
        return 0
    fi
    printf '%-40s %-12s %-10s %s\n' "NAMESPACE/NAME" "VERSION" "DOWNLOADS" "DESCRIPTION"
    while IFS=$'\t' read -r full_name version downloads description; do
        printf '%-40s %-12s %-10s %s\n' "$full_name" "$version" "$downloads" "${description:0:70}"
    done <<< "$results"
    echo
    log_info "Install one with: ./${SCRIPT_NAME} install <namespace/name> <instance>"
}

###############################################################################
# BEPINEX (prerequisite mod loader)
###############################################################################

# bepinex_installed: true if this instance's server dir already has a
# working BepInEx tree.
bepinex_installed() {
    [[ -d "${INSTANCE_SERVER_DIR}/BepInEx/core" ]]
}

# ensure_bepinex: installs BepInEx into this instance's server directory if
# it isn't already present. Every mod on Thunderstore for Valheim depends
# on this being in place first -- it's the actual mod loader; individual
# mods are just DLLs BepInEx discovers and loads at startup.
ensure_bepinex() {
    if bepinex_installed; then
        log_ok "[${INSTANCE_NAME}] BepInEx is already installed."
        return 0
    fi

    log_step "[${INSTANCE_NAME}] BepInEx not found -- installing it first (required by every Thunderstore Valheim mod)"
    local url
    url="$(fetch_thunderstore_download_url "$BEPINEX_NAMESPACE" "$BEPINEX_NAME")" \
        || die "Could not look up BepInEx's download URL on Thunderstore (network issue, or the API changed)."

    local work="${INSTANCE_TMP_DIR}/bepinex-install-$$"
    mkdir -p "$work"
    curl -fsSL --max-time 120 "$url" -o "${work}/bepinex.zip" 2>>"$LOG_FILE" \
        || { rm -rf "$work"; die "BepInEx download failed."; }
    unzip -oq "${work}/bepinex.zip" -d "${work}/extracted" 2>>"$LOG_FILE" \
        || { rm -rf "$work"; die "BepInEx archive could not be extracted."; }

    # Thunderstore packages wrap the real payload in an icon.png/manifest.json/
    # README shell around one inner folder; copy that folder's CONTENTS
    # (not the folder itself) into the server directory.
    local payload_dir
    payload_dir="$(find "${work}/extracted" -maxdepth 1 -mindepth 1 -type d | head -n1)"
    [[ -n "$payload_dir" ]] || payload_dir="${work}/extracted"
    mkdir -p "$INSTANCE_SERVER_DIR"
    cp -a "${payload_dir}/." "${INSTANCE_SERVER_DIR}/" 2>>"$LOG_FILE" \
        || { rm -rf "$work"; die "Could not copy BepInEx files into ${INSTANCE_SERVER_DIR}."; }
    rm -rf "$work"

    if ! bepinex_installed; then
        die "BepInEx was downloaded but no BepInEx/core/ folder appeared after extraction -- the package layout may have changed."
    fi
    if [[ "${EUID}" -eq 0 ]] && id -u "$VALHEIM_USER" >/dev/null 2>&1; then
        chown -R "$VALHEIM_USER:$VALHEIM_GROUP" "$INSTANCE_SERVER_DIR"
    fi
    log_ok "[${INSTANCE_NAME}] BepInEx installed."
}

###############################################################################
# MOD REGISTRY (per-instance record of what this script installed, so
# 'list' and 'remove' don't have to guess at directory layouts)
###############################################################################

# mods_registry_add: appends "namespace:name:version:plugin_dir:installed_at".
mods_registry_add() {
    local namespace="$1" name="$2" version="$3" plugin_dir="$4"
    mods_registry_remove_silent "$namespace" "$name"
    echo "${namespace}:${name}:${version}:${plugin_dir}:$(date '+%Y-%m-%d_%H-%M-%S')" >> "$MODS_REGISTRY"
}

# mods_registry_remove_silent: deletes any existing line for this mod
# (used before re-adding, so re-installing/upgrading never leaves a stale
# duplicate entry behind).
mods_registry_remove_silent() {
    local namespace="$1" name="$2"
    [[ -f "$MODS_REGISTRY" ]] || return 0
    sed -i.bak "/^${namespace}:${name}:/d" "$MODS_REGISTRY" 2>/dev/null && rm -f "${MODS_REGISTRY}.bak"
}

# mods_registry_find: prints the registry line for namespace/name, if any.
mods_registry_find() {
    local namespace="$1" name="$2"
    [[ -f "$MODS_REGISTRY" ]] || return 1
    awk -F: -v ns="$namespace" -v n="$name" '$1==ns && $2==n {print; found=1} END{exit !found}' "$MODS_REGISTRY"
}

###############################################################################
# INSTALL / LIST / REMOVE
###############################################################################

# split_namespace_name: splits "namespace/name" (argument $1) into the
# globals NS and MOD, or dies with a clear usage error if the format is
# wrong -- every command below that takes a mod identifier calls this
# first so the error message is consistent everywhere.
split_namespace_name() {
    local id="$1"
    if [[ "$id" != */* ]]; then
        die "Mod must be given as <namespace/name>, e.g. Azumatt/Where_You_At (got: '${id}')."
    fi
    NS="${id%%/*}"
    MOD="${id#*/}"
    [[ -n "$NS" && -n "$MOD" ]] || die "Mod must be given as <namespace/name>, e.g. Azumatt/Where_You_At (got: '${id}')."
}

# cmd_install: ensures BepInEx is present, downloads the requested mod
# (latest, or a pinned version), extracts it into its own subfolder under
# BepInEx/plugins/, verifies at least one .dll actually landed (proof
# BepInEx has something to load), and records the install in this
# instance's mods.registry.
cmd_install() {
    local mod_id="$1" instance="$2" version="${3:-}"
    [[ -n "$mod_id" && -n "$instance" ]] || die "Usage: ${SCRIPT_NAME} install <namespace/name> <instance> [version]"
    split_namespace_name "$mod_id"
    require_instance "$instance"
    ensure_bepinex

    log_step "[${INSTANCE_NAME}] Installing ${NS}/${MOD}${version:+ (version ${version})}"
    local url
    url="$(fetch_thunderstore_download_url "$NS" "$MOD" "$version")" \
        || die "Could not look up ${NS}/${MOD} on Thunderstore (check the name -- it's case-sensitive)."

    local resolved_version="$version"
    if [[ -z "$resolved_version" ]]; then
        resolved_version="$(fetch_thunderstore_latest_version "$NS" "$MOD" || echo "unknown")"
    fi

    local work="${INSTANCE_TMP_DIR}/mod-install-${NS}-${MOD}-$$"
    mkdir -p "$work"
    if ! curl -fsSL --max-time 120 "$url" -o "${work}/mod.zip" 2>>"$LOG_FILE"; then
        rm -rf "$work"
        die "Download failed for ${NS}/${MOD} (URL: ${url}). Check the mod name/version and try again."
    fi
    if ! unzip -oq "${work}/mod.zip" -d "${work}/extracted" 2>>"$LOG_FILE"; then
        rm -rf "$work"
        die "${NS}/${MOD}'s archive could not be extracted -- it may not be a valid ZIP."
    fi

    # Drop Thunderstore's own packaging cruft (icon/manifest/readme at the
    # TOP level only -- a mod that legitimately ships a README.md deep
    # inside a subfolder is left untouched) so it doesn't clutter the
    # plugin's own directory once installed.
    find "${work}/extracted" -maxdepth 1 -type f \
        \( -iname 'icon.png' -o -iname 'manifest.json' -o -iname 'README.md' -o -iname 'CHANGELOG.md' \) \
        -delete 2>>"$LOG_FILE" || true

    local plugin_dir="${PLUGINS_DIR}/${NS}-${MOD}"
    mkdir -p "$PLUGINS_DIR"
    rm -rf "$plugin_dir"
    mkdir -p "$plugin_dir"
    cp -a "${work}/extracted/." "${plugin_dir}/" 2>>"$LOG_FILE" \
        || { rm -rf "$work"; die "Could not copy ${NS}/${MOD}'s files into ${plugin_dir}."; }
    rm -rf "$work"

    local dll_count
    dll_count="$(find "$plugin_dir" -iname '*.dll' 2>/dev/null | wc -l | tr -d '[:space:]')"
    if [[ "$dll_count" -eq 0 ]]; then
        log_warn "[${INSTANCE_NAME}] ${NS}/${MOD} installed to ${plugin_dir}, but no .dll was found inside it."
        log_warn "This may be a translation/config/asset-only pack rather than an actual BepInEx plugin -- verify it's the right package."
    else
        log_ok "[${INSTANCE_NAME}] ${NS}/${MOD} installed: ${dll_count} DLL(s) in ${plugin_dir}"
    fi

    if [[ "${EUID}" -eq 0 ]] && id -u "$VALHEIM_USER" >/dev/null 2>&1; then
        chown -R "$VALHEIM_USER:$VALHEIM_GROUP" "$plugin_dir"
    fi

    mods_registry_add "$NS" "$MOD" "$resolved_version" "$plugin_dir"
    log_ok "[${INSTANCE_NAME}] Recorded in ${MODS_REGISTRY} (version ${resolved_version})."
    log_warn "[${INSTANCE_NAME}] Restart this shard for the mod to take effect: sudo ${INSTANCES_DIR%/instances}/scripts/restart-valheim.sh ${INSTANCE_NAME}"
}

# cmd_list: prints every mod this script has installed for an instance,
# per mods.registry -- flags any entry whose plugin_dir no longer exists
# on disk (e.g. deleted by hand) instead of silently claiming it's fine.
cmd_list() {
    local instance="$1"
    [[ -n "$instance" ]] || die "Usage: ${SCRIPT_NAME} list <instance>"
    require_instance "$instance"

    log_step "Installed mods for '${INSTANCE_NAME}'"
    if ! bepinex_installed; then
        log_info "BepInEx is not installed on this shard yet -- no mods can be loaded. Run 'install' to add one (installs BepInEx automatically)."
        return 0
    fi
    if [[ ! -s "$MODS_REGISTRY" ]]; then
        log_info "No mods installed via ${SCRIPT_NAME} on this shard."
        return 0
    fi
    printf '%-25s %-30s %-12s %-10s %s\n' "NAMESPACE" "NAME" "VERSION" "STATUS" "INSTALLED"
    while IFS=: read -r namespace name version plugin_dir installed_at; do
        [[ -n "$namespace" ]] || continue
        local status="ok"
        [[ -d "$plugin_dir" ]] || status="MISSING"
        printf '%-25s %-30s %-12s %-10s %s\n' "$namespace" "$name" "$version" "$status" "$installed_at"
    done < "$MODS_REGISTRY"
}

# cmd_remove: deletes a previously-installed mod's plugin directory and
# its registry entry. Verifies the directory is actually gone afterward
# rather than assuming rm succeeded.
cmd_remove() {
    local mod_id="$1" instance="$2"
    [[ -n "$mod_id" && -n "$instance" ]] || die "Usage: ${SCRIPT_NAME} remove <namespace/name> <instance>"
    split_namespace_name "$mod_id"
    require_instance "$instance"

    local line plugin_dir
    line="$(mods_registry_find "$NS" "$MOD")" || {
        log_warn "[${INSTANCE_NAME}] ${NS}/${MOD} is not recorded as installed by ${SCRIPT_NAME}."
        plugin_dir="${PLUGINS_DIR}/${NS}-${MOD}"
        if [[ -d "$plugin_dir" ]]; then
            log_info "A matching directory does exist at ${plugin_dir}; removing it anyway."
        else
            die "Nothing to remove: ${plugin_dir} does not exist either."
        fi
    }
    [[ -n "${line:-}" ]] && plugin_dir="$(awk -F: '{print $4}' <<< "$line")"

    log_step "[${INSTANCE_NAME}] Removing ${NS}/${MOD}"
    rm -rf -- "$plugin_dir"
    if [[ -d "$plugin_dir" ]]; then
        die "Removal failed: ${plugin_dir} still exists."
    fi
    mods_registry_remove_silent "$NS" "$MOD"
    log_ok "[${INSTANCE_NAME}] Removed ${NS}/${MOD} (was: ${plugin_dir})."
    log_warn "[${INSTANCE_NAME}] Restart this shard for the removal to take effect."
}

cmd_list_instances() {
    log_step "Configured Valheim instances (${VALHEIM_BASE})"
    local names
    names="$(list_instance_names)"
    if [[ -z "$names" ]]; then
        log_info "No instances found. Run install-valheim-server.sh first."
        return 0
    fi
    echo "$names"
}

###############################################################################
# CLI PARSING + MAIN
###############################################################################
print_usage() {
    cat << EOF
Usage: ./${SCRIPT_NAME} <command> [args]

Commands:
  search <query>                      Search Thunderstore's Valheim mods.
  install <namespace/name> <instance> [version]
                                       Install a mod (installs BepInEx first
                                       if this shard doesn't have it yet).
  list <instance>                     List mods installed on a shard.
  remove <namespace/name> <instance>  Remove a previously installed mod.
  list-instances                      List every configured shard.
  -h, --help                          Show this help message and exit.
  --version                           Show this script's version and exit.

Examples:
  ./${SCRIPT_NAME} search "portal"
  ./${SCRIPT_NAME} install Azumatt/Where_You_At main
  ./${SCRIPT_NAME} install Azumatt/Where_You_At main 1.0.10
  ./${SCRIPT_NAME} list main
  ./${SCRIPT_NAME} remove Azumatt/Where_You_At main

Mods are always given as <namespace/name> (case-sensitive), exactly as
shown by 'search' or on the mod's Thunderstore page URL.
EOF
}

main() {
    # Captured BEFORE shifting the subcommand off -- require_root re-execs
    # via `exec sudo -E bash "$0" "$@"`, so it needs the FULL original
    # argument list (including the subcommand itself), not just what's
    # left after this function has already consumed "install"/"list"/etc.
    local all_args=("$@")
    local cmd="${1:-}"
    [[ -n "$cmd" ]] && shift || true

    case "$cmd" in
        -h|--help|"") print_usage; exit 0 ;;
        --version) echo "${SCRIPT_NAME} v${SCRIPT_VERSION}"; exit 0 ;;
        search)
            init_logging "$LOG_FILE" "manage-mods.sh v${SCRIPT_VERSION}"
            cmd_search "${1:-}"
            ;;
        list-instances)
            init_logging "$LOG_FILE" "manage-mods.sh v${SCRIPT_VERSION}"
            cmd_list_instances
            ;;
        install)
            require_root "${all_args[@]}"
            init_logging "$LOG_FILE" "manage-mods.sh v${SCRIPT_VERSION}"
            cmd_install "${1:-}" "${2:-}" "${3:-}"
            ;;
        list)
            require_root "${all_args[@]}"
            init_logging "$LOG_FILE" "manage-mods.sh v${SCRIPT_VERSION}"
            cmd_list "${1:-}"
            ;;
        remove)
            require_root "${all_args[@]}"
            init_logging "$LOG_FILE" "manage-mods.sh v${SCRIPT_VERSION}"
            cmd_remove "${1:-}" "${2:-}"
            ;;
        *)
            echo "Unknown command: ${cmd}" >&2
            print_usage
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

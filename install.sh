#!/usr/bin/env bash
###############################################################################
# install.sh -- single entry point for every game in this repository
#
# This is the ONE script to run, regardless of which game you want. It
# doesn't do any installing itself -- it just figures out whether you want
# Valheim (which has its own dedicated, most heavily-tested installer) or
# one of the multi-game platform's games, and hands off to the right
# script with your exact arguments passed through untouched.
#
# USAGE (identical to running either script directly, just from one place):
#   ./install.sh --game valheim --add-instance myworld
#   ./install.sh --game terraria --add-instance myworld
#   ./install.sh --list-games
#   ./install.sh --list-instances
#   ./install.sh --help
#
# WHY THIS EXISTS: without this file, using this repository means knowing
# in advance "Valheim is its own separate script over in valheim/, but
# every other game is a different script over in multi-game-platform/" --
# a real thing to have to remember correctly. This file removes that
# decision: run this one script, tell it which game, and it takes care of
# routing to the right place itself.
###############################################################################

if [ -z "${BASH_VERSION:-}" ]; then
    echo "ERROR: This script must be run with bash, e.g.: sudo bash install.sh" >&2
    exit 1
fi

set -Eeuo pipefail

# SCRIPT_DIR figures out the exact folder this file itself is sitting in,
# no matter what folder you happened to be standing in when you ran it --
# this is what lets "./install.sh" work correctly whether you're inside
# this repository's folder already, or ran it via a full/relative path
# from somewhere else entirely.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VALHEIM_SCRIPT="${SCRIPT_DIR}/valheim/install-valheim-server.sh"
PLATFORM_SCRIPT="${SCRIPT_DIR}/multi-game-platform/install-game-server.sh"

# Same conditional-on-a-real-terminal color setup used by both underlying
# scripts, so --all's output (below) is styled consistently with them
# rather than silently rendering as plain, unstyled text.
if [[ -t 1 ]]; then
    C_BOLD='\033[1m'
    C_RESET='\033[0m'
else
    C_BOLD=''
    C_RESET=''
fi

print_usage() {
    cat << EOF
Usage: ./install.sh [OPTIONS]

This is a single entry point that automatically routes to the right
installer based on which game you name -- you never need to know or
remember which underlying script handles which game.

  --game valheim ...           Routes to the dedicated Valheim installer
                                (supports everything install-valheim-server.sh
                                supports: multi-shard, BepInEx modding, etc.)
  --game <any other game> ...  Routes to the multi-game platform
  --all                        Install EVERY game (Valheim + all platform
                                games) as one instance each, fully automated.
                                Every instance (Valheim included) sleeps
                                until a player connects (on-demand mode).
                                Asks to confirm first unless -y is also
                                given. Safe to re-run: skips any game
                                already installed.
  --list-games                 Show every game available across BOTH systems
  --list-instances              Show every running instance across BOTH systems
  --uninstall-valheim           Fully remove the Valheim installation
  --uninstall-platform          Fully remove the multi-game platform installation
  -h, --help                    Show this help message

Every other option is passed through unchanged to whichever underlying
script handles the game you named -- see that script's own --help for the
full list (they're very similar: --add-instance, --remove-instance,
-y/--yes, and so on).
EOF
}

# instance_already_exists: checks each system's own on-disk registry file
# directly for an existing instance with this exact name -- used by
# install_all_games (below) so re-running --all skips anything already
# installed instead of erroring out on it. Read-only, and falls back to
# "assume it doesn't exist yet" if the registry can't be read for any
# reason (missing file, permissions) -- in that case, the underlying
# install itself is still the final, authoritative check.
instance_already_exists() {
    local system="$1" name="$2" registry_file=""
    if [[ "$system" == "valheim" ]]; then
        registry_file="/srv/valheim/instances.registry"
    else
        registry_file="/srv/gameservers/instances.registry"
    fi
    [[ -r "$registry_file" ]] && grep -q "^${name}:" "$registry_file" 2>/dev/null
}

# install_all_games: installs every game (Valheim, plus every profile the
# multi-game platform currently bundles) as one on-demand instance each,
# fully automated -- this is purely an ORCHESTRATION loop over the exact
# same, already-tested "--add-instance <name> -y" entry points a person
# would otherwise run one at a time by hand. Neither underlying script is
# modified by this at all. Continues past any single game's failure
# (logging it clearly) rather than aborting the whole batch, and skips
# anything already installed so it's safe to re-run.
install_all_games() {
    echo -e "${C_BOLD:-}Discovering every available game...${C_RESET:-}"

    # Ask the platform script for its current list of profiles, the same
    # way --list-games does -- this stays correct automatically as more
    # profiles are added later, rather than this file needing its own
    # hardcoded, easily-stale copy of that list. The filter keeps only
    # lines that look like a clean, single-word game id, which discards
    # the one informational line the platform script mixes into this same
    # output before it's been installed yet ("Base platform not installed
    # yet; listing bundled profiles from this script instead.").
    local platform_games=()
    local line first_word
    while IFS= read -r line; do
        # Extract just the first whitespace-separated word of this line
        # before filtering -- necessary because --list-games' own output
        # format differs depending on whether the platform has been
        # installed yet: a clean single word per line beforehand, but a
        # padded "id   Display Name" format afterward. Taking just the
        # first word handles both correctly, and also naturally discards
        # header/info lines ("Available game profiles:", "[INFO] ...")
        # since their first word never matches the game-id pattern below.
        first_word="$(awk '{print $1}' <<< "$line")"
        if [[ "$first_word" =~ ^[a-z][a-z0-9]*$ ]]; then
            platform_games+=("$first_word")
        fi
    done < <(bash "$PLATFORM_SCRIPT" --list-games 2>/dev/null)

    if [[ "${#platform_games[@]}" -eq 0 ]]; then
        echo "Could not determine the list of available platform games -- aborting." >&2
        exit 1
    fi

    local all_games=("valheim" "${platform_games[@]}")

    echo
    echo "This installs ${#all_games[@]} games total, one instance each:"
    printf '  %s\n' "${all_games[@]}"
    echo
    echo "Running all of these simultaneously, at full tilt, would need far more RAM"
    echo "than almost any real server has -- some of these alone recommend 24GB+."
    echo "Every instance (Valheim included) is created with on-demand mode ON by default:"
    echo "each sleeps (using next-to-no resources) until a player actually tries to connect"
    echo "to it specifically, which is what makes installing all of them at once realistic."
    echo "Already-installed games are skipped automatically, so this is safe to re-run."
    echo

    local skip_confirm=0
    for arg in "$@"; do
        [[ "$arg" == "-y" || "$arg" == "--yes" ]] && skip_confirm=1
    done
    if [[ "$skip_confirm" -ne 1 ]]; then
        local confirm=""
        read -r -p "Continue installing all ${#all_games[@]} games? [y/N]: " confirm
        if [[ ! "${confirm,,}" =~ ^y ]]; then
            echo "Cancelled. Nothing was changed."
            exit 0
        fi
    fi

    local succeeded=() failed=() skipped=()
    for game in "${all_games[@]}"; do
        echo
        echo -e "${C_BOLD:-}=== ${game} ===${C_RESET:-}"

        local system="platform"
        [[ "$game" == "valheim" ]] && system="valheim"

        if instance_already_exists "$system" "$game"; then
            echo "Already installed -- skipping."
            skipped+=("$game")
            continue
        fi

        local rc=0
        if [[ "$game" == "valheim" ]]; then
            bash "$VALHEIM_SCRIPT" --add-instance "$game" -y || rc=$?
        else
            bash "$PLATFORM_SCRIPT" --game "$game" --add-instance "$game" -y || rc=$?
        fi

        if [[ "$rc" -eq 0 ]]; then
            succeeded+=("$game")
        else
            echo "FAILED (exit ${rc}) -- continuing with the rest." >&2
            failed+=("$game")
        fi
    done

    echo
    echo -e "${C_BOLD:-}=== Summary ===${C_RESET:-}"
    echo "Installed:        ${#succeeded[@]}  (${succeeded[*]:-none})"
    echo "Already existed:  ${#skipped[@]}  (${skipped[*]:-none})"
    if [[ "${#failed[@]}" -gt 0 ]]; then
        echo "Failed:           ${#failed[@]}  (${failed[*]})"
        echo
        echo "A failure in one game never affects any of the others -- everything listed"
        echo "under \"Installed\" above is up and working. Check that specific game's own"
        echo "log (/var/log/gameserver-install.log or /var/log/valheim-install.log) for why"
        echo "it failed, fix that, then re-run --all (or install just that one game by name)"
        echo "-- everything already installed will be skipped automatically."
    fi
}

# A first-time user's very first question is usually "what can I even
# install?" -- this answers it by asking BOTH underlying systems and
# showing everything in one combined list, since the person running this
# shouldn't need to already know these are two separate tools under the
# hood.
if [[ "${1:-}" == "--list-games" ]]; then
    echo "Valheim:"
    echo "  valheim"
    echo
    echo "Multi-game platform:"
    bash "$PLATFORM_SCRIPT" --list-games 2>/dev/null | sed 's/^/  /' || echo "  (not installed yet -- this list populates after the first install)"
    exit 0
fi

if [[ "${1:-}" == "--list-instances" ]]; then
    echo "=== Valheim instances ==="
    if [[ -x "/srv/valheim/scripts/status-valheim.sh" ]]; then
        sudo /srv/valheim/scripts/status-valheim.sh 2>/dev/null || echo "(none yet, or Valheim not installed)"
    else
        echo "(Valheim not installed yet)"
    fi
    echo
    echo "=== Multi-game platform instances ==="
    bash "$PLATFORM_SCRIPT" --list-instances 2>/dev/null || echo "(none yet, or platform not installed)"
    exit 0
fi

if [[ "${1:-}" == "--uninstall-valheim" ]]; then
    exec bash "$VALHEIM_SCRIPT" --uninstall
fi

if [[ "${1:-}" == "--uninstall-platform" ]]; then
    exec bash "$PLATFORM_SCRIPT" --uninstall
fi

if [[ "${1:-}" == "--all" ]]; then
    install_all_games "$@"
    exit 0
fi

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -eq 0 ]]; then
    print_usage
    exit 0
fi

# This is the actual routing decision: scan through every argument given
# looking specifically for "--game", and read whatever word comes right
# after it.
game=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
    if [[ "${args[$i]}" == "--game" && -n "${args[$((i+1))]:-}" ]]; then
        game="${args[$((i+1))]}"
        break
    fi
done

if [[ -z "$game" ]]; then
    # Special case: "--check" with no --game is a reasonable, common
    # thing to try first -- rather than an unhelpful "specify a game"
    # error, run a general (non-game-specific) environment check via the
    # platform script, since that check works fine without a game named.
    for arg in "${args[@]}"; do
        if [[ "$arg" == "--check" ]]; then
            exec bash "$PLATFORM_SCRIPT" --check
        fi
    done
    echo "Please specify a game, e.g.: ./install.sh --game valheim --add-instance myworld" >&2
    echo "Run ./install.sh --list-games to see everything available." >&2
    exit 1
fi

if [[ "${game,,}" == "valheim" ]]; then
    # Valheim's own script doesn't take a --game flag at all (it only
    # ever does Valheim) -- so that word needs to be removed before
    # handing the rest of the arguments through, otherwise Valheim's
    # script would see "--game valheim" and not understand what to do
    # with it.
    new_args=()
    skip_next=0
    for ((i=0; i<${#args[@]}; i++)); do
        if [[ "$skip_next" -eq 1 ]]; then
            skip_next=0
            continue
        fi
        if [[ "${args[$i]}" == "--game" ]]; then
            skip_next=1
            continue
        fi
        new_args+=("${args[$i]}")
    done
    # "exec" here means this script is replaced entirely by the Valheim
    # installer -- there's no need for this wrapper script to still exist
    # once it's handed off, so this is a clean, simple way to pass
    # through.
    exec bash "$VALHEIM_SCRIPT" "${new_args[@]}"
else
    # Every other game already goes through the multi-game platform's own
    # --game flag exactly as typed, so the full, unmodified argument list
    # is simply passed straight through.
    exec bash "$PLATFORM_SCRIPT" "${args[@]}"
fi

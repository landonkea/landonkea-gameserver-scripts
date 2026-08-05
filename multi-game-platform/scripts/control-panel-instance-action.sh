#!/usr/bin/env bash
###############################################################################
# control-panel-instance-action.sh -- root-only start/stop/restart of ONE
# game-server instance. This is the ONLY thing that ever actually touches
# systemctl on behalf of the web control panel (control-panel.py); the
# Python server never calls systemctl directly.
#
# It is deliberately narrow and paranoid: exactly one of three fixed
# actions, an instance name checked against a strict allow-list regex AND
# checked for registry membership, and no other input accepted from
# anywhere. control-panel.py already validates the action/name shape
# before invoking this script, but this script re-validates everything
# itself and trusts none of that -- it is the last line of defense
# standing directly in front of a privileged systemctl call, so it must
# never assume its caller got things right.
#
# Usage: control-panel-instance-action.sh <start|stop|restart> <instance-name>
#
# Exit codes:
#   0  the requested action succeeded and the unit reached the expected state
#   1  bad usage / unknown action / unknown or invalid instance name
#   2  not running as root
#   3  systemctl ran, but the unit did not reach the expected end state
###############################################################################
set -uo pipefail

GS_BASE="${CONTROL_PANEL_GS_BASE:-/srv/gameservers}"
INSTANCES_DIR="${GS_BASE}/instances"

###############################################################################
# ROOT CHECK
# Starting/stopping a systemd unit is a privileged operation, so this
# script insists on EUID 0 by default -- consistent with the existing
# stop-instance.sh / restart-instance.sh wrappers this platform already
# ships, which enforce the exact same thing.
#
# CONTROL_PANEL_ACTION_ALLOW_NONROOT is a TEST-ONLY escape hatch, in the
# same spirit as GAMESERVER_NOTIFY_DRY_RUN used elsewhere in this repo's
# notify_discord(): it exists purely so tests/control_panel_test.sh can
# exercise this script's real branching logic against a mocked systemctl
# without needing actual root. It must never be set in a production
# deployment -- setup-control-panel.sh never sets it, and the systemd unit
# it installs runs this script as root, so the variable is simply unset
# (and therefore inert) on a real system.
###############################################################################
if [[ "${EUID}" -ne 0 && "${CONTROL_PANEL_ACTION_ALLOW_NONROOT:-0}" != "1" ]]; then
    echo "ERROR: control-panel-instance-action.sh must run as root." >&2
    exit 2
fi

action="${1:-}"
name="${2:-}"

case "$action" in
    start|stop|restart) ;;
    *)
        echo "ERROR: action must be one of: start, stop, restart (got '${action}')." >&2
        exit 1
        ;;
esac

# Strict allow-list on the instance name itself, before it is ever used to
# build a filesystem path or a systemd unit name: letters, digits,
# underscore, hyphen only. No spaces, no slashes, no shell metacharacters.
if [[ ! "$name" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "ERROR: invalid instance name '${name}'." >&2
    exit 1
fi

if [[ ! -f "${INSTANCES_DIR}/${name}/config.env" ]]; then
    echo "ERROR: no instance named '${name}' (looked for ${INSTANCES_DIR}/${name}/config.env)." >&2
    exit 1
fi

# ON_DEMAND is read out of the instance's own config.env with a targeted
# grep rather than sourcing the whole file -- this script has no reason to
# execute config.env as shell code just to read one flag, and not doing so
# keeps this security-sensitive script's own behavior fully self-contained.
on_demand="0"
if grep -q '^ON_DEMAND=1' "${INSTANCES_DIR}/${name}/config.env" 2>/dev/null; then
    on_demand="1"
fi

unit="gameserver@${name}"
sleep_unit="gameserver-sleep@${name}"

# wake_if_sleeping: an on-demand instance's real server unit is inactive
# while it's sleeping -- the sleep-listener unit is what's actually
# running in that state. Starting or restarting such an instance means
# stopping the sleep-listener first so it doesn't immediately re-wake/
# fight over the port; this mirrors the exact same handling
# restart-instance.sh already does for the on-demand case.
wake_if_sleeping() {
    if [[ "$on_demand" == "1" ]] && systemctl is-active --quiet "$sleep_unit" 2>/dev/null; then
        systemctl stop "$sleep_unit" 2>/dev/null || true
    fi
}

case "$action" in
    start)
        wake_if_sleeping
        systemctl start "$unit"
        sleep 1
        ;;
    stop)
        systemctl stop "$unit"
        systemctl stop "$sleep_unit" 2>/dev/null || true
        sleep 1
        ;;
    restart)
        wake_if_sleeping
        systemctl restart "$unit"
        sleep 1
        ;;
esac

state="$(systemctl is-active "$unit" 2>/dev/null || true)"
echo "instance=${name} action=${action} unit_state=${state}"

if [[ "$action" == "stop" ]]; then
    if [[ "$state" != "active" ]]; then
        exit 0
    fi
    echo "ERROR: ${unit} is still active after stop." >&2
    exit 3
else
    if [[ "$state" == "active" ]]; then
        exit 0
    fi
    echo "ERROR: ${unit} did not become active after ${action}." >&2
    exit 3
fi

#!/bin/sh
# docker/factorio/entrypoint.sh -- writes server-settings.json from
# environment variables, creates the save on first run if it doesn't
# already exist, then execs the dedicated server. Runs fresh on every
# container start (same idea as factorio.profile.sh's
# profile_build_launch_args), so changing settings in docker-compose.yml
# and recreating the container is enough -- no rebuild needed.
set -eu

mkdir -p /data

SETTINGS_PATH="/data/server-settings.json"
SAVE_PATH="/data/${SAVE_NAME}.zip"

cat > "$SETTINGS_PATH" << CFG
{
  "name": "${SERVER_NAME}",
  "description": "",
  "tags": [],
  "max_players": ${MAX_PLAYERS},
  "visibility": {"public": false, "lan": true},
  "password": "${SERVER_PASSWORD}",
  "game_password": "${SERVER_PASSWORD}",
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

if [ ! -f "$SAVE_PATH" ]; then
    echo "No existing save found; creating a new map '${SAVE_NAME}'..."
    /opt/factorio/bin/x64/factorio --create "$SAVE_PATH"
fi

exec /opt/factorio/bin/x64/factorio \
    --start-server "$SAVE_PATH" \
    --server-settings "$SETTINGS_PATH" \
    --port "$SERVER_PORT"

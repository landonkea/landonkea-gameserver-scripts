#!/bin/sh
# docker/minecraft/entrypoint.sh -- writes eula.txt and server.properties
# from environment variables, then execs the server. Runs fresh on every
# container start (same idea as minecraft.profile.sh's
# profile_build_launch_args), so changing settings in docker-compose.yml
# and recreating the container is enough -- no rebuild needed.
set -eu

if [ "${EULA}" != "true" ]; then
    echo "==================================================================="
    echo "You must accept Mojang's EULA to run this server:"
    echo "  https://www.minecraft.net/eula"
    echo "Set EULA=true in docker-compose.yml (or -e EULA=true) to continue."
    echo "==================================================================="
    exit 1
fi

echo "eula=true" > /data/eula.txt

# RCON is required to be usable if a password isn't supplied; disable it
# cleanly rather than starting with a blank/guessable admin password.
if [ -z "${RCON_PASSWORD}" ]; then
    ENABLE_RCON=false
else
    ENABLE_RCON=true
fi

cat > /data/server.properties << CFG
server-port=${SERVER_PORT}
max-players=${MAX_PLAYERS}
motd=${MOTD}
difficulty=${DIFFICULTY}
gamemode=${GAMEMODE}
online-mode=true
white-list=false
enable-rcon=${ENABLE_RCON}
rcon.port=${RCON_PORT}
rcon.password=${RCON_PASSWORD}
enable-command-block=false
CFG

cd /data
exec java "-Xms${JAVA_HEAP_GB}G" "-Xmx${JAVA_HEAP_GB}G" -jar /opt/minecraft/server.jar --nogui

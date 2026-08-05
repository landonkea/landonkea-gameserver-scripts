#!/bin/sh
# docker/mindustry/entrypoint.sh -- Mindustry's server has no config file
# and no command-line flags for "start hosting now" -- it starts up and
# sits at a ">" prompt waiting for someone to TYPE commands like "host".
# This fakes that with a named pipe (FIFO), the same technique
# profile_pre_launch_setup() uses in mindustry.profile.sh: pre-load the
# pipe with the startup commands, then hand the server that pipe as its
# stdin instead of a real (empty) terminal.
set -eu

mkdir -p /data
cd /data

FIFO="/data/mindustry.fifo"
rm -f "$FIFO"
mkfifo "$FIFO"

# Keep the pipe open forever so the server's read side never sees EOF and
# gives up -- without this, the pipe would close the instant the command
# writer below finishes, and the "waiting for more input" state would
# break.
( exec 3>"$FIFO"; exec sleep infinity ) &

# Give the JVM/server time to finish starting before commands arrive --
# sending them too early means they're silently dropped.
(
    sleep 10
    {
        echo "config port ${SERVER_PORT}"
        echo "config name ${SERVER_NAME}"
        # "host" with no arguments at all picks survival mode plus a random
        # one of Mindustry's own built-in maps (this is standard vanilla
        # server behavior, not a workaround). The server's own command
        # parser only reads a game mode out of the SECOND argument, and
        # treats the first argument as a map name to look up whenever any
        # argument is given at all -- so MODE can only be honored together
        # with an explicit MAP; a matching custom map file needs to exist
        # under /data/config/maps first, since "host <name>" only searches
        # already-loaded custom maps, never the built-in set.
        if [ -n "${MAP}" ]; then
            echo "host ${MAP} ${MODE}"
        else
            echo "host"
        fi
    } > "$FIFO"
) &

exec java "-Xms${JAVA_HEAP_GB}G" "-Xmx${JAVA_HEAP_GB}G" -jar /opt/mindustry/server-release.jar < "$FIFO"

#!/bin/sh
# docker/openttd/entrypoint.sh -- writes openttd.cfg from environment
# variables, then execs the dedicated server. Runs fresh on every container
# start, so changing SERVER_NAME/MAX_CLIENTS/SERVER_PASSWORD in
# docker-compose.yml and recreating the container is enough -- no need to
# rebuild the image.
set -eu

mkdir -p /data/save /data/autosave

cat > /data/openttd.cfg << CFG
[network]
server_name = ${SERVER_NAME}
server_port = ${SERVER_PORT}
max_clients = ${MAX_CLIENTS}
server_password = ${SERVER_PASSWORD}
CFG

exec /opt/openttd/openttd -D -c /data/openttd.cfg

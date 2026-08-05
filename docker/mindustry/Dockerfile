# docker/mindustry/Dockerfile -- containerized Mindustry dedicated server
#
# This is an ADDITIVE alternative to multi-game-platform/profiles/mindustry.profile.sh,
# not a replacement. See ../README.md for what you gain/lose by running this way
# instead of the host-based installer.
#
# Downloads server-release.jar directly from Mindustry's GitHub Releases
# (github.com/Anuken/Mindustry) at build time -- same source and mechanism
# as the host profile's profile_custom_download. Mindustry is open-source
# and not on Steam, so no Steam account is needed either way.
#
# Mindustry's server is console-driven, not config-file-driven: it starts
# up and waits for someone to TYPE commands like "host". entrypoint.sh
# fakes that the same way profile_pre_launch_setup() does in the host
# profile -- a named pipe (FIFO) pre-loaded with the startup commands. See
# entrypoint.sh for the full explanation.

FROM eclipse-temurin:25-jre-jammy AS builder

RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
        curl \
        jq \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/mindustry

# Same GitHub Releases API lookup as profile_custom_download() in
# mindustry.profile.sh: ask for the latest release, find the asset
# literally named "server-release.jar", download just that file.
RUN asset_url="$(curl -fsS --max-time 20 -H 'Accept: application/vnd.github+json' \
        https://api.github.com/repos/Anuken/Mindustry/releases/latest \
        | jq -r '.assets[] | select(.name == "server-release.jar") | .browser_download_url // empty')" \
    && test -n "$asset_url" \
    && curl -fsSL --max-time 300 "$asset_url" -o /opt/mindustry/server-release.jar \
    && test -s /opt/mindustry/server-release.jar

# --- final stage: JRE-only runtime, no curl/jq left behind ------------------
FROM eclipse-temurin:25-jre-jammy

RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
        iproute2 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --create-home --home-dir /home/mindustry --shell /usr/sbin/nologin mindustry

COPY --from=builder /opt/mindustry/server-release.jar /opt/mindustry/server-release.jar

# Mindustry writes its config/saves under a "config" directory next to
# wherever it's launched from -- point that whole tree at /data so it
# persists across container recreation.
RUN mkdir -p /data && chown -R mindustry:mindustry /data /opt/mindustry

VOLUME ["/data"]
USER mindustry
WORKDIR /data

# Game port: 6567, Mindustry's default (matches profile_port_specs in
# mindustry.profile.sh: "0:udp:game"). In practice the server listens on
# BOTH tcp and udp on this same port number (tcp for the reliable
# connection, udp for in-game traffic) -- expose both.
EXPOSE 6567/tcp
EXPOSE 6567/udp

# MAP is deliberately empty by default -- see entrypoint.sh: "host" with
# no arguments picks survival mode plus a random one of Mindustry's own
# built-in maps, which just works out of the box. Set MAP to a specific
# name only after placing a matching custom map file under
# /data/config/maps (built-in map names aren't valid here -- see
# entrypoint.sh for why).
ENV SERVER_NAME="My Mindustry Server" \
    SERVER_PORT=6567 \
    MAP="" \
    MODE="survival" \
    JAVA_HEAP_GB=1

COPY --chown=mindustry:mindustry entrypoint.sh /opt/mindustry/entrypoint.sh
USER root
RUN chmod +x /opt/mindustry/entrypoint.sh
USER mindustry

ENTRYPOINT ["/opt/mindustry/entrypoint.sh"]

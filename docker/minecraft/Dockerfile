# docker/minecraft/Dockerfile -- containerized Minecraft (Java Edition)
# dedicated server
#
# This is an ADDITIVE alternative to multi-game-platform/profiles/minecraft.profile.sh,
# not a replacement. See ../README.md for what you gain/lose by running this way
# instead of the host-based installer.
#
# Downloads server.jar directly from Mojang's official version-manifest API
# at build time (same source and mechanism as the host profile's
# profile_custom_download), always the latest official release. Rebuild the
# image to pick up a newer Minecraft release.
#
# By building this image and running the container, you are accepting
# Mojang's EULA (https://www.minecraft.net/eula) -- same as the host
# installer's profile_gather_prompts step for this game.

FROM eclipse-temurin:25-jre-jammy AS builder

RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
        curl \
        jq \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/minecraft

# bash (not the default dash/sh) so the "<<<" here-string below works.
SHELL ["/bin/bash", "-c"]

# Same two-step lookup as profile_custom_download() in minecraft.profile.sh:
# ask the manifest which release is current, then fetch that release's own
# manifest to get the actual server.jar download URL.
RUN manifest="$(curl -fsS --max-time 20 https://piston-meta.mojang.com/mc/game/version_manifest_v2.json)" \
    && latest_release="$(jq -r '.latest.release' <<< "$manifest")" \
    && echo "Latest release: ${latest_release}" \
    && version_url="$(jq -r --arg id "$latest_release" '.versions[] | select(.id == $id) | .url' <<< "$manifest")" \
    && version_manifest="$(curl -fsS --max-time 20 "$version_url")" \
    && server_url="$(jq -r '.downloads.server.url' <<< "$version_manifest")" \
    && curl -fsSL --max-time 300 "$server_url" -o /opt/minecraft/server.jar \
    && test -s /opt/minecraft/server.jar

# --- final stage: JRE-only runtime, no curl/jq left behind ------------------
FROM eclipse-temurin:25-jre-jammy

RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
        iproute2 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --create-home --home-dir /home/minecraft --shell /usr/sbin/nologin minecraft

COPY --from=builder /opt/minecraft/server.jar /opt/minecraft/server.jar

# World save, server.properties, and everything else Minecraft writes at
# runtime lives entirely under /data -- mount this as a volume to persist
# it across container recreation (and to have something for the platform's
# usual backup tooling to point at, if you script that up yourself).
RUN mkdir -p /data && chown -R minecraft:minecraft /data /opt/minecraft

VOLUME ["/data"]
USER minecraft
WORKDIR /data

# Game port (matches profile_port_specs: "0:tcp:game") and RCON port
# ("1:tcp:rcon") from minecraft.profile.sh.
EXPOSE 25565/tcp
EXPOSE 25575/tcp

ENV EULA="false" \
    SERVER_PORT=25565 \
    RCON_PORT=25575 \
    MAX_PLAYERS=20 \
    MOTD="A Minecraft Server" \
    DIFFICULTY=easy \
    GAMEMODE=survival \
    JAVA_HEAP_GB=2 \
    RCON_PASSWORD=""

COPY --chown=minecraft:minecraft entrypoint.sh /opt/minecraft/entrypoint.sh
USER root
RUN chmod +x /opt/minecraft/entrypoint.sh
USER minecraft

ENTRYPOINT ["/opt/minecraft/entrypoint.sh"]

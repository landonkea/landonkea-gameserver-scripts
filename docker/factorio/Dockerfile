# docker/factorio/Dockerfile -- containerized Factorio headless dedicated server
#
# This is an ADDITIVE alternative to multi-game-platform/profiles/factorio.profile.sh,
# not a replacement. See ../README.md for what you gain/lose by running this way
# instead of the host-based installer.
#
# Downloads the same official, direct-from-factorio.com "stable" headless
# Linux tarball the host profile uses (no Steam account needed) -- see
# FACTORIO_DOWNLOAD_URL in the profile for the identical URL.

# factorio.com only publishes an x86_64 headless build (no arm64), so both
# stages are pinned to linux/amd64 explicitly, same reasoning as
# ../openttd/Dockerfile -- this makes the image build and run consistently
# (via emulation where needed) on arm64 hosts too.
FROM --platform=linux/amd64 debian:bookworm-slim AS builder

RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
        curl \
        ca-certificates \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt

# Always fetches whatever factorio.com currently calls "stable" -- same
# mechanism (and URL) as profile_custom_download() in factorio.profile.sh.
RUN curl -fsSL --max-time 300 \
        "https://factorio.com/get-download/stable/headless/linux64" \
        -o /tmp/factorio.tar.xz \
    && tar -xJf /tmp/factorio.tar.xz -C /opt \
    && rm -f /tmp/factorio.tar.xz \
    && test -x /opt/factorio/bin/x64/factorio

# --- final stage: slim runtime image, no build tools left behind -----------
FROM --platform=linux/amd64 debian:bookworm-slim

RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
        ca-certificates \
        iproute2 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --create-home --home-dir /home/factorio --shell /usr/sbin/nologin factorio

COPY --from=builder /opt/factorio /opt/factorio

# Save file, server-settings.json, and mod list (if any) live entirely
# under /data -- mount this as a volume to persist it across container
# recreation.
RUN mkdir -p /data && chown -R factorio:factorio /data /opt/factorio

VOLUME ["/data"]
USER factorio
WORKDIR /data

# Game port: 34197/udp, Factorio's long-standing default (matches
# profile_port_specs in factorio.profile.sh: "0:udp:game").
EXPOSE 34197/udp

ENV SERVER_NAME="My Factorio Server" \
    SERVER_PORT=34197 \
    MAX_PLAYERS=0 \
    SERVER_PASSWORD="" \
    SAVE_NAME="world"

# entrypoint.sh writes server-settings.json from env vars each start,
# creates the save on first run if it doesn't exist yet, then execs
# factorio in --start-server mode.
COPY --chown=factorio:factorio entrypoint.sh /opt/factorio/entrypoint.sh
RUN chmod +x /opt/factorio/entrypoint.sh

ENTRYPOINT ["/opt/factorio/entrypoint.sh"]

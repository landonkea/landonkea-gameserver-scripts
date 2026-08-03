# docker/openttd/Dockerfile -- containerized OpenTTD dedicated server
#
# This is an ADDITIVE alternative to multi-game-platform/profiles/openttd.profile.sh,
# not a replacement. See ../README.md for what you gain/lose by running this way
# instead of the host-based installer.
#
# Downloads the same official, direct-from-openttd.org release tarball the
# host profile uses (no Steam account needed), pinned to the same version for
# consistency. Update OPENTTD_VERSION here and in the profile together if you
# bump it.

# The upstream openttd.org release tarball is only published for amd64
# (no arm64 build), so both stages are pinned to linux/amd64 explicitly --
# this makes the image build and run consistently (via emulation where
# needed) on arm64 hosts too, instead of silently mismatching archs.
FROM --platform=linux/amd64 debian:bookworm-slim AS builder

ARG OPENTTD_VERSION=14.1
# OpenGFX is OpenTTD's free/open-source base graphics set -- the
# dedicated server binary refuses to start without SOME graphics set
# present, even though it never renders anything to a screen. Pinned
# separately since it versions independently of OpenTTD itself.
ARG OPENGFX_VERSION=7.1
ENV OPENTTD_VERSION=${OPENTTD_VERSION}

RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
        curl \
        ca-certificates \
        xz-utils \
        unzip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/openttd

RUN curl -fsSL --max-time 300 \
        "https://cdn.openttd.org/openttd-releases/${OPENTTD_VERSION}/openttd-${OPENTTD_VERSION}-linux-generic-amd64.tar.xz" \
        -o /tmp/openttd.tar.xz \
    && tar -xJf /tmp/openttd.tar.xz -C /opt/openttd --strip-components=1 \
    && rm -f /tmp/openttd.tar.xz \
    && test -x /opt/openttd/openttd

RUN mkdir -p /opt/openttd/baseset \
    && curl -fsSL --max-time 300 \
        "https://cdn.openttd.org/opengfx-releases/${OPENGFX_VERSION}/opengfx-${OPENGFX_VERSION}-all.zip" \
        -o /tmp/opengfx.zip \
    && unzip -q /tmp/opengfx.zip -d /tmp/opengfx \
    && find /tmp/opengfx -iname '*.tar' -exec tar -xf {} -C /opt/openttd/baseset --strip-components=1 \; \
    && rm -rf /tmp/opengfx.zip /tmp/opengfx

# --- final stage: slim runtime image, no build tools left behind -----------
FROM --platform=linux/amd64 debian:bookworm-slim

RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
        ca-certificates \
        libsdl2-2.0-0 \
        libfontconfig1 \
        libicu72 \
        libgomp1 \
        libglib2.0-0 \
        iproute2 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --create-home --home-dir /home/openttd --shell /usr/sbin/nologin openttd

COPY --from=builder /opt/openttd /opt/openttd

# Save data (games/, autosave/, config, etc.) lives entirely under
# /data -- mount this as a volume to persist it across container recreation.
RUN mkdir -p /data/save /data/autosave && chown -R openttd:openttd /data /opt/openttd

VOLUME ["/data"]
USER openttd
WORKDIR /data

# Game port: 3979 by default, UDP for the master-server/LAN query protocol
# and TCP for the actual game connection (matches profile_port_specs in
# openttd.profile.sh: "0:udp:game" and "0:tcp:game").
EXPOSE 3979/tcp
EXPOSE 3979/udp

ENV SERVER_NAME="My OpenTTD Server" \
    SERVER_PORT=3979 \
    MAX_CLIENTS=8 \
    SERVER_PASSWORD=""

# entrypoint.sh writes openttd.cfg from env vars each start (so config
# changes via docker-compose environment: take effect on container
# recreation) and then execs openttd in dedicated-server mode.
COPY --chown=openttd:openttd entrypoint.sh /opt/openttd/entrypoint.sh
RUN chmod +x /opt/openttd/entrypoint.sh

ENTRYPOINT ["/opt/openttd/entrypoint.sh"]

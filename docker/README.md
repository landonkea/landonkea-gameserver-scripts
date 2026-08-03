# Containerized runtime (alternative, additive)

This directory adds an **alternative way** to run a single game server: inside
a Docker (or Podman) container, instead of directly on the host.

**This does not replace the host-based installer.** The primary,
full-featured path for this project remains
[`multi-game-platform/install-game-server.sh`](../multi-game-platform/install-game-server.sh)
(and the standalone [`valheim/`](../valheim/) installer) run via
[`install.sh`](../install.sh) at the repo root. Nothing about those scripts
changed, and they're still the recommended way to run a production game
server with this project.

## What you get here vs. the host installer

| | Host installer (`install.sh`) | Containerized (`docker/`) |
|---|---|---|
| Games supported | 29 profiles + Valheim | **OpenTTD, Minecraft (Java Edition)** only |
| Systemd service management | Yes | No (container restart policy only) |
| Automated backups (cron, retention) | Yes | No -- mount the data volume and back it up yourself |
| Health monitoring / auto-restart on crash | Yes | No (Docker's own `restart: unless-stopped` only) |
| Discord notifications | Yes | No |
| Multi-instance management (many servers, one host) | Yes | No -- one container = one server; run multiple containers/compose services yourself if you want more |
| On-demand sleep/wake when idle | Yes (some profiles) | No |
| Firewall/port management | Automatic (ufw) | Manual -- you own whatever ports you publish |

In short: the container path is a **smaller, self-contained option** for
running one of two specific games with just Docker/Podman and nothing else
installed on the host. If you want backups, monitoring, Discord alerts, or to
run several game servers manageably on one box, use the host installer
instead.

## Currently supported games

Only two games have container images in this pass, chosen because they need
no Steam account, no interactive setup, and no proprietary launcher:

- **OpenTTD** -- [`docker/openttd/Dockerfile`](openttd/Dockerfile). Same
  direct-from-openttd.org release the host profile
  (`multi-game-platform/profiles/openttd.profile.sh`) uses, plus the
  official OpenGFX free graphics set (required for the dedicated server to
  start at all, even headless).
- **Minecraft (Java Edition)** -- [`docker/minecraft/Dockerfile`](minecraft/Dockerfile).
  Downloads the latest official release `server.jar` straight from Mojang's
  version-manifest API at build time, same mechanism as the host profile
  (`multi-game-platform/profiles/minecraft.profile.sh`). **Building or
  running this image means you accept
  [Mojang's EULA](https://www.minecraft.net/eula)** -- the container refuses
  to start unless you explicitly set `EULA=true`.

The other 27+ profiles (Steam-authenticated games, Wine-dependent games,
games with interactive installers, etc.) are out of scope for this pass --
containerizing them well is a larger undertaking on its own.

## Quick start

```bash
cd docker

# OpenTTD -- no config required to just try it
docker compose up -d openttd

# Minecraft -- you must accept the EULA yourself first
#   (edit docker-compose.yml: environment.EULA: "true" under the minecraft
#   service, or override on the command line)
EULA=true docker compose run --rm -e EULA=true -p 25565:25565 -p 25575:25575 minecraft
# or, after editing docker-compose.yml:
docker compose up -d minecraft
```

Save data persists in named Docker volumes (`openttd-data`, `minecraft-data`)
so it survives `docker compose down` / container recreation. Back those up
however you back up the rest of your Docker host -- this path does not wire
into this project's own backup scripts.

## Building and verifying manually (without compose)

```bash
# OpenTTD
docker build -t openttd-server ./openttd
docker run -d --name openttd -p 3979:3979/tcp -p 3979:3979/udp openttd-server
docker exec openttd ss -tulnp   # confirm the process is listening on 3979

# Minecraft
docker build -t minecraft-server ./minecraft
docker run -d --name minecraft -e EULA=true -p 25565:25565 minecraft-server
docker logs -f minecraft         # wait for "Done (...)! For help, type help"
docker exec minecraft ss -tlnp   # confirm the process is listening on 25565
```

## Configuration

Both images are configured entirely through environment variables (see each
`Dockerfile`'s `ENV` block for the full list and defaults) -- edit
`docker-compose.yml`'s `environment:` section, or pass `-e VAR=value` to
`docker run`. Changes take effect on container recreation; no image rebuild
needed unless you're changing the pinned game version
(`OPENTTD_VERSION`/`OPENGFX_VERSION` build args for OpenTTD, or just
rebuilding the Minecraft image to pick up whatever Mojang's "latest release"
is at build time).

## CI

`.github/workflows/docker-build.yml` builds both images and runs a smoke
test (starts the container, waits for the process to come up, confirms the
expected port is listening) on every push/PR that touches `docker/`. This is
a separate, additive CI job -- it does not touch the existing shellcheck /
profile-contract workflow (`.github/workflows/syntax-check.yml`).

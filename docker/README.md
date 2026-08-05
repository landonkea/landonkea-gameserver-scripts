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
| Games supported | 29 profiles + Valheim | **OpenTTD, Minecraft (Java Edition), Factorio, Mindustry** only |
| Systemd service management | Yes | No (container restart policy only) |
| Automated backups (cron, retention) | Yes | No -- mount the data volume and back it up yourself |
| Health monitoring / auto-restart on crash | Yes | No (Docker's own `restart: unless-stopped` only) |
| Discord notifications | Yes | No |
| Multi-instance management (many servers, one host) | Yes | No -- one container = one server; run multiple containers/compose services yourself if you want more |
| On-demand sleep/wake when idle | Yes (some profiles) | No |
| Firewall/port management | Automatic (ufw) | Manual -- you own whatever ports you publish |

In short: the container path is a **smaller, self-contained option** for
running one of a handful of specific games with just Docker/Podman and
nothing else installed on the host. If you want backups, monitoring,
Discord alerts, or to run several game servers manageably on one box, use
the host installer instead.

## Currently supported games

Four games have container images so far, chosen because they need no Steam
account, no interactive setup, and no proprietary launcher -- each one is
downloaded directly from its publisher over plain HTTP(S), the same
mechanism its host profile already uses under
`multi-game-platform/profiles/`:

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
- **Factorio** -- [`docker/factorio/Dockerfile`](factorio/Dockerfile).
  Downloads whatever factorio.com currently calls "stable" headless Linux
  server at build time, same URL as the host profile
  (`multi-game-platform/profiles/factorio.profile.sh`). The save is
  auto-created on first container start if it doesn't exist yet.
- **Mindustry** -- [`docker/mindustry/Dockerfile`](mindustry/Dockerfile).
  Downloads `server-release.jar` from Mindustry's GitHub Releases at build
  time, same mechanism as the host profile
  (`multi-game-platform/profiles/mindustry.profile.sh`). Mindustry's server
  is console-driven rather than config-file-driven, so `entrypoint.sh` feeds
  it startup commands through a named pipe, the same trick the host
  profile's `profile_pre_launch_setup()` uses -- see that file's comments
  for the full explanation.

The other 25+ profiles are downloaded through SteamCMD (with `+login
anonymous` -- no actual Steam account needed either), several also need
Wine or an interactive first-run. **Valheim in particular was evaluated for
this pass** (it fits the "no Steam account, no interactive setup" bar the
same way the four games above do) but was held back: this platform's own
verification standard requires actually building and running each new
container image and confirming the server process comes up and the right
port starts listening, not just that the image builds -- and SteamCMD's
Linux client is a 32-bit x86 binary that reliably segfaults while loading
the Steam API under ARM-host container emulation (confirmed with both the
official SteamCMD tarball and a well-established community SteamCMD Docker
image; this is a widely-documented category of ARM-host limitation, not
something specific to how this repo builds the image). SteamCMD-backed
games are expected to build and run fine as-is on a genuine x86_64 host or
CI runner -- adding Valheim (or any other SteamCMD-backed profile) is a
reasonable follow-up for whoever can verify it on one.

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

# Factorio -- no config required to just try it
docker compose up -d factorio

# Mindustry -- no config required to just try it
docker compose up -d mindustry
```

Save data persists in named Docker volumes (`openttd-data`, `minecraft-data`,
`factorio-data`, `mindustry-data`) so it survives `docker compose down` /
container recreation. Back those up however you back up the rest of your
Docker host -- this path does not wire into this project's own backup
scripts.

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

# Factorio
docker build -t factorio-server ./factorio
docker run -d --name factorio -p 34197:34197/udp factorio-server
docker logs -f factorio          # wait for "Hosting game at IP ADDR"
docker exec factorio ss -tulnp   # confirm the process is listening on 34197/udp

# Mindustry
docker build -t mindustry-server ./mindustry
docker run -d --name mindustry -p 6567:6567/tcp -p 6567:6567/udp mindustry-server
docker logs -f mindustry         # wait for "Opened a server on port 6567"
docker exec mindustry ss -tulnp  # confirm the process is listening on 6567
```

## Configuration

All four images are configured entirely through environment variables (see
each `Dockerfile`'s `ENV` block for the full list and defaults) -- edit
`docker-compose.yml`'s `environment:` section, or pass `-e VAR=value` to
`docker run`. Changes take effect on container recreation; no image rebuild
needed unless you're changing the pinned game version
(`OPENTTD_VERSION`/`OPENGFX_VERSION` build args for OpenTTD, or just
rebuilding the Minecraft/Factorio/Mindustry images to pick up whatever
their respective "latest" is at build time).

Mindustry's default `MAP=""` means "host" picks a random built-in map on
each start -- set `MAP` to a specific name only after placing a matching
custom map file under the `mindustry-data` volume's `config/maps/`
directory (see `mindustry/entrypoint.sh` for why built-in map names alone
don't work as a `MAP` value).

## CI

`.github/workflows/docker-build.yml` builds all four images and runs a
smoke test on each (starts the container, waits for the process to come
up, confirms the expected port is listening) on every push/PR that touches
`docker/`. This is a separate, additive CI job -- it does not touch the
existing shellcheck / profile-contract workflow
(`.github/workflows/syntax-check.yml`).

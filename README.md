# landonkea-gameserver-scripts

A production-grade game server management platform for Ubuntu Linux. Install, update, back up, monitor, and manage dedicated game servers from a single command-line interface.

## Supported Games (29 profiles)

ARK: Survival Ascended, ARK: Survival Evolved, Arma 3, Astroneer, Conan Exiles, Core Keeper, Counter-Strike 2, DayZ, Empyrion, Enshrouded, Factorio, Garry's Mod, Insurgency: Sandstorm, Killing Floor 2, Left 4 Dead 2, Mindustry, Minecraft (Java Edition), OpenTTD, Palworld, Project Zomboid, Rust, Satisfactory, 7 Days to Die, Space Engineers, Squad, Team Fortress 2, Terraria, Unturned, V Rising

Plus a standalone **Valheim** installer with extended backup/restore and status monitoring features.

There is also an [additive, containerized runtime option](docker/README.md)
(Docker/Podman) for two of these games -- OpenTTD and Minecraft -- for
anyone who wants a single containerized instance instead of a host install.
It's a smaller alternative, not a replacement: it has no backups, monitoring,
Discord alerts, or multi-instance management. The host-based installer below
remains the primary, full-featured path.

## Architecture

```
install.sh                          # Entry point — detects which installer to run
├── lib/common.sh                   # Shared library (54 functions: logging, validation, firewall, monitoring)
├── multi-game-platform/
│   ├── install-game-server.sh      # Core multi-game installer (systemd, cron, backups, on-demand)
│   ├── profiles/*.profile.sh       # 29 game-specific config files
│   └── scripts/
│       ├── status-dashboard.sh     # Unified health-check dashboard
│       ├── control-panel.py        # Optional read-write web control panel (off by default)
│       ├── control-panel-instance-action.sh  # Root-only start/stop/restart, called only by control-panel.py
│       └── setup-control-panel.sh  # The only way to opt into the control panel
├── valheim/
│   ├── install-valheim-server.sh   # Valheim-specific installer
│   └── manage-mods.sh              # Thunderstore mod manager for Valheim shards
└── docker/                         # Additive containerized runtime (OpenTTD, Minecraft only)
    ├── openttd/Dockerfile
    ├── minecraft/Dockerfile
    └── docker-compose.yml
```

## Features

- **Interactive & automatic modes** — runs with prompts for humans, or `-y` for scripts/CI
- **Dry-run mode** — `--dry-run` previews what would happen without making changes
- **Systemd integration** — each instance gets its own `gameserver@instancename.service`
- **Automated backups** — per-instance cron jobs with configurable retention
- **On-demand instances** — servers sleep when idle, wake on player connect (via sleep-listener)
- **Health monitoring** — cron-based checks with auto-restart on failure
- **Crash simulation** — `--simulate-crash <instance>` deliberately breaks an instance and proves the auto-restart + Discord-alert loop actually recovers it
- **Status dashboard** — `status-dashboard.sh` shows all instances at a glance (`--json` for scripting/monitoring)
- **Discord notifications** — optional alerts for starts, stops, failures
- **Golden installs** — shared game files downloaded once, symlinked into instances
- **Per-instance config** — each instance gets its own settings, world data, and logs

## Quick Start

```bash
# Install the multi-game platform
sudo ./install.sh

# Install a game server instance
sudo /srv/gameservers/scripts/start-instance.sh

# Check status of all instances
sudo /srv/gameservers/scripts/status-dashboard.sh

# Health-check a specific instance
sudo /srv/gameservers/scripts/healthcheck-instance.sh myinstance

# Test the auto-restart + Discord-alert safety loop for real
sudo ./install-game-server.sh --simulate-crash myinstance
```

## Testing the auto-restart safety loop (`--simulate-crash`)

Health monitoring and Discord alerts only matter if they actually work when
something really breaks -- and the only way to know for sure is to break
something on purpose. `--simulate-crash <instance>` does exactly that: it
deliberately stops (or, with `--crash-mode kill`, SIGKILLs) a real running
instance, runs the actual `healthcheck-instance.sh` against it, and reports
PASS or FAIL depending on whether the instance came back up on its own --
using the exact same code path a real crash would trigger, not a simulation
of it.

```bash
sudo ./install-game-server.sh --simulate-crash myinstance
sudo ./install-game-server.sh --simulate-crash myinstance --crash-mode kill
sudo ./install-game-server.sh --simulate-crash myinstance --no-notify        # skip the real Discord POST
sudo ./install-game-server.sh --simulate-crash myinstance --crash-timeout 90 # allow more time to recover
```

Only run it against an instance you're OK restarting right now -- it's a
real crash, not a dry run, and requires root for the same reason
`healthcheck-instance.sh` does.

## Discord Notifications (optional)

Every instance can optionally send Discord alerts when something goes wrong:
a crashed server getting auto-restarted, a failed backup, a backup skipped
because the backup disk is nearly full, or a failed post-update restart.
This is entirely optional -- if you never configure it, nothing changes;
the tool works exactly the same either way.

**Setup:**

1. In Discord, go to the target channel's Settings → Integrations →
   Webhooks → New Webhook, and copy its URL. It looks like:
   `https://discord.com/api/webhooks/123456789/abcDEF...`
2. When the installer prompts `Discord webhook URL for crash/backup-failure
   alerts (blank to disable)`, paste it in. Leave it blank to skip.
3. To add, change, or remove it after an instance already exists, edit
   `DISCORD_WEBHOOK_URL="..."` in that instance's config file:
   `/srv/gameservers/instances/<name>/config.env` (or
   `/srv/valheim/instances/<name>/config.env` for the standalone Valheim
   installer). No restart is needed -- every backup/update/health-check
   script reads config.env fresh each time it runs, so the change takes
   effect on the very next run.

The webhook URL is per-instance (not a single global setting), stored in
that instance's `config.env` alongside its other settings -- the same file
already used for the server password and backup schedule, and it's
`chmod 600` for the same reason: only root can read it.

## Web Control Panel (optional, off by default, security-sensitive)

A small, dependency-free web UI (Python 3 standard library only) that shows
live status for every instance and can start/stop/restart them from a
browser. **It is not exposed by default** -- installing the platform writes
the control panel's files to `/srv/gameservers/scripts/`, but the server
refuses every start/stop/restart request until you explicitly opt in.

**What it can do:** view status (read-only, always available once the
server is running) and start/stop/restart any registered instance
(read-write, requires the admin token below). It cannot add/remove
instances, change any instance's configuration, or run arbitrary commands.

**Enable it:**

```bash
sudo /srv/gameservers/scripts/setup-control-panel.sh --enable
```

This generates a random 64-character admin token (`openssl rand -hex 32`),
writes it to `/srv/gameservers/control-panel.conf` (`chmod 600`,
root-owned), prints the token to your terminal **exactly once**, and
installs + starts a systemd service (`gameserver-control-panel.service`)
listening on `127.0.0.1:8642` by default. Save the token now -- it is never
shown again (rotate instead if you lose it). Running the script with no
flags asks interactively instead (default: declined, nothing enabled).

Open `http://127.0.0.1:8642/` (or tunnel/proxy that port to wherever you're
sitting -- the server has no TLS of its own and isn't meant to be put
directly on the public internet), paste the token into the "Admin token"
field, and click a start/stop/restart button.

**Auth, in short:** every action request must include
`Authorization: Bearer <token>`. There is no other way in -- the token is
never accepted via a URL query string (so it never ends up in an access
log), and actions are POST-only (so a plain cross-site form can't trigger
one; a script would need to know the token and deliberately set that
header). Every attempt, successful or not, is written to
`/srv/gameservers/control-panel-audit.log`.

**Rotate the token:**

```bash
sudo /srv/gameservers/scripts/setup-control-panel.sh --rotate
```

The old token stops working immediately; a new one is printed once, same
as above.

**Disable it again:**

```bash
sudo /srv/gameservers/scripts/setup-control-panel.sh --disable
```

The service is stopped; any previously-issued token is left in the config
file but becomes inert (every action request gets refused) until you
`--enable` or `--rotate` again.

See `multi-game-platform/scripts/control-panel.py`'s module docstring for
the full security model and reasoning, and
`tests/control_panel_test.sh` for the functional test that exercises both
the rejection paths (no token / wrong token / GET instead of POST / query
string token) and the success path (a valid token genuinely starts/stops/
restarts the target instance) against a real running server.

## Requirements

- Ubuntu 22.04+
- Root access (auto-elevates via sudo)
- ~2 GB free disk space minimum (varies by game)

## License

Open source — use freely.

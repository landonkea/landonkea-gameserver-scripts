# landonkea-gameserver-scripts

A production-grade game server management platform for Ubuntu Linux. Install, update, back up, monitor, and manage dedicated game servers from a single command-line interface.

## Supported Games (29 profiles)

ARK: Survival Ascended, ARK: Survival Evolved, Arma 3, Astroneer, Conan Exiles, Core Keeper, Counter-Strike 2, DayZ, Empyrion, Enshrouded, Factorio, Garry's Mod, Insurgency: Sandstorm, Killing Floor 2, Left 4 Dead 2, Mindustry, Minecraft (Java Edition), OpenTTD, Palworld, Project Zomboid, Rust, Satisfactory, 7 Days to Die, Space Engineers, Squad, Team Fortress 2, Terraria, Unturned, V Rising

Plus a standalone **Valheim** installer with extended backup/restore and status monitoring features.

## Architecture

```
install.sh                          # Entry point — detects which installer to run
├── lib/common.sh                   # Shared library (54 functions: logging, validation, firewall, monitoring)
├── multi-game-platform/
│   ├── install-game-server.sh      # Core multi-game installer (systemd, cron, backups, on-demand)
│   ├── profiles/*.profile.sh       # 29 game-specific config files
│   └── scripts/
│       └── status-dashboard.sh     # Unified health-check dashboard
└── valheim/
    └── install-valheim-server.sh   # Valheim-specific installer
```

## Features

- **Interactive & automatic modes** — runs with prompts for humans, or `-y` for scripts/CI
- **Dry-run mode** — `--dry-run` previews what would happen without making changes
- **Systemd integration** — each instance gets its own `gameserver@instancename.service`
- **Automated backups** — per-instance cron jobs with configurable retention
- **On-demand instances** — servers sleep when idle, wake on player connect (via sleep-listener)
- **Health monitoring** — cron-based checks with auto-restart on failure
- **Status dashboard** — `status-dashboard.sh` shows all instances at a glance
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
```

## Requirements

- Ubuntu 22.04+
- Root access (auto-elevates via sudo)
- ~2 GB free disk space minimum (varies by game)

## License

Open source — use freely.

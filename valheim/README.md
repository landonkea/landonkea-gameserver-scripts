# Valheim Dedicated Server — Multi-Instance ("Shard") Installer

A single, self-contained Bash script that deploys and manages any number of
independent Valheim dedicated server instances ("shards") on one Ubuntu
Server LTS host, with no manual setup and no terminal window that has to
stay open.

## Why "shards" instead of one big server?

Valheim's dedicated server has a hard, engine-level limit: it's designed
and supported for **10 concurrent players**. That's not a config setting —
it comes from how the game itself simulates the world (largely on a single
CPU thread). Community mods can raise the cap, but real-world consensus is
that things degrade badly past roughly 10-15 players **regardless of
hardware**. If you need to support more total players than that, the only
real answer is several separate worlds running side by side — this script
automates exactly that, instead of pretending one instance can be tuned to
hold hundreds of people.

A **shard** is just one independent copy of the game world: its own save,
its own players, its own systemd service. Players on shard 1 never see or
interact with players on shard 2 — they're separate, parallel instances of
the same game, not one shared crowd.

---

## Requirements

- **Ubuntu Server**, any current **LTS** release (auto-detected; not
  pinned to a specific version number).
- **x86_64** CPU.
- RAM/disk sized for however many shards you actually plan to run
  *concurrently* — budget roughly 2-4 GB RAM and ~2 GB disk **per shard**,
  plus the base OS overhead.
- An internet connection.

---

## Quick Start

**Not sure this server is ready? Check first, without changing anything:**

```bash
chmod +x install-valheim-server.sh
./install-valheim-server.sh --check
```

This confirms Ubuntu, architecture, internet, RAM, and disk space, and
exits without installing or changing a single thing — safe to run as
many times as you like, and doesn't need `sudo`.

**First run** (installs shared prerequisites + your first shard):

```bash
chmod +x install-valheim-server.sh
./install-valheim-server.sh
```

You don't need to type `sudo` — the script re-launches itself with sudo
automatically if needed.

**Add another shard later:**

```bash
./install-valheim-server.sh --add-instance shard2
```

**List / remove / uninstall:**

```bash
./install-valheim-server.sh --list-instances
./install-valheim-server.sh --remove-instance shard2
./install-valheim-server.sh --uninstall              # removes everything
```

Every invocation re-verifies the shared prerequisites (packages, the game
install, firewall, fail2ban, etc.) before touching anything shard-specific
— safe and quick to re-run.

---

## Every Shard Is Private

There is no "public" option. Every instance always runs with `-public 0`,
so **none of them ever appear in any Steam or in-game server browser.**
Joining always requires the exact IP:port (and password) for that specific
shard — see the connection summary printed after each `--add-instance` run.
This is deliberate: for a large, curated community split across many
shards, you want to control exactly who ends up on which one, not have
people randomly browsing and joining the wrong crowd.

---

## Interactive Prompts (per shard)

| Prompt | Default | Notes |
|---|---|---|
| Instance (shard) name | — | Letters, numbers, `_` `-`; used in paths, systemd, and the port registry |
| Server name | `Valheim - <shard>` | Shown to players once they've connected |
| World name | `Midgard` | |
| Password | — (random if `-y`) | 5-64 chars, can't overlap the server name |
| Port | next free block | Auto-suggested from the port registry; uses port, port+1, port+2 |
| Max players | **15** | 10 = vanilla, no mods. Above 10 auto-installs BepInEx + MaxPlayerCount (see below) and disables Crossplay for that shard. Hard-capped at 30, with a strong warning above 20 — that's past where the community/hosting consensus says Valheim holds up "regardless of specs." |
| Crossplay | no | Only asked if max players ≤ 10 (mods and Crossplay are mutually exclusive) |
| Backup retention / directory / time | 7 days / shard's own `backups/` / `03:00` | |
| Daily update-check time | `04:00` | |

---

## Raising the Player Cap: BepInEx + MaxPlayerCount

Setting max players above 10 makes the installer automatically:

1. Download **BepInEx** (the standard Unity mod loader) from Thunderstore.
2. Download the **MaxPlayerCount** plugin from Thunderstore.
3. Briefly start that shard once (a throwaway probe world, never exposed
   through the firewall) so the plugin generates its config file.
4. Patch that config to your chosen player count, and verify the change
   actually stuck.

This is best-effort and **self-verifying, never silently wrong**: if any
step doesn't produce what's expected (a network hiccup, a changed package
layout, an unexpected config format), the installer clearly tells you
exactly what happened and falls back to vanilla (10-player cap) for that
shard rather than leaving it in a broken, half-configured state. Check the
install log for `[shard-name]`-tagged lines if a shard fell back
unexpectedly.

**Crossplay and mods cannot both be on.** Crossplay uses a different
networking backend (PlayFab) that BepInEx can't hook into — this is a
Valheim limitation, not something the script can work around. Any shard
with max players above 10 has Crossplay forced off automatically.

**Be realistic about the ceiling.** 15 is a reasonable default for "more
than vanilla, still mostly stable." Above ~20, you're past where hosting
companies and the community agree the game holds up at all. This raises
the cap; it doesn't repeal Valheim's underlying architecture.

---

## Directory Layout

```
/srv/valheim/
├── steamcmd/              SteamCMD itself (shared)
├── golden-server/         ONE canonical, SteamCMD-managed game install (shared)
├── scripts/                All helper scripts + common.sh (shared)
├── instances.registry      name:port:created — powers port allocation & listing
└── instances/
    └── <shard-name>/
        ├── server/         This shard's own copy of the game files
        │                   (+ BepInEx, if modded) — synced from golden-server
        ├── world/           World save files
        ├── backups/         Timestamped ZIP backups (default location)
        ├── logs/             Game log, backup.log, update.log
        ├── tmp/              Scratch space (backup staging, restore safety copies)
        └── config.env        This shard's settings (mode 600)
```

Only **one** copy of the actual game binaries is ever downloaded
(`golden-server/`) — each shard gets a fast local copy synced from it, so
updating the game once (via `update-valheim.sh`) refreshes every shard
without re-downloading per shard. A shard's own BepInEx/mod files are never
touched by that sync.

---

## Managing Shards

```bash
systemctl status  valheim@shard2      # this shard specifically
systemctl restart valheim@shard2
journalctl -u valheim@shard2 -f
```

## Helper Scripts (`/srv/valheim/scripts/`)

Every script below takes an instance name as its first argument; most also
accept the literal `all` to operate across every shard.

| Script | Usage |
|---|---|
| `status-valheim.sh [name]` | One shard's detail, or a summary table of all (default) |
| `logs-valheim.sh <name> [service\|game\|backup\|update]` | Tail the relevant log |
| `stop-valheim.sh` / `restart-valheim.sh` `<name\|all>` | |
| `backup-valheim.sh <name\|all>` | Manual backup (same logic as the daily schedule) |
| `restore-valheim.sh <name> <backup.zip>` | Restore one shard from a backup (keeps a safety copy first) |
| `update-valheim.sh <name\|all>` | Validates the shared golden install, then re-syncs + restarts the target shard(s) one at a time |
| `healthcheck-valheim.sh <name\|all>` | Manual health check (auto-restarts if run as root); also flags if a modded shard's MaxPlayerCount config has drifted from what was configured |
| `manual-foreground-start.sh <name>` | Foreground debugging as the `valheim` user — stop the real service first |
| `cpu-status.sh` / `ram-status.sh` / `disk-status.sh` / `smart-status.sh` | Host-wide resource usage |
| `network-status.sh` | Every shard's listening status + UFW status |
| `host-capacity-monitor.sh` | Runs every 15 min via cron; logs host-wide CPU/RAM utilization to `host-capacity.log`, flagging sustained high usage |

Every script auto-elevates with `sudo` if you didn't already run it as
root — you never need to remember it yourself.

---

## Scheduling Model

Rather than one cron entry per shard (which would mean rewriting
`/etc/cron.d` every time a shard is added or removed), a single dispatcher
runs every minute and checks each shard's **own** configured `BACKUP_TIME`/
`UPDATE_TIME` against the current clock — so every shard keeps an
independently chosen schedule with zero per-shard cron maintenance. A
separate health check runs across all shards every 10 minutes.

---

## On-Demand Mode (Sleep Until Connected)

Offered as a yes/no prompt (default: yes) when adding a shard. A
lightweight listener (`socat`) sits on the shard's game port while
asleep; the first connection wakes the real server. A per-minute check
then watches for **5 consecutive idle minutes** and, if idle, stops the
shard (Valheim saves the world cleanly via `SIGINT` on a normal
shutdown — no separate save step needed) and goes back to sleep.

Two honest limitations:
- **The first join attempt after waking will likely need a retry** —
  nothing was actually listening to complete that connection, it only
  triggered the wake-up. Depending on how long the world takes to load,
  you may need to manually reconnect once it's up.
- **Idle detection is a network-traffic heuristic, not an exact player
  count.** Valheim has no RCON or similar interface to ask "how many
  players are connected right now," so this watches for recent traffic
  to the shard's port instead — it can occasionally misjudge a
  quiet-but-still-connected player as idle. If that's a concern for a
  specific shard, answer "no" to the on-demand prompt for it.

`status-valheim.sh` shows `sleeping` as its own state, distinct from
`active`/`inactive`. `stop-valheim.sh` on a sleeping shard also disables
its listener (won't auto-wake until you restart it); `restart-valheim.sh`
on a sleeping shard wakes it instead of trying to restart something that
isn't running.

---

## Security

- Every shard's game process runs as an unprivileged, no-login system user
  (`valheim`) — never root.
- Every shard's `config.env` (contains its password) is locked to `600`.
- **Private by design** — see above.
- **UFW**: only SSH (rate-limited) and each shard's 3 UDP ports are opened.
- **fail2ban**: an explicit `sshd` jail (`/etc/fail2ban/jail.local`) bans an
  IP for an hour after 5 failed logins in 10 minutes, escalating for repeat
  offenders (up to a week). Left in place even after `--uninstall`.
- `journald` is capped at 500 MB total (shared across all shards' logs).
- Ownership/permissions are re-checked and repaired automatically before
  every single shard start.

---

## Connecting to a Shard

Vanilla Valheim has no direct "join by IP" box on its main menu:

1. In **Steam**: `View → Game Servers → Favorites tab → Add a Server`
2. Enter the exact `IP:port` for **that specific shard** (shown in its
   connection summary) — LAN players use the LAN IP, remote players use
   the public IP (with the shard's 3 ports forwarded on your router).
3. In Valheim: `Join Game → Favorites`

Since every shard is private, there's no server-browser search fallback —
the IP:port is the only way in, by design.

---

## Sizing for Your Numbers

If you're running many shards concurrently:

- **RAM/CPU**: each shard wants ~1 real CPU thread and 2-4 GB RAM most of
  the time. Running 10+ shards well generally wants a machine with that
  many real cores to hand out, not just a fast single core.
- **Bandwidth**: Valheim caps each connected player at roughly 64 KB/s
  (~512 Kbps). For remote players, budget (players × 0.5 Mbps) of **actual
  tested upload bandwidth** at the hosting location — test at
  speedtest.net and look at the upload number specifically, not the
  advertised download speed.
- Consider splitting **where** shards run: LAN-facing shards on local
  hardware (bandwidth is free since it never leaves the network), and
  remote-facing shards on a rented datacenter VPS (solves the home-upload
  bottleneck and usually costs less than building equivalent hardware
  yourself).

### Is CPU/RAM allocation "elastic"?

CPU already is, for free: Linux's scheduler shares CPU time dynamically —
a shard can burst above its "1 thread" baseline whenever the box has spare
capacity, and only gets proportionally throttled once there's real
contention. Nothing in this script imposes a hard per-shard CPU cap.

RAM is different: it's physically fixed. There's no elastic pool to draw
from the way a cloud auto-scaling group can spin up more VMs — this box
has whatever RAM it has. So instead of pretending to "auto-allocate more,"
the installer gives you **visibility** so you can make that call yourself:

- **Before adding a new shard**, it samples current CPU/RAM utilization
  and warns (asking for confirmation) if the host is already running hot
  — the healthy target range is **40-80%** utilization. Below 40%, you're
  told there's comfortable headroom; at/above 80%, it suggests lowering a
  busy shard's `MAX_PLAYERS`, moving a shard to different hardware, or
  provisioning the new one elsewhere instead.
- **`host-capacity-monitor.sh`** runs every 15 minutes via cron, logging
  utilization to `/srv/valheim/host-capacity.log` and flagging it only
  after several consecutive high readings (avoiding false alarms from a
  brief spike) — a sustained warning there is your cue to act.

### Why is the journald cap 500MB, and does it scale?

It scales automatically: `configure_journald_limit` sets it to a 500MB
floor plus 150MB per registered shard (capped at 8GB), and re-runs on
every `--add-instance` so it keeps up as your fleet grows. There's no
downside to a higher ceiling — `SystemMaxUse` is a cap, not a
pre-allocation, so unused headroom costs nothing — and a bigger fleet
benefits from more retained troubleshooting history per shard. If you
customize `SystemMaxUse` by hand, the installer detects that (via a
marker comment it leaves on its own managed value) and leaves your
setting alone from then on.

---

## Uninstalling

```bash
./install-valheim-server.sh --uninstall
```

Stops/disables every shard, removes the systemd template, cron, logrotate
config, and every shard's firewall rules. Then asks (separately, once)
whether to also delete all game data. fail2ban is deliberately left in
place.

To remove just one shard instead: `--remove-instance <name>`.

---

## Troubleshooting

- **Full install log**: `/var/log/valheim-install.log`
- **A shard fell back to vanilla unexpectedly**: search the install log for
  that shard's name in brackets, e.g. `[shard2]` — the exact reason is
  always logged, never silent.
- **Port not listening right after adding a shard**: a brand-new world can
  take a minute or two to generate. Check again with
  `status-valheim.sh <name>`.
- **Shard won't start**: `journalctl -u valheim@<name> -n 100 --no-pager`

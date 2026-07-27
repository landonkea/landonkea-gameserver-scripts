# Multi-Game Dedicated Server Platform

A single Bash installer that deploys and manages dedicated server
instances for **multiple different games** on one Ubuntu Server LTS host
— no manual setup, no terminal that has to stay open, and adding a new
game means writing one small profile file, never touching the core script.

Bundled games (29 total): **Terraria, Project Zomboid, Rust, Team
Fortress 2, Garry's Mod, Left 4 Dead 2, Counter-Strike 2, Killing Floor 2,
Squad, Arma 3, DayZ, Insurgency: Sandstorm** (native Linux, via SteamCMD);
**Factorio, Core Keeper, Satisfactory, ARK: Survival Evolved, Conan
Exiles, 7 Days to Die, Palworld, Unturned, OpenTTD** (more native Linux
games, various download/config styles); **Minecraft Java Edition,
Mindustry** (not on Steam, both run on a JVM); and **Enshrouded, Space
Engineers, Astroneer, ARK: Survival Ascended, V Rising, Empyrion**
(Wine-tier — Windows-only binaries run through Wine). See
[`PROFILE-AUTHORING.md`](PROFILE-AUTHORING.md) to add more, and
[`../HOW-TO-READ-THIS-CODE.md`](../HOW-TO-READ-THIS-CODE.md) if you're new
to reading code at all.

---

## Requirements

- Ubuntu Server, any current LTS release (auto-detected).
- x86_64 CPU.
- RAM/disk sized for whichever games/instances you actually run — this
  varies enormously by game (Terraria needs very little; ARK-family games
  can need 20GB+ RAM per instance). Check each profile's own guidance.

---

## Quick Start

**Not sure this server is ready? Check first, without changing anything:**

```bash
chmod +x install-game-server.sh
./install-game-server.sh --check --game terraria
```

This confirms Ubuntu, architecture, internet, RAM, and disk space — and,
with `--game`, that specific game's own RAM recommendation and whether it
needs Wine — without installing or changing a single thing. Safe to run
as many times as you like, and doesn't need `sudo`.

```bash
chmod +x install-game-server.sh
./install-game-server.sh --game terraria --add-instance myworld
```

`sudo` is applied automatically if you don't run it yourself.

```bash
# See what's available
./install-game-server.sh --list-games

# Add another instance (same or different game)
./install-game-server.sh --game rust --add-instance myrustserver

# List everything running
./install-game-server.sh --list-instances

# Remove one instance / everything
./install-game-server.sh --remove-instance myworld
./install-game-server.sh --uninstall
```

---

## Architecture

```
/srv/gameservers/
├── steamcmd/                    (shared — one SteamCMD for every game)
├── golden/<game>/                (one shared download PER GAME)
├── scripts/
│   ├── common.sh                 (generic instance/profile loading, logging)
│   ├── profiles/*.profile.sh     (one small file per game — see below)
│   └── *-instance.sh              (generic backup/restore/update/healthcheck/status/logs)
├── instances/<name>/
│   ├── config.env                 (which game + this instance's settings, mode 600)
│   ├── server/                    (synced from golden/<game>/, plus any per-instance
│   │                                additions like a Wine prefix or symlinked save path)
│   ├── data/                      (world/save data — always what gets backed up)
│   ├── backups/  logs/  tmp/
└── instances.registry             (name:game:port:created)
```

**Why this split:** everything above the `profiles/` line — SteamCMD,
systemd templating, backups, firewall, fail2ban, log rotation, host
capacity monitoring, sudo auto-elevation — is written once and never
touched when a new game is added. Each game is a **profile**: a small file
declaring its Steam App ID, whether it needs Wine, its ports, and two
functions (how to build its launch command, what config questions to
ask). See `PROFILE-AUTHORING.md` for the full contract.

---

## The Wine Tier

A handful of popular titles — **ARK: Survival Ascended, Enshrouded, Space
Engineers, Astroneer** among them — have no native Linux dedicated server
at all; the only way to run them on Linux is through Wine. This is
genuinely a different, more fragile category of engineering than a native
binary: expect higher CPU overhead, and BattlEye-based anti-cheat (as used
by ARK: Survival Ascended) does not work under Wine at all — that
instance runs without anti-cheat, a real trade-off worth knowing about
before inviting people to it.

The framework handles this transparently: set `PROFILE_REQUIRES_WINE=1` and
`PROFILE_STEAM_PLATFORM="windows"` in a profile, and the core installs Wine
(only the first time it's actually needed) and wraps the launch in
`xvfb-run` + `wine64` with a per-instance `WINEPREFIX`, so multiple
Wine-based instances never share Wine state. Profiles never deal with Wine
directly — all four Wine-tier games above are now built; `enshrouded.profile.sh`
has the most detailed explanatory comments if you're adding a fifth.

---

## Non-Steam Games

Not every game is on Steam — Minecraft is downloaded directly from Mojang.
A profile signals this by leaving `PROFILE_STEAM_APPID=""` and
implementing `profile_custom_download()` to fetch the game its own way;
the core framework calls that instead of SteamCMD, for both the initial
install and later updates. Everything else (backups, on-demand sleep/wake,
firewall, monitoring) works identically either way. Games needing a JVM
instead of a native binary or Wine (again, Minecraft) set
`PROFILE_REQUIRES_JAVA=1`, and the framework installs a JVM automatically,
only when actually needed. `minecraft.profile.sh` is the template for
this pattern (also useful for Factorio, which similarly offers a direct
non-Steam download).

---

## On-Demand Mode (Sleep Until Connected)

Any instance can be set to sleep until a player actually tries to connect,
instead of running 24/7. Offered as a yes/no prompt (default: yes) during
`--add-instance`.

**How it works:** a lightweight listener (`socat`, a mature and widely-used
tool) sits on the instance's primary port while it's asleep. The first
connection/packet triggers the real server to start, and the listener gets
out of the way. A per-minute check then watches for **5 consecutive idle
minutes** — using a precise player-count query if the game's profile
provides one, or a `conntrack`-based "any recent traffic" heuristic
otherwise — and when idle, triggers an optional save hook and stops the
server, going back to sleep.

**Two honest limitations, not glossed over:**
- **The first join attempt after waking a sleeping server will likely need
  a retry.** Nothing was actually listening to complete that first
  connection's handshake — it only triggered the wake-up. Depending on how
  long the game takes to boot (seconds for Terraria, up to a couple of
  minutes for a fresh world in other games), the player may need to
  manually reconnect once it's up.
- **Idle detection is only as precise as the game allows.** A handful of
  profiles can query exact player count; for the rest, the traffic
  heuristic can occasionally misjudge a quiet-but-still-connected player as
  idle. If that's a concern for a specific instance, just answer "no" to
  the on-demand prompt for it.

`status-instance.sh` shows `sleeping` as a distinct state from
`active`/`inactive`. `stop-instance.sh` on a sleeping instance also
disables its listener (won't auto-wake until you restart it);
`restart-instance.sh` on a sleeping instance wakes it instead of trying to
restart something that isn't running.

---

## Interactive Prompts

Every instance is asked (regardless of game): instance name, base port,
backup retention/directory/schedule, and update-check time. Each game
profile then asks whatever it specifically needs (world name, max
players, password, map seed, etc.) — see that profile's file for its exact
questions.

---

## Managing Instances

```bash
systemctl status  gameserver@myworld
systemctl restart gameserver@myworld
journalctl -u gameserver@myworld -f
```

| Script | Usage |
|---|---|
| `status-instance.sh [name]` | One instance's detail, or a summary table of all (default) |
| `logs-instance.sh <name> [service\|backup\|update]` | Tail the relevant log |
| `stop-instance.sh` / `restart-instance.sh` `<name\|all>` | |
| `backup-instance.sh <name\|all>` | Manual backup |
| `restore-instance.sh <name> <backup.zip>` | Restore from a backup (keeps a safety copy first) |
| `update-instance.sh <name\|all>` | Validates the shared golden install, re-syncs + restarts |
| `healthcheck-instance.sh <name\|all>` | Manual health check (auto-restarts if run as root) |
| `manual-foreground-start.sh <name>` | Foreground debugging as the `gameserver` user |
| `cpu/ram/disk/smart/network-status.sh` | Host-wide resource usage |
| `host-capacity-monitor.sh` | Runs every 15 min via cron; flags sustained high CPU/RAM |

Every script auto-elevates with `sudo` if needed — you never have to
remember it.

---

## Scheduling, Security, Sizing

These all work exactly as in the original single-game version of this
platform: a per-minute dispatcher lets every instance keep its own
independently-chosen backup/update time without per-instance cron entries;
UFW opens only what each game's profile declares (`profile_port_specs`)
plus rate-limited SSH; fail2ban bans repeated SSH failures with escalating
ban times; `journald` is capped at a size that scales with fleet size;
and a pre-flight capacity check warns before adding a new instance to an
already-hot host, backed by continuous monitoring rather than a
non-existent "auto-allocate more hardware" mechanism.

---

## Reliability

A few things aimed specifically at "this should just work, unattended":

- **`--check`** (see Quick Start above) validates a server before you
  commit to a real install.
- **Per-game RAM recommendations.** Every profile can optionally state a
  recommended minimum (`PROFILE_RECOMMENDED_RAM_MB`) — if the host has
  less, `--add-instance` warns clearly and asks for confirmation before
  proceeding (or just warns and continues in `-y` mode). This is advisory,
  not a hard block — a heavy game on a small server will still install if
  you confirm you want that, but you won't discover the mismatch only
  after something crashes under real load.
- **Every network download retries automatically** — SteamCMD, Mojang's
  API, GitHub's API, Factorio's and OpenTTD's direct downloads all go
  through a shared `curl_with_retry` helper (3 attempts, short delay
  between them), so a brief network hiccup doesn't fail an install that
  would have worked a few seconds later.
- **A failed install cleans up after itself.** If setting up a new
  instance fails partway through, before it's been fully registered, the
  half-created directory is automatically removed. Once an instance is
  registered, a later failure never touches its data.

## Troubleshooting

- **Full install log**: `/var/log/gameserver-install.log`
- **An instance won't start**: `journalctl -u gameserver@<name> -n 100 --no-pager`
  — for most profile issues this shows the game's own config-parse error
  directly.
- **Backups look empty**: check that the game's profile is actually
  writing/symlinking save data into `INSTANCE_DATA_DIR` — see
  `PROFILE-AUTHORING.md`'s note on this exact failure mode.
- **A Wine-based game won't start**: `manual-foreground-start.sh <name>`
  and watch for Wine's own error output; Wine issues are the most likely
  failure point for that tier specifically.

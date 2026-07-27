# Adding a New Game Profile

Adding a game to this platform means writing **one file** — nothing in
`install-game-server.sh` itself ever needs to change. Drop your file in
`profiles/<game_id>.profile.sh`, and it's automatically picked up the next
time the installer runs (or copy it straight into
`/srv/gameservers/scripts/profiles/` on an already-running host and it's
usable immediately).

Copy `profiles/terraria.profile.sh` (simplest, native) or
`profiles/enshrouded.profile.sh` (Wine-based) as your starting point.

## Required variables

```bash
PROFILE_GAME_ID="mygame"          # matches the filename (mygame.profile.sh)
PROFILE_DISPLAY_NAME="My Game"    # shown to the admin
PROFILE_STEAM_APPID="123456"      # the dedicated server's Steam App ID
PROFILE_STEAM_PLATFORM="linux"    # "linux" or "windows" -- see below
PROFILE_REQUIRES_WINE=0           # 1 if this game has no native Linux server
PROFILE_PORT_COUNT=1              # how many consecutive ports this instance needs
```

**Finding the Steam App ID and platform**: search `<game name> dedicated
server steamcmd app id` — [SteamDB](https://steamdb.info) is the most
reliable source. If the game has no Linux depot, set
`PROFILE_STEAM_PLATFORM="windows"` and `PROFILE_REQUIRES_WINE=1` — the
framework installs Wine and wraps the launch automatically; you never
write Wine-handling code yourself.

**If the game isn't on Steam at all** (Minecraft, Factorio's direct
download): leave `PROFILE_STEAM_APPID=""` and implement
`profile_custom_download(golden_dir)` instead — download the server files
into `golden_dir` yourself (see `minecraft.profile.sh`, which uses
Mojang's public version-manifest API). The core calls this instead of
SteamCMD, for both the initial install and later updates.

**If the game needs a JVM instead of a native binary** (again, Minecraft):
set `PROFILE_REQUIRES_JAVA=1`. The framework installs a JVM automatically
(only the first time it's actually needed) and launches via
`java -jar <binary>` instead of executing the binary directly — you don't
need to handle this yourself, just make `profile_find_binary` return the
path to the `.jar`.

## Required functions

### `profile_port_specs()`
Print one `offset:protocol:description` line per port this game needs,
where `offset` is added to the instance's base port:

```bash
profile_port_specs() {
    echo "0:udp:game"
    echo "1:udp:query"
    echo "2:tcp:rcon"
}
```

### `profile_find_binary(search_dir)`
Print the full path to the server executable inside `search_dir`. Prefer
searching over hardcoding a path — Steam depot layouts shift between
versions:

```bash
profile_find_binary() {
    find "$1" -iname 'MyGameServer.bin.x86_64' 2>/dev/null | head -n1
}
```

For a Wine-based game, this points at the **Windows** `.exe` — the
framework runs it through Wine automatically based on
`PROFILE_REQUIRES_WINE`.

### `profile_gather_prompts()`
Ask whatever questions this game needs beyond the generic ones the core
already asks (instance name, port, backup schedule). Use the shared
prompt engine and validators:

```bash
profile_gather_prompts() {
    prompt_and_validate "World name" "MyWorld" validate_generic_safe_string MG_WORLD_NAME 0
    prompt_and_validate "Max players" "10" validate_generic_safe_string MG_MAX_PLAYERS 0
    PROFILE_EXTRA_CONFIG_VARS=(MG_WORLD_NAME MG_MAX_PLAYERS)
}
```

`PROFILE_EXTRA_CONFIG_VARS` is the array of variable names the generic
config writer persists into `config.env` — always set this, even if empty.

Available generic validators: `validate_generic_safe_string`,
`validate_generic_password`, `validate_yesno`, `validate_port`. Write your
own (like `validate_tr_world_size` in the Terraria profile) for anything
game-specific.

**Non-interactive (`-y`) mode**: check `$ASSUME_DEFAULTS` and either use a
sensible default or generate a random password — never leave a variable
unset, since `-y` must still complete without a terminal. See any bundled
profile's password-handling block for the pattern.

### `profile_build_launch_args()`
Called right before launch (by the generated `start-instance.sh`, with
`INSTANCE_NAME`/`INSTANCE_SERVER_DIR`/`INSTANCE_DATA_DIR`/`SERVER_PORT`/
your own `config.env` variables all already in scope). Populate the
`LAUNCH_ARGS` array with what to pass to the binary, and write any config
file this game needs:

```bash
profile_build_launch_args() {
    cat > "${INSTANCE_DATA_DIR}/config.json" << CFG
{ "port": ${SERVER_PORT}, "maxPlayers": ${MG_MAX_PLAYERS} }
CFG
    LAUNCH_ARGS=(-config "${INSTANCE_DATA_DIR}/config.json")
}
```

**Important — where save data goes**: the platform's backup/restore
mechanism always backs up `INSTANCE_DATA_DIR`. If the game supports a
"save data goes here" flag (most do), point it there directly. If it
doesn't — some games nest saves inside their own install directory (see
Rust's `+server.identity` for a worked example) — symlink the game's
expected internal path to `INSTANCE_DATA_DIR` inside
`profile_build_launch_args`, idempotently (check `[[ -L ... ]]` first).
This is the single most important thing to get right in a new profile;
get it wrong and backups will silently be empty.

## Optional variable

### `PROFILE_RECOMMENDED_RAM_MB`
A best-effort recommended minimum, in megabytes. If set, `--add-instance`
compares it against the host's actual RAM and warns clearly (asking for
confirmation interactively, or just warning in `-y` mode) if the host has
less. This is advisory only — it never blocks an install outright. Not
every profile needs to set this; skip it if you're not confident in a
specific number for your game.

## Optional functions

### `profile_pre_launch_setup()`
For games that don't take config via file or arguments and are instead
driven by typing commands at an interactive console (Mindustry is the
example) -- runs right before the process is exec'd, in the same shell,
so anything you background here survives the exec (which replaces the
process image but doesn't kill already-started children) and lands in the
same systemd cgroup, stopping cleanly together with the real server. See
`mindustry.profile.sh` for the full pattern: create a named pipe,
background a process to hold its write side open (so the exec'd
process's stdin never sees EOF), redirect this shell's own stdin to the
pipe, and schedule your startup commands to be written to it once the
server's had time to initialize.

### `profile_post_start_notes()`
Extra lines appended to the completion summary — use this for anything a
first-time admin of this specific game should know (Terraria's TCP-not-UDP
note, Enshrouded's Wine-overhead note, etc.).

### `profile_get_player_count()`
Used by the on-demand idle monitor. If your game supports querying current
player count (RCON, a query protocol, a status file), implement this to
echo a plain number. Without it, idle detection falls back to a
`conntrack`-based "any recent traffic" heuristic, which is approximate —
implementing this precisely is worth doing if the game makes it possible.

```bash
profile_get_player_count() {
    # example: RCON-based count for a game with an RCON console
    echo "playercount" | mcrcon-style-client "$RCON_PASSWORD" "127.0.0.1" "$RCON_PORT" 2>/dev/null \
        | grep -oP '\d+' | head -n1
}
```

### `profile_trigger_save()`
Called by the idle monitor right before stopping an idle on-demand
instance. If your game has an explicit save command (RCON `save`,
a console command, etc.), implement this to call it. Without it, the
platform relies solely on the graceful stop signal to trigger the game's
own save-on-exit behavior, which is not guaranteed for every game.

---

## The On-Demand System

Any instance can be configured (during `--add-instance`) to sleep until a
player connects, and auto-save + auto-stop after 5 idle minutes. This is a
generic, game-agnostic core feature — profiles don't need to do anything
to support the *sleep/wake* mechanism itself (it works via a `socat`
listener sitting on the instance's primary port); the two hooks above are
just how a profile can make the *idle detection* precise instead of
heuristic. See the main README for the full behavior and honest caveats
(the first join attempt after waking usually needs a retry; the traffic
heuristic can occasionally misjudge a quiet-but-connected player as idle).

## Testing a new profile before trusting it

1. `bash -n profiles/mygame.profile.sh` — syntax check.
2. `./install-game-server.sh --list-games` — confirms the contract
   (required variables/functions) is satisfied; a missing piece fails
   loudly here with a clear message, not a mysterious crash later.
3. `./install-game-server.sh --game mygame --add-instance test1` on a
   real (or disposable VM) host — the only way to confirm the exact
   binary name, config schema, and port numbers are actually correct,
   since these details can't be verified without the real game files.
4. Check `/srv/gameservers/instances/test1/logs/` and
   `journalctl -u gameserver@test1 -n 100` if it doesn't come up —
   almost always a config-file or launch-argument mismatch, visible
   directly in the game's own error output.

## A note on confidence

Every bundled profile's file header states plainly which facts are
well-established versus best-effort (exact config file keys are the most
common thing that drifts between game updates). Do the same in any new
profile you write — a clear "this part is my best understanding, verify
it" comment saves the next person real debugging time.

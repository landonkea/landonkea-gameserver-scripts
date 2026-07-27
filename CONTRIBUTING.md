# Contributing

Thanks for taking a look at this project. It's two related tools: a
standalone Valheim installer (`valheim/`), and a general multi-game
platform (`multi-game-platform/`) where each game is a small "profile"
plugging into a shared core.

## Before you do anything else

Read `HOW-TO-READ-THIS-CODE.md` if bash isn't already familiar — every
recurring pattern in this codebase is explained there in plain English.

## Reporting a problem

Please include:
- Which script (`install-valheim-server.sh` or `install-game-server.sh`)
  and, for the platform, which `--game`.
- Your Ubuntu version (`lsb_release -a`).
- The relevant section of `/var/log/gameserver-install.log` (or
  `/var/log/valheim-install.log`), or the specific error shown on screen.
- Whether it's a fresh install or an existing instance.

## What's most worth testing right now

This project has been extensively tested in a sandboxed mock environment
(fake SteamCMD responses, a hand-verified RCON protocol implementation,
real interactive prompt tests) but **not against real Steam servers, real
Wine, or real hardware** — that requires an actual Ubuntu box, which
wasn't available during development. If you're reviewing this, the
highest-value things to check on a real disposable VM, roughly in order:

1. **The four Wine-tier profiles** (`enshrouded`, `spaceengineers`,
   `astroneer`, `arksurvivalascended`) — Wine is the most fragile part of
   this whole platform by nature, and `astroneer.profile.sh` in
   particular is flagged in its own header as the least-certain profile
   here.
2. **Minecraft's RCON client** (`minecraft.profile.sh`'s `mc_rcon`
   function, and `teamfortress2.profile.sh`'s equivalent) — the wire
   protocol was verified against a hand-written test server during
   development, but never against a real Minecraft/Source server.
3. **Any profile's exact config file keys** — every profile's header
   comment states plainly whether its config format is "long-stable,
   high confidence" or "best understanding, may need adjusting." Start
   with the ones honestly flagged as lower-confidence.
4. **A full fresh-install-to-uninstall cycle** on a genuinely clean
   Ubuntu LTS cloud image (DigitalOcean/AWS/Linode's default minimal
   image) — this project's testing was done in a general-purpose sandbox,
   not a minimal cloud image specifically, so package assumptions are
   worth double-checking there.

## Adding a new game to the multi-game platform

See `multi-game-platform/PROFILE-AUTHORING.md` — it's a complete,
self-contained guide. In short: copy the closest existing profile to the
game you're adding (there's a template noted in this project for each of:
native Linux, Wine-based, non-Steam/JVM-based, and console-driven), fill
in the App ID/launch convention/config format, and test with:

```bash
bash -n profiles/yourgame.profile.sh          # syntax
./install-game-server.sh --list-games          # confirms the required contract is satisfied
./install-game-server.sh --game yourgame --add-instance test1   # the real test, on a disposable VM
```

## Before submitting a change

- `bash -n` every file you touched (no syntax errors).
- If you touched the core framework (`install-game-server.sh` or
  `install-valheim-server.sh`), re-run `--list-games` (platform) or a full
  install (Valheim) to confirm nothing regressed.
- Watch specifically for `[[ condition ]] && action` as the *last*
  statement in a function — if `condition` can ever be false, this
  pattern makes the function return a failing exit code, which (under
  `set -e`, active throughout both scripts) can silently abort whoever
  called it. Use `if [[ condition ]]; then action; fi` instead. This
  exact bug was found and fixed in three profiles during development —
  it's the single most likely subtle mistake to reintroduce here.

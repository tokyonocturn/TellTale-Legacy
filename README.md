# Telltale Legacy

Offline preservation and compatibility work for **legitimately owned** Telltale games.

Telltale Legacy documents how each game actually works, verifies what still works
without a network, and provides tooling that protects player state across the
platform changes that have already broken parts of these games. It is not a
launcher, a crack, or a content distribution project.

> **Scope boundary:** the Steam DRM wrapper in these builds is never bypassed,
> patched, or emulated. A real licence and the Steam client remain mandatory. See
> [docs/legal-boundaries.md](docs/legal-boundaries.md).

---

## Current status

| Item | Value |
| --- | --- |
| Title | The Walking Dead (Season 1) |
| Steam app id | 207610 (depot 207611) |
| Installed build | 244978 |
| Executable | `WalkingDead101.exe` (x86, linked 2014-04-25) |
| Engine | Telltale Tool, Lua 5.1.4, FMOD Ex, Direct3D 9 |
| Content | 112 `ttarch` v9 archives, 3.55 GiB, 5 content groups |
| Milestone 1 | **complete** — inventory, profile, offline startup verified, backup/restore verified |

Full analysis: [forensic inventory](docs/rea/01-forensic-inventory.md),
[engine architecture](docs/rea/02-engine-and-architecture.md),
[startup sequence](docs/rea/03-startup-sequence.md),
[online dependencies](docs/rea/04-online-dependencies.md),
[save architecture](docs/rea/05-save-architecture.md),
[preservation requirements](docs/rea/06-preservation-requirements.md).

## What was actually verified

Not claims — measured on the installed build, with logs:

* **Offline startup works.** With the game's only publisher endpoint
  (`api.telltalegames.com`) blackholed, a Steam-launched session reached the main
  menu (`PLAY / EPISODE STATUS / SETTINGS / EXIT GAME`) and held **zero remote
  network endpoints**. The menu shows a static news banner instead of live news.
* **The game has exactly one non-Steam online dependency in its startup path.**
  During a normal launch it resolves and connects to `api.telltalegames.com:443`
  (CloudFront). Nothing else in the startup path talked to a game-owned endpoint.
* **Direct execution is not supported by design.** Starting the executable directly
  exits with code `53` after `SteamAPI_RestartAppIfNecessary`, and Steam relaunches
  it. Launch through Steam (`steam://rungameid/207610`) is the supported route.
* **Per-user state is created on first launch** in
  `%USERPROFILE%\Documents\Telltale Games\The Walking Dead\` (`prefs.prop`,
  `steam_autocloud.vdf`).
* **Backup and restore are hash-verified end to end**, including tamper rejection
  and non-destructive pre-restore snapshots.

Not yet verified (do not assume): gameplay progression past the main menu, save
slot creation through play, episode transitions, a full machine-offline Steam
Offline Mode session, and any release other than this Steam build.

## Repository layout

```
profiles/                 Version-specific compatibility profiles (facts + expectations)
  twd-s1-steam-207610/
tools/                    Preservation tooling (PowerShell 5.1, no external dependencies)
  Get-GameInventory.ps1   Read-only forensic inventory: hashes, PE, archive headers
  Test-OfflineReadiness.ps1  Audits an install against a profile
  Backup-GameProfile.ps1  Hash-verified snapshot of per-user state (never game content)
  Restore-GameProfile.ps1 Verified restore with pre-restore safety copy
  Start-ObservedSession.ps1  Launches/attaches and records session evidence
  Invoke-OfflineProbe.ps1 Reversible hosts-level API block for offline testing
tests/                    Automated tests for the tooling (synthetic fixtures)
docs/                     REA findings, architecture, installation, legal boundaries
```

## Quick start

```powershell
# 1. Is this installation ready, and is it the build the profile expects?
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Test-OfflineReadiness.ps1

# 2. Protect existing saves before doing anything
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Backup-GameProfile.ps1 -Label before-testing

# 3. Observe a real session (launches through Steam, records evidence, closes it)
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Start-ObservedSession.ps1 `
    -ViaSteam -Label baseline -ObservationSeconds 60 -StopAtEnd

# 4. Run the test suite
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-Tests.ps1
```

Offline testing with the publisher API blocked (needs an elevated shell for the
hosts entry, and removes it again afterwards):

```powershell
.\tools\Invoke-OfflineProbe.ps1 -Action Block     # elevated
.\tools\Start-ObservedSession.ps1 -ViaSteam -Label offline -ObservationSeconds 75
.\tools\Invoke-OfflineProbe.ps1 -Action Unblock   # elevated
```

See [docs/installation.md](docs/installation.md) for prerequisites and details.

## Findings that shape the preservation strategy

1. **Steam is the gate, not Telltale.** The executable carries a `.bind` section
   (Steam DRM stub) and imports `steam_api.dll` (`SteamClient012`/`SteamUser016`).
   Legitimate offline play therefore means Steam Offline Mode with a cached
   licence — not a patched binary.
2. **The Telltale account API is optional at startup.** It is contacted during the
   splash, but the game still reaches the main menu when it is unreachable. Only
   live news and episode-status information degrade.
3. **Achievements are online-only.** Steam stats/achievements
   (`com.telltalegames.<episode>.ch.<NN>`) cannot unlock while Steam is offline;
   gameplay and saves are unaffected.
4. **Saves are local and small.** State lives in the per-user Documents folder, so
   it is easy to protect, diff and restore — and easy to lose if a reinstall or a
   profile change happens without a backup.
5. **Content is layered, not monolithic.** Episode directories overlay `default`
   with numbered patch archives (`0_*`) taking precedence, which is what makes
   per-episode compatibility profiles possible.

## Roadmap

* Milestone 2 — drive a new game to a real save slot and verify dialogue,
  branching choice persistence and episode transitions offline.
* Milestone 3 — full machine-offline run (Steam Offline Mode) with evidence, plus
  a save-format reader for progression inspection (no asset extraction).
* Later — Season 2, 400 Days, and the Definitive Series as **separate** profiles;
  the engine is shared but content layout and DRM differ.

## Legal

Telltale Legacy ships no game code, assets, archives, or save data. Tools only read
an installation you already own, and write backups to your own machine. Telltale
Legacy does not circumvent Steam DRM, authentication, licensing, or access
controls. Read [docs/legal-boundaries.md](docs/legal-boundaries.md) before use.

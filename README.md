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
| Milestone 2 | **complete** — real gameplay saved, closed, restarted and resumed with the publisher API blocked |
| Milestone 3 | **blocked** — offline launch with both publisher domains blocked, Episode 2 content verified present; Episode 1 completion and the transition need an attended playthrough |
| Playthrough (automated) | **in progress, stopped** — real input drives the game (click-and-hold walks, Esc menus, synthetic WASD does not move Lee); reached Episode 1 “Chapter 2: In The Yard” and replayed it from the chapter start, no story progress beyond its opening shot |
| Audio | **identified, not routed** — `100027813` resolved to `{63b45a0d-…}` (three stale same-named endpoints rejected); game audio measured on the default endpoint after raising the silent `SOUND 0`, but Windows accepts and then ignores the per-app override, measured against a control process |

Full analysis: [forensic inventory](docs/rea/01-forensic-inventory.md),
[engine architecture](docs/rea/02-engine-and-architecture.md),
[startup sequence](docs/rea/03-startup-sequence.md),
[online dependencies](docs/rea/04-online-dependencies.md),
[save architecture](docs/rea/05-save-architecture.md),
[preservation requirements](docs/rea/06-preservation-requirements.md),
[save container and slots](docs/rea/07-save-and-slot-format.md),
[offline gameplay verification](docs/rea/08-offline-gameplay-verification.md),
[400 Days and achievements](docs/rea/09-400-days-and-achievements.md),
[episode transition](docs/rea/10-episode-transition.md),
[audio routing](docs/rea/11-audio-routing.md),
[gameplay automation](docs/rea/12-gameplay-automation.md).

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
* **A real session survives offline.** Ep1 was played under the API block, wrote
  `save_1/5/6.save` plus `prefs.prop`, exited cleanly, and then — twice — the game
  listed the slot as `Game 1 — Episode 1 — 05/11/26 16:53:35`, resumed the saved
  checkpoint on CONTINUE, and held **zero TCP connections** throughout. See
  [docs/rea/08-offline-gameplay-verification.md](docs/rea/08-offline-gameplay-verification.md).
* **Episode content is verified present, not assumed.** All five packs exist with
  27/25/21/22/17 archives (`tools/Test-ContentPacks.ps1`).
* **The game is drivable with real input, and its controls were measured, not
  assumed.** Click-and-hold on the ground walks Lee; `Esc` opens the pause menu;
  synthetic WASD moves nothing. Menus, slot selection, chapter select and rewind
  were all driven this way. See
  [docs/rea/12-gameplay-automation.md](docs/rea/12-gameplay-automation.md).
* **The save container is opaque.** Magic `bbdeaf64`, a 56-byte header, then a
  per-file keystream: entropy 7.99, incompressible, no repeating key out to 4,096,
  XOR of two saves yields noise. No chapter or choice identifier is readable, so
  no decoding is claimed ([doc 07](docs/rea/07-save-and-slot-format.md)).

Not yet verified (do not assume): the Episode 1 → 2 transition (needs a full
playthrough), 400 Days (content not installed), achievement unlocks with Steam
offline, the semantic content of persisted choices, a full Steam Offline Mode
session, and any release other than this Steam build.

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
  Get-SaveArtifacts.ps1   Save container inventory, byte diff and drift detection
  Test-ContentPacks.ps1   Verifies every profile episode has archives on disk
tests/                    Automated tests for the tooling (synthetic fixtures)
docs/                     REA findings, architecture, installation, legal boundaries
  verification-scenarios.json  Which claims are automated vs attended gameplay
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

# 4. What does the save folder actually contain, and did anything move?
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Get-SaveArtifacts.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Get-SaveArtifacts.ps1 `
    -BaselinePath docs\rea\data\save-artifacts.json   # exit 0 identical, 3 = drift

# 5. Is every episode's content really installed?
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Test-ContentPacks.ps1

# 6. Run the test suite
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
4. **Saves are local and small, but not readable.** State lives in the per-user
   Documents folder, so it is easy to protect, diff and restore — and easy to lose
   if a reinstall or a profile change happens without a backup. The files are
   obfuscated, so tooling protects them as opaque bytes and does not pretend to
   interpret decisions.
5. **Content is layered, not monolithic.** Episode directories overlay `default`
   with numbered patch archives (`0_*`) taking precedence, which is what makes
   per-episode compatibility profiles possible.

## Roadmap

* Milestone 3 — Episode 1 completion and the Episode 2 transition offline; blocked
  on an attended playthrough because the game has no chapter select (see
  [the transition analysis](docs/rea/10-episode-transition.md)). Also pending: a
  full machine-offline run with Steam itself in Offline Mode.
* Milestone 4 — save-container research (keystream/compression identification) so
  decisions can be verified by content rather than behaviour, without extracting
  assets.
* Later — Season 2, 400 Days, and the Definitive Series as **separate** profiles;
  the engine is shared but content layout and DRM differ.

## Legal

Telltale Legacy ships no game code, assets, archives, or save data. Tools only read
an installation you already own, and write backups to your own machine. Telltale
Legacy does not circumvent Steam DRM, authentication, licensing, or access
controls. Read [docs/legal-boundaries.md](docs/legal-boundaries.md) before use.

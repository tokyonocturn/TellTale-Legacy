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
| Milestone 1 | **complete**: inventory, profile, offline startup verified, backup/restore verified |
| Offline dependencies | **mapped**: one compiled-in publisher URL (`https://meta.telltalegames.com/1/`), a persistent `Established` TLS socket to `api.telltalegames.com` during play, no other endpoints. 400 Days is not installed |
| Offline acceptance | **verified per episode**: with `api`/`meta.telltalegames.com` blocked, Episodes 2, 3, 4 and 5 each load into a live scene and take real input (movement, widgets, dialogue) at zero remote connections, and Episode 1's finale plays from an existing save. Not proven: Episode 1's credits, the ending-driven 1 → 2 transition, downstream branching. 400 Days is not installed |
| Offline launch wait | **fixed and measured**: when the machine has no internet route the client used to leave the game unlaunched for a minute or more; with Steam in Offline Mode under the same cut-off the frontend is usable in 11.6 s (`tools/Set-SteamOfflineMode.ps1`, [doc 19](docs/rea/19-offline-launch-stall.md)) |
| Milestone 2 | **complete**: real gameplay saved, closed, restarted and resumed with the publisher API blocked |
| Milestone 3 | **blocked**: offline launch with both publisher domains blocked, Episode 2 content verified present; Episode 1 completion and the transition need an attended playthrough |
| Playthrough (automated) | **partial**: the driver's two defects (26 px window/client offset, presses without a preceding mouse-move) are fixed. Episode 1's finale was then driven offline to its last scene and Episodes 2–5 were each started and advanced by injected input; Episode 1's credits and the ending-driven transition remain open ([doc 18](docs/rea/18-multiepisode-offline-run.md)) |
| Audio verification | **re-checkable**: `tools/Assert-AudioDelivery.ps1` resolves the endpoint by device id, refuses any fallback, and returns a named verdict with a distinct exit code (`endpoint-missing`, `endpoint-inactive`, `no-signal-on-target`, `default-changed`, `mirror-not-running`). Verified during live play at 0.474 peak with the default unchanged |
| Audio | **routed and measured**: silence was the game's own `VOICE/MUSIC/SOUND` all at 0 (now 10/10/10); the endpoint renders (direct WASAPI tone meters 0.5) but Windows ignores per-app redirection, so a loopback mirror carries the stream to `100027813`: target peaks 0.14–0.77 during dialogue and cinematics while headphones stay at their unrelated floor, across a restart and a chapter change. Default device unchanged |

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
[gameplay automation](docs/rea/12-gameplay-automation.md),
[audio delivery](docs/rea/13-audio-delivery.md),
[session evidence](docs/rea/14-session-evidence.md),
[offline dependency map](docs/rea/15-offline-dependency-map.md),
[offline acceptance matrix](docs/rea/16-offline-acceptance-matrix.md),
[offline acceptance run](docs/rea/17-offline-run.md),
[multi-episode offline run](docs/rea/18-multiepisode-offline-run.md),
[offline launch stall](docs/rea/19-offline-launch-stall.md).

## What was actually verified

Not claims, measured on the installed build, with logs:

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
  `save_1/5/6.save` plus `prefs.prop`, exited cleanly, and then, twice, the game
  listed the slot as `Game 1 - Episode 1 - 05/11/26 16:53:35`, resumed the saved
  checkpoint on CONTINUE, and held **zero TCP connections** throughout. See
  [docs/rea/08-offline-gameplay-verification.md](docs/rea/08-offline-gameplay-verification.md).
* **The game's audio reaches `100027813` by measurement.** A loopback mirror
  (`tools/Start-AudioMirror.ps1`) carries the default endpoint's stream to it and the
  endpoint's own meter shows 0.40 while the game shows 0.45; `tools/Test-AudioEndpoint.ps1`
  proves the endpoint renders at all. See
  [docs/rea/13-audio-delivery.md](docs/rea/13-audio-delivery.md).
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

## Offline launch patch, per game

One patch entry point, one profile per game. Each patch puts Steam in Offline Mode so an
offline launch does not wait for a connection that is not there, and pins that build's
publisher endpoint to loopback so a blocked startup call fails immediately instead of timing
out. Both steps revert byte-for-byte, and a build whose executable hash does not match the
profile is refused rather than patched.

| Game | App id | Build | Profile | Tag | Launch measured |
|---|---|---|---|---|---|
| Season 1 | 207610 | 244978 | `twd-s1-steam-207610` | `twd-s1-v1.0.0` | **verified**, 11.63 s |
| Season Two | 261030 | 1298753 | `twd-s2-steam-261030` | `twd-s2-v1.0.0` | not yet measured |
| A New Frontier | 536220 | 2784143 | `twd-s3-steam-536220` | `twd-s3-v1.0.0` | not yet measured |
| Michonne | 429570 | 1094475 | `twd-michonne-steam-429570` | `twd-michonne-v1.0.0` | not yet measured |
| The Final Season | 866800 | 3679591 | `twd-s4-steam-866800` | `twd-s4-v1.0.0` | not yet measured |
| Definitive Series | 1449690 | 5952618 | `twd-definitive-steam-1449690` | `twd-definitive-v1.0.0` | **verified**, 18.54 s |

```powershell
# read-only: install present, build hash match, endpoint pins, client mode
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Set-GameOfflinePatch.ps1 -Game twd-s2-steam-261030 -Action Status

# apply / revert one game (both need an elevated shell)
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Set-GameOfflinePatch.ps1 -Game twd-s2-steam-261030 -Action Install
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Set-GameOfflinePatch.ps1 -Game twd-s2-steam-261030 -Action Remove
```

The endpoint each build contacts was read from its own executable, not assumed: Seasons 2 to
4 and Michonne use `services.telltalegames.com`, while Season 1 uses `api` and
`meta.telltalegames.com`. Details, including what is measured and what is not, are in
[docs/rea/20-other-games-offline-patch.md](docs/rea/20-other-games-offline-patch.md).

## Preservation program (multi-game)

The Telltale work above is the origin of a broader program: the same method applied
to every owned installation, one profile at a time, with an explicit status per
capability and no claim without a measurement. The Telltale profiles, tools and
documents are unchanged; the program lives alongside them.

| Document | What it records |
| --- | --- |
| [Program and statuses](docs/preservation/00-program.md) | Scope, modes A/B/C, status vocabulary, registry and profile schemas, tools |
| [Inventory](docs/preservation/01-inventory.md) | Every owned installation: app id, build, size, engine, primary binary and hash |
| [Dependency map](docs/preservation/02-dependency-map.md) | Endpoints read out of each binary, mandatory or optional, plus the community landscape |
| [Renegade LAN host](docs/preservation/03-renegade-lan.md) | The first implementation milestone, including the five failures it fixed |

`registry/games.json` lists every title and its per-capability status;
`games/<id>/profile.json` holds the measured facts for one build. Adding a game
means adding those two files — no tool changes.

```powershell
# what is registered, installed, and how far each title has got
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Get-PreservationStatus.ps1

# measured facts for one installation (read-only)
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Get-PreservationInventory.ps1 -GameId cnc-renegade-steam-2229890

# fail-closed audit: install, build, binary hashes, mandatory dependencies
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Test-GameOfflineReadiness.ps1 -All

# Renegade: shipped dedicated server, LAN mode, no publisher infrastructure
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Start-RenegadeLanHost.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Start-RenegadeLanHost.ps1 -Status
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Stop-RenegadeLanHost.ps1
```

**Current state, stated plainly.** Twelve of the fourteen registered titles are
installed and inventoried; Red Alert 3 is a partial download and the Remastered
Collection has never been downloaded, so neither is analysed. Renegade's LAN host
is implemented and measured: it enters LAN mode, binds UDP 3373, creates a channel
and loads a map, with the installation unmodified. That is **not** `LAN VERIFIED`
— that needs a client to join and play, which needs a second machine. No title is
`OFFLINE VERIFIED` yet: offline acceptance runs are the next milestone. C&C4 is
`BLOCKED BY EXTERNAL DEPENDENCY` (EA Blaze account and server-side progression),
and Friday the 13th's multiplayer is blocked the same way since its backend closed
on 2024-12-31.

## Release packages

Each game is published as a self-contained zip on its tag's release: the shared tooling, the
documentation, that game's profile and a generated `PATCH.md` with the commands and the
verified/untested lists for that build. No other game's profile is included, and no game code,
assets, archives or saves are ever packaged.

```powershell
# one tag, built from that tag's own tree
.\tools\New-ReleasePackage.ps1 -ProfileId twd-s2-steam-261030 -Tag twd-s2-v1.0.0 -Commit twd-s2-v1.0.0

# every profile at the current commit
.\tools\New-ReleasePackage.ps1
```

Each published package is built from the tree of its own tag, so a release is a snapshot of that
tag rather than of current `main`: an older tag's package does not carry documents, profiles or
tools that were written after it, and its notes only link to documents it actually contains.
Files come from a commit, not from the working tree, so a zip always matches a state that
exists in git. The script refuses forbidden paths (backups, `dist`, `tools/scratch`,
`docs/rea/data`, logs) and any file over 4 MB, writes a manifest with a hash per file next to
the zip, and stamps entries with the commit's timestamp so the same commit rebuilds to the same
bytes.

Publishing is a second, idempotent step. It creates a missing release for a tag, rewrites the
notes when they no longer match the package, replaces stray or mismatched assets, and then
downloads every asset back from its public URL and compares the SHA-256 with the local file, so
"uploaded" and "served identically" are the same claim. The token comes from the git credential
helper and is never printed or written; running it a second time reports each tag as verified:

```powershell
.\tools\Publish-ReleasePackage.ps1 -DryRun          # show what would change
.\tools\Publish-ReleasePackage.ps1                  # reconcile all six releases
.\tools\Publish-ReleasePackage.ps1 -Tag twd-s2-v1.0.0
```

## Repository layout

```
profiles/                 Version-specific compatibility profiles (facts + expectations)
  twd-s1-steam-207610/
  twd-s2-steam-261030/
  twd-s3-steam-536220/
  twd-michonne-steam-429570/
  twd-s4-steam-866800/
  twd-definitive-steam-1449690/
tools/                    Preservation tooling (PowerShell 5.1, no external dependencies)
  Get-GameInventory.ps1   Read-only forensic inventory: hashes, PE, archive headers
  Test-OfflineReadiness.ps1  Audits an install against a profile
  Backup-GameProfile.ps1  Hash-verified snapshot of per-user state (never game content)
  Restore-GameProfile.ps1 Verified restore with pre-restore safety copy
  Start-ObservedSession.ps1  Launches/attaches and records session evidence
  Invoke-OfflineProbe.ps1 Reversible hosts-level API block for offline testing
  Get-SaveArtifacts.ps1   Save container inventory, byte diff and drift detection
  Test-ContentPacks.ps1   Verifies every profile episode has archives on disk
  Set-SteamOfflineMode.ps1  Puts Steam in Offline Mode so an offline launch does not wait
  Set-OfflineLaunchPatch.ps1  Pins the publisher hostnames to loopback (byte-reversible)
  Set-GameOfflinePatch.ps1  Applies, reports or reverts one game's patch after a build check
  Invoke-UnattendedRun.ps1  Drives an episode with nobody at the controls and logs what it saw
  New-ReleasePackage.ps1  Builds one self-contained zip and manifest per game profile
  Publish-ReleasePackage.ps1  Publishes each package as its tag's release and verifies the bytes
  Measure-LaunchLatency.ps1  Times a launch to a usable frontend by driving it
  classify_frame.py       Frame measurement helper used by the latency instrument
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

# 5. Playing with no internet? Put the client in Offline Mode first (elevated), revert after.
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Set-SteamOfflineMode.ps1 -Action Enable
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Set-SteamOfflineMode.ps1 -Action Disable

# 6. Is every episode's content really installed?
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Test-ContentPacks.ps1

# 7. Run the test suite
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
   licence, not a patched binary.
2. **The Telltale account API is optional at startup.** It is contacted during the
   splash, but the game still reaches the main menu when it is unreachable. Only
   live news and episode-status information degrade.
3. **Achievements are online-only.** Steam stats/achievements
   (`com.telltalegames.<episode>.ch.<NN>`) cannot unlock while Steam is offline;
   gameplay and saves are unaffected.
4. **Saves are local and small, but not readable.** State lives in the per-user
   Documents folder, so it is easy to protect, diff and restore, and easy to lose
   if a reinstall or a profile change happens without a backup. The files are
   obfuscated, so tooling protects them as opaque bytes and does not pretend to
   interpret decisions.
5. **Content is layered, not monolithic.** Episode directories overlay `default`
   with numbered patch archives (`0_*`) taking precedence, which is what makes
   per-episode compatibility profiles possible.

## Roadmap

* Milestone 3: Episode 1 completion and the Episode 2 transition offline; blocked
  on an attended playthrough because the game has no chapter select (see
  [the transition analysis](docs/rea/10-episode-transition.md)). Also pending: a
  full machine-offline run with Steam itself in Offline Mode.
* Milestone 4: save-container research (keystream/compression identification) so
  decisions can be verified by content rather than behaviour, without extracting
  assets.
* Done: all five releases outside Season 1 have a profile and a patch. The
  Definitive Series was patched last, once it was installed: its launcher is
  `WDC.exe`, build 5952618, and it carries the same publisher hostname as
  Seasons 2 to 4. Its archive layout is flat rather than per-episode, and it
  includes 400 Days content that the standalone Season 1 install here lacks.
* Open: the offline launch is timed for Season 1 and the Definitive Series, not
  for Seasons 2 to 4 or Michonne. The Definitive Series launcher still contains a
  Telltale sign-in sentence that did not appear during the measured launch, so
  whether it can is unknown.

## Legal

Telltale Legacy ships no game code, assets, archives, or save data. Tools only read
an installation you already own, and write backups to your own machine. Telltale
Legacy does not circumvent Steam DRM, authentication, licensing, or access
controls. Read [docs/legal-boundaries.md](docs/legal-boundaries.md) before use.

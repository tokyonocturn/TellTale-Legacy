# REA 16 — Offline acceptance matrix

Every row is one thing the mission asks for, with the status it has actually earned. A row
becomes VERIFIED only from evidence produced by the game itself; a menu appearing is not
evidence, and neither is a successful launch.

**Status vocabulary**

- **VERIFIED** — observed, with the capture, measurement or hash named in the evidence column.
- **FAILED** — attempted and observed not to work, with the evidence.
- **UNTESTED** — not attempted, or attempted without the conditions required to judge it.
- **NOT AVAILABLE** — the content is not installed, so it cannot be tested here.

## Current matrix

| Feature | Status | Evidence |
|---|---|---|
| Installed content inventory (Episodes 1–5, all voice archives) | **VERIFIED** | `appmanifest_207610.acf` depot 207611; `Pack/default` + `WalkingDead102`…`105` counted in `15-offline-dependency-map.md` |
| 400 Days | **NOT AVAILABLE** | no `Pack/WalkingDead106`, no DLC depot in the manifest; only backpatch archives reference 106 |
| Publisher endpoints identified | **VERIFIED** | exe literal `https://meta.telltalegames.com/1/`; live `Established` socket to `api.telltalegames.com` (18.245.113.119) in 12/12 samples |
| Reversible endpoint block | **VERIFIED** | Block→Unblock restores the hosts file to an identical SHA-256 (unit test, fixture hosts) |
| Offline harness refuses to disturb a live session | **VERIFIED** | `Test-OfflineLaunch.ps1` exits 20 with the hosts hash unchanged while the game is running |
| Audio on endpoint `100027813` during play | **VERIFIED** | `Assert-AudioDelivery.ps1` exit 0, target peak 0.474285 / 0.386791, default unchanged, mirror running |
| Save backup integrity and restore-by-hash | **VERIFIED** | `Test-BackupIntegrity.ps1` 7/7 files, sandboxed restore identical, one-byte tamper rejected |
| Gameplay progression **with** network (Episode 1 past Chapter 2) | **VERIFIED** | owner's session: 6 → 9 save slots, `prefs.prop` 7,770 → 11,010 bytes, hashes recorded in `14-session-evidence.md` |
| **Cold launch with publisher endpoints unavailable** | **VERIFIED** | `Test-OfflineLaunch.ps1`: block applied and verified, window reached the title screen, 11 frames captured — `17-offline-run.md` |
| **Publisher endpoints unreachable during play** | **VERIFIED** | zero remote TCP connections during the harness observation and again with the game in-game on a fresh offline launch — `17-offline-run.md` |
| **Main menu / episode page offline** | **VERIFIED** | frames `off1`, `off2`, `off3`, `offl3` from the blocked runs |
| **Save load offline** | **VERIFIED** | slot list populated, episode page rendered, chapter loaded into the motor inn gameplay scene with zero connections (pid 6056) |
| **Restart then load offline** | **VERIFIED** | the scenario above is a fresh cold start of an existing save under the block |
| **Episode transition offline (1 → 2)** | **UNTESTED** | needs the episode to end and Episode 2 to load |
| **Episode 2–5 initialization offline** | **UNTESTED** | the episodes are installed but have never been launched by this project |
| **Gameplay scene running offline** | **VERIFIED** | in-game motor inn scene with live interaction chevrons while blocked; long-form progression beyond it not exercised |
| **Dialogue choices / branching consequences offline** | **UNTESTED** | not exercised in the offline run |
| **Cinematics offline** | **UNTESTED** | cinematics have played with network available, not without it |
| **Episode 1 ending + credits offline** | **UNTESTED** | the save is in Episode 1's final chapter; not played to the end |

## What would move each UNTESTED row

| Row | Procedure |
|---|---|
| Cold launch, endpoints unreachable | `Test-OfflineLaunch.ps1` (elevated, game closed): blocks `api`+`meta`, launches via Steam, samples the process, restores hosts identically, writes `docs/rea/data/offline-launch.json` |
| Save load offline | same harness, then load an existing slot and capture the frame showing the chapter title |
| Episode transition | reach the Episode 1 ending in-game, then the Episode 2 opening; capture both |
| Episodes 2–5 | load each episode's opening chapter from the episode menu and capture it |
| Choices/cinematics offline | attend the run; the recorder captures frames + save hashes for each |

## Where this leaves the mission

Offline launching, the frontend, save discovery and loading into a live scene are now
**VERIFIED with the publisher endpoints blocked and zero network traffic**. The ending,
the transition and Episodes 2–5 remain **UNTESTED**, and 400 Days is **NOT AVAILABLE** on
this machine.

## Honest summary

The **dependency** half of the mission is answered with evidence: the game has exactly one
compiled-in publisher URL, keeps a persistent TLS connection to the API host while playing,
never contacts the metadata host during play, and needs nothing else from the network except
Steam's own DRM gate.

The **acceptance** half is not answered. The offline launch, offline save load, the episode
transition, Episodes 2–5 and the ending are all UNTESTED, and the single reason is that the
game has been in an attended session for the whole period in which this work was done. The
harness that settles them exists and refuses to run until that session ends; running it is
the next action, not a claim made now.

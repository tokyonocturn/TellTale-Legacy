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

---

## Update — multi-episode offline drive (2026-11-06, later the same day)

Everything above is the state before the multi-episode drive and is left as written. This
section supersedes the rows it names; the run record is
[`18-multiepisode-offline-run.md`](18-multiepisode-offline-run.md).

Block applied throughout: both domains → `127.0.0.1`, hosts hash
`B90B7D4A3555404288F0B780ADD639523CAED8ABFB25CCBC1E873BEA80C3734`. Restored afterwards to
`4DA2C479D9A3774B99BF03CECBC1FD26F731816DF9D7BCF076663BB1782B6097` — identical.

| Feature | Status | Evidence |
|---|---|---|
| **Episode 1 finale, offline** | **VERIFIED** (playable to its last scene) | restored pre-drive save loaded straight into the finale conversation; live `hoist` chevron on the wall, attic, RV, motel horde with `Examine Zombie`/`Break Wall` widgets and the grab QTE, then the Lee/Clementine closing conversation with the game's own `You made a difficult choice` notice, then the night car scene — 0 remote connections, frames `g1`–`g3`, `hc`–`hd`, `k1`–`k46`, `z1`–`z2` |
| **Episode 1 ending + credits offline** | **UNTESTED** | the finale ran to its last scene offline, but no credits screen was captured; the session came back in Episode 1 Chapter 1 instead, and nothing in the frames attributes that to the network |
| **Episode transition offline (1 → 2)** | **UNTESTED** | not exercised: Episodes 2–5 were started through the game's own "generate story decisions for skipped episodes" path, which is not the ending-driven transition |
| **Episode 2 initialization offline** | **VERIFIED** (third attempt) | forest opening → walker attack → motel chapter with dialogue; `W` moved Lee (1,814,454 px) and the scene cut, 0 remote connections |
| **Episode 3 initialization offline** | **VERIFIED** | title card → subtitled dialogue → truck scene; ladder click made Lee climb, live Kenny dialogue, `Attach Trailer Axle` widget, 0 remote connections |
| **Episode 4 initialization offline** | **VERIFIED** | `LOADING` (~100 s) → Savannah/church opening cinematics → `W` walked Lee (1,299,901 px) with the camera following, 0 remote connections |
| **Episode 5 initialization offline** | **VERIFIED** | morgue opening with live `LOOK AT` / `FIRE EXTINGUISHER` widgets → `W` walked Lee and the scene transitioned (1,549,343 px), 0 remote connections |
| **Episode 2 opening, first cold load** | **FAILED** (twice), then not reproducible | frozen at `THREE MONTHS LATER` for >8 min: 0 connections, ~110–125 % one core, 464 KB/10 s read, pause menu live, audio peak 0.082031 on `100027813`, and a 9-point click grid plus `W`/`Space`/`Enter`/`E` changed nothing beyond ambient sway; the same prompt played with no stall once Episodes 3–5 had been loaded. Cause **not established**, and not the network |
| **Episode discovery / unlock state offline** | **VERIFIED** | the game's own EPISODE STATUS screen, block held, lists Episodes 1–5 as `Installed` and 400 Days as `Coming Soon` — `docs/rea/data/20261106-episode-status-offline.png`; each episode page offered `PLAY` and each episode started |
| **Save creation offline** | **VERIFIED** | new saves written by the game with the block held: `save_11` (Ep2), `save_12` (Ep4), `save_13` (Ep5); `save_9`/`save_7`/`save_10` rewritten during the Episode 1 drive |
| **Save persistence across restart offline** | **VERIFIED** | clean `EXIT GAME`, cold relaunch, slot row and episode pages rebuilt from the rewritten saves, Episode 1 finale reloaded from the restored profile |
| **Cinematics (multi-episode) offline** | **VERIFIED** | Episodes 2–5 opening cinematics and the Episode 1 finale played with the block held, with subtitles and audio |
| **Dialogue choice recording offline** | **VERIFIED** (recording only) | the finale produced the game's own `You made a difficult choice` notice with the block held |
| **Branching consequences downstream of a choice** | **UNTESTED** | later scenes were not followed far enough to observe the consequence |
| **Clean exit / no crash, offline** | **VERIFIED** | `Esc` → `MAIN MENU` → dialog `Yes` → frontend, and frontend `EXIT GAME` terminated the process; no `WalkingDead` crash event in the Application log |
| **Input mapping for driving the game** | **VERIFIED (corrected)** | pause rows are 48 px apart: `RESUME` 410, `SETTINGS` 480, `MAIN MENU` 548, `EXIT GAME` 617 (client); dialog `Yes` 642,745, `No` 1035,745. Earlier "MAIN MENU/EXIT GAME does not respond" failures were clicks landing on `EXIT GAME` at y 598/688 |

### Where this leaves the mission, after this drive

- **Proven offline:** Episodes 1 (finale, playable), 2, 3, 4 and 5 each load and accept real
  gameplay input with the publisher endpoints blocked and zero remote connections; episode
  discovery, unlock state, saves, cinematics and audio all work locally.
- **Not proven:** Episode 1's credits, the ending-driven Episode 1 → Episode 2 transition,
  and downstream branching consequences. 400 Days is not installed.
- The one unexplained runtime failure is the intermittent Episode 2 first-load stall, which
  is a scene/asset-side stall with no network involvement.

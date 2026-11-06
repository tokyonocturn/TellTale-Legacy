# REA 18: Multi-episode offline drive (2026-11-06)

The first run in which the game was driven through **Episodes 1–5 with the publisher
endpoints blocked**. Everything below is what the game did; the parts that failed or did
not finish are recorded the same way as the parts that worked.

## Preconditions

| Item | Value |
|---|---|
| Block | marked host block, `api.telltalegames.com` + `meta.telltalegames.com` → `127.0.0.1`, applied through `tools/Invoke-OfflineProbe.ps1 -Action Block` (elevated) |
| Hosts hash while blocked | `B90B7D4A3555404288F0B780ADD639523CAED8ABFB25CCBC1E873BEA80C3734` |
| Hosts hash before / after | `4DA2C479D9A3774B99BF03CECBC1FD26F731816DF9D7BCF076663BB1782B6097` (identical after rollback, 0 `telltale` lines left) |
| Backup before the drive | `backups/20261106-052935-pre-multiepisode-offline` (manifest + 12 files, hash-verified) |
| Backup after the drive | `backups/20261106-072029-post-multiepisode-offline` (15 files: `save_1`–`save_13`, `prefs.prop`, `steam_autocloud.vdf`), taken before the profile restore |
| Profile restore | `tools/Restore-GameProfile.ps1 -BackupPath backups/20261106-052935-pre-multiepisode-offline -SaveSubDirectory 'The Walking Dead' -Force` → "Verified 12 backup file(s); restored 12 file(s)"; the previous data was preserved in `The Walking Dead.pre-restore-20261106-072119` |
| Steam | running, DRM untouched; the game was always started with `steam://rungameid/207610` |
| Network measurement | `Get-NetTCPConnection -OwningProcess <pid>` filtered to exclude `0.0.0.0`, `::`, `127.0.0.1`, `::1` |

Every "zero connections" statement below is that command returning an empty set at the
moment the frame in question was captured.

## Episode 1: finale driven offline (ending not reached)

The restored pre-drive profile put `CONTINUE` on the Episode 1 finale save, and the game
loaded it with the block held (pid 10616, 0 remote connections).

| Step | What the game showed | Evidence |
|---|---|---|
| Load | Episode 1 finale conversation at night: Lee, Clementine, the group, the walker's walkie-talkie ("It's a girl. We talked and she got frightened…" / "You guys are suicidal. Over a girl.") | frames `g1`–`g3` |
| Gameplay live | over-wall scene with the `hoist`/climb chevron above the brick wall and inventory icons on the left | frame `hc` |
| Interaction accepted | click on the wall chevron (client 971,166) → scene cut to the attic walkers | frame `hd` |
| Story advanced | RV interior → motel walker → crouching group → "Examine Window" widget → "Examine Zombie"/"Break Wall" → walker grab QTE → Kenny at the truck → motel stairs | frames `k1`–`k16` |
| Combat QTE | the grab QTE circle widget appeared and the sequence continued past it | frames `k14`–`k16` |
| Finale conversation | `You made a difficult choice` notice, then Lee/Clementine: "Clem, I've got something to tell you…" / "I have to tell you…" | frames `k37`–`k46` |
| End sequence | the car leaving the motel at night, then Lee in the car | frames `k46`, `z1`–`z2` |

Save writes during this stretch, all with the block held: `save_9` rewritten 07:21,
`save_7` 07:30, `save_10` 07:32.

**Credits were not observed.** After the night-car scene the session came back in
**Episode 1 Chapter 1** (Doug at the drugstore, "Cool, and… we'll keep it down"), i.e. an
Episode 1 playthrough was running again, and no credit roll was captured. Why the game
returned to Chapter 1 rather than to the frontend is not established; the frames do not
show a credits screen, a "next episode" prompt, or an error. Episode 1's ending and credits
therefore stay **UNTESTED**, not verified, and nothing in this drive attributes the gap to
the network: the finale itself ran to its last scene offline with 0 connections.

## Episodes 2–5: loaded and played offline

Frontend path for every episode: `PLAY` → slot row `Game 1` → bottom action bar → episode
page → paging arrow → `PLAY` → the game's own **"Generate story decisions for skipped
episodes?"** dialog → `Yes`. Answering `No` was tried on the Episode 3 page: the dialog
dismissed and the game stayed on the episode page; declining is a no-op, it does not start
the episode.

| Episode | Offline start | Reached | Real advance | Conns at that moment |
|---|---|---|---|---|
| 2 | episode page `PLAY`, generate `Yes` | third attempt: forest opening → walker attack → motel chapter with dialogue and choices | held `W` moved Lee (**1,814,454** changed px) and the scene cut to a close-up | 0 |
| 3 | same | title card → subtitles ("Okay, just like last time. Over the rib.") → truck scene | clicked the ladder (client 1160,560): Lee climbed, live Kenny dialogue, then the `Attach Trailer Axle` widget | 0 |
| 4 | same | `LOADING` (~100 s) → Savannah/church opening cinematics with subtitles | held `W` walked Lee (**1,299,901** changed px), camera followed; later the wounded-man scene | 0 |
| 5 | same | morgue opening; live `LOOK AT` / `FIRE EXTINGUISHER` widgets | held `W` walked Lee and the scene transitioned (**1,549,343** changed px, fade to black) → group scene | 0 |

New save files written by the game during these starts, block still applied:
`save_11` (Episode 2), `save_12` (Episode 4), `save_13` (Episode 5). Save creation,
loading and persistence are therefore exercised offline, not inferred.

### Episode discovery and unlock state offline

The frontend's own **EPISODE STATUS** screen was opened with the block in place: Episodes 1
through 5 each listed as **Installed** with their art, and `SPECIAL EPISODE 400 DAYS` as
**Coming Soon**. Archived as `docs/rea/data/20261106-episode-status-offline.png` (game
art, git-ignored directory).

## The Episode 2 stall, recorded as observed

Attempts 1 and 2 of Episode 2 (both cold starts made right after an Episode 1 session)
**stalled at the opening forest shot** (`THREE MONTHS LATER`, Lee with the hatchet,
camera facing him):

| Measurement | Value |
|---|---|
| Duration static | > 8 min, frame differences limited to ambient grass sway |
| Remote connections | **0** for the whole stall |
| CPU / disk | ~110–125 % of one core; 464,160 bytes read per 10 s; busy, still streaming |
| Engine responsive | `Esc` opened the pause menu, `RESUME GAME` returned to the identical shot |
| Audio | playing: endpoint `100027813` peak 0.082031 while stalling |
| Input probe | `W`, `Space`, `Enter`, `E` plus a 9-point click grid over the 3-D area: every diff ≈1.45 M px, identical to the ambient-only baseline |

Attempt 3, made after Episodes 3–5 had been loaded in the same session, played the same
episode from the same prompt with no stall at all.

### Cause: Episode 2 needs human input

The owner's diagnosis, recorded here as the working explanation: **this opening will not
move on synthetic input; it wants a person at the keyboard and mouse.** The automation's
injected events are not enough to carry it, so the scene sat there looking frozen for as long
as it was left to the driver.

That fits every measurement above:

- zero remote connections throughout; it is **not** a network timeout;
- the engine was alive and burning CPU, the audio was playing, the pause menu opened and
  resumed to the same shot, not a hang;
- the click grid, the pointer sweeps and `W`/`Space`/`Enter`/`E` produced only ambient-sway
  deltas; the scene was waiting on input it did not accept from this harness.

It also explains the shape of the earlier "frozen chapter" records in
[`12-gameplay-automation.md`](12-gameplay-automation.md): what looked like unwinnable scenes
was input that never really reached the game.

One observation is left on the record rather than smoothed away: attempt 3 advanced the same
opening with **no input sent at all**. So the exact mechanism (human input required versus a
first-load state that cleared itself once the earlier episodes had been loaded) is not fully
pinned. What this drive does establish is the direction: **the stall is input/attention-side,
not network-side, and a human at the controls moves it.**

## Input mapping correction

The pause-menu rows are 48 px apart, not 90, and three earlier failures came from that:

| Target | Client coordinate (1920×1071 client) | Note |
|---|---|---|
| `RESUME GAME` | 960, 410 | |
| `SETTINGS` | 960, 480 | |
| `MAIN MENU` | 960, 548 | clicks at y 598 went to `EXIT GAME` |
| `EXIT GAME` | 960, 617 | clicks at y 688 hit nothing |
| Dialog `Yes` / `No` | 642, 745 / 1035, 745 | the dialog is not dismissed by clicking outside it; `No` only works inside its own button |

Frontend: `PLAY` 500,338 · `EPISODE STATUS` 552,439 · `SETTINGS` 522,538 · `EXIT GAME`
531,640 · slot row 900,346 · bottom action bar 1587,962 · episode arrows 270,94 (left) and
1644,103 (right) · `BACK` 186,961.

With this mapping every step above was a single click, and the game exited **cleanly**
through `EXIT GAME` (process gone, no crash event in the Application log).

## Rollback

`-Action Unblock` (elevated) removed the marked block: the hosts file hash returned to
`4DA2C479D9A3774B99BF03CECBC1FD26F731816DF9D7BCF076663BB1782B6097`: **identical** to the
pre-drive value: zero `telltale` lines remained, and `api.telltalegames.com` resolved again
to its CloudFront addresses (18.245.113.x).

## What this run establishes

- **Episodes 2, 3, 4 and 5 each load offline into a live, interactive scene** and accept
  real input that changes game state (movement, widgets, dialogue, scene cuts), with the
  publisher endpoints blocked and **zero remote connections** at the moment of the capture.
- **Episode 1's finale plays offline** from the existing save through its last scene.
- **Episode discovery, episode pages and the installed/not-installed status** are rendered
  from local data with the block held.
- **Saves are created, loaded and rewritten offline.**
- The playthrough is **not** completed: Episode 1's credits were never displayed, and the
  Episode 1 → Episode 2 transition (ending Episode 1, then continuing into Episode 2) was
  not exercised; Episodes 2–5 were all started through the game's own
  "generate story decisions for skipped episodes" path.

## What remains open

| Item | Status |
|---|---|
| Episode 1 ending and credits offline | UNTESTED, finale driven to its last scene, no credits captured |
| Episode 1 → Episode 2 transition offline | UNTESTED, requires finishing Episode 1 |
| Branching consequences downstream of a choice | UNTESTED, a choice was registered (`You made a difficult choice`), its later effects were not followed |
| Episode 2 first-load stall | FAILED twice under this harness; it needs human input at the controls (owner's finding) and was not reproducible afterwards; not a network fault |
| 400 Days | NOT AVAILABLE on this machine |

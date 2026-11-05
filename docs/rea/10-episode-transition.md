# 10 — Episode completion and the Episode 1 → Episode 2 transition

Status: **not verified.** M3 requires Episode 1 to be played to its ending and the
transition into Episode 2 to be observed with the publisher unavailable. Episode 1
has not been completed (see [Blocker](#blocker)), so nothing in this document is a
claim that the transition works offline. It records what the installation and the
executable establish, what was observed directly, and what is still inference.

Everything below is separated into **observed** (measured on this machine) and
**inferred** (a reading of the evidence that has not been demonstrated by playing).

## Content layout (observed)

| Pack directory | Entries | `.ttarch` | Episode |
|---|---|---|---|
| `Pack/default` | 28 | 27 | 1 |
| `Pack/WalkingDead102` | 26 | 25 | 2 |
| `Pack/WalkingDead103` | 22 | 21 | 3 |
| `Pack/WalkingDead104` | 23 | 22 | 4 |
| `Pack/WalkingDead105` | 19 | 17 | 5 |

There is no `Pack/WalkingDead101`: Episode 1 ships in `Pack/default`, while
Episodes 2–5 each get a directory named after their build. Episode 2 carries all
six asset classes — `data`, `voice`, `ms`, `tx`, `mesh`, `anichore` — plus 19
patch archives, so it is a complete local episode rather than a stub awaiting a
download.

Archive file names are prefixed with a load-order index (`1_WalkingDead102_english_pc_data.ttarch`,
`2_..._voice`, …). Anything that matches on file names must treat the prefix as
variable; `tools/Test-TransitionReadiness.ps1` matches on the suffix.

**Inferred:** `WalkingDead10N` ↔ Episode N, with `default` holding Episode 1. The
profile records this as confirmed by archive naming; the runtime observation that
supports it is that with only `default` present the slot list labelled the save
`Episode 1`.

## Publisher surface (observed)

The executable contains exactly one Telltale URL literal:

```
https://meta.telltalegames.com/1/
```

`meta.telltalegames.com` resolves to CloudFront (`108.156.245.x`). M2 blocked only
`api.telltalegames.com` (`18.245.113.x`), which was the endpoint seen at runtime in
run A of `04-online-dependencies.md`. Blocking `api` alone therefore left a
documented, compiled-in publisher endpoint reachable, and "publisher API
unavailable" was narrower than it sounded.

M3 blocks **both** domains for any session used as evidence. The probe now refuses
a comma-joined domain list outright: passing `-Domains a,b` through `-File` binds
one string, which previously produced a hosts line that blocked nothing while
reporting success.

## Offline launch and episode discovery (observed)

Session `docs/rea/data/sessions/20261105-173323-m3-episode-status-offline.json`:

- `api.telltalegames.com` and `meta.telltalegames.com` → `127.0.0.1` in the marked
  hosts block, Steam left online (DRM untouched).
- Launched through Steam, observed 130 s, reached the main menu.
- `RemoteEndpoints: []` for the whole session — no remote connection was held.
- The main menu rendered normally, including the scrolling banner ("For the latest
  information on The Walking Dead five-part game series, please visit the official
  website www.walkingdeadthegame.com"), so that banner is local text, not a feed.
- `EPISODE STATUS` still showed its red badge, matching the M2 observation that the
  badge appears identically with and without connectivity. Its meaning remains
  unexplained and is **not** attributed to the API.

The `PLAY` slot list was reached and read: one saved game labelled `Game 1`,
`Episode 1`, timestamp `05/11/26 17:08:35`, with two empty `New Game` rows and the
`BACK / COPY / DELETE / PLAY` actions.

**Not observed:** the `EPISODE STATUS` screen itself. Menu input in this
environment is unreliable — a first click registered, after which the same window
accepted neither synthesised clicks (SendInput, foreground confirmed, no window
overlapping the target) nor `WM_LBUTTON*`/`Esc`. The screen was abandoned rather
than driven blind, because blindly clicking episode rows risks starting an episode
and writing saves. Whether that screen lists Episode 2 as available offline is
therefore an open question, to be answered during the attended session.

## Save-side effects of a menu visit (observed)

Launching to the menu and leaving the game at rest rewrote `prefs.prop` while all
five saves stayed byte-identical:

```
CHANGED   prefs.prop
UNCHANGED save_1.save  save_2.save  save_3.save  save_5.save  save_6.save
UNCHANGED steam_autocloud.vdf
```

**Inferred:** `prefs.prop` carries slot-list metadata that the game refreshes on
start (it is the file the offline slot list was rendered from in M2). The container
is opaque, so this is behaviour, not decoded content.

## What the transition must still demonstrate

These are the M3 questions that remain open, in the order the attended session will
answer them:

1. **Discovery** — after Episode 1 ends, does Episode 2 appear as playable without
   any publisher response?
2. **Transfer** — does the completed Episode 1 progression produce an Episode 2
   start state, or does the episode open as a fresh game?
3. **Choice carry-over** — at least one decision must be visible in Episode 2. The
   planned observables are the drugstore survivor (Carley vs Doug) and the
   consequence tied to them at the motel; both are visible in play without reading
   the container.
4. **No extra components** — Episode 2 must start from the installed archives alone:
   no additional executable, no additional pack, no download.
5. **Restart persistence** — exiting and relaunching offline must keep both the
   Episode 1 completion state and the Episode 2 progress.

None of these is answered by static inspection. Episode 2 being present on disk
makes a download unnecessary, which is not the same as proving the game will not
attempt one at the transition.

## Choice preservation experiment (designed, not yet run)

Recorded separately from internal implementation:

1. Start from a controlled save at a checkpoint before a decision.
2. Make decision A, reach the next autosave, note the immediate consequence.
3. Exit to the menu, relaunch offline, continue, and confirm the consequence is
   reproduced at the same checkpoint.
4. Complete Episode 1 and confirm the consequence survives into Episode 2.

Observed behaviour is recorded as behaviour. The save container stays opaque: a
byte difference between two saves does not name a decision, and none of these
documents claim otherwise.

## Evidence index

| Item | Path |
|---|---|
| Offline launch session | `docs/rea/data/sessions/20261105-173323-m3-episode-status-offline.json` |
| Pre-session backup (7 files) | `backups/20261105-173230-m3-baseline/` |
| Progression baseline | `docs/rea/data/save-progress-m3-baseline.json` |
| Current progression | `docs/rea/data/save-progress.json` |
| Menu / slot-list captures | `docs/rea/data/captures/m3-*.png` |

Progression baseline at the time of writing: `save_1 → save_6 → save_5 → save_3 →
save_2`, 5 distinct slots, written over 2,775 s.

## Reproduce

```powershell
# Pre-flight: content, build hash, block, backup, saves, space
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Test-TransitionReadiness.ps1

# Record save activity while playing (JSONL, read-only)
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Get-Progression.ps1 -WatchSeconds 10800

# Compare progression against the baseline afterwards (exit 3 = drift)
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Get-Progression.ps1 `
    -BaselinePath docs\rea\data\save-progress-m3-baseline.json
```

## Blocker

Episode 1 cannot be completed by the agent. It is roughly two hours of narrative
play — dialogue choices, QTEs, exploration — and the game has **no chapter select**:
progression is autosave-only, so reaching the ending means playing forward from the
current checkpoint. Driving that with synthesised input would produce a fabricated
result, and editing save files to skip ahead is forbidden by the project rules.
The transition is therefore untested until the owner plays the remaining Episode 1
content in an instrumented session.

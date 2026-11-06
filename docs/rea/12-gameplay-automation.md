# REA 12 — Driving the game with real input (playthrough attempt)

This record covers the first attempt to play Episode 1 **through automation**: real
mouse and keyboard input delivered to the game window, screen evidence captured
from the window itself, and the run documented honestly, including where it stopped.

It exists because the mission requires a full playthrough, and a playthrough cannot
be claimed from menus. Everything below is what the game actually did.

## Method

| Element | Detail |
|---|---|
| Input | `tools/Invoke-GameInput.ps1` — `SendInput` for keys, `mouse_event` for buttons, `SetCursorPos` for aiming; client coordinates converted with `ClientToScreen` |
| Capture | `PrintWindow` with `PW_RENDERFULLCONTENT` (0x2). Plain `PrintWindow` returns a blank DirectX surface; `CopyFromScreen` was rejected because another window on the desktop could sit over the game and appear in the capture |
| Observation | Frames sampled at fixed intervals, downscaled, mean-grey-level deltas between frames to tell "the view changed" from "the view is frozen" |
| Build | Steam app 207610, build 244978, unmodified files |
| Saves | Backed up before the run: `backups/20261106-014855-episode-run-1` (7 files) |
| Network | Game ran with Steam online and the publisher API reachable; the API-absent evidence is M2's (`08-offline-gameplay-verification.md`), not this run's |

## Control scheme, established by measurement

The first problem was not the game but the assumption about its controls. Measuring
rather than guessing produced this table:

| Input | Effect observed | Evidence |
|---|---|---|
| `Esc` | Opens and closes the pause menu | Menu rendered; `RESUME GAME` returned to play |
| `W` / arrow keys (held 1.2–3 s) | **No movement** in free roam | Frame delta 0.1–0.5 mean grey levels, identical to sending nothing |
| Click on walkable ground and hold (~3 s) | **Lee walks** toward the pointer | Frame delta 24.4; Lee's position and the camera both change |
| Move pointer without clicking | Camera turns / re-aims | Delta 4.6–12.1 depending on distance |
| Click on a menu entry | Activates it | Menu navigation, chapter select, confirm dialogs |
| `Space`, `1`–`4` during free roam | No effect observed | No frame or state change |

So this build is driven by **click-and-hold to walk plus click to interact**, and
synthetic WASD is not equivalent. Any earlier claim that "synthesised input is
rejected" was wrong in its cause: the input was being delivered, the keys simply are
not the movement control.

## Menu path used (client coordinates, 1024×768 client area)

| Step | Target | Client coordinate |
|---|---|---|
| 1 | Main menu `PLAY` | 268, 295 |
| 2 | Slot row `Game 1` | 331, 275 |
| 3 | Slot list `PLAY` | 837, 625 |
| 4 | Chapter select `CONTINUE` | 837, 625 |
| 5 | Chapter select `REWIND` | 615, 622 |
| 6 | Rewind confirmation `Yes` | 350, 492 |
| 7 | Pause menu `RESUME GAME` / `MAIN MENU` / `EXIT GAME` | 516, 332 / 401 / 440 |

One calibration trap worth recording: chapter and dialog thumbnails are rendered at
a different scale from the capture, so a coordinate read off a montage and applied
as if it were full-size lands tens of pixels away and silently does nothing. Two
clicks were lost to exactly that before it was measured.

## What the run reached

| Observation | Result |
|---|---|
| Save loaded | `Game 1`, Episode 1, timestamp 05/11/26 17:03:36, then 11/26 01:52:30 after the resume |
| Chapter (from the in-game chapter browser) | **Chapter 2: In The Yard** — the browser labels it, and its thumbnail is the aerial view of the yard |
| Chapter start replayed | Yes, via `REWIND` → confirmation `Yes`; the chapter's opening cinematic played from its first frame (walkers at a fence, red wagon, Lee close-up) |
| Free movement | Yes in the yard: Lee walked to the porch, the treehouse tree and the fence corner |
| Story progress | **None beyond the chapter's opening shot** |

## Where it stopped, and what is actually known

After the chapter's opening cinematic the game settles on a static shot of Lee
standing in the yard. Over roughly five minutes of probing — click-and-hold on
walkable ground, clicks on the porch, the door, the treehouse ladder, the fence and
the walker beyond it, camera sweeps in every direction, `Space` and digits — no
input produced any state change. `Esc` → `RESUME GAME` returned to the identical
shot, so the session itself was alive.

Two readings remain open, and this record does not choose between them:

1. **A missed interaction.** In this engine, progress at a still shot usually comes
   from clicking a highlighted hotspot. Hotspot highlight and the game cursor are
   not present in the captured frame, so "no hotspot was found" is a statement about
   the search, not about the scene.
2. **A chapter that cannot advance on this machine.** Consistent with that reading:
   the game's own audio session stayed `State=Active, Peak=0` throughout the probing,
   and the scene produced no dialogue audio or subtitles at any point.

What is *not* claimed: that the chapter is unwinnable, that any decision was made,
that any episode was completed, or that the Episode 2 transition was seen. None of
those happened.

## Machine state after the run

| Check | Result |
|---|---|
| Policy store entries | 700 before, 700 after, none added or removed |
| Per-value comparison | 0 changed, 0 added, 0 removed — identical hash under one normalisation |
| Default render endpoint | Voicemeeter AUX Input (`Default = True`), unchanged |
| `100027813` | active, not default, `PeakMax = 0` |
| Game process | exited through `EXIT GAME` → `Yes`, no crash |
| Saves | only the game's own autosaves moved (`save_2`, `save_3`, `prefs.prop`); `save_1`, `save_5`, `save_6` untouched; pre-run backup intact |

The rewound chapter restarts from its checkpoint, so no progression was destroyed by
the attempt beyond the chapter's own post-checkpoint state.

## Reproduce

```powershell
.\tools\Backup-GameProfile.ps1 -SaveSubDirectory 'The Walking Dead' -Label before-play
Start-Process 'steam://rungameid/207610'          # ~30 s to the main menu
.\tools\Invoke-GameInput.ps1 -Action Info         # client origin, size, foreground
.\tools\Invoke-GameInput.ps1 -Action Click -X 268 -Y 295      # PLAY
.\tools\Invoke-GameInput.ps1 -Action Click -X 331 -Y 275      # slot row
.\tools\Invoke-GameInput.ps1 -Action Click -X 837 -Y 625      # PLAY
.\tools\Invoke-GameInput.ps1 -Action Press -X 510 -Y 600 -Milliseconds 3000   # walk
.\tools\Invoke-GameInput.ps1 -Action Capture -CaptureMethod Window -OutputPath shot.png
```

## Honest status

- Episode 1: **not completed**. Reached its second chapter, played it from the
  chapter start, no story progress beyond the opening shot.
- Episodes 2–5 and 400 Days: **untouched**.
- Episode transitions, dialogue choices, branching consequences: **untested**.
- Audio on `100027813`: **not achieved**; see `11-audio-routing.md` for the measured
  failure and the control experiment.

---

## Update: re-tested with the game's audio working

The earlier note left two readings of the Chapter 2 stall open, one of them "a chapter
that cannot advance, consistent with silence". The silence has since been fixed — the
game's own `VOICE/MUSIC/SOUND` were all at zero and are now 10/10/10, with measured
audio at 0.44–0.79 peaks during the chapter's own cinematics
([`13-audio-delivery.md`](13-audio-delivery.md)). The stall is unchanged.

Each probe below was run **with audio playing**, in the same still shot:

| Probe | Attempts | Result |
|---|---|---|
| Click sweep | 12 points across the picture (3 rows × 4 columns), each preceded by a pointer move | Camera swings; no dialogue, no choice UI, no scene change |
| Walk | 8 × 2.2 s held clicks along the visible sidewalk | Lee does not move |
| Walk (drag) | 3 held drags, including a slow steer | Lee does not move |
| Interact | Click on Lee, click at his feet | Frame delta 1.3 then 0.2 — no state change |
| Keys | `Q`, `E`, `R`, `F`, `Tab`, `Enter`, `Space`, digits | Frame delta **0.0** — nothing at all |
| Menus | `Esc` → `RESUME` | Returns to the identical still shot |
| Chapter replay | `REWIND` → `Yes`, replayed from the chapter's first frame | Cinematic plays, then the same still shot |

The game is verifiably alive throughout: the window is foreground
(`ForegroundPid` = game pid), the engine consumes ~1 core, and the audio session stays
`Active` with a changing ambient bed.

### What this establishes, and what it does not

Established: the still shot is inert to every input the driver can send, with audio
working, and it returns identically after a resume. The two earlier readings are now
one: the chapter does not advance on this machine, and it is **not** an audio fault.

Not established: *why*. A missing or failed cinematic/script asset, a scene trigger that
depends on something this configuration never satisfies, and an engine soft-lock are all
consistent with what was observed; nothing yet distinguishes them. The engine ships no
log, the save container is opaque, and the scene's script lives inside the encrypted
`ttarch` archives.

### Consequence for the mission's acceptance

- **Episode 1 Chapter 3 was not reached.** No dialogue choice was presented, so none was
  recorded, and no checkpoint beyond the chapter's own was written.
- The last save state is the chapter checkpoint; the pre-run backup taken for this
  session, `backups/20261106-022557-audio-silence-run`, is intact.
- Episodes 2–5, 400 Days and the episode transition remain untested.

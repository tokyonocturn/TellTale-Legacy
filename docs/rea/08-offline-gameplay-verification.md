# REA 08: Offline gameplay verification (M2)

This is the milestone record for "a real gameplay session can be started, saved,
closed, restarted and resumed with the publisher API unavailable". It separates
what a person played from what a machine asserted, because the two prove
different things.

## Test environment

| Item | Value |
|---|---|
| Game | The Walking Dead, Steam app 207610, build 244978 |
| Executable SHA-256 | `44a5ff21cbb085812c48179259141ff5c83eaeaa3423b4734b43533df0a2528d` |
| Installation | `C:\Program Files (x86)\Steam\steamapps\common\The Walking Dead` |
| Save root | `%USERPROFILE%\Documents\Telltale Games\The Walking Dead` |
| Network condition | `api.telltalegames.com` → `127.0.0.1` via marked hosts block |
| Steam | Online, normal launch through `steam://rungameid/207610` |
| Game files | Unmodified. No patch, no DLL replacement, no DRM interaction |
| Display | Windowed 1030×797, Standard display style |

The block is applied by `tools/Invoke-OfflineProbe.ps1 -Action Block` and removed
with `-Action Unblock`. Steam is deliberately **not** blocked: the Steam DRM
wrapper is the legitimate gate and was never touched.

## Method and attribution

- The first playthrough (new game, opening act, several checkpoints) was played
  by the project owner at the keyboard. It is recorded as an **attended** run.
- Resume, exit and the second launch were driven through real mouse/keyboard
  input to the game window, with screenshots captured as they ran. This is UI
  automation of a human-equivalent click path, not gameplay automation, and it
  is labelled as such.
- No save was hand-edited, deleted or fabricated. Save operations were never
  scripted against the game.

## What happened, in order

| Step | Action | Result |
|---|---|---|
| 1 | Steam launch with API blocked, click through splash | Main menu, banner falls back to static text, 0 remote endpoints |
| 2 | PLAY, choose display style, select Episode 1, PLAY | Episode 1 loads; `prefs.prop` grows 6,647 → 6,795 |
| 3 | Owner plays the opening act | Live gameplay; autosaves at 16:47, 16:51, 16:53 |
| 4 | Owner exits through the in-game menu | `prefs.prop` rewritten at 16:53:40; saves stable |
| 5 | Relaunch offline, PLAY | Slot list shows "Game 1 - Episode 1 - 05/11/26 16:53:35" |
| 6 | Select slot, PLAY, CONTINUE | Checkpoint resumes into gameplay; `save_3` written; 0 TCP connections |
| 7 | Esc → main menu → EXIT GAME → Yes | Clean process exit, no crash, no error dialog |
| 8 | Second offline launch, same path | Slot list again, CONTINUE resumes the same checkpoint, `save_2` written; 0 TCP connections |
| 9 | Esc → main menu → EXIT GAME → Yes | Clean exit again |

Step 4 is the owner's; steps 1–3 and 5–9 were observed or driven by scripted
input with the owner present.

## Evidence

Session logs (`docs/rea/data/sessions/`, git-ignored because they contain local
paths), each asserting `RemoteEndpoints: []`:

- `20261105-164027-m2-gameplay-start.json`: 45 s, Steam launch, intro running
- `20261105-170025-m2-offline-resume-1.json`: 40 s, first offline relaunch
- `20261105-170346-m2-offline-resumed-gameplay.json`: 20 s attached to the resumed process
- `20261105-170622-m2-offline-resume-2.json`: 25 s, second offline relaunch

Screen captures (`docs/rea/data/captures/`):

| File | Shows |
|---|---|
| `01-offline-main-menu.png` | Main menu with API blocked |
| `02-display-style.png` | First-run display-style choice |
| `03-episode-select.png` | "EPISODE 1: A NEW DAY" |
| `04-slot-list.png` | "Game 1" slot with timestamp, offline |
| `05-slot-selected.png` | BACK / COPY / DELETE / PLAY |
| `06-resumed-gameplay.png` | Checkpoint resumed in-game |
| `07-second-cycle-continue.png` | Second launch reaching CONTINUE |
| `08-second-resume.png` | Second resume, same scene |

Machine evidence:

- `tools/Get-SaveArtifacts.ps1` → 5 saves, 1 prop, all magic recognised, no `temp.save`
- `tools/Get-SaveArtifacts.ps1 -BaselinePath` → `added=2, changed=1 (prefs.prop)`, exit 3,
  i.e. the two saves produced by the test are the only additions and no pre-existing
  save was altered
- `tools/Test-ContentPacks.ps1` → all 5 episode packs present (27/25/21/22/17 archives)
- `tests/Run-Tests.ps1` → 22 passed, 0 failed

No TCP connections were held by the process at any sampled point during gameplay
(`Get-NetTCPConnection -OwningProcess`), and the observer recorded zero remote
endpoints on every launch.

## Confirmed offline functionality

- Launch through Steam and reach the main menu.
- Start a new game and play Episode 1's opening act.
- Write autosave checkpoints (`save_N.save`) and slot metadata (`prefs.prop`).
- Show the save slot list with correct name, episode and timestamp.
- Resume a checkpoint into gameplay after a full restart.
- Repeat the whole launch → resume → exit cycle a second time.
- Play with no connection to the publisher API and no socket opened at all.

## Choice persistence: what is and is not verified

Verified: progression persists. The checkpoint that resumed was created *after*
the owner's decisions in the opening act, and the game returned to that exact
state rather than to the start of the episode.

Not verified: the encoded decision values. The save container is opaque (see
`07-save-and-slot-format.md`), the slot UI shows no decision recap, and Episode 1's
own statistics screen is not available offline in a form that lists choices. A
byte diff between two saves is 98% noise and cannot name a decision. So the claim
"choices persisted" rests on behavioural continuity across a checkpoint, not on
reading them back. Any stronger claim would require decoding the container, which
M2 did not achieve.

## Episode transition

Not run. Reaching Episode 2 requires a complete Episode 1 playthrough (hours of
attended play), and the transition cannot be simulated without editing save data,
which this project does not do. What *was* verified structurally: all five episode
packs are installed and each contains its archives (`content-packs.json`), so no
content is missing for the transition when it is played.

## Remaining dependencies

| Dependency | Status during gameplay |
|---|---|
| Steam client + cached licence | **Required.** DRM gate, by design |
| `api.telltalegames.com` | Not required. Zero connections during play |
| Steam Auto-Cloud | Optional. Local saves work without it |
| Steam achievements | Online-only, separate from gameplay (see doc 09) |

## Known limitations

- One playthrough at one build on one machine. No other builds were exercised.
- The save container was not decoded, so semantic choice verification is
  behavioural only.
- Episode transition and 400 Days are untested (content absent for the latter).
- Slot-number selection is unexplained; resumes wrote slots 3 and 2 for a save
  loaded from slot 5.
- Screenshots were reviewed by eye; no frame-by-frame capture of dialogue timing
  was recorded.

## Reproduce

```powershell
.\tools\Invoke-OfflineProbe.ps1 -Action Block          # elevated
.\tools\Start-ObservedSession.ps1 -Label m2-manual -ObservationSeconds 60 -ViaSteam
# in game: PLAY -> Episode 1 -> play -> EXIT GAME
.\tools\Get-SaveArtifacts.ps1 -OutputPath docs\rea\data\save-artifacts.json
.\tools\Invoke-OfflineProbe.ps1 -Action Unblock        # elevated
```

Compare a launch against the previous state with
`-BaselinePath docs\rea\data\save-artifacts.json`; exit 0 means the save set is
byte-identical, exit 3 lists what moved.

# Version matrix

One row per **verified** build. A profile is only marked validated for scenarios
that were actually exercised on that exact build.

## The Walking Dead (Season 1)

| Profile | Steam app / build | Exe SHA-256 (first 16) | Link date | Content | Offline startup | Gameplay offline | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `twd-s1-steam-207610` | 207610 / 244978 | `44a5ff21cbb08581` | 2014-04-25 | 112 ttarch v9, Ep1–5 | **Verified** (API blocked) | **Verified** Ep1 (attended, API blocked) | Milestone 2 complete; M3 blocked on attended playthrough |

Full hashes are in `profiles/twd-s1-steam-207610/profile.json`.

### Scenario detail: `twd-s1-steam-207610`

| Scenario | Result | Evidence |
| --- | --- | --- |
| Readiness audit | ready (0 fail, 0 warn) | `offline-readiness.json` |
| Launch via Steam, online | main menu | session `baseline-viasteam` |
| Launch via Steam, `api.telltalegames.com` blocked | main menu, 0 remote endpoints | session `offline-api-blocked` |
| Direct exe launch | exits 53, Steam relaunches | session `baseline-online` |
| First-run save directory creation | `prefs.prop`, `steam_autocloud.vdf` | session snapshots |
| Preference persistence across exit | file rewritten, size changed | three sessions |
| New game, Episode 1 gameplay (API blocked) | played to multiple autosaves | `08-offline-gameplay-verification.md` |
| Save creation | `save_1/5/6.save`, magic `bbdeaf64` | `save-artifacts.json` |
| Slot list offline | `Game 1 - Episode 1 - 05/11/26 16:53:35` | `captures/04-slot-list.png` |
| Restart + resume (API blocked) | checkpoint resumed, 0 TCP connections | sessions `m2-offline-resume-1/2` |
| Repeated offline launch | second resume identical, `save_2` written | session `m2-offline-resume-2` |
| Save-set integrity across test | added=2, changed=`prefs.prop`, no save altered | `save-drift-m2.json` |
| Episode packs present | 5 packs, 27/25/21/22/17 archives | `content-packs.json` |
| Publisher surface blocked | api **and** meta to loopback, 0 remote endpoints | session `m3-episode-status-offline` |
| Transition readiness gate | ready (0 fail, 0 warn) on the real install | `transition-readiness.json` |
| Save activity harness | progression chronology + drift + JSONL watcher | `save-progress-m3-baseline.json` |
| Choice persistence | progression verified behaviourally; values not readable | `07-save-and-slot-format.md` |
| Episode transition | **blocked**: needs full Ep1 playthrough; offline launch and Ep2 content verified | `10-episode-transition.md` |
| Achievements offline | expected unavailable (Steam stats) | static analysis only |
| 400 Days | **not applicable**: content not installed | `09-400-days-and-achievements.md` |
| Full Steam Offline Mode run | **not tested** | - |
| Audio endpoint `100027813` | **identified** (`{63b45a0d-…}`), 3 of 4 same-named devices stale | `11-audio-routing.md` |
| Game audio on `100027813` | **not routed / not verified** | `11-audio-routing.md` |

## Builds identified but not investigated

These exist and are referenced in store metadata on this machine, but **no analysis
has been performed** and no profile exists. They must not inherit Season 1
conclusions: content layout, DRM and engine revision may differ.

| Title | Steam app | State on this machine |
| --- | --- | --- |
| The Walking Dead: Season Two | 261030 | manifest present, not installed |
| The Walking Dead: The Final Season | 866800 | manifest present, not installed |
| The Walking Dead: The Telltale Definitive Series | 1449690 | manifest present, not installed |

## How to add a build

1. Install it and confirm it is fully installed (`StateFlags` bit 2).
2. `.\tools\Get-GameInventory.ps1 -GameRoot <path>` and inspect what changed:
   engine revision, archive version, content directories, DLL set.
3. Duplicate the closest profile, change every identity field, and replace the
   hashes with the new build's real hashes.
4. `.\tools\Test-OfflineReadiness.ps1 -ProfilePath <new profile>`.
5. Run real sessions and record only what you observed.
6. Add a row above with honest `Verified` / `Not tested` values.

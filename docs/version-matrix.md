# Version matrix

One row per **verified** build. A profile is only marked validated for scenarios
that were actually exercised on that exact build.

## The Walking Dead (Season 1)

| Profile | Steam app / build | Exe SHA-256 (first 16) | Link date | Content | Offline startup | Gameplay offline | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `twd-s1-steam-207610` | 207610 / 244978 | `44a5ff21cbb08581` | 2014-04-25 | 112 ttarch v9, Ep1–5 | **Verified** (API blocked) | Not tested | Milestone 1 complete |

Full hashes are in `profiles/twd-s1-steam-207610/profile.json`.

### Scenario detail — `twd-s1-steam-207610`

| Scenario | Result | Evidence |
| --- | --- | --- |
| Readiness audit | ready (0 fail, 0 warn) | `offline-readiness.json` |
| Launch via Steam, online | main menu | session `baseline-viasteam` |
| Launch via Steam, `api.telltalegames.com` blocked | main menu, 0 remote endpoints | session `offline-api-blocked` |
| Direct exe launch | exits 53, Steam relaunches | session `baseline-online` |
| First-run save directory creation | `prefs.prop`, `steam_autocloud.vdf` | session snapshots |
| Preference persistence across exit | file rewritten, size changed | three sessions |
| New game / save slot | **not tested** | — |
| Dialogue, choices, cinematics | **not tested** | — |
| Episode transition | **not tested** | — |
| Achievements offline | expected unavailable (Steam stats) | static analysis only |
| Full Steam Offline Mode run | **not tested** | — |

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

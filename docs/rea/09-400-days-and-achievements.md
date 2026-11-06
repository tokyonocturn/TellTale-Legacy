# REA 09: 400 Days, Steam statistics and service dependencies

Two things are deliberately kept out of the core "playable offline" claim:
additional content that is not installed, and platform features that need a
network by design. This document separates them so neither is mistaken for a
gameplay dependency.

## 400 Days

**Status: not installed, therefore not tested.**

What is on disk: every episode directory contains one shared overlay archive
named `0_20_WalkingDead106_<pack>backpatch_s.ttarch`:

```
Pack/default/       0_20_WalkingDead106_101backpatch_s.ttarch
Pack/WalkingDead102/0_20_WalkingDead106_102backpatch_s.ttarch
Pack/WalkingDead103/0_20_WalkingDead106_103backpatch_s.ttarch
Pack/WalkingDead104/0_20_WalkingDead106_104backpatch_s.ttarch
Pack/WalkingDead105/0_20_WalkingDead106_105backpatch_s.ttarch
```

There is **no** `Pack/WalkingDead106` directory and the inventory contains no
`WalkingDead106` content group. `tools/Test-ContentPacks.ps1` confirms exactly
five episodes, each with its own archives (27, 25, 21, 22, 17).

Interpretation, labelled as inference: the `106` numbering continues after
`105`, and 400 Days is the content that follows Episode 5 in this release line,
so `WalkingDead106` most likely denotes 400 Days assets shared into each episode
pack as back-patch content. This is **not** confirmed by runtime observation,
because the content is absent. It is not in the profile's episode map, so the
content validator does not claim it as present.

Consequence: the game cannot be asked to load 400 Days on this installation. If
the DLC is installed later, the check is `tools/Test-ContentPacks.ps1` after
adding `WalkingDead106` to the profile's `content.episodeDirectories`, then a real
playthrough under the same blocked-API conditions. Until then the milestone
scenario `four-hundred-days` stays `not-applicable`.

## Steam achievements and statistics

Achievements are a platform feature, not core gameplay. Evidence that they are
tracked through Steam rather than the Telltale API:

- `steam_api.dll` is imported with interfaces `SteamClient012` and `SteamUser016`.
- The executable contains no `SteamRemoteStorage` strings, so cloud sync is Steam
  Auto-Cloud (file-level), not the remote-storage API.
- Episode packs contain stat items such as
  `Pack/WalkingDead105/StatsItem_Chapter8.prop`, which carries the ERTM magic and
  the stat id `com.telltalegames.WalkingDead105.ch.08`.

That last item shows the in-game chapter progress is mirrored into a Steam stat
namespace. Unlocking achievements therefore requires a working Steam session with
the stats service reachable; it is not something the publisher API provides, and
it is not something this project supplies or emulates.

Known behaviour, and its honest limit:

- The main menu's `EPISODE STATUS` entry shows a red alert badge in **both** the
  online and blocked runs. Its meaning was not established. It is not a gameplay
  dependency: no socket was opened when the screen was used, and gameplay is
  unaffected.
- Achievements were not tested offline. Steam Offline Mode generally defers or
  drops stat/achievement writes; that is a Steam-side behaviour and this project
  makes no claim about which achievements survive it.
- No achievement or statistic was modified, spoofed or unlocked by this project,
  and nothing here should be used to do so.

## Service dependencies during gameplay (summary)

| Endpoint / service | When it is contacted | Needed to play |
|---|---|---|
| Steam client (licence, DRM) | Launch, always | **Yes**: this is the legitimate gate |
| `api.telltalegames.com` | Splash / news fetch | No. Blocked run played normally |
| Steam stats/achievements | On stat writes | No, for gameplay |
| Steam Auto-Cloud | Around launches and exits | No, local saves are authoritative |

The M2 sessions recorded zero remote endpoints across four launches, including
gameplay and two resumes, with the publisher API blocked. No local replacement
for any Telltale service was needed, and none was written.

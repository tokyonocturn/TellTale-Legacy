# REA 21: The Definitive Series offline launch, measured with the patch installed

[Doc 19](19-offline-launch-stall.md) established where the offline wait lives: Steam, not the
game, and Steam's own Offline Mode removes it. That was measured on Season 1. This is the same
measurement for the Definitive Series, on its own build, with its own patch applied.

Short version: **main menu rendered 18.54 s after Steam was asked to start the game, and it
accepted a click that opened the season chooser.** No minute-plus wait, no connection prompt.

## What was measured

| Item | Value |
|---|---|
| Game | The Walking Dead: The Telltale Definitive Series, app 1449690, build 5952618 |
| Executable under test | `WDC.exe`, SHA-256 `5f44e53fcaec4c59c8c2f79403722076fc1c518c0d006d2a1262efeaec656782` |
| Patch | `Set-GameOfflinePatch.ps1 -Action Install`: `WantsOfflineMode 1`, `SkipOfflineModeWarning 1`, `services.telltalegames.com` pinned to `127.0.0.1` |
| Cut-off | Steam's own Offline Mode plus outbound block rules for `steam.exe`, `steamwebhelper.exe` and `WDC.exe` |
| Clock | starts when `steam://rungameid/1449690` is handed to Steam |
| Machine | this desktop, 1920x1080, game in its own 1366x768 window |

The three firewall rules are the same reversible emulation doc 19 used: the host kept its
adapter, and the blocked programs could not reach anything outbound. A physically disconnected
machine was still not available, so the "no adapter at all" case remains untested here too.

## What "usable" means for this build, and why the first attempt was wrong

Season 1's frontend path is title, main menu, slot list, episode page. The Definitive Series is
a collection launcher and its path is different:

```
Skybound / FMOD splash  ->  title screen "Click to Begin"  ->  spinner  ->  main menu
    ->  Season Select carousel with a PLAY button on the chosen season
```

The first attempt reused the click-difference instrument with a two-step path. It reported
14.10 s and was wrong: the screenshots it saved show a click accepted during the splash and a
second "acceptance" that was the title screen still fading in, not the menu. Click-difference
alone cannot tell a screen the game reacted to from a screen that was already animating.

The measurement below therefore does not infer state from click differences. It records the
launch as a frame sequence and identifies screens by their own signatures:

- **Title screen**: the red "THE TELLTALE DEFINITIVE SERIES" band. Fraction of red pixels in
  the lower middle of the frame is 0.077 to 0.081 on the title screen, and 0.000 in every other
  state measured (splash, spinner, menu, season chooser, gameplay scene).
- **Main menu**: a frame with no red band, mean luminance around 64, and consecutive samples
  that differ by less than 3 grey levels, which is the menu's live background. The spinner is
  near-black (luminance 0.07 to 0.11) and the splash is brighter and changing.

Frames were sampled about every 1.6 s, and a click at the title position was sent with each
sample. That click is harmless on the splash, the spinner and the menu background, and it is
what advances "Click to Begin".

## The measured sequence

| t (s) | Frame state | Evidence |
|---|---|---|
| 1.39 | `WDC.exe` process present | process poll |
| 2.43 to 4.14 | black | luminance 0.10 to 0.13 |
| 5.72 to 8.88 | splash, then a dark transition | luminance 39 to 49, then 11.6 |
| **10.48** | **title screen rendered** | red band 0.0779, still 0.0813 at 12.01, fading 0.0370 at 13.58 |
| 15.15 to 16.77 | spinner | luminance 0.07 to 0.11, no red |
| **18.54** | **main menu rendered** | luminance 62.6, no red, stable at 64 for every later sample |
| 18.54 onward | menu holds | sample diffs 0.5 to 3.1 over the next 50 s |
| after that | menu accepted a click | Season Select opened the carousel with a PLAY button, captured |

So: title screen at 10.5 s, menu at 18.5 s, and the menu was live when clicked. Against the
reported symptom (a minute to ninety seconds, then "please connect"), this build reached its
menu in under twenty seconds with no network available at all.

## What this establishes, and what it does not

| Claim | Status |
|---|---|
| Definitive Series reaches its main menu with the patch installed and no network | **VERIFIED**: 18.54 s, frame evidence above |
| That menu accepts input offline | **VERIFIED**: Season Select click opened the season chooser |
| The patch applies to this build only | **VERIFIED**: `-Action Status` reports `BuildMatches: True` for `WDC.exe` |
| The same run without the patch is slower on this build | **UNTESTED**: no unpatched cut-off run was made for the Definitive Series. The comparison exists only for Season 1 (doc 19 condition C: no game process in 220 s) |
| Physically disconnected machine, no adapter | **UNTESTED**: the cut-off was firewall-scoped |
| Gameplay, saves, episode transitions offline | **UNTESTED**: nothing was played; the run stopped at the season chooser |
| The launcher's Telltale sign-in sentence can appear offline | **NOT OBSERVED**: no prompt appeared in this run. `WDC.exe` still carries the sentence, so it is recorded as an open question, not as settled |

## The instrument change

`tools/Measure-LaunchLatency.ps1` was written for Season 1: process name, app id and absolute
click points were fixed. It now takes `-ProcessName`, `-SteamAppId` and `-Steps`, where each
step is `name:xFraction,yFraction` of the **live client area**, because this frontend changes
resolution during startup (1920x1080 title, then a 1366x768 window). Defaults are unchanged, so
the Season 1 measurements in doc 19 still describe what the script does when called as before.

```powershell
# The measurement taken here (patch installed, Steam in Offline Mode, outbound blocked)
.\tools\Measure-LaunchLatency.ps1 -Label definitive-patched-offline -ProcessName WDC `
    -SteamAppId 1449690 -Steps "title-begin:0.5,0.856;menu-season-select:0.132,0.220"
```

## Machine state after this work

| Item | State |
|---|---|
| hosts file | restored byte-identical to `4DA2C479D9A3774B99BF03CECBC1FD26F731816DF9D7BCF076663BB1782B6097` |
| Firewall | `ttl-launchtest-steam`, `ttl-launchtest-webhelper`, `ttl-launchtest-wdc` all removed |
| Steam | restarted at desktop integrity, normal online mode: `WantsOfflineMode 0`, `OfflineModeEnabled False` |
| `loginusers.vdf` | restored from the tool's backup and verified identical at that moment, then rewritten by Steam on restart (hash `E7ECCBF2…DD38`, offline values 0). Steam maintains this file itself, so byte equality only holds until its next write |
| Patch record | `Set-GameOfflinePatch.ps1 -Action Status` reports `EndpointsPinned False`, `SteamOfflineMode False` |
| Game | closed by the measurement, no save was created |

## Reproduce

```powershell
# 1. arm: patch plus the three outbound blocks (elevated)
.\tools\scratch\arm-launch-test.ps1

# 2. record the launch as a frame sequence (normal integrity, so input is delivered)
.\tools\scratch\capture-launch-sequence.ps1 -Label patched-offline -Seconds 70

# 3. identify the screens from the frames: title by the red band, menu by luminance and stability

# 4. disarm (elevated): rules out, hosts restored, Steam back online
.\tools\scratch\disarm-launch-test.ps1
```

The two arm/disarm scripts and the capture loop are scratch helpers, deliberately not part of the
shipped tooling; the frame analysis is described above so it can be repeated by hand.

# REA 19: The offline launch wait, and the patch that removes it

The symptom: on a machine with no internet route, the game asks for a connection and then
sits there for a minute to ninety seconds before it will let anyone play.

This is the record of finding out what that wait actually is, and of the patch that removes
it. It is measured, not assumed, including the part where the first hypothesis was wrong.

## What was measured, and how

A launch was timed end to end by *driving the frontend*, not by watching for a window:

```
title screen -> main menu -> slot list -> episode page
```

Each step is a click at a measured point, and it only counts when the rendered frame really
changed as a result (mean grey difference ≥ 6). The clock starts when Steam is asked to
start the game; "usable" is the moment the episode page appears, i.e. the game will accept a
play command.

Instrument: `tools/Measure-LaunchLatency.ps1` (frames via `tools/Invoke-GameInput.ps1`,
frame comparison via `tools/classify_frame.py`). Results per condition are written to
`tools/scratch/latency/latency-<label>-<timestamp>.json` with the full per-attempt timeline.

An earlier version of this instrument measured "the window exists and the process responds"
and reported the launch as fast in every condition. That was the wrong measurement: the game
creates its window in ~5 s and keeps answering Windows' liveness probe while a network call
blocks elsewhere. It is recorded here because it is exactly the kind of number that looks
like proof and is not.

## Conditions and results

| # | Steam | Publisher hostnames | Time to usable frontend | Attempts per step |
|---|---|---|---|---|
| A | running normally | pinned to `127.0.0.1` | **19.93 s** (title 5.08, menu 8.86, slot 12.52, page 19.93) | 2 / 1 / 1 / 2 |
| B | running normally | unroutable `10.255.255.1` | **11.82 s** (title 1.39, menu 4.44, slot 8.16, page 11.82) | 1 / 1 / 1 / 1 |
| C | running normally, **client and game outbound traffic blocked** | pinned | **never started**: no game process in 220 s | n/a |
| D | **Offline Mode**, client and game outbound traffic blocked | pinned | **11.63 s** (title 1.37, menu 4.37, slot 8.02, page 11.63) | 1 / 1 / 1 / 1 |

Reading the table:

- **A vs B rules the publisher endpoints out.** Pinned or completely unroutable, the game
  reached a usable frontend in about ten to twenty seconds. Whatever the 60–90 s wait is, it
  is not the game waiting on `api.telltalegames.com` / `meta.telltalegames.com` on this
  machine.
- **C reproduces the reported symptom.** With the Steam client cut off from the internet and
  not in Offline Mode, the game never launched at all; Steam is where the wait is, and the
  "please connect" prompt is the client's, not the game's.
- **D is the patch.** Same cut-off condition, but the client in Offline Mode: usable at
  11.63 s, faster than the online baseline in A.

## The patch

`tools/Set-SteamOfflineMode.ps1` sets Steam's own documented per-account values in
`config\loginusers.vdf`:

```
"WantsOfflineMode"        "1"
"SkipOfflineModeWarning"  "1"
```

and restarts the client. That is the whole change. It does not touch the game, its files, its
archives, Steam's DRM or its ownership checks: Offline Mode still requires the account to
have signed in on this machine, and it does not grant anything the account does not own. It
only stops the client from spending a minute discovering it cannot reach a network that is
not there.

Reverting is byte-exact: the first change copies the original file to
`backups/steam-loginusers-original.vdf` (SHA-256 `06A5ABE63D384E2D70FAC1D775C320D87DB783F4D7012B445299F404B29CA87C`
on this machine) and `-Action Disable` writes those bytes back and verifies the hash.

```powershell
.\tools\Set-SteamOfflineMode.ps1 -Action Enable    # elevated; sets both values and restarts Steam
.\tools\Set-SteamOfflineMode.ps1 -Action Status
.\tools\Set-SteamOfflineMode.ps1 -Action Disable   # elevated; byte-identical revert
```

### A second, complementary switch

`tools/Set-OfflineLaunchPatch.ps1` pins both publisher hostnames to `127.0.0.1` in the hosts
file, with a recorded pre-patch byte length and hash so `-Action Remove` truncates back
byte-for-byte. It exists because it removes the *possibility* of a publisher-side timeout
anywhere in the game (episode pages, news banner, later calls), and because it is the
reversible form of the block this project has used all along. **It is not what fixes the
launch wait**: condition A measured it as no faster than an unroutable address.

```powershell
.\tools\Set-OfflineLaunchPatch.ps1 -Action Install   # elevated
.\tools\Set-OfflineLaunchPatch.ps1 -Action Status
.\tools\Set-OfflineLaunchPatch.ps1 -Action Remove    # elevated; byte-identical revert
```

## A trap worth recording: elevation breaks input

One measurement run came back with every menu click ignored. The cause was not the game: the
Steam client had been started from an elevated shell, so Steam (and the game it launched)
ran at high integrity, and Windows' UIPI refuses input injection from a normal process into
an elevated window. `Stop-Process` on that game also failed with access denied.

`Set-SteamOfflineMode.ps1` therefore restarts Steam through `explorer.exe`, so it comes back
at the desktop's integrity level. Any future automation of this game must do the same, or it
will look like "the game ignores input" when it is Windows refusing to deliver it.

## Reproduce

```powershell
# 1. baseline with the client cut off and no patch  (nuisance firewall rules, removed afterwards)
#    -> no game process within 220 s
.\tools\Measure-LaunchLatency.ps1 -Label steam-blocked -TimeoutSeconds 220

# 2. apply the patch (elevated), then measure again under the same cut-off
.\tools\Set-SteamOfflineMode.ps1 -Action Enable
.\tools\Measure-LaunchLatency.ps1 -Label steam-offline-patched -TimeoutSeconds 220

# 3. revert
.\tools\Set-SteamOfflineMode.ps1 -Action Disable
```

## Machine state after this work

| Item | State |
|---|---|
| hosts file | restored byte-identical to pre-test `4DA2C479D9A3774B99BF03CECBC1FD26F731816DF9D7BCF076663BB1782B6097`, no publisher entries |
| `loginusers.vdf` | byte-identical to its original, hash `06A5ABE6…A87C` |
| Firewall | the three test rules (`steam.exe`, `steamwebhelper.exe`, `WalkingDead101.exe`, outbound block) were removed |
| Steam | restarted at desktop integrity, normal online mode |
| Saves | backed up before the session: `backups/20261106-075357-pre-unattended-ep2` |

## Status

| Item | Status |
|---|---|
| Steam Offline Mode removes the offline launch wait | **VERIFIED**: condition D, 11.63 s, same cut-off that produced no launch in 220 s |
| Publisher endpoints cause the launch wait | **REFUTED**: conditions A and B both launched in ≤ 20 s |
| Offline-mode patch is byte-reversibly removable | **VERIFIED**: unit tests, `loginusers.vdf` back to its original hash |
| Hosts patch install/remove is byte-reversible | **VERIFIED**: unit tests, including a refusal when the file changed after install |
| Offline launch on a machine with **no adapter at all** | **UNTESTED**: this machine was cut off at the firewall, which is the closest reversible emulation available; a physically disconnected host was not available to test |

The one honest gap: the reproduction used a scoped firewall cut rather than pulling the
machine's network, because disconnecting the host is not something to do unilaterally. If a
genuinely disconnected launch still waits, the next measurement to take is
`Measure-LaunchLatency.ps1 -Label truly-offline` on that host.

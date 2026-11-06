# REA 20: Per-game offline patches for Seasons 2, 3 and 4, Michonne and the Definitive Series

The launch wait is described and fixed once in [doc 19](19-offline-launch-stall.md): on a
machine with no internet route, the Steam client spends a minute or more deciding it cannot
connect before it will start the game. The fix is Steam's own Offline Mode, which is a
client-wide setting and therefore applies to every game Steam launches.

What is per game is everything else: which executable runs, which build it is, and which
publisher hostname that build would try to reach. This document records those facts for the
other Walking Dead releases in this repository and the patch entry point that uses them.

## What a patch consists of

`tools/Set-GameOfflinePatch.ps1` performs two steps, both reversible, both delegated to tools
that already own their mechanics:

| Step | Effect | Tool | Revert |
|---|---|---|---|
| 1 | Steam starts in Offline Mode instead of waiting for a connection | `tools/Set-SteamOfflineMode.ps1` | original `loginusers.vdf` written back and hash-checked |
| 2 | That build's publisher endpoint is pinned to `127.0.0.1`, so a blocked startup call fails in microseconds instead of timing out | `tools/Set-OfflineLaunchPatch.ps1` | marked block removed; hosts file restored byte-for-byte |

Before either step runs, the installed executable's SHA-256 is compared with the profile. A
different build is refused with exit 24 rather than patched, so every claim in a profile stays
attached to the binary it was measured on.

Neither step patches a game file, bypasses Steam DRM, or grants ownership. Offline Mode still
requires an account that has signed in on that machine with a cached licence.

```powershell
.\tools\Set-GameOfflinePatch.ps1 -Game twd-s2-steam-261030 -Action Status     # read-only
.\tools\Set-GameOfflinePatch.ps1 -Game twd-s2-steam-261030 -Action Install    # elevated
.\tools\Set-GameOfflinePatch.ps1 -Game twd-s2-steam-261030 -Action Remove     # elevated
```

## The builds these patches target

| Profile | Game | App id | Build | Executable | Endpoint pinned | Tag |
|---|---|---|---|---|---|---|
| `twd-s1-steam-207610` | Season 1 | 207610 | 244978 | `WalkingDead101.exe` | `api.telltalegames.com`, `meta.telltalegames.com` | `twd-s1-v1.0.0` |
| `twd-s2-steam-261030` | Season Two | 261030 | 1298753 | `TheWalkingDead2.exe` | `services.telltalegames.com` | `twd-s2-v1.0.0` |
| `twd-s3-steam-536220` | A New Frontier | 536220 | 2784143 | `WalkingDead3.exe` | `services.telltalegames.com` | `twd-s3-v1.0.0` |
| `twd-michonne-steam-429570` | Michonne | 429570 | 1094475 | `WalkingDeadMichonne.exe` | `services.telltalegames.com` | `twd-michonne-v1.0.0` |
| `twd-s4-steam-866800` | The Final Season | 866800 | 3679591 | `WalkingDead4.exe` | `services.telltalegames.com` | `twd-s4-v1.0.0` |
| `twd-definitive-steam-1449690` | Definitive Series | 1449690 | 5952618 | `WDC.exe` | `services.telltalegames.com` | `twd-definitive-v1.0.0` (launch measured, doc 21) |

Every row above was read from this machine: the app id and build id from the Steam
`appmanifest_<appid>.acf`, the executable and its hashes from the install directory itself.

## Where the endpoints came from

The Season 1 build carries `https://meta.telltalegames.com/1/` as its only publisher URL
literal and connects to `api.telltalegames.com` during play (doc 15). The five later builds do
not use those names. Scanning the shipped executables for hostname and URL literals gives a
different picture:

| Build | Publisher literals found in the executable |
|---|---|
| Season Two | `https://services.telltalegames.com/1/bulkresource`, `https://services.telltalegames.com/1/syncfs/`, `www.telltalegames.com` |
| A New Frontier | `https://services.telltalegames.com`, `https://services.telltalegames.com/1/syncfs/`, `www.telltalegames.com` (all three executables) |
| Michonne | `https://services.telltalegames.com`, `https://services.telltalegames.com/1/syncfs/`, `www.telltalegames.com` |
| The Final Season | `https://services.telltalegames.com`, `https://services.telltalegames.com/1/syncfs/`, `www.telltalegames.com` |
| Definitive Series | `https://services.telltalegames.com`, `https://services.telltalegames.com/1/syncfs/`, `www.telltalegames.com` (in the sign-in help sentence) |

`services.telltalegames.com` is the one pinned: it is the host a startup or file-sync call
would block on. `www.telltalegames.com` appears as a store link, not a startup call, so it is
recorded but deliberately left alone; pinning it would only break an in-game link that no
longer resolves anyway.

This is string evidence, not packet capture. No netstat sample or capture was taken while
these builds were running, and the profiles say so.

## Status, item by item

| Item | Status | Basis |
|---|---|---|
| Steam Offline Mode removes the offline launch wait | **VERIFIED** | measured on Season 1: 11.63 s to a usable frontend with the client and game cut off, against no launch in 220 s without it (doc 19, condition D) |
| Each profile's recorded executable hash matches the installed binary | **VERIFIED** | `Set-GameOfflinePatch.ps1 -Action Status` on this machine: `BuildMatches: True` for Seasons 2, 3 and 4 and Michonne |
| Each build's publisher endpoint, as listed above | **VERIFIED as a string literal** | executable scan on this machine; not observed on the wire |
| Patch install and revert are byte-exact and per-game | **VERIFIED** | automated: `tests/Run-Tests.ps1` installs two games' patches, removes one and checks the other survives, then checks the last removal restores the original hosts bytes |
| The patch refuses a build it was not written for | **VERIFIED** | automated: a mismatched executable exits 24 and pins nothing |
| The Definitive Series install and its executable hash | **VERIFIED** | `-Action Status` on this machine after installation: `BuildMatches: True` against `WDC.exe`, app 1449690, build 5952618 |
| Offline launch of the Definitive Series with the patch installed | **VERIFIED** | main menu at 18.54 s with the client and game cut off; the menu accepted a click that opened the season chooser (doc 21) |
| Offline launch time on Seasons 2, 3, 4 and Michonne | **UNTESTED** | no launch was timed on those builds; their profiles record `launchVerification: UNTESTED` |
| Gameplay, saves and episode transitions offline on those builds | **UNTESTED** | nothing was played; only Season 1 has gameplay evidence (doc 08) |
| Whether the Definitive Series launcher shows a Telltale sign-in prompt offline | **UNTESTED** | `WDC.exe` contains that sentence as a string; no launch was made to see whether it is reachable |

The honest summary: the launch fix is proven on one game and is a Steam client setting, while
the per-game part, the endpoint set and the build identity, is read from the shipped binaries
but has not been exercised by launching each game.

## The Definitive Series

This was the last patch in the queue, and it was blocked until the app was actually installed:
for a while Steam had app 1449690 registered on the `F:` library but reported `buildid 0`,
`SizeOnDisk 0` and `StateFlags 1026` against an empty folder. Guessing its endpoint from
Seasons 2 to 4 would have been fabrication, so the profile recorded the blocked reading with no
executable, no hostname and no endpoint, and the driver refuses such a profile (exit 21) by
design.

The app was then installed on the same machine. The reading is now `StateFlags 4`,
`SizeOnDisk 48,816,593,394`, `buildid 5952618`, eight top-level entries and a populated
`Archives` folder, and the profile was rewritten from the real binary:

| Fact | Value |
|---|---|
| Executable | `WDC.exe`, 18,162,896 bytes, x64, linked 2019-11-25 09:42:12Z |
| SHA-256 | `5f44e53fcaec4c59c8c2f79403722076fc1c518c0d006d2a1262efeaec656782` |
| File version | 2019.11.25.83, product GameApp 1.0.0.1 |
| Publisher literals | `https://services.telltalegames.com`, `https://services.telltalegames.com/1/syncfs/` |
| Content | 480 archives, 48,794,065,464 bytes, flat in `Archives` with no per-episode folders |
| Episode codes | 101 to 106, 201 to 205, 301 to 305, 401 to 404 |

Two things about this build are worth recording rather than smoothing over. First, the archives
are flat: Seasons 1 to 4 keep episode directories, while the collection names every archive
`WDC_pc_WalkingDead<code>_<class>` or `WD4_<language>_<set><code>` in one folder, so any tooling
that assumes per-episode directories will not fit it. Second, code 106 exists in Season 1 with
six archives, which is the slot 400 Days occupies in Telltale packaging; the collection
includes that content, which the standalone Season 1 install here does not have. Neither the
code mapping nor the content was confirmed by playing it.

`WDC.exe` also carries the sentence "To unlock your game, log in with your Telltale e-mail
address and password." No login gate was exercised and no launch was made, so whether this build
can present that prompt offline is unknown and is listed as such in the profile. If it does
appear, it is a different problem from the launch wait and this patch does not address it.

## Several games, one hosts file

All patches share one marked block in the hosts file, because Windows has one. Installing a
second game's patch merges its endpoint into the block instead of replacing what is already
there, and removing one game's patch drops only that game's entries. The block is removed
entirely when its last entry goes, which is the point at which the file returns to its
pre-patch bytes.

## Reproduce

```powershell
# read-only check of every profile on this machine
foreach ($game in 'twd-s2-steam-261030','twd-s3-steam-536220','twd-michonne-steam-429570','twd-s4-steam-866800','twd-definitive-steam-1449690') {
    .\tools\Set-GameOfflinePatch.ps1 -Game $game -Action Status
}

# apply, then revert, one game (both need an elevated shell)
.\tools\Set-GameOfflinePatch.ps1 -Game twd-s3-steam-536220 -Action Install
.\tools\Set-GameOfflinePatch.ps1 -Game twd-s3-steam-536220 -Action Remove

# the automated coverage, including the two-game merge and the build-identity refusal
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-Tests.ps1
```

## Tags

Each game's patch landed in its own commit and carries its own annotated tag, listed in the
table above. `git tag -l 'twd-*-v1.0.0'` lists all six; the tag points at the commit that added
that game's profile and its patch wiring, so each game can be checked out independently.

# Inventory of the owned installations

Measured on 2026-11-06 on this machine (Windows 10 19045, `D:\SteamLibrary`).
Every hash below was computed from the installed file; every endpoint claim in
[02-dependency-map.md](02-dependency-map.md) comes from the same read.

## How the inventory was produced

* Steam manifests (`steamapps/appmanifest_<appid>.acf`) were read for the app id,
  build id, `StateFlags`, install directory and on-disk size. `StateFlags` bit 4
  means fully installed; a manifest alone does not.
* Executables and payload DLLs were parsed for machine type, subsystem, link
  timestamp, sections and imported modules (`tools/Preservation.Common.psm1`).
* Host-like strings were extracted from every binary under 48 MB.
* Nothing was written to any installation. The only writes were JSON reports
  under `docs/preservation/data/`.

**A limitation that matters:** a Steam `.bind` section means the executable's
code is wrapped by Steam DRM and its strings are not readable statically. Titles
with `.bind` are marked `bind` below; for them, "no endpoint strings found" is
not evidence of no dependency, and their profiles say so.

## Installed and analysable

| Title | App | Build | On disk | Engine | Primary binary | SHA-256 (first 16) | bind |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Command & Conquer: Generals | 2229870 | 17435253 | 1.69 GB | SAGE (2003) | `Game.dat` (12.2 MB) | `88b03cfb9851c84e` | launcher only |
| C&C: Generals – Zero Hour | 2732960 | 17435311 | 2.94 GB | SAGE expansion | `Game.dat` (6.5 MB) | `420fba1dbdc4c14e` | launcher only |
| Command & Conquer: Renegade | 2229890 | 17427416 | 1.48 GB | Westwood 3D (2002) | `Game.exe` (4.8 MB) | `7fe262e00f871236` | launcher only |
| C&C 3: Tiberium Wars | 24790 | 17447444 | 6.53 GB | SAGE 2 (RNA) | `RetailExe/1.10/cnc3game.dat` (16.3 MB) | `af568a89b6d0d4f6` | no |
| C&C 3: Kane's Wrath | 24810 | 17447564 | 4.96 GB | SAGE 2 expansion | `RetailExe/1.3/cnc3ep1.dat` (24.3 MB) | `1716c954ab80cf05` | launcher only |
| C&C 4: Tiberian Twilight | 47700 | 17459716 | 6.03 GB | SAGE (C&C4) | `CNC4.exe` (.NET launcher, 10.2 MB) | `eee9efd36ce856c3` | no |
| Friday the 13th: The Game | 438740 | 7200111 | 9.49 GB | Unreal Engine 4 | `SummerCamp/Binaries/Win64/SummerCamp.exe` (60.7 MB) | `04dbb06a6d720837` | no |
| Plants vs. Zombies GOTY | 3590 | 11226 | 51 MB | PopCap SexyAppFramework | `PlantsVsZombies.exe` (5.3 MB) | `868f8e2bab0d6a7e` | no |
| Plants vs. Zombies: Replanted | 3654560 | 21398230 | 1.71 GB | Unity (IL2CPP) | `Replanted.exe` (0.7 MB) + `GameAssembly.dll` (83 MB) | `2b7ef100ec84c215` | no |
| SimCity 3000 Unlimited | 2741560 | 12966690 | 614 MB | Maxis GZ | `Apps/SC3U.exe` (1.2 MB) | `38781bc3c0041a71` | no |
| SimCity 4 Deluxe | 24780 | 4644414 | 1.24 GB | Maxis SC4 | `Apps/SimCity 4.exe` (7.9 MB) | `f9b059d29940d1a2` | yes |
| Need for Speed: Rivals | 1262600 | 10351327 | 10.18 GB | Frostbite 3 | `NFS14.exe` (30.4 MB) | `66b0cd705d8e1b13` | no |

Full hashes for every profiled binary live in `games/<id>/profile.json`.

## Owned but not installed

| Title | App | Manifest state | Finding |
| --- | --- | --- | --- |
| C&C: Red Alert 3 | 17480 | `StateFlags 1026`, `LastUpdated 0`, 463 MB of 7.15 GB downloaded, install directory contains no files | A partial download. There is nothing to analyse and no profile is claimed. |
| C&C Remastered Collection | 1213210 | build `0`, `SizeOnDisk 0`, empty install directory | Owned, never downloaded. |

Anything claimed about those two would be invented, so nothing is claimed.

## Structural findings that shape the work

1. **The visible executable is often not the game.** Generals, Zero Hour, Kane's
   Wrath and Renegade all ship a small launcher (`Generals.exe`, `CNC3EP1.exe`,
   `Renegade.exe`) that reads its own config and starts a payload: `Game.dat`,
   `cnc3ep1.dat`, `Game.exe`, `Server.dat`. Profiling the launcher alone would
   have missed every dependency string in Generals and Zero Hour — both
   `Game.dat` files carry the GameSpy stack, while the launchers carry nothing.
2. **`RetailExe/<version>` keeps older builds.** Tiberium Wars ships 1.0 to 1.10
   plus `.bak` copies; Kane's Wrath ships 1.0 to 1.3. The profile records the
   newest versioned binary and says so; which one the launcher picks is a runtime
   question.
3. **A zero-byte placeholder exists.** `Kane's Wrath\CNC3TW\CNC3.exe` is 0 bytes,
   a packaging artefact that must not be mistaken for an executable.
4. **Runtimes are visible in the layout.** F13 is a UE4 tree (`Engine/`,
   `SummerCamp/Binaries/Win64`, `Saved/`); Replanted is Unity IL2CPP
   (`il2cpp_data`, `GameAssembly.dll`); Rivals is Frostbite content-addressed
   storage (`cas.cat` plus numbered `.cas`); SimCity 3000 is a GOG-packaged build
   (`goggame-2086050016.dll`, 2022 link date) delivered through Steam.
5. **Renegade ships infrastructure, not just a game.** `RenegadeFDS/` contains
   `RenegadeServer.exe`, `Server.dat`, `Server.ini` and `RenRem.exe`. Its
   `Server.ini` documents `GameType = WOL | GameSpy | LAN`. That is the basis of
   the first implementation milestone: [03-renegade-lan.md](03-renegade-lan.md).
6. **Anti-cheat is present where it matters.** F13 ships EasyAntiCheat, Generals
   and Zero Hour ship PunkBuster (`P2XDLL.DLL`). Neither is bypassed by this
   program; both constrain what multiplayer preservation can honestly promise.
7. **Some installations are only wrappers.** PvZ GOTY's `PlantsVsZombies.exe`
   cannot start without the Steam client and extracts the game it actually runs
   to `C:\ProgramData\PopCap Games\PlantsVsZombies\popcapgame1.exe`, staging
   assets and saves under `C:\ProgramData\Steam\PlantsVsZombies`. The files in
   the installation therefore describe the wrapper, not the game. Measured in
   [04-pvz-offline.md](04-pvz-offline.md); it is the reason that document records
   two blocked executables and a save path outside the install.

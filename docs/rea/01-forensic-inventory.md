# REA 01: Forensic inventory

Target: `C:\Program Files (x86)\Steam\steamapps\common\The Walking Dead`
Captured: 2026-11-05, on the machine that owns the installation.

Every fact below was read from the installation. Nothing here is inferred unless it
is explicitly labelled **Inference**.

## 1. Installation identity

| Property | Value | Source |
| --- | --- | --- |
| Steam app id | 207610 | `installscript.vdf`, `appmanifest_207610.acf` |
| Depot | 207611 | `appmanifest_207610.acf` |
| Manifest id | 5142651071651553335 | `appmanifest_207610.acf` |
| Build id | 244978 | `appmanifest_207610.acf` |
| `StateFlags` | 4 (fully installed) | `appmanifest_207610.acf` |
| Installed size | 3,809,843,441 bytes | `appmanifest_207610.acf` |
| Files (recursive) | 130 | `tools/Get-GameInventory.ps1` |
| Executable | `WalkingDead101.exe`, 8,861,712 bytes | filesystem |
| Executable link timestamp | 2014-04-25 22:22:10 UTC | PE header |
| Architecture | x86 / PE32, GUI subsystem | PE header |
| Display name | "The Walking Dead" | `appmanifest_207610.acf` |

The installation had **never been launched** before this investigation
(`LastPlayed 0`, no `Documents\Telltale Games`, no Telltale registry key). That
matters: the first launch observations are a clean first-run baseline.

## 2. Top-level files

| File | Size | Role |
| --- | --- | --- |
| `WalkingDead101.exe` | 8,861,712 | Game executable + Steam DRM stub |
| `steam_api.dll` | 120,616 | Steamworks SDK client shim |
| `fmodex.dll` | 1,086,464 | FMOD Ex audio runtime |
| `installscript.vdf` | 957 | Steam install script (registry + DirectX) |
| `DirectX/` | 13 files | Bundled DirectX 9 redistribution |
| `Pack/` | 112 archives, 5 groups | All game content |

Core hashes (SHA-256):

```
WalkingDead101.exe  44a5ff21cbb085812c48179259141ff5c83eaeaa3423b4734b43533df0a2528d
steam_api.dll       b0fd893eaa8a225510389e04c0802312539a01fd2eb3a1a8a38005cee7f1d10f
fmodex.dll          4d0ecbb2e3a60cba9e754ab3724dbbbd11de044a896914aabe01fe45c88ac956
installscript.vdf   5dafbf786e5e35c387f680c055bdcd86bc112a95ca37d1b47131314a85483f31
```

## 3. Executable analysis

```
Machine          0x014C (x86)
Optional magic   0x010B (PE32)
Subsystem        GUI (2)
Sections         .text .rdata .data .rsrc .reloc .bind
```

The presence of a **`.bind` section** identifies the Steam DRM wrapper
(SteamStub). This is the single most important architectural fact in the whole
project: the executable is only meant to run through Steam, with a valid licence.

Imported modules:

```
ADVAPI32.dll  COMCTL32.dll  d3d9.dll  d3dx9_41.dll  DINPUT8.dll  fmodex.dll
GDI32.dll  KERNEL32.dll  ole32.dll  OLEAUT32.dll  SHELL32.dll  SHLWAPI.dll
USER32.dll  VERSION.dll  WINMM.dll  WLDAP32.dll  WS2_32.dll
```

`WS2_32.dll`/`WLDAP32.dll` come with the statically linked libcurl/OpenSSL stack
visible in strings (`Authorization: Digest`, `TLS Web Client Authentication`,
`curl.haxx.se/rfc/cookie_spec.html`). That stack is what talks to the Telltale API.

## 4. Supporting libraries

`steam_api.dll` (linked 2012-03-15) exports the classic flat Steamworks API and the
versioned interfaces `SteamClient012` and `SteamUser016`. Imported entry points
include `SteamAPI_Init`, `SteamAPI_IsSteamRunning`,
`SteamAPI_RestartAppIfNecessary`, `SteamAPI_RunCallbacks`,
`SteamAPI_RegisterCallback`, `SteamAPI_RegisterCallResult` and
`SteamAPI_GetSteamInstallPath`. Embedded PDB path:
`e:\buildslave\steam_rel_client_win32\build\src\steam_api\Release\steam_api.pdb`.

`fmodex.dll` (linked 2011-12-12) is FMOD Ex, importing `MSACM32`, `WINMM`,
`WSOCK32` (the socket import is part of FMOD's netstream support, not evidence that
the game streams audio).

## 5. Content archives

All **112** `.ttarch` files start with the same 16-byte header pattern:

```
09 00 00 00 | 01 00 00 00 | 02 00 00 00 | 02 00 00 00
```

The leading `uint32` is `9` in every archive, which is why the profile records
`archiveVersion: 9`. The remaining fields are recorded verbatim but their meaning is
**not** claimed here; parsing the full table is Milestone 3 work.

Content groups (all inside `Pack/`):

| Group | Files | Bytes | Interpretation |
| --- | --- | --- | --- |
| `default` | 27 | 532,752,883 | Episode 1 base content |
| `WalkingDead102` | 25 | 1,027,518,529 | Episode 2 |
| `WalkingDead103` | 21 | 717,755,136 | Episode 3 |
| `WalkingDead104` | 22 | 739,274,135 | Episode 4 |
| `WalkingDead105` | 17 | 776,846,664 | Episode 5 |

Archive naming is consistent and informative:

```
1_<episode>_english_pc_anichore.ttarch
2_<episode>_english_pc_data.ttarch
3_<episode>_english_pc_voice.ttarch
4_<episode>_english_pc_ms.ttarch
5_<episode>_english_pc_txmesh.ttarch
6_pc_only_shaders.ttarch            (identical size in every group)
0_*.ttarch                          numbered patches/backpatches
```

Every group also contains `0_20_WalkingDead106_<episode>backpatch_s.ttarch`.
**Inference:** `WalkingDead106` is the 400 Days content, back-patched into each
episode so that choices can be imported. This is not yet confirmed at runtime and
is recorded as a hypothesis in the profile, not as a finding.

Two archive sets are byte-identical in size across all groups
(`6_pc_only_shaders.ttarch` = 13,096,768 bytes in all five), suggesting shared
renderer content shipped per episode rather than a fallback lookup.

## 6. Install script and system state

`installscript.vdf` declares:

* registry key `HKCU\Software\Telltale Games\WalkingDead101.exe`
* `franchise` = `WalkingDead100`, `distribution` = `Telltale`
* `savegamefoldername` = `The Walking Dead`
* declared `version` = `1.0.0.0` (installer metadata, **not** the build id)
* `Run Process` → `DirectX\DXSETUP.exe /silent`, guarded by
  `HKLM\SOFTWARE\Valve\Steam\Apps\207610`

Observed: on first launch Steam executed `DXSETUP.exe` (exit code 0 in
`logs\runprocess_log.txt`) and the DirectX 9 runtime became available
(`d3dx9_41.dll` present in SysWOW64). The declared Telltale registry key was
**absent before first launch**; the game does not appear to depend on it being
pre-created.

## 7. Generated data

`tools/Get-GameInventory.ps1` writes the full machine-readable inventory
(per-file size + SHA-256 + PE detail + archive headers) to
`docs/rea/data/inventory.json`. That directory is git-ignored because it contains
absolute local paths; regenerate it on your own machine with:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Get-GameInventory.ps1 -IncludeUserState
```

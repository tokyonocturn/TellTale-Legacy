# REA 02: Engine and architecture

## Engine identification

| Component | Evidence |
| --- | --- |
| Engine | **Telltale Tool**: PDB path `C:\Telltale\src\alt\Engine\GameApp\GameApp.pdb` in the executable |
| Scripting | **Lua 5.1.4**: `$Lua: Lua 5.1.4 Copyright (C) 1994-2008 Lua.org, PUC-Rio $`, plus `_boot.lua`, `_title.lua`, `Dialog.lua` and `!\\lua\\?.lua` search patterns |
| Content containers | **TTArchive**: C++ symbols `TTArchive`, `TTArchive_File`, `FileInfo@TTArchive`, `*.ttarch` |
| Rendering | Direct3D 9: `d3d9.dll`, `d3dx9_41.dll`, `D3DXGetShaderVersion`, `IDirect3DSurface9`, `IDirect3DVertexDeclaration9` |
| Audio | FMOD Ex: `fmodex.dll`, `%sFMODGetCodecDescription%s`, runtime `FMOD_Memory_GetStats` |
| Input | DirectInput 8: `DINPUT8.dll` |
| UI | Win32 + ATL windows (window class `ATL:013D5C38`, title `Telltale Games`) |
| Networking | Statically linked libcurl/OpenSSL inside the executable (`WS2_32`, `WLDAP32`) |

The engine is data-driven: gameplay modules are described by `.prop` property
bundles (`module_dialog.prop`, `module_camera.prop`, `module_scene.prop`,
`module_inversekinematics.prop`, …) and driven by Lua state machines
(`Dialog.lua`, `runtime_dialog_logic.prop`, `all_dlg_state.prop`).

## Content layering

```text
GameRoot/
  WalkingDead101.exe        Steam-DRM wrapped, x86, statically linked engine
  steam_api.dll             Steamworks shim (SteamClient012 / SteamUser016)
  fmodex.dll                audio
  Pack/
    default/                Episode 1 content + global patches
    WalkingDead102/         Episode 2 content + patches
    ...
    WalkingDead105/         Episode 5 content + patches
```

Observed naming supports a layered mount model: every episode directory contains
both its own base archives (`1_`…`6_`) and a numbered `0_*` series of patch and
backpatch archives, while `default/` holds Episode 1 plus global fix archives
(`0_97_global_steam_102.ttarch`, `0_98_patch.ttarch`, `0_99_patch.ttarch`).

**Inference (not yet proven at runtime):** the loader mounts `default` first, then
the active episode directory, then applies `0_*` archives in ascending name order as
overrides. Evidence for this shape is the numbering convention and the presence of
per-episode copies of the same backpatch; it has not been confirmed by tracing the
mount order. Confirming it is a Milestone 2/3 task and must not be assumed by any
profile logic yet.

## Property bundles (`.prop`)

`.prop` files are binary bundles, not plain text. A decodable one,
`Pack/WalkingDead105/StatsItem_Chapter8.prop`, begins with the ASCII magic `ERTM`
and contains typed fields:

```
StatManager - Internal Name                       StatsItem_Chapter8
StatManager - Platform - Steamworks - ID          com.telltalegames.WalkingDead105.ch.08
StatManager - Platform - Steamworks - String Token 1.3
StatManager - Platform - Xbox - Achievement ID    41
StatManager - Condition - Logic Keys              logic_game
Completed Chapter 8
```

This is direct evidence for the Steamworks stat/achievement namespace. It also
shows the same logical content mapped to PS3/Xbox/Steam ids, useful when adding
profiles for console-era re-releases.

Most other `.prop` files in the user profile directory (for example `prefs.prop`)
are obfuscated: their first bytes are non-ASCII and non-repeating, while still
containing readable fragments such as repeated `false` values. **No claim is made
about the obfuscation scheme.** Parsing it is deliberately out of scope for now;
the backup tool treats these files as opaque bytes and verifies them by hash.

## Platform abstraction in the executable

The binary contains `Platform*` entry points (`PlatformUnlockAchievement`,
`PlatformGetAchievements`, `PlatformOpenAchievementUI`,
`PlatformResetStatsAndAchievements`) and a `SteamAchieve` implementation with
`UserStatsReceived_t`, `UserStatsStored_t` and `UserAchievementStored_t`
callbacks. This is the engine's platform abstraction layer, not game logic, which
is why achievement handling can be described independently of gameplay.

## Why this matters for preservation

1. The engine itself is **self-contained** in the executable plus two DLLs. No .NET,
   no Java, no external runtime that can disappear.
2. All content is on disk in 112 archives; nothing is streamed at runtime.
3. The only dynamic external contract is **Steam** (DRM + stats) and the optional
   **Telltale HTTP API**.
4. Because content is layered by directory, separate compatibility profiles per
   episode or per release are practical without duplicating the install.

## Explicit unknowns

* Full `.ttarch` v9 table layout (only the first 16 bytes are characterised).
* `.prop` obfuscation/encryption used for `prefs.prop` and most content props.
* Exact archive mount order and override rules.
* Whether `WalkingDead106` archives are 400 Days, and how episode selection loads
  them.
* Console/Definitive Series equivalents of every item above.

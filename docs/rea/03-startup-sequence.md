# REA 03 — Startup sequence (observed)

All timings and states below come from real launches recorded by
`tools/Start-ObservedSession.ps1` and from Steam's own logs
(`logs/console_log.txt`, `logs/gameprocess_log.txt`, `logs/runprocess_log.txt`).

## Sequence

### 1. Direct execution is rejected by design

Starting `WalkingDead101.exe` directly (no Steam launch context):

```
process started  -> exits within ~1-3 s with exit code 53
Steam log        -> "AppID 207610 state changed : Fully Installed,App Running,"
                    "Game process added : AppID 207610 ... ProcID <new pid>"
```

The executable calls `SteamAPI_RestartAppIfNecessary` (present in `steam_api.dll`),
exits, and Steam relaunches it with a valid launch context. **Exit code 53 is the
normal handoff, not a crash.** This is why direct-launch testing without Steam
produces a false "the game won't start" result.

### 2. First launch performs the install script

On the first ever launch Steam ran the `Run Process` section of
`installscript.vdf`:

```
logs\runprocess_log.txt:
  [AppID 207610] Exit Code (0) : "...\DirectX\DXSETUP.exe" /silent
```

This is when the DirectX 9 runtime (`d3dx9_41.dll`) became available. A machine
that never launched the game may still be missing it; that is a real first-run
offline prerequisite when the DirectX redistributable has not been installed from
another source.

### 3. Splash and account API

Immediately after launch:

* a visible window appears with class `ATL:013D5C38`, title **`Telltale Games`**,
  geometry 1030×797 (client area 1024×768-class);
* the process resolves **`api.telltalelegames.com`** (CloudFront, `18.245.113.0/24`)
  and holds an HTTPS connection to it while the splash is displayed;
* the process creates `%USERPROFILE%\Documents\Telltale Games\The Walking Dead\`
  and writes `prefs.prop` plus `steam_autocloud.vdf`;
* Steam's overlay attaches (`gameoverlayrenderer.dll` is loaded in-process).

### 4. Main menu

The splash resolves to the main menu without any input:

```
PLAY
EPISODE STATUS   (with a red alert badge)
SETTINGS
EXIT GAME
```

The main window keeps the title `Telltale Games`; the title does not change to the
game name, so window title alone is not a reliable "menu is ready" signal for
automation. Use a window capture or an input probe instead.

Menu appearance is identical online and with the Telltale API blocked, except that
the offline run shows a static news banner
("For the latest information on The Walking Dead five-part gam…") where the online
run shows live news text.

### 5. Shutdown

Closing via the normal window message exits cleanly within ~15 s and leaves the
process list empty. `prefs.prop` is rewritten on clean exit (size changed across
sessions: 6447 → 6591 → 6647 bytes), which means **preferences are persisted at
exit**, not only at launch. Any preservation tooling must therefore treat an
in-progress session as "do not snapshot".

## Timing summary

| Phase | Observed |
| --- | --- |
| Direct-exec handoff | process exits in ~1–3 s, code 53 |
| Steam launch → splash window | ~2–5 s |
| Splash → main menu | within the 75 s observation window; menu present at first sample of the offline run |
| Clean exit | < 15 s |
| Steam overlay attach | after splash appears |

## Startup dependencies

| Dependency | Required for startup? | Evidence |
| --- | --- | --- |
| Steam client + valid licence | **Yes** | `.bind` DRM section, `SteamAPI_Init`, `RestartAppIfNecessary` |
| DirectX 9 runtime (`d3dx9_41`) | **Yes** | static import; first-run DXSETUP |
| FMOD Ex (`fmodex.dll`) | **Yes** | static import |
| `api.telltalegames.com` | **No** | menu reached with endpoint blackholed |
| Steam stats/achievements | No | `UserStatsReceived_t` path is async; no stats blocking observed |
| `Documents\Telltale Games` | Created automatically | first-run observation |

## Reproducing the observation

```powershell
# Normal launch, observed for 60 s, then closed
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Start-ObservedSession.ps1 `
    -ViaSteam -Label baseline -ObservationSeconds 60 -StopAtEnd

# Attach to a session you started yourself
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Start-ObservedSession.ps1 `
    -AttachProcessId <pid> -Label manual -ObservationSeconds 30
```

Session logs land in `docs/rea/data/sessions/` (git-ignored: they contain local
paths and machine-specific process data).

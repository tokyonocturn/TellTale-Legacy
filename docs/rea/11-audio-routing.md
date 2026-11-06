# 11 — Audio endpoint `100027813`

Status: **endpoint identified, verification instrumented, routing not applied, and
game audio could not be measured at all.** The game emitted no audio in any state
reachable in this session (see *Why nothing could be measured*), so the routing
requirement is unresolved rather than satisfied. Nothing here claims otherwise.

## What `100027813` actually is

`100027813` is a **display name**, not an endpoint identifier. It belongs to an
NVIDIA HDMI audio output, and four enumerated devices carry that name:

| Endpoint id | State | Outcome |
|---|---|---|
| `{0.0.0.00000000}.{63b45a0d-a22d-42a4-a438-b64a52829507}` | `DeviceState = 1` | **live — this is the target** |
| `{0.0.0.00000000}.{825aafdd-89f4-42e0-b1dd-dc80ce2d628c}` | `0x20000004` | not present (stale) |
| `{0.0.0.00000000}.{a17e01de-ea23-41fe-b932-fabccfab6dba}` | `0x20000004` | not present (stale) |
| `{0.0.0.00000000}.{3c032cf1-7069-4bf3-8a04-c112b815c626}` | `0x20000004` | not present (stale) |

Target details:

| Field | Value |
|---|---|
| Friendly name | `100027813 (NVIDIA High Definition Audio)` |
| PnP instance | `SWD\MMDEVAPI\{0.0.0.00000000}.{63B45A0D-A22D-42A4-A438-B64A52829507}` |
| Render default | **no** |
| Device interface | `{2}.\\?\hdaudio#func_01&ven_10de&dev_009f&subsys_104388a8&rev_1001#5&2b74da90&0&0001#{6994ad04-93ef-11d0-a3cc-00a0c9223196}\topo00` |

Because the name is shared, resolving by name alone can bind to a stale endpoint.
`tools/Get-AudioRoute.ps1` reports every match plus its state and id, and fails
(exit 2) when none is active, instead of silently choosing.

## Instrumentation built

| Tool | What it measures |
|---|---|
| `tools/Get-AudioRoute.ps1` | render endpoints: name, id, state, default flag, peak meter |
| `tools/Get-AudioSession.ps1` | audio sessions per endpoint: owning **process id**, state, peak, master volume, mute |

Session enumeration is the important one: endpoint peaks only say *something* played,
while a session names the process. That is how "the game's audio reached device X"
becomes a measurement rather than an inference.

## Why nothing could be measured

The game was launched normally (Steam, DRM intact), reached the splash, the main
menu, `EPISODE STATUS`, and the `PLAY → slot list` screen. At every point:

- `WalkingDead101` held an **active** session on `Voicemeeter AUX Input` (the
  default) with **peak 0.000000**, volume 1.0, not muted.
- The same zero held with the game window verified as foreground for 18 s
  (`tools/scratch/measure_focus.ps1`), so it is not a focus-pause artefact.
- During launch cinematics it was also 0.
- The only audio on the machine was other applications (a browser at ~0.07, other
  media at ~0.55 on the default), which the session list clearly attributed to
  other PIDs.

The cause is visible in the game's own settings — **Audio Settings**:

```
VOICE  10
MUSIC  10
SOUND   0     <-- sound effects muted by the game's configuration
```

`SOUND = 0` silences UI effects. The menu also carries no music, so the only audio
left is in gameplay, which could not be entered: the slot-list `PLAY` button did not
accept synthesised input (SendInput with confirmed foreground, repeated clicks,
`Enter`), even though the same mechanism successfully drove the splash, the menu,
`EPISODE STATUS` and row selection. Without entering gameplay there is no audio to
route or to measure.

Changing the user's in-game audio settings or forcing a save load is a user decision,
not something to do unilaterally while hunting for a measurement.

## Routes attempted for per-app routing

### 1. Synthetic Windows policy entry — ignored

The value format was recovered from the machine's own 700 entries and written for a
test process exactly as Windows stores it (device string taken from the endpoint's
`{b3f8fa53-…},11` property, executable path resolved to `\Device\HarddiskVolume4\…`).
Windows ignored it: the same tone stayed on the default, target peak 0. The key is a
hash that was not recovered (700 samples, 10 algorithms, 6 path/encoding variants,
zero matches), so entries cannot be synthesised. Test key deleted.

### 2. `IAudioPolicyConfigFactory` — available, declined

`Windows.Media.Internal.AudioPolicyConfig` activates; the Windows 10 interface
`{2A59116D-…}` is supported and the Windows 11 GUID returns `E_NOINTERFACE`. It was
not called: the vtable order is undocumented and a mis-indexed call lands on
`ClearAllPersistedApplicationDefaultEndpoints`, which would wipe all 700 mappings.

### 3. Settings UI Automation — not attempted

It would change the same policy store as (2) and could not be *verified* while the
game produces no audio, so driving the UI would have produced an unprovable change.

## Machine state after the session (verified, not asserted)

| Check | Baseline | After |
|---|---|---|
| Policy entries | 700 | **700** |
| Policy hash (SHA-256 of sorted key=value) | `630B71A532AA250A28A8148FE157978A9145661CBEB253C6EB9F49E6A9126875` | **identical** |
| Default render endpoint | Voicemeeter AUX Input | **Voicemeeter AUX Input** |
| Game process | none | **none** (closed) |

No routing change was left half-applied.

## Manual steps (under a minute)

**A. Route the game to `100027813`** (per-app, leaves the system default alone):

1. Launch the game and get to a screen with sound (see B).
2. `Win+I` → **System** → **Sound** → **App volume and device preferences**.
3. Under *The Walking Dead*, set **Output** to `100027813 (NVIDIA High Definition Audio)`.
   If the name appears more than once, pick the entry that stays selected after
   reopening the page — only `{63b45a0d-…}` is present; the other three are stale
   duplicates that Windows lists from earlier HDMI sinks.
4. Keep the **system default** on *Voicemeeter AUX Input* (top of the same page).

**B. Restore game sound effects** (currently `SOUND = 0`):

1. Main menu → **SETTINGS** → **AUDIO**.
2. Set **SOUND** to 10 (leave VOICE/MUSIC as they are), then **APPLY**.

**C. Verify by measurement** (no guessing):

```powershell
# per-device peaks; the target must be above 0 while the default stops carrying the game
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Get-AudioRoute.ps1 -Samples 6

# per-process attribution: the game's session must appear on the target endpoint
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Get-AudioSession.ps1 -ProcessName WalkingDead101
```

Then kill the game, relaunch, and repeat C — the mapping is stored per executable,
but persistence across a restart still has to be *shown*, not assumed.

## Measured vs unverified

**Measured:** endpoint identity and the three stale duplicates; session/peak/volume
attribution per process; the target receiving nothing (peak 0) while the default
carries other applications; the game holding a silent active session; the game's
audio settings (`SOUND 0`); the machine's 700-entry policy store and default device
unchanged byte-for-byte after all attempts.

**Unverified:** game audio routed to `100027813`; dialogue, music, effects or
cinematics on that endpoint; persistence across restart; persistence across an
episode transition (no gameplay exists yet, and Episode 2 has never been entered);
human audibility of the HDMI sink.

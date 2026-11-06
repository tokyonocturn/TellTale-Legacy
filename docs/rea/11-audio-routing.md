# 11 — Audio endpoint `100027813`

Status: **endpoint identified, game audio measured on the default device, per-app
routing attempted through the supported Settings page and shown not to be applied by
Windows on this machine.** No routing change is left in effect. Episode-transition
audio is untested because no episode transition has been exercised.

## What `100027813` actually is

`100027813` is a **display name**, not an endpoint identifier. It belongs to an
NVIDIA HDMI audio output, and four enumerated devices carry that name:

| Endpoint id | State | Outcome |
|---|---|---|
| `{0.0.0.00000000}.{63b45a0d-a22d-42a4-a438-b64a52829507}` | `DeviceState = 1` | **live — the target** |
| `{0.0.0.00000000}.{825aafdd-89f4-42e0-b1dd-dc80ce2d628c}` | `0x20000004` | not present (stale) |
| `{0.0.0.00000000}.{a17e01de-ea23-41fe-b932-fabccfab6dba}` | `0x20000004` | not present (stale) |
| `{0.0.0.00000000}.{3c032cf1-7069-4bf3-8a04-c112b815c626}` | `0x20000004` | not present (stale) |

| Field | Value |
|---|---|
| Friendly name | `100027813 (NVIDIA High Definition Audio)` |
| PnP instance | `SWD\MMDEVAPI\{0.0.0.00000000}.{63B45A0D-A22D-42A4-A438-B64A52829507}` |
| Render default | **no** |
| Device interface | `{2}.\\?\hdaudio#func_01&ven_10de&dev_009f&subsys_104388a8&rev_1001#5&2b74da90&0&0001#{6994ad04-93ef-11d0-a3cc-00a0c9223196}\topo00` |

The Settings page offers exactly **one** `100027813 (NVIDIA High Definition Audio)`
item in its output lists — the three stale duplicates are not offered. So the page
itself cannot be used to pick a wrong duplicate; only name-based resolution in code can.

## Instrumentation

| Tool | What it measures |
|---|---|
| `tools/Get-AudioRoute.ps1` | render endpoints: name, id, state, default flag, peak meter |
| `tools/Get-AudioSession.ps1` | sessions per endpoint: owning **process id**, state, peak, volume, mute |
| `tools/Set-AppAudioRoute.ps1` | drives the Settings page over UI Automation to set one app's output |

Session enumeration is what makes a claim a measurement: the game's own session is
attributed to its PID, rather than inferring from an endpoint's peak.

## The earlier "no audio" wall, resolved

Silence was a game setting, not a failure: `SETTINGS → AUDIO` had **`SOUND 0`** next to
a menu with no music. Raising the three sliders to audible values (reversible test
setting: `VOICE 10`, `MUSIC 10`, `SOUND 0` were the originals, recorded first, and
restored afterwards — see the restore section) made the game produce sound:

```
WalkingDead101  pid 15380  Voicemeeter AUX Input  state=1  peak=0.050720
```

That is the game's own session, in the foreground, playing menu/UI effects. Game audio
therefore exists and is measurable — on the system default.

## The Settings-page route, driven by UI Automation

The page was driven entirely through `UIAutomationClient`; no registry keys, no
`IAudioPolicyConfigFactory`, no undocumented COM.

UIA structure found on `ms-settings:apps-volume` (window class `ApplicationFrameWindow`):

| Element | Identification |
|---|---|
| master output list | `SystemSettings_Audio_OutputList_ComboBox` |
| per-app row | `ListItem` whose `Name` is the app title, e.g. `Telltale Games` |
| per-app volume | `SystemSettings_Audio_Mixer_App<PID>_Slider` |
| per-app output | `SystemSettings_Audio_Mixer_App<PID>_ComboBox` (first of the two) |
| per-app input | `SystemSettings_Audio_Mixer_App<PID>_ComboBox` (second) |

What the automation did, and what it proved:

1. `ExpandCollapsePattern.Expand()` on the game's output combo listed 15 devices,
   including one `100027813 (NVIDIA High Definition Audio)`.
2. `SelectionItemPattern.Select()` on that item was accepted without error.
3. Reading the combo back showed `100027813 (NVIDIA High Definition Audio)` — and it
   still showed that after the game was killed and relaunched (new PID, new row
   `App15380_ComboBox`). **Windows stored the choice.**

What the measurement then showed:

| Measurement | Result |
|---|---|
| game session state/peak | `state=1 peak=0.029694` on **Voicemeeter AUX Input** |
| target endpoint peak during the same window | **0** |
| fresh process started *after* the setting was stored | still rendered on Voicemeeter |

### Control experiment — it is not the game

A plain `System.Media.SoundPlayer` tone (WASAPI shared mode) was routed the same way,
and measured the same way:

| Target chosen in the page | Session device after selecting | New process started afterwards |
|---|---|---|
| `Headphones (3- E7 Stereo)` — a device that demonstrably renders | Voicemeeter AUX | Voicemeeter AUX |
| `SHARP HDMI (NVIDIA High Definition Audio)` | Voicemeeter AUX | — |
| `100027813 (NVIDIA High Definition Audio)` | Voicemeeter AUX | Voicemeeter AUX |

A device that certainly works could not be targeted either. So the failure is not
specific to the game, its audio engine, or the HDMI endpoint: **the per-app override is
accepted and persisted by the page but never applied by Windows on this machine.**

Registry evidence for that conclusion: the per-app policy store
(`HKCU\Software\Microsoft\Internet Explorer\LowRegistry\Audio\PolicyConfig\PropertyStore`)
did not change at all across the attempt — 700 entries, hash identical, per-value diff
empty — so the page's override is not written to that store on this build. No audio
Group Policy keys exist under `HKLM`/`HKCU\SOFTWARE\Policies\Microsoft\Windows\Audio`
or `...\Windows\Multimedia`.

### Exact failure, for the record

`100027813` (`{63b45a0d-…}`) is enumerated **ACTIVE** (`DeviceState = 1`) and is offered
by Windows as an output, but it never receives rendered audio: its peak meter stays
`0.000000` even when a control process is explicitly assigned to it and is playing a
continuous tone. The per-application assignment for it is accepted by the Settings page
and ignored by the audio engine. That is the endpoint-level fact this project has to
record; nothing was silently redirected to another device.

## Machine state after the run (verified, not asserted)

| Check | Baseline (snapshot taken before touching anything) | After |
|---|---|---|
| Policy entries | 700 | **700** |
| Policy hash (SHA-256 of sorted key=value) | `630B71A532AA250A28A8148FE157978A9145661CBEB253C6EB9F49E6A9126875` | **identical** |
| Per-value diff | — | **empty** (not just a count match) |
| Default render endpoint | Voicemeeter AUX Input | **Voicemeeter AUX Input** (`Default = True`) |
| Target endpoint | active, not default | **active, not default, peak 0** |
| Game row in Settings | `Default` | **`Default`** (reverted and read back) |
| In-game audio settings | `VOICE 10`, `MUSIC 10`, `SOUND 0` | **`VOICE 10`, `MUSIC 10`, `SOUND 0`** (re-applied) |
| Game process | none | **none** |

Saves were backed up before any testing
(`backups/20261105-182801-audio-run-baseline`); no save was modified and no gameplay
was entered.

## Manual steps (for a machine where per-app routing does work)

**A. Route the game to `100027813`** — this is the step this machine's audio stack
refuses to honour:

1. Launch the game and reach a screen with sound.
2. `Win+I` → **System** → **Sound** → **App volume and device preferences**.
3. Under *Telltale Games*, set **Output** to `100027813 (NVIDIA High Definition Audio)`.
   The page lists that name once; the three stale duplicates never appear here, so no
   disambiguation is needed in the UI. (If you see it twice, reopen the page — only one
   is persisted.)
4. Leave the **system default** on *Voicemeeter AUX Input*.

**B. If the game is silent**, check `SETTINGS → AUDIO`: `SOUND 0` silences effects and
the menu has no music.

**C. Verify by measurement**:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Set-AppAudioRoute.ps1 -AppName 'Telltale Games' -DeviceName 100027813
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Get-AudioSession.ps1 -ProcessName WalkingDead101
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Get-AudioRoute.ps1 -Samples 6
```

Success is the game's session reporting `Device = 100027813 …` with `Peak > 0` while the
target endpoint's peak rises and Voicemeeter's stops carrying it. On this machine that
never happened, for the game or for a control process.

## Measured vs unverified

**Measured:** endpoint identity and the three stale duplicates; one live duplicate offered
by the Settings page; per-session attribution by PID; the game producing audio
(`peak 0.050720`) on the default device once `SOUND` was raised; the Settings page
accepting and persisting a per-app output selection; that selection **not** being
applied to the game, to `Headphones (3- E7 Stereo)`, or to `SHARP HDMI`, including for
processes started after it was stored; the policy store unchanged (700 entries, same
hash, empty per-value diff); default device still Voicemeeter AUX; game settings and
process restored.

**Unverified:** game audio on `100027813` (never observed, target peak stayed 0); dialogue,
music and cinematics on that endpoint; persistence of routing across restart and across
episode transitions (persistence cannot be shown for a routing that is never applied;
no episode transition has been exercised); human audibility of the HDMI sink.

## Why the remaining routes are not attempted here

Synthetic `PolicyConfig` entries were already measured as ignored (the key hash is not
recoverable), and `IAudioPolicyConfigFactory` remains off-limits because a mis-indexed
call lands on `ClearAllPersistedApplicationDefaultEndpoints`, which would wipe all 700
mappings. Those are the two remaining programmatic options and both are excluded by
instruction or by risk.

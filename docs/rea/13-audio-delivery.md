# REA 13: Getting the game's audio onto `100027813`

This is the record of how the game's audio was made to reach the endpoint that the
mission requires, what was measured at each step, and what is still not proven. It
replaces the conclusion in `11-audio-routing.md` that the endpoint "never renders":
that conclusion was wrong, and the correction is the reason the problem was solvable.

## The three faults, in the order they were found

| # | Fault | Evidence | Fix |
|---|---|---|---|
| 1 | **Every in-game volume was 0**: `VOICE 0, MUSIC 0, SOUND 0`: so the engine rendered silence everywhere | Measured at the main menu: game session `Active`, `Volume 1.00`, `Muted False`, `Peak 0.000000`; the game's own AUDIO screen showed 0/0/0 | Set 10/10/10 in the game's AUDIO screen (originals recorded as 0/0/0) |
| 2 | **Windows per-app redirection is accepted and ignored** on this machine | `11-audio-routing.md`: selection persisted across a restart and read back, session never moved, for the game *and* a control tone, on three devices including a known-good one | Not used; replaced by a stream-level shim |
| 3 | **Voicemeeter does not re-open a bus device from a settings load** | Loading a settings file with `OutputDev index='1'` changed to the target left A1 on the headphones; Voicemeeter opened a session on the target that metered `0.0000` | Not used |

Fault 1 is the one that mattered most, and it was invisible from peak meters alone
because a muted-by-volume engine and a broken endpoint look identical from outside.

## Fault 1: the silence was the game's own settings

The Windows side was never the problem:

- The game's session reported `Volume 1.00`, `Muted False` on the default endpoint,
  read through `ISimpleAudioVolume::GetMasterVolume`/`GetMute`, not inferred from peaks.
- The default device was `Voicemeeter AUX Input`, whose chain was proven carrying audio
  by playing a control tone and measuring `0.385586` on the headphones downstream.
- Direct WASAPI render to the target endpoint metered `0.5` at 0.5 amplitude.

So the silence had to be inside the engine. The game's AUDIO screen confirmed it:
all three sliders at zero. Raising them to 10/10/10 and pressing APPLY produced, within
two seconds, `0.022430` on the game's session at the main menu and `0.44`, `0.46`, `0.79`
during the chapter cinematic. That is a *measured* change caused by one setting change.

**Why it had been "restored" to 10/10/0 earlier and read 0/0/0 later is not established.**
What is established: at the start of this session all three were 0, and after APPLY they
are 10/10/10. The plausible explanation is that the earlier restore targeted the pause
menu's copy of the screen and did not commit, or that a later exit re-wrote prefs from
the pre-test state; the save container is opaque, so this cannot be read back directly.
It is recorded as an open question rather than a claim.

## Fault 2 and the delivery mechanism

Since the OS will not redirect one application's stream, the project carries the stream
itself. `tools/Start-AudioMirror.ps1`:

1. Opens the source endpoint (`Voicemeeter AUX Input`, still the system default; the
   game keeps rendering there, exactly as before) in **WASAPI loopback** mode.
2. Opens the target endpoint (`100027813 (NVIDIA High Definition Audio)`) for rendering
   in shared mode, using the source's mix format (48 kHz, 2ch, 32-bit float).
3. Copies every captured packet to the target, and meters both sides.

`tools/Test-AudioEndpoint.ps1` is the companion probe that proves what an endpoint does
with a stream, independently of any mixer: it renders a tone straight to a named device
and reads that device's own peak meter.

### What the two tools measured

| Test | Result |
|---|---|
| `Test-AudioEndpoint -Name "E7 Stereo"` (control) | `endpointPeak 0.6030891`, "endpoint meters the tone it was given" |
| `Test-AudioEndpoint -Name "100027813"` | `endpointPeak 0.5`, 292,320 frames written, "endpoint meters the tone it was given" |
| `Start-AudioMirror` with a 440 Hz tone on the source | capture `0.910579`, target `0.910579` |
| `Start-AudioMirror` during real game audio | capture `0.452847` → target `0.403610` at the same moment |

## Fault 3 and isolation

Voicemeeter would happily have put the same audio on the user's headphones as well
(A1 → `Headphones (3- E7 Stereo)`), which is exactly the duplicate the mission's proof
forbids. `Command.Load` does not re-open bus devices, so the mixer's A1 device cannot be
moved from a file without restarting the whole mixer.

Instead, one flag is cleared on the game's mixer strip through the Voicemeeter remote
API: `Strip[4].A1 = 0` (strip 4 is the `Voicemeeter AUX Input` strip). Consequences:

- The game's audio no longer reaches `Headphones` through the mixer.
- The loopback capture happens **before** the strip, so the mirror still sees everything
  the game renders; the two operations are independent.
- Other applications keep their own routing; the user's non-game audio still reaches the
  headphones through the untouched `Voicemeeter Input` strip (`Strip[3].A1 = 1`).

Measured during a loud game moment after that change:

| Endpoint | Peak |
|---|---|
| `Voicemeeter AUX Input` (source) | 0.452847 |
| `100027813` (target) | 0.403610 |
| `Headphones (3- E7 Stereo)` | 0.020820 (the user's unrelated audio, and it did not follow the game's 0.45) |
| `SHARP HDMI`, `Realtek Digital Output`, `Speakers (Yeti Classic)` | 0 |

## Persistence

The mirror was left running and the game was fully restarted (`EXIT GAME` → `Yes`,
process gone, relaunched through Steam):

| Stage | Source | Target | Headphones |
|---|---|---|---|
| Game exited, no audio from it | 0 | **0** | 0.061 (other apps, unaffected) |
| Fresh launch, splash screen | 0.0226 | **0.0156** | 0.1746 (other apps) |
| Main menu | 0.0211 | **0.0163** | 0.0269 (other apps) |
| Chapter load + chapter change | 0.6814 → 0.1607 | **0.1429 → 0.1641**, peaks to **0.7685** | 0.0242 → 0.0045 |

So the path survives a restart and a chapter change, and the target's peaks track the
game's own peaks while the headphones stay at their unrelated floor.

## Side effects, and how to undo them

| Change | Scope | Undo |
|---|---|---|
| In-game `VOICE/MUSIC/SOUND` 0/0/0 → 10/10/10 | The game's own prefs only | Set them back on the AUDIO screen; originals were 0/0/0 |
| Voicemeeter `Strip[4].A1 = 0` | One strip's bus flag in the user's mixer | `VBVMR_SetParameterFloat("Strip[4].A1", 1)` (or restart Voicemeeter from the saved settings) |
| Mirror process running | A process, holding two WASAPI streams | Stop the process; nothing is persisted |
| Settings files loaded during the investigation | The user's mixer settings were loaded several times, always from a backup of their own file; final state re-loaded from that backup before the single flag change | `backups/vm-banana-before-*.xml` |

The system default endpoint is **unchanged** throughout: `Voicemeeter AUX Input`
(`Default = True`).

### Policy store footprint

The store was measured again after all of this work: 700 entries, identical hash,
0 changed, 0 removed. Two entries *were* created along the way; Windows records a
per-app route the first time a process renders to a device, both for
`powershell.exe` (one for the HDMI topology, one for the Bluetooth hands-free
device), created by the probe and the mirror. Each was exported
(`backups/policy-entry-348a5aac.reg`, `backups/policy-entry-6eee855e.reg`) and then
deleted, after which the store matched the baseline byte for byte. They are not
required by the mechanism and did not come back once removed.

## Unverified, stated plainly

- **Audibility at the far end.** Peak meters prove the samples reach the endpoint's
  engine; nobody has listened to the HDMI sink. Peak is not sound pressure.
- **Process-level exclusivity.** The mirror carries the *source endpoint's mix*. During
  the proof the only stream on that endpoint was the game's, but any other application
  that renders to the default device while the mirror runs is carried too. Windows
  process-loopback capture (which would be exclusive) was not implemented.
- **The mirror is a process, not a service.** Nothing starts it automatically. It must
  be running for the game's audio to reach the endpoint.
- **Fault 1's history.** See the open question above.
- **Episode transitions and the rest of the game** are untouched by this work; the
  gameplay status is in `12-gameplay-automation.md`.

## Reproduce

```powershell
# 1. prove what the endpoint does with a stream
.\tools\Test-AudioEndpoint.ps1 -Name "100027813" -Seconds 5

# 2. start the shim (source = system default, target = required endpoint)
.\tools\Start-AudioMirror.ps1 -SourceName "Voicemeeter AUX" -TargetName "100027813" -Seconds 3600

# 3. stop the duplicate at the mixer (one flag, reversible)
VBVMR_SetParameterFloat("Strip[4].A1", 0)     # via the remote API

# 4. measure all endpoints while the game plays
.\tools\Get-AudioRoute.ps1
```

---

## Durable verification (added after the live session)

The mechanism above is only worth as much as the ability to re-check it. That is now a
single read-only command, `tools/Assert-AudioDelivery.ps1`, which resolves the endpoint by
**Core Audio device id** (the friendly name has three stale duplicates on this machine),
requires it to be `active`, requires it to **not** be the system default, requires the
mirror to be running, and requires a measured non-zero peak on the target while audio is
demonstrably playing elsewhere.

It has no fallback by design. If the endpoint is gone it says `endpoint-missing` and exits
3 rather than measuring some other device and calling the requirement met. The full set of
verdicts is in [`14-session-evidence.md`](14-session-evidence.md#audio-measured-during-live-play).

Measured while the owner was playing, with the game untouched:

| Reading | Value |
|---|---|
| Verdict | `verified` (exit 0) |
| `100027813` | active, not default, peak **0.474285** |
| Default | `Voicemeeter AUX Input (VB-Audio Voicemeeter VAIO)`, unchanged, peak 0.524213 |
| Mirror | running, pid 3660 |

Across that session's 23 recorded samples the target never fell silent (min 0.049835,
median 0.162346, max 0.522247) and the default device's name never changed. Persistence
across a restart and across an episode transition is still pending: restarting the game is
what the session cannot survive while it is being played.

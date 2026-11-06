# 11 — Audio endpoint `100027813`

Status: **endpoint identified and instrumented; routing not applied; in-game audio
not verified.** The game's audio has not been shown to reach the target device, and
this document does not claim it has.

## What `100027813` actually is

`100027813` is a **display name**, not an endpoint identifier. The endpoint is an
NVIDIA HDMI audio output:

| Field | Value |
|---|---|
| Friendly name | `100027813 (NVIDIA High Definition Audio)` |
| Endpoint id | `{0.0.0.00000000}.{63b45a0d-a22d-42a4-a438-b64a52829507}` |
| PnP instance | `SWD\MMDEVAPI\{0.0.0.00000000}.{63B45A0D-A22D-42A4-A438-B64A52829507}` |
| State | active (`DeviceState = 1`) |
| Render default | **no** |
| Device interface path | `{2}.\\?\hdaudio#func_01&ven_10de&dev_009f&subsys_104388a8&rev_1001#5&2b74da90&0&0001#{6994ad04-93ef-11d0-a3cc-00a0c9223196}\topo00` |

**The name is ambiguous, which matters.** Four enumerated devices carry the string
`100027813`; three are not present (`DeviceState = 0x20000004`) and only
`{63b45a0d-…}` is active. Selecting by name alone could bind to a stale endpoint, so
the tool resolves the name and then reports the id, state and count of matches
rather than picking silently.

The endpoint is an **HDMI** output. Audio can only be heard from it if the attached
sink is powered and selected; HDMI outputs routinely stay "active" while producing
no sound.

## Current audio topology (observed)

- Render default: `Voicemeeter AUX Input (VB-Audio Voicemeeter VAIO)`.
- The machine runs Voicemeeter with a large per-app routing setup: **700 entries**
  under `HKCU\…\Audio\PolicyConfig\PropertyStore`, each pinning one executable to
  a Voicemeeter bus or an HDMI output.
- A 1 s test tone played through the default reached
  `Voicemeeter AUX Input` (peak 0.377) and `Headphones (3- E7 Stereo)` (peak 0.382)
  and **not** `100027813` (peak 0).

This is why routing the game must be per-application: changing the system default
would reconfigure the user's audio for every other program, which the brief
explicitly forbids.

## Verification instrument

`tools/Get-AudioRoute.ps1` enumerates render endpoints through Core Audio, resolves
the target by name, and samples each endpoint's peak meter. Because peaks are per
device, "target peak > 0 while the others stay flat" is direct evidence that audio
reached `100027813` — no guessing from settings.

```powershell
# Baseline / verification: shows every render endpoint with its peak
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Get-AudioRoute.ps1 -Samples 4

# Machine-readable
.\tools\Get-AudioRoute.ps1 -Samples 3 -OutputPath docs\rea\data\audio-route.json
```

Exit codes: `0` target resolved with an active endpoint, `2` no active endpoint
with that name.

## Automation attempts (both failed, both documented)

### 1. Synthetic per-application policy entry — ignored by Windows

The registry format used by the OS was recovered from the machine's own 700
entries:

```
{2}.\\?\hdaudio#…#{6994ad04-…}\topo00/00010001|\Device\HarddiskVolume4\…\app.exe%b{00000000-0000-0000-0000-000000000000}
```

The device string for the target was taken from the endpoint's own property
`{b3f8fa53-0004-438e-9003-51a46e139bfc},11` and reduced to the form Windows writes
(the exact string used by 35 existing entries), the executable path was resolved to
`\Device\HarddiskVolume4\…`, and the entry was written under a synthetic key.

Test: the same tone, same process. It went to the default again (0.377 / 0.382),
target still 0. **Windows ignores entries whose key name it did not derive itself.**
The key is a hash of something not recovered: across 700 real entries and 10
algorithm/path variants (CRC32, FNV-1a, FNV-1, MD5/SHA-1/SHA-256 truncations, over
full/relative/bare exe paths, UTF-8 and UTF-16, three casings) there were **zero**
matches. The test key was deleted.

### 2. `IAudioPolicyConfigFactory` — available, but declined

The per-app routing factory used by the Windows UI does activate on this build:

```
Windows.Media.Internal.AudioPolicyConfig
  activate as IInspectable:            hr=0x00000000
  QI  {2A59116D-6C4F-45E0-A74F-707E3FEF9258}:  supported (Windows 10 interface)
  QI  {AB3D4648-E242-459F-B02F-541C70306324}:  E_NOINTERFACE (Windows 11 interface)
```

So a programmatic route exists. It was **not** used: the interface is undocumented
and its vtable order is version-dependent. A mis-indexed call would land on
`ClearAllPersistedApplicationDefaultEndpoints`, wiping all 700 of the user's
mappings — while audio was in active use. Guessing offsets on a live audio session
is not a risk worth taking for a setting the OS exposes in its own UI, so the
attempt stops here and the exact blocker is recorded instead.

## Supported route (one manual step, ~15 s)

1. Play the game so it appears in the volume mixer.
2. **Settings → System → Sound → App volume and device preferences**.
3. Find *The Walking Dead* and set **Output → `100027813 (NVIDIA High Definition Audio)`**.
   This writes a key the OS derives itself, so it is honoured.
4. Confirm with `tools\Get-AudioRoute.ps1 -Samples 6` while the game is running:
   target peak should rise above 0 and the default endpoint should stop receiving it.

The mapping persists by design (it is stored per executable, not per session), but
it must still be **demonstrated** across a game restart and an episode transition
before it counts as verified.

## Not verified

- Game audio on `100027813`: **no**. Nothing has been routed yet.
- Menu music, dialogue, music cues, sound effects and cinematics on that endpoint:
  **none verified.**
- Persistence across restart and episode transition: **not tested.**
- Whether the HDMI sink is powered and audible: **unknown** — a positive peak meter
  proves the samples reached the endpoint, not that a human heard them. Audibility
  is an attended check.

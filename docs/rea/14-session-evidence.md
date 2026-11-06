# REA 14 — Attended play session: evidence, and what it does not prove

The project owner is playing Episode 1 at the keyboard while this document was written.
Everything here is a measurement taken *alongside* that session: the game was never given
focus, sent input, paused, restarted or closed, and the audio mirror was left running
untouched. The point of this record is to hold the line the mission asks for — evidence
produced by real play is worth more than anything a launch or a menu can show, and it is
still not the same as a completed playthrough.

## How the evidence was taken

`tools/Watch-GameSession.ps1` samples every 15 seconds while the game process is alive:

| Sampled | Why |
|---|---|
| window frame, downscaled to 480 px | a visual timeline of the session, cheap enough to keep running for hours |
| every save file: name, size, mtime, SHA-256 (first 16 hex) | each write is a checkpoint the game itself made, and the hash lets the same bytes be recognised later |
| live peak on `100027813` and on the system default | the audio claim has to rest on numbers taken during real play, not on a one-off test |
| process id and window title | ties every sample to the process that produced it |

Frames and the raw JSONL index stay in `tools/scratch/session/`, which is git-ignored:
they are captures of the game's own art and must not be published. Only the measurements
and this write-up are committed. `tools/Summarize-SessionCapture.ps1` reduces the index to
`docs/rea/data/session-summary.json` (also ignored, regenerable).

## Audio, measured during live play

`tools/Assert-AudioDelivery.ps1` (new) is the gate for the audio requirement. It resolves
the endpoint by **Core Audio device id**, refuses to guess between the three stale
same-named duplicates, and has no fallback path at all.

Run against the live session at 10:51:38Z:

| Check | Value |
|---|---|
| Verdict | **`verified`** (exit 0) |
| Required endpoint | `100027813 (NVIDIA High Definition Audio)`, id `{0.0.0.00000000}.{63b45a0d-…}`, state `active`, `IsDefault = false` |
| Target peak | **0.474285** |
| System default | `Voicemeeter AUX Input (VB-Audio Voicemeeter VAIO)`, unchanged |
| Default peak | 0.524213 |
| Mirror | running, pid 3660 |
| Game | running, pid 8020 |

Across the recorded session's own samples (23 samples, 10:48:58Z → 10:54:48Z):

| Endpoint | Min | Median | Max | Samples with signal |
|---|---|---|---|---|
| `100027813` | 0.049835 | 0.162346 | 0.522247 | 23 / 23 |
| default | 0.074201 | 0.218700 | 0.539967 | 23 / 23 |

The default device's friendly name was identical in every sample
(`Voicemeeter AUX Input (VB-Audio Voicemeeter VAIO)`), so the requirement to leave the
user's default alone held for the whole recorded window — it did not merely hold at the
start.

### The failure path is explicit, not silent

| Condition | Verdict | Exit |
|---|---|---|
| Endpoint id not enumerated | `endpoint-missing` — states that nothing was measured or redirected | 3 |
| Enumerated but not `active` | `endpoint-inactive` | 4 |
| Default carried audio, target did not | `no-signal-on-target` | 5 |
| Default device moved | `default-changed` | 6 |
| Mirror process gone | `mirror-not-running` | 8 |
| No audio anywhere to measure | `no-audio-to-measure` — explicitly *not* proof of failure | 9 |

Both the missing-endpoint and moved-default paths were exercised for real this turn (exit
3 and exit 6) and are covered by tests.

## Saves the game wrote during the session

Each row is a write the game performed on its own; the hash identifies those bytes.

| Time (UTC) | Change | File | Bytes | SHA-256 (16) |
|---|---|---|---|---|
| 10:48:58 | observed at first sample | `save_1.save` … `save_8.save`, `prefs.prop`, `steam_autocloud.vdf` | 18 K – 80 K | see summary |
| 10:53:13 | prefs rewritten | `prefs.prop` | 11,010 | `4D8CAC519F2D0CCE` |
| 10:53:13 | new slot appeared | `save_9.save` | 79,988 | `7E2A49E044C64893` |

Nine save slots exist now where the pre-session backup holds six, and `prefs.prop` grew
from 7,770 to 11,010 bytes: the session is producing progression, not a static screen.

**What this does not say.** The recorder proves *that* checkpoints were written and
exactly which bytes they are. It does not by itself say which chapter or which dialogue
choice produced them — that attribution needs the frames reviewed against the captured
saves, and that review has not been done. Treating the write list as a choice log would be
exactly the kind of claim this project is supposed to refuse.

## Backup and restore, verified by hash

`tools/Test-BackupIntegrity.ps1` (new) checks a backup against its manifest and proves the
restore path without touching the live saves: `-MaterializeTo` copies the backup into a
scratch directory and re-hashes what lands there.

Against `backups/20261106-041144-ep1-playthrough`:

| Check | Result |
|---|---|
| Files matching manifest | **7 / 7** |
| Backup intact | true |
| Restore proof (sandboxed) | true, 7 files materialized, all hashes identical |
| Live saves vs manifest | 4 files changed (`prefs.prop`, `save_2`, `save_5`, `save_6`) — expected while a session is running, reported as drift not corruption |
| Tampered backup | correctly rejected: exit 10, naming `prefs.prop` with both hashes |

The live save directory is only ever read by this tool; a real restore is deliberately not
performed while the owner is playing.

## Offline compatibility: prepared, not proved

`tools/Invoke-OfflineProbe.ps1` gained a read-only `Preflight` action, and Block/Unblock
now skip the elevation requirement only for a caller-supplied fixture hosts file (so the
round trip can be tested without administrator rights or touching live DNS).

Preflight at 10:52Z reported:

| Field | Value |
|---|---|
| Hosts file | `C:\Windows\System32\drivers\etc\hosts`, SHA-256 `4DA2C479D9A3774B…` |
| Currently blocked | false |
| `api.telltalegames.com` resolves to | `18.245.113.118`, `.61`, `.77`, `.119` |
| Game connections | `CloseWait 18.245.113.77:443` — i.e. the game **did** contact the API during play |
| Elevated | false |
| Ready | **false** — `needs-elevation`, `game-running` |

That last observation is the useful one for the mission's online-dependency objective: the
game is not merely configured to talk to the publisher API, it opened a connection to it
while being played. Whether it *needs* that connection is exactly what the offline launch
has to establish, and that cannot be tested without closing the game.

The reversibility of the block is now proven on a fixture: Block then Unblock returns the
hosts file to the **identical** SHA-256 (covered by a test).

## Verified vs unverified

**Verified this turn**

- Audio reached `100027813` during live play, by the endpoint's own meter, with the default
  device unchanged and the mirror running (0.474 peak, verdict `verified`, exit 0).
- Delivery failure modes are explicit and non-fallback; missing endpoint and moved default
  were both reproduced.
- The save backup is intact (7/7), a sandboxed restore reproduces identical bytes, and a
  one-byte change is caught.
- The game writes checkpoints during this session: nine slots and a grown `prefs.prop`,
  each with hashes and a frame reference.
- The hosts block/unblock round trip is byte-identical (fixture test).
- The game contacts `api.telltalegames.com` during normal play.

**Unverified, and explicitly not claimed**

- **Offline launch** — the game has been running the entire time; proving it launches and
  plays with the API blocked requires closing it, which this turn was told not to do.
- **Episode 1 completion, chapter transitions, the ending and the credits** — the session
  is still in progress. No frame showing the final chapter or credits exists yet.
- **Dialogue choices and their consequences** — checkpoints are recorded, but attributing
  each write to a specific choice needs the frames reviewed; not done.
- **The Episode 1 → Episode 2 transition** — pending the episode ending.
- **Audio across a restart or episode transition** — the endpoint, mirror and default are
  verified *now*; a restart would end this session, so persistence is pending.
- **Audibility at the far end of the HDMI sink** — peak meters prove the samples reach the
  endpoint's engine, not that a listener hears them.

## Reproduce

```powershell
# audio gate (exits 0 verified, 3/4/5/6/8/9 with a named failure)
.\tools\Assert-AudioDelivery.ps1

# backup + restore proof, without touching live saves
.\tools\Test-BackupIntegrity.ps1 -BackupPath .\backups\<label> -MaterializeTo .\tools\scratch\restore-proof -CompareCurrent

# offline readiness (read-only)
.\tools\Invoke-OfflineProbe.ps1 -Action Preflight

# session summary from the recorder's index
.\tools\Summarize-SessionCapture.ps1
```

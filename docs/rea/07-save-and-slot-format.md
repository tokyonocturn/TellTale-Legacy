# REA 07: Save container and slot behaviour

Scope: The Walking Dead, Steam app 207610, build 244978, executable
`44a5ff21cbb085812c48179259141ff5c83eaeaa3423b4734b43533df0a2528d`.

Everything below was measured from real artefacts written by the game during the
M2 attended session. Nothing here is a decoded save file: the container resisted
readback, and this document says so explicitly rather than implying otherwise.

## What the game writes

Save root: `%USERPROFILE%\Documents\Telltale Games\The Walking Dead`

| File | Size | Magic | First seen |
|---|---|---|---|
| `save_1.save` | 18,282 B | `bbdeaf64` | 16:47:36 local, first chapter checkpoint |
| `save_6.save` | 23,120 B | `bbdeaf64` | 16:51:04 |
| `save_5.save` | 29,303 B | `bbdeaf64` | 16:53:35 (held slot list "Game 1") |
| `save_3.save` | 29,254 B | `bbdeaf64` | 17:03:51, written when slot was resumed |
| `save_2.save` | 29,266 B | `bbdeaf64` | 17:08:36, written on the second resume |
| `prefs.prop` | 7,645 B | `aadeaf64` | rewritten on every launch, load and exit |
| `steam_autocloud.vdf` | 53 B | (text VDF) | Steam Auto-Cloud account stub |

Note the slot numbers are not sequential: 1, 5, 6 on the first playthrough, then
3 and 2 when the same checkpoint was resumed twice. **The slot-selection rule is
not established.** What is established is that N in `save_<N>.save` is a slot
identifier, not a chapter number, and that resuming a save can write a *different*
slot than the one loaded.

`prefs.prop` growth across the session: 6,447 → 6,591 → 6,647 → 6,795 → 7,581 →
7,645 bytes. It carries the slot metadata the UI displays: the slot list rendered
"Game 1 - Episode 1 - 05/11/26 16:53:35" with the publisher API unreachable,
which means display name, episode and timestamp come from local state.

## Container layout (measured, not inferred from documentation)

Saves use a 56-byte header, then an opaque payload:

| Offset | Length | Observed value | Reading |
|---|---|---|---|
| 0x00 | 4 | `bb de af 64` (saves), `aa de af 64` (props) | type-tagged magic |
| 0x04 | 4 | `38 f6 01 00` → 128,568 | unknown field, **not** the file length |
| 0x08 | 32 | `fd045547 f88beb73 c3eddace f97bd26a 6758b21d 9afe20e7 4ca93aa4 57fb2f2e` | constant across all five saves |
| 0x28 | 8 | `7e88ae13 58bb3511` | constant; also present in `prefs.prop` at 0x24 |
| 0x38 | … | high-entropy bytes | payload |

Field 0x04 is a size-like value only for saves: 128,568 / 138,010 / 183,152 /
183,248 against file sizes of 18,282–29,303 (ratio ≈ 6.0–7.0). In `prefs.prop`
the same offset reads 734,106,001 in every build of the file, so the field is
type-dependent and its meaning is **unknown**.

All three artefacts from the first playthrough share the entire 0x08–0x2F block
byte for byte, and the two saves written later share it too. A shared header plus
a random-looking payload is the signature of a fixed metadata block followed by a
per-file encrypted and/or compressed stream.

## Why the payload cannot be read back

Five independent tests, all negative:

1. **Compressed-stream signatures**: no zlib/gzip/bzip2/xz/zstd header at any
   offset in any save. The two `78 da` byte pairs found inside payloads are
   coincidence: decompression at every offset 0–32 with `wbits` 15, −15 and 47
   yields nothing.
2. **Compressibility**: zlib on the raw payload achieves ratio 0.992–0.996,
   i.e. the bytes are already at maximum entropy.
3. **Entropy**: 7.981–7.988 bits/byte over 256 distinct byte values.
4. **Repeating-key XOR**: index of coincidence after XOR-by-period is flat at
   ~0.0039 (random) for every period 1–64, and flat out to period 4,096. A short
   repeating key is ruled out.
5. **Fixed-keystream cancellation**: XORing two different saves produces 7.972
   bits/byte of entropy and a zlib ratio of 0.991. If a single fixed keystream
   were applied, XORing would cancel it and expose plaintext structure. It does
   not, so the keystream is per-file (or the payload is compressed before
   encryption).

Consequence, stated plainly: **no chapter, slot, decision or choice identifier is
readable from a save file.** `save_1` and `save_6` differ in 98.28% of their
overlapping bytes, and that number carries no semantic information; see
`docs/rea/data/save-diff-1-6.json`.

`prefs.prop` is different: entropy 6.44 with structural autocorrelation
(IC ≈ 0.0299 at period 1), so it is partially structured rather than fully
encrypted. It was not decoded either, and M2 does not depend on decoding it.

## Autosave and checkpoint behaviour

- The executable contains `SaveLoadPreSave`, `SaveLoadPostSave`,
  `SaveLoadCreateBanner`, `SaveLoadHasAvailableSpace`, `SaveLoadRemoveUserFiles`,
  `SaveLoadSetSaveDisplayName`, `SaveGameIncremental`, `IsSaveGameCorrupt`,
  `FileIsLastErrorCorruptSaveFile`, and the filename patterns `%s - %02d.save`,
  `*.save`, `temp.save`.
- Writing goes through a temporary file: `temp.save` was never observed left
  behind, and `docs/rea/data/save-artifacts.json` records `IncompleteTempFile:
  false` after every session.
- Autosaves arrived during unattended play at roughly 2.5–3.5 minute intervals in
  Episode 1's opening act (16:47, 16:51, 16:53), which matches chapter-boundary
  checkpoints rather than a timer.
- The exit dialog states "Any progress since last autosave will be lost", so the
  checkpoint is the persistence unit. Loading resumes at the checkpoint, and
  re-entering gameplay from the slot list writes a new `save_N` (3 and 2 above).
- `prefs.prop` is rewritten even by a launch that only reaches the menu, which is
  why the drift tool treats it as expected-to-change and the `.save` files as
  expected-to-stay-stable.

## Banners and thumbnails

`+SaveLoadImage.d3dtx` and `SaveLoadCreateBanner` exist in the executable, and the
slot list renders an empty thumbnail frame. No `+SaveLoadImage.d3dtx` marker was
found inside any of the five saves, so banner/thumbnail embedding in the save
payload is **not confirmed** for this build. The slot UI shows text only.

## Tools

- `tools/Get-SaveArtifacts.ps1`: read-only inventory: magic validation, declared
  field, header block, slot number, entropy, hashes; refuses to write inside the
  save root; `-CompareA/-CompareB` for byte diffs; `-BaselinePath` for drift.
- `tools/Backup-GameProfile.ps1` / `Restore-GameProfile.ps1`: hash-verified
  snapshots and restores of the whole save root, including `.save` and `.prop`.

Evidence: `docs/rea/data/save-artifacts.json`, `save-artifacts-before-m2.json`,
`save-drift-m2.json`, `save-diff-1-6.json`, `save-diff-6-5.json`, and the hash
manifest in `docs/rea/data/saves/20261105-m2-first-saves/SHA256SUMS.txt`.

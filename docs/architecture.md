# Architecture of the preservation tooling

## Principles

1. **Read, don't patch.** No tool writes to the game installation. The only writes
   are to the user's own save directory (restore) and to git-ignored data folders.
2. **Profiles are data, tools are generic.** Everything build-specific lives in
   `profiles/<id>/profile.json`. The tools never hard-code a hash, build id or
   episode list.
3. **Evidence over assertion.** Runtime observations are recorded as JSON sessions;
   audits and tests produce machine-readable reports.
4. **Fail closed.** A mismatch (hash, build id, integrity) stops the operation
   instead of proceeding with a warning.
5. **Reversibility.** Restores preserve prior state; the offline probe removes its
   hosts block; session observation never leaves a process running unintentionally.

## Components

```text
profiles/<id>/profile.json
        │  identity: app id, build id, hashes, engine, content map
        ▼
Test-OfflineReadiness.ps1 ──► docs/rea/data/offline-readiness.json
        │  pass/warn/fail per prerequisite, verdict
        ▼
Start-ObservedSession.ps1 ──► docs/rea/data/sessions/<ts>-<label>.json
        │  process tree, window titles, loaded modules, endpoints,
        │  save-directory before/after
        ▼
Backup-GameProfile.ps1 ────► backups/<ts>-<label>/manifest.json + saves/
Restore-GameProfile.ps1 ◄─── verifies hashes, preserves existing data

Get-SaveArtifacts.ps1 ─────► docs/rea/data/save-artifacts.json
        │  magic/declared field/header block/entropy per artefact,
        │  -CompareA/-CompareB byte diff, -BaselinePath drift (exit 3)
        ▼
Test-ContentPacks.ps1 ─────► docs/rea/data/content-packs.json
        │  profile episode map vs installed Pack directories
```

### `Get-GameInventory.ps1`

Read-only. Walks the installation, classifies files, hashes them, parses PE headers
(architecture, subsystem, link timestamp, sections, imports, `.bind` detection) and
archive headers. Emits one JSON document consumed by reports and tests.

Design notes:

* Archives are read header-only (first 32 bytes); 388 MB files are never loaded.
* Executables/libraries are read fully for PE parsing; there are only four.
* Hashing is optional (`-SkipHash`) because a full run reads 3.5 GiB.

### `Test-OfflineReadiness.ps1`

Profile-driven audit. Checks: install presence, executable hash against the
profile, required DLL hashes, archive count/version/episode directories, `.bind`
presence, Steam client running, Steam user session, Steam manifest build id and
`StateFlags`, DirectX 9 runtime, save-directory writability and existing save
volume.

Exit codes: `0` no failures, `2` at least one failure. Warnings still exit `0`,
because warnings describe risk rather than blocking conditions.

### `Start-ObservedSession.ps1`

Three launch modes:

* `-ViaSteam`: the supported route; starts `steam://rungameid/<appid>` and waits
  up to 120 s for the process, then records it.
* direct execution: for completeness and for capturing the `RestartAppIfNecessary` exit
  behaviour.
* `-AttachProcessId`: observes a session the user started themselves.

It refuses to launch when the game is already running (except in attach mode), so a
real player session is never disturbed. Sampling is every 2 s; endpoints come from
`netstat -ano` filtered to the process tree, because that works without elevation.

### `Invoke-OfflineProbe.ps1`

Adds/removes a clearly marked block in the hosts file and flushes DNS. Blocking a
hostname (not an IP) is required because the API sits behind a four-address CDN
front. It deliberately does **not** touch Steam.

Requires elevation for Block/Unblock. `-Action Status` works unelevated and exists
so a machine cannot silently be left in a blocked state.

### `Get-SaveArtifacts.ps1`

Read-only save inspection with three modes: inventory, pairwise byte diff, and
drift against a previous inventory. It validates the container magic
(`bbdeaf64` saves, `aadeaf64` props), reports the declared field at offset 4, the
constant header block, slot number and payload entropy, and refuses to write its
report inside the save root.

Drift is the mechanism that makes "nothing changed across a restart" checkable:
exit `0` means every artefact hash matches the baseline, exit `3` lists added,
removed and changed files. In M2 it showed `added=2, changed=prefs.prop`, which is
exactly the expected footprint of two resumes.

The tool never decodes a payload. Entropy, compression and keystream tests are
documented in `docs/rea/07-save-and-slot-format.md`; the container is treated as
opaque bytes on purpose.

### `Test-ContentPacks.ps1`

Checks the profile's `content.episodeDirectories` against `<GameRoot>\Pack`, and
fails when a directory is missing or contains no `.ttarch`. Without it, "episode 2
is installed" is an assumption; with it, an absent pack is a failing exit code.

### Backup / restore

Manifest schema:

```json
{
  "SchemaVersion": 1,
  "CreatedUtc": "...",
  "Label": "before-testing",
  "SourceRoot": "C:\\Users\\<user>\\Documents\\Telltale Games",
  "FileCount": 2,
  "TotalBytes": 6700,
  "Game": { "ExecutableSha256": "...", "SteamBuildId": "244978" },
  "Registry": [ { "Key": "...", "Values": { } } ],
  "Files": [ { "RelativePath": "...", "SizeBytes": 0, "Sha256": "..." } ]
}
```

Registry values are captured as JSON data rather than a `.reg` hive export: it is
reviewable, diffable and cannot accidentally carry unrelated keys.

## Extending to another Telltale title

1. Create `profiles/<new-id>/profile.json` with the new app id, build id, hashes,
   engine facts and content map. Do **not** assume the engine or layout is shared.
2. Run `Get-GameInventory.ps1` against that installation and record what differs.
3. Run `Test-OfflineReadiness.ps1 -ProfilePath <new profile>`.
4. Observe a session; discover that title's online dependencies before claiming
   offline support.
5. Add a version-matrix row; only mark `validated: true` for scenarios actually
   exercised.

## Testing strategy

`tests/Run-Tests.ps1` is dependency-free (no Pester) and runs against synthetic
fixtures in a temporary directory:

* profile/inventory schema validity;
* backup manifest completeness and per-file hashes;
* round-trip restore byte equality;
* refusal to overwrite a non-empty destination;
* pre-restore preservation with `-Force`;
* tamper rejection before any write (exit code 2);
* probe status output shape;
* fail-closed readiness audit on a missing install;
* save-artefact parsing of magic, slot, declared field and hash;
* tolerance of truncated and mislabelled artefacts;
* refusal to write a report inside the save root;
* drift mode: identical set, and a rewritten `prefs.prop` detected;
* byte diff of divergent vs identical saves with exact offsets;
* restored save and prefs hash equality;
* content-pack validator passing a complete map and failing a missing pack;
* probe parsing of a fixture hosts file without touching real DNS;
* `docs/verification-scenarios.json` integrity: unique ids, valid modes, and at
  least one scenario of each mode.

Tests never touch real saves or the installation. The scenario registry keeps
machine checks separate from attended gameplay: no test claims a played session,
and `08-offline-gameplay-verification.md` is the only place gameplay results live.

## Milestone 2 result

The completion criterion (start, save, close, restart, resume with the publisher
API unavailable) was met twice on build 244978. No game file was modified and no
Telltale service needed a local replacement, so no compatibility patch exists or
is planned for this build.

# REA 05 — Save, preference and progression architecture

## Where state lives

`installscript.vdf` declares `savegamefoldername` = `The Walking Dead`, and the
observed first-run directory matches:

```text
%USERPROFILE%\Documents\Telltale Games\The Walking Dead\
    prefs.prop              (6.4-6.6 KiB observed, rewritten at exit)
    steam_autocloud.vdf     (53 bytes, Steam Auto-Cloud marker)
```

No Telltale registry key existed before the first launch, and none was required for
the game to start. The engine contains a `SaveGameFolderName` property, so the
folder name is data-driven rather than hard-coded.

## Save file naming

Strings in the executable define the save naming contract:

```
%s - %02d.save      (title - slot.save)
*.save              (enumeration pattern)
Save Game File / Save Game Title / Save Game Description / Save Game Subtitle
SaveGameIncremental
IsSaveGameCorrupt
CacheSaveGameImage / GetSaveGameImage
```

On this fresh installation no `.save` files exist yet because no new game has been
started. A save slot is therefore expected at
`...\The Walking Dead\<Title> - <NN>.save`, with a companion image/metadata path
handled by the engine. **This has not yet been observed on disk** — it is the first
thing Milestone 2 must confirm.

## Preference persistence

`prefs.prop` is a binary `.prop` bundle and is obfuscated rather than plain text.
Observed behaviour:

* created on first launch, before the main menu is shown;
* rewritten on clean exit (size changed 6447 → 6591 → 6647 bytes across three
  sessions);
* contains readable fragments including repeated `false` values;
* cannot be parsed by this project yet, and is not required to be: it is backed up
  and restored as opaque bytes, verified by SHA-256.

Related preference bundles referenced by the executable (loaded from archives, not
from the save folder):

```
prefs.prop  prefs_general.prop  prefs_gamewindow.prop  prefs_lang.prop
prefs_language.prop  prefs_platform.prop  prefs_dlg.prop  prefs_idle.prop
prefs_auto_acting.prop  prefs_lipsync2.prop  game_prefs.prop
```

## Choices, episodes and achievements

The engine models dialogue and branching explicitly:

```
Default_Dialog_Branch.prop  Default_Dialog_Choice / Line / Exchange / Item
all_dlg_state.prop  runtime_dialog_logic.prop  Dialog.lua
module_dialog_choice.prop  module_dlg_choice_presentation.prop
```

Choices are consequently part of save state, not a server-side record. Because the
only cloud mechanism present is Steam Auto-Cloud over these local files, an offline
copy of the save folder contains the full choice history.

Achievements are the exception: they live in Steam user stats, with ids such as
`com.telltalegames.WalkingDead105.ch.08` (from `StatsItem_Chapter8.prop`). They
cannot be reconstructed offline and are not part of the save files.

## Backup and restore contract

`tools/Backup-GameProfile.ps1` and `tools/Restore-GameProfile.ps1` implement a
deliberately conservative contract:

1. Backups contain **only** per-user state (never game content or executables).
2. Every copied file is hashed at copy time and the copy is re-hashed before the
   manifest is written.
3. Restore verifies **all** hashes before writing anything; a mismatch aborts the
   restore with exit code 2 and leaves the destination untouched.
4. Restore refuses a non-empty destination unless `-Force` is given.
5. With `-Force`, existing data is first copied to
   `<saveRoot>.pre-restore-<timestamp>`, so a restore is itself reversible.
6. Restored files are verified again after being written.

The manifest also records the executable hash, file version and Steam build id at
backup time, so a backup can be matched to the build that produced it.

## Threat model this addresses

| Risk | Mitigation |
| --- | --- |
| Reinstall / Steam Cloud conflict overwrites progress | Timestamped, hashed snapshots |
| User experiments with settings and loses preferences | Restore with pre-restore safety copy |
| Silent save corruption | Hash verification on every restore |
| Build change invalidating saves | Build identity recorded in the manifest |
| Wrong backup restored to wrong profile | Manifest + profile separation |

## Open questions

* Exact `.save` container layout (header, checksum, embedded thumbnail).
* Whether `IsSaveGameCorrupt` triggers on cross-build saves (relevant to the
  Definitive Series, which uses different content).
* How episode progression is encoded (per-episode save vs. a season state file).
* Whether `prefs.prop` obfuscation is a simple XOR/stream cipher (do not guess; only
  a documented finding should be recorded).

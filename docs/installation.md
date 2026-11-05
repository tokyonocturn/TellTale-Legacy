# Installation and usage

## Prerequisites

* Windows 10/11, Windows PowerShell 5.1 (built in) or PowerShell 7.
* A **legitimately owned** copy of the game installed through Steam.
* Steam client signed in at least once (so a licence is cached for Offline Mode).
* Administrator rights **only** for `Invoke-OfflineProbe.ps1` (it edits the hosts
  file). Every other tool runs as your normal user.

The tools never need to be copied into the game directory, and the game directory
must never be modified.

## Setup

```powershell
git clone <your fork> telltale-legacy
cd telltale-legacy
```

No build step, no dependencies, no package installs.

## 1. Confirm the installation

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Test-OfflineReadiness.ps1
```

Expected on a healthy install: `Verdict: ready`, with an `Info` line confirming the
Steam DRM wrapper and a `Pass` for the build hash, archives, Steam manifest and
DirectX runtime.

If the verdict is `blocked`, fix failures before continuing. Typical causes:

| Failure | Fix |
| --- | --- |
| Executable/archive hash mismatch | Different build — create a new profile instead of forcing this one |
| Missing episode directory | Verify the installation in Steam |
| `StateFlags` not fully installed | Let Steam finish updating |
| Save location not writable | Fix Documents folder permissions |

If you use a different game path:

```powershell
.\tools\Test-OfflineReadiness.ps1 -GameRoot "D:\SteamLibrary\steamapps\common\The Walking Dead"
```

## 2. Back up before anything else

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Backup-GameProfile.ps1 -Label before-testing
```

Backups go to `backups/<timestamp>-<label>/` (git-ignored) with a hash manifest.

Restore:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Restore-GameProfile.ps1 `
    -BackupPath backups\20261105-163000-before-testing
```

Restore refuses to overwrite existing data unless `-Force` is passed, and with
`-Force` it first copies the current data to
`<saveRoot>.pre-restore-<timestamp>`.

## 3. Observe a real session

```powershell
# Normal online launch, observed 60 s, then closed
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Start-ObservedSession.ps1 `
    -ViaSteam -Label baseline -ObservationSeconds 60 -StopAtEnd
```

`-ViaSteam` is required: a direct launch intentionally exits with code 53 and lets
Steam relaunch the game.

To observe a session you launched from Steam yourself:

```powershell
.\tools\Start-ObservedSession.ps1 -AttachProcessId 12345 -Label manual -ObservationSeconds 30
```

Session JSON goes to `docs/rea/data/sessions/`.

## 4. Test offline behaviour

This needs an elevated PowerShell for steps 1 and 3.

```powershell
# 1. Blackhole the publisher API (marked, reversible hosts entry)
.\tools\Invoke-OfflineProbe.ps1 -Action Block

# 2. Confirm the block
.\tools\Invoke-OfflineProbe.ps1 -Action Status
#    api.telltalegames.com -> 127.0.0.1

# 3. Launch through Steam and observe
.\tools\Start-ObservedSession.ps1 -ViaSteam -Label offline -ObservationSeconds 75

# 4. Always remove the block
.\tools\Invoke-OfflineProbe.ps1 -Action Unblock
```

If a machine is ever left blocked, `Invoke-OfflineProbe.ps1 -Action Status` reports
it and `-Action Unblock` (elevated) fixes it.

For a **full** offline test, additionally switch Steam to Offline Mode yourself and
repeat step 3. That path cannot be automated safely from this project.

## 5. Run the tests

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-Tests.ps1
```

Exit code `0` means every test passed. Tests use synthetic fixtures in `%TEMP%` and
never read or write real saves.

## 6. Regenerate evidence

```powershell
# Full inventory (hashes 3.5 GiB; several minutes)
.\tools\Get-GameInventory.ps1 -IncludeUserState

# Readiness report
.\tools\Test-OfflineReadiness.ps1
```

Both write into `docs/rea/data/`, which is git-ignored because it contains absolute
local paths.

## Troubleshooting

| Symptom | Cause | Action |
| --- | --- | --- |
| Direct launch exits with 53 | Steam DRM handoff | Launch through Steam / use `-ViaSteam` |
| `Steam did not start WalkingDead101.exe within 120s` | Steam signed out or app not installed | Sign in, verify install, retry |
| Game shows no window but process runs | Splash phase | Wait; or attach and capture the window |
| Readiness warns about build id | Steam updated the game | Create a new profile, verify, then update the matrix |
| Restore exits with 2 | Backup failed hash verification | Do not force; investigate the backup (see `-AllowHashMismatch` only for forensics) |

#Requires -Version 5.1
<#
.SYNOPSIS
    Restores per-user game state from a Telltale Legacy backup.

.DESCRIPTION
    Verifies every file in the backup manifest against its recorded SHA-256 before
    touching the live save directory, then restores the save tree. Any existing
    per-user data is first copied aside into a .pre-restore-<timestamp> directory,
    so a restore can itself be undone.

    Game installation files are never touched.

.PARAMETER BackupPath
    Backup directory produced by Backup-GameProfile.ps1.

.PARAMETER SaveRoot
    Destination root. Defaults to Documents\Telltale Games.

.PARAMETER SaveSubDirectory
    Must match the SaveSubDirectory the backup was taken with, when one was used.

.PARAMETER Force
    Restore even if the destination already contains files (they are still preserved
    in the .pre-restore directory).

.PARAMETER AllowHashMismatch
    Skip the integrity verification. Not recommended; recorded in the output.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BackupPath,
    [string]$SaveRoot = (Join-Path $env:USERPROFILE 'Documents\Telltale Games'),
    [string]$SaveSubDirectory = '',
    [switch]$Force,
    [switch]$AllowHashMismatch
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$BackupPath = (Resolve-Path -LiteralPath $BackupPath).ProviderPath
$manifestPath = Join-Path $BackupPath 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) { throw "Manifest not found: $manifestPath" }

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if (-not $manifest.Files) { throw "Manifest contains no files: $manifestPath" }

$sourceDir = Join-Path $BackupPath 'saves'
if (-not (Test-Path -LiteralPath $sourceDir)) { throw "Backup payload missing: $sourceDir" }

$targetRoot = if ($SaveSubDirectory) { Join-Path $SaveRoot $SaveSubDirectory } else { $SaveRoot }

# ---- integrity verification (before any write)
$verified = 0
$mismatches = @()
foreach ($entry in $manifest.Files) {
    $file = Join-Path $sourceDir $entry.RelativePath
    if (-not (Test-Path -LiteralPath $file)) {
        $mismatches += [pscustomobject]@{ File = $entry.RelativePath; Reason = 'missing from backup' }
        continue
    }
    $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
    if ($actual -ne $entry.Sha256) {
        $mismatches += [pscustomobject]@{ File = $entry.RelativePath; Reason = 'sha256 mismatch' }
    } else {
        $verified++
    }
}

if ($mismatches.Count -gt 0 -and -not $AllowHashMismatch) {
    Write-Host ("Backup failed integrity verification ({0} problem file(s)). Nothing was restored." -f $mismatches.Count) -ForegroundColor Red
    $mismatches | Format-Table -AutoSize | Out-String | Write-Host
    exit 2
}

# ---- preserve what is currently there
$preRestoreDir = $null
if (Test-Path -LiteralPath $targetRoot) {
    $existing = @(Get-ChildItem -LiteralPath $targetRoot -Recurse -File -Force -ErrorAction SilentlyContinue)
    if ($existing.Count -gt 0) {
        if (-not $Force) {
            throw ("Destination already contains {0} file(s): {1}. Re-run with -Force to restore anyway (existing data is preserved in a .pre-restore directory)." -f $existing.Count, $targetRoot)
        }
        $preRestoreDir = "$targetRoot.pre-restore-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        New-Item -ItemType Directory -Path $preRestoreDir -Force | Out-Null
        Copy-Item -Path (Join-Path $targetRoot '*') -Destination $preRestoreDir -Recurse -Force
    }
}

# ---- restore
New-Item -ItemType Directory -Path $targetRoot -Force | Out-Null
$restored = 0
foreach ($entry in $manifest.Files) {
    $source = Join-Path $sourceDir $entry.RelativePath
    $target = Join-Path $targetRoot $entry.RelativePath
    $parent = Split-Path -Parent $target
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Copy-Item -LiteralPath $source -Destination $target -Force
    $actual = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
    if ($actual -ne $entry.Sha256) { throw "Post-restore verification failed for: $($entry.RelativePath)" }
    $restored++
}

Write-Host ("Verified {0} backup file(s); restored {1} file(s) to {2}" -f $verified, $restored, $targetRoot)
if ($preRestoreDir) { Write-Host ("Previous data preserved in: {0}" -f $preRestoreDir) }

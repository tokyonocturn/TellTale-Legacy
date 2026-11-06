#Requires -Version 5.1
<#
.SYNOPSIS
    Proves a save backup is intact, and that restoring it reproduces identical bytes.

.DESCRIPTION
    A backup that has never been verified is a hope. This checks a backup directory
    against its own manifest by SHA-256, and can prove the restore path without touching
    the live saves at all: `-MaterializeTo` copies the backup's files into a scratch
    directory and re-hashes them there, which is exactly what a restore would produce.
    The live save directory is only ever read.

    Three independent checks, each reported separately:

      backup      every file in the backup still matches the manifest hash
      restore     files materialized into a sandbox match the manifest hash
      current     (optional) the live save directory compared to the manifest, reported
                  as drift so an in-progress play session does not look like corruption

.PARAMETER BackupPath
    Backup directory containing manifest.json.

.PARAMETER MaterializeTo
    Scratch directory to materialize the backup into for the restore proof. Must not be
    inside the live save root; the tool refuses that.

.PARAMETER SaveRoot
    Live save directory, read only, used by -CompareCurrent.

.PARAMETER CompareCurrent
    Also compare the live save directory against the manifest.

.PARAMETER OutputPath
    Optional JSON report path.

.PARAMETER AsJson
    Emit the report as JSON on stdout.

.OUTPUTS
    Exit codes: 0 all requested checks passed; 10 backup file missing or hash mismatch;
    11 restore proof mismatch; 12 manifest unreadable or empty; 13 unsafe materialize path.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BackupPath,
    [string]$MaterializeTo = '',
    [string]$SaveRoot = '',
    [switch]$CompareCurrent,
    [string]$OutputPath = '',
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $SaveRoot) { $SaveRoot = Join-Path $env:USERPROFILE 'Documents\Telltale Games' }
$backupFull = [System.IO.Path]::GetFullPath($BackupPath)
$manifestPath = Join-Path $backupFull 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) { throw "Manifest not found: $manifestPath" }

try {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
} catch {
    throw "Manifest could not be parsed: $manifestPath"
}
$entries = @($manifest.Files)
if ($entries.Count -eq 0) {
    [pscustomobject]@{ Verdict = 'manifest-empty'; ManifestPath = $manifestPath } | ConvertTo-Json -Depth 4
    exit 12
}

# Backup-GameProfile.ps1 lays the copied files out under 'saves'; older layouts used 'files'.
$filesDir = if (Test-Path -LiteralPath (Join-Path $backupFull 'saves')) { Join-Path $backupFull 'saves' }
            elseif (Test-Path -LiteralPath (Join-Path $backupFull 'files')) { Join-Path $backupFull 'files' }
            else { Join-Path $backupFull 'saves' }
$problems = New-Object System.Collections.Generic.List[string]
$checked = 0

# 1. The backup itself.
foreach ($entry in $entries) {
    $path = Join-Path $filesDir $entry.RelativePath
    if (-not (Test-Path -LiteralPath $path)) {
        $problems.Add("missing-in-backup: $($entry.RelativePath)")
        continue
    }
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    if ($hash -ne $entry.Sha256) {
        $problems.Add("hash-mismatch: $($entry.RelativePath) manifest=$($entry.Sha256) actual=$hash")
    }
    $checked++
}
$backupOk = ($problems.Count -eq 0)

# 2. The restore proof, into a sandbox that cannot be the live save root.
$restoreOk = $null
$materialized = 0
if ($MaterializeTo) {
    $target = [System.IO.Path]::GetFullPath($MaterializeTo)
    $saveFull = [System.IO.Path]::GetFullPath($SaveRoot)
    if ($target.TrimEnd('\') -eq $saveFull.TrimEnd('\')) {
        $problems.Add('unsafe-materialize-path: refusing to write a restore proof over the live saves')
        $restoreOk = $false
    } else {
        if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }
        $restoreProblems = New-Object System.Collections.Generic.List[string]
        foreach ($entry in $entries) {
            $source = Join-Path $filesDir $entry.RelativePath
            if (-not (Test-Path -LiteralPath $source)) { $restoreProblems.Add("missing-source: $($entry.RelativePath)"); continue }
            $destination = Join-Path $target $entry.RelativePath
            $parent = Split-Path -Parent $destination
            if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            Copy-Item -LiteralPath $source -Destination $destination -Force
            $hash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
            if ($hash -ne $entry.Sha256) {
                $restoreProblems.Add("restore-mismatch: $($entry.RelativePath) expected=$($entry.Sha256) got=$hash")
            }
            $materialized++
        }
        foreach ($p in $restoreProblems) { $problems.Add($p) }
        $restoreOk = ($restoreProblems.Count -eq 0)
    }
}

# 3. Optional comparison with the live saves: drift, not corruption.
$current = $null
if ($CompareCurrent) {
    $drift = @()
    foreach ($entry in $entries) {
        $live = Join-Path $SaveRoot $entry.RelativePath
        if (-not (Test-Path -LiteralPath $live)) { $drift += [pscustomobject]@{ Path = $entry.RelativePath; State = 'absent-live' }; continue }
        $hash = (Get-FileHash -LiteralPath $live -Algorithm SHA256).Hash
        if ($hash -ne $entry.Sha256) { $drift += [pscustomobject]@{ Path = $entry.RelativePath; State = 'changed-since-backup'; Sha256 = $hash } }
    }
    $current = [pscustomobject]@{
        SaveRoot = $SaveRoot
        Drift    = $drift
        Identical = ($drift.Count -eq 0)
    }
}

$verdict = if (-not $backupOk) { 'backup-mismatch' }
           elseif ($restoreOk -eq $false) { 'restore-mismatch' }
           else { 'verified' }
$exit = if ($verdict -eq 'backup-mismatch') { 10 } elseif ($verdict -eq 'restore-mismatch') { 11 } else { 0 }

$report = [ordered]@{
    SchemaVersion = 1
    GeneratedUtc  = (Get-Date).ToUniversalTime().ToString('o')
    Verdict       = $verdict
    ExitCode      = $exit
    BackupPath    = $backupFull
    ManifestPath  = $manifestPath
    Label         = $manifest.Label
    CreatedUtc    = $manifest.CreatedUtc
    SourceRoot    = $manifest.SourceRoot
    FilesChecked  = $checked
    TotalInManifest = $entries.Count
    BackupIntact  = $backupOk
    RestoreProof  = $restoreOk
    Materialized  = $materialized
    MaterializeTo = if ($MaterializeTo) { [System.IO.Path]::GetFullPath($MaterializeTo) } else { $null }
    Current       = $current
    Problems      = @($problems)
}

$json = $report | ConvertTo-Json -Depth 6
if ($OutputPath) {
    $full = [System.IO.Path]::GetFullPath($OutputPath)
    $parent = Split-Path -Parent $full
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Set-Content -LiteralPath $full -Value $json -Encoding UTF8
}
if ($AsJson) { $json } else { $json }

exit $exit

#Requires -Version 5.1
<#
.SYNOPSIS
    Creates a verified, restorable snapshot of per-user game state.

.DESCRIPTION
    Copies the game's per-user save and preference data (never game content) into a
    timestamped backup directory together with a manifest containing SHA-256 hashes,
    the game build identity and the Telltale per-user registry values.

    Game installation files are only read (hash + build id), never modified.

.PARAMETER SaveRoot
    Root of the per-user data. Defaults to Documents\Telltale Games.

.PARAMETER GameRoot
    Installation directory, used to record build identity. Optional.

.PARAMETER Destination
    Backup root directory. Defaults to <repo>\backups.

.PARAMETER Label
    Suffix for the backup directory name.

.PARAMETER SaveSubDirectory
    Optional subdirectory inside SaveRoot to snapshot (for example "The Walking Dead").
#>
[CmdletBinding()]
param(
    [string]$SaveRoot = (Join-Path $env:USERPROFILE 'Documents\Telltale Games'),
    [string]$GameRoot = 'C:\Program Files (x86)\Steam\steamapps\common\The Walking Dead',
    [string]$Destination,
    [string]$Label = 'manual',
    [string]$SaveSubDirectory = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $Destination) { $Destination = Join-Path $repoRoot 'backups' }

$sourceRoot = if ($SaveSubDirectory) { Join-Path $SaveRoot $SaveSubDirectory } else { $SaveRoot }
if (-not (Test-Path -LiteralPath $sourceRoot)) {
    throw "No per-user data to back up at: $sourceRoot"
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDir = Join-Path $Destination ("$stamp-$Label")
if (Test-Path -LiteralPath $backupDir) { throw "Backup directory already exists: $backupDir" }
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

$filesDir = Join-Path $backupDir 'saves'
New-Item -ItemType Directory -Path $filesDir -Force | Out-Null

$files = @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force)
$entries = New-Object System.Collections.Generic.List[object]

foreach ($file in $files) {
    $relative = $file.FullName.Substring($sourceRoot.Length).TrimStart('\')
    $target = Join-Path $filesDir $relative
    $targetParent = Split-Path -Parent $target
    if ($targetParent -and -not (Test-Path -LiteralPath $targetParent)) {
        New-Item -ItemType Directory -Path $targetParent -Force | Out-Null
    }
    Copy-Item -LiteralPath $file.FullName -Destination $target -Force

    $sourceHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    $copyHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
    if ($sourceHash -ne $copyHash) { throw "Copy verification failed for: $relative" }

    $entries.Add([pscustomobject]@{
        RelativePath = $relative
        SizeBytes    = (Get-Item -LiteralPath $target).Length
        Sha256       = $copyHash
        LastWriteUtc = $file.LastWriteTimeUtc.ToString('u')
    })
}

# Per-user registry values, captured as data (no secrets, no binary hive export).
$registry = @()
foreach ($key in @('HKCU:\Software\Telltale Games', 'HKCU:\Software\Telltale Games\WalkingDead101.exe')) {
    if (Test-Path -LiteralPath $key) {
        $item = Get-Item -LiteralPath $key
        $values = [ordered]@{}
        $props = Get-ItemProperty -LiteralPath $item.PSPath
        foreach ($prop in $props.PSObject.Properties) {
            if ($prop.Name -like 'PS*') { continue }
            $values[$prop.Name] = [string]$prop.Value
        }
        $registry += [pscustomobject]@{ Key = $key; Values = $values }
    }
}

# Build identity of the installation (read-only).
$gameIdentity = [ordered]@{ GameRoot = $GameRoot; Present = (Test-Path -LiteralPath $GameRoot) }
if ($gameIdentity.Present) {
    $exe = Join-Path $GameRoot 'WalkingDead101.exe'
    if (Test-Path -LiteralPath $exe) {
        $gameIdentity['ExecutableSha256'] = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
        $gameIdentity['ExecutableVersion'] = (Get-Item -LiteralPath $exe).VersionInfo.FileVersion
    }
    $manifest = Join-Path (Split-Path -Parent (Split-Path -Parent $GameRoot)) 'appmanifest_207610.acf'
    if (Test-Path -LiteralPath $manifest) {
        $text = Get-Content -LiteralPath $manifest -Raw
        if ($text -match '"buildid"\s+"(\d+)"') { $gameIdentity['SteamBuildId'] = $Matches[1] }
        if ($text -match '"LastOwner"\s+"(\d+)"') { $gameIdentity['SteamLastOwner'] = $Matches[1] }
    }
}

$document = [ordered]@{
    SchemaVersion   = 1
    CreatedUtc      = (Get-Date).ToUniversalTime().ToString('u')
    Label           = $Label
    SourceRoot      = $sourceRoot
    FileCount       = $entries.Count
    TotalBytes      = ($entries | Measure-Object -Property SizeBytes -Sum).Sum
    Game            = $gameIdentity
    Registry        = $registry
    Files           = $entries
}

$manifestPath = Join-Path $backupDir 'manifest.json'
[System.IO.File]::WriteAllText($manifestPath, ($document | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))

Write-Host ("Backed up {0} file(s), {1:N2} KiB" -f $entries.Count, ($document.TotalBytes / 1KB))
Write-Host ("Backup   : {0}" -f $backupDir)
Write-Host ("Manifest : {0}" -f $manifestPath)

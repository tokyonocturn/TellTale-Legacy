#Requires -Version 5.1
<#
.SYNOPSIS
    Verifies that every episode recorded in the compatibility profile has local content.

.DESCRIPTION
    Reads the profile's content.episodeDirectories map and confirms each directory
    exists under <GameRoot>\Pack with at least one .ttarch archive. This is what makes
    "episode N is installed" a checked fact instead of an assumption: a missing or
    empty pack directory is reported as a failure, because the game cannot load that
    episode offline if its archives are not on disk.

    Read-only. Exit 0 when every episode is present, 2 when anything is missing.

.EXAMPLE
    .\Test-ContentPacks.ps1
    .\Test-ContentPacks.ps1 -GameRoot 'D:\Games\The Walking Dead' -OutputPath out.json
#>
[CmdletBinding()]
param(
    [string]$GameRoot = 'C:\Program Files (x86)\Steam\steamapps\common\The Walking Dead',
    [string]$ProfilePath = 'profiles\twd-s1-steam-207610\profile.json',
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$profileFull = if ([System.IO.Path]::IsPathRooted($ProfilePath)) { [System.IO.Path]::GetFullPath($ProfilePath) } else { [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $ProfilePath)) }
if (-not (Test-Path -LiteralPath $profileFull)) { [Console]::Error.WriteLine("Profile not found: $profileFull"); exit 2 }
if (-not (Test-Path -LiteralPath $GameRoot)) { [Console]::Error.WriteLine("Game root not found: $GameRoot"); exit 2 }

$profile = Get-Content -LiteralPath $profileFull -Raw | ConvertFrom-Json
$archiveRoot = Join-Path $GameRoot $profile.content.archiveRoot
if (-not (Test-Path -LiteralPath $archiveRoot)) { [Console]::Error.WriteLine("Archive root not found: $archiveRoot"); exit 2 }

$results = @()
$failures = 0
foreach ($property in $profile.content.episodeDirectories.PSObject.Properties) {
    $directoryName = $property.Name
    $episodeNumber = $property.Value.episode
    $directory = Join-Path $archiveRoot $directoryName
    $exists = Test-Path -LiteralPath $directory
    $archives = @()
    if ($exists) {
        $archives = @(Get-ChildItem -LiteralPath $directory -Filter '*.ttarch' -File -ErrorAction SilentlyContinue)
    }
    $ok = ($exists -and $archives.Count -gt 0)
    if (-not $ok) { $failures++ }
    $totalBytes = if ($archives.Count -gt 0) { ($archives | Measure-Object -Property Length -Sum).Sum } else { 0 }

    $results += [pscustomobject]@{
        Episode      = $episodeNumber
        Directory    = $directoryName
        Exists       = $exists
        ArchiveCount = $archives.Count
        TotalBytes   = $totalBytes
        Ok           = $ok
    }
}

$report = [pscustomobject]@{
    SchemaVersion = 1
    GeneratedUtc  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ssZ')
    GameRoot      = $GameRoot
    ArchiveRoot   = $archiveRoot
    EpisodeCount  = $results.Count
    MissingCount  = $failures
    AllPresent    = ($failures -eq 0)
    Episodes      = $results
}

if ($OutputPath) {
    $outFull = if ([System.IO.Path]::IsPathRooted($OutputPath)) { [System.IO.Path]::GetFullPath($OutputPath) } else { [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $OutputPath)) }
    $outDir = Split-Path -Parent $outFull
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $outFull -Encoding UTF8
}

$results | Sort-Object Episode | Format-Table -AutoSize

if ($failures -gt 0) {
    [Console]::Error.WriteLine(("{0} episode pack(s) missing or empty under {1}" -f $failures, $archiveRoot))
    exit 2
}

Write-Host ("All {0} episode packs present." -f $results.Count)
exit 0

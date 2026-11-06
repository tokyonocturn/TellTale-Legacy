#Requires -Version 5.1
<#
.SYNOPSIS
    Summarises a recorded session into checkpoints, audio statistics and save drift.

.DESCRIPTION
    Reads the JSONL index written by Watch-GameSession.ps1 and reduces it to the facts a
    report needs: how long the session ran, which save files were written when (each write
    is a checkpoint the game made, with its hash so the same bytes can be recognised
    later), what the audio peaks were on the required endpoint versus the system default,
    and whether the default device moved at any point.

    Read-only. It never touches the game or its saves.

.PARAMETER IndexPath
    Path to index.jsonl.

.PARAMETER OutputPath
    Optional JSON report path.

.PARAMETER AsJson
    Emit the report as JSON on stdout.
#>
[CmdletBinding()]
param(
    [string]$IndexPath = '',
    [string]$OutputPath = '',
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $IndexPath) { $IndexPath = Join-Path $root 'tools\scratch\session\index.jsonl' }
if (-not (Test-Path -LiteralPath $IndexPath)) { throw "Session index not found: $IndexPath" }

$rows = @(Get-Content -LiteralPath $IndexPath | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
$samples = @($rows | Where-Object { $_.frame })
if ($samples.Count -eq 0) { throw 'Session index contains no frame samples.' }

$first = $samples[0].t
$last = $samples[-1].t

# Save writes: a sample that reports saveEvent=true is the moment a checkpoint landed.
$writes = @()
$previous = $null
foreach ($sample in $samples) {
    if ($sample.saveEvent) {
        foreach ($file in $sample.saves) {
            $oldHash = $null
            if ($previous) {
                $match = @($previous.saves | Where-Object { $_.name -eq $file.name })
                if ($match.Count -gt 0) { $oldHash = $match[0].sha256 }
            }
            if ($oldHash -ne $file.sha256) {
                $writes += [pscustomobject]@{
                    Utc      = $sample.t
                    File     = $file.name
                    Bytes    = $file.bytes
                    Sha256   = $file.sha256
                    Modified = $file.modified
                    Frame    = $sample.frame
                    Change   = if ($oldHash) { 'rewritten' } else { 'appeared' }
                }
            }
        }
    }
    $previous = $sample
}

function Get-Stats {
    param([double[]]$Values)
    $clean = @($Values | Where-Object { $null -ne $_ })
    if ($clean.Count -eq 0) { return $null }
    $sorted = $clean | Sort-Object
    [pscustomobject]@{
        Samples = $clean.Count
        Min     = [math]::Round(($sorted | Measure-Object -Minimum).Minimum, 6)
        Median  = [math]::Round($sorted[[int][math]::Floor($sorted.Count / 2)], 6)
        Max     = [math]::Round(($sorted | Measure-Object -Maximum).Maximum, 6)
        NonZero = @($clean | Where-Object { $_ -gt 0 }).Count
    }
}

$targetPeaks = @($samples | ForEach-Object { $_.audio.targetPeak })
$defaultPeaks = @($samples | ForEach-Object { $_.audio.defaultPeak })
$defaultNames = @($samples | ForEach-Object { $_.audio.defaultName } | Where-Object { $_ } | Sort-Object -Unique)

$report = [ordered]@{
    SchemaVersion = 1
    GeneratedUtc  = (Get-Date).ToUniversalTime().ToString('o')
    IndexPath     = (Resolve-Path -LiteralPath $IndexPath).Path
    StartedUtc    = $first
    LastSampleUtc = $last
    DurationSeconds = [math]::Round(((Get-Date $last) - (Get-Date $first)).TotalSeconds, 0)
    Samples       = $samples.Count
    Frames        = @($samples | ForEach-Object { $_.frame } | Sort-Object -Unique).Count
    SaveWrites    = @($writes)
    SaveWriteCount = $writes.Count
    Audio = [ordered]@{
        Required = Get-Stats -Values $targetPeaks
        Default  = Get-Stats -Values $defaultPeaks
        DefaultNamesSeen = $defaultNames
        DefaultChangedDuringSession = ($defaultNames.Count -gt 1)
    }
    GamePids = @($samples | ForEach-Object { $_.pid } | Sort-Object -Unique)
}

$json = $report | ConvertTo-Json -Depth 6
if ($OutputPath) {
    $full = [System.IO.Path]::GetFullPath($OutputPath)
    $parent = Split-Path -Parent $full
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Set-Content -LiteralPath $full -Value $json -Encoding UTF8
}
$json

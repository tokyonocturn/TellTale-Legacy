#Requires -Version 5.1
<#
.SYNOPSIS
    Records an attended play session as preservation evidence.

.DESCRIPTION
    While The Walking Dead is running, this samples the machine on a fixed interval and
    writes evidence that cannot be reconstructed later:

      * a downscaled frame of the game window (visual record of each step),
      * the save directory state (name, size, timestamp, SHA-256) on every change,
      * the audio peak on the required endpoint and on the system default, so the routing
        claim is backed by numbers taken during real play,
      * a JSONL index tying every sample to a timestamp, process id and window title.

    Frames are kept at reduced size on purpose: the point is a timeline of what was on
    screen, not a high-fidelity copy of the game's art. Nothing here writes to the game,
    its saves or its settings.

.PARAMETER Minutes
    How long to watch. The watcher stops early if the game exits.

.PARAMETER IntervalSeconds
    Seconds between samples.

.PARAMETER OutDir
    Directory for frames and the JSONL index.
#>
[CmdletBinding()]
param(
    [int]$Minutes = 240,
    [int]$IntervalSeconds = 12,
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $OutDir) { $OutDir = Join-Path $root 'tools\scratch\session' }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

$frameDir = Join-Path $OutDir 'frames'
if (-not (Test-Path -LiteralPath $frameDir)) { New-Item -ItemType Directory -Path $frameDir -Force | Out-Null }

$index = Join-Path $OutDir 'index.jsonl'
$saves = Join-Path $env:USERPROFILE 'Documents\Telltale Games\The Walking Dead'
$input = Join-Path $root 'tools\Invoke-GameInput.ps1'
$route = Join-Path $root 'tools\Get-AudioRoute.ps1'

function Get-SaveState {
    if (-not (Test-Path -LiteralPath $saves)) { return @() }
    Get-ChildItem -LiteralPath $saves -File |
        Sort-Object Name |
        ForEach-Object {
            [pscustomobject]@{
                name = $_.Name
                bytes = $_.Length
                modified = $_.LastWriteTime.ToUniversalTime().ToString('o')
                sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.Substring(0, 16)
            }
        }
}

function Get-AudioPeaks {
    $result = [ordered]@{ defaultName = $null; defaultPeak = $null; targetName = $null; targetPeak = $null }
    try {
        $rows = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $route 2>$null
        foreach ($line in $rows) {
            if ($line -match '^(?<name>\S.*?)\s+active\s+(?<def>True|False)\s+(?<peak>[0-9.]+)\s*$') {
                $name = $Matches.name.Trim()
                $peak = [double]$Matches.peak
                if ($Matches.def -eq 'True') { $result.defaultName = $name; $result.defaultPeak = $peak }
                if ($name -like '100027813*') { $result.targetName = $name; $result.targetPeak = $peak }
            }
        }
    } catch { }
    [pscustomobject]$result
}

$deadline = (Get-Date).AddMinutes($Minutes)
$lastSaveFingerprint = $null
$samples = 0
$saveEvents = 0
$started = (Get-Date).ToUniversalTime().ToString('o')

while ((Get-Date) -lt $deadline) {
    $proc = Get-Process WalkingDead101 -ErrorAction SilentlyContinue
    if (-not $proc) {
        Add-Content -LiteralPath $index -Value (@{ t = (Get-Date).ToUniversalTime().ToString('o'); event = 'game-exited'; samples = $samples; saveEvents = $saveEvents } | ConvertTo-Json -Compress)
        break
    }
    $proc = $proc | Select-Object -First 1
    $samples++

    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $png = Join-Path $frameDir "$stamp.png"
    $jpg = Join-Path $frameDir "$stamp.jpg"
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $input -Action Capture -CaptureMethod Window -OutputPath $png 2>$null | Out-Null
        if (Test-Path -LiteralPath $png) {
            $img = [System.Drawing.Image]::FromFile($png)
            try {
                $w = 480
                $h = [int]([math]::Round($img.Height * ($w / $img.Width)))
                $bmp = New-Object System.Drawing.Bitmap $w, $h
                $g = [System.Drawing.Graphics]::FromImage($bmp)
                try {
                    $g.InterpolationMode = 'HighQualityBicubic'
                    $g.DrawImage($img, 0, 0, $w, $h)
                } finally { $g.Dispose() }
                $bmp.Save($jpg, [System.Drawing.Imaging.ImageFormat]::Jpeg)
                $bmp.Dispose()
            } finally { $img.Dispose() }
            Remove-Item -LiteralPath $png -Force -ErrorAction SilentlyContinue
        }
    } catch { }

    $state = @(Get-SaveState)
    $fingerprint = ($state | ForEach-Object { "$($_.name):$($_.bytes):$($_.modified):$($_.sha256)" }) -join '|'
    $saveEvent = $false
    if ($fingerprint -ne $lastSaveFingerprint) {
        $saveEvent = $true
        $saveEvents++
        $lastSaveFingerprint = $fingerprint
    }

    $peaks = Get-AudioPeaks

    $record = [ordered]@{
        t = (Get-Date).ToUniversalTime().ToString('o')
        pid = $proc.Id
        title = $proc.MainWindowTitle
        frame = (Split-Path -Leaf $jpg)
        saveEvent = $saveEvent
        saves = $state
        audio = $peaks
    }
    Add-Content -LiteralPath $index -Value ($record | ConvertTo-Json -Compress -Depth 6)

    Start-Sleep -Seconds $IntervalSeconds
}

Add-Content -LiteralPath $index -Value (@{ t = (Get-Date).ToUniversalTime().ToString('o'); event = 'watcher-stopped'; started = $started; samples = $samples; saveEvents = $saveEvents } | ConvertTo-Json -Compress)
"session recorder stopped: $samples samples, $saveEvents save events, index $index"

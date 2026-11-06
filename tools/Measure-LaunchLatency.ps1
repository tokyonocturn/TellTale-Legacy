#Requires -Version 5.1
<#
.SYNOPSIS
    Measures how long an offline launch takes to become usable, by driving the frontend.

.DESCRIPTION
    The offline wait is not a frozen window: the game creates its window in seconds and keeps
    answering Windows' liveness probe while a network call blocks somewhere else. So neither
    "the window exists" nor "the process responds" measures it. What measures it is whether
    the game *accepts* input, so this drives the frontend and times each step:

      title screen  ->  main menu  ->  slot list  ->  episode page

    Each step is a click at a measured point, and it only counts when the rendered frame
    actually changed as a result (mean grey difference above a threshold). The clock starts
    when Steam is asked to start the game; each step's acceptance time is recorded, and the
    episode page is the moment the game is ready to be played.

    The hosts file is never modified here. It is hashed and its publisher entries recorded so
    every measurement is tied to the configuration that produced it.

.PARAMETER Label
    Name for this measurement; used in the file name and the JSON.

.PARAMETER TimeoutSeconds
    Give up after this long. The stall being measured is 60-90 s.

.PARAMETER OutputDirectory
    Where the JSON goes. Defaults to tools/scratch/latency.

.PARAMETER ChangeThreshold
    Mean grey difference that counts as "the game accepted the click".

.PARAMETER KeepRunning
    Leave the game running at the episode page when the measurement ends.

.EXAMPLE
    .\tools\Measure-LaunchLatency.ps1 -Label offline-no-patch -TimeoutSeconds 200

.OUTPUTS
    0 measured; 20 the game was already running; 21 the window never appeared.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Label,
    [int]$TimeoutSeconds = 200,
    [string]$OutputDirectory = '',
    [double]$ChangeThreshold = 6.0,
    [switch]$KeepRunning,
    [string]$HostsPath = (Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'),
    [string]$PythonPath = 'python'
)

$ErrorActionPreference = 'Stop'

$inputTool = Join-Path $PSScriptRoot 'Invoke-GameInput.ps1'
$classifier = Join-Path $PSScriptRoot 'classify_frame.py'

# Measured click points (1920x1071 client). See docs/rea/12 and docs/rea/18.
$steps = @(
    [pscustomobject]@{ Name = 'title-continue'; Point = @(960, 640) },
    [pscustomobject]@{ Name = 'main-menu-play'; Point = @(500, 338) },
    [pscustomobject]@{ Name = 'slot-row'; Point = @(900, 346) },
    [pscustomobject]@{ Name = 'slot-play'; Point = @(1587, 962) }
)
$exitPoint = @(531, 640)

function Get-HostsSnapshot {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{ Hash = ''; Entries = @() } }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '').ToUpperInvariant()
    $text = [System.IO.File]::ReadAllText($Path)
    $entries = @()
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^\s*\d+\.\d+\.\d+\.\d+\s+(\S*telltale\S*)') { $entries += $line.Trim() }
    }
    [pscustomobject]@{ Hash = $hash; Entries = $entries }
}

if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools/scratch/latency'
}
if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}

$existing = Get-Process -Name 'WalkingDead101' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($existing) {
    Write-Error "The game is already running (pid $($existing.Id)); close it before measuring."
    exit 20
}

$hosts = Get-HostsSnapshot -Path $HostsPath
$before = Join-Path $OutputDirectory 'latency-before.png'
$after = Join-Path $OutputDirectory 'latency-after.png'

$started = Get-Date
Start-Process 'steam://rungameid/207610'

$timeline = New-Object System.Collections.Generic.List[object]
$windowAt = $null
$processId = 0
$stepIndex = 0
$attempts = @{}
$deadline = $started.AddSeconds($TimeoutSeconds)
$accepted = @{}

while ((Get-Date) -lt $deadline -and $stepIndex -lt $steps.Count) {
    $process = Get-Process -Name 'WalkingDead101' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $process) { Start-Sleep -Milliseconds 600; continue }

    $processId = $process.Id
    $elapsed = [math]::Round(((Get-Date) - $started).TotalSeconds, 2)
    if ($null -eq $windowAt) { $windowAt = $elapsed }

    $step = $steps[$stepIndex]
    if (-not $attempts.ContainsKey($step.Name)) { $attempts[$step.Name] = 0 }
    $attempts[$step.Name]++

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $inputTool `
        -Action Capture -CaptureMethod Window -OwnerPid $processId -OutputPath $before | Out-Null
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $inputTool `
        -Action Click -X $step.Point[0] -Y $step.Point[1] -OwnerPid $processId | Out-Null
    Start-Sleep -Milliseconds 1200
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $inputTool `
        -Action Capture -CaptureMethod Window -OwnerPid $processId -OutputPath $after | Out-Null

    $diff = 0.0
    try {
        $json = & $PythonPath $classifier $after $before 2>$null
        if ($json) { $diff = [double](($json | ConvertFrom-Json).diff) }
    } catch {
        $diff = 0.0
    }

    $timeline.Add([pscustomobject]@{
        t = $elapsed
        step = $step.Name
        attempt = $attempts[$step.Name]
        diff = $diff
        accepted = ($diff -ge $ChangeThreshold)
    })

    if ($diff -ge $ChangeThreshold) {
        $accepted[$step.Name] = $elapsed
        Copy-Item -LiteralPath $after -Destination (Join-Path $OutputDirectory ("latency-{0}-{1}.png" -f $Label, $step.Name)) -Force
        $stepIndex++
    } elseif ($attempts[$step.Name] -ge 12 -and $stepIndex -eq 0) {
        # The title screen may already have advanced on its own; try the menu directly.
        Write-Host 'Title continue not accepted after 12 tries; trying the main menu.'
        $stepIndex++
    } elseif ($attempts[$step.Name] -ge 25) {
        # Never accepted; stop rather than spend the whole budget on one step.
        break
    }

    Start-Sleep -Milliseconds 300
}

$result = [pscustomobject]@{
    Label = $Label
    StartedAt = $started.ToString('s')
    Pid = $processId
    WindowSeconds = $windowAt
    TitleContinueSeconds = $accepted['title-continue']
    MainMenuSeconds = $accepted['main-menu-play']
    SlotListSeconds = $accepted['slot-row']
    EpisodePageSeconds = $accepted['slot-play']
    UsableSeconds = $accepted['slot-play']
    StepsAccepted = $accepted.Count
    Attempts = ($steps | ForEach-Object { '{0}={1}' -f $_.Name, $attempts[$_.Name] }) -join ' '
    ChangeThreshold = $ChangeThreshold
    HostsHash = $hosts.Hash
    HostsEntries = $hosts.Entries
}

$file = Join-Path $OutputDirectory ("latency-$Label-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
[pscustomobject]@{ Result = $result; Timeline = $timeline } |
    ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $file -Encoding UTF8

$result | Format-List

if (-not $KeepRunning -and $processId -ne 0) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $inputTool -Action Click -X $exitPoint[0] -Y $exitPoint[1] -OwnerPid $processId | Out-Null
    Start-Sleep -Seconds 4
    if (Get-Process -Id $processId -ErrorAction SilentlyContinue) {
        Stop-Process -Id $processId -Force
        Write-Host 'The frontend EXIT GAME click did not close the game; closed the measured process.'
    }
}

if ($null -eq $windowAt) { exit 21 }
exit 0

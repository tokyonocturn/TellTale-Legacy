#Requires -Version 5.1
<#
.SYNOPSIS
    Carries one episode from the frontend into a committed dialogue choice with nobody at
    the controls, and records what it saw and did.

.DESCRIPTION
    An unattended counterpart to driving the game by hand. It launches nothing itself unless
    asked, navigates the real frontend through measured click points, and then watches the
    game frame by frame:

      * a frame that keeps changing is a cinematic - it waits;
      * a frame that has stopped changing draws a recovery probe (pointer movement, clicks,
        keys, pause/resume) and records which probe, if any, made the picture move again;
      * a frame with several dialogue-response rows on it is a choice - it clicks a response
        and then verifies the response list is gone, which is what "the choice was committed"
        looks like from outside the process.

    Every action is logged with the frame difference that followed it, so "the harness sent
    input and the game ignored it" and "the game was not ready for input yet" stay separable
    afterwards. No memory is read or written, no game file is modified, no save is edited.

.PARAMETER Episode
    Episode page to start, 1-5. The frontend is driven by its own paging arrows.

.PARAMETER Minutes
    Wall-clock budget for the observation loop after the episode starts.

.PARAMETER OutputDirectory
    Where frames and the JSONL event log go. Defaults to tools/scratch/runs/<timestamp>.

.PARAMETER Launch
    Start the game through Steam when it is not already running.

.PARAMETER SkipBlockCheck
    Run anyway when the publisher block is not present in the hosts file. Recorded.

.PARAMETER HostsPath
    Hosts file to inspect. Exists so the preflight can be tested without the system file.

.EXAMPLE
    .\tools\Invoke-UnattendedRun.ps1 -Episode 2 -Minutes 18 -Launch

.OUTPUTS
    Exit 0  a dialogue response was clicked and the response list cleared
    Exit 20 preflight failed (publisher block absent, or the input tool is missing)
    Exit 21 the game window never appeared
    Exit 22 the frame classifier could not run
    Exit 30 the budget ran out before a choice was committed
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 5)][int]$Episode = 2,
    [int]$Minutes = 15,
    [string]$OutputDirectory = '',
    [switch]$Launch,
    [switch]$SkipBlockCheck,
    [string]$HostsPath = (Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'),
    [int]$OwnerPid = 0,
    [string]$PythonPath = 'python'
)

$ErrorActionPreference = 'Stop'

$inputTool = Join-Path $PSScriptRoot 'Invoke-GameInput.ps1'
$classifier = Join-Path $PSScriptRoot 'classify_frame.py'

# Click points measured on this display (1920x1071 client). See docs/rea/12 and 18.
$FrontendContinue = @(960, 640)
$FrontendPlay = @(500, 338)
$SlotRow = @(900, 346)
$BottomBar = @(1587, 962)
$ArrowRight = @(1644, 103)
$ArrowLeft = @(270, 94)
$DialogYes = @(642, 745)
$PauseResume = @(960, 410)

function Test-PublisherBlock {
    <#
    .SYNOPSIS
        True when both publisher domains are still mapped by the hosts file.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $text = Get-Content -LiteralPath $Path -Raw
    return (($text -match 'api\.telltalegames\.com') -and ($text -match 'meta\.telltalegames\.com'))
}

function Get-RemoteConnectionCount {
    <#
    .SYNOPSIS
        Remote (non-loopback) TCP connections owned by the process.
    #>
    param([Parameter(Mandatory)][int]$ProcessId)

    $loopback = @('0.0.0.0', '::', '127.0.0.1', '::1')
    try {
        $connections = @(Get-NetTCPConnection -OwningProcess $ProcessId -ErrorAction Stop)
    } catch {
        return 0
    }
    return @($connections | Where-Object { $loopback -notcontains $_.RemoteAddress }).Count
}

function Get-GameFrame {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$ProcessId
    )

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $inputTool `
        -Action Capture -CaptureMethod Window -OwnerPid $ProcessId -OutputPath $Path | Out-Null
    if (-not (Test-Path -LiteralPath $Path)) { throw "Frame capture produced no file: $Path" }
    $Path
}

function Get-FrameClassification {
    param(
        [Parameter(Mandatory)][string]$Current,
        [string]$Previous
    )

    $arguments = @($classifier, $Current)
    if ($Previous) { $arguments += $Previous }
    $json = & $PythonPath @arguments 2>&1
    if ($LASTEXITCODE -ne 0 -or -not $json) { throw "Frame classifier failed: $json" }
    return ($json | ConvertFrom-Json)
}

function Invoke-GameAction {
    <#
    .SYNOPSIS
        Runs one action through the input driver and returns its output text.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][int]$ProcessId
    )

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $inputTool @Arguments -OwnerPid $ProcessId 2>&1
}

function Wait-GameWindow {
    param(
        [int]$TimeoutSeconds = 150,
        [string]$ProcessName = 'WalkingDead101'
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $process = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($process -and $process.MainWindowHandle -ne [IntPtr]::Zero) { return $process.Id }
        Start-Sleep -Milliseconds 900
    }
    return 0
}

function Get-ClientScale {
    <#
    .SYNOPSIS
        Client height and width of the game window, for turning classifier rows into clicks.
    #>
    param([Parameter(Mandatory)][int]$ProcessId)

    $info = (Invoke-GameAction -Arguments @('-Action', 'Info') -ProcessId $ProcessId) -join "`n"
    $width = 0
    $height = 0
    if ($info -match 'ClientWidth\s*:\s*(\d+)') { $width = [int]$Matches[1] }
    if ($info -match 'ClientHeight\s*:\s*(\d+)') { $height = [int]$Matches[1] }
    [pscustomobject]@{ Width = $width; Height = $height }
}

function Get-StaticThreshold {
    <#
    .SYNOPSIS
        Frame difference below which the picture counts as stopped, from observed noise.
    #>
    param([double[]]$History)

    if (-not $History -or $History.Count -eq 0) { return 1.2 }
    $sorted = @($History | Sort-Object)
    $median = $sorted[[int][math]::Floor($sorted.Count / 2)]
    return [math]::Round([math]::Max(0.8, $median * 1.4), 2)
}

# Functions above stay testable: dot-sourcing defines them without touching the game.
if ($MyInvocation.InvocationName -eq '.') { return }

# --- preflight ---------------------------------------------------------------
if (-not (Test-Path -LiteralPath $inputTool)) { Write-Error "Input driver missing: $inputTool"; exit 20 }
if (-not (Test-Path -LiteralPath $classifier)) { Write-Error "Frame classifier missing: $classifier"; exit 20 }

$blockPresent = Test-PublisherBlock -Path $HostsPath
if (-not $blockPresent -and -not $SkipBlockCheck) {
    Write-Error 'Publisher block is not present in the hosts file; refusing to run as an offline run.'
    exit 20
}

& $PythonPath -c 'import PIL' 2>$null
if ($LASTEXITCODE -ne 0) { Write-Error "Python with Pillow is required for frame classification ($PythonPath)"; exit 22 }

if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path (Split-Path -Parent $PSScriptRoot) ('tools/scratch/runs/' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}
$eventsPath = Join-Path $OutputDirectory 'events.jsonl'
$framePath = Join-Path $OutputDirectory 'current.png'
$previousPath = Join-Path $OutputDirectory 'previous.png'

$eventCount = 0
function Write-Event {
    param([Parameter(Mandatory)][hashtable]$Event)

    $script:eventCount++
    $Event['n'] = $script:eventCount
    $Event['at'] = (Get-Date).ToString('HH:mm:ss.fff')
    ($Event | ConvertTo-Json -Compress) | Add-Content -LiteralPath $eventsPath -Encoding UTF8
}

$started = Get-Date
if ($OwnerPid -eq 0) {
    $running = Get-Process -Name 'WalkingDead101' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($running) { $OwnerPid = $running.Id }
}
if ($OwnerPid -eq 0) {
    if (-not $Launch) { Write-Error 'No game process, and -Launch was not given.'; exit 21 }
    Start-Process 'steam://rungameid/207610'
    $OwnerPid = Wait-GameWindow -TimeoutSeconds 150
    if ($OwnerPid -eq 0) { Write-Error 'Game window did not appear within 150 s.'; exit 21 }
}

$scale = Get-ClientScale -ProcessId $OwnerPid
if ($scale.Height -le 0) { Write-Error 'Could not read the game client size.'; exit 21 }

Write-Event @{ kind = 'start'; pid = $OwnerPid; episode = $Episode; client = @($scale.Width, $scale.Height); block = $blockPresent; hosts = $HostsPath }

function Invoke-VerifiedClick {
    <#
    .SYNOPSIS
        Clicks a point, then checks the frame moved; retries once with a nudge.
    #>
    param(
        [Parameter(Mandatory)][int[]]$Point,
        [Parameter(Mandatory)][string]$Label,
        [int]$Attempts = 4,
        [int]$RetryDelayMilliseconds = 2000
    )

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $before = Join-Path $script:OutputDirectory ("nav-$Label-before.png")
        $after = Join-Path $script:OutputDirectory ("nav-$Label-after.png")
        Get-GameFrame -Path $before -ProcessId $OwnerPid | Out-Null
        Invoke-GameAction -Arguments @('-Action', 'Click', '-X', $Point[0], '-Y', $Point[1]) -ProcessId $OwnerPid | Out-Null
        Start-Sleep -Milliseconds $RetryDelayMilliseconds
        Get-GameFrame -Path $after -ProcessId $OwnerPid | Out-Null
        $class = Get-FrameClassification -Current $after -Previous $before
        Write-Event @{ kind = 'nav'; step = $Label; attempt = $attempt; point = $Point; diff = $class.diff; changed = $class.changed }
        if ($class.diff -ge 1.0) { return $true }
    }
    return $false
}

# --- frontend navigation -----------------------------------------------------
Invoke-GameAction -Arguments @('-Action', 'Foreground') -ProcessId $OwnerPid | Out-Null

# A cold launch reaches its window seconds before the frontend finishes fading in, so give
# it a fixed head start and then let the verified clicks retry rather than clicking blind.
if ($Launch) {
    Start-Sleep -Seconds 20
    Write-Event @{ kind = 'nav'; step = 'settle'; seconds = 20 }
}
Invoke-VerifiedClick -Point $FrontendContinue -Label 'continue' | Out-Null
Invoke-VerifiedClick -Point $FrontendPlay -Label 'play' | Out-Null
Invoke-VerifiedClick -Point $SlotRow -Label 'slot' | Out-Null
Invoke-VerifiedClick -Point $BottomBar -Label 'slot-play' | Out-Null

# Saturate at the last episode page, then step back to the target: independent of which
# episode the save slot happened to be showing.
$previousFrame = Join-Path $OutputDirectory 'clamp-a.png'
$currentFrame = Join-Path $OutputDirectory 'clamp-b.png'
Get-GameFrame -Path $previousFrame -ProcessId $OwnerPid | Out-Null
$clamped = $false
for ($i = 1; $i -le 8; $i++) {
    Invoke-GameAction -Arguments @('-Action', 'Click', '-X', $ArrowRight[0], '-Y', $ArrowRight[1]) -ProcessId $OwnerPid | Out-Null
    Start-Sleep -Milliseconds 800
    Get-GameFrame -Path $currentFrame -ProcessId $OwnerPid | Out-Null
    $class = Get-FrameClassification -Current $currentFrame -Previous $previousFrame
    Write-Event @{ kind = 'nav'; step = 'arrow-right'; iteration = $i; diff = $class.diff }
    if ($class.diff -lt 0.6) { $clamped = $true; break }
    Copy-Item -LiteralPath $currentFrame -Destination $previousFrame -Force
}
Write-Event @{ kind = 'nav'; step = 'clamped'; reached = $clamped; at_iteration = $i }

$stepsBack = 5 - $Episode
for ($i = 1; $i -le $stepsBack; $i++) {
    Invoke-GameAction -Arguments @('-Action', 'Click', '-X', $ArrowLeft[0], '-Y', $ArrowLeft[1]) -ProcessId $OwnerPid | Out-Null
    Start-Sleep -Milliseconds 700
}
$pageFrame = Join-Path $OutputDirectory 'episode-page.png'
Get-GameFrame -Path $pageFrame -ProcessId $OwnerPid | Out-Null
Write-Event @{ kind = 'nav'; step = 'episode-page'; steps_back = $stepsBack; frame = $pageFrame }

Invoke-VerifiedClick -Point $BottomBar -Label 'episode-play' | Out-Null
Invoke-VerifiedClick -Point $DialogYes -Label 'generate-yes' | Out-Null

# --- observation loop --------------------------------------------------------
$budgetEnds = (Get-Date).AddMinutes($Minutes)
$history = New-Object System.Collections.Generic.List[double]
$ladderIndex = 0
$staticStreak = 0
$choiceCommitted = $false
$cycle = 0
$lastConnSample = -1
$conns = 0

Get-GameFrame -Path $previousPath -ProcessId $OwnerPid | Out-Null

while ((Get-Date) -lt $budgetEnds -and -not $choiceCommitted) {
    $cycle++
    Get-GameFrame -Path $framePath -ProcessId $OwnerPid | Out-Null
    $class = Get-FrameClassification -Current $framePath -Previous $previousPath
    $diff = [double]$class.diff
    $threshold = Get-StaticThreshold -History $history.ToArray()
    $static = $diff -le $threshold

    if ($cycle % 5 -eq 0) {
        $conns = Get-RemoteConnectionCount -ProcessId $OwnerPid
        $lastConnSample = $cycle
    }

    Write-Event @{
        kind = 'frame'; cycle = $cycle; diff = $diff; static = $static; threshold = $threshold
        choice_lines = $class.choice_lines; subtitle_rows = $class.subtitle_rows
        conns = $conns; conns_cycle = $lastConnSample
    }

    # Keep a sparse record of the run for review, plus every frame that mattered.
    if ($cycle % 20 -eq 0) {
        Copy-Item -LiteralPath $framePath -Destination (Join-Path $OutputDirectory ('seq-{0:d4}.png' -f $cycle)) -Force
    }

    if ($class.choice_lines -ge 2) {
        $evidence = Join-Path $OutputDirectory ('choice-{0:d4}-before.png' -f $cycle)
        Copy-Item -LiteralPath $framePath -Destination $evidence -Force
        Write-Event @{ kind = 'choice-detected'; cycle = $cycle; lines = $class.choice_lines; line_ys = $class.line_ys; frame = $evidence }

        $classifierHeight = 0
        $image = & $PythonPath -c "from PIL import Image;import sys;i=Image.open(sys.argv[1]);print(i.height)" $framePath
        if ($image) { $classifierHeight = [int]$image }
        $ratio = if ($classifierHeight -gt 0) { [double]$scale.Height / $classifierHeight } else { 1.0 }

        foreach ($lineY in $class.line_ys) {
            $clientY = [int][math]::Round($lineY * $ratio)
            $clientY = [math]::Min([math]::Max($clientY, 120), $scale.Height - 60)
            Invoke-GameAction -Arguments @('-Action', 'Click', '-X', 760, '-Y', $clientY) -ProcessId $OwnerPid | Out-Null
            Start-Sleep -Milliseconds 500
            Get-GameFrame -Path $framePath -ProcessId $OwnerPid | Out-Null
            $check = Get-FrameClassification -Current $framePath
            Write-Event @{ kind = 'choice-click'; cycle = $cycle; client_y = $clientY; remaining_lines = $check.choice_lines }
            if ($check.choice_lines -lt 2) {
                $choiceCommitted = $true
                $after = Join-Path $OutputDirectory ('choice-{0:d4}-after.png' -f $cycle)
                Copy-Item -LiteralPath $framePath -Destination $after -Force
                Write-Event @{ kind = 'choice-committed'; cycle = $cycle; client_y = $clientY; frame = $after; conns = $conns; conns_cycle = $lastConnSample }
                break
            }
        }
    }
    elseif ($static) {
        $staticStreak++
        if ($staticStreak -ge 2) {
            $steps = @(
                @{ name = 'pointer-sweep'; actions = @(@('-Action', 'Look', '-X', 1000, '-Y', 480), @('-Action', 'Look', '-X', 700, '-Y', 620)) },
                @{ name = 'click-lower'; actions = @(@('-Action', 'Click', '-X', 960, '-Y', 700)) },
                @{ name = 'key-enter'; actions = @(@('-Action', 'Key', '-Key', 'ENTER')) },
                @{ name = 'hold-w'; actions = @(@('-Action', 'Hold', '-Key', 'W', '-Milliseconds', 700)) },
                @{ name = 'click-center'; actions = @(@('-Action', 'Click', '-X', 960, '-Y', 520)) },
                @{ name = 'key-space'; actions = @(@('-Action', 'Key', '-Key', 'SPACE')) },
                @{ name = 'pause-resume'; actions = @(@('-Action', 'Key', '-Key', 'ESC'), @('-Action', 'Click', '-X', $PauseResume[0], '-Y', $PauseResume[1])) }
            )
            $probe = $steps[$ladderIndex % $steps.Count]
            $ladderIndex++

            $probeBefore = Join-Path $OutputDirectory ('probe-{0:d4}-before.png' -f $cycle)
            $probeAfter = Join-Path $OutputDirectory ('probe-{0:d4}-after.png' -f $cycle)
            Copy-Item -LiteralPath $framePath -Destination $probeBefore -Force
            foreach ($action in $probe.actions) {
                Invoke-GameAction -Arguments $action -ProcessId $OwnerPid | Out-Null
            }
            Start-Sleep -Milliseconds 900
            Get-GameFrame -Path $probeAfter -ProcessId $OwnerPid | Out-Null
            $probeClass = Get-FrameClassification -Current $probeAfter -Previous $probeBefore
            $acknowledged = ([double]$probeClass.diff -gt [math]::Max(3.0, $threshold * 2))

            Write-Event @{
                kind = 'probe'; cycle = $cycle; probe = $probe.name; diff = $probeClass.diff
                acknowledged = $acknowledged; conns = $conns; conns_cycle = $lastConnSample
            }
            if ($acknowledged) {
                $staticStreak = 0
                Copy-Item -LiteralPath $probeAfter -Destination (Join-Path $OutputDirectory ('probe-{0:d4}-effective.png' -f $cycle)) -Force
            }
            Copy-Item -LiteralPath $probeAfter -Destination $previousPath -Force
            continue
        }
    }
    else {
        $staticStreak = 0
    }

    $history.Add($diff)
    if ($history.Count -gt 12) { $history.RemoveAt(0) }
    Copy-Item -LiteralPath $framePath -Destination $previousPath -Force
    Start-Sleep -Milliseconds 700
}

# --- verdict -----------------------------------------------------------------
$conns = Get-RemoteConnectionCount -ProcessId $OwnerPid
$summary = [pscustomobject]@{
    Kind = 'summary'
    Episode = $Episode
    StartedAt = $started.ToString('s')
    EndedAt = (Get-Date).ToString('s')
    Cycles = $cycle
    ChoiceCommitted = $choiceCommitted
    RemoteConnections = $conns
    BlockPresent = (Test-PublisherBlock -Path $HostsPath)
    OutputDirectory = $OutputDirectory
    Pid = $OwnerPid
}
$summary | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDirectory 'summary.json') -Encoding UTF8
$summary | Format-List

if ($choiceCommitted) { exit 0 }
exit 30

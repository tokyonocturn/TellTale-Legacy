#Requires -Version 5.1
<#
.SYNOPSIS
    Launches the game under observation and records a structured session log.

.DESCRIPTION
    Starts the game through its normal executable (Steam DRM intact), samples the
    process tree, window state and network endpoints, snapshots the per-user save
    and preference directories before and after, and writes a JSON evidence file.

    The tool never patches, injects into, or modifies the game. It refuses to run
    if an instance of the game is already running, so an existing user session is
    never disturbed.

.PARAMETER GameRoot
    Installation directory.

.PARAMETER Executable
    Executable file name inside the installation.

.PARAMETER ObservationSeconds
    How long to observe. The game is normally left at the main menu.

.PARAMETER OutputPath
    JSON session log path. Defaults to docs/rea/data/sessions/<timestamp>.json

.PARAMETER Label
    Short label recorded in the log (for example "baseline-online").

.PARAMETER StopAtEnd
    Close the game when observation finishes. Without this the game is left running.

.PARAMETER Arguments
    Optional command line arguments passed unchanged to the executable.

.PARAMETER ViaSteam
    Launch through the Steam client (steam://rungameid/<appid>) instead of starting
    the executable directly. This is the supported route for Steam-DRM builds;
    a direct launch exits with code 53 after SteamAPI_RestartAppIfNecessary.

.PARAMETER SteamAppId
    Steam app id used with -ViaSteam.

.PARAMETER AttachProcessId
    Observe an already running instance instead of launching a new one. Used when a
    legitimate session was started outside the tool.
#>
[CmdletBinding()]
param(
    [string]$GameRoot = 'C:\Program Files (x86)\Steam\steamapps\common\The Walking Dead',
    [string]$Executable = 'WalkingDead101.exe',
    [int]$ObservationSeconds = 45,
    [string]$OutputPath,
    [string]$Label = 'session',
    [switch]$StopAtEnd,
    [string[]]$Arguments = @(),
    [switch]$ViaSteam,
    [string]$SteamAppId = '207610',
    [int]$AttachProcessId = 0
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$GameRoot = (Resolve-Path -LiteralPath $GameRoot).ProviderPath
$exePath = Join-Path $GameRoot $Executable
if (-not (Test-Path -LiteralPath $exePath)) { throw "Executable not found: $exePath" }
if (-not $OutputPath) {
    $OutputPath = Join-Path $repoRoot ("docs\rea\data\sessions\{0}-{1}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $Label)
}

$saveRoot = Join-Path $env:USERPROFILE 'Documents\Telltale Games'
$processName = [System.IO.Path]::GetFileNameWithoutExtension($Executable)

if ($AttachProcessId -ne 0) {
    $attached = Get-Process -Id $AttachProcessId -ErrorAction SilentlyContinue
    if (-not $attached) { throw "Attach target not running: PID $AttachProcessId" }
    if ($attached.ProcessName -ne $processName) { throw "Attach target is '$($attached.ProcessName)', expected '$processName'" }
} else {
    $already = Get-Process -Name $processName -ErrorAction SilentlyContinue
    if ($already) {
        throw "Refusing to start: $processName is already running (PID $($already.Id -join ', ')). Close it first or pass -AttachProcessId to observe it."
    }
}

function Get-DirectorySnapshot {
    param([string]$Root)
    if (-not (Test-Path -LiteralPath $Root)) {
        return [pscustomobject]@{ Exists = $false; Path = $Root; Files = @() }
    }
    $files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue |
        ForEach-Object {
            [pscustomobject]@{
                RelativePath = $_.FullName.Substring($Root.Length).TrimStart('\')
                SizeBytes    = $_.Length
                LastWriteUtc = $_.LastWriteTimeUtc.ToString('u')
            }
        })
    [pscustomobject]@{ Exists = $true; Path = $Root; Files = $files }
}

function Get-EndpointSnapshot {
    param([int[]]$ProcessIds)
    $result = @()
    if (-not $ProcessIds -or $ProcessIds.Count -eq 0) { return $result }
    $lines = & netstat.exe -ano
    foreach ($line in $lines) {
        if ($line -notmatch '^\s*(TCP|UDP)\s+(\S+)\s+(\S+)\s+(\S+)?\s*(\d+)\s*$') { continue }
        $pidFromLine = [int]$Matches[5]
        if ($ProcessIds -notcontains $pidFromLine) { continue }
        $result += [pscustomobject]@{
            Protocol    = $Matches[1]
            Local       = $Matches[2]
            Remote      = $Matches[3]
            State       = if ($Matches[4]) { $Matches[4] } else { '' }
            ProcessId   = $pidFromLine
        }
    }
    $result
}

function Get-TreeIds {
    param([int]$RootId)
    $ids = New-Object System.Collections.Generic.List[int]
    $ids.Add($RootId)
    $queue = New-Object System.Collections.Generic.Queue[int]
    $queue.Enqueue($RootId)
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        foreach ($child in (Get-CimInstance Win32_Process -Filter "ParentProcessId = $current" -ErrorAction SilentlyContinue)) {
            if (-not $ids.Contains([int]$child.ProcessId)) {
                $ids.Add([int]$child.ProcessId)
                $queue.Enqueue([int]$child.ProcessId)
            }
        }
    }
    $ids.ToArray()
}

function Get-LoadedModules {
    param([int]$ProcessId)
    try {
        @(Get-Process -Id $ProcessId -ErrorAction Stop).Modules |
            ForEach-Object { [pscustomobject]@{ Name = $_.ModuleName; Path = $_.FileName } }
    } catch {
        @()
    }
}

$startedUtc = (Get-Date).ToUniversalTime()
$steamBefore = @(Get-Process -Name steam -ErrorAction SilentlyContinue).Count -gt 0
$saveBefore = Get-DirectorySnapshot -Root $saveRoot

$launchMode = if ($AttachProcessId -ne 0) { 'attach' } elseif ($ViaSteam) { 'steam' } else { 'direct' }
Write-Host ("Starting {0} (observed for {1}s, launch={2}) ..." -f $exePath, $ObservationSeconds, $launchMode)
$rootProcess = $null

if ($AttachProcessId -ne 0) {
    $rootProcess = Get-Process -Id $AttachProcessId
} elseif ($ViaSteam) {
    Start-Process -FilePath ("steam://rungameid/{0}" -f $SteamAppId)
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline -and -not $rootProcess) {
        Start-Sleep -Milliseconds 500
        $candidate = @(Get-Process -Name $processName -ErrorAction SilentlyContinue)
        if ($candidate.Count -gt 0) { $rootProcess = $candidate[0] }
    }
    if (-not $rootProcess) {
        throw "Steam did not start $processName within 120s. Check that Steam is signed in and the app is installed."
    }
} else {
    $rootProcess = if ($Arguments.Count -gt 0) {
        Start-Process -FilePath $exePath -WorkingDirectory $GameRoot -ArgumentList $Arguments -PassThru
    } else {
        Start-Process -FilePath $exePath -WorkingDirectory $GameRoot -PassThru
    }
}

$samples = New-Object System.Collections.Generic.List[object]
$allModules = @()
$seenIds = New-Object System.Collections.Generic.List[int]
$network = @()
$exitCode = $null
$stopReason = 'observed'

try {
    $elapsed = 0
    while ($elapsed -lt $ObservationSeconds) {
        Start-Sleep -Milliseconds 2000
        $elapsed += 2

        $ids = Get-TreeIds -RootId $rootProcess.Id
        foreach ($id in $ids) { if (-not $seenIds.Contains($id)) { $seenIds.Add($id) } }

        $live = @(Get-Process -Id $ids -ErrorAction SilentlyContinue)
        foreach ($p in $live) {
            $samples.Add([pscustomobject]@{
                ElapsedSeconds = $elapsed
                ProcessId      = $p.Id
                ProcessName    = $p.ProcessName
                WindowTitle    = $p.MainWindowTitle
                Responding     = $p.Responding
                WorkingSetMB   = [Math]::Round($p.WorkingSet64 / 1MB, 1)
                CpuSeconds     = [Math]::Round($p.CPU, 2)
                Threads        = $p.Threads.Count
                Handles        = $p.HandleCount
            })
        }

        $network += Get-EndpointSnapshot -ProcessIds $ids

        if ($live.Count -eq 0) {
            $stopReason = 'exited'
            break
        }
    }

    $allModules = Get-LoadedModules -ProcessId $rootProcess.Id

    if ($stopReason -ne 'exited') {
        $proc = Get-Process -Id $rootProcess.Id -ErrorAction SilentlyContinue
        if ($proc) {
            if ($StopAtEnd) {
                $closed = $proc.CloseMainWindow()
                if ($closed) { $proc.WaitForExit(15000) | Out-Null }
                if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
                $stopReason = 'closed-by-tool'
            } else {
                $stopReason = 'left-running'
            }
        }
        if ($proc) { $proc.Refresh(); if ($proc.HasExited) { $exitCode = $proc.ExitCode } }
    } else {
        $rootProcess.Refresh()
        if ($rootProcess.HasExited) { $exitCode = $rootProcess.ExitCode }
    }
}
finally {
    $finishedUtc = (Get-Date).ToUniversalTime()
}

$saveAfter = Get-DirectorySnapshot -Root $saveRoot

$uniqueWindowTitles = @($samples | Where-Object { $_.WindowTitle } | ForEach-Object { $_.WindowTitle } | Select-Object -Unique)
$remoteEndpoints = @($network | Where-Object { $_.Remote -and $_.Remote -notmatch '^(0\.0\.0\.0|\*|127\.0\.0\.1|\[::\]|\[::1\])' } |
    ForEach-Object { $_.Remote } | Select-Object -Unique)

$document = [ordered]@{
    SchemaVersion    = 1
    Label            = $Label
    StartedUtc       = $startedUtc.ToString('u')
    FinishedUtc      = $finishedUtc.ToString('u')
    ObservationSeconds = $ObservationSeconds
    GameRoot         = $GameRoot
    Executable       = $Executable
    ExecutableSha256 = (Get-FileHash -LiteralPath $exePath -Algorithm SHA256).Hash
    SteamRunningBefore = $steamBefore
    LaunchMode       = $launchMode
    StartedProcessId = $rootProcess.Id
    ProcessIdsSeen   = $seenIds.ToArray()
    StopReason       = $stopReason
    ExitCode         = $exitCode
    WindowTitles     = $uniqueWindowTitles
    LoadedModules    = $allModules
    NetworkEndpoints = @($network | Sort-Object Protocol, Local -Unique)
    RemoteEndpoints  = $remoteEndpoints
    SaveRootBefore   = $saveBefore
    SaveRootAfter    = $saveAfter
    Samples          = $samples.ToArray()
}

$outDir = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
[System.IO.File]::WriteAllText($OutputPath, ($document | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))

Write-Host ''
Write-Host ("Processes seen : {0}" -f ($seenIds.ToArray() -join ', '))
Write-Host ("Window titles  : {0}" -f ($(if ($uniqueWindowTitles.Count) { $uniqueWindowTitles -join ' | ' } else { '(none)' })))
Write-Host ("Remote network : {0}" -f ($(if ($remoteEndpoints.Count) { $remoteEndpoints -join ', ' } else { '(none observed)' })))
Write-Host ("Save dir       : before={0} after={1}" -f $saveBefore.Exists, $saveAfter.Exists)
Write-Host ("Stop reason    : {0}" -f $stopReason)
Write-Host ("Log written    : {0}" -f $OutputPath)

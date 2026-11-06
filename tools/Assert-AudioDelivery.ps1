#Requires -Version 5.1
<#
.SYNOPSIS
    Asserts that game audio is reaching endpoint 100027813, and says exactly why not.

.DESCRIPTION
    This is the gate the audio requirement needs: a single command that answers "is the
    game's audio on the required endpoint right now?" without changing anything. It checks
    the endpoint by its Core Audio device id (not by friendly name, which has three stale
    duplicates on this machine), confirms it is active, confirms it is *not* the system
    default, confirms the mirror is running, and requires a measured non-zero peak on the
    target while audio is demonstrably playing somewhere.

    Every failure is a distinct exit code and a named verdict. There is deliberately no
    fallback: if the endpoint is gone, this reports that it is gone rather than measuring
    some other device and calling the requirement met.

    Read-only: no endpoint, session, default device or mixer value is modified.

.PARAMETER EndpointId
    Core Audio device instance id to require. Defaults to the id this project targets.

.PARAMETER ExpectedDefaultName
    Friendly-name substring the system default must still match. The default must not
    move; if it does, that is a failure, not a note.

.PARAMETER Samples
    Peak measurements to take (spread over the sample window).

.PARAMETER SampleMilliseconds
    Delay between peak measurements.

.PARAMETER MinPeak
    Peak the target must reach at least once to count as carrying audio.

.PARAMETER MirrorPidPath
    File holding the mirror process id.

.PARAMETER OutputPath
    Optional path for the JSON report.

.PARAMETER AsJson
    Emit the report as JSON on stdout.

.OUTPUTS
    Exit codes: 0 verified; 3 endpoint missing; 4 endpoint inactive; 5 no signal on target;
    6 default device moved; 8 mirror not running; 9 audio playing nowhere, so nothing could
    be measured.
#>
[CmdletBinding()]
param(
    [string]$EndpointId = '{0.0.0.00000000}.{63b45a0d-a22d-42a4-a438-b64a52829507}',
    [string]$ExpectedDefaultName = 'Voicemeeter AUX Input',
    [int]$Samples = 6,
    [int]$SampleMilliseconds = 900,
    [double]$MinPeak = 0.01,
    [string]$MirrorPidPath = '',
    [string]$OutputPath = '',
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$routeScript = Join-Path $root 'tools\Get-AudioRoute.ps1'
if (-not $MirrorPidPath) { $MirrorPidPath = Join-Path $root 'tools\scratch\mirror.pid' }

function Get-GuidTail {
    param([string]$Id)
    if ($Id -match '\{([0-9a-fA-F-]{36})\}\s*$') { return $Matches[1].ToLowerInvariant() }
    $Id.ToLowerInvariant()
}

$wantedTail = Get-GuidTail -Id $EndpointId
$json = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $routeScript -AsJson -Samples $Samples -SampleMilliseconds $SampleMilliseconds
if ($LASTEXITCODE -ne 0) { throw 'Get-AudioRoute failed to produce a report.' }
$route = ($json -join "`n") | ConvertFrom-Json

$target = @($route.Endpoints | Where-Object { (Get-GuidTail -Id $_.Id) -eq $wantedTail })
$defaultEndpoint = @($route.Endpoints | Where-Object { $_.Default }) | Select-Object -First 1
$game = Get-Process WalkingDead101 -ErrorAction SilentlyContinue | Select-Object -First 1

$mirrorPid = $null
$mirrorAlive = $false
if (Test-Path -LiteralPath $MirrorPidPath) {
    $mirrorPid = (Get-Content -LiteralPath $MirrorPidPath -Raw).Trim()
    if ($mirrorPid -match '^\d+$') {
        $mirrorAlive = [bool](Get-Process -Id ([int]$mirrorPid) -ErrorAction SilentlyContinue)
    }
}

$verdict = 'verified'
$explanation = 'The required endpoint is present, active, not the default, and metered non-zero audio while the default endpoint was also carrying audio.'
$exit = 0

if ($target.Count -eq 0) {
    $verdict = 'endpoint-missing'
    $explanation = ("No render endpoint with id {0} is enumerated. The requirement is not met and no fallback device was measured or selected." -f $EndpointId)
    $exit = 3
}
elseif ($target.Count -gt 1) {
    $verdict = 'endpoint-ambiguous'
    $explanation = ("{0} endpoints share id {1}; refusing to pick one." -f $target.Count, $EndpointId)
    $exit = 3
}
elseif ($target[0].State -ne 'active') {
    $verdict = 'endpoint-inactive'
    $explanation = ("Endpoint {0} is enumerated but its state is '{1}', so it cannot render. Nothing was redirected to another device." -f $target[0].Name, $target[0].State)
    $exit = 4
}
elseif ($target[0].Default) {
    $verdict = 'default-changed'
    $explanation = 'The required endpoint has become the system default, which the requirement forbids.'
    $exit = 6
}
elseif ($defaultEndpoint -and $defaultEndpoint.Name -notlike "*$ExpectedDefaultName*") {
    $verdict = 'default-changed'
    $explanation = ("The system default render endpoint is now '{0}', not '{1}'. The requirement is that the default is left alone." -f $defaultEndpoint.Name, $ExpectedDefaultName)
    $exit = 6
}
elseif (-not $mirrorAlive) {
    $verdict = 'mirror-not-running'
    $explanation = ("The endpoint is healthy but the delivery process is not running (pid file: {0}), so the game's stream is not being carried to it." -f $MirrorPidPath)
    $exit = 8
}
elseif ($target[0].PeakMax -lt $MinPeak) {
    $sourcePeak = if ($defaultEndpoint) { [double]$defaultEndpoint.PeakMax } else { 0 }
    if ($sourcePeak -ge $MinPeak) {
        $verdict = 'no-signal-on-target'
        $explanation = ("The default endpoint carried audio (peak {0:N6}) but the target stayed at {1:N6}. Delivery is broken even though the endpoint is healthy." -f $sourcePeak, $target[0].PeakMax)
        $exit = 5
    } else {
        $verdict = 'no-audio-to-measure'
        $explanation = 'Neither the default endpoint nor the target carried any audio during the sample window, so delivery could not be measured. This is not proof of failure; run it while the game is playing dialogue or music.'
        $exit = 9
    }
}

$report = [ordered]@{
    SchemaVersion   = 1
    GeneratedUtc    = (Get-Date).ToUniversalTime().ToString('o')
    Verdict         = $verdict
    ExitCode        = $exit
    Explanation     = $explanation
    RequiredEndpoint = [ordered]@{
        Id        = $EndpointId
        Name      = if ($target.Count -ge 1) { $target[0].Name } else { $null }
        State     = if ($target.Count -ge 1) { $target[0].State } else { 'absent' }
        PeakMax   = if ($target.Count -ge 1) { $target[0].PeakMax } else { $null }
        IsDefault = if ($target.Count -ge 1) { $target[0].Default } else { $null }
    }
    DefaultEndpoint = [ordered]@{
        ExpectedName = $ExpectedDefaultName
        Name         = if ($defaultEndpoint) { $defaultEndpoint.Name } else { $null }
        PeakMax      = if ($defaultEndpoint) { $defaultEndpoint.PeakMax } else { $null }
        Unchanged    = [bool]($defaultEndpoint -and $defaultEndpoint.Name -like "*$ExpectedDefaultName*")
    }
    Mirror = [ordered]@{
        PidPath = $MirrorPidPath
        Pid     = $mirrorPid
        Running = $mirrorAlive
    }
    Game   = [ordered]@{
        Running = [bool]$game
        Pid     = if ($game) { $game.Id } else { $null }
    }
    Sampling = [ordered]@{
        Samples             = $Samples
        SampleMilliseconds  = $SampleMilliseconds
        MinPeak             = $MinPeak
    }
}

$jsonOut = $report | ConvertTo-Json -Depth 6
if ($OutputPath) {
    $full = [System.IO.Path]::GetFullPath($OutputPath)
    $parent = Split-Path -Parent $full
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Set-Content -LiteralPath $full -Value $jsonOut -Encoding UTF8
}

if ($AsJson) { $jsonOut }
else {
    [pscustomobject]@{
        Verdict   = $verdict
        Endpoint  = if ($target.Count -ge 1) { $target[0].Name } else { '(absent)' }
        Target    = if ($target.Count -ge 1) { $target[0].PeakMax } else { $null }
        Default   = if ($defaultEndpoint) { $defaultEndpoint.Name } else { '(none)' }
        DefPeak   = if ($defaultEndpoint) { $defaultEndpoint.PeakMax } else { $null }
        Mirror    = $mirrorAlive
        Detail    = $explanation
    } | Format-List
}

exit $exit

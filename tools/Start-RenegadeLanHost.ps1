#Requires -Version 5.1
<#
.SYNOPSIS
    Starts the shipped Renegade dedicated server in LAN mode, without touching the
    game installation.

.DESCRIPTION
    Builds a self-contained host directory under %LOCALAPPDATA%\GamePreservation\
    renegade-lan containing:
      * a generated Server.ini with GameType = LAN (no WOL account, no serial),
      * a generated svrcfg_lan.ini game-settings file,
      * copies of RenegadeServer.exe and Server.dat,
      * a junction named Data that points at the installation's own Data folder.

    The junction is how the server sees the game's maps without a multi-gigabyte
    copy and without writing anything into the installation. It is removed with
    'rmdir' (never a recursive delete) so the real Data folder cannot be touched.

    The server is started, its UDP endpoints are sampled, and the result is
    recorded as host.json. -Status and -Stop act on that record.

    Exit codes:
      0  host started and at least one UDP endpoint was observed
      2  refused or failed to start (hash mismatch, missing files, bad state)
      3  process started but no UDP endpoint was observed in the window
      4  a host is already running

.PARAMETER GameId
    Registry id. Defaults to the Renegade profile.

.PARAMETER Port
    UDP game port. 0 lets the server choose.

.PARAMETER ObserveSeconds
    How long to sample the server's UDP endpoints.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\Start-RenegadeLanHost.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\Start-RenegadeLanHost.ps1 -Status
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\Start-RenegadeLanHost.ps1 -Stop
#>
[CmdletBinding()]
param(
    [string]$GameId = 'cnc-renegade-steam-2229890',
    [int]$Port = 0,
    [string]$MapName = 'C&C_Field.mix',
    [int]$TimeLimitMinutes = 30,
    [int]$ObserveSeconds = 10,
    [string]$StatePath,
    [string]$InstallRoot,
    [switch]$SkipHashCheck,
    [switch]$Status,
    [switch]$Stop
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Preservation.Common.psm1') -Force

if ($Status -and $Stop) { throw 'Pass either -Status or -Stop, not both.' }

if ($Status) {
    $status = Get-RenegadeLanHostStatus -StatePath $StatePath
    if (-not $status.State) {
        Write-Host ("LAN host: not running (no state at {0})" -f $status.StatePath)
        exit 0
    }
    Write-Host ("LAN host : {0}" -f $(if ($status.Running) { 'running' } else { 'stopped' }))
    Write-Host ("game     : {0}" -f $status.State.gameId)
    Write-Host ("pid      : {0}" -f $status.State.processId)
    Write-Host ("mode     : {0}" -f $status.State.mode)
    Write-Host ("started  : {0}" -f $status.State.startedUtc)
    Write-Host ("state    : {0}" -f $status.StatePath)
    foreach ($endpoint in @($status.Endpoints)) { Write-Host ("udp      : {0}" -f $endpoint) }
    if ($status.Running) { exit 0 }
    Write-Host 'The recorded process has exited; run -Stop to clean up the host directory.'
    exit 0
}

if ($Stop) {
    $result = Stop-RenegadeLanHost -StatePath $StatePath
    if (-not $result.Stopped) {
        Write-Host ("Nothing to stop: {0} ({1})" -f $result.Reason, $result.StatePath)
        exit 0
    }
    Write-Host ("Stopped pid {0}; host directory removed: {1}" -f $result.ProcessId, $result.HostRemoved)
    Write-Host ("Evidence kept under {0} (last-run-*.log)" -f $result.StatePath)
    exit 0
}

try {
    $state = Start-RenegadeLanHost -GameId $GameId -Port $Port -MapName $MapName -TimeLimitMinutes $TimeLimitMinutes `
        -StatePath $StatePath -ObserveSeconds $ObserveSeconds -SkipHashCheck:$SkipHashCheck -InstallRoot $InstallRoot
} catch {
    $message = $_.Exception.Message
    if ($message -match 'already running') {
        Write-Host $message
        exit 4
    }
    Write-Host ("Refused: {0}" -f $message)
    exit 2
}

Write-Host ("LAN host started for {0}" -f $state.gameId)
Write-Host ("  mode      : LAN (no Westwood Online login, no serial)")
Write-Host ("  pid       : {0}" -f $state.processId)
Write-Host ("  host dir  : {0}" -f $state.hostDirectory)
Write-Host ("  Server.ini: {0}" -f $state.serverIni)
Write-Host ("  Data      : junction -> {0}" -f $state.junctionTarget)
Write-Host ("  hash check: {0}" -f $(if ($state.hashVerified) { 'matched profile' } else { 'skipped' }))

foreach ($endpoint in @($state.endpoints)) { Write-Host ("  udp       : {0}" -f $endpoint) }
if ($state.windowTitle) { Write-Host ("  window    : {0}" -f $state.windowTitle) }
foreach ($line in @($state.logs.lines | Select-Object -First 12)) { Write-Host ("  log       : {0}" -f $line) }

if ($state.exited) {
    Write-Host ("Server exited immediately with code {0}; see {1}" -f $state.exitCode, $state.logs.stderr)
    exit 2
}
if (@($state.endpoints).Count -eq 0) {
    Write-Host 'The process is alive but no UDP endpoint was observed; the server may still be loading.'
    exit 3
}
Write-Host 'The host is listening. It is not LAN VERIFIED until a second client joins and plays.'
exit 0

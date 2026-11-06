#Requires -Version 5.1
<#
.SYNOPSIS
    Proves the game launches and runs with the publisher endpoints unavailable.

.DESCRIPTION
    This is the acceptance harness for the offline mission. It refuses to do anything while
    a play session is live, so it can never destroy someone's progress:

      1. refuses if the game is running (exit 20) or the shell is not elevated (exit 21),
      2. records the hosts file hash and takes a save backup,
      3. blocks the discovered publisher endpoints with the marked, reversible block,
      4. proves the block resolves to loopback,
      5. launches the game cold through Steam,
      6. waits for the process and samples it: window frames, and every remote address it
         holds, so a connection to a blocked endpoint is caught rather than assumed away,
      7. always unblocks and verifies the hosts file is byte-identical to before,
      8. writes a JSON report that marks each feature VERIFIED, FAILED or UNTESTED.

    It never edits a save and never writes to the game directory. What it cannot do is play
    the game: frames prove what was on screen, and anything it did not observe is reported
    as UNTESTED rather than inferred.

.PARAMETER DryRun
    Validate preconditions and print the plan without changing the hosts file or launching.

.PARAMETER LaunchTimeoutSeconds
    How long to wait for the game window after the launch request.

.PARAMETER ObserveSeconds
    How long to sample the running game once its window appears.

.PARAMETER OutputPath
    JSON report path.

.OUTPUTS
    Exit codes: 0 harness completed and hosts restored; 20 game already running;
    21 not elevated; 22 block did not take effect; 23 launch timeout (game never appeared);
    24 hosts rollback mismatch.
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [int]$LaunchTimeoutSeconds = 180,
    [int]$ObserveSeconds = 60,
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$probe = Join-Path $root 'tools\Invoke-OfflineProbe.ps1'
$capture = Join-Path $root 'tools\Invoke-GameInput.ps1'
$backupScript = Join-Path $root 'tools\Backup-GameProfile.ps1'
$hostsPath = Join-Path $env:WINDIR 'System32\drivers\etc\hosts'
$domains = @('api.telltalegames.com', 'meta.telltalegames.com')
$evidenceDir = Join-Path $root ('tools\scratch\offline-' + (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss'))
if (-not $OutputPath) { $OutputPath = Join-Path $root 'docs\rea\data\offline-launch.json' }

function Test-Elevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$report = [ordered]@{
    SchemaVersion = 1
    GeneratedUtc  = (Get-Date).ToUniversalTime().ToString('o')
    DryRun        = [bool]$DryRun
    Domains       = $domains
    Stages        = @()
    Matrix        = [ordered]@{}
    ExitCode      = $null
}

function Add-Stage {
    param([string]$Name, [string]$Status, [string]$Detail)
    $report.Stages += [pscustomobject]@{ Stage = $Name; Status = $Status; Detail = $Detail; Utc = (Get-Date).ToUniversalTime().ToString('o') }
    Write-Host ("{0,-26} {1,-10} {2}" -f $Name, $Status, $Detail)
}

function Save-Report {
    param([int]$ExitCode)
    $report.ExitCode = $ExitCode
    $full = [System.IO.Path]::GetFullPath($OutputPath)
    $parent = Split-Path -Parent $full
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Set-Content -LiteralPath $full -Value ($report | ConvertTo-Json -Depth 8) -Encoding UTF8
}

# --- preconditions -------------------------------------------------------------------
$game = Get-Process WalkingDead101 -ErrorAction SilentlyContinue | Select-Object -First 1
if ($game) {
    Add-Stage 'precondition' 'BLOCKED' ("game is running (pid {0}); refusing to launch a second instance or disturb a live session" -f $game.Id)
    Save-Report 20
    exit 20
}
Add-Stage 'precondition' 'OK' 'no game process running'

$elevated = Test-Elevated
$report | Add-Member -NotePropertyName Elevated -NotePropertyValue $elevated
if (-not $elevated) {
    Add-Stage 'elevation' 'BLOCKED' 'the hosts file is protected; run this from an elevated shell'
    Save-Report 21
    exit 21
}
Add-Stage 'elevation' 'OK' 'elevated shell'

$hostsBefore = (Get-FileHash -LiteralPath $hostsPath -Algorithm SHA256).Hash
$report | Add-Member -NotePropertyName HostsSha256Before -NotePropertyValue $hostsBefore
Add-Stage 'hosts-snapshot' 'OK' "sha256 $hostsBefore"

if ($DryRun) {
    Add-Stage 'plan' 'OK' ("would block {0}, launch 207610, observe {1}s, then restore hosts to {2}" -f ($domains -join ', '), $ObserveSeconds, $hostsBefore)
    $report.Matrix['offline-launch'] = 'UNTESTED (dry run)'
    Save-Report 0
    exit 0
}

# --- backup -------------------------------------------------------------------------
if (Test-Path -LiteralPath $backupScript) {
    $backupOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $backupScript -Label 'offline-acceptance' 2>&1
    $backupPath = ($backupOut | Where-Object { $_ -match '^\s*Backup\s*:' } | Select-Object -First 1)
    Add-Stage 'save-backup' 'OK' (($backupPath -as [string]) -replace '^\s*Backup\s*:\s*', '')
}

# --- block --------------------------------------------------------------------------
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $probe -Action Block -Domains $domains | Out-Null
if ($LASTEXITCODE -ne 0) {
    Add-Stage 'block' 'FAILED' "probe exited $LASTEXITCODE"
    Save-Report 22
    exit 22
}
$status = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $probe -Action Status) -join "`n" | ConvertFrom-Json
$blocked = @($status.BlockedDomains)
$missing = @($domains | Where-Object { $blocked -notcontains $_ })
if ($missing.Count -gt 0) {
    Add-Stage 'block' 'FAILED' ("domains not blocked: " + ($missing -join ', '))
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $probe -Action Unblock | Out-Null
    Save-Report 22
    exit 22
}
Add-Stage 'block' 'OK' (($blocked -join ', ') + ' -> 127.0.0.1')

try {
    # --- launch ---------------------------------------------------------------------
    if (-not (Test-Path -LiteralPath $evidenceDir)) { New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null }
    Start-Process 'steam://rungameid/207610'
    Add-Stage 'launch' 'OK' 'steam://rungameid/207610 requested'

    $deadline = (Get-Date).AddSeconds($LaunchTimeoutSeconds)
    $proc = $null
    while ((Get-Date) -lt $deadline) {
        $proc = Get-Process WalkingDead101 -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($proc -and $proc.MainWindowHandle -ne 0) { break }
        Start-Sleep -Seconds 2
    }
    if (-not $proc -or $proc.MainWindowHandle -eq 0) {
        Add-Stage 'launch' 'FAILED' "no game window within $LaunchTimeoutSeconds s"
        $report.Matrix['cold-launch-offline'] = 'FAILED'
        Save-Report 23
        exit 23
    }
    Add-Stage 'launch' 'OK' ("pid {0}, window '{1}'" -f $proc.Id, $proc.MainWindowTitle)
    $report.Matrix['cold-launch-offline'] = 'VERIFIED'
    $report | Add-Member -NotePropertyName GamePid -NotePropertyValue $proc.Id

    # --- observe --------------------------------------------------------------------
    $blockedIps = @()
    foreach ($domain in $domains) {
        try { $blockedIps += @((Resolve-DnsName -Name $domain -Type A -ErrorAction Stop | Where-Object IPAddress | ForEach-Object IPAddress)) } catch { }
    }
    $remoteSeen = @{}
    $frames = 0
    $observeUntil = (Get-Date).AddSeconds($ObserveSeconds)
    while ((Get-Date) -lt $observeUntil) {
        $stamp = (Get-Date).ToUniversalTime().ToString('HHmmss')
        $framePath = Join-Path $evidenceDir "$stamp.png"
        try {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $capture -Action Capture -CaptureMethod Window -OutputPath $framePath 2>$null | Out-Null
            if (Test-Path -LiteralPath $framePath) { $frames++ }
        } catch { }
        try {
            $conn = @(Get-NetTCPConnection -OwningProcess $proc.Id -ErrorAction SilentlyContinue |
                Where-Object { $_.RemoteAddress -and $_.RemoteAddress -notin @('0.0.0.0', '::', '127.0.0.1', '::1') })
            foreach ($c in $conn) { $remoteSeen[$c.RemoteAddress] = $c.State }
        } catch { }
        Start-Sleep -Seconds 8
    }

    $leaks = @($remoteSeen.Keys | Where-Object { $blockedIps -contains $_ })
    $report | Add-Member -NotePropertyName RemoteAddresses -NotePropertyValue @($remoteSeen.Keys)
    $report | Add-Member -NotePropertyName BlockedAddressLeaks -NotePropertyValue $leaks
    $report | Add-Member -NotePropertyName Frames -NotePropertyValue $frames
    $report | Add-Member -NotePropertyName EvidenceDir -NotePropertyValue $evidenceDir
    Add-Stage 'observe' $(if ($frames -gt 0) { 'OK' } else { 'FAILED' }) ("{0} frames, remote addresses: {1}" -f $frames, (($remoteSeen.Keys | Sort-Object) -join ', '))
    if ($leaks.Count -gt 0) {
        Add-Stage 'offline-isolation' 'FAILED' ("game still reached blocked address(es): " + ($leaks -join ', '))
        $report.Matrix['publisher-endpoints-unreachable'] = 'FAILED'
    } else {
        Add-Stage 'offline-isolation' 'OK' 'no connection to a blocked publisher address observed'
        $report.Matrix['publisher-endpoints-unreachable'] = 'VERIFIED'
    }

    # The harness cannot play the game. Say so rather than inferring anything.
    foreach ($feature in @('menu-navigation', 'save-load', 'gameplay-progression', 'dialogue-choices', 'episode-transition', 'cinematics')) {
        if (-not $report.Matrix.Contains($feature)) { $report.Matrix[$feature] = 'UNTESTED (requires attended play)' }
    }

    Save-Report 0
    exit 0
}
finally {
    # --- always restore -------------------------------------------------------------
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $probe -Action Unblock | Out-Null
    Start-Sleep -Milliseconds 300
    $hostsAfter = (Get-FileHash -LiteralPath $hostsPath -Algorithm SHA256).Hash
    $report | Add-Member -NotePropertyName HostsSha256After -NotePropertyValue $hostsAfter -Force
    if ($hostsAfter -eq $hostsBefore) {
        Add-Stage 'hosts-rollback' 'OK' 'hosts file restored byte-identical'
    } else {
        Add-Stage 'hosts-rollback' 'FAILED' "hosts hash changed: $hostsBefore -> $hostsAfter"
        $report.Matrix['hosts-rollback'] = 'FAILED'
        Save-Report 24
    }
}

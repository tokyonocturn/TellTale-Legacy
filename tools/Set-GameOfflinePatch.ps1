#Requires -Version 5.1
<#
.SYNOPSIS
    Applies, reports or reverts the offline launch patch for one game profile.

.DESCRIPTION
    The offline launch wait is the Steam client deciding it cannot reach a network that is
    not there, and it is measured and fixed once in docs/rea/19-offline-launch-stall.md.
    This script is the per-game entry point to that fix, because every other build in this
    project has its own executable, its own content layout and its own publisher endpoint,
    and a patch that silently applied to the wrong build would be worthless.

    Two reversible steps are involved, and both are delegated to tools that already own
    their mechanics:

      1. Steam Offline Mode: the documented WantsOfflineMode / SkipOfflineModeWarning values
         in config\loginusers.vdf, restored byte-for-byte on removal
         (tools/Set-SteamOfflineMode.ps1).
      2. The publisher endpoint pinned to loopback, so a startup call fails in microseconds
         instead of waiting out TCP retransmits, restored byte-for-byte on removal
         (tools/Set-OfflineLaunchPatch.ps1). Hostnames come from the profile, which records
         where they were found in the shipped executable.

    Before either step, the installed executable's SHA-256 is compared with the profile. A
    different build is refused rather than patched, so the profile's claims stay attached to
    the binary they were measured on.

    What this script cannot do is play the game. Whether the frontend becomes usable quickly
    is recorded per profile in offlinePatch.launchVerification, and it only says VERIFIED
    when someone measured it.

.PARAMETER Game
    Profile id, e.g. twd-s2-steam-261030. Resolved to profiles\<id>\profile.json.

.PARAMETER Action
    Status   report install, build match, endpoint pins and client mode. Read-only.
    Install  verify the build, enable Steam Offline Mode, pin the endpoints.
    Remove   unpin this game's endpoints and restore the client mode if no other game needs it.

.PARAMETER ProfilePath
    Explicit profile path instead of profiles\<Game>\profile.json.

.PARAMETER GameRoot
    Explicit install directory instead of the profile's installPaths. Used by tests.

.PARAMETER SkipSteamOfflineMode
    Leave the Steam client alone and only pin the endpoints.

.PARAMETER SkipRestart
    Do not restart Steam after changing its mode (tests, or callers that restart it).

.PARAMETER AsJson
    Emit Status as JSON.

.EXAMPLE
    .\tools\Set-GameOfflinePatch.ps1 -Game twd-s2-steam-261030 -Action Status
    .\tools\Set-GameOfflinePatch.ps1 -Game twd-s2-steam-261030 -Action Install   # elevated
    .\tools\Set-GameOfflinePatch.ps1 -Game twd-s2-steam-261030 -Action Remove    # elevated

.OUTPUTS
    0 done; 20 not elevated; 21 profile missing or invalid; 22 hosts step failed;
    23 install not found; 24 installed executable is not the build this patch targets;
    25 Steam mode step failed; 26 nothing recorded to remove.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$Game,
    [ValidateSet('Status', 'Install', 'Remove')][string]$Action = 'Status',
    [string]$ProfilePath = '',
    [string]$GameRoot = '',
    [string]$HostsPath = (Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'),
    [string]$ManifestPath = '',
    [string]$VdfPath = 'C:\Program Files (x86)\Steam\config\loginusers.vdf',
    [string]$VdfBackupPath = '',
    [string]$StateDirectory = '',
    [switch]$SkipSteamOfflineMode,
    [switch]$SkipRestart,
    [switch]$SkipDnsFlush,
    [switch]$SkipResolveCheck,
    [switch]$SkipElevationCheck,
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'

function Write-Failure {
    param([Parameter(Mandatory)][string]$Message)
    $host.UI.WriteErrorLine($Message)
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$steamSwitch = Join-Path $PSScriptRoot 'Set-SteamOfflineMode.ps1'
$hostsSwitch = Join-Path $PSScriptRoot 'Set-OfflineLaunchPatch.ps1'
if (-not $ManifestPath) { $ManifestPath = Join-Path $repoRoot 'backups/offline-launch-patch.json' }
if (-not $VdfBackupPath) { $VdfBackupPath = Join-Path $repoRoot 'backups/steam-loginusers-original.vdf' }
if (-not $StateDirectory) { $StateDirectory = Join-Path $repoRoot 'backups/game-patches' }
if (-not $ProfilePath) { $ProfilePath = Join-Path (Join-Path $repoRoot 'profiles') (Join-Path $Game 'profile.json') }

function Test-HasProperty {
    <#
    .SYNOPSIS
        Safe property test: an empty JSON object deserialises to a null property list.
    #>
    param($Object, [AllowEmptyString()][Parameter(Mandatory)][string]$Name)

    if ($null -eq $Object -or -not $Name) { return $false }
    return ($null -ne $Object.PSObject.Properties[$Name])
}

function Test-IsElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-ChildScript {
    <#
    .SYNOPSIS
        Runs a sibling tool and returns its exit code and output.

    .DESCRIPTION
        Called through -Command rather than -File so array arguments survive: -File binding
        spreads an array into separate positional arguments, which would land a hostname in
        the next parameter.
    #>
    param([Parameter(Mandatory)][string]$ScriptPath, [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Arguments)

    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($key in $Arguments.Keys) {
        $value = $Arguments[$key]
        if ($value -is [array]) {
            $quoted = ($value | ForEach-Object { "'" + ([string]$_ -replace "'", "''") + "'" }) -join ','
            $parts.Add(('-' + $key + ' @(' + $quoted + ')'))
        } elseif ($value -is [bool]) {
            $parts.Add(('-' + $key + ':$' + $value.ToString().ToLowerInvariant()))
        } else {
            $parts.Add(('-' + $key + " '" + ([string]$value -replace "'", "''") + "'"))
        }
    }
    $command = "& '" + ($ScriptPath -replace "'", "''") + "' " + ($parts -join ' ')
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $command 2>&1
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = ($output | Out-String).Trim()
    }
}

function Get-SteamModeStatus {
    if (-not (Test-Path -LiteralPath $VdfPath)) {
        return [pscustomobject]@{ Known = $false; OfflineModeEnabled = $null; Detail = 'no loginusers.vdf on this machine' }
    }
    $result = Invoke-ChildScript -ScriptPath $steamSwitch -Arguments ([ordered]@{
            Action = 'Status'; VdfPath = $VdfPath; BackupPath = $VdfBackupPath; AsJson = $true
        })
    if ($result.ExitCode -ne 0) {
        return [pscustomobject]@{ Known = $false; OfflineModeEnabled = $null; Detail = $result.Output }
    }
    $status = $result.Output | ConvertFrom-Json
    [pscustomobject]@{
        Known              = $true
        OfflineModeEnabled = [bool]$status.OfflineModeEnabled
        Detail             = ('WantsOfflineMode={0}' -f $status.WantsOfflineMode)
    }
}

function Get-PinnedDomains {
    if (-not (Test-Path -LiteralPath $HostsPath)) { return @() }
    $result = Invoke-ChildScript -ScriptPath $hostsSwitch -Arguments ([ordered]@{
            Action = 'Status'; HostsPath = $HostsPath; ManifestPath = $ManifestPath; AsJson = $true
            SkipResolveCheck = $true
        })
    if ($result.ExitCode -ne 0) { return @() }
    $status = $result.Output | ConvertFrom-Json
    return @($status.Domains)
}

function Get-StatePath {
    param([Parameter(Mandatory)][string]$Id)
    return (Join-Path $StateDirectory ($Id + '.json'))
}

function Get-InstalledStateIds {
    if (-not (Test-Path -LiteralPath $StateDirectory)) { return @() }
    $ids = @()
    foreach ($file in Get-ChildItem -LiteralPath $StateDirectory -Filter '*.json' -File) {
        try {
            $state = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            if (-not $state.Reverted) { $ids += [string]$state.Game }
        } catch { }
    }
    return $ids
}

# --- profile -----------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $ProfilePath)) {
    Write-Failure "No profile at $ProfilePath."
    exit 21
}
try {
    $profile = Get-Content -LiteralPath $ProfilePath -Raw | ConvertFrom-Json
} catch {
    Write-Failure ("Profile is not valid JSON: {0}" -f $_.Exception.Message)
    exit 21
}
foreach ($field in @('id', 'steamAppId', 'executable')) {
    if (-not (Test-HasProperty -Object $profile -Name $field)) {
        Write-Failure "Profile $ProfilePath has no '$field'."
        exit 21
    }
}
$endpoints = @()
if ((Test-HasProperty -Object $profile -Name 'offlinePatch') -and (Test-HasProperty -Object $profile.offlinePatch -Name 'endpoints')) {
    $endpoints = @($profile.offlinePatch.endpoints)
}
$tag = if (Test-HasProperty -Object $profile.offlinePatch -Name 'tag') { [string]$profile.offlinePatch.tag } else { '' }
$launchVerification = if (Test-HasProperty -Object $profile.offlinePatch -Name 'launchVerification') { [string]$profile.offlinePatch.launchVerification } else { 'UNTESTED' }
$expectedHash = if ((Test-HasProperty -Object $profile -Name 'knownGoodHashes') -and (Test-HasProperty -Object $profile.knownGoodHashes -Name $profile.executable)) {
    [string]$profile.knownGoodHashes.($profile.executable)
} else { '' }

# --- install -----------------------------------------------------------------------------
$installPath = ''
if ($GameRoot) {
    $installPath = $GameRoot
} elseif (Test-HasProperty -Object $profile -Name 'installPaths') {
    foreach ($candidate in @($profile.installPaths)) {
        if (Test-Path -LiteralPath $candidate) { $installPath = $candidate; break }
    }
}
if (-not $installPath -or -not (Test-Path -LiteralPath $installPath)) {
    $report = [pscustomobject]@{
        Game = $Game; AppId = $profile.steamAppId; Tag = $tag
        InstallFound = $false; InstallPath = $installPath
        BuildMatches = $false; LaunchVerification = $launchVerification
        Detail = 'install directory not found'
    }
    if ($Action -eq 'Status') {
        if ($AsJson) { $report | ConvertTo-Json -Depth 5 } else { $report | Format-List }
        exit 0
    }
    Write-Failure ("Install directory for {0} not found. Pass -GameRoot if it lives elsewhere." -f $Game)
    exit 23
}

$executablePath = if ($profile.executable) { Join-Path $installPath $profile.executable } else { '' }
$actualHash = ''
if ($executablePath -and (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
    $actualHash = (Get-FileHash -LiteralPath $executablePath -Algorithm SHA256).Hash.ToUpperInvariant()
}
$buildMatches = ($expectedHash -ne '') -and ($actualHash -eq $expectedHash.ToUpperInvariant())

$steamMode = Get-SteamModeStatus
$pinned = @(Get-PinnedDomains)
$missingPins = @($endpoints | Where-Object { $pinned -notcontains $_ })
$statePath = Get-StatePath -Id $Game
$stateKnown = Test-Path -LiteralPath $statePath

if ($Action -eq 'Status') {
    $report = [pscustomobject]@{
        Game                = $Game
        AppId               = [int]$profile.steamAppId
        Build               = [string]$profile.steamBuildId
        Tag                 = $tag
        InstallFound        = $true
        InstallPath         = $installPath
        Executable          = $profile.executable
        ExpectedSha256      = $expectedHash
        ActualSha256        = $actualHash
        BuildMatches        = $buildMatches
        Endpoints           = $endpoints
        PinnedEndpoints     = $pinned
        EndpointsPinned     = (($endpoints.Count -gt 0) -and ($missingPins.Count -eq 0))
        PatchAvailable      = (($endpoints.Count -gt 0) -and $buildMatches)
        SteamOfflineMode    = $steamMode.OfflineModeEnabled
        SteamModeDetail     = $steamMode.Detail
        PatchRecorded       = $stateKnown
        LaunchVerification  = $launchVerification
    }
    if ($AsJson) { $report | ConvertTo-Json -Depth 5 } else { $report | Format-List }
    exit 0
}

# --- write actions -----------------------------------------------------------------------
if (-not (Test-IsElevated) -and -not $SkipElevationCheck) {
    # Only a problem when the targets are outside the user's writable area. Tests drive
    # fixtures they already own, which is what SkipElevationCheck is for.
    $writable = $true
    foreach ($path in @($HostsPath, $VdfPath)) {
        $directory = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $directory)) { continue }
        $probe = Join-Path $directory ('.write-probe-' + [guid]::NewGuid().ToString('n'))
        try {
            [System.IO.File]::WriteAllText($probe, 'x')
            Remove-Item -LiteralPath $probe -Force
        } catch {
            $writable = $false
        }
    }
    if (-not $writable) {
        Write-Failure 'Install and Remove change the hosts file and the Steam client config, which needs an elevated shell.'
        exit 20
    }
}

if ($endpoints.Count -eq 0) {
    Write-Failure ("Profile {0} records no publisher endpoints; there is nothing to pin, and a patch without a target is not written." -f $ProfilePath)
    exit 21
}

if ($Action -eq 'Install') {
    if (-not $executablePath -or -not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
        Write-Failure ("No {0} under {1}." -f $profile.executable, $installPath)
        exit 23
    }
    if (-not $buildMatches) {
        Write-Failure ("Refusing to patch: {0} has sha256 {1}, but this patch is written for {2}." -f $profile.executable, $actualHash, $expectedHash)
        exit 24
    }

    $steamChanged = $false
    if (-not $SkipSteamOfflineMode) {
        $steamArgs = [ordered]@{ Action = 'Enable'; VdfPath = $VdfPath; BackupPath = $VdfBackupPath }
        if ($SkipRestart) { $steamArgs['SkipRestart'] = $true }
        $steamResult = Invoke-ChildScript -ScriptPath $steamSwitch -Arguments $steamArgs
        if ($steamResult.ExitCode -ne 0) {
            Write-Failure ("Steam Offline Mode step failed ({0}): {1}" -f $steamResult.ExitCode, $steamResult.Output)
            exit 25
        }
        $steamChanged = $true
        Write-Host $steamResult.Output
    }

    $hostsArgs = [ordered]@{
        Action = 'Install'; Domains = $endpoints; HostsPath = $HostsPath; ManifestPath = $ManifestPath
        Merge = $true; SkipDnsFlush = [bool]$SkipDnsFlush; SkipResolveCheck = [bool]$SkipResolveCheck
    }
    if ($SkipElevationCheck) { $hostsArgs['SkipElevationCheck'] = $true }
    $hostsResult = Invoke-ChildScript -ScriptPath $hostsSwitch -Arguments $hostsArgs
    if ($hostsResult.ExitCode -ne 0) {
        if ($steamChanged) {
            Write-Warning 'The Steam client mode was changed before this step failed; run -Action Enable on Set-SteamOfflineMode.ps1 or re-run Install.'
        }
        Write-Failure ("Endpoint pin step failed ({0}): {1}" -f $hostsResult.ExitCode, $hostsResult.Output)
        exit 22
    }
    Write-Host $hostsResult.Output

    if (-not (Test-Path -LiteralPath $StateDirectory)) {
        New-Item -ItemType Directory -Path $StateDirectory -Force | Out-Null
    }
    [pscustomobject]@{
        Game                    = $Game
        AppId                   = [int]$profile.steamAppId
        Build                   = [string]$profile.steamBuildId
        Tag                     = $tag
        Executable              = $profile.executable
        ExecutableSha256        = $actualHash
        Endpoints               = $endpoints
        SteamOfflineModeEnabled = $steamChanged
        InstalledAt             = (Get-Date).ToString('s')
        Reverted                = $false
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding UTF8

    Write-Host ("Patch installed for {0} (app {1}, build {2}{3})." -f $Game, $profile.steamAppId, $profile.steamBuildId, $(if ($tag) { ', tag ' + $tag } else { '' }))
    Write-Host ("Endpoints pinned: {0}" -f ($endpoints -join ', '))
    Write-Host 'Revert with -Action Remove; both steps restore their files byte-for-byte.'
    exit 0
}

# --- Remove ------------------------------------------------------------------------------
if (-not $stateKnown) {
    Write-Failure ("No patch record at {0}; nothing to remove for {1}." -f $statePath, $Game)
    exit 26
}
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
if ($state.Reverted) {
    Write-Failure ("The patch record at {0} is already reverted; nothing to remove for {1}." -f $statePath, $Game)
    exit 26
}

$hostsArgs = [ordered]@{
    Action = 'RemoveDomains'; Domains = @($state.Endpoints); HostsPath = $HostsPath; ManifestPath = $ManifestPath
    SkipDnsFlush = [bool]$SkipDnsFlush
}
if ($SkipElevationCheck) { $hostsArgs['SkipElevationCheck'] = $true }
$hostsResult = Invoke-ChildScript -ScriptPath $hostsSwitch -Arguments $hostsArgs
if ($hostsResult.ExitCode -ne 0 -and $hostsResult.ExitCode -ne 22) {
    Write-Failure ("Endpoint unpin step failed ({0}): {1}" -f $hostsResult.ExitCode, $hostsResult.Output)
    exit 22
}
Write-Host $hostsResult.Output

$state | Add-Member -NotePropertyName Reverted -NotePropertyValue $true -Force
$state | Add-Member -NotePropertyName RevertedAt -NotePropertyValue ((Get-Date).ToString('s')) -Force
$state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding UTF8

$others = @(Get-InstalledStateIds)
if ($state.SteamOfflineModeEnabled -and $others.Count -eq 0) {
    $steamArgs = [ordered]@{ Action = 'Disable'; VdfPath = $VdfPath; BackupPath = $VdfBackupPath }
    if ($SkipRestart) { $steamArgs['SkipRestart'] = $true }
    $steamResult = Invoke-ChildScript -ScriptPath $steamSwitch -Arguments $steamArgs
    if ($steamResult.ExitCode -ne 0) {
        Write-Failure ("Steam Offline Mode revert failed ({0}): {1}" -f $steamResult.ExitCode, $steamResult.Output)
        exit 25
    }
    Write-Host $steamResult.Output
} elseif ($state.SteamOfflineModeEnabled) {
    Write-Host ("Steam stays in Offline Mode: another game's patch still needs it ({0})." -f ($others -join ', '))
}

Write-Host ("Patch removed for {0}." -f $Game)
exit 0

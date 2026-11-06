#Requires -Version 5.1
<#
.SYNOPSIS
    Puts the Steam client into Offline Mode before a launch, and puts it back.

.DESCRIPTION
    This is the fix for the offline startup stall: on a machine with no internet route, a
    Steam client that is not already in Offline Mode spends a minute or more deciding it
    cannot connect, and during that time the game either never starts or starts and does not
    accept input. Measured on this machine with the client's and game's outbound traffic cut
    (see docs/rea/19-offline-launch-stall.md):

        Steam online  + no internet   -> the game had not started after 220 s
        Steam offline + no internet   -> usable frontend at 11.6 s

    The switch is Steam's own documented setting: the per-account
    "WantsOfflineMode"/"SkipOfflineModeWarning" values in config\loginusers.vdf. Offline Mode
    still requires the account to have signed in before, and it does not bypass ownership or
    DRM - it only stops the client from waiting on a connection it does not have.

    The original file is copied aside before the first change, and Disable writes those exact
    bytes back, so reverting is byte-identical rather than approximate.

.PARAMETER Action
    Enable   set the offline-mode values and restart Steam.
    Disable  restore the recorded original file and restart Steam.
    Status   report the values, needing no elevation.

.PARAMETER VdfPath
    loginusers.vdf to edit. Exists so the behaviour can be tested against a fixture.

.PARAMETER BackupPath
    Where the pre-change copy goes. Defaults to backups/steam-loginusers-original.vdf.

.PARAMETER SkipRestart
    Edit the file without restarting Steam (used by tests, and by callers that restart it
    themselves).

.PARAMETER AsJson
    Emit Status as JSON, so callers can compose it instead of parsing text.

.EXAMPLE
    .\tools\Set-SteamOfflineMode.ps1 -Action Enable      # elevated
    .\tools\Set-SteamOfflineMode.ps1 -Action Status
    .\tools\Set-SteamOfflineMode.ps1 -Action Disable     # elevated

.OUTPUTS
    0 done; 20 not elevated, or the file has no offline-mode values to set;
    21 nothing to restore.
#>
[CmdletBinding()]
param(
    [ValidateSet('Enable', 'Disable', 'Status')][string]$Action = 'Status',
    [string]$VdfPath = 'C:\Program Files (x86)\Steam\config\loginusers.vdf',
    [string]$BackupPath = '',
    [string]$SteamExe = 'C:\Program Files (x86)\Steam\steam.exe',
    [switch]$SkipRestart,
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'

function Write-Failure {
    <#
    .SYNOPSIS
        Reports a failure to stderr without throwing, so the documented exit code is reached.
    #>
    param([Parameter(Mandatory)][string]$Message)
    $host.UI.WriteErrorLine($Message)
}


$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $BackupPath) { $BackupPath = Join-Path $repoRoot 'backups/steam-loginusers-original.vdf' }

function Test-IsElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-FileHashHex {
    param([Parameter(Mandatory)][string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-OfflineModeValues {
    param([Parameter(Mandatory)][string]$Text)

    $wants = $null
    $skip = $null
    if ($Text -match '"WantsOfflineMode"\s+"([01])"') { $wants = $Matches[1] }
    if ($Text -match '"SkipOfflineModeWarning"\s+"([01])"') { $skip = $Matches[1] }
    [pscustomobject]@{ WantsOfflineMode = $wants; SkipOfflineModeWarning = $skip }
}

function Set-OfflineModeValues {
    <#
    .SYNOPSIS
        Returns the vdf text with both values set, preserving the file's tabs and layout.
    #>
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][ValidateSet('0', '1')][string]$Value
    )

    $updated = [regex]::Replace($Text, '("WantsOfflineMode"[ \t]+")[01](")', ('${1}' + $Value + '${2}'))
    $updated = [regex]::Replace($updated, '("SkipOfflineModeWarning"[ \t]+")[01](")', ('${1}' + $Value + '${2}'))
    return $updated
}

function Restart-SteamClient {
    param([Parameter(Mandatory)][string]$Exe)

    if (-not (Test-Path -LiteralPath $Exe)) {
        Write-Warning "Steam executable not found at $Exe; restart it yourself for the change to apply."
        return
    }

    Write-Host 'Restarting Steam...'
    try { Start-Process -FilePath $Exe -ArgumentList '-shutdown' -Wait -ErrorAction Stop } catch { }
    for ($i = 0; $i -lt 30; $i++) {
        if (-not (Get-Process -Name 'steam' -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Seconds 1
    }
    if (Get-Process -Name 'steam' -ErrorAction SilentlyContinue) {
        Write-Warning 'Steam did not shut down within 30 s; close it yourself and start it again.'
        return
    }

    # Start through Explorer so Steam runs at the desktop's integrity level. Starting it from
    # an elevated shell would make Steam - and every game it launches - elevated, and Windows
    # would then block normal input automation against those windows (UIPI).
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $Exe + '"')
    Start-Sleep -Seconds 12
    Write-Host ('Steam restarted: ' + [bool](Get-Process -Name 'steam' -ErrorAction SilentlyContinue))
}

if (-not (Test-Path -LiteralPath $VdfPath)) {
    Write-Failure "No loginusers.vdf at $VdfPath; has this account signed in to Steam on this machine?"
    exit 20
}

$text = [System.IO.File]::ReadAllText($VdfPath)
$values = Get-OfflineModeValues -Text $text

if ($Action -eq 'Status') {
    $status = [pscustomobject]@{
        VdfPath = $VdfPath
        VdfHash = Get-FileHashHex -Path $VdfPath
        WantsOfflineMode = $values.WantsOfflineMode
        SkipOfflineModeWarning = $values.SkipOfflineModeWarning
        OfflineModeEnabled = ($values.WantsOfflineMode -eq '1')
        BackupExists = (Test-Path -LiteralPath $BackupPath)
        BackupHash = if (Test-Path -LiteralPath $BackupPath) { Get-FileHashHex -Path $BackupPath } else { '' }
    }
    if ($AsJson) { $status | ConvertTo-Json -Depth 4 } else { $status | Format-List }
    exit 0
}

if ($null -eq $values.WantsOfflineMode -or $null -eq $values.SkipOfflineModeWarning) {
    Write-Failure 'loginusers.vdf has no WantsOfflineMode/SkipOfflineModeWarning values to set.'
    exit 20
}

if (-not (Test-IsElevated)) {
    # Only a problem when the target is outside the user's writable area, which is the Steam
    # install; fixtures under the repo do not need elevation.
    $probe = Join-Path (Split-Path -Parent $VdfPath) ('.write-probe-' + [guid]::NewGuid().ToString('n'))
    $writable = $false
    try {
        [System.IO.File]::WriteAllText($probe, 'x')
        Remove-Item -LiteralPath $probe -Force
        $writable = $true
    } catch {
        $writable = $false
    }
    if (-not $writable) {
        Write-Failure "Cannot write $VdfPath without an elevated shell."
        exit 20
    }
}

$backupDirectory = Split-Path -Parent $BackupPath
if ($backupDirectory -and -not (Test-Path -LiteralPath $backupDirectory)) {
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
}

if ($Action -eq 'Enable') {
    if (-not (Test-Path -LiteralPath $BackupPath)) {
        Copy-Item -LiteralPath $VdfPath -Destination $BackupPath -Force
        Write-Host ("Original copied to {0} (sha256 {1})" -f $BackupPath, (Get-FileHashHex -Path $BackupPath))
    }
    [System.IO.File]::WriteAllText($VdfPath, (Set-OfflineModeValues -Text $text -Value '1'))
    $after = Get-OfflineModeValues -Text ([System.IO.File]::ReadAllText($VdfPath))
    Write-Host ("WantsOfflineMode={0} SkipOfflineModeWarning={1}" -f $after.WantsOfflineMode, $after.SkipOfflineModeWarning)
    if (-not $SkipRestart) { Restart-SteamClient -Exe $SteamExe }
    Write-Host 'Steam will now start in Offline Mode instead of waiting for a connection it does not have.'
    exit 0
}

# Disable
if (-not (Test-Path -LiteralPath $BackupPath)) {
    Write-Failure "No recorded original at $BackupPath; nothing to restore."
    exit 21
}
[System.IO.File]::WriteAllText($VdfPath, [System.IO.File]::ReadAllText($BackupPath))
$restoredHash = Get-FileHashHex -Path $VdfPath
$backupHash = Get-FileHashHex -Path $BackupPath
Write-Host ("Restored {0} (sha256 {1})" -f $VdfPath, $restoredHash)
if ($restoredHash -ne $backupHash) {
    Write-Failure 'The restored file does not match the recorded original.'
    exit 21
}
if (-not $SkipRestart) { Restart-SteamClient -Exe $SteamExe }
Write-Host 'Verified: loginusers.vdf is byte-identical to its pre-patch state.'
exit 0

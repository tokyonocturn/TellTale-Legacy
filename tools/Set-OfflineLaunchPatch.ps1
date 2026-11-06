#Requires -Version 5.1
<#
.SYNOPSIS
    Installs or removes the offline launch patch: publisher endpoints pinned to loopback.

.DESCRIPTION
    The game contacts its publisher endpoint during startup. On a machine with no internet
    route the connection attempt does not fail, it *times out* - TCP retransmits a SYN for
    about 21 seconds per attempt, and the startup sequence waits through several of them.
    That is the minute to ninety seconds of nothing that people hit before the game will
    let them play while offline.

    Pinning the publisher hostnames to 127.0.0.1 changes that wait into an immediate
    refusal: the name resolves locally, the connection is refused in microseconds, and the
    startup path continues instead of blocking. Nothing else about the game changes - no
    file is patched, no DRM or licensing check is touched, and the endpoint is not
    impersonated; it simply stops being reachable slowly.

    The change is a marked block appended to the hosts file. Install records the exact
    bytes that were there before it, and Remove truncates back to them, so a revert is
    byte-identical rather than "close enough".

.PARAMETER Action
    Install  add the marked block (elevated).
    Remove   truncate the hosts file back to its recorded pre-patch bytes (elevated).
    Status   report state, needing no elevation.

.PARAMETER Domains
    Hostnames to pin. Defaults to the endpoints the REA map names.

.PARAMETER HostsPath
    Hosts file to edit. Exists so the behaviour can be tested against a fixture.

.PARAMETER ManifestPath
    Where the pre-patch byte record lives. Defaults to backups/offline-launch-patch.json.

.PARAMETER SkipDnsFlush
    Do not flush the resolver cache (used by tests).

.PARAMETER SkipResolveCheck
    Do not verify that the domains now resolve to loopback (used by tests).

.PARAMETER SkipElevationCheck
    Allow Install/Remove of a hosts file the caller can already write, without demanding an
    elevated shell. Used by the tests against a fixture.

.EXAMPLE
    .\tools\Set-OfflineLaunchPatch.ps1 -Action Install      # elevated
    .\tools\Set-OfflineLaunchPatch.ps1 -Action Status
    .\tools\Set-OfflineLaunchPatch.ps1 -Action Remove       # elevated, byte-identical

.OUTPUTS
    0 done; 20 not elevated; 21 the hosts file changed since the patch was installed;
    22 nothing to remove.
#>
[CmdletBinding()]
param(
    [ValidateSet('Install', 'Remove', 'Status')][string]$Action = 'Status',
    [string[]]$Domains = @('api.telltalegames.com', 'meta.telltalegames.com'),
    [string]$HostsPath = (Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'),
    [string]$ManifestPath = '',
    [switch]$SkipDnsFlush,
    [switch]$SkipResolveCheck,
    [switch]$SkipElevationCheck
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
if (-not $ManifestPath) { $ManifestPath = Join-Path $repoRoot 'backups/offline-launch-patch.json' }

$markerStart = '# >>> telltale-legacy offline launch patch >>>'
$markerEnd = '# <<< telltale-legacy offline launch patch <<<'

function Test-IsElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-BytesHash {
    param([Parameter(Mandatory)][byte[]]$Bytes)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    return (($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) -join '').ToUpperInvariant()
}

function Get-InstalledBlockText {
    param([Parameter(Mandatory)][string[]]$Names)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('')
    $lines.Add($markerStart)
    $lines.Add('# Pins the publisher endpoints to loopback so an offline launch fails instantly')
    $lines.Add('# instead of waiting through TCP timeouts. Remove with -Action Remove.')
    foreach ($name in $Names) { $lines.Add("127.0.0.1`t$name") }
    $lines.Add($markerEnd)
    return (($lines -join "`r`n") + "`r`n")
}

function Get-PatchEntryList {
    param([Parameter(Mandatory)][string]$Text)

    $entries = @()
    $inside = $false
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line.Trim() -eq $markerStart) { $inside = $true; continue }
        if ($line.Trim() -eq $markerEnd) { $inside = $false; continue }
        if ($inside -and $line.Trim()) { $entries += $line.Trim() }
    }
    return $entries
}

function Read-PatchManifest {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
}

function Get-ResolvedAddresses {
    param([Parameter(Mandatory)][string]$Name)

    try {
        return @([System.Net.Dns]::GetHostAddresses($Name) | ForEach-Object { $_.IPAddressToString })
    } catch {
        return @()
    }
}

if ($Action -eq 'Status') {
    $text = if (Test-Path -LiteralPath $HostsPath) { [System.IO.File]::ReadAllText($HostsPath) } else { '' }
    $entries = Get-PatchEntryList -Text $text
    $manifest = Read-PatchManifest -Path $ManifestPath
    $resolved = foreach ($name in $Domains) {
        [pscustomobject]@{ Domain = $name; Addresses = ((Get-ResolvedAddresses -Name $name) -join ', ') }
    }
    [pscustomobject]@{
        HostsPath = $HostsPath
        Installed = ($entries.Count -gt 0)
        Entries = ($entries -join '; ')
        HostsHash = if (Test-Path -LiteralPath $HostsPath) { Get-BytesHash -Bytes ([System.IO.File]::ReadAllBytes($HostsPath)) } else { '' }
        PrePatchHash = if ($manifest) { $manifest.OriginalHash } else { '' }
        InstalledAt = if ($manifest) { $manifest.InstalledAt } else { '' }
        Domains = $resolved
    } | Format-List
    exit 0
}

if (-not (Test-IsElevated) -and -not $SkipElevationCheck) {
    Write-Failure 'Install and Remove write the hosts file, which needs an elevated shell.'
    exit 20
}

if ($Action -eq 'Install') {
    $bytes = [System.IO.File]::ReadAllBytes($HostsPath)
    $originalHash = Get-BytesHash -Bytes $bytes
    $text = [System.IO.File]::ReadAllText($HostsPath)

    if (Get-PatchEntryList -Text $text) {
        Write-Host 'The patch block is already present; refreshing its entries.'
        $text = $text.Substring(0, $text.IndexOf($markerStart))
        $text = $text.TrimEnd("`r", "`n")
        [System.IO.File]::WriteAllBytes($HostsPath, [System.Text.Encoding]::UTF8.GetBytes($text))
        $bytes = [System.IO.File]::ReadAllBytes($HostsPath)
        $originalHash = Get-BytesHash -Bytes $bytes
    }

    $block = Get-InstalledBlockText -Names $Domains
    $combined = [System.Text.Encoding]::UTF8.GetBytes($text + $block)
    [System.IO.File]::WriteAllBytes($HostsPath, $combined)

    $manifestDirectory = Split-Path -Parent $ManifestPath
    if ($manifestDirectory -and -not (Test-Path -LiteralPath $manifestDirectory)) {
        New-Item -ItemType Directory -Path $manifestDirectory -Force | Out-Null
    }
    [pscustomobject]@{
        OriginalHash = $originalHash
        OriginalLength = $bytes.Length
        Domains = $Domains
        HostsPath = $HostsPath
        InstalledAt = (Get-Date).ToString('s')
        Reverted = $false
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ManifestPath -Encoding UTF8

    if (-not $SkipDnsFlush) {
        try { Clear-DnsClientCache -ErrorAction Stop; Write-Host 'Resolver cache flushed.' }
        catch { Write-Warning "Could not flush the resolver cache: $($_.Exception.Message)" }
    }

    if (-not $SkipResolveCheck) {
        $bad = @()
        foreach ($name in $Domains) {
            $addresses = Get-ResolvedAddresses -Name $name
            if ($addresses -notcontains '127.0.0.1') { $bad += ("{0} -> {1}" -f $name, ($addresses -join ',')) }
        }
        if ($bad.Count -gt 0) {
            Write-Warning ("These names do not resolve to loopback yet: {0}" -f ($bad -join '; '))
        }
    }

    Write-Host ("Offline launch patch installed for: {0}" -f ($Domains -join ', '))
    Write-Host ("Pre-patch hosts bytes: {0} ({1} bytes) recorded in {2}" -f $originalHash, $bytes.Length, $ManifestPath)
    exit 0
}

# Remove
$manifest = Read-PatchManifest -Path $ManifestPath
if (-not $manifest) {
    Write-Failure "No patch manifest at $ManifestPath; install the patch before removing it."
    exit 22
}

$current = [System.IO.File]::ReadAllBytes($HostsPath)
$originalLength = [int]$manifest.OriginalLength
if ($current.Length -lt $originalLength) {
    Write-Failure 'The hosts file is shorter than the recorded pre-patch file; refusing to guess.'
    exit 21
}

$prefix = New-Object byte[] $originalLength
[Array]::Copy($current, $prefix, $originalLength)
if ((Get-BytesHash -Bytes $prefix) -ne $manifest.OriginalHash) {
    Write-Failure 'The hosts file has changed since the patch was installed; refusing to overwrite those changes.'
    exit 21
}

[System.IO.File]::WriteAllBytes($HostsPath, $prefix)
$after = Get-BytesHash -Bytes ([System.IO.File]::ReadAllBytes($HostsPath))

$manifest | Add-Member -NotePropertyName Reverted -NotePropertyValue $true -Force
$manifest | Add-Member -NotePropertyName RevertedAt -NotePropertyValue ((Get-Date).ToString('s')) -Force
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ManifestPath -Encoding UTF8

if (-not $SkipDnsFlush) {
    try { Clear-DnsClientCache -ErrorAction Stop } catch { }
}

Write-Host ("Patch removed; hosts is back to {0} bytes, hash {1}" -f $prefix.Length, $after)
if ($after -ne $manifest.OriginalHash) {
    Write-Failure 'The restored hosts file does not match the recorded pre-patch hash.'
    exit 21
}
Write-Host 'Verified: the hosts file is byte-identical to its pre-patch state.'
exit 0

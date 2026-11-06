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
    Install        add the marked block (elevated).
    Remove         truncate the hosts file back to its recorded pre-patch bytes (elevated).
    RemoveDomains  drop only the listed hostnames from the block, leaving the rest (elevated).
    Status         report state, needing no elevation.

.PARAMETER Merge
    On Install, keep the hostnames already in the marked block and add the listed ones
    rather than replacing the block. Several games share one hosts file, so each game's
    patch adds its own endpoints without evicting another game's.

.PARAMETER AsJson
    Emit Status as JSON, so callers can compose it instead of parsing text.

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
    [ValidateSet('Install', 'Remove', 'RemoveDomains', 'Status')][string]$Action = 'Status',
    [string[]]$Domains = @('api.telltalegames.com', 'meta.telltalegames.com'),
    [string]$HostsPath = (Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'),
    [string]$ManifestPath = '',
    [switch]$Merge,
    [switch]$AsJson,
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
        # The block carries its own comment lines; only address lines are entries.
        if ($inside -and $line.Trim() -and -not $line.Trim().StartsWith('#')) { $entries += $line.Trim() }
    }
    return $entries
}

function Get-PrePatchText {
    <#
    .SYNOPSIS
        Returns the file text as it was before the block was appended.

    .DESCRIPTION
        The block starts with one blank line, so the split point sits after exactly one
        separator that this tool added. Removing that separator (and nothing else) is what
        keeps the revert byte-identical when the original file ended with a newline.
    #>
    param([Parameter(Mandatory)][string]$Text)

    $index = $Text.IndexOf($markerStart)
    if ($index -lt 0) { return $Text }
    $prefix = $Text.Substring(0, $index)
    if ($prefix.EndsWith("`r`n")) { return $prefix.Substring(0, $prefix.Length - 2) }
    if ($prefix.EndsWith("`n")) { return $prefix.Substring(0, $prefix.Length - 1) }
    return $prefix
}

function Get-PatchDomainNames {
    <#
    .SYNOPSIS
        Pulls the hostname out of each recorded block entry.
    #>
    param([AllowEmptyCollection()][string[]]$Entries = @())

    foreach ($entry in $Entries) {
        $parts = $entry -split '\s+'
        if ($parts.Count -ge 2) { $parts[1] }
    }
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
        Domains = @(Get-PatchDomainNames -Entries $entries)
        HostsHash = if (Test-Path -LiteralPath $HostsPath) { Get-BytesHash -Bytes ([System.IO.File]::ReadAllBytes($HostsPath)) } else { '' }
        PrePatchHash = if ($manifest) { $manifest.OriginalHash } else { '' }
        InstalledAt = if ($manifest) { $manifest.InstalledAt } else { '' }
        Resolved = $resolved
    } | ForEach-Object { if ($AsJson) { $_ | ConvertTo-Json -Depth 5 } else { $_ | Format-List } }
    exit 0
}

if (-not (Test-IsElevated) -and -not $SkipElevationCheck) {
    Write-Failure 'Install and Remove write the hosts file, which needs an elevated shell.'
    exit 20
}

if ($Action -eq 'Install') {
    $text = [System.IO.File]::ReadAllText($HostsPath)
    $manifest = Read-PatchManifest -Path $ManifestPath
    $existing = @()
    if ((Get-PatchEntryList -Text $text).Count -gt 0) {
        $existing = @(Get-PatchDomainNames -Entries (Get-PatchEntryList -Text $text))
        Write-Host ('The patch block is already present; it holds ' + ($existing -join ', ') + '.')
        $text = Get-PrePatchText -Text $text
    }

    $names = @($Domains)
    if ($Merge -or $existing.Count -gt 0) {
        # Several games share one hosts file: a second game's patch adds its endpoints
        # instead of replacing the first game's.
        $names = @(@($existing) + @($Domains) | Where-Object { $_ } | Select-Object -Unique)
    }

    $prefixBytes = [System.Text.Encoding]::UTF8.GetBytes($text)
    $prefixHash = Get-BytesHash -Bytes $prefixBytes
    if ($manifest -and $manifest.OriginalHash -ne $prefixHash) {
        Write-Warning 'The hosts file does not match the recorded pre-patch state; the current bytes become the new pre-patch baseline.'
    }
    [System.IO.File]::WriteAllBytes($HostsPath, $prefixBytes)

    $block = Get-InstalledBlockText -Names $names
    $combined = [System.Text.Encoding]::UTF8.GetBytes($text + $block)
    [System.IO.File]::WriteAllBytes($HostsPath, $combined)

    $manifestDirectory = Split-Path -Parent $ManifestPath
    if ($manifestDirectory -and -not (Test-Path -LiteralPath $manifestDirectory)) {
        New-Item -ItemType Directory -Path $manifestDirectory -Force | Out-Null
    }
    [pscustomobject]@{
        OriginalHash = $prefixHash
        OriginalLength = $prefixBytes.Length
        Domains = $names
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
        foreach ($name in $names) {
            $addresses = Get-ResolvedAddresses -Name $name
            if ($addresses -notcontains '127.0.0.1') { $bad += ("{0} -> {1}" -f $name, ($addresses -join ',')) }
        }
        if ($bad.Count -gt 0) {
            Write-Warning ("These names do not resolve to loopback yet: {0}" -f ($bad -join '; '))
        }
    }

    Write-Host ("Offline launch patch installed for: {0}" -f ($names -join ', '))
    Write-Host ("Pre-patch hosts bytes: {0} ({1} bytes) recorded in {2}" -f $prefixHash, $prefixBytes.Length, $ManifestPath)
    exit 0
}

if ($Action -eq 'RemoveDomains') {
    $text = [System.IO.File]::ReadAllText($HostsPath)
    $entries = @(Get-PatchEntryList -Text $text)
    if ($entries.Count -eq 0) {
        Write-Failure 'The patch block is not present; nothing to remove.'
        exit 22
    }

    $drop = @($Domains | ForEach-Object { $_.ToLowerInvariant() })
    $keepEntries = @($entries | Where-Object { $drop -notcontains ((Get-PatchDomainNames -Entries @($_)) | Select-Object -First 1).ToLowerInvariant() })
    $keepNames = @($keepEntries | ForEach-Object { (Get-PatchDomainNames -Entries @($_)) | Select-Object -First 1 })
    $prefix = Get-PrePatchText -Text $text
    $manifest = Read-PatchManifest -Path $ManifestPath

    if ($keepEntries.Count -eq 0) {
        $prefixBytes = [System.Text.Encoding]::UTF8.GetBytes($prefix)
        [System.IO.File]::WriteAllBytes($HostsPath, $prefixBytes)
        if ($manifest -and ((Get-BytesHash -Bytes $prefixBytes) -ne $manifest.OriginalHash)) {
            Write-Warning 'The restored bytes do not match the recorded pre-patch hash.'
        }
        Write-Host 'Patch block removed; the hosts file is back to its pre-patch length.'
    } else {
        $combined = [System.Text.Encoding]::UTF8.GetBytes($prefix + (Get-InstalledBlockText -Names $keepNames))
        [System.IO.File]::WriteAllBytes($HostsPath, $combined)
        Write-Host ("Removed entries for: {0}. Still pinned: {1}" -f ($Domains -join ', '), ($keepNames -join ', '))
    }

    if ($manifest) {
        $manifest | Add-Member -NotePropertyName Domains -NotePropertyValue $keepNames -Force
        $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ManifestPath -Encoding UTF8
    }

    if (-not $SkipDnsFlush) {
        try { Clear-DnsClientCache -ErrorAction Stop } catch { }
    }
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

#Requires -Version 5.1
<#
.SYNOPSIS
    Reversibly blocks the game's Telltale API endpoints to test offline behaviour.

.DESCRIPTION
    Adds marked entries to the Windows hosts file that point the discovered Telltale
    API endpoints at 127.0.0.1, flushes the DNS cache, and can remove the entries
    again. This simulates "the publisher API is unreachable" while leaving Steam and
    the rest of the network untouched, which is the only way to test the game's own
    online dependency without disabling networking.

    Requires an elevated shell for Block/Unblock (the hosts file is protected).
    Steam itself is NOT blocked: the Steam DRM wrapper must keep working, because
    Telltale Legacy never bypasses licensing.

.PARAMETER Action
    Block, Unblock, or Status.

.PARAMETER Domains
    Domains to block. Defaults to the endpoints observed in REA session logs.

.EXAMPLE
    .\Invoke-OfflineProbe.ps1 -Action Block
    .\Invoke-OfflineProbe.ps1 -Action Status
    .\Invoke-OfflineProbe.ps1 -Action Unblock
#>
[CmdletBinding()]
param(
    [ValidateSet('Block', 'Unblock', 'Status')][string]$Action = 'Status',
    [string[]]$Domains = @('api.telltalegames.com'),
    [string]$HostsPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# -File argument binding can pass "a.example,b.example" as a single string. A comma
# is never valid in a host name, and accepting it silently writes a hosts line that
# blocks nothing, so refuse it instead of reporting a successful block.
foreach ($domain in $Domains) {
    if ($domain -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]*$') {
        [Console]::Error.WriteLine("Invalid domain '{0}'. Pass one value per domain, not a comma-separated list." -f $domain)
        exit 2
    }
}

$systemHostsPath = Join-Path $env:WINDIR 'System32\drivers\etc\hosts'
# Note: PowerShell variable names are case-insensitive, so this must NOT be called
# $hostsPath — that would overwrite the $HostsPath parameter and break the
# $liveResolution check below.
$effectiveHostsPath = if ($HostsPath) { $HostsPath } else { $systemHostsPath }
# A caller-supplied hosts file is a fixture: never touch live DNS for it.
$liveResolution = (-not $HostsPath)
$beginMarker = '# >>> telltale-legacy offline probe >>>'
$endMarker = '# <<< telltale-legacy offline probe <<<'

function Test-IsElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-HostsLines {
    param([string]$Content)
    @($Content -split "`r?`n")
}

function Get-HostsContent {
    [System.IO.File]::ReadAllText($effectiveHostsPath)
}

function Remove-ProbeBlock {
    param([string]$Content)
    $pattern = [regex]::Escape($beginMarker) + '[\s\S]*?' + [regex]::Escape($endMarker)
    [regex]::Replace($Content, $pattern, '').TrimEnd() + "`r`n"
}

function Get-ProbeStatus {
    $content = Get-HostsContent
    $blocked = $content.Contains($beginMarker)
    $activeDomains = @()
    if ($blocked) {
        $segment = $content.Substring($content.IndexOf($beginMarker))
        $segment = $segment.Substring(0, $segment.IndexOf($endMarker))
        $activeDomains = @($segment -split "`r?`n" | Where-Object { $_ -match '^\s*127\.0\.0\.1\s+' } | ForEach-Object { ($_ -split '\s+')[1] })
    }
    [pscustomobject]@{
        Blocked        = $blocked
        BlockedDomains = $activeDomains
        ResolvesTo     = @(
            foreach ($domain in $Domains) {
                $addresses = @()
                $resolutionError = $null
                if ($liveResolution) {
                    try {
                        $records = @(Resolve-DnsName -Name $domain -Type A -ErrorAction Stop)
                        $addresses = @($records | Where-Object { $_.IPAddress } | ForEach-Object { $_.IPAddress })
                        if ($records.Count -eq 0) { $resolutionError = 'resolver returned no records' }
                        elseif ($addresses.Count -eq 0) { $resolutionError = ('resolver returned {0} record(s) without an A address' -f $records.Count) }
                    } catch { $resolutionError = $_.Exception.Message }
                } else {
                    $addresses = @(Get-HostsLines -Content $content | Where-Object { $_ -match ('^\s*\S+\s+' + [regex]::Escape($domain) + '\s*$') } | ForEach-Object { ($_ -split '\s+')[0] })
                }
                [pscustomobject]@{ Domain = $domain; Addresses = ($addresses -join ', '); ResolutionError = $resolutionError }
            }
        )
    }
}

switch ($Action) {
    'Status' {
        Get-ProbeStatus | ConvertTo-Json -Depth 5
    }

    'Block' {
        if (-not (Test-IsElevated)) { throw 'Block requires an elevated shell (hosts file is protected).' }
        $content = Get-HostsContent
        $content = Remove-ProbeBlock -Content $content
        $lines = @($beginMarker, '# Temporary block added by Telltale Legacy to test offline behaviour.', '# Remove with: Invoke-OfflineProbe.ps1 -Action Unblock')
        foreach ($domain in $Domains) { $lines += "127.0.0.1`t$domain" }
        $lines += $endMarker
        $newContent = ($content.TrimEnd() + "`r`n`r`n" + ($lines -join "`r`n") + "`r`n")
        [System.IO.File]::WriteAllText($effectiveHostsPath, $newContent)
        & ipconfig.exe /flushdns | Out-Null

        Start-Sleep -Milliseconds 500
        $status = Get-ProbeStatus
        if (-not $status.Blocked) { throw 'Block did not take effect.' }
        Write-Host ("Blocked: {0}" -f ($Domains -join ', '))
        $status.ResolvesTo | Format-Table -AutoSize
    }

    'Unblock' {
        if (-not (Test-IsElevated)) { throw 'Unblock requires an elevated shell (hosts file is protected).' }
        $content = Get-HostsContent
        $cleaned = Remove-ProbeBlock -Content $content
        [System.IO.File]::WriteAllText($effectiveHostsPath, $cleaned)
        & ipconfig.exe /flushdns | Out-Null

        Start-Sleep -Milliseconds 500
        $status = Get-ProbeStatus
        if ($status.Blocked) { throw 'Unblock did not take effect.' }
        Write-Host 'Probe block removed.'
        $status.ResolvesTo | Format-Table -AutoSize
    }
}

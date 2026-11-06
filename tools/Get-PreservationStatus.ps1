#Requires -Version 5.1
<#
.SYNOPSIS
    Prints the preservation status of every registered game.

.DESCRIPTION
    Reads registry/games.json plus each profile and reports, per title, whether it
    is installed, the engine, and the recorded status of offline, LAN and P2P
    capabilities using the program's status vocabulary. Read-only.

.PARAMETER Json
    Emit the table as JSON instead of a console table.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\Get-PreservationStatus.ps1
#>
[CmdletBinding()]
param(
    [switch]$Json,
    [string]$RegistryPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Preservation.Common.psm1') -Force

$repoRoot = Get-PreservationRepoRoot
$registry = Get-GameRegistry -Path $RegistryPath

$rows = foreach ($entry in $registry.games) {
    $profile = $null
    if ($entry.profile) {
        $profilePath = Resolve-RepoPath -Path $entry.profile
        if (Test-Path -LiteralPath $profilePath) { $profile = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json }
    }
    [pscustomobject]@{
        Id             = $entry.id
        Title          = $entry.title
        AppId          = $entry.steamAppId
        BuildId        = $entry.steamBuildId
        Installed      = [bool]$entry.installed
        Engine         = $entry.engine
        Offline        = $entry.capabilities.offline
        Lan            = $entry.capabilities.lan
        P2p            = $entry.capabilities.p2p
        Adapter        = $entry.adapter
        Profile        = [bool]$profile
        ProfileBinaries = if ($profile) { @($profile.binaries).Count } else { 0 }
    }
}

if ($Json) {
    [ordered]@{
        schemaVersion = 1
        generatedUtc  = (Get-Date).ToUniversalTime().ToString('u')
        games         = @($rows)
    } | ConvertTo-Json -Depth 5
    exit 0
}

Write-Host ''
Write-Host ("{0,-34} {1,-5} {2,-34} {3,-32} {4,-32}" -f 'GAME ID', 'INST', 'OFFLINE', 'LAN', 'P2P')
Write-Host ('-' * 143)
foreach ($row in $rows) {
    $mark = if ($row.Installed) { 'yes' } else { 'no' }
    Write-Host ("{0,-34} {1,-5} {2,-34} {3,-32} {4,-32}" -f $row.Id, $mark, $row.Offline, $row.Lan, $row.P2p)
}
Write-Host ''
Write-Host ("{0} titles, {1} installed, {2} with a profile, {3} with an adapter" -f $rows.Count, @($rows | Where-Object { $_.Installed }).Count, @($rows | Where-Object { $_.Profile }).Count, @($rows | Where-Object { $_.Adapter }).Count)
exit 0

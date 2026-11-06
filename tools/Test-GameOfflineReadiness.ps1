#Requires -Version 5.1
<#
.SYNOPSIS
    Profile-driven offline readiness audit for a registered game.

.DESCRIPTION
    Fails closed: a binary whose hash or size does not match the profile is a
    failure, not a warning. Checks the install, the Steam manifest and its build
    id, every recorded binary, the user-state locations the profile names, and
    whether the profile declares a mandatory external dependency that makes an
    offline claim impossible.

    Read-only. Writes one JSON report per audited game when -OutputPath is given.

.PARAMETER GameId
    Registry id to audit.

.PARAMETER All
    Audit every installed game with a profile.

.PARAMETER OutputDirectory
    Where JSON reports are written. Defaults to docs/preservation/data/readiness.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\Test-GameOfflineReadiness.ps1 -GameId pvz-goty-steam-3590 -OutputDirectory docs\preservation\data\readiness
#>
[CmdletBinding()]
param(
    [string]$GameId,
    [switch]$All,
    [string]$OutputDirectory,
    [switch]$SkipHash,
    [string]$RegistryPath,
    # Test seams: audit a fixture tree without a Steam manifest.
    [string]$InstallRoot,
    [switch]$SkipSteamChecks
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Preservation.Common.psm1') -Force

$repoRoot = Get-PreservationRepoRoot
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repoRoot 'docs\preservation\data\readiness' }

$registry = Get-GameRegistry -Path $RegistryPath
if (-not $GameId -and -not $All) { throw 'Pass -GameId <id> or -All.' }

$targets = @(if ($All) {
    $registry.games | Where-Object { $_.installed -and $_.profile }
} else {
    $registry.games | Where-Object { $_.id -eq $GameId }
})
if ($targets.Count -eq 0) { throw "No registry entry matched '$GameId'" }

$failedAny = $false
$results = New-Object System.Collections.Generic.List[object]

foreach ($entry in $targets) {
    $checks = New-Object System.Collections.Generic.List[object]
    $add = {
        param([string]$Name, [string]$Status, [string]$Message)
        $checks.Add([pscustomobject]@{ check = $Name; status = $Status; message = $Message })
    }

    if (-not $entry.installed) {
        & $add 'installed' 'fail' ($entry.notes)
    }

    $profile = $null
    $profilePath = if ($entry.profile) { Resolve-RepoPath -Path $entry.profile } else { $null }
    if (-not $profilePath -or -not (Test-Path -LiteralPath $profilePath)) {
        & $add 'profile' 'fail' 'no profile recorded for this title'
    } else {
        $profile = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
        & $add 'profile' 'pass' $entry.profile
    }

    $manifest = if ($SkipSteamChecks) { $null } else { Get-SteamManifest -AppId ([int]$entry.steamAppId) }
    $gameRoot = if ($InstallRoot) { (Resolve-Path -LiteralPath $InstallRoot).ProviderPath }
        elseif ($entry.PSObject.Properties.Name -contains 'installPath' -and $entry.installPath) { $entry.installPath }
        else { $null }
    if ($SkipSteamChecks) {
        & $add 'steam-manifest' 'pass' 'skipped (-SkipSteamChecks)'
    } elseif (-not $manifest) {
        & $add 'steam-manifest' 'fail' 'appmanifest not found in any Steam library'
    } else {
        if (-not $gameRoot) { $gameRoot = $manifest.InstallPath }
        if ($manifest.FullyInstalled) {
            & $add 'steam-manifest' 'pass' ('build ' + $manifest.BuildId + ', StateFlags ' + $manifest.StateFlags)
        } else {
            & $add 'steam-manifest' 'fail' ('StateFlags ' + $manifest.StateFlags + ' means the app is not fully installed')
        }
        if ($profile -and $entry.steamBuildId -and $manifest.BuildId -ne [string]$entry.steamBuildId) {
            & $add 'build-id' 'fail' ('profile records ' + $entry.steamBuildId + ' but the installed manifest is ' + $manifest.BuildId)
        } elseif ($profile) {
            & $add 'build-id' 'pass' ('build ' + $manifest.BuildId)
        }
    }

    if ($gameRoot -and (Test-Path -LiteralPath $gameRoot)) {
        $topLevel = @(Get-ChildItem -LiteralPath $gameRoot -File -Force -ErrorAction SilentlyContinue)
        $count = @($topLevel).Count
        if ($count -gt 0) { & $add 'install-content' 'pass' ('install directory present (' + $count + ' top-level files)') }
        else { & $add 'install-content' 'fail' 'install directory is empty' }
    } elseif ($gameRoot) {
        & $add 'install-content' 'fail' 'install path missing on disk'
    } elseif ($manifest) {
        & $add 'install-content' 'fail' 'install path missing on disk'
    }

    if ($profile) {
        foreach ($binary in @($profile.binaries)) {
            $relative = ([string]$binary.path).Replace('/', '\')
            if (-not $gameRoot) { break }
            $full = Join-Path $gameRoot $relative
            if (-not (Test-Path -LiteralPath $full)) {
                & $add ('binary:' + $binary.path) 'fail' 'missing'
                continue
            }
            $size = (Get-Item -LiteralPath $full).Length
            if ($size -ne [int64]$binary.sizeBytes) {
                & $add ('binary:' + $binary.path) 'fail' ('size ' + $size + ' does not match recorded ' + $binary.sizeBytes)
                continue
            }
            if ($SkipHash) {
                & $add ('binary:' + $binary.path) 'pass' 'size matches (hash skipped)'
                continue
            }
            $hash = Get-FileSha256 -Path $full
            if ($hash -ne [string]$binary.sha256) {
                & $add ('binary:' + $binary.path) 'fail' ('sha256 ' + $hash + ' does not match recorded ' + $binary.sha256)
            } else {
                & $add ('binary:' + $binary.path) 'pass' 'size and sha256 match'
            }
        }

        foreach ($state in @($profile.userState)) {
            $path = [string]$state.path
            if ([string]$state.kind -eq 'registry') {
                if (Test-Path -LiteralPath $path) { & $add ('user-state:' + $state.role) 'pass' ('key present: ' + $path) }
                else { & $add ('user-state:' + $state.role) 'warn' ('key not created yet: ' + $path) }
                continue
            }
            if ($path.StartsWith('<install>')) {
                if (-not $gameRoot) { continue }
                $path = Join-Path $gameRoot $path.Substring('<install>'.Length).TrimStart('\')
            } else {
                $path = [Environment]::ExpandEnvironmentVariables($path)
            }
            if (Test-Path -LiteralPath $path) {
                & $add ('user-state:' + $state.role) 'pass' ('present: ' + $path)
            } elseif (Test-DirectoryWritable -Path $path) {
                $status = if ($state.verified) { 'warn' } else { 'pass' }
                & $add ('user-state:' + $state.role) $status ('not created yet, will be writable: ' + $path)
            } else {
                & $add ('user-state:' + $state.role) 'fail' ('not writable: ' + $path)
            }
        }

        $blocking = @($profile.dependencies | Where-Object { $_.mandatory })
        if ($blocking.Count -gt 0) {
            foreach ($dependency in $blocking) {
                & $add ('dependency:' + $dependency.service) 'fail' ('mandatory external dependency (' + $dependency.endpoint + ')') 
            }
        } else {
            & $add 'dependencies' 'pass' 'no mandatory external dependency recorded'
        }
    }

    $steamClient = Get-Process -Name steam -ErrorAction SilentlyContinue
    if ($steamClient) { & $add 'steam-client' 'pass' 'Steam client is running' }
    else { & $add 'steam-client' 'warn' 'Steam client not running; launching through Steam needs it' }

    $failures = @($checks | Where-Object { $_.status -eq 'fail' })
    $warnings = @($checks | Where-Object { $_.status -eq 'warn' })
    $verdict = if ($failures.Count -gt 0) { 'blocked' } else { 'ready' }
    if ($failures.Count -gt 0) { $failedAny = $true }

    $report = [ordered]@{
        schemaVersion = 1
        generatedUtc  = (Get-Date).ToUniversalTime().ToString('u')
        gameId        = $entry.id
        title         = $entry.title
        verdict       = $verdict
        failures      = $failures.Count
        warnings      = $warnings.Count
        capabilities  = $entry.capabilities
        gameRoot   = $gameRoot
        checks        = $checks
    }

    if (-not (Test-Path -LiteralPath $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null }
    $outputPath = Join-Path $OutputDirectory ($entry.id + '.json')
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $outputPath -Encoding UTF8

    Write-Host ''
    Write-Host ("{0}  [{1}]" -f $entry.title, $verdict.ToUpperInvariant())
    foreach ($check in $checks) {
        $color = switch ($check.status) { 'pass' { 'Green' } 'warn' { 'Yellow' } default { 'Red' } }
        Write-Host ("  {0,-7} {1,-28} {2}" -f $check.status.ToUpperInvariant(), $check.check, $check.message) -ForegroundColor $color
    }
    $results.Add([pscustomobject]@{ gameId = $entry.id; verdict = $verdict; failures = $failures.Count; warnings = $warnings.Count; report = $outputPath })
}

Write-Host ''
Write-Host ("{0} audited: {1} ready, {2} blocked" -f $results.Count, @($results | Where-Object { $_.verdict -eq 'ready' }).Count, @($results | Where-Object { $_.verdict -ne 'ready' }).Count)
if ($failedAny) { exit 2 }
exit 0

#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only forensic inventory of one registered game installation.

.DESCRIPTION
    Walks a game's installation, classifies files, parses PE headers and imported
    modules, extracts host-like strings from binaries, and hashes the binaries the
    profile depends on. Nothing is written to the game directory; the JSON report
    goes to docs/preservation/data (git-ignored) or a path you choose.

    This is the generic counterpart to Get-GameInventory.ps1: it makes no
    assumptions about Telltale archives or engine layout.

.PARAMETER GameId
    Registry id, for example cnc-renegade-steam-2229890.

.PARAMETER All
    Inventory every installed game in the registry.

.PARAMETER OutputDirectory
    Directory for the JSON reports. Defaults to docs/preservation/data/inventory.

.PARAMETER SkipHash
    Do not hash anything except the profile's own binaries.

.PARAMETER HashAll
    Hash every file, including multi-gigabyte content archives. Slow by design.

.PARAMETER MaxFiles
    Safety cap on the number of file entries recorded per game.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\Get-PreservationInventory.ps1 -GameId cnc-renegade-steam-2229890
#>
[CmdletBinding()]
param(
    [string]$GameId,
    [switch]$All,
    [string]$OutputDirectory,
    [switch]$SkipHash,
    [switch]$HashAll,
    [int]$MaxFiles = 20000,
    [string]$RegistryPath,
    # Overrides manifest-derived discovery. Used by the tests against a fixture tree.
    [string]$InstallRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Preservation.Common.psm1') -Force

$repoRoot = Get-PreservationRepoRoot
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repoRoot 'docs\preservation\data\inventory' }

$registry = Get-GameRegistry -Path $RegistryPath
if (-not $GameId -and -not $All) {
    throw 'Pass -GameId <id> or -All. Use tools\Get-PreservationStatus.ps1 to list ids.'
}

$targets = @(if ($All) {
    $registry.games | Where-Object { $_.installed -and $_.profile }
} else {
    $registry.games | Where-Object { $_.id -eq $GameId }
})
if ($targets.Count -eq 0) { throw "No registry entry matched '$GameId'" }
if ($GameId -and -not $All -and -not $targets[0].installed) {
    Write-Host ("{0}: not installed, nothing to inventory" -f $GameId)
    exit 2
}

function Get-FileClass {
    param([string]$Name)
    switch -Regex ($Name) {
        '(?i)\.(exe)$'                       { return 'executable' }
        '(?i)\.(dll|dat|game)$'              { return 'library' }
        '(?i)\.(big|mix|pak|cas|cat|ttarch)$' { return 'archive' }
        '(?i)\.(ini|cfg|xml|json|txt|prop|lua|nfo|acf|vdf|sig|lcf)$' { return 'configuration' }
        default                              { return 'other' }
    }
}

$reports = New-Object System.Collections.Generic.List[object]

foreach ($entry in $targets) {
    $profilePath = Resolve-RepoPath -Path $entry.profile
    if (-not (Test-Path -LiteralPath $profilePath)) { throw "Profile missing for '$($entry.id)': $profilePath" }
    $profile = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json

    $manifest = Get-SteamManifest -AppId ([int]$entry.steamAppId)
    # An explicit registry installPath wins over the manifest, for relocated or
    # non-Steam copies. The parameter wins over both (used by the fixture tests).
    $gameRoot = if ($InstallRoot) { (Resolve-Path -LiteralPath $InstallRoot).ProviderPath }
        elseif ($entry.PSObject.Properties.Name -contains 'installPath' -and $entry.installPath) { $entry.installPath }
        elseif ($manifest -and $manifest.InstallPath) { $manifest.InstallPath }
        else { $null }
    if (-not $gameRoot -or -not (Test-Path -LiteralPath $gameRoot)) {
        Write-Host ("{0}: install directory not found" -f $entry.id)
        exit 2
    }

    Write-Host ("Inventorying {0} -> {1}" -f $entry.id, $gameRoot)
    $profilePaths = @($profile.binaries | ForEach-Object { ([string]$_.path).Replace('/', '\') })
    $files = @(Get-ChildItem -LiteralPath $gameRoot -Recurse -File -Force -ErrorAction SilentlyContinue)
    $records = New-Object System.Collections.Generic.List[object]
    $totalBytes = 0L
    $skipped = 0
    $index = 0

    foreach ($file in $files) {
        $index++
        $relative = $file.FullName.Substring($gameRoot.Length).TrimStart('\', '/').Replace('\', '/')
        $class = Get-FileClass -Name $file.Name
        $totalBytes += $file.Length

        if ($records.Count -ge $MaxFiles) { $skipped++; continue }

        $record = [ordered]@{
            path      = $relative
            class     = $class
            sizeBytes = $file.Length
        }

        $isProfileBinary = $profilePaths -contains $relative.Replace('/', '\')
        $shouldHash = $isProfileBinary -or ($HashAll -and -not $SkipHash) -or (-not $SkipHash -and ($class -eq 'executable' -or $class -eq 'library') -and $file.Length -le 32MB)
        if ($shouldHash) {
            $record['sha256'] = Get-FileSha256 -Path $file.FullName
        }

        if ($class -eq 'executable' -or $class -eq 'library') {
            if ($file.Length -le 64MB) {
                try {
                    $pe = Read-PeFile -Path $file.FullName
                    $record['pe'] = [ordered]@{
                        architecture     = $pe.Machine
                        subsystem        = $pe.Subsystem
                        linkTimestampUtc = $pe.LinkTimestampUtc
                        steamDrmBind     = $pe.HasBindSection
                        importedModules  = @($pe.ImportedModules | Select-Object -First 24)
                    }
                } catch {
                    $record['peError'] = $_.Exception.Message
                }
            } else {
                $record['peSkipped'] = 'larger than 64 MB'
            }
            try {
                $endpoints = @(Get-EndpointStrings -Path $file.FullName)
                if ($endpoints.Count -gt 0) { $record['endpoints'] = $endpoints }
            } catch {
                $record['endpointError'] = $_.Exception.Message
            }
        }

        if ($isProfileBinary) { $record['profileBinary'] = $true }
        $records.Add([pscustomobject]$record)

        if ($index % 500 -eq 0) { Write-Progress -Activity 'Inventory' -Status $relative -PercentComplete (($index / [Math]::Max($files.Count, 1)) * 100) }
    }
    Write-Progress -Activity 'Inventory' -Completed

    $archiveRecords = @($records | Where-Object { $_.class -eq 'archive' })
    $summary = [ordered]@{
        fileCount       = @($files).Count
        recordedFiles   = $records.Count
        skippedFiles    = $skipped
        totalBytes      = $totalBytes
        executables     = @($records | Where-Object { $_.class -eq 'executable' } | ForEach-Object { $_.path })
        libraries       = @($records | Where-Object { $_.class -eq 'library' } | ForEach-Object { $_.path })
        archives        = @($archiveRecords).Count
        archiveBytes    = if (@($archiveRecords).Count -gt 0) { ($archiveRecords | Measure-Object -Property sizeBytes -Sum).Sum } else { 0 }
        endpointsFound  = @($records | Where-Object { $_.PSObject.Properties.Name -contains 'endpoints' } | ForEach-Object { $_.endpoints } | Sort-Object -Unique)
    }

    $report = [ordered]@{
        schemaVersion = 1
        generatedUtc  = (Get-Date).ToUniversalTime().ToString('u')
        gameId        = $entry.id
        gameRoot   = $gameRoot
        steam         = [ordered]@{
            appId      = [int]$entry.steamAppId
            buildId    = if ($manifest) { $manifest.BuildId } else { $null }
            stateFlags = if ($manifest) { $manifest.StateFlags } else { $null }
        }
        summary       = $summary
        files         = $records
    }

    if (-not (Test-Path -LiteralPath $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null }
    $outputPath = Join-Path $OutputDirectory ($entry.id + '.json')
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $outputPath -Encoding UTF8

    Write-Host ("  files {0} ({1:N2} GiB), archives {2}, endpoints {3}" -f $summary.fileCount, ($totalBytes / 1GB), $summary.archives, @($summary.endpointsFound).Count)
    Write-Host ("  written {0}" -f $outputPath)
    $reports.Add([pscustomobject]@{ gameId = $entry.id; outputPath = $outputPath; summary = $summary })
}

exit 0

#Requires -Version 5.1
<#
.SYNOPSIS
    Automated tests for the Telltale Legacy tooling.

.DESCRIPTION
    Exercises the backup/restore round trip, tamper detection, restore safety
    behaviour, profile validity and the readiness auditor's failure mode. Tests use
    synthetic per-user data in a temporary directory and never touch real saves or
    the game installation.

    Run: powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-Tests.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$tools = Join-Path $repoRoot 'tools'
$script:passed = 0
$script:failed = 0
$script:failures = New-Object System.Collections.Generic.List[string]

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:passed++
        Write-Host ("  PASS  {0}" -f $Name) -ForegroundColor Green
    } catch {
        $script:failed++
        $script:failures.Add(("{0}: {1}" -f $Name, $_.Exception.Message))
        Write-Host ("  FAIL  {0} -- {1}" -f $Name, $_.Exception.Message) -ForegroundColor Red
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { throw ("{0} (expected '{1}', got '{2}')" -f $Message, $Expected, $Actual) }
}

function Invoke-Script {
    param([string]$ScriptPath, [string[]]$ScriptArguments = @())
    # Call through the call operator: it quotes arguments (temporary paths contain
    # spaces) and exposes the child exit code through $LASTEXITCODE.
    $previousPreference = $ErrorActionPreference
    try {
        # Redirecting stderr from a native command raises NativeCommandError when
        # ErrorActionPreference is Stop, which would hide the real exit code.
        $ErrorActionPreference = 'Continue'
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @ScriptArguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    [pscustomobject]@{
        ExitCode = $exitCode
        StdOut   = ($output | Out-String)
        StdErr   = (($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) | Out-String)
    }
}

$script:sandbox = Join-Path $env:TEMP ("telltale-legacy-tests-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:sandbox -Force | Out-Null

try {
    # ---------------------------------------------------------------- fixtures
    $saveRoot = Join-Path $script:sandbox 'Documents\Telltale Games'
    $gameData = Join-Path $saveRoot 'The Walking Dead'
    New-Item -ItemType Directory -Path $gameData -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $gameData 'prefs.prop') -Value 'prefs-fixture' -NoNewline
    Set-Content -LiteralPath (Join-Path $gameData 'Lee - 01.save') -Value ('save-fixture-' * 40) -NoNewline
    $nested = Join-Path $gameData 'slot0'
    New-Item -ItemType Directory -Path $nested -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $nested 'meta.prop') -Value 'nested-fixture' -NoNewline

    $backupRoot = Join-Path $script:sandbox 'backups'
    $emptyGameRoot = Join-Path $script:sandbox 'no-game-here'
    New-Item -ItemType Directory -Path $emptyGameRoot -Force | Out-Null

    Write-Host ''
    Write-Host 'Profile and data integrity'
    Test-Case 'Compatibility profile is valid JSON with required fields' {
        $profilePath = Join-Path $repoRoot 'profiles\twd-s1-steam-207610\profile.json'
        Assert-True (Test-Path -LiteralPath $profilePath) 'profile.json missing'
        $p = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
        Assert-Equal 1 $p.schemaVersion 'schemaVersion'
        Assert-Equal 207610 $p.steamAppId 'steamAppId'
        Assert-True ($p.knownGoodHashes.PSObject.Properties.Name -contains 'WalkingDead101.exe') 'missing exe hash'
        Assert-True ($null -ne $p.content.episodeDirectories) 'missing episode map'
    }

    Test-Case 'Recorded inventory schema is well formed' {
        $inventoryPath = Join-Path $repoRoot 'docs\rea\data\inventory.json'
        if (-not (Test-Path -LiteralPath $inventoryPath)) { return }  # inventory is optional until generated
        $inv = Get-Content -LiteralPath $inventoryPath -Raw | ConvertFrom-Json
        Assert-Equal 1 $inv.schemaVersion 'schemaVersion'
        Assert-True ($inv.Files.Count -gt 0) 'no files recorded'
        Assert-True (($inv.Files | Where-Object { $_.Kind -eq 'archive' }).Count -gt 0) 'no archives recorded'
    }

    Write-Host ''
    Write-Host 'Backup and restore'

    $backupResult = Invoke-Script -ScriptPath (Join-Path $tools 'Backup-GameProfile.ps1') -ScriptArguments @(
        '-SaveRoot', $saveRoot, '-Destination', $backupRoot, '-Label', 'test', '-GameRoot', $emptyGameRoot
    )
    $backupDir = Get-ChildItem -LiteralPath $backupRoot -Directory | Sort-Object Name | Select-Object -Last 1
    $backupPath = if ($backupDir) { $backupDir.FullName } else { '' }
    $manifestPath = Join-Path $backupPath 'manifest.json'

    Test-Case 'Backup succeeds and records every file with a hash' {
        Assert-Equal 0 $backupResult.ExitCode ("backup exit code: " + $backupResult.StdErr)
        Assert-True (Test-Path -LiteralPath $manifestPath) 'manifest not written'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        Assert-Equal 3 $manifest.FileCount 'file count'
        Assert-Equal 3 @($manifest.Files).Count 'manifest entries'
        foreach ($entry in $manifest.Files) {
            $copied = Join-Path (Join-Path $backupPath 'saves') $entry.RelativePath
            Assert-True (Test-Path -LiteralPath $copied) "missing copied file: $($entry.RelativePath)"
            Assert-Equal (Get-FileHash -LiteralPath $copied -Algorithm SHA256).Hash $entry.Sha256 "hash mismatch: $($entry.RelativePath)"
        }
    }

    Test-Case 'Restore into an empty location reproduces the backup byte for byte' {
        $target = Join-Path $script:sandbox 'restore-target'
        $result = Invoke-Script -ScriptPath (Join-Path $tools 'Restore-GameProfile.ps1') -ScriptArguments @(
            '-BackupPath', $backupPath, '-SaveRoot', $target
        )
        Assert-Equal 0 $result.ExitCode ("restore exit code: " + $result.StdErr)
        $sourceFile = Join-Path $saveRoot 'The Walking Dead\Lee - 01.save'
        $restoredFile = Join-Path $target 'The Walking Dead\Lee - 01.save'
        Assert-True (Test-Path -LiteralPath $restoredFile) 'save file not restored'
        Assert-Equal (Get-FileHash -LiteralPath $sourceFile -Algorithm SHA256).Hash (Get-FileHash -LiteralPath $restoredFile -Algorithm SHA256).Hash 'restored hash'
        Assert-True (Test-Path -LiteralPath (Join-Path $target 'The Walking Dead\slot0\meta.prop')) 'nested file not restored'
    }

    Test-Case 'Restore refuses a non-empty destination without -Force' {
        $target = Join-Path $script:sandbox 'restore-occupied'
        New-Item -ItemType Directory -Path (Join-Path $target 'The Walking Dead') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $target 'The Walking Dead\keep.me') -Value 'do-not-lose' -NoNewline
        $result = Invoke-Script -ScriptPath (Join-Path $tools 'Restore-GameProfile.ps1') -ScriptArguments @(
            '-BackupPath', $backupPath, '-SaveRoot', $target
        )
        Assert-True ($result.ExitCode -ne 0) 'restore should have failed'
        Assert-True (Test-Path -LiteralPath (Join-Path $target 'The Walking Dead\keep.me')) 'existing data was disturbed'
    }

    Test-Case 'Restore -Force preserves existing data in a pre-restore directory' {
        $target = Join-Path $script:sandbox 'restore-occupied'
        $result = Invoke-Script -ScriptPath (Join-Path $tools 'Restore-GameProfile.ps1') -ScriptArguments @(
            '-BackupPath', $backupPath, '-SaveRoot', $target, '-Force'
        )
        Assert-Equal 0 $result.ExitCode ("restore -Force exit code: " + $result.StdErr)
        $preRestore = @(Get-ChildItem -LiteralPath $script:sandbox -Directory -Filter 'restore-occupied.pre-restore-*')
        Assert-True ($preRestore.Count -ge 1) 'no pre-restore directory created'
        $preserved = Join-Path $preRestore[0].FullName 'The Walking Dead\keep.me'
        Assert-True (Test-Path -LiteralPath $preserved) 'pre-restore copy missing'
        Assert-Equal 'do-not-lose' (Get-Content -LiteralPath $preserved -Raw) 'pre-restore content'
    }

    Test-Case 'Tampered backup is rejected before anything is written' {
        $tamperBackup = Join-Path $script:sandbox 'backups\tampered'
        Copy-Item -LiteralPath $backupPath -Destination $tamperBackup -Recurse -Force
        $payload = Join-Path $tamperBackup 'saves\The Walking Dead\Lee - 01.save'
        [System.IO.File]::AppendAllText($payload, 'tampered')
        $target = Join-Path $script:sandbox 'tamper-target'
        $result = Invoke-Script -ScriptPath (Join-Path $tools 'Restore-GameProfile.ps1') -ScriptArguments @(
            '-BackupPath', $tamperBackup, '-SaveRoot', $target
        )
        Assert-Equal 2 $result.ExitCode ("expected integrity failure exit 2, stderr: " + $result.StdErr)
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $target 'The Walking Dead'))) 'files were written despite tampering'
    }

    Write-Host ''
    Write-Host 'Audit tooling'

    Test-Case 'Offline probe reports status as JSON' {
        $result = Invoke-Script -ScriptPath (Join-Path $tools 'Invoke-OfflineProbe.ps1') -ScriptArguments @('-Action', 'Status')
        Assert-Equal 0 $result.ExitCode ("status exit code: " + $result.StdErr)
        $status = $result.StdOut | ConvertFrom-Json
        Assert-True ($status.PSObject.Properties.Name -contains 'Blocked') 'missing Blocked property'
        Assert-True ($status.ResolvesTo.Count -ge 1) 'missing resolution report'
    }

    Test-Case 'Readiness audit fails closed on a missing installation' {
        $reportPath = Join-Path $script:sandbox 'readiness.json'
        $result = Invoke-Script -ScriptPath (Join-Path $tools 'Test-OfflineReadiness.ps1') -ScriptArguments @(
            '-GameRoot', (Join-Path $script:sandbox 'absent-game'), '-OutputPath', $reportPath
        )
        Assert-Equal 2 $result.ExitCode ("expected exit 2, stderr: " + $result.StdErr)
    }
    # ------------------------------------------------------- M2 save evidence
    function New-FixtureArtifact {
        param([string]$Path, [string]$Magic, [uint32]$DeclaredSize, [byte[]]$Payload)
        $headerLength = 56
        $bytes = New-Object byte[] ($headerLength + $Payload.Length)
        for ($i = 0; $i -lt 4; $i++) { $bytes[$i] = [Convert]::ToByte($Magic.Substring($i * 2, 2), 16) }
        $sizeBytes = [BitConverter]::GetBytes($DeclaredSize)
        [Array]::Copy($sizeBytes, 0, $bytes, 4, 4)
        [Array]::Copy($Payload, 0, $bytes, $headerLength, $Payload.Length)
        [System.IO.File]::WriteAllBytes($Path, $bytes)
    }

    $payload = New-Object byte[] 300
    for ($i = 0; $i -lt $payload.Length; $i++) { $payload[$i] = [byte](($i * 37 + 11) % 256) }

    $artifactRoot = Join-Path $script:sandbox 'artifacts'
    New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null
    New-FixtureArtifact -Path (Join-Path $artifactRoot 'save_2.save') -Magic 'bbdeaf64' -DeclaredSize 4096 -Payload $payload
    New-FixtureArtifact -Path (Join-Path $artifactRoot 'prefs.prop') -Magic 'aadeaf64' -DeclaredSize 900 -Payload $payload
    $artifactReport = Join-Path $script:sandbox 'save-artifacts.json'

    Write-Host ''
    Write-Host 'Save artefacts'

    Test-Case 'Save artefact parser reads magic, slot, declared size and hash' {
        $result = Invoke-Script -ScriptPath (Join-Path $tools 'Get-SaveArtifacts.ps1') -ScriptArguments @(
            '-SaveRoot', $artifactRoot, '-OutputPath', $artifactReport
        )
        Assert-Equal 0 $result.ExitCode ("artifacts exit code: " + $result.StdErr)
        $report = Get-Content -LiteralPath $artifactReport -Raw | ConvertFrom-Json
        Assert-Equal 1 $report.SaveCount 'save count'
        Assert-Equal 1 $report.PropCount 'prop count'
        Assert-True $report.AllMagicValid 'magic should be recognised'
        $save = @($report.Artifacts | Where-Object { $_.Name -eq 'save_2.save' })[0]
        Assert-Equal 2 $save.Slot 'slot number'
        Assert-Equal 4096 $save.DeclaredSize 'declared size field'
        Assert-Equal 'bbdeaf64' $save.Magic 'magic value'
        Assert-Equal 64 $save.Sha256.Length 'sha256 length'
        Assert-Equal 1 $report.DistinctHeaderBlocks 'fixture header blocks'
    }

    Test-Case 'Truncated and mislabelled artefacts are reported, not silently accepted' {
        $edgeRoot = Join-Path $script:sandbox 'artifacts-edge'
        New-Item -ItemType Directory -Path $edgeRoot -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $edgeRoot 'save_9.save'), ([byte[]](0xbb, 0xde, 0xaf, 0x64, 0x00, 0x01)))
        [System.IO.File]::WriteAllBytes((Join-Path $edgeRoot 'prefs.prop'), (New-Object byte[] 80))
        $edgeReport = Join-Path $script:sandbox 'save-artifacts-edge.json'
        $result = Invoke-Script -ScriptPath (Join-Path $tools 'Get-SaveArtifacts.ps1') -ScriptArguments @(
            '-SaveRoot', $edgeRoot, '-OutputPath', $edgeReport
        )
        Assert-Equal 0 $result.ExitCode ("parser should tolerate bad input: " + $result.StdErr)
        $report = Get-Content -LiteralPath $edgeReport -Raw | ConvertFrom-Json
        Assert-True (-not $report.AllMagicValid) 'all-zero prop magic should not validate'
        $truncated = @($report.Artifacts | Where-Object { $_.Name -eq 'save_9.save' })[0]
        Assert-True ($null -eq $truncated.DeclaredSize) 'six-byte file cannot carry a size field'
        Assert-Equal 6 $truncated.SizeBytes 'truncated length'
    }

    Test-Case 'Save inspector refuses to write inside the save root' {
        $result = Invoke-Script -ScriptPath (Join-Path $tools 'Get-SaveArtifacts.ps1') -ScriptArguments @(
            '-SaveRoot', $artifactRoot, '-OutputPath', (Join-Path $artifactRoot 'report.json')
        )
        Assert-Equal 2 $result.ExitCode 'expected refusal exit 2'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $artifactRoot 'report.json'))) 'report was written anyway'
    }

    Test-Case 'Drift mode reports an unchanged save set as identical' {
        $result = Invoke-Script -ScriptPath (Join-Path $tools 'Get-SaveArtifacts.ps1') -ScriptArguments @(
            '-SaveRoot', $artifactRoot, '-BaselinePath', $artifactReport, '-BaselineOutputPath', (Join-Path $script:sandbox 'drift-none.json')
        )
        Assert-Equal 0 $result.ExitCode ("drift exit code: " + $result.StdOut + $result.StdErr)
        $drift = Get-Content -LiteralPath (Join-Path $script:sandbox 'drift-none.json') -Raw | ConvertFrom-Json
        Assert-True $drift.Unchanged 'save set should be unchanged'
        Assert-Equal 0 @($drift.Changed).Count 'changed count'
    }

    Test-Case 'Drift mode detects a rewritten prefs.prop' {
        $driftRoot = Join-Path $script:sandbox 'artifacts-drift'
        Copy-Item -LiteralPath $artifactRoot -Destination $driftRoot -Recurse -Force
        $baselineReport = Join-Path $script:sandbox 'save-artifacts-drift-base.json'
        $null = Invoke-Script -ScriptPath (Join-Path $tools 'Get-SaveArtifacts.ps1') -ScriptArguments @(
            '-SaveRoot', $driftRoot, '-OutputPath', $baselineReport
        )
        [System.IO.File]::AppendAllText((Join-Path $driftRoot 'prefs.prop'), 'rewritten')
        $driftOut = Join-Path $script:sandbox 'drift-changed.json'
        $result = Invoke-Script -ScriptPath (Join-Path $tools 'Get-SaveArtifacts.ps1') -ScriptArguments @(
            '-SaveRoot', $driftRoot, '-BaselinePath', $baselineReport, '-BaselineOutputPath', $driftOut
        )
        Assert-Equal 3 $result.ExitCode ("expected drift exit 3, got: " + $result.StdErr)
        $drift = Get-Content -LiteralPath $driftOut -Raw | ConvertFrom-Json
        Assert-True (-not $drift.Unchanged) 'drift should be reported'
        Assert-True (@($drift.Changed) -contains 'prefs.prop') 'prefs.prop should be listed as changed'
    }

    Test-Case 'Divergent saves are reported with exact differing offsets' {
        $diffRoot = Join-Path $script:sandbox 'diff'
        New-Item -ItemType Directory -Path $diffRoot -Force | Out-Null
        $first = New-Object byte[] 400
        for ($i = 0; $i -lt $first.Length; $i++) { $first[$i] = [byte]($i % 251) }
        $second = [byte[]]$first.Clone()
        $second[60] = 0x01
        $second[61] = 0xFF
        [System.IO.File]::WriteAllBytes((Join-Path $diffRoot 'a.save'), $first)
        [System.IO.File]::WriteAllBytes((Join-Path $diffRoot 'b.save'), $second)
        $diffOut = Join-Path $script:sandbox 'diff.json'
        $result = Invoke-Script -ScriptPath (Join-Path $tools 'Get-SaveArtifacts.ps1') -ScriptArguments @(
            '-CompareA', (Join-Path $diffRoot 'a.save'), '-CompareB', (Join-Path $diffRoot 'b.save'),
            '-CompareOutputPath', $diffOut
        )
        Assert-Equal 0 $result.ExitCode ("diff exit code: " + $result.StdErr)
        $diff = Get-Content -LiteralPath $diffOut -Raw | ConvertFrom-Json
        Assert-True (-not $diff.Identical) 'files should differ'
        Assert-Equal 2 $diff.DifferingBytes 'differing byte count'
        Assert-Equal 60 $diff.FirstDiffOffset 'first differing offset'
        Assert-Equal 61 $diff.LastDiffOffset 'last differing offset'
        Assert-Equal 60 $diff.CommonPrefixBytes 'common prefix length'
    }

    Test-Case 'Identical saves compare as identical' {
        $diffRoot = Join-Path $script:sandbox 'diff'
        Copy-Item -LiteralPath (Join-Path $diffRoot 'a.save') -Destination (Join-Path $diffRoot 'a-copy.save') -Force
        $diffOut = Join-Path $script:sandbox 'diff-same.json'
        $result = Invoke-Script -ScriptPath (Join-Path $tools 'Get-SaveArtifacts.ps1') -ScriptArguments @(
            '-CompareA', (Join-Path $diffRoot 'a.save'), '-CompareB', (Join-Path $diffRoot 'a-copy.save'),
            '-CompareOutputPath', $diffOut
        )
        Assert-Equal 0 $result.ExitCode ("diff exit code: " + $result.StdErr)
        $diff = Get-Content -LiteralPath $diffOut -Raw | ConvertFrom-Json
        Assert-True $diff.Identical 'identical copies should match'
        Assert-Equal 0 $diff.DifferingBytes 'no differing bytes'
    }

    Test-Case 'Restored save and prefs match the backup hashes' {
        $target = Join-Path $script:sandbox 'restore-save-hashes'
        $result = Invoke-Script -ScriptPath (Join-Path $tools 'Restore-GameProfile.ps1') -ScriptArguments @(
            '-BackupPath', $backupPath, '-SaveRoot', $target
        )
        Assert-Equal 0 $result.ExitCode ("restore exit code: " + $result.StdErr)
        foreach ($relative in @('The Walking Dead\prefs.prop', 'The Walking Dead\Lee - 01.save')) {
            $source = Join-Path $saveRoot $relative
            $restored = Join-Path $target $relative
            Assert-True (Test-Path -LiteralPath $restored) "missing restored file: $relative"
            Assert-Equal (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash (Get-FileHash -LiteralPath $restored -Algorithm SHA256).Hash "hash mismatch: $relative"
        }
    }

    Write-Host ''
    Write-Host 'Content packs'

    $packRoot = Join-Path $script:sandbox 'episode-packs'
    $profileObj = Get-Content -LiteralPath (Join-Path $repoRoot 'profiles\twd-s1-steam-207610\profile.json') -Raw | ConvertFrom-Json
    $episodeNames = @($profileObj.content.episodeDirectories.PSObject.Properties.Name)
    foreach ($name in $episodeNames) {
        $directory = Join-Path $packRoot (Join-Path 'Pack' $name)
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $directory 'content.ttarch') -Value 'archive-fixture' -NoNewline
    }

    Test-Case 'Content pack validator accepts a complete episode map' {
        $result = Invoke-Script -ScriptPath (Join-Path $tools 'Test-ContentPacks.ps1') -ScriptArguments @(
            '-GameRoot', $packRoot, '-ProfilePath', (Join-Path $repoRoot 'profiles\twd-s1-steam-207610\profile.json'),
            '-OutputPath', (Join-Path $script:sandbox 'packs-ok.json')
        )
        Assert-Equal 0 $result.ExitCode ("packs exit code: " + $result.StdErr)
        $report = Get-Content -LiteralPath (Join-Path $script:sandbox 'packs-ok.json') -Raw | ConvertFrom-Json
        Assert-Equal $episodeNames.Count $report.EpisodeCount 'episode count'
        Assert-True $report.AllPresent 'every episode should be present'
    }

    Test-Case 'Content pack validator fails when an episode pack is missing' {
        $missing = Join-Path $packRoot (Join-Path 'Pack' $episodeNames[-1])
        Remove-Item -LiteralPath $missing -Recurse -Force
        $result = Invoke-Script -ScriptPath (Join-Path $tools 'Test-ContentPacks.ps1') -ScriptArguments @(
            '-GameRoot', $packRoot, '-ProfilePath', (Join-Path $repoRoot 'profiles\twd-s1-steam-207610\profile.json')
        )
        Assert-Equal 2 $result.ExitCode 'expected missing-pack exit 2'
    }

    Write-Host ''
    Write-Host 'Network probe fixture'

    Test-Case 'Offline probe parses a fixture hosts file without touching DNS' {
        $hostsFixture = Join-Path $script:sandbox 'hosts-blocked.txt'
        $blockedLines = @(
            '# >>> telltale-legacy offline probe >>>',
            "127.0.0.1`tapi.telltalegames.com",
            '# <<< telltale-legacy offline probe <<<'
        )
        Set-Content -LiteralPath $hostsFixture -Value ($blockedLines -join "`r`n")
        $result = Invoke-Script -ScriptPath (Join-Path $tools 'Invoke-OfflineProbe.ps1') -ScriptArguments @(
            '-Action', 'Status', '-HostsPath', $hostsFixture
        )
        Assert-Equal 0 $result.ExitCode ("probe exit code: " + $result.StdErr)
        $status = $result.StdOut | ConvertFrom-Json
        Assert-True $status.Blocked 'block should be detected'
        Assert-True (@($status.BlockedDomains) -contains 'api.telltalegames.com') 'blocked domain should be listed'
        Assert-Equal '127.0.0.1' @($status.ResolvesTo)[0].Addresses 'fixture address'
    }

    Test-Case 'Offline probe reports an unblocked fixture as clean' {
        $hostsFixture = Join-Path $script:sandbox 'hosts-clean.txt'
        Set-Content -LiteralPath $hostsFixture -Value "# normal hosts file`r`n127.0.0.1 localhost"
        $result = Invoke-Script -ScriptPath (Join-Path $tools 'Invoke-OfflineProbe.ps1') -ScriptArguments @(
            '-Action', 'Status', '-HostsPath', $hostsFixture
        )
        Assert-Equal 0 $result.ExitCode ("probe exit code: " + $result.StdErr)
        $status = $result.StdOut | ConvertFrom-Json
        Assert-True (-not $status.Blocked) 'clean hosts file should not report a block'
    }

    Test-Case 'Verification scenarios separate automated from attended evidence' {
        $scenarioPath = Join-Path $repoRoot 'docs\verification-scenarios.json'
        Assert-True (Test-Path -LiteralPath $scenarioPath) 'verification-scenarios.json missing'
        $scenarios = Get-Content -LiteralPath $scenarioPath -Raw | ConvertFrom-Json
        Assert-Equal 1 $scenarios.schemaVersion 'schemaVersion'
        Assert-True (@($scenarios.scenarios).Count -ge 10) 'expected the M1 and M2 scenarios'
        $modes = @($scenarios.scenarios | ForEach-Object { $_.mode } | Select-Object -Unique)
        foreach ($mode in $modes) { Assert-True ($mode -eq 'automated' -or $mode -eq 'manual-attended') "unexpected mode: $mode" }
        Assert-True (@($scenarios.scenarios | Where-Object { $_.mode -eq 'automated' }).Count -ge 5) 'expected automated scenarios'
        Assert-True (@($scenarios.scenarios | Where-Object { $_.mode -eq 'manual-attended' }).Count -ge 4) 'expected attended scenarios'
        $ids = @($scenarios.scenarios | ForEach-Object { $_.id })
        Assert-Equal $ids.Count (@($ids | Select-Object -Unique).Count) 'scenario ids must be unique'
    }
    Write-Host ''
    Write-Host 'Progression chronology'

    $progressRoot = Join-Path $script:sandbox 'progress'
    New-Item -ItemType Directory -Path $progressRoot -Force | Out-Null
    $progressPayload = New-Object byte[] 120
    for ($i = 0; $i -lt $progressPayload.Length; $i++) { $progressPayload[$i] = [byte](($i * 13 + 7) % 256) }
    $progressEpoch = [datetime]::new(2026, 11, 5, 10, 0, 0, [DateTimeKind]::Utc)
    foreach ($spec in @(
        @{ Name = 'save_1.save'; Minutes = 0 },
        @{ Name = 'save_6.save'; Minutes = 12 },
        @{ Name = 'prefs.prop'; Minutes = 24 })) {
        $path = Join-Path $progressRoot $spec.Name
        $magic = if ($spec.Name -eq 'prefs.prop') { 'aadeaf64' } else { 'bbdeaf64' }
        New-FixtureArtifact -Path $path -Magic $magic -DeclaredSize 2048 -Payload $progressPayload
        (Get-Item -LiteralPath $path).LastWriteTimeUtc = $progressEpoch.AddMinutes($spec.Minutes)
    }
    $progressReport = Join-Path $script:sandbox 'save-progress.json'

    Test-Case 'Progression orders saves by write time and reports the slot sequence' {
        $result = Invoke-Script -ScriptPath (Join-Path $tools 'Get-Progression.ps1') -ScriptArguments @(
            '-SaveRoot', $progressRoot, '-OutputPath', $progressReport
        )
        Assert-Equal 0 $result.ExitCode ("progress exit code: " + $result.StdErr)
        $report = Get-Content -LiteralPath $progressReport -Raw | ConvertFrom-Json
        Assert-Equal 3 $report.EntryCount 'entry count'
        Assert-Equal 2 $report.SaveCount 'save count'
        Assert-Equal 2 $report.DistinctSlots 'distinct slots'
        Assert-Equal 'save_1.save' $report.Entries[0].Name 'first entry'
        Assert-Equal 'prefs.prop' $report.Entries[2].Name 'last entry'
        Assert-Equal 720 $report.Entries[1].SecondsSincePrevious 'second gap in seconds'
        Assert-Equal 1440 $report.SpanSeconds 'total span'
    }

    Test-Case 'Progression refuses to write its report inside the save root' {
        $result = Invoke-Script -ScriptPath (Join-Path $tools 'Get-Progression.ps1') -ScriptArguments @(
            '-SaveRoot', $progressRoot, '-OutputPath', (Join-Path $progressRoot 'progress.json')
        )
        Assert-Equal 2 $result.ExitCode 'must refuse to write inside the save root'
        Assert-True ($result.StdErr -like '*Refusing*') 'expected a refusal message'
    }

    Test-Case 'Progression drift is clean against an identical snapshot' {
        $result = Invoke-Script -ScriptPath (Join-Path $tools 'Get-Progression.ps1') -ScriptArguments @(
            '-SaveRoot', $progressRoot, '-OutputPath', $progressReport, '-BaselinePath', $progressReport
        )
        Assert-Equal 0 $result.ExitCode ("drift exit code: " + $result.StdErr)
        $report = Get-Content -LiteralPath $progressReport -Raw | ConvertFrom-Json
        Assert-True $report.Drift.Unchanged 'drift should report unchanged'
    }

    Test-Case 'Progression drift reports a modified save and exits 3' {
        $baselinePath = Join-Path $script:sandbox 'save-progress-baseline.json'
        Copy-Item -LiteralPath $progressReport -Destination $baselinePath -Force
        $changed = Join-Path $progressRoot 'save_6.save'
        $bytes = [System.IO.File]::ReadAllBytes($changed)
        $bytes[$bytes.Length - 1] = [byte](($bytes[$bytes.Length - 1] + 1) % 256)
        [System.IO.File]::WriteAllBytes($changed, $bytes)
        $result = Invoke-Script -ScriptPath (Join-Path $tools 'Get-Progression.ps1') -ScriptArguments @(
            '-SaveRoot', $progressRoot, '-OutputPath', $progressReport, '-BaselinePath', $baselinePath
        )
        Assert-Equal 3 $result.ExitCode 'drift must exit 3'
        $report = Get-Content -LiteralPath $progressReport -Raw | ConvertFrom-Json
        Assert-True (-not $report.Drift.Unchanged) 'drift should report a change'
        Assert-True (@($report.Drift.Changed) -contains 'save_6.save') 'changed save should be named'
    }

    Test-Case 'Watch mode writes start and end markers to the event log' {
        $watchRoot = Join-Path $script:sandbox 'watch-root'
        New-Item -ItemType Directory -Path $watchRoot -Force | Out-Null
        New-FixtureArtifact -Path (Join-Path $watchRoot 'save_1.save') -Magic 'bbdeaf64' -DeclaredSize 512 -Payload $progressPayload
        $eventLog = Join-Path $script:sandbox 'save-events.jsonl'
        $result = Invoke-Script -ScriptPath (Join-Path $tools 'Get-Progression.ps1') -ScriptArguments @(
            '-SaveRoot', $watchRoot, '-WatchSeconds', '2', '-PollMilliseconds', '400',
            '-EventLogPath', $eventLog, '-OutputPath', (Join-Path $script:sandbox 'watch-report.json')
        )
        Assert-Equal 0 $result.ExitCode ("watch exit code: " + $result.StdErr)
        $lines = @(Get-Content -LiteralPath $eventLog)
        Assert-True ($lines.Count -ge 2) 'expected watch-start and watch-end records'
        Assert-True (($lines[0] | ConvertFrom-Json).Kind -eq 'watch-start') 'first record should be watch-start'
        Assert-True ((($lines[$lines.Count - 1]) | ConvertFrom-Json).Kind -eq 'watch-end') 'last record should be watch-end'
    }

    Write-Host ''
    Write-Host 'Transition readiness'

    $readyGame = Join-Path $script:sandbox 'ready-game'
    New-Item -ItemType Directory -Path (Join-Path $readyGame 'Pack\default') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $readyGame 'Pack\WalkingDead102') -Force | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $readyGame 'Pack\default\0_base.ttarch'), (New-Object byte[] 8))
    foreach ($class in @('data', 'voice', 'ms', 'tx', 'mesh', 'anichore')) {
        $archiveName = '1_WalkingDead102_english_pc_{0}.ttarch' -f $class
        [System.IO.File]::WriteAllBytes((Join-Path $readyGame ('Pack\WalkingDead102\' + $archiveName)), (New-Object byte[] 8))
    }
    [System.IO.File]::WriteAllBytes((Join-Path $readyGame 'WalkingDead101.exe'), [byte[]](1, 2, 3, 4, 5, 6, 7, 8))
    $readyHash = (Get-FileHash -LiteralPath (Join-Path $readyGame 'WalkingDead101.exe') -Algorithm SHA256).Hash.ToLowerInvariant()
    $readyBackup = Join-Path $script:sandbox 'ready-backups'
    $readyBackupEntry = Join-Path $readyBackup '20261105-000000-test'
    New-Item -ItemType Directory -Path $readyBackupEntry -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $readyBackupEntry 'manifest.json') -Value '{"CreatedUtc":"2026-11-05 00:00:00Z","Files":[{"RelativePath":"save_2.save"}]}'
    $readyHosts = Join-Path $script:sandbox 'ready-hosts'
    Set-Content -LiteralPath $readyHosts -Value @(
        '# fixture hosts file',
        '# >>> telltale-legacy offline probe >>>',
        '127.0.0.1' + [char]9 + 'api.telltalegames.com',
        '127.0.0.1' + [char]9 + 'meta.telltalegames.com',
        '# <<< telltale-legacy offline probe <<<'
    )

    Test-Case 'Transition readiness is ready when content, block, backup and saves all check out' {
        $reportPath = Join-Path $script:sandbox 'transition-ready.json'
        $result = Invoke-Script -ScriptPath (Join-Path $tools 'Test-TransitionReadiness.ps1') -ScriptArguments @(
            '-GameRoot', $readyGame, '-SaveRoot', $artifactRoot, '-BackupRoot', $readyBackup,
            '-HostsPath', $readyHosts, '-ExpectedExeSha256', $readyHash, '-SkipProcessCheck', '-OutputPath', $reportPath
        )
        Assert-Equal 0 $result.ExitCode ("readiness exit code: " + $result.StdErr)
        $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
        Assert-Equal 'ready' $report.Verdict 'verdict'
        Assert-Equal 0 $report.FailCount 'fail count'
        $ep2 = @($report.Findings | Where-Object { $_.Id -eq 'episode-2-content' })[0]
        Assert-Equal 'pass' $ep2.Level 'episode 2 finding'
    }

    Test-Case 'Transition readiness fails when Episode 2 is missing an asset class' {
        $brokenGame = Join-Path $script:sandbox 'broken-game'
        New-Item -ItemType Directory -Path $brokenGame -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $brokenGame 'WalkingDead101.exe'), [byte[]](1, 2, 3, 4, 5, 6, 7, 8))
        New-Item -ItemType Directory -Path (Join-Path $brokenGame 'Pack\default') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $brokenGame 'Pack\WalkingDead102') -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $brokenGame 'Pack\default\0_base.ttarch'), (New-Object byte[] 8))
        foreach ($class in @('data', 'voice', 'ms', 'tx', 'anichore')) {
            $archiveName = '1_WalkingDead102_english_pc_{0}.ttarch' -f $class
            [System.IO.File]::WriteAllBytes((Join-Path $brokenGame ('Pack\WalkingDead102\' + $archiveName)), (New-Object byte[] 8))
        }
        $reportPath = Join-Path $script:sandbox 'transition-broken.json'
        $result = Invoke-Script -ScriptPath (Join-Path $tools 'Test-TransitionReadiness.ps1') -ScriptArguments @(
            '-GameRoot', $brokenGame, '-SaveRoot', $artifactRoot, '-BackupRoot', $readyBackup,
            '-HostsPath', $readyHosts, '-ExpectedExeSha256', $readyHash, '-SkipProcessCheck', '-OutputPath', $reportPath
        )
        Assert-Equal 2 $result.ExitCode 'readiness must fail closed'
        $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
        Assert-Equal 'not-ready' $report.Verdict 'verdict'
        $failure = @($report.Findings | Where-Object { $_.Id -eq 'episode-2-content' })[0]
        Assert-Equal 'fail' $failure.Level 'episode 2 finding'
        Assert-True ($failure.Detail -like '*mesh*') 'missing class should be named'
    }

    Test-Case 'Transition readiness fails when a publisher domain is not blocked' {
        $partialHosts = Join-Path $script:sandbox 'partial-hosts'
        Set-Content -LiteralPath $partialHosts -Value @(
            '# >>> telltale-legacy offline probe >>>',
            '127.0.0.1' + [char]9 + 'api.telltalegames.com',
            '# <<< telltale-legacy offline probe <<<'
        )
        $reportPath = Join-Path $script:sandbox 'transition-partial.json'
        $result = Invoke-Script -ScriptPath (Join-Path $tools 'Test-TransitionReadiness.ps1') -ScriptArguments @(
            '-GameRoot', $readyGame, '-SaveRoot', $artifactRoot, '-BackupRoot', $readyBackup,
            '-HostsPath', $partialHosts, '-ExpectedExeSha256', $readyHash, '-SkipProcessCheck', '-OutputPath', $reportPath
        )
        Assert-Equal 2 $result.ExitCode 'a missing domain must fail the gate'
        $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
        $failure = @($report.Findings | Where-Object { $_.Id -eq 'publisher-blocked' })[0]
        Assert-Equal 'fail' $failure.Level 'publisher block finding'
        Assert-True ($failure.Detail -like '*meta.telltalegames.com*') 'unblocked domain should be named'
    }

    Test-Case 'Offline probe refuses a comma-joined domain list' {
        $result = Invoke-Script -ScriptPath (Join-Path $tools 'Invoke-OfflineProbe.ps1') -ScriptArguments @(
            '-Action', 'Status', '-Domains', 'api.example,meta.example'
        )
        Assert-Equal 2 $result.ExitCode 'a comma-joined domain must be refused'
        Assert-True ($result.StdErr -like '*Invalid domain*') 'expected an invalid-domain message'
    }
    Write-Host ''
    Write-Host 'Audio endpoint probe'

    Test-Case 'Audio probe reports an unknown target endpoint as unavailable' {
        $result = Invoke-Script -ScriptPath (Join-Path $tools 'Get-AudioRoute.ps1') -ScriptArguments @(
            '-TargetName', 'no-such-endpoint-xyz', '-Samples', '1'
        )
        Assert-Equal 2 $result.ExitCode 'an unknown endpoint must exit 2'
        Assert-True ($result.StdErr -like '*no active render endpoint*') 'expected an unavailable-endpoint message'
    }

    Test-Case 'Audio probe resolves the configured endpoint by name when present' {
        $reportPath = Join-Path $script:sandbox 'audio-route.json'
        $result = Invoke-Script -ScriptPath (Join-Path $tools 'Get-AudioRoute.ps1') -ScriptArguments @(
            '-TargetName', '100027813', '-Samples', '1', '-OutputPath', $reportPath
        )
        # The endpoint is hardware-dependent: accept "present" (0) or "absent" (2),
        # but never a crash, and when present the report must be well formed.
        Assert-True ($result.ExitCode -eq 0 -or $result.ExitCode -eq 2) ("unexpected exit code: " + $result.StdErr)
        if ($result.ExitCode -eq 0) {
            Assert-True (Test-Path -LiteralPath $reportPath) 'report should be written'
            $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
            Assert-Equal '100027813' $report.TargetName 'target name'
            Assert-True ($report.TargetActiveCount -ge 1) 'target should have an active endpoint'
            Assert-True (@($report.Endpoints).Count -ge 1) 'expected at least one endpoint'
            $active = @($report.Endpoints | Where-Object { $_.State -eq 'active' })
            Assert-True ($active.Count -ge 1) 'expected an active endpoint entry'
        }
    }
}
finally {
    if (Test-Path -LiteralPath $script:sandbox) {
        Remove-Item -LiteralPath $script:sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:passed, $script:failed)
if ($script:failed -gt 0) {
    $script:failures | ForEach-Object { Write-Host ("  - {0}" -f $_) -ForegroundColor Red }
    exit 1
}
exit 0

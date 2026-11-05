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

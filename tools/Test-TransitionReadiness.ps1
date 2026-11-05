#Requires -Version 5.1
<#
.SYNOPSIS
    Pre-flight gate for an attended Episode 1 completion / transition session.

.DESCRIPTION
    Checks the conditions that must hold before a playthrough is used as M3 evidence:
    the installation still matches the profiled build, both episodes have their
    content, the publisher endpoints are actually blocked, a fresh backup exists,
    the game is not already running, the save set is readable and there is room to
    write. It changes nothing: every check is read-only.

    Exit 0 when no check failed, 2 when at least one failed. Warnings do not fail
    the gate but are printed so they can be resolved before playing.

.PARAMETER GameRoot
    Installation directory containing WalkingDead101.exe and Pack/.

.PARAMETER SaveRoot
    Per-user save directory.

.PARAMETER BackupRoot
    Directory holding timestamped backup folders. Defaults to <repo>/backups.

.PARAMETER HostsPath
    Hosts file to inspect. Defaults to the system hosts file.

.PARAMETER ExpectedExeSha256
    Expected executable hash. Empty string skips the hash comparison (warned).

.PARAMETER EpisodeOneDirectory
    Pack subdirectory holding Episode 1 content. Every episode folder except 2-5
    uses the name "default", so this is not "WalkingDead101".

.PARAMETER EpisodeTwoDirectory
    Pack subdirectory holding Episode 2 content.

.PARAMETER RequiredDomains
    Publisher domains that must be blocked for the run to count as offline.

.PARAMETER MinFreeGigabytes
    Minimum free space on the save volume.

.PARAMETER SkipProcessCheck
    Skip the "game not running" check (used by fixture tests).

.PARAMETER OutputPath
    JSON report path.
#>
param(
    [string]$GameRoot = 'C:\Program Files (x86)\Steam\steamapps\common\The Walking Dead',
    [string]$SaveRoot = (Join-Path $env:USERPROFILE (Join-Path 'Documents' (Join-Path 'Telltale Games' 'The Walking Dead'))),
    [string]$BackupRoot = '',
    [string]$HostsPath = '',
    [string]$OutputPath = 'docs/rea/data/transition-readiness.json',
    [string]$ExpectedExeSha256 = '44a5ff21cbb085812c48179259141ff5c83eaeaa3423b4734b43533df0a2528d',
    [string]$EpisodeOneDirectory = 'default',
    [string]$EpisodeTwoDirectory = 'WalkingDead102',
    [string[]]$RequiredDomains = @('api.telltalegames.com', 'meta.telltalegames.com'),
    [int]$MinFreeGigabytes = 1,
    [switch]$SkipProcessCheck
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $BackupRoot) { $BackupRoot = Join-Path $repoRoot 'backups' }
if (-not $HostsPath) { $HostsPath = Join-Path $env:WINDIR (Join-Path 'System32' (Join-Path 'drivers' (Join-Path 'etc' 'hosts'))) }

$findings = New-Object System.Collections.Generic.List[object]

function Add-Finding {
    param([string]$Id, [string]$Level, [string]$Detail)
    $findings.Add([pscustomobject]@{ Id = $Id; Level = $Level; Detail = $Detail })
}

function Get-FullPath {
    param([string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) {
        [System.IO.Path]::GetFullPath($Path)
    } else {
        [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
    }
}

$beginMarker = '# >>> telltale-legacy offline probe >>>'
$endMarker = '# <<< telltale-legacy offline probe <<<'

function Test-DomainBlocked {
    param([string]$HostsText, [string]$Domain)
    if (-not $HostsText -or -not $HostsText.Contains($beginMarker)) { return $false }
    $start = $HostsText.IndexOf($beginMarker, [StringComparison]::Ordinal)
    $end = $HostsText.IndexOf($endMarker, $start, [StringComparison]::Ordinal)
    if ($end -lt 0) { return $false }
    $segment = $HostsText.Substring($start, $end - $start)
    $pattern = '(?m)^\s*127\.0\.0\.1\s+' + [regex]::Escape($Domain) + '\s*$'
    [regex]::IsMatch($segment, $pattern)
}

# --- 1. Installation identity ------------------------------------------------
$exePath = Join-Path $GameRoot 'WalkingDead101.exe'
if (-not (Test-Path -LiteralPath $exePath)) {
    Add-Finding -Id 'install-executable' -Level 'fail' -Detail "Executable not found: $exePath"
} elseif (-not $ExpectedExeSha256) {
    Add-Finding -Id 'install-executable' -Level 'warn' -Detail 'No expected hash supplied; build identity not verified.'
} else {
    $actual = (Get-FileHash -LiteralPath $exePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -eq $ExpectedExeSha256.ToLowerInvariant()) {
        Add-Finding -Id 'install-executable' -Level 'pass' -Detail "Executable hash matches the profile ($($actual.Substring(0, 16))...)."
    } else {
        Add-Finding -Id 'install-executable' -Level 'fail' -Detail "Executable hash $($actual.Substring(0, 16))... does not match the profile."
    }
}

# --- 2. Episode content ------------------------------------------------------
$packRoot = Join-Path $GameRoot 'Pack'
$ep1Path = Join-Path $packRoot $EpisodeOneDirectory
if (-not (Test-Path -LiteralPath $ep1Path)) {
    Add-Finding -Id 'episode-1-content' -Level 'fail' -Detail "Episode 1 pack directory missing: $ep1Path"
} else {
    $ep1Archives = @(Get-ChildItem -LiteralPath $ep1Path -File -Filter '*.ttarch' -ErrorAction SilentlyContinue)
    if ($ep1Archives.Count -eq 0) {
        Add-Finding -Id 'episode-1-content' -Level 'fail' -Detail 'Episode 1 pack directory contains no .ttarch archives.'
    } else {
        Add-Finding -Id 'episode-1-content' -Level 'pass' -Detail ("Episode 1: {0} archive(s) in '{1}'." -f $ep1Archives.Count, $EpisodeOneDirectory)
    }
}

$ep2Path = Join-Path $packRoot $EpisodeTwoDirectory
if (-not (Test-Path -LiteralPath $ep2Path)) {
    Add-Finding -Id 'episode-2-content' -Level 'fail' -Detail "Episode 2 pack directory missing: $ep2Path"
} else {
    $ep2Archives = @(Get-ChildItem -LiteralPath $ep2Path -File -Filter '*.ttarch' -ErrorAction SilentlyContinue)
    $missing = @()
    foreach ($class in @('data', 'voice', 'ms', 'tx', 'mesh', 'anichore')) {
        # Archives are prefixed with a load-order index (1_..., 2_...), so match on suffix.
        $pattern = ('*_english_pc_{0}.ttarch' -f $class)
        if (-not ($ep2Archives | Where-Object { $_.Name -like $pattern })) { $missing += $class }
    }
    if ($ep2Archives.Count -eq 0) {
        Add-Finding -Id 'episode-2-content' -Level 'fail' -Detail 'Episode 2 pack directory contains no .ttarch archives.'
    } elseif ($missing.Count -gt 0) {
        Add-Finding -Id 'episode-2-content' -Level 'fail' -Detail ("Episode 2 is missing asset class(es): {0}" -f ($missing -join ', '))
    } else {
        Add-Finding -Id 'episode-2-content' -Level 'pass' -Detail ("Episode 2: {0} archive(s), all six asset classes present (data, voice, ms, tx, mesh, anichore)." -f $ep2Archives.Count)
    }
}

# --- 3. Publisher endpoints blocked -----------------------------------------
if (-not (Test-Path -LiteralPath $HostsPath)) {
    Add-Finding -Id 'publisher-blocked' -Level 'fail' -Detail "Hosts file not found: $HostsPath"
} else {
    $hostsText = Get-Content -LiteralPath $HostsPath -Raw
    $unblocked = @()
    foreach ($domain in $RequiredDomains) {
        if (-not (Test-DomainBlocked -HostsText $hostsText -Domain $domain)) { $unblocked += $domain }
    }
    if ($unblocked.Count -gt 0) {
        Add-Finding -Id 'publisher-blocked' -Level 'fail' -Detail ("Not blocked: {0}. Run Invoke-OfflineProbe.ps1 -Action Block with both domains." -f ($unblocked -join ', '))
    } else {
        Add-Finding -Id 'publisher-blocked' -Level 'pass' -Detail ("Blocked via marked hosts entry: {0}" -f ($RequiredDomains -join ', '))
    }
}

# --- 4. Fresh backup ---------------------------------------------------------
if (-not (Test-Path -LiteralPath $BackupRoot)) {
    Add-Finding -Id 'save-backup' -Level 'fail' -Detail "Backup root not found: $BackupRoot"
} else {
    $candidates = @(Get-ChildItem -LiteralPath $BackupRoot -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)
    $found = $null
    foreach ($candidate in $candidates) {
        $manifestPath = Join-Path $candidate.FullName 'manifest.json'
        if (-not (Test-Path -LiteralPath $manifestPath)) { continue }
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $saveEntries = @(@($manifest.Files) | Where-Object { $_.RelativePath -like '*.save' })
        if ($saveEntries.Count -gt 0) {
            $found = [pscustomobject]@{ Path = $candidate.FullName; Saves = $saveEntries.Count; Created = $manifest.CreatedUtc }
            break
        }
    }
    if (-not $found) {
        Add-Finding -Id 'save-backup' -Level 'fail' -Detail 'No backup directory with a manifest containing at least one save.'
    } else {
        Add-Finding -Id 'save-backup' -Level 'pass' -Detail ("Latest save backup: {0} ({1} save(s), {2})." -f (Split-Path -Leaf $found.Path), $found.Saves, $found.Created)
    }
}

# --- 5. Game not running -----------------------------------------------------
if (-not $SkipProcessCheck) {
    $running = @(Get-Process -Name 'WalkingDead101' -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        Add-Finding -Id 'game-not-running' -Level 'fail' -Detail ("Game is already running (PID {0}); close it before starting an observed session." -f (($running | ForEach-Object { $_.Id }) -join ', '))
    } else {
        Add-Finding -Id 'game-not-running' -Level 'pass' -Detail 'No game process running.'
    }
}

# --- 6. Save set readable ----------------------------------------------------
if (-not (Test-Path -LiteralPath $SaveRoot)) {
    Add-Finding -Id 'save-artifacts' -Level 'warn' -Detail "Save root not found: $SaveRoot (a first run would have none)."
} else {
    $saves = @(Get-ChildItem -LiteralPath $SaveRoot -File -Filter '*.save' -ErrorAction SilentlyContinue)
    if ($saves.Count -eq 0) {
        Add-Finding -Id 'save-artifacts' -Level 'warn' -Detail 'No .save files present yet.'
    } else {
        $bad = 0
        foreach ($save in $saves) {
            $bytes = [System.IO.File]::ReadAllBytes($save.FullName)
            $magic = if ($bytes.Length -ge 4) { ($bytes[0..3] | ForEach-Object { $_.ToString('x2') }) -join '' } else { '' }
            if ($magic -ne 'bbdeaf64') { $bad++ }
        }
        if ($bad -gt 0) {
            Add-Finding -Id 'save-artifacts' -Level 'fail' -Detail ("{0} of {1} save file(s) have an unrecognised magic value." -f $bad, $saves.Count)
        } else {
            Add-Finding -Id 'save-artifacts' -Level 'pass' -Detail ("{0} save file(s) present, all with the expected magic." -f $saves.Count)
        }
    }
}

# --- 7. Free space -----------------------------------------------------------
try {
    $volumeRoot = [System.IO.Path]::GetPathRoot((Get-FullPath $SaveRoot))
    $drive = New-Object System.IO.DriveInfo($volumeRoot)
    $freeGb = [Math]::Round($drive.AvailableFreeSpace / 1GB, 2)
    if ($freeGb -lt $MinFreeGigabytes) {
        Add-Finding -Id 'free-space' -Level 'fail' -Detail ("Only {0} GB free on {1}; at least {2} GB required." -f $freeGb, $volumeRoot, $MinFreeGigabytes)
    } else {
        Add-Finding -Id 'free-space' -Level 'pass' -Detail ("{0} GB free on {1}." -f $freeGb, $volumeRoot)
    }
} catch {
    Add-Finding -Id 'free-space' -Level 'warn' -Detail ("Could not determine free space: {0}" -f $_.Exception.Message)
}

# --- Report ------------------------------------------------------------------
$fails = @($findings | Where-Object { $_.Level -eq 'fail' })
$warns = @($findings | Where-Object { $_.Level -eq 'warn' })
$verdict = if ($fails.Count -eq 0) { 'ready' } else { 'not-ready' }

$report = [pscustomobject]@{
    SchemaVersion   = 1
    GeneratedUtc    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ssZ')
    Verdict         = $verdict
    FailCount       = $fails.Count
    WarnCount       = $warns.Count
    GameRoot        = Get-FullPath $GameRoot
    SaveRoot        = Get-FullPath $SaveRoot
    BackupRoot      = Get-FullPath $BackupRoot
    RequiredDomains = $RequiredDomains
    Findings        = $findings
    Notes           = @(
        'Read-only: no file, process or hosts entry is modified.',
        'A "ready" verdict means the conditions for an evidence-grade run hold, not that the transition has been tested.'
    )
}

$outFull = if ([System.IO.Path]::IsPathRooted($OutputPath)) {
    [System.IO.Path]::GetFullPath($OutputPath)
} else {
    [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $OutputPath))
}
$outDir = Split-Path -Parent $outFull
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $outFull -Encoding UTF8

foreach ($finding in $findings) {
    if ($finding.Level -eq 'pass') { continue }
    Write-Host ("[{0}] {1}: {2}" -f $finding.Level.ToUpperInvariant(), $finding.Id, $finding.Detail)
}
Write-Host ''
Write-Host ("Verdict: {0}  (fail={1}, warn={2})" -f $verdict, $fails.Count, $warns.Count)
Write-Host ("Report : {0}" -f $outFull)

if ($fails.Count -gt 0) { exit 2 }
exit 0

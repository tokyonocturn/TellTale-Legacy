#Requires -Version 5.1
<#
.SYNOPSIS
    Reports save progression in write order and can record save activity live.

.DESCRIPTION
    The game autosaves into rotating slots, so file times alone cannot reconstruct a
    playthrough: slots are reused and earlier writes are overwritten. This tool
    produces a chronological view of the current save set for a before/after
    comparison, and with -WatchSeconds it samples the save directory while someone
    plays and appends every observed change to a JSONL event log.

    Read-only with respect to the game: nothing inside the save root is written,
    renamed or deleted, and output paths inside the save root are refused.

.PARAMETER SaveRoot
    Directory holding save_<N>.save and prefs.prop.

.PARAMETER OutputPath
    JSON report path (progression snapshot).

.PARAMETER BaselinePath
    Optional earlier progression JSON; when given, drift is reported and exit 3
    signals that something changed.

.PARAMETER WatchSeconds
    Sample the save directory for this many seconds, appending events to
    -EventLogPath. 0 (default) only reports the snapshot.

.PARAMETER EventLogPath
    JSONL file for watch events. Defaults to docs/rea/data/save-events.jsonl

.PARAMETER PollMilliseconds
    Sampling interval for watch mode. Defaults to 2000.
#>
param(
    [string]$SaveRoot = (Join-Path $env:USERPROFILE (Join-Path 'Documents' (Join-Path 'Telltale Games' 'The Walking Dead'))),
    [string]$OutputPath = 'docs/rea/data/save-progress.json',
    [string]$BaselinePath = '',
    [int]$WatchSeconds = 0,
    [string]$EventLogPath = 'docs/rea/data/save-events.jsonl',
    [int]$PollMilliseconds = 2000
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$saveRootFull = if ([System.IO.Path]::IsPathRooted($SaveRoot)) {
    [System.IO.Path]::GetFullPath($SaveRoot)
} else {
    [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $SaveRoot))
}

function Resolve-OutputPath {
    param([string]$CandidatePath)
    $full = if ([System.IO.Path]::IsPathRooted($CandidatePath)) {
        [System.IO.Path]::GetFullPath($CandidatePath)
    } else {
        [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $CandidatePath))
    }
    if ($full.StartsWith($saveRootFull, [StringComparison]::OrdinalIgnoreCase)) {
        [Console]::Error.WriteLine("Refusing to write '$full' inside the game save root.")
        exit 2
    }
    $dir = Split-Path -Parent $full
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $full
}

function Get-Sha256 {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-SlotNumber {
    param([string]$Name)
    $match = [regex]::Match($Name, '^save_([0-9]+)[.]save$', 'IgnoreCase')
    if ($match.Success) { return [int]$match.Groups[1].Value }
    $null
}

function Get-ArtifactEntry {
    param([System.IO.FileInfo]$File)
    $bytes = [System.IO.File]::ReadAllBytes($File.FullName)
    $magic = if ($bytes.Length -ge 4) { ($bytes[0..3] | ForEach-Object { $_.ToString('x2') }) -join '' } else { '' }
    [pscustomobject]@{
        Name         = $File.Name
        Slot         = Get-SlotNumber -Name $File.Name
        SizeBytes    = $File.Length
        ModifiedUtc  = $File.LastWriteTimeUtc.ToString('yyyy-MM-dd HH:mm:ssZ')
        ModifiedSort = $File.LastWriteTimeUtc.Ticks
        Sha256       = Get-Sha256 -Path $File.FullName
        Magic        = $magic
        MagicValid   = ($magic -eq 'bbdeaf64' -or $magic -eq 'aadeaf64')
    }
}

function Get-Snapshot {
    if (-not (Test-Path -LiteralPath $saveRootFull)) {
        [Console]::Error.WriteLine("Save root not found: $saveRootFull")
        exit 2
    }
    $files = @(Get-ChildItem -LiteralPath $saveRootFull -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -eq '.save' -or $_.Extension -eq '.prop' })
    if ($files.Count -eq 0) {
        [Console]::Error.WriteLine("No .save or .prop artefacts found in $saveRootFull")
        exit 2
    }
    @($files | Sort-Object LastWriteTimeUtc | ForEach-Object { Get-ArtifactEntry -File $_ })
}

function Write-EventRecord {
    param([string]$Path, [string]$Kind, [string]$Name, [int64]$SizeBytes, [string]$Sha256)
    $record = [pscustomobject]@{
        ObservedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ssZ')
        Kind        = $Kind
        Name        = $Name
        SizeBytes   = $SizeBytes
        Sha256      = $Sha256
    }
    ($record | ConvertTo-Json -Compress) | Add-Content -LiteralPath $Path -Encoding UTF8
    if ($Kind -ne 'watch-start') {
        Write-Host ("  [{0}] {1,-6} {2} ({3} bytes)" -f $record.ObservedUtc, $Kind, $Name, $SizeBytes)
    }
}

# --- Live watch mode ---------------------------------------------------------
if ($WatchSeconds -gt 0) {
    $logFull = Resolve-OutputPath -CandidatePath $EventLogPath
    Write-Host ("Watching {0} for {1}s (poll {2}ms). Events -> {3}" -f $saveRootFull, $WatchSeconds, $PollMilliseconds, $logFull)

    $seen = @{}
    foreach ($entry in (Get-Snapshot)) {
        $seen[$entry.Name] = ('{0}|{1}|{2}' -f $entry.SizeBytes, $entry.ModifiedSort, $entry.Sha256)
    }
    Write-EventRecord -Path $logFull -Kind 'watch-start' -Name '' -SizeBytes 0 -Sha256 ''

    $deadline = (Get-Date).AddSeconds($WatchSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds $PollMilliseconds
        $current = Get-Snapshot
        foreach ($entry in $current) {
            $signature = '{0}|{1}|{2}' -f $entry.SizeBytes, $entry.ModifiedSort, $entry.Sha256
            $isNew = -not $seen.ContainsKey($entry.Name)
            if ($isNew -or $seen[$entry.Name] -ne $signature) {
                $kind = if ($isNew) { 'added' } else { 'modified' }
                Write-EventRecord -Path $logFull -Kind $kind -Name $entry.Name -SizeBytes $entry.SizeBytes -Sha256 $entry.Sha256
                $seen[$entry.Name] = $signature
            }
        }
        $present = @{}
        foreach ($entry in $current) { $present[$entry.Name] = $true }
        foreach ($name in @($seen.Keys)) {
            if (-not $present.ContainsKey($name)) {
                Write-EventRecord -Path $logFull -Kind 'removed' -Name $name -SizeBytes 0 -Sha256 ''
                $seen.Remove($name)
            }
        }
    }
    Write-EventRecord -Path $logFull -Kind 'watch-end' -Name '' -SizeBytes 0 -Sha256 ''
    Write-Host 'Watch finished.'
    exit 0
}

# --- Snapshot mode -----------------------------------------------------------
$entries = Get-Snapshot
$ordered = @()
$previousTicks = $null
foreach ($entry in $entries) {
    $delta = if ($null -ne $previousTicks) {
        [int][Math]::Round(($entry.ModifiedSort - $previousTicks) / [double][TimeSpan]::TicksPerSecond)
    } else {
        $null
    }
    $ordered += [pscustomobject]@{
        Order                = $ordered.Count + 1
        Name                 = $entry.Name
        Slot                 = $entry.Slot
        SizeBytes            = $entry.SizeBytes
        ModifiedUtc          = $entry.ModifiedUtc
        SecondsSincePrevious = $delta
        MagicValid           = $entry.MagicValid
        Sha256               = $entry.Sha256
    }
    $previousTicks = $entry.ModifiedSort
}

$slots = @($ordered | Where-Object { $null -ne $_.Slot } | ForEach-Object { $_.Slot })
$spanSeconds = 0
if ($ordered.Count -gt 1) {
    $spanSeconds = [int][Math]::Round(($entries[$entries.Count - 1].ModifiedSort - $entries[0].ModifiedSort) / [double][TimeSpan]::TicksPerSecond)
}

$report = [pscustomobject]@{
    SchemaVersion = 1
    GeneratedUtc  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ssZ')
    SaveRoot      = $saveRootFull
    EntryCount    = $ordered.Count
    SaveCount     = @($ordered | Where-Object { $null -ne $_.Slot }).Count
    DistinctSlots = @($slots | Select-Object -Unique).Count
    SlotSequence  = $slots
    FirstWriteUtc = if ($ordered.Count -gt 0) { $ordered[0].ModifiedUtc } else { $null }
    LastWriteUtc  = if ($ordered.Count -gt 0) { $ordered[$ordered.Count - 1].ModifiedUtc } else { $null }
    SpanSeconds   = $spanSeconds
    Entries       = $ordered
    Notes         = @(
        'Ordered by last-write time: it says when a file was written, not which chapter it belongs to.',
        'Slots rotate and are reused, so a snapshot cannot recover writes the game has already overwritten.',
        'Watch mode (-WatchSeconds) is what preserves the sequence during an attended play session.'
    )
}

# --- Baseline drift ----------------------------------------------------------
$drift = $null
if ($BaselinePath) {
    if (-not (Test-Path -LiteralPath $BaselinePath)) {
        [Console]::Error.WriteLine("Baseline not found: $BaselinePath")
        exit 2
    }
    $baseline = Get-Content -LiteralPath $BaselinePath -Raw | ConvertFrom-Json
    $before = @{}
    foreach ($entry in @($baseline.Entries)) { $before[$entry.Name] = $entry.Sha256 }
    $after = @{}
    foreach ($entry in $ordered) { $after[$entry.Name] = $entry.Sha256 }
    $added = @($after.Keys | Where-Object { -not $before.ContainsKey($_) } | Sort-Object)
    $removed = @($before.Keys | Where-Object { -not $after.ContainsKey($_) } | Sort-Object)
    $changed = @($after.Keys | Where-Object { $before.ContainsKey($_) -and $before[$_] -ne $after[$_] } | Sort-Object)
    $drift = [pscustomobject]@{
        BaselinePath = $BaselinePath
        Unchanged    = ($added.Count -eq 0 -and $removed.Count -eq 0 -and $changed.Count -eq 0)
        Added        = $added
        Removed      = $removed
        Changed      = $changed
    }
    $report | Add-Member -NotePropertyName Drift -NotePropertyValue $drift
}

$outFull = Resolve-OutputPath -CandidatePath $OutputPath
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $outFull -Encoding UTF8

Write-Host ("Saves        : {0} ({1} distinct slot(s))" -f $report.SaveCount, $report.DistinctSlots)
Write-Host ("Slot sequence: {0}" -f (($slots | ForEach-Object { "save_$_" }) -join ' -> '))
Write-Host ("Span         : {0}s ({1} -> {2})" -f $report.SpanSeconds, $report.FirstWriteUtc, $report.LastWriteUtc)
Write-Host ("Report       : {0}" -f $outFull)

if ($drift) {
    if (-not $drift.Unchanged) {
        Write-Host ("DRIFT  added={0} removed={1} changed={2}" -f $drift.Added.Count, $drift.Removed.Count, $drift.Changed.Count)
        if ($drift.Changed.Count -gt 0) { Write-Host ("  changed: {0}" -f ($drift.Changed -join ', ')) }
        exit 3
    }
    Write-Host 'DRIFT  none (save set identical to baseline)'
}
exit 0

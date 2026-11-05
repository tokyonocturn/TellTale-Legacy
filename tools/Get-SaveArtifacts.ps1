param(
    [string]$SaveRoot = (Join-Path $env:USERPROFILE 'Documents\Telltale Games\The Walking Dead'),
    [string]$OutputPath = 'docs/rea/data/save-artifacts.json',
    [string]$CompareA = '',
    [string]$CompareB = '',
    [string]$CompareOutputPath = 'docs/rea/data/save-diff.json',
    [string]$BaselinePath = '',
    [string]$BaselineOutputPath = 'docs/rea/data/save-drift.json',
    [string]$ExpectedSaveMagic = 'bbdeaf64',
    [string]$ExpectedPropMagic = 'aadeaf64'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-Sha256 {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-ShannonEntropy {
    param([byte[]]$Bytes, [int]$Offset = 0)
    if ($Bytes.Length -le $Offset) { return 0.0 }
    $counts = New-Object 'int[]' 256
    for ($i = $Offset; $i -lt $Bytes.Length; $i++) { $counts[$Bytes[$i]]++ }
    $total = [double]($Bytes.Length - $Offset)
    $entropy = 0.0
    foreach ($c in $counts) {
        if ($c -gt 0) {
            $p = $c / $total
            $entropy -= $p * [Math]::Log($p, 2)
        }
    }
    [Math]::Round($entropy, 4)
}

function Get-MagicHex {
    param([byte[]]$Bytes)
    if ($Bytes.Length -lt 4) { return $null }
    ($Bytes[0..3] | ForEach-Object { $_.ToString('x2') }) -join ''
}

function Test-AsciiMarker {
    param([byte[]]$Bytes, [string]$Marker)
    $text = [System.Text.Encoding]::ASCII.GetString($Bytes)
    $text.IndexOf($Marker, [StringComparison]::Ordinal) -ge 0
}

function Get-SaveArtifact {
    param([string]$Path, [string]$ExpectedMagic)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $info = Get-Item -LiteralPath $Path
    $name = $info.Name
    $slot = $null
    $slotMatch = [regex]::Match($name, '^save_(\d+)\.save$', 'IgnoreCase')
    if ($slotMatch.Success) { $slot = [int]$slotMatch.Groups[1].Value }

    $declared = $null
    if ($bytes.Length -ge 8) { $declared = [BitConverter]::ToUInt32($bytes, 4) }

    $headerBlock = $null
    if ($bytes.Length -ge 16) {
        $headerBlock = ($bytes[8..15] | ForEach-Object { $_.ToString('x2') }) -join ''
    }

    $magic = Get-MagicHex -Bytes $bytes

    [pscustomobject]@{
        Name             = $name
        Slot             = $slot
        SizeBytes        = $bytes.Length
        Sha256           = Get-Sha256 -Path $Path
        ModifiedUtc      = $info.LastWriteTimeUtc.ToString('yyyy-MM-dd HH:mm:ssZ')
        Magic            = $magic
        MagicValid       = ($magic -eq $ExpectedMagic)
        DeclaredSize     = $declared
        DeclaredDelta    = if ($null -ne $declared) { [int64]$declared - [int64]$bytes.Length } else { $null }
        HeaderBlock      = $headerBlock
        PayloadEntropy   = Get-ShannonEntropy -Bytes $bytes -Offset 16
        UniqueByteValues = @($bytes | Select-Object -Unique).Count
        HasBannerMarker  = Test-AsciiMarker -Bytes $bytes -Marker '+SaveLoadImage.d3dtx'
    }
}

$saveRootFull = [System.IO.Path]::GetFullPath($SaveRoot)

function Assert-OutsideSaveRoot {
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
    $full
}

function Write-JsonReport {
    param([object]$Data, [string]$Path)
    $full = Assert-OutsideSaveRoot -CandidatePath $Path
    $dir = Split-Path -Parent $full
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $Data | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $full -Encoding UTF8
}

# --- Differential mode -------------------------------------------------------
if ($CompareA -and $CompareB) {
    $aBytes = [System.IO.File]::ReadAllBytes($CompareA)
    $bBytes = [System.IO.File]::ReadAllBytes($CompareB)
    $limit = [Math]::Min($aBytes.Length, $bBytes.Length)

    $prefix = 0
    while ($prefix -lt $limit -and $aBytes[$prefix] -eq $bBytes[$prefix]) { $prefix++ }

    $differing = 0
    $firstDiff = -1
    $lastDiff = -1
    for ($i = 0; $i -lt $limit; $i++) {
        if ($aBytes[$i] -ne $bBytes[$i]) {
            $differing++
            if ($firstDiff -lt 0) { $firstDiff = $i }
            $lastDiff = $i
        }
    }

    $result = [pscustomobject]@{
        SchemaVersion     = 1
        GeneratedUtc      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ssZ')
        A                 = [pscustomobject]@{ Path = $CompareA; SizeBytes = $aBytes.Length; Sha256 = Get-Sha256 -Path $CompareA }
        B                 = [pscustomobject]@{ Path = $CompareB; SizeBytes = $bBytes.Length; Sha256 = Get-Sha256 -Path $CompareB }
        CommonPrefixBytes = $prefix
        OverlapBytes      = $limit
        DifferingBytes    = $differing
        DifferingPct      = if ($limit -gt 0) { [Math]::Round(100.0 * $differing / $limit, 2) } else { 0 }
        FirstDiffOffset   = $firstDiff
        LastDiffOffset    = $lastDiff
        Identical         = ($aBytes.Length -eq $bBytes.Length -and $differing -eq 0)
        Note              = 'Byte-level only: the container is obfuscated, so a difference does not name the decision it encodes.'
    }

    Write-JsonReport -Data $result -Path $CompareOutputPath
    $result | Format-List
    exit 0
}

# --- Inventory ---------------------------------------------------------------
if (-not (Test-Path -LiteralPath $saveRootFull)) {
    [Console]::Error.WriteLine("Save root not found: $saveRootFull")
    exit 2
}

$saves = @(Get-ChildItem -LiteralPath $saveRootFull -Filter '*.save' -File -ErrorAction SilentlyContinue | Sort-Object Name)
$props = @(Get-ChildItem -LiteralPath $saveRootFull -Filter '*.prop' -File -ErrorAction SilentlyContinue | Sort-Object Name)
$leftovers = @(Get-ChildItem -LiteralPath $saveRootFull -Filter 'temp.save' -File -ErrorAction SilentlyContinue)

if ($saves.Count -eq 0 -and $props.Count -eq 0) {
    [Console]::Error.WriteLine("No .save or .prop artefacts found in $saveRootFull")
    exit 2
}

$artifacts = @()
foreach ($file in $saves) { $artifacts += Get-SaveArtifact -Path $file.FullName -ExpectedMagic $ExpectedSaveMagic }
foreach ($file in $props) { $artifacts += Get-SaveArtifact -Path $file.FullName -ExpectedMagic $ExpectedPropMagic }

$distinctHeaders = @($artifacts | Where-Object { $_.HeaderBlock } | Select-Object -ExpandProperty HeaderBlock -Unique)

$report = [pscustomobject]@{
    SchemaVersion        = 1
    GeneratedUtc         = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ssZ')
    SaveRoot             = $saveRootFull
    SaveCount            = $saves.Count
    PropCount            = $props.Count
    TotalBytes           = ($artifacts | Measure-Object -Property SizeBytes -Sum).Sum
    DistinctHeaderBlocks = $distinctHeaders.Count
    HeaderBlocks         = $distinctHeaders
    AllMagicValid        = (@($artifacts | Where-Object { -not $_.MagicValid }).Count -eq 0)
    IncompleteTempFile   = ($leftovers.Count -gt 0)
    Artifacts            = $artifacts
    Notes                = @(
        'Read-only inspection: nothing in the save root is modified.',
        'DeclaredSize is the little-endian uint32 at offset 4; it does not match the file length, so it is not a plain byte count.',
        'PayloadEntropy near 8.0 indicates obfuscated or compressed content; no plaintext chapter or choice identifiers are exposed.'
    )
}

# --- Drift mode --------------------------------------------------------------
if ($BaselinePath) {
    if (-not (Test-Path -LiteralPath $BaselinePath)) {
        [Console]::Error.WriteLine("Baseline not found: $BaselinePath")
        exit 2
    }
    $baseline = Get-Content -LiteralPath $BaselinePath -Raw | ConvertFrom-Json
    $before = @{}
    foreach ($entry in @($baseline.Artifacts)) { $before[$entry.Name] = $entry.Sha256 }
    $after = @{}
    foreach ($entry in $artifacts) { $after[$entry.Name] = $entry.Sha256 }

    $added = @($after.Keys | Where-Object { -not $before.ContainsKey($_) } | Sort-Object)
    $removed = @($before.Keys | Where-Object { -not $after.ContainsKey($_) } | Sort-Object)
    $changed = @($after.Keys | Where-Object { $before.ContainsKey($_) -and $before[$_] -ne $after[$_] } | Sort-Object)

    $drift = [pscustomobject]@{
        SchemaVersion = 1
        GeneratedUtc  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ssZ')
        BaselinePath  = $BaselinePath
        SaveRoot      = $saveRootFull
        Unchanged     = ($added.Count -eq 0 -and $removed.Count -eq 0 -and $changed.Count -eq 0)
        Added         = $added
        Removed       = $removed
        Changed       = $changed
        BeforeHashes  = $before
        AfterHashes   = $after
    }
    Write-JsonReport -Data $drift -Path $BaselineOutputPath

    if (-not $drift.Unchanged) {
        Write-Host ("DRIFT  added={0} removed={1} changed={2}" -f $added.Count, $removed.Count, $changed.Count)
        if ($changed.Count -gt 0) { Write-Host ("  changed: {0}" -f ($changed -join ', ')) }
        exit 3
    }
    Write-Host 'DRIFT  none (save set identical to baseline)'
    exit 0
}

Write-JsonReport -Data $report -Path $OutputPath

Write-Host ("Saves      : {0}" -f $report.SaveCount)
Write-Host ("Props      : {0}" -f $report.PropCount)
Write-Host ("Total bytes: {0}" -f $report.TotalBytes)
Write-Host ("Headers    : {0} distinct block(s)" -f $report.DistinctHeaderBlocks)
Write-Host ("Magic      : {0}" -f $(if ($report.AllMagicValid) { 'all recognised' } else { 'unrecognised value present' }))
Write-Host ("Temp file  : {0}" -f $(if ($report.IncompleteTempFile) { 'present (interrupted write?)' } else { 'none' }))
Write-Host ("Report     : {0}" -f $OutputPath)
exit 0

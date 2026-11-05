#Requires -Version 5.1
<#
.SYNOPSIS
    Builds a forensic inventory of a Telltale Tool game installation.

.DESCRIPTION
    Reads (never writes to) the game directory and produces:
      * a per-file inventory with size and SHA-256
      * PE analysis (architecture, subsystem, link timestamp, sections, imports)
      * telltale archive (.ttarch) header facts
      * optional registry / save-directory facts via -IncludeUserState

    Output is a machine-readable JSON document plus a console summary.

.PARAMETER GameRoot
    Installation directory of the game.

.PARAMETER OutputPath
    Path of the JSON document to write.

.PARAMETER SkipHash
    Skip SHA-256 hashing (much faster on multi-GB installations).

.PARAMETER IncludeUserState
    Also record per-user state locations (save folders, HKCU keys) if present.
#>
[CmdletBinding()]
param(
    [string]$GameRoot = 'C:\Program Files (x86)\Steam\steamapps\common\The Walking Dead',
    [string]$OutputPath,
    [switch]$SkipHash,
    [switch]$IncludeUserState
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $OutputPath) {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $OutputPath = Join-Path $repoRoot 'docs\rea\data\inventory.json'
}

$GameRoot = (Resolve-Path -LiteralPath $GameRoot).ProviderPath
if (-not (Test-Path -LiteralPath $GameRoot -PathType Container)) {
    throw "Game root not found: $GameRoot"
}

# ---------------------------------------------------------------- PE analysis

function Read-U32 {
    param([byte[]]$Bytes, [int]$Offset)
    [BitConverter]::ToUInt32($Bytes, $Offset)
}

function Get-PeAnalysis {
    param([string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 0x40) { throw "Not a PE file: $Path" }
    $pe = [BitConverter]::ToInt32($bytes, 0x3C)
    if ([Text.Encoding]::ASCII.GetString($bytes, $pe, 4) -ne "PE`0`0") {
        throw "Missing PE signature: $Path"
    }

    $machine      = [BitConverter]::ToUInt16($bytes, $pe + 4)
    $sectionCount = [BitConverter]::ToUInt16($bytes, $pe + 6)
    $linkStamp    = [BitConverter]::ToUInt32($bytes, $pe + 8)
    $optSize      = [BitConverter]::ToUInt16($bytes, $pe + 20)
    $optMagic     = [BitConverter]::ToUInt16($bytes, $pe + 24)
    $is64         = ($optMagic -eq 0x20B)
    $subsystem    = [BitConverter]::ToUInt16($bytes, $pe + 24 + 68)
    $imageBase    = if ($is64) { [BitConverter]::ToUInt64($bytes, $pe + 24 + 24) } else { [uint64][BitConverter]::ToUInt32($bytes, $pe + 24 + 28) }

    $dirOffset = $pe + 24 + $(if ($is64) { 112 } else { 96 })
    $importRva = [BitConverter]::ToUInt32($bytes, $dirOffset + 8)
    $importSize = [BitConverter]::ToUInt32($bytes, $dirOffset + 12)

    $sectionTable = $pe + 24 + $optSize
    $sections = @()
    for ($i = 0; $i -lt $sectionCount; $i++) {
        $o = $sectionTable + ($i * 40)
        $name = [Text.Encoding]::ASCII.GetString($bytes, $o, 8).Trim([char]0)
        $sections += [pscustomobject]@{
            Name       = $name
            VirtualSize = [BitConverter]::ToUInt32($bytes, $o + 8)
            VirtualAddr = [BitConverter]::ToUInt32($bytes, $o + 12)
            RawSize    = [BitConverter]::ToUInt32($bytes, $o + 16)
            RawPointer = [BitConverter]::ToUInt32($bytes, $o + 20)
            Characteristics = ('0x{0:X8}' -f [BitConverter]::ToUInt32($bytes, $o + 36))
        }
    }

    $script:RvaToOffset = {
        param([uint32]$Rva)
        foreach ($s in $sections) {
            if ($s.VirtualSize -eq 0) { continue }
            if ($Rva -ge $s.VirtualAddr -and $Rva -lt ($s.VirtualAddr + [Math]::Max($s.VirtualSize, $s.RawSize))) {
                return [int]($Rva - $s.VirtualAddr + $s.RawPointer)
            }
        }
        return -1
    }

    # Imported DLL names (import directory entry 1).
    $imports = @()
    if ($importRva -ne 0) {
        $off = & $script:RvaToOffset $importRva
        if ($off -gt 0) {
            for ($d = 0; $d -lt 512; $d++) {
                $o = $off + ($d * 20)
                if (($o + 20) -gt $bytes.Length) { break }
                $nameRva = [BitConverter]::ToUInt32($bytes, $o + 12)
                $firstThunk = [BitConverter]::ToUInt32($bytes, $o + 16)
                if ($nameRva -eq 0 -and $firstThunk -eq 0) { break }
                if ($nameRva -eq 0) { continue }
                $nameOff = & $script:RvaToOffset $nameRva
                if ($nameOff -le 0 -or $nameOff -ge $bytes.Length) { continue }
                $end = $nameOff
                while ($end -lt $bytes.Length -and $bytes[$end] -ne 0) { $end++ }
                $imports += [Text.Encoding]::ASCII.GetString($bytes, $nameOff, $end - $nameOff)
            }
        }
    }

    $hasBindSection = [bool]($sections | Where-Object { $_.Name -eq '.bind' })

    [pscustomobject]@{
        Path          = $Path
        SizeBytes     = $bytes.Length
        Architecture  = if ($machine -eq 0x14C) { 'x86' } elseif ($machine -eq 0x8664) { 'x64' } else { ('machine-0x{0:X4}' -f $machine) }
        Subsystem     = switch ($subsystem) { 2 { 'GUI' } 3 { 'console' } default { "subsystem-$subsystem" } }
        LinkTimestampUtc = ([DateTimeOffset]::FromUnixTimeSeconds($linkStamp)).UtcDateTime.ToString('u')
        ImageBase     = ('0x{0:X}' -f $imageBase)
        SectionCount  = $sectionCount
        Sections      = $sections
        HasBindSection = $hasBindSection
        ImportedModules = $imports
    }
}

# ------------------------------------------------------------ archive headers

function Get-TtarchHeader {
    param([string]$Path)

    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $buf = New-Object byte[] 32
        $read = $fs.Read($buf, 0, 32)
    } finally {
        $fs.Dispose()
    }

    [pscustomobject]@{
        Version      = if ($read -ge 4) { [BitConverter]::ToUInt32($buf, 0) } else { $null }
        Flags        = if ($read -ge 8) { [BitConverter]::ToUInt32($buf, 4) } else { $null }
        HeaderHex    = (($buf[0..([Math]::Min($read, 32) - 1)]) | ForEach-Object { $_.ToString('X2') }) -join ' '
        SizeBytes    = (Get-Item -LiteralPath $Path).Length
    }
}

function Get-FileKind {
    param([string]$Name)
    switch -Regex ($Name) {
        '(?i)\.exe$'                    { return 'executable' }
        '(?i)\.dll$'                    { return 'library' }
        '(?i)\.ttarch$'                 { return 'archive' }
        '(?i)\.(prop|cab|vdf|txt|lua)$' { return 'data' }
        default                         { return 'other' }
    }
}

# ------------------------------------------------------------------ inventory

Write-Host "Inventorying: $GameRoot"
$files = Get-ChildItem -LiteralPath $GameRoot -Recurse -File -Force |
    Sort-Object FullName

$total = 0L
$entries = New-Object System.Collections.Generic.List[object]
$i = 0
foreach ($f in $files) {
    $i++
    $relative = $f.FullName.Substring($GameRoot.Length).TrimStart('\', '/')
    $kind = Get-FileKind -Name $f.Name
    Write-Progress -Activity 'Inventory' -Status $relative -PercentComplete (($i / $files.Count) * 100)

    $entry = [ordered]@{
        Path       = $relative.Replace('\', '/')
        Kind       = $kind
        SizeBytes  = $f.Length
        Sha256     = if ($SkipHash) { $null } else { (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash }
    }

    if ($kind -eq 'executable' -or $kind -eq 'library') {
        $entry['Pe'] = Get-PeAnalysis -Path $f.FullName
    }
    elseif ($kind -eq 'archive') {
        $entry['Ttarch'] = Get-TtarchHeader -Path $f.FullName
    }
    elseif ($f.Extension -eq '.prop') {
        $entry['TextPreview'] = (Get-Content -LiteralPath $f.FullName -TotalCount 40 -ErrorAction SilentlyContinue) -join "`n"
    }

    $total += $f.Length
    $entries.Add([pscustomobject]$entry)
}
Write-Progress -Activity 'Inventory' -Completed

$archiveGroups = $entries | Where-Object { $_.Kind -eq 'archive' } | Group-Object {
    ($_.Path -split '/')[1]
} | ForEach-Object {
    [pscustomobject]@{
        Group       = $_.Name
        FileCount   = $_.Count
        TotalBytes  = ($_.Group | Measure-Object -Property SizeBytes -Sum).Sum
        Versions    = (($_.Group | ForEach-Object { $_.Ttarch.Version } | Sort-Object -Unique) -join ',')
    }
}

$userState = $null
if ($IncludeUserState) {
    $saveRoot = Join-Path $env:USERPROFILE 'Documents\Telltale Games'
    $userState = [pscustomobject]@{
        DocumentsTelltaleGamesExists = (Test-Path -LiteralPath $saveRoot)
        DocumentsTelltaleGamesPath   = $saveRoot
        RegistryKeys                 = @(
            foreach ($k in @('HKCU:\Software\Telltale Games', 'HKCU:\Software\Telltale Games\WalkingDead101.exe')) {
                if (Test-Path -LiteralPath $k) {
                    $item = Get-Item -LiteralPath $k
                    [pscustomobject]@{
                        Key     = $k
                        Values  = @(Get-ItemProperty -LiteralPath $item.PSPath | Select-Object * -ExcludeProperty PS*)
                        SubKeys = @(Get-ChildItem -LiteralPath $item.PSPath -ErrorAction SilentlyContinue | ForEach-Object { $_.PSChildName })
                    }
                }
            }
        )
    }
}

$document = [ordered]@{
    SchemaVersion = 1
    GeneratedUtc  = (Get-Date).ToUniversalTime().ToString('u')
    GameRoot      = $GameRoot
    Summary       = [ordered]@{
        FileCount    = $entries.Count
        TotalBytes   = $total
        Executables  = @($entries | Where-Object { $_.Kind -eq 'executable' } | ForEach-Object { $_.Path })
        Libraries    = @($entries | Where-Object { $_.Kind -eq 'library' } | ForEach-Object { $_.Path })
        ArchiveGroups = $archiveGroups
    }
    Files         = $entries
    UserState     = $userState
}

$json = $document | ConvertTo-Json -Depth 8
$outDir = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}
[System.IO.File]::WriteAllText($OutputPath, $json, [Text.UTF8Encoding]::new($false))

Write-Host ''
Write-Host ("Files     : {0}" -f $entries.Count)
Write-Host ("Total     : {0:N2} GiB" -f ($total / 1GB))
Write-Host ("Archives  : {0}" -f @($entries | Where-Object { $_.Kind -eq 'archive' }).Count)
Write-Host ("Written   : {0}" -f $OutputPath)

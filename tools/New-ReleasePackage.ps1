#Requires -Version 5.1
<#
.SYNOPSIS
    Builds one self-contained release package per game profile, from the committed tree.

.DESCRIPTION
    Each package carries the shared tooling, the documentation, one game's profile and a
    generated PATCH.md for that game. Nothing is read from the working tree: every file is
    taken from the commit, so a package always describes a state that exists in git.

    Only tracked text files can enter a package, and the script refuses to build if a
    forbidden path (backups, dist, tools/scratch, docs/rea/data, logs) or an unexpectedly
    large file appears, which is how game content and machine state stay out.

    Zip entries are written in sorted order with the commit's timestamp, so rebuilding the
    same commit produces the same bytes.

.PARAMETER ProfileId
    One profile id, for example twd-s2-steam-261030. When omitted, every profile is packaged.

.PARAMETER Tag
    Tag recorded in the manifest and the package notes. Optional.

.PARAMETER Commit
    Commit to package. Defaults to HEAD.

.PARAMETER OutputDirectory
    Where zips and manifests go. Defaults to dist/.

.PARAMETER AsJson
    Emit the manifest objects as JSON instead of a summary.

.EXAMPLE
    .\tools\New-ReleasePackage.ps1 -ProfileId twd-definitive-steam-1449690 -Tag twd-definitive-v1.0.0

.EXAMPLE
    .\tools\New-ReleasePackage.ps1
#>
[CmdletBinding()]
param(
    [string]$ProfileId = '',
    [string]$Tag = '',
    [string]$Commit = 'HEAD',
    [string]$OutputDirectory = '',
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $repo
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repo 'dist' }
if (-not (Test-Path -LiteralPath $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null }

function Invoke-Git {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $output = & git @Arguments
    if ($LASTEXITCODE -ne 0) { throw ("git {0} failed" -f ($Arguments -join ' ')) }
    return $output
}

$commitSha = (Invoke-Git -Arguments @('rev-parse', $Commit)).Trim()
$commitDate = [datetimeoffset]::Parse((Invoke-Git -Arguments @('log', '-1', '--format=%cI', $commitSha)).Trim())
$shortSha = $commitSha.Substring(0, 7)
$trackedPaths = @(Invoke-Git -Arguments @('ls-tree', '-r', '--name-only', $commitSha))

# Read the commit through a detached worktree so packaged bytes are the committed bytes,
# not a text round trip through git show (which would rewrite line endings).
$worktreePath = Join-Path ([System.IO.Path]::GetTempPath()) ('telltale-legacy-pkg-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
Invoke-Git -Arguments @('worktree', 'add', '--detach', $worktreePath, $commitSha) | Out-Null
try {

$forbiddenPatterns = @('^backups/', '^dist/', '^\.git/', '^tools/scratch/', '^docs/rea/data/', '\.log$', '\.zip$', '\.bundle$')
$maxFileBytes = 4194304

$profileIds = @()
if ($ProfileId) {
    $profileIds = @($ProfileId)
} else {
    $profileIds = @($trackedPaths | Where-Object { $_ -match '^profiles/(?<id>[^/]+)/profile\.json$' } | ForEach-Object { [regex]::Match($_, '^profiles/(?<id>[^/]+)/').Groups['id'].Value } | Sort-Object)
}
if ($profileIds.Count -eq 0) { throw 'No profiles found in the commit.' }

function Get-ProfileFor {
    param([Parameter(Mandatory)][string]$Id)
    $path = "profiles/$Id/profile.json"
    if ($trackedPaths -notcontains $path) { throw "No profile at $path in commit $shortSha" }
    $json = [System.IO.File]::ReadAllText((Join-Path $worktreePath $path))
    return ($json | ConvertFrom-Json)
}

function Get-PackageFiles {
    param([Parameter(Mandatory)][string]$Id)

    $ownProfile = "profiles/$Id/"
    $selected = @()
    foreach ($path in $trackedPaths) {
        $keep = $false
        if ($path -eq 'LICENSE' -or $path -eq 'README.md') { $keep = $true }
        elseif ($path -like 'docs/*') { $keep = $true }
        elseif ($path -like 'tools/*') { $keep = $true }
        elseif ($path.StartsWith($ownProfile, [System.StringComparison]::Ordinal)) { $keep = $true }
        if (-not $keep) { continue }
        foreach ($pattern in $forbiddenPatterns) {
            if ($path -match $pattern) { throw "Refusing to package $path (matches $pattern)" }
        }
        $selected += $path
    }
    return @($selected | Sort-Object)
}

function New-PatchNotes {
    param([Parameter(Mandatory)]$Profile, [Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$TagName)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Offline patch: $($Profile.displayName)")
    $lines.Add('')
    $lines.Add('This package carries the tooling, the documentation and one game profile. It contains no')
    $lines.Add('game code, no assets, no archives and no save data, and it patches nothing on its own')
    $lines.Add('until you run the command below against an installation you own.')
    $lines.Add('')
    $lines.Add('## The build this patch is written for')
    $lines.Add('')
    $lines.Add("| Item | Value |")
    $lines.Add("|---|---|")
    $lines.Add("| Profile | $Id |")
    $lines.Add("| Steam app | $($Profile.steamAppId) |")
    $lines.Add("| Steam build | $($Profile.steamBuildId) |")
    $lines.Add("| Executable | $($Profile.executable) |")
    $exeHash = $Profile.knownGoodHashes.($Profile.executable)
    if ($exeHash) { $lines.Add("| Executable SHA-256 | $exeHash |") }
    $endpoints = @($Profile.offlinePatch.endpoints)
    if ($endpoints.Count -gt 0) { $lines.Add("| Endpoint pinned | $($endpoints -join ', ') |") }
    if ($TagName) { $lines.Add("| Release tag | $TagName |") }
    $lines.Add('')
    $lines.Add('A package refuses to install against a different build: the driver hashes the installed')
    $lines.Add('executable first and exits 24 when it does not match.')
    $lines.Add('')
    $lines.Add('## What it changes')
    $lines.Add('')
    $lines.Add('1. Steam starts in Offline Mode, so an offline launch does not wait for a connection that')
    $lines.Add('   is not there. This is Steam''s own documented setting, reverted byte for byte.')
    $lines.Add('2. The publisher endpoint above is pinned to 127.0.0.1 in the hosts file, so a blocked')
    $lines.Add('   startup call fails immediately instead of timing out. The marked block is removed on')
    $lines.Add('   revert and the file is restored to its pre-patch bytes.')
    $lines.Add('')
    $lines.Add('Neither step patches a game file, bypasses Steam DRM, or grants anything the account does')
    $lines.Add('not own. Offline Mode still needs an account that has signed in on this machine.')
    $lines.Add('')
    $lines.Add('## Commands')
    $lines.Add('')
    $lines.Add('```powershell')
    $lines.Add("# read-only: install present, build hash match, pins, client mode")
    $lines.Add("powershell -NoProfile -ExecutionPolicy Bypass -File tools\Set-GameOfflinePatch.ps1 -Game $Id -Action Status")
    $lines.Add('')
    $lines.Add('# apply, then revert (both need an elevated shell)')
    $lines.Add("powershell -NoProfile -ExecutionPolicy Bypass -File tools\Set-GameOfflinePatch.ps1 -Game $Id -Action Install")
    $lines.Add("powershell -NoProfile -ExecutionPolicy Bypass -File tools\Set-GameOfflinePatch.ps1 -Game $Id -Action Remove")
    $lines.Add('```')
    $lines.Add('')
    $lines.Add('If the game lives somewhere the profile does not list, add -GameRoot "<install path>".')
    $lines.Add('')
    $lines.Add('## Verified for this build')
    $lines.Add('')
    foreach ($item in @($Profile.offlinePatch.verified)) { $lines.Add("- $item") }
    $lines.Add('')
    $lines.Add('## Not verified for this build')
    $lines.Add('')
    foreach ($item in @($Profile.offlinePatch.untested)) { $lines.Add("- $item") }
    $lines.Add('')
    $lines.Add('Launch verification field: ' + $Profile.offlinePatch.launchVerification)
    $lines.Add('')
    $lines.Add('## Where the details are')
    $lines.Add('')
    $lines.Add('- docs/rea/20-other-games-offline-patch.md: the per-game record and status matrix')
    $lines.Add('- docs/rea/21-definitive-offline-launch.md: the measured offline launch of the Definitive Series')
    $lines.Add('- docs/rea/19-offline-launch-stall.md: what the launch wait is, and the measurement that found it')
    $lines.Add('- docs/legal-boundaries.md: what this project does and does not do')

    return ($lines -join "`n") + "`n"
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Security

function Get-Sha256Hex {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $sha.Dispose() }
}

$manifests = @()

foreach ($id in $profileIds) {
    $profile = Get-ProfileFor -Id $id
    if (-not $profile.offlinePatch -or @($profile.offlinePatch.endpoints).Count -eq 0) {
        Write-Warning "Skipping ${id}: no endpoints, so there is nothing to pin."
        continue
    }

    $packageName = "telltale-legacy-$id-$shortSha"
    $zipPath = Join-Path $OutputDirectory ($packageName + '.zip')
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

    $fileRecords = New-Object System.Collections.Generic.List[object]
    $zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($path in (Get-PackageFiles -Id $id)) {
            $blob = [System.IO.File]::ReadAllBytes((Join-Path $worktreePath $path))
            if ($blob.Length -gt $maxFileBytes) { throw "Refusing to package ${path}: $($blob.Length) bytes" }
            $entry = $zip.CreateEntry($path, [System.IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = [DateTimeOffset]$commitDate
            $stream = $entry.Open()
            try { $stream.Write($blob, 0, $blob.Length) } finally { $stream.Dispose() }
            $fileRecords.Add([pscustomobject]@{ path = $path; bytes = $blob.Length; sha256 = (Get-Sha256Hex -Bytes $blob) })
        }

        $notes = New-PatchNotes -Profile $profile -Id $id -TagName $Tag
        $notesBlob = [System.Text.Encoding]::UTF8.GetBytes($notes)
        $notesEntry = $zip.CreateEntry('PATCH.md', [System.IO.Compression.CompressionLevel]::Optimal)
        $notesEntry.LastWriteTime = [DateTimeOffset]$commitDate
        $notesStream = $notesEntry.Open()
        try { $notesStream.Write($notesBlob, 0, $notesBlob.Length) } finally { $notesStream.Dispose() }
        $fileRecords.Add([pscustomobject]@{ path = 'PATCH.md'; bytes = $notesBlob.Length; sha256 = (Get-Sha256Hex -Bytes $notesBlob) })
    } finally {
        $zip.Dispose()
    }

    $zipBytes = [System.IO.File]::ReadAllBytes($zipPath)
    $manifest = [ordered]@{
        package    = $packageName + '.zip'
        profileId  = $id
        tag        = $Tag
        commit     = $commitSha
        commitDate = $commitDate.ToString('o')
        builtUtc   = (Get-Date).ToUniversalTime().ToString('o')
        bytes      = $zipBytes.Length
        sha256     = (Get-Sha256Hex -Bytes $zipBytes)
        fileCount  = $fileRecords.Count
        files      = $fileRecords
    }
    $manifestPath = Join-Path $OutputDirectory ('manifest-' + $id + '.json')
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    $manifests += [pscustomobject]$manifest
}
} finally {
    if (Test-Path -LiteralPath $worktreePath) {
        Invoke-Git -Arguments @('worktree', 'remove', '--force', $worktreePath) | Out-Null
    }
}

if ($AsJson) {
    $manifests | ConvertTo-Json -Depth 5
} else {
    foreach ($m in $manifests) {
        Write-Host ("{0}`n  sha256 {1}`n  {2} files, {3:N0} bytes" -f $m.package, $m.sha256, $m.fileCount, $m.bytes)
    }
    Write-Host ("commit {0} ({1})" -f $shortSha, $commitDate.ToString('u'))
}

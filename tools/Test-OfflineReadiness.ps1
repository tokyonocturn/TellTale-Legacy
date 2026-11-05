#Requires -Version 5.1
<#
.SYNOPSIS
    Audits whether a Telltale game installation is ready for legitimate offline play.

.DESCRIPTION
    Compares the installed build against a compatibility profile and checks the
    local prerequisites for an offline session: build identity, required binaries,
    Steam DRM presence, Steam client state, save-directory writability and the
    DirectX 9 redistributable runtime.

    This tool reports facts. It never modifies the installation and cannot grant
    a license: the Steam DRM wrapper (.bind) means a legitimately owned license and
    Steam Offline Mode remain mandatory.

.PARAMETER ProfilePath
    Compatibility profile JSON. Defaults to profiles\twd-s1-steam-207610\profile.json.

.PARAMETER GameRoot
    Installation directory. Defaults to the path in the profile.

.PARAMETER SaveRoot
    Per-user data root. Defaults to Documents\Telltale Games.

.PARAMETER OutputPath
    JSON report path. Defaults to docs\rea\data\offline-readiness.json.

.OUTPUTS
    Exit code 0 when no check failed, 2 when at least one check failed.
#>
[CmdletBinding()]
param(
    [string]$ProfilePath,
    [string]$GameRoot,
    [string]$SaveRoot = (Join-Path $env:USERPROFILE 'Documents\Telltale Games'),
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $ProfilePath) { $ProfilePath = Join-Path $repoRoot 'profiles\twd-s1-steam-207610\profile.json' }
if (-not $OutputPath) { $OutputPath = Join-Path $repoRoot 'docs\rea\data\offline-readiness.json' }
if (-not (Test-Path -LiteralPath $ProfilePath)) { throw "Profile not found: $ProfilePath" }

$profile = Get-Content -LiteralPath $ProfilePath -Raw | ConvertFrom-Json
if (-not $GameRoot) { $GameRoot = 'C:\Program Files (x86)\Steam\steamapps\common\The Walking Dead' }

$checks = New-Object System.Collections.Generic.List[object]

function Add-Check {
    param(
        [string]$Id,
        [string]$Name,
        [ValidateSet('Pass', 'Warn', 'Fail', 'Info')][string]$Status,
        [string]$Detail
    )
    $checks.Add([pscustomobject]@{ Id = $Id; Check = $Name; Status = $Status; Detail = $Detail })
}

$gamePresent = Test-Path -LiteralPath $GameRoot -PathType Container
Add-Check -Id 'install-root' -Name 'Installation directory present' -Status $(if ($gamePresent) { 'Pass' } else { 'Fail' }) -Detail $GameRoot
if (-not $gamePresent) {
    Write-Host "Game root not found: $GameRoot" -ForegroundColor Red
    $checks | Format-Table -AutoSize
    exit 2
}

# --- build identity
$exePath = Join-Path $GameRoot $profile.executable
$exePresent = Test-Path -LiteralPath $exePath
Add-Check -Id 'executable' -Name ("{0} present" -f $profile.executable) -Status $(if ($exePresent) { 'Pass' } else { 'Fail' }) -Detail $exePath

if ($exePresent) {
    $hash = (Get-FileHash -LiteralPath $exePath -Algorithm SHA256).Hash
    $expected = $profile.knownGoodHashes.($profile.executable)
    if ($expected -and $hash -eq $expected) {
        Add-Check -Id 'executable-hash' -Name 'Executable matches profile build' -Status 'Pass' -Detail "sha256=$hash"
    } else {
        Add-Check -Id 'executable-hash' -Name 'Executable matches profile build' -Status 'Warn' -Detail ("sha256={0} (profile expects {1}); this is a different build or a modified file" -f $hash, $expected)
    }
}

foreach ($name in $profile.knownGoodHashes.PSObject.Properties.Name) {
    if ($name -eq $profile.executable) { continue }
    $path = Join-Path $GameRoot $name
    if (-not (Test-Path -LiteralPath $path)) {
        Add-Check -Id "file:$name" -Name "$name present" -Status 'Fail' -Detail 'missing'
        continue
    }
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    if ($hash -eq $profile.knownGoodHashes.$name) {
        Add-Check -Id "file:$name" -Name "$name matches profile" -Status 'Pass' -Detail "sha256=$hash"
    } else {
        Add-Check -Id "file:$name" -Name "$name matches profile" -Status 'Warn' -Detail ("sha256={0} (expected {1})" -f $hash, $profile.knownGoodHashes.$name)
    }
}

# --- content
$packRoot = Join-Path $GameRoot $profile.content.archiveRoot
if (Test-Path -LiteralPath $packRoot) {
    $archives = @(Get-ChildItem -LiteralPath $packRoot -Recurse -File -Filter '*.ttarch')
    $badVersion = @()
    foreach ($a in $archives) {
        $fs = [System.IO.File]::OpenRead($a.FullName)
        try { $buf = New-Object byte[] 4; $null = $fs.Read($buf, 0, 4); $version = [BitConverter]::ToUInt32($buf, 0) } finally { $fs.Dispose() }
        if ($version -ne $profile.content.archiveVersion) { $badVersion += $a.Name }
    }
    $missingEpisodes = @($profile.content.episodeDirectories.PSObject.Properties.Name | Where-Object { -not (Test-Path -LiteralPath (Join-Path $packRoot $_)) })
    $status = if ($archives.Count -eq 0 -or $badVersion.Count -gt 0 -or $missingEpisodes.Count -gt 0) { 'Fail' } else { 'Pass' }
    Add-Check -Id 'content-archives' -Name 'Episode archives present (ttarch v9)' -Status $status -Detail (
        "{0} archives; unexpected versions: {1}; missing episode dirs: {2}" -f
        $archives.Count,
        $(if ($badVersion.Count) { $badVersion -join ',' } else { 'none' }),
        $(if ($missingEpisodes.Count) { $missingEpisodes -join ',' } else { 'none' })
    )
} else {
    Add-Check -Id 'content-archives' -Name 'Episode archives present (ttarch v9)' -Status 'Fail' -Detail "missing Pack directory: $packRoot"
}

# --- Steam requirement (DRM is present by design; never bypassed)
$bindPresent = $false
try {
    $bytes = [System.IO.File]::ReadAllBytes($exePath)
    $pe = [BitConverter]::ToInt32($bytes, 0x3C)
    $numSections = [BitConverter]::ToUInt16($bytes, $pe + 6)
    $optSize = [BitConverter]::ToUInt16($bytes, $pe + 20)
    $sectionTable = $pe + 24 + $optSize
    for ($i = 0; $i -lt $numSections; $i++) {
        $name = [Text.Encoding]::ASCII.GetString($bytes, $sectionTable + ($i * 40), 8).Trim([char]0)
        if ($name -eq '.bind') { $bindPresent = $true }
    }
} catch {
    Add-Check -Id 'steam-drm' -Name 'Steam DRM wrapper' -Status 'Info' -Detail 'could not parse executable'
}
if ($bindPresent) {
    Add-Check -Id 'steam-drm' -Name 'Steam DRM wrapper present (.bind)' -Status 'Info' -Detail 'Steam license + Steam client required; Telltale Legacy does not bypass this'
}

$steamProcess = @(Get-Process -Name steam -ErrorAction SilentlyContinue)
Add-Check -Id 'steam-client' -Name 'Steam client running' -Status $(if ($steamProcess.Count -gt 0) { 'Pass' } else { 'Warn' }) -Detail $(if ($steamProcess.Count -gt 0) { "PID $($steamProcess[0].Id)" } else { 'not running; the game will start Steam' })

$activeUser = $null
try { $activeUser = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Valve\Steam\ActiveProcess' -ErrorAction Stop).ActiveUser } catch { }
Add-Check -Id 'steam-session' -Name 'Steam account signed in' -Status $(if ($activeUser -and $activeUser -ne 0) { 'Pass' } else { 'Warn' }) -Detail $(if ($activeUser -and $activeUser -ne 0) { "ActiveUser=$activeUser" } else { 'no active Steam user in HKCU; sign in once online before relying on Offline Mode' })

# --- Steam app manifest / build id
$appManifest = Join-Path (Split-Path -Parent (Split-Path -Parent $GameRoot)) ("appmanifest_{0}.acf" -f $profile.steamAppId)
if (Test-Path -LiteralPath $appManifest) {
    $text = Get-Content -LiteralPath $appManifest -Raw
    $buildId = if ($text -match '"buildid"\s+"(\d+)"') { $Matches[1] } else { $null }
    $stateFlags = if ($text -match '"StateFlags"\s+"(\d+)"') { [int]$Matches[1] } else { $null }
    $fullyInstalled = ($stateFlags -ne $null -and ($stateFlags -band 4) -ne 0)
    if ($buildId -eq $profile.steamBuildId) {
        Add-Check -Id 'steam-manifest' -Name 'Steam manifest build matches profile' -Status 'Pass' -Detail "buildid=$buildId StateFlags=$stateFlags"
    } else {
        Add-Check -Id 'steam-manifest' -Name 'Steam manifest build matches profile' -Status 'Warn' -Detail ("buildid={0} (profile {1}) StateFlags={2}" -f $buildId, $profile.steamBuildId, $stateFlags)
    }
    Add-Check -Id 'steam-installed' -Name 'Depot fully installed' -Status $(if ($fullyInstalled) { 'Pass' } else { 'Fail' }) -Detail "StateFlags=$stateFlags (bit 2 = fully installed)"
} else {
    Add-Check -Id 'steam-manifest' -Name 'Steam manifest present' -Status 'Warn' -Detail "not found: $appManifest"
}

# --- DirectX 9 runtime (32-bit game)
$d3dx = @(
    (Join-Path $env:WINDIR 'SysWOW64\d3dx9_41.dll'),
    (Join-Path $env:WINDIR 'System32\d3dx9_41.dll')
) | Where-Object { Test-Path -LiteralPath $_ }
Add-Check -Id 'directx9' -Name 'DirectX 9 runtime (d3dx9_41.dll)' -Status $(if ($d3dx.Count -gt 0) { 'Pass' } else { 'Warn' }) -Detail $(if ($d3dx.Count -gt 0) { $d3dx -join '; ' } else { 'not registered; run the bundled DirectX\DXSETUP.exe if the game fails to start' })

# --- per-user state
$saveExists = Test-Path -LiteralPath $SaveRoot
$writable = $false
try {
    $probeRoot = if ($saveExists) { $SaveRoot } else { Split-Path -Parent $SaveRoot }
    $probe = Join-Path $probeRoot ('.telltale-legacy-write-test-{0}' -f [guid]::NewGuid().ToString('N'))
    [System.IO.File]::WriteAllText($probe, 'probe')
    Remove-Item -LiteralPath $probe -Force
    $writable = $true
} catch { $writable = $false }
Add-Check -Id 'save-root' -Name 'Per-user save location' -Status $(if ($writable) { 'Pass' } else { 'Fail' }) -Detail ("{0} (exists={1}, writable={2})" -f $SaveRoot, $saveExists, $writable)

$saveFiles = if ($saveExists) { @(Get-ChildItem -LiteralPath $SaveRoot -Recurse -File -ErrorAction SilentlyContinue) } else { @() }
Add-Check -Id 'save-state' -Name 'Existing save data' -Status 'Info' -Detail $(if ($saveFiles.Count) { "$($saveFiles.Count) file(s), $([Math]::Round((($saveFiles | Measure-Object Length -Sum).Sum)/1MB,2)) MiB" } else { 'none yet; first launch will create it' })

$failed = @($checks | Where-Object { $_.Status -eq 'Fail' })
$warned = @($checks | Where-Object { $_.Status -eq 'Warn' })

$document = [ordered]@{
    SchemaVersion = 1
    GeneratedUtc  = (Get-Date).ToUniversalTime().ToString('u')
    Profile       = $profile.id
    GameRoot      = $GameRoot
    Verdict       = if ($failed.Count) { 'blocked' } elseif ($warned.Count) { 'ready-with-warnings' } else { 'ready' }
    FailCount     = $failed.Count
    WarnCount     = $warned.Count
    Checks        = $checks
}

$outDir = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
[System.IO.File]::WriteAllText($OutputPath, ($document | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))

$checks | Format-Table -AutoSize -Property Status, Check, Detail | Out-String -Width 200 | Write-Host
Write-Host ("Verdict: {0}  (fail={1}, warn={2})" -f $document.Verdict, $failed.Count, $warned.Count)
Write-Host ("Report : {0}" -f $OutputPath)

if ($failed.Count -gt 0) { exit 2 }
exit 0

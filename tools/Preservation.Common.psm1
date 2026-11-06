#Requires -Version 5.1
<#
    Shared helpers for the preservation program: Steam manifests, PE inspection,
    endpoint extraction, INI handling, registry/profiles and the Renegade LAN host.

    Everything here is read-only with respect to a game installation. The only
    writes are to a caller-supplied state directory and to the per-user save
    locations that a profile names explicitly.
#>

Set-StrictMode -Version Latest

function Get-PreservationRepoRoot {
    Split-Path -Parent $PSScriptRoot
}

<#
    Registry and profile paths are normally repository-relative, but an absolute
    path is honoured so a fixture registry can live outside the repository.
#>
function Resolve-RepoPath {
    param([Parameter(Mandatory)][string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path (Get-PreservationRepoRoot) $Path }
}

# --------------------------------------------------------------- Steam library

<#
    Resolves the Steam library roots that exist on this machine. The explicit
    override wins, then STEAM_LIBRARY, then the paths declared in Steam's own
    libraryfolders.vdf next to the client, then the registry's SteamPath.
#>
function Resolve-SteamLibrary {
    param([string]$Override)

    if ($Override) { return @($Override) }
    if ($env:STEAM_LIBRARY) { return @($env:STEAM_LIBRARY) }

    $clients = New-Object System.Collections.Generic.List[string]
    foreach ($key in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam')) {
        $value = $null
        try { $value = (Get-ItemProperty -LiteralPath $key -Name SteamPath -ErrorAction Stop).SteamPath } catch { $value = $null }
        if ($value) { $clients.Add($value) }
    }
    foreach ($guess in @('C:\Program Files (x86)\Steam', 'C:\Program Files\Steam')) {
        if (Test-Path -LiteralPath $guess) { $clients.Add($guess) }
    }

    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($client in $clients) {
        $normalized = $client.Replace('/', '\')
        foreach ($candidate in @($normalized, (Join-Path $normalized 'steamapps'))) {
            if ((Test-Path -LiteralPath (Join-Path $candidate 'steamapps')) -and -not $roots.Contains($candidate)) {
                $roots.Add($candidate)
            }
        }
        $vdf = Join-Path $normalized 'steamapps\libraryfolders.vdf'
        if (-not (Test-Path -LiteralPath $vdf)) { $vdf = Join-Path $normalized 'steamapps\libraryfolders.vdf' }
        if (Test-Path -LiteralPath $vdf) {
            $text = Get-Content -LiteralPath $vdf -Raw
            foreach ($match in [regex]::Matches($text, '"path"\s*"([^"]+)"')) {
                $path = $match.Groups[1].Value.Replace('\\', '\')
                if ((Test-Path -LiteralPath $path) -and -not $roots.Contains($path)) { $roots.Add($path) }
            }
        }
    }
    @($roots)
}

<#
    Reads and parses one appmanifest_<appid>.acf. StateFlags bit 4 means the app is
    fully installed; a manifest present without that bit is a partial download.
#>
function Get-SteamManifest {
    param(
        [Parameter(Mandatory)][int]$AppId,
        [string[]]$LibraryRoot
    )

    if (-not $LibraryRoot -or $LibraryRoot.Count -eq 0) { $LibraryRoot = Resolve-SteamLibrary }
    $fileName = 'appmanifest_{0}.acf' -f $AppId

    foreach ($root in $LibraryRoot) {
        $steamapps = if ((Split-Path -Leaf $root) -eq 'steamapps') { $root } else { Join-Path $root 'steamapps' }
        $manifestPath = Join-Path $steamapps $fileName
        if (-not (Test-Path -LiteralPath $manifestPath)) { continue }

        $text = Get-Content -LiteralPath $manifestPath -Raw
        $read = {
            param([string]$Key)
            $m = [regex]::Match($text, '"' + [regex]::Escape($Key) + '"\s+"([^"]*)"')
            if ($m.Success) { $m.Groups[1].Value } else { $null }
        }
        $installDir = & $read 'installdir'
        $stateFlags = & $read 'StateFlags'
        $payload = [pscustomobject]@{
            AppId         = $AppId
            Name          = (& $read 'name')
            BuildId       = (& $read 'buildid')
            StateFlags    = if ($stateFlags) { [int]$stateFlags } else { 0 }
            SizeOnDisk    = (& $read 'SizeOnDisk')
            InstallDir    = $installDir
            LastUpdated   = (& $read 'LastUpdated')
            ManifestPath  = $manifestPath
            LibraryRoot   = $steamapps
            InstallPath   = if ($installDir) { Join-Path (Join-Path $steamapps 'common') $installDir } else { $null }
        }
        $payload | Add-Member -MemberType NoteProperty -Name FullyInstalled -Value ([bool]($payload.StateFlags -band 4))
        return $payload
    }
    $null
}

# ------------------------------------------------------------------ hashing/PE

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Read-U32 {
    param([byte[]]$Bytes, [int]$Offset)
    [BitConverter]::ToUInt32($Bytes, $Offset)
}

<#
    Minimal PE reader: machine, subsystem, link timestamp, sections and imported
    module names. Deliberately independent of the Telltale inventory tool so a
    non-Telltale engine can be inspected with the same code.
#>
function Read-PeFile {
    param([Parameter(Mandatory)][string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 0x40) { throw "Not a PE file (too short): $Path" }
    $pe = [BitConverter]::ToInt32($bytes, 0x3C)
    if ($pe -lt 0 -or ($pe + 24) -gt $bytes.Length) { throw "Not a PE file (bad e_lfanew): $Path" }
    if ([Text.Encoding]::ASCII.GetString($bytes, $pe, 4) -ne "PE`0`0") { throw "Missing PE signature: $Path" }

    $machine      = [BitConverter]::ToUInt16($bytes, $pe + 4)
    $sectionCount = [BitConverter]::ToUInt16($bytes, $pe + 6)
    $linkStamp    = [BitConverter]::ToUInt32($bytes, $pe + 8)
    $optSize      = [BitConverter]::ToUInt16($bytes, $pe + 20)
    $optMagic     = [BitConverter]::ToUInt16($bytes, $pe + 24)
    $is64         = ($optMagic -eq 0x20B)
    $subsystem    = [BitConverter]::ToUInt16($bytes, $pe + 24 + 68)
    $dirOffset    = $pe + 24 + $(if ($is64) { 112 } else { 96 })
    $importRva    = [BitConverter]::ToUInt32($bytes, $dirOffset + 8)

    $sectionTable = $pe + 24 + $optSize
    $sections = @()
    for ($i = 0; $i -lt $sectionCount; $i++) {
        $o = $sectionTable + ($i * 40)
        if (($o + 40) -gt $bytes.Length) { break }
        $sections += [pscustomobject]@{
            Name       = [Text.Encoding]::ASCII.GetString($bytes, $o, 8).Trim([char]0)
            VirtualSize = [BitConverter]::ToUInt32($bytes, $o + 8)
            VirtualAddr = [BitConverter]::ToUInt32($bytes, $o + 12)
            RawSize    = [BitConverter]::ToUInt32($bytes, $o + 16)
            RawPointer = [BitConverter]::ToUInt32($bytes, $o + 20)
        }
    }

    $rvaToOffset = {
        param([uint32]$Rva)
        foreach ($s in $sections) {
            if ($s.VirtualSize -eq 0) { continue }
            $span = [Math]::Max($s.VirtualSize, $s.RawSize)
            if ($Rva -ge $s.VirtualAddr -and $Rva -lt ($s.VirtualAddr + $span)) {
                return [int]($Rva - $s.VirtualAddr + $s.RawPointer)
            }
        }
        return -1
    }

    $imports = @()
    if ($importRva -ne 0) {
        $off = & $rvaToOffset $importRva
        if ($off -gt 0) {
            for ($d = 0; $d -lt 512; $d++) {
                $o = $off + ($d * 20)
                if (($o + 20) -gt $bytes.Length) { break }
                $nameRva = [BitConverter]::ToUInt32($bytes, $o + 12)
                if ($nameRva -eq 0) { break }
                $nameOff = & $rvaToOffset $nameRva
                if ($nameOff -le 0 -or $nameOff -ge $bytes.Length) { continue }
                $end = $nameOff
                while ($end -lt $bytes.Length -and $bytes[$end] -ne 0) { $end++ }
                $imports += [Text.Encoding]::ASCII.GetString($bytes, $nameOff, $end - $nameOff)
            }
        }
    }

    $stamp = if ($linkStamp -gt 0) { ([DateTimeOffset]::FromUnixTimeSeconds([int64]$linkStamp)).UtcDateTime.ToString('yyyy-MM-dd') } else { $null }

    [pscustomobject]@{
        Machine         = if ($machine -eq 0x14C) { 'x86' } elseif ($machine -eq 0x8664) { 'x64' } else { ('machine-0x{0:X4}' -f $machine) }
        Subsystem       = switch ($subsystem) { 2 { 'GUI' } 3 { 'console' } default { "subsystem-$subsystem" } }
        LinkTimestampUtc = $stamp
        SectionCount    = $sectionCount
        SectionNames    = @($sections | ForEach-Object { $_.Name })
        ImportedModules = @($imports | Sort-Object -Unique)
        HasBindSection  = [bool](@($sections | Where-Object { $_.Name -eq '.bind' }).Count)
        SizeBytes       = $bytes.Length
    }
}

<#
    Host-like strings inside a binary. Certificates dominate the output of signed
    Windows executables, so the well-known PKI hosts are filtered out and only
    candidates that look like a service are returned.
#>
function Get-EndpointStrings {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MaxBytes = 48MB
    )

    $info = Get-Item -LiteralPath $Path
    if ($info.Length -gt $MaxBytes) { return @() }

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    # Latin-1 maps every byte to one char, so offsets stay aligned and regex works
    # on both ASCII and UTF-16LE text (the NULs are skipped by the character class).
    $text = [Text.Encoding]::GetEncoding(28591).GetString($bytes)
    $pattern = '([a-z0-9][a-z0-9\-]{0,40}\.)+(com|net|org|io|tv|gg)(:\d{1,5})?(/[a-z0-9\.\-_/?=&%{}]{0,60})?'
    $skip = 'digicert\.com|verisign\.com|symantec\.com|thawte\.com|globalsign\.com|sectigo\.com|usertrust\.com|godaddy\.com|microsoft\.com|schemas\.|w3\.org|xmlsoap\.org|opensource\.org|lua\.org|havok\.com|paint\.net|system\.'
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($match in [regex]::Matches($text, $pattern, 'IgnoreCase')) {
        $value = $match.Value.ToLowerInvariant()
        if ($value -match $skip) { continue }
        if (-not $found.Contains($value)) { $found.Add($value) }
    }
    @($found | Sort-Object)
}

# ------------------------------------------------------------------------ INI

<#
    Parses INI text into a section-ordered hashtable. Values keep their inline
    formatting so a round trip does not silently rewrite a game's settings.
#>
function ConvertFrom-IniText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $document = [ordered]@{}
    $current = 'General'
    $document[$current] = [ordered]@{}
    foreach ($rawLine in ($Text -split "`r?`n")) {
        $line = $rawLine.Trim()
        if (-not $line) { continue }
        if ($line.StartsWith(';') -or $line.StartsWith('#')) { continue }
        $sectionMatch = [regex]::Match($line, '^\[([^\]]+)\]$')
        if ($sectionMatch.Success) {
            $current = $sectionMatch.Groups[1].Value.Trim()
            if (-not $document.Contains($current)) { $document[$current] = [ordered]@{} }
            continue
        }
        $pair = [regex]::Match($line, '^([^=]+?)\s*=\s*(.*)$')
        if ($pair.Success) {
            $document[$current][$pair.Groups[1].Value.Trim()] = $pair.Groups[2].Value.Trim()
        }
    }
    $document
}

function Read-IniFile {
    param([Parameter(Mandatory)][string]$Path)
    ConvertFrom-IniText -Text (Get-Content -LiteralPath $Path -Raw)
}

<#
    Generates the Renegade Free Dedicated Server master config. GameType = LAN is
    the whole point: the server then needs no Westwood Online nickname, password
    or serial, and registers with nothing.
#>
# The server's INI parser is a 2002-era reader that expects CRLF line endings;
# LF-only files were read far enough to find MapName= and then lost the map cycle.
function ConvertTo-CrlfText {
    param([string[]]$Lines)
    ((@($Lines) -join "`r`n").TrimEnd("`r", "`n")) + "`r`n"
}

function New-RenegadeLanServerIni {
    param(
        [int]$Port = 0,
        # The server resolves Config relative to its map directory ("data\<Config>").
        # '..' keeps the generated settings file in the host directory instead of
        # writing through the junction into the installation's Data folder.
        [string]$GameConfig = '..\svrcfg_lan.ini',
        [switch]$AllowRemoteAdmin,
        [string]$RemoteAdminPassword = ''
    )

    $admin = if ($AllowRemoteAdmin) { 'true' } else { 'false' }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in @(
        ';',
        ';  Generated by the preservation program. Do not edit: regenerate instead.',
        ';',
        ';  Renegade Free Dedicated Server, LAN mode. No Westwood Online account is',
        ';  configured because GameType = LAN never contacts a matchmaking service.',
        ';',
        '',
        '[Server]',
        '',
        ('Config = {0}' -f $GameConfig),
        'GameType = LAN',
        'Nickname =',
        'Password =',
        'Serial =',
        'LoginServer =',
        ('Port = {0}' -f $Port),
        'GameSpyGamePort = 0',
        'GameSpyQueryPort = 0',
        'BandwidthUp = 0',
        'NetUpdateRate = 10',
        ('AllowRemoteAdmin = {0}' -f $admin),
        ('RemoteAdminPassword = {0}' -f $RemoteAdminPassword),
        'RemoteAdminIP =',
        'RemoteAdminPort =',
        ''
    )) { $lines.Add($line) }

    for ($slave = 1; $slave -le 7; $slave++) {
        foreach ($line in @(
            ('[Slave{0}]' -f $slave),
            'Enable = 0',
            ('Config = {0}' -f $GameConfig),
            'Nickname =',
            'Password =',
            'BandwidthUp = 0',
            'Serial =',
            'Port = 0',
            'RemoteAdminPort =',
            '',
            ''
        )) { $lines.Add($line) }
    }

    (ConvertTo-CrlfText -Lines $lines)
}

<#
    Generates the per-game settings file named by Config=. Values here are the
    server's own defaults for a listen/LAN game; a caller can override the map.
#>
function New-RenegadeLanGameConfig {
    param(
        [string]$MapName = 'C&C_Field.mix',
        [string[]]$MapCycle,
        [int]$TimeLimitMinutes = 30,
        [string]$ConfigName = 'LAN Preservation Server'
    )

    if (-not $MapCycle -or @($MapCycle).Count -eq 0) { $MapCycle = @($MapName) }
    elseif (@($MapCycle) -notcontains $MapName) { $MapCycle = @($MapName) + @($MapCycle) }

    # Map cycling is on by default and the server refuses to start with an empty
    # cycle, so the generated file always names at least one installed map.
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in @(
        '[Settings]',
        ('ConfigName={0}' -f $ConfigName),
        ('MapName={0}' -f $MapName),
        ('TimeLimitMinutes={0}' -f $TimeLimitMinutes),
        'RadarMode=1',
        'IsAutoRestart=yes',
        'IsPassworded=no',
        'IsDedicated=yes',
        'bPassword=',
        'IsQuickMatch=no',
        'IsLaddered=no',
        'UseLagReduction=yes',
        'RemixTeams=yes',
        'CanRepairBuildings=yes',
        'DriverIsAlwaysGunner=yes',
        'SpawnWeapons=no',
        'IsFriendlyFirePermitted=no',
        'DoMapsLoop=yes',
        'IsTeamChangingAllowed=yes',
        'IsClanGame=no'
    )) { $lines.Add($line) }

    for ($i = 0; $i -lt @($MapCycle).Count; $i++) {
        $lines.Add(('MapName{0:D2}={1}' -f $i, $MapCycle[$i]))
    }

    (ConvertTo-CrlfText -Lines $lines)
}

# --------------------------------------------------------------------- library

function Get-GameRegistry {
    param([string]$Path)

    if (-not $Path) { $Path = Join-Path (Get-PreservationRepoRoot) 'registry\games.json' }
    if (-not (Test-Path -LiteralPath $Path)) { throw "Game registry not found: $Path" }
    $document = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $document
}

function Get-GameProfile {
    param(
        [Parameter(Mandatory)][string]$GameId,
        [string]$RegistryPath
    )

    $registry = Get-GameRegistry -Path $RegistryPath
    $entry = @($registry.games | Where-Object { $_.id -eq $GameId })
    if ($entry.Count -eq 0) { throw "Unknown game id '$GameId' (not in the registry)" }
    $entry = $entry[0]
    if (-not $entry.profile) { throw "Game '$GameId' has no profile recorded in the registry" }

    $profilePath = Resolve-RepoPath -Path $entry.profile
    if (-not (Test-Path -LiteralPath $profilePath)) { throw "Profile not found for '$GameId': $profilePath" }
    [pscustomobject]@{
        Entry       = $entry
        ProfilePath = $profilePath
        Profile     = (Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json)
    }
}

# -------------------------------------------------------------- path integrity

<#
    True when Path is inside Root. Used to refuse writing generated files into a
    game installation before anything is created.
#>
function Test-PathUnder {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    if ($fullPath.Equals($fullRoot, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    $fullPath.StartsWith($fullRoot + '\', [StringComparison]::OrdinalIgnoreCase)
}

<#
    Whether a directory can be created/written. A path that does not exist yet is
    judged by its nearest existing ancestor, which is what a first launch does.
#>
function Test-DirectoryWritable {
    param([Parameter(Mandatory)][string]$Path)

    $candidate = [System.IO.Path]::GetFullPath($Path)
    while ($candidate -and -not (Test-Path -LiteralPath $candidate)) {
        $parent = Split-Path -Parent $candidate
        if (-not $parent -or $parent -eq $candidate) { return $false }
        $candidate = $parent
    }
    if (-not (Test-Path -LiteralPath $candidate -PathType Container)) { return $false }
    try {
        $probe = Join-Path $candidate ('.preservation-probe-{0}' -f [guid]::NewGuid().ToString('N'))
        [System.IO.File]::WriteAllText($probe, 'probe')
        Remove-Item -LiteralPath $probe -Force -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

# ------------------------------------------------------- Renegade LAN host bits

<#
    A junction lets the dedicated server see the installation's Data folder while
    the server's own working directory holds only generated files. Junctions do
    not need elevation, unlike symlinks, and nothing is written through it.
#>
function New-DirectoryJunction {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Target
    )

    if (Test-Path -LiteralPath $Path) { throw "Junction path already exists: $Path" }
    if (-not (Test-Path -LiteralPath $Target -PathType Container)) { throw "Junction target is not a directory: $Target" }

    $output = & cmd.exe /c mklink /J "`"$Path`"" "`"$Target`"" 2>&1
    if ($LASTEXITCODE -ne 0) { throw ("mklink failed ({0}): {1}" -f $LASTEXITCODE, ($output | Out-String).Trim()) }

    $item = Get-Item -LiteralPath $Path -Force
    if (-not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        throw "Created path is not a reparse point: $Path"
    }
    $item
}

<#
    Removes a junction itself. rmdir on a junction never touches the target's
    contents, which is exactly why it is used instead of a recursive delete.
#>
function Remove-DirectoryJunction {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force
    if (-not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        throw "Refusing to remove a real directory as a junction: $Path"
    }
    $output = & cmd.exe /c rmdir "`"$Path`"" 2>&1
    if ($LASTEXITCODE -ne 0) { throw ("rmdir failed ({0}): {1}" -f $LASTEXITCODE, ($output | Out-String).Trim()) }
}

function Get-RenegadeLanStatePath {
    param([string]$StatePath)
    if ($StatePath) { return $StatePath }
    Join-Path $env:LOCALAPPDATA 'GamePreservation\renegade-lan'
}

function Get-RenegadeLanHostStatus {
    param([string]$StatePath)

    $root = Get-RenegadeLanStatePath -StatePath $StatePath
    $stateFile = Join-Path $root 'host.json'
    if (-not (Test-Path -LiteralPath $stateFile)) {
        return [pscustomobject]@{ Running = $false; StatePath = $root; State = $null; Process = $null; Endpoints = @() }
    }
    $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
    $recorded = if ($state.PSObject.Properties.Name -contains 'processIds') { @($state.processIds) } else { @($state.processId) }
    $live = @($recorded | ForEach-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
    [pscustomobject]@{
        Running   = @($live).Count -gt 0
        StatePath = $root
        State     = $state
        Process   = @($live | Select-Object -First 1)
        ProcessIds = @($recorded)
        Endpoints = @($state.endpoints)
    }
}

<#
    A process and its descendants, resolved from one WMI snapshot. Renegade's
    launcher stub runs Server.dat as a separate process, so anything that wants to
    observe or stop "the server" has to follow the tree rather than one pid.
#>
function Get-ProcessTree {
    param([Parameter(Mandatory)][int]$Root)

    $snapshot = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Select-Object ProcessId, ParentProcessId)
    $ids = New-Object System.Collections.Generic.List[int]
    $ids.Add($Root)
    $added = $true
    while ($added) {
        $added = $false
        foreach ($proc in $snapshot) {
            if ($ids -contains [int]$proc.ParentProcessId -and -not $ids.Contains([int]$proc.ProcessId)) {
                $ids.Add([int]$proc.ProcessId)
                $added = $true
            }
        }
    }
    @($ids)
}

<#
    UDP endpoints owned by one process. Get-NetUDPEndpoint is used first because
    it reports the local address too; netstat is the fallback when the module is
    not available.
#>
function Get-ProcessUdpEndpoints {
    param([Parameter(Mandatory)][int]$ProcessId)

    $endpoints = New-Object System.Collections.Generic.List[string]
    # A process that has no UDP sockets (or has already exited) is a normal answer,
    # not an error, so nothing here is allowed to throw.
    if (Get-Command Get-NetUDPEndpoint -ErrorAction SilentlyContinue) {
        foreach ($entry in @(Get-NetUDPEndpoint -OwningProcess $ProcessId -ErrorAction SilentlyContinue)) {
            $endpoints.Add(('{0}:{1}' -f $entry.LocalAddress, $entry.LocalPort))
        }
    } else {
        foreach ($line in @(& netstat.exe -ano -p UDP 2>$null)) {
            $parts = @(($line -split '\s+') | Where-Object { $_ })
            $pidColumn = $parts[-1]
            if ($parts.Count -ge 4 -and $pidColumn -eq [string]$ProcessId) { $endpoints.Add($parts[1]) }
        }
    }
    @($endpoints | Sort-Object -Unique)
}

<#
    Builds a self-contained host directory and starts the shipped Renegade Free
    Dedicated Server in LAN mode. The installation is only read: the server binary
    and its data container are copied, the game's map Data folder is exposed
    through a junction, and every generated file lives under the state root.
#>
function Start-RenegadeLanHost {
    param(
        [string]$GameId = 'cnc-renegade-steam-2229890',
        [string]$InstallRoot,
        [int]$Port = 0,
        [string]$MapName = 'C&C_Field.mix',
        [int]$TimeLimitMinutes = 30,
        [string]$StatePath,
        [int]$ObserveSeconds = 10,
        [switch]$SkipHashCheck,
        [string]$RegistryPath
    )

    $resolved = Get-GameProfile -GameId $GameId -RegistryPath $RegistryPath
    $profile = $resolved.Profile

    if (-not $InstallRoot) {
        $manifest = Get-SteamManifest -AppId ([int]$profile.steam.appId)
        if ($manifest -and $manifest.InstallPath -and (Test-Path -LiteralPath $manifest.InstallPath)) {
            $InstallRoot = $manifest.InstallPath
        }
    }
    if (-not $InstallRoot) { throw "Install root not found for '$GameId'; pass -InstallRoot" }
    $InstallRoot = (Resolve-Path -LiteralPath $InstallRoot).ProviderPath

    $roles = @($profile.binaries | ForEach-Object { $_.role })
    if ($roles -notcontains 'dedicated-server') { throw "Profile for '$GameId' does not declare a dedicated-server binary" }
    $serverEntry = @($profile.binaries | Where-Object { $_.role -eq 'dedicated-server' })[0]
    $serverRelative = [string]$serverEntry.path
    $serverPath = Join-Path $InstallRoot $serverRelative
    if (-not (Test-Path -LiteralPath $serverPath)) { throw "Dedicated server not found: $serverPath" }

    if (-not $SkipHashCheck) {
        $actual = Get-FileSha256 -Path $serverPath
        if ($actual -ne [string]$serverEntry.sha256) {
            throw ("Dedicated server hash does not match the profile.{0}  expected {1}{0}  actual   {2}" -f [Environment]::NewLine, $serverEntry.sha256, $actual)
        }
    }

    $stateRoot = Get-RenegadeLanStatePath -StatePath $StatePath
    if (Test-PathUnder -Path $stateRoot -Root $InstallRoot) {
        throw "Refusing to use a state directory inside the game installation: $stateRoot"
    }

    $existing = Get-RenegadeLanHostStatus -StatePath $stateRoot
    if ($existing.Running) { throw "A LAN host is already running (pid $($existing.State.processId)); stop it first" }
    if (Test-Path -LiteralPath $stateRoot) {
        $leftoverData = Join-Path $stateRoot 'host\Data'
        if (Test-Path -LiteralPath $leftoverData) { Remove-DirectoryJunction -Path $leftoverData }
        Remove-Item -LiteralPath $stateRoot -Recurse -Force
    }

    $hostDir = Join-Path $stateRoot 'host'
    $logDir = Join-Path $stateRoot 'logs'
    New-Item -ItemType Directory -Path $hostDir -Force | Out-Null
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null

    Copy-Item -LiteralPath $serverPath -Destination (Join-Path $hostDir (Split-Path -Leaf $serverPath)) -Force
    $serverDir = Split-Path -Parent $serverPath
    $dataContainer = Join-Path $serverDir 'Server.dat'
    if (Test-Path -LiteralPath $dataContainer) {
        Copy-Item -LiteralPath $dataContainer -Destination (Join-Path $hostDir 'Server.dat') -Force
    }
    # The Steam-edition RenegadeServer.exe is a launcher stub that refuses to start
    # without its .lcf next to it (it shows a modal 'Launcher config file missing'
    # and never initialises networking). The .lcf names the payload (RUN=server.dat)
    # and the registry keys the SKU check reads.
    foreach ($lcf in @(Get-ChildItem -LiteralPath $serverDir -Filter '*.lcf' -File -ErrorAction SilentlyContinue)) {
        Copy-Item -LiteralPath $lcf.FullName -Destination (Join-Path $hostDir $lcf.Name) -Force
    }
    $banList = Join-Path $serverDir 'banlist.txt'
    if (Test-Path -LiteralPath $banList) { Copy-Item -LiteralPath $banList -Destination (Join-Path $hostDir 'banlist.txt') -Force }

    # RenegadeServer.exe starts Server.dat as a second process, and that payload
    # imports the game's own runtime libraries (BandTest, binkw32, mss32), which
    # live in the game root one level above RenegadeFDS. Without them Windows shows
    # a modal 'Server.dat - System Error' and the simulation never initialises, so
    # every import that resolves inside the installation is copied next to it.
    $supportFiles = New-Object System.Collections.Generic.List[string]
    $missingSupport = New-Object System.Collections.Generic.List[string]
    $payloadPath = Join-Path $serverDir 'Server.dat'
    $importNames = New-Object System.Collections.Generic.List[string]
    foreach ($binaryPath in @($serverPath, $payloadPath)) {
        if (-not (Test-Path -LiteralPath $binaryPath)) { continue }
        foreach ($import in @((Read-PeFile -Path $binaryPath).ImportedModules)) {
            if ($import -like 'api-ms-*') { continue }
            if (-not $importNames.Contains($import)) { $importNames.Add($import) }
        }
    }
    # Scripts.dll is loaded by name at runtime rather than imported.
    if (-not $importNames.Contains('Scripts.dll')) { $importNames.Add('Scripts.dll') }
    foreach ($name in $importNames) {
        $resolved = $null
        foreach ($candidateDir in @($serverDir, $InstallRoot)) {
            $candidate = Join-Path $candidateDir $name
            if (Test-Path -LiteralPath $candidate) { $resolved = $candidate; break }
        }
        if (-not $resolved) { $missingSupport.Add($name); continue }
        $target = Join-Path $hostDir $name
        if (-not (Test-Path -LiteralPath $target)) {
            Copy-Item -LiteralPath $resolved -Destination $target -Force
            $supportFiles.Add($name)
        }
    }

    $dataDir = Join-Path $InstallRoot 'Data'
    if (-not (Test-Path -LiteralPath $dataDir -PathType Container)) { throw "Game Data directory not found: $dataDir" }
    $junction = New-DirectoryJunction -Path (Join-Path $hostDir 'Data') -Target $dataDir

    # The map cycle is generated from the maps actually installed, so the server's
    # 'map cycling is enabled but there are no maps in the cycle' refusal cannot
    # happen and no map is claimed that is not on disk.
    $availableMaps = @(Get-ChildItem -LiteralPath $dataDir -Filter '*.mix' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'C&C_*' } | ForEach-Object { $_.Name } | Sort-Object)
    if (@($availableMaps).Count -eq 0) { throw "No multiplayer maps (C&C_*.mix) found in $dataDir" }
    if (@($availableMaps) -notcontains $MapName) {
        throw ("Map '{0}' is not installed. Installed maps: {1}" -f $MapName, (@($availableMaps) -join ', '))
    }
    $mapCycle = @($availableMaps | Select-Object -First 12)

    $serverIniPath = Join-Path $hostDir 'Server.ini'
    $gameIniPath = Join-Path $hostDir 'svrcfg_lan.ini'
    [System.IO.File]::WriteAllText($serverIniPath, (New-RenegadeLanServerIni -Port $Port), [Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($gameIniPath, (New-RenegadeLanGameConfig -MapName $MapName -MapCycle $mapCycle -TimeLimitMinutes $TimeLimitMinutes), [Text.UTF8Encoding]::new($false))

    $stdoutLog = Join-Path $logDir 'server.out.log'
    $stderrLog = Join-Path $logDir 'server.err.log'
    $startedUtc = (Get-Date).ToUniversalTime().ToString('u')
    $executable = Join-Path $hostDir (Split-Path -Leaf $serverPath)
    # Launch through WMI so the server is detached from this console. A GUI-subsystem
    # child started directly from a console keeps the invoking shell's handles open,
    # which leaves the caller waiting long after this function has returned. cmd.exe
    # carries the redirection so the server's own console output still lands in a log.
    $commandLine = 'cmd.exe /c ""{0}" > "{1}" 2> "{2}""' -f $executable, $stdoutLog, $stderrLog
    $created = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
        CommandLine      = $commandLine
        CurrentDirectory = $hostDir
    }
    if ($created.ReturnValue -ne 0) {
        throw ("Win32_Process.Create failed with {0}" -f $created.ReturnValue)
    }

    # Record the server stub itself rather than the cmd.exe wrapper WMI created.
    $process = $null
    $startDeadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $startDeadline -and -not $process) {
        Start-Sleep -Milliseconds 300
        $candidate = @(Get-CimInstance Win32_Process -Filter "Name='RenegadeServer.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ExecutablePath -and (Test-PathUnder -Path $_.ExecutablePath -Root $hostDir) })
        if (@($candidate).Count -gt 0) {
            $process = Get-Process -Id $candidate[0].ProcessId -ErrorAction SilentlyContinue
        }
    }
    if (-not $process) { throw 'The Renegade server stub did not appear after launch' }

    $deadline = (Get-Date).AddSeconds([Math]::Max($ObserveSeconds, 1))
    $tree = @($process.Id)
    $endpoints = @()
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 700
        $tree = @(Get-ProcessTree -Root $process.Id)
        $endpoints = @(@(foreach ($procId in $tree) { Get-ProcessUdpEndpoints -ProcessId $procId }) | Sort-Object -Unique)
        if (@($endpoints).Count -gt 0) {
            Start-Sleep -Milliseconds 1200
            $tree = @(Get-ProcessTree -Root $process.Id)
            $endpoints = @(@(foreach ($procId in $tree) { Get-ProcessUdpEndpoints -ProcessId $procId }) | Sort-Object -Unique)
            break
        }
        $liveNow = @($tree | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
        if ($liveNow.Count -eq 0) { break }
    }

    $tree = @(Get-ProcessTree -Root $process.Id)
    $live = @($tree | ForEach-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
    $alive = @($live).Count -gt 0
    $windowTitle = (@($live | Where-Object { $_.MainWindowTitle } | ForEach-Object { $_.MainWindowTitle }) -join ' | ')
    $process.Refresh()
    $exitCode = if (-not $alive -and $process.HasExited) { $process.ExitCode } else { $null }
    $stdoutText = if (Test-Path -LiteralPath $stdoutLog) { Get-Content -LiteralPath $stdoutLog -Raw -ErrorAction SilentlyContinue } else { '' }
    $stderrText = if (Test-Path -LiteralPath $stderrLog) { Get-Content -LiteralPath $stderrLog -Raw -ErrorAction SilentlyContinue } else { '' }
    $logLines = @((@($stdoutText, $stderrText) -join "`n") -split "`r?`n" | Where-Object { $_.Trim() })

    $state = [ordered]@{
        schemaVersion = 1
        gameId        = $GameId
        mode          = 'LAN'
        startedUtc    = $startedUtc
        processId     = $process.Id
        processIds    = @($tree)
        exited        = -not $alive
        exitCode      = $exitCode
        installRoot   = $InstallRoot
        hostDirectory = $hostDir
        serverIni     = $serverIniPath
        gameIni       = $gameIniPath
        junction      = (Join-Path $hostDir 'Data')
        junctionTarget = $dataDir
        port          = $Port
        endpoints     = @($endpoints)
        windowTitle   = $windowTitle
        supportFiles  = @($supportFiles)
        missingSupport = @($missingSupport)
        logs          = [ordered]@{ stdout = $stdoutLog; stderr = $stderrLog; lines = $logLines }
        hashVerified  = (-not $SkipHashCheck.IsPresent)
    }
    $stateFile = Join-Path $stateRoot 'host.json'
    $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $stateFile -Encoding UTF8

    [pscustomobject]$state
}

<#
    Stops the recorded host, removes the junction and deletes the generated host
    directory. The log is kept under the state root as the run's evidence.
#>
function Stop-RenegadeLanHost {
    param([string]$StatePath)

    $root = Get-RenegadeLanStatePath -StatePath $StatePath
    $stateFile = Join-Path $root 'host.json'
    if (-not (Test-Path -LiteralPath $stateFile)) {
        return [pscustomobject]@{ Stopped = $false; Reason = 'no host state recorded'; StatePath = $root }
    }

    $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
    $hostDir = [string]$state.hostDirectory
    $recorded = if ($state.PSObject.Properties.Name -contains 'processIds') { @($state.processIds) } else { @($state.processId) }
    if (@($recorded).Count -eq 0) { $recorded = @($state.processId) }

    $killed = New-Object System.Collections.Generic.List[int]
    foreach ($procId in @($recorded | Sort-Object -Descending)) {
        $live = Get-Process -Id $procId -ErrorAction SilentlyContinue
        if (-not $live) { continue }
        # Only ever kill an image that lives in the generated host directory.
        $imagePath = $null
        try { $imagePath = (Get-CimInstance Win32_Process -Filter "ProcessId=$procId" -ErrorAction Stop).ExecutablePath } catch { $imagePath = $null }
        if ($imagePath -and -not (Test-PathUnder -Path $imagePath -Root $hostDir)) { continue }
        Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
        $killed.Add($procId)
    }
    # Sweep anything still running an image out of the host directory (a child the
    # server spawned after the state file was written). Scoped by image path, so no
    # process outside the generated directory can be hit by name.
    $leftovers = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and (Test-PathUnder -Path $_.ExecutablePath -Root $hostDir) })
    foreach ($leftover in $leftovers) {
        Stop-Process -Id $leftover.ProcessId -Force -ErrorAction SilentlyContinue
        $killed.Add([int]$leftover.ProcessId)
    }

    $waited = 0
    while ($waited -lt 100 -and @($killed | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue }).Count -gt 0) {
        Start-Sleep -Milliseconds 100
        $waited++
    }
    $stoppedProcess = (@($killed | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue }).Count -eq 0)
    $junction = Join-Path $hostDir 'Data'
    if (Test-Path -LiteralPath $junction) { Remove-DirectoryJunction -Path $junction }
    if (Test-Path -LiteralPath (Join-Path $root 'logs')) {
        foreach ($log in @(Get-ChildItem -LiteralPath (Join-Path $root 'logs') -File)) {
            Copy-Item -LiteralPath $log.FullName -Destination (Join-Path $root ('last-run-' + $log.Name)) -Force
        }
    }
    # A just-terminated process can keep a loaded DLL locked for a moment, so the
    # delete is retried before it is allowed to fail.
    if (Test-Path -LiteralPath $hostDir) {
        $attempt = 0
        while ($attempt -lt 5 -and (Test-Path -LiteralPath $hostDir)) {
            $attempt++
            try { Remove-Item -LiteralPath $hostDir -Recurse -Force -ErrorAction Stop }
            catch { Start-Sleep -Milliseconds 300 }
        }
    }
    Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue

    [pscustomobject]@{
        Stopped    = $true
        StatePath  = $root
        ProcessId  = [int]$state.processId
        ProcessExited = $stoppedProcess
        HostRemoved = -not (Test-Path -LiteralPath $hostDir)
    }
}

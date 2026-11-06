#Requires -Version 5.1
<#
.SYNOPSIS
    Publishes the built game packages as GitHub releases, one per tag, and verifies the
    uploaded bytes by downloading them again.

.DESCRIPTION
    Takes the zips and manifests produced by New-ReleasePackage.ps1 in dist/ and reconciles
    each one with its release:

      * creates the release for the manifest's tag when it does not exist;
      * rewrites the release body when it does not match the package's PATCH.md;
      * deletes assets that no longer belong to the package and uploads missing or
        size-mismatched ones;
      * downloads every asset back from its public URL and compares its SHA-256 with the
        local package, so "uploaded" and "served identically" are the same claim.

    Running it twice is a no-op: the second run reports each tag as up to date. Nothing is
    written to the repository, and the token is read from the git credential helper and
    never printed or written anywhere.

.PARAMETER Tag
    Publish only the package whose manifest carries this tag. Defaults to every manifest.

.PARAMETER OutputDirectory
    Where the zips and manifests are. Defaults to dist/.

.PARAMETER Repository
    owner/name. Defaults to the origin remote of the current repository.

.PARAMETER DryRun
    Report what would change without calling any write endpoint.

.PARAMETER SkipVerify
    Skip the download-and-hash check. The report then only claims what was uploaded, not
    what is served, so the summary says so.

.PARAMETER AsJson
    Emit one JSON object per package instead of a table.

.EXAMPLE
    .\tools\Publish-ReleasePackage.ps1 -DryRun

.EXAMPLE
    .\tools\Publish-ReleasePackage.ps1 -Tag twd-s2-v1.0.0

.OUTPUTS
    0 everything reconciled and verified; 20 no credential; 21 cannot determine the
    repository; 22 the API refused a call; 23 a served asset differs from the local package.
#>
[CmdletBinding()]
param(
    [string]$Tag = '',
    [string]$OutputDirectory = '',
    [string]$Repository = '',
    [switch]$DryRun,
    [switch]$SkipVerify,
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$repo = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $repo
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repo 'dist' }
if (-not (Test-Path -LiteralPath $OutputDirectory)) { throw "No package directory at $OutputDirectory. Run New-ReleasePackage.ps1 first." }

function Get-GitHubToken {
    $request = "protocol=https`nhost=github.com`n`n"
    $lines = $request | & git credential fill 2>$null
    foreach ($line in $lines) {
        if ($line -match '^password=(.+)$') { return $Matches[1] }
    }
    return ''
}

function Get-RepositorySlug {
    if ($Repository) { return $Repository }
    $url = (& git remote get-url origin 2>$null)
    if (-not $url) { return '' }
    if ($url -match 'github\.com[:/](?<slug>[^/]+/[^/]+?)(\.git)?$') { return $Matches['slug'] }
    return ''
}

$slug = Get-RepositorySlug
if (-not $slug) { Write-Error 'Cannot determine the GitHub repository; pass -Repository owner/name.'; exit 21 }

$token = Get-GitHubToken
if (-not $token) {
    Write-Error 'No GitHub credential available from the git credential helper. Sign in with git push once, then retry.'
    exit 20
}

$apiBase = "https://api.github.com/repos/$slug"
$headers = @{
    Authorization          = "Bearer $token"
    Accept                 = 'application/vnd.github+json'
    'User-Agent'           = 'telltale-legacy-publisher'
    'X-GitHub-Api-Version' = '2022-11-28'
}

function Invoke-Api {
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        $Body = $null,
        [string]$ContentType = 'application/json'
    )

    $parameters = @{ Method = $Method; Uri = $Uri; Headers = $headers; ErrorAction = 'Stop' }
    if ($null -ne $Body) {
        if ($Body -is [string]) {
            $parameters['Body'] = $Body
            $parameters['ContentType'] = $ContentType
        } else {
            $parameters['Body'] = ($Body | ConvertTo-Json -Depth 6)
            $parameters['ContentType'] = 'application/json'
        }
    }
    try {
        return Invoke-RestMethod @parameters
    } catch {
        $detail = ''
        if ($_.Exception.Response) {
            try {
                $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $detail = $reader.ReadToEnd()
            } catch { $detail = '' }
        }
        throw ("{0} {1} failed: {2} {3}" -f $Method, $Uri, $_.Exception.Message, $detail)
    }
}

function Get-ZipText {
    param([Parameter(Mandatory)][string]$ZipPath, [Parameter(Mandatory)][string]$EntryName)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $entry = $archive.Entries | Where-Object { $_.FullName -eq $EntryName } | Select-Object -First 1
        if (-not $entry) { throw "No $EntryName inside $ZipPath" }
        $reader = New-Object System.IO.StreamReader($entry.Open())
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally {
        $archive.Dispose()
    }
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function New-ReleaseBody {
    param([Parameter(Mandatory)]$Manifest, [Parameter(Mandatory)][string]$Notes)

    return (
        $Notes.TrimEnd() + "`n`n---`n`n" +
        ("Package: ``{0}``" -f $Manifest.package) + "`n`n" +
        ("SHA-256: ``{0}``" -f $Manifest.sha256) + "`n`n" +
        ("Built from the tree of commit ``{0}``, which is the commit this release's tag points at. Per-file hashes are attached to this release as ``manifest-{1}.json``." -f $Manifest.commit, $Manifest.profileId) + "`n"
    )
}

$manifests = @(Get-ChildItem -LiteralPath $OutputDirectory -Filter 'manifest-twd-*.json' | Sort-Object Name)
if ($Tag) { $manifests = @($manifests | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).tag -eq $Tag }) }
if ($manifests.Count -eq 0) { Write-Error "No manifest matched. Build packages first."; exit 22 }

$releases = @{}
foreach ($release in (Invoke-Api -Method Get -Uri ("{0}/releases?per_page=100" -f $apiBase))) {
    $releases[$release.tag_name] = $release
}

$results = New-Object System.Collections.Generic.List[object]
$exitCode = 0

foreach ($manifestFile in $manifests) {
    $manifest = Get-Content -LiteralPath $manifestFile.FullName -Raw | ConvertFrom-Json
    $zipPath = Join-Path $OutputDirectory $manifest.package
    if (-not (Test-Path -LiteralPath $zipPath)) { throw "Missing package $zipPath for $($manifest.profileId)" }

    $localHash = Get-FileSha256 -Path $zipPath
    if ($localHash -ne $manifest.sha256) {
        throw ("{0} does not match its manifest hash; rebuild before publishing." -f $manifest.package)
    }

    $notes = Get-ZipText -ZipPath $zipPath -EntryName 'PATCH.md'
    $body = New-ReleaseBody -Manifest $manifest -Notes $notes
    $desired = @(
        @{ Name = $manifest.package; Path = $zipPath; Type = 'application/zip' },
        @{ Name = $manifestFile.Name; Path = $manifestFile.FullName; Type = 'application/json' }
    )

    $state = [ordered]@{
        tag = $manifest.tag
        profileId = $manifest.profileId
        package = $manifest.package
        sha256 = $localHash
        releaseUrl = ''
        created = $false
        bodyUpdated = $false
        replaced = @()
        uploaded = @()
        verified = @()
        status = 'up-to-date'
    }

    $release = $releases[$manifest.tag]
    if (-not $release) {
        if ($DryRun) {
            $state.status = 'would-create'
            Write-Host ("[dry run] would create release {0}" -f $manifest.tag)
        } else {
            $release = Invoke-Api -Method Post -Uri ("{0}/releases" -f $apiBase) -Body @{
                tag_name = $manifest.tag
                name     = ("{0} offline patch" -f $manifest.profileId)
                body     = $body
                draft    = $false
                prerelease = $false
            }
            $releases[$manifest.tag] = $release
            $state.created = $true
            $state.status = 'created'
            Write-Host ("created release {0}: {1}" -f $manifest.tag, $release.html_url)
        }
    }

    if ($release) {
        $state.releaseUrl = $release.html_url
        if (($release.body -as [string]) -ne $body) {
            if ($DryRun) {
                Write-Host ("[dry run] would update the body of {0}" -f $manifest.tag)
                $state.bodyUpdated = $true
            } else {
                $release = Invoke-Api -Method Patch -Uri ("{0}/releases/{1}" -f $apiBase, $release.id) -Body @{ body = $body }
                $state.bodyUpdated = $true
                Write-Host ("updated body for {0}" -f $manifest.tag)
            }
        }

        $assets = @($release.assets)
        foreach ($old in $assets) {
            if ($desired.Name -notcontains $old.name) {
                if ($DryRun) {
                    Write-Host ("[dry run] would delete stray asset {0}" -f $old.name)
                } else {
                    Invoke-Api -Method Delete -Uri ("{0}/releases/assets/{1}" -f $apiBase, $old.id) | Out-Null
                    Write-Host ("deleted stray asset {0}" -f $old.name)
                }
                $state.replaced += $old.name
            }
        }

        foreach ($item in $desired) {
            $localBytes = (Get-Item -LiteralPath $item.Path).Length
            $existing = $assets | Where-Object { $_.name -eq $item.Name } | Select-Object -First 1
            $needsUpload = (-not $existing) -or ($existing.size -ne $localBytes)
            if ($needsUpload) {
                if ($DryRun) {
                    Write-Host ("[dry run] would upload {0} ({1:N0} bytes)" -f $item.Name, $localBytes)
                    $state.uploaded += $item.Name
                } else {
                    $uploadUrl = $release.upload_url.Split('{')[0] + ('?name={0}' -f $item.Name)
                    if ($existing) {
                        Invoke-Api -Method Delete -Uri ("{0}/releases/assets/{1}" -f $apiBase, $existing.id) | Out-Null
                        $state.replaced += $existing.name
                    }
                    # Upload straight from the file: passing bytes as -Body makes PowerShell
                    # convert them to a string, which quietly rewrites the asset.
                    try {
                        Invoke-WebRequest -Method Post -Uri $uploadUrl -Headers $headers `
                            -InFile $item.Path -ContentType $item.Type -UseBasicParsing | Out-Null
                    } catch {
                        throw ("upload of {0} failed: {1}" -f $item.Name, $_.Exception.Message)
                    }
                    $state.uploaded += $item.Name
                    Write-Host ("uploaded {0} ({1:N0} bytes)" -f $item.Name, $localBytes)
                }
                $state.status = 'published'
            }
        }

        if (-not $SkipVerify -and -not $DryRun) {
            $current = Invoke-Api -Method Get -Uri ("{0}/releases/{1}" -f $apiBase, $release.id)
            $partial = $false
            foreach ($item in $desired) {
                $served = @($current.assets) | Where-Object { $_.name -eq $item.Name } | Select-Object -First 1
                if (-not $served) {
                    Write-Host ("MISSING after upload: {0}" -f $item.Name)
                    $partial = $true
                    continue
                }
                $localFileHash = Get-FileSha256 -Path $item.Path
                $digest = [string]$served.digest
                if ($digest -and ($digest -ne ("sha256:{0}" -f $localFileHash))) {
                    Write-Host ("DIGEST MISMATCH stored vs local: {0}" -f $item.Name)
                    $partial = $true
                    continue
                }

                # The release download URL is served through a cache keyed by tag and file
                # name, so straight after an upload it can still return the previous bytes.
                # Ask for the file until it matches, with a cache busting parameter.
                $servedHash = ''
                for ($attempt = 1; $attempt -le 5; $attempt++) {
                    $temp = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N') + '.asset')
                    try {
                        $downloadUrl = $served.browser_download_url + ('?cachebust={0}' -f [guid]::NewGuid().ToString('N'))
                        Invoke-WebRequest -Uri $downloadUrl -OutFile $temp -UseBasicParsing
                        $servedHash = Get-FileSha256 -Path $temp
                    } finally {
                        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
                    }
                    if ($servedHash -eq $localFileHash) { break }
                    Start-Sleep -Seconds 3
                }
                if ($servedHash -ne $localFileHash) {
                    Write-Host ("HASH MISMATCH served vs local: {0}" -f $item.Name)
                    $partial = $true
                } else {
                    $state.verified += $item.Name
                }
            }
            if ($partial) { $state.status = 'verify-failed'; $exitCode = 23 }
            elseif ($state.status -eq 'up-to-date') { $state.status = 'verified' }
        }
    }

    $results.Add([pscustomobject]$state)
}

if ($AsJson) {
    $results | ConvertTo-Json -Depth 5
} else {
    foreach ($result in $results) {
        Write-Host ("`n{0}" -f $result.tag)
        Write-Host ("  status   {0}" -f $result.status)
        Write-Host ("  release  {0}" -f $result.releaseUrl)
        Write-Host ("  zip      {0}  {1}" -f $result.sha256, $result.package)
        if ($result.replaced.Count) { Write-Host ("  replaced {0}" -f ($result.replaced -join ', ')) }
        if ($result.uploaded.Count) { Write-Host ("  uploaded {0}" -f ($result.uploaded -join ', ')) }
        if ($result.verified.Count) { Write-Host ("  verified {0} of 2 assets by download" -f $result.verified.Count) }
    }
    $failed = @($results | Where-Object { $_.status -eq 'verify-failed' })
    if ($failed.Count -eq 0 -and -not $SkipVerify -and -not $DryRun) {
        Write-Host ("`nAll {0} releases serve bytes identical to the local packages." -f $results.Count)
    } elseif ($SkipVerify) {
        Write-Host "`nUploads reported without downloading the assets back (-SkipVerify)."
    }
}

exit $exitCode

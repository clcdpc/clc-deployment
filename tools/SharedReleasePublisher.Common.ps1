Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-SharedReleaseHttpClient {
    [CmdletBinding()]
    param([Net.Http.HttpMessageHandler] $Handler)

    if ($null -eq $Handler) {
        $Handler = [Net.Http.HttpClientHandler]::new()
        $Handler.AllowAutoRedirect = $false
        return [Net.Http.HttpClient]::new($Handler)
    }
    return [Net.Http.HttpClient]::new($Handler,$false)
}

function Send-SharedReleaseHttpRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Net.Http.HttpClient] $Client,
        [Parameter(Mandatory)][Net.Http.HttpRequestMessage] $Request,
        [string] $GitHubToken,
        [switch] $GitHubAuthorization,
        [string[]] $AllowedRedirectHosts = @(),
        [ValidateRange(0,5)][int] $MaximumRedirects = 5
    )

    $activeRequest = $Request
    for ($redirect = 0; ; $redirect++) {
        $uri = $activeRequest.RequestUri
        if ($null -eq $uri -or -not $uri.IsAbsoluteUri -or $uri.Scheme -cne 'https' -or
            -not $uri.IsDefaultPort -or -not [string]::IsNullOrEmpty($uri.UserInfo)) {
            $activeRequest.Dispose()
            throw 'Release service request URI must use HTTPS without user information or a custom port.'
        }

        $activeRequest.Headers.Authorization = $null
        if ($GitHubAuthorization) {
            if ([string]::IsNullOrWhiteSpace($GitHubToken)) {
                $activeRequest.Dispose()
                throw 'GitHub authorization token is unavailable.'
            }
            $isGitHubApiHost = $uri.Host -ceq 'api.github.com'
            $isGitHubUploadHost = $uri.Host -ceq 'uploads.github.com'
            if ($isGitHubApiHost -and $uri.AbsolutePath -cnotmatch '\A/repos/clcdpc/clc-deployment/') {
                $activeRequest.Dispose()
                throw 'GitHub authorization is restricted to the configured repository API.'
            }
            if ($isGitHubUploadHost -and
                ($activeRequest.Method -cne [Net.Http.HttpMethod]::Post -or $uri.AbsolutePath -cnotmatch '\A/repos/clcdpc/clc-deployment/releases/[1-9][0-9]*/assets\z')) {
                $activeRequest.Dispose()
                throw 'GitHub authorization is restricted to the configured release upload endpoint.'
            }
            if (-not $isGitHubApiHost -and -not $isGitHubUploadHost) {
                $redirectHostAllowed = $false
                if ($redirect -gt 0) {
                    foreach ($allowedHost in $AllowedRedirectHosts) {
                        if ($uri.Host.Equals($allowedHost,[StringComparison]::OrdinalIgnoreCase)) { $redirectHostAllowed = $true; break }
                    }
                }
                if (-not $redirectHostAllowed) {
                    $activeRequest.Dispose()
                    if ($redirect -gt 0) { throw 'Release service redirect destination is not allowlisted for GitHub asset access.' }
                    throw 'GitHub authorization is restricted to the configured GitHub API hosts.'
                }
            } else {
                $activeRequest.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$GitHubToken)
            }
        }

        $response = $null
        try {
            $response = $Client.SendAsync($activeRequest,[Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            if ([int]$response.StatusCode -notin @(301,302,303,307,308)) {
                $activeRequest.Dispose()
                return $response
            }
            if ($activeRequest.Method -cne [Net.Http.HttpMethod]::Get -or $redirect -ge $MaximumRedirects -or $null -eq $response.Headers.Location) {
                $response.Dispose()
                $activeRequest.Dispose()
                throw 'Release service redirect is unsupported or exceeds its bound.'
            }

            $location = $response.Headers.Location
            $nextUri = if ($location.IsAbsoluteUri) { $location } else { [Uri]::new($uri,$location) }
            $allowed = $false
            foreach ($allowedHost in $AllowedRedirectHosts) {
                if ($nextUri.Host.Equals($allowedHost,[StringComparison]::OrdinalIgnoreCase)) { $allowed = $true; break }
            }
            if (-not $nextUri.IsAbsoluteUri -or $nextUri.Scheme -cne 'https' -or -not $nextUri.IsDefaultPort -or
                -not [string]::IsNullOrEmpty($nextUri.UserInfo) -or -not $allowed) {
                $response.Dispose()
                $activeRequest.Dispose()
                throw 'Release service redirect destination is not allowlisted.'
            }

            $response.Dispose()
            $activeRequest.Dispose()
            $activeRequest = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get,$nextUri)
        } catch {
            if ($null -ne $response) { $response.Dispose() }
            $activeRequest.Dispose()
            throw
        }
    }
}

function Read-SharedReleaseBoundedResponseBytes {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Net.Http.HttpContent] $Content,[Parameter(Mandatory)][ValidateRange(1,[long]::MaxValue)][long] $MaximumBytes)

    if ($Content.Headers.ContentLength -gt $MaximumBytes) { throw 'Release service response exceeds its byte bound.' }
    $inputStream = $Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $outputStream = [IO.MemoryStream]::new()
    $timeout = [Threading.CancellationTokenSource]::new([TimeSpan]::FromMinutes(5))
    try {
        $buffer = [byte[]]::new(65536)
        while (($count = $inputStream.ReadAsync($buffer,0,$buffer.Length,$timeout.Token).GetAwaiter().GetResult()) -gt 0) {
            if ($count -gt ($MaximumBytes - $outputStream.Length)) { throw 'Release service response exceeds its byte bound.' }
            $outputStream.Write($buffer,0,$count)
        }
        return ,$outputStream.ToArray()
    } finally {
        $timeout.Dispose()
        $outputStream.Dispose()
        $inputStream.Dispose()
    }
}

function Get-SharedReleasePublishedNuGetPackage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Net.Http.HttpClient] $Client,[Parameter(Mandatory)][string] $PackageVersion)

    $flatVersion = $PackageVersion.ToLowerInvariant()
    $uri = 'https://api.nuget.org/v3-flatcontainer/clc.deployment.aspnetcore/' + [Uri]::EscapeDataString($flatVersion) + '/clc.deployment.aspnetcore.' + [Uri]::EscapeDataString($flatVersion) + '.nupkg'
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get,$uri)
    try {
        $response = Send-SharedReleaseHttpRequest -Client $Client -Request $request -AllowedRedirectHosts @('api.nuget.org','globalcdn.nuget.org')
        try {
            if ([int]$response.StatusCode -eq 404) { return $null }
            if (-not $response.IsSuccessStatusCode) { throw 'Could not inspect the existing NuGet package version.' }
            return ,(Read-SharedReleaseBoundedResponseBytes -Content $response.Content -MaximumBytes 268435456)
        } finally { $response.Dispose() }
    } finally { $request.Dispose() }
}

function Get-SharedReleasePackageEntryDigests {
    [CmdletBinding()]
    param([Parameter(Mandatory)][byte[]] $PackageBytes)

    if ($PackageBytes.Length -eq 0 -or $PackageBytes.Length -gt 268435456) { throw 'NuGet package exceeds its bounded size.' }
    $memory = [IO.MemoryStream]::new($PackageBytes,$false)
    $archive = $null
    try {
        $archive = [IO.Compression.ZipArchive]::new($memory,[IO.Compression.ZipArchiveMode]::Read,$true)
        if ($archive.Entries.Count -lt 1 -or $archive.Entries.Count -gt 20000) { throw 'NuGet package contains an invalid entry count.' }
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $digests = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
        $signaturePresent = $false
        [long]$total = 0
        foreach ($entry in $archive.Entries) {
            if (-not $names.Add($entry.FullName)) { throw 'NuGet package contains a duplicate entry.' }
            $isSignature = $entry.FullName -ceq '.signature.p7s'
            if ($isSignature) {
                if ($entry.Length -le 0 -or $entry.Length -gt 16777216) { throw 'NuGet package signature entry has an invalid size.' }
                $signaturePresent = $true
            } else {
                if ($entry.Length -gt 268435456 -or $entry.Length -gt (1073741824 - $total)) { throw 'NuGet package contents exceed their bounded size.' }
                $total += $entry.Length
            }

            $inputStream = $entry.Open()
            $hash = if ($isSignature) { $null } else { [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256) }
            try {
                [long]$readTotal = 0
                $buffer = [byte[]]::new(65536)
                while (($count = $inputStream.Read($buffer,0,$buffer.Length)) -gt 0) {
                    if ($count -gt ($entry.Length - $readTotal)) { throw 'NuGet package entry exceeded its declared length.' }
                    $readTotal += $count
                    if ($null -ne $hash) { $hash.AppendData($buffer,0,$count) }
                }
                if ($readTotal -ne $entry.Length) { throw 'NuGet package entry length differs from its ZIP directory.' }
                if ($null -ne $hash) { $digests.Add($entry.FullName,[Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant()) }
            } finally {
                $inputStream.Dispose()
                if ($null -ne $hash) { $hash.Dispose() }
            }
        }
        return [pscustomobject]@{ digests=$digests; signaturePresent=$signaturePresent }
    } finally {
        if ($null -ne $archive) { $archive.Dispose() }
        $memory.Dispose()
    }
}

function Get-SharedReleaseNuGetIdentityFromBytes {
    [CmdletBinding()]
    param([Parameter(Mandatory)][byte[]] $PackageBytes)

    $path = Join-Path ([IO.Path]::GetTempPath()) ('clc-nuget-verify-' + [guid]::NewGuid().ToString('N') + '.nupkg')
    try {
        [IO.File]::WriteAllBytes($path,$PackageBytes)
        return Get-DistNuGetPackageIdentity $path
    } finally {
        if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
    }
}

function Test-SharedReleaseNuGetPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ExpectedPackagePath,
        [Parameter(Mandatory)][byte[]] $PublishedPackageBytes,
        [Parameter(Mandatory)][string] $ExpectedPackageId,
        [Parameter(Mandatory)][string] $ExpectedVersion,
        [Parameter(Mandatory)][string] $ExpectedSourceCommit
    )

    $expectedIdentity = Get-DistNuGetPackageIdentity $ExpectedPackagePath
    $publishedIdentity = Get-SharedReleaseNuGetIdentityFromBytes $PublishedPackageBytes
    foreach ($field in @('id','version','licenseType','licenseExpression','repositoryType','repositoryUrl','repositoryCommit')) {
        if ([string]$expectedIdentity.$field -cne [string]$publishedIdentity.$field) { return $false }
    }
    if ($expectedIdentity.id -cne $ExpectedPackageId -or $expectedIdentity.version -cne $ExpectedVersion -or
        $expectedIdentity.repositoryCommit -cne $ExpectedSourceCommit) { return $false }

    $expectedBytes = Read-DistFileBytes $ExpectedPackagePath 268435456
    $expectedContents = Get-SharedReleasePackageEntryDigests $expectedBytes
    $publishedContents = Get-SharedReleasePackageEntryDigests $PublishedPackageBytes
    if (-not $publishedContents.signaturePresent) { return $false }
    if ($expectedContents.digests.Count -ne $publishedContents.digests.Count) { return $false }
    foreach ($entryName in $expectedContents.digests.Keys) {
        if (-not $publishedContents.digests.ContainsKey($entryName) -or
            $expectedContents.digests[$entryName] -cne $publishedContents.digests[$entryName]) { return $false }
    }
    return $true
}

function Invoke-SharedReleaseNuGetPublication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $PackagePath,
        [Parameter(Mandatory)][string] $PackageId,
        [Parameter(Mandatory)][string] $Version,
        [Parameter(Mandatory)][string] $SourceCommit,
        [Parameter(Mandatory)][Net.Http.HttpClient] $NuGetClient,
        [Parameter(Mandatory)][scriptblock] $PushPackage,
        [string] $ApiKey,
        [string] $DotnetPath
    )

    $existing = Get-SharedReleasePublishedNuGetPackage -Client $NuGetClient -PackageVersion $Version
    if ($null -ne $existing) {
        if (-not (Test-SharedReleaseNuGetPackage -ExpectedPackagePath $PackagePath -PublishedPackageBytes $existing -ExpectedPackageId $PackageId -ExpectedVersion $Version -ExpectedSourceCommit $SourceCommit)) {
            throw 'NuGet already contains this version with different identity or package contents; refusing publication.'
        }
        return 'already-published-identical'
    }

    $pushExit = [int](& $PushPackage $PackagePath $ApiKey $DotnetPath)
    # A successful push means NuGet accepted these exact bytes. Its asynchronous
    # signing/indexing must not delay the independently verified GitHub assets.
    if ($pushExit -eq 0) { return 'submitted-processing' }

    # A retry can race an earlier accepted upload. Never treat an unavailable
    # version or a duplicate response as proof that its contents match.
    $confirmed = Get-SharedReleasePublishedNuGetPackage -Client $NuGetClient -PackageVersion $Version
    if ($null -ne $confirmed) {
        if (-not (Test-SharedReleaseNuGetPackage -ExpectedPackagePath $PackagePath -PublishedPackageBytes $confirmed -ExpectedPackageId $PackageId -ExpectedVersion $Version -ExpectedSourceCommit $SourceCommit)) {
            throw 'NuGet contains different identity or package contents for this version; refusing to continue.'
        }
        return 'already-published-identical'
    }
    throw 'NuGet package push failed and its version is not downloadable for verification. If an earlier upload is still processing, retry after it becomes available.'
}

# The tag endpoint does not expose draft releases. Locate a resumable draft in
# the release collection, then use its ID throughout asset upload/publication.
function Get-SharedReleaseByTag {
    param([string] $Repository,[string] $Tag,[scriptblock] $GetJson)
    $release=& $GetJson ('/repos/'+$Repository+'/releases/tags/'+[Uri]::EscapeDataString($Tag))
    if ($null -ne $release) { return $release }
    for ($page=1; $page -le 10; $page++) {
        $releases=@(& $GetJson ('/repos/'+$Repository+'/releases?per_page=100&page='+$page))
        $matches=@($releases | Where-Object { $_.tag_name -ceq $Tag })
        if ($matches.Count -gt 1) { throw 'Multiple GitHub releases match the tag.' }
        if ($matches.Count -eq 1) { return $matches[0] }
        if ($releases.Count -lt 100) { return $null }
    }
    throw 'GitHub release lookup exceeded its page bound.'
}
function Get-SharedReleaseById {
    param([string] $Repository,[long] $ReleaseId,[scriptblock] $GetJson)
    if ($ReleaseId -le 0) { throw 'GitHub release ID is invalid.' }
    return & $GetJson ('/repos/'+$Repository+'/releases/'+$ReleaseId)
}

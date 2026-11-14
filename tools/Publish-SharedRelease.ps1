[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RepositoryRoot,
    [Parameter(Mandatory)][string] $BundleRoot,
    [Parameter(Mandatory)][string] $Tag,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string] $SourceCommit,
    [Parameter(Mandatory)][ValidatePattern('^clc-release-[a-f0-9]{40}-[1-9][0-9]*$')][string] $ArtifactName,
    [Parameter(Mandatory)][ValidateRange(1,[long]::MaxValue)][long] $ProducerRunId,
    [Parameter(Mandatory)][ValidateRange(1,1000)][int] $ProducerRunAttempt,
    [Parameter(Mandatory)][ValidatePattern('^clcdpc/clc-deployment$')][string] $Repository,
    [switch] $PreflightOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root=[IO.Path]::GetFullPath($RepositoryRoot)
$bundle=[IO.Path]::GetFullPath($BundleRoot)
. (Join-Path $PSScriptRoot 'Distribution.Common.ps1')
. (Join-Path $PSScriptRoot 'SharedReleasePublisher.Common.ps1')
$identity=& (Join-Path $PSScriptRoot 'Test-SharedReleaseArtifacts.ps1') -RepositoryRoot $root -BundleRoot $bundle -Tag $Tag -SourceCommit $SourceCommit -ArtifactName $ArtifactName -ProducerRunId $ProducerRunId -ProducerRunAttempt $ProducerRunAttempt
$manifest=Read-DistJson (Read-DistFileBytes (Join-Path $bundle 'release-manifest.json') 4194304)
$packagePath=Join-Path $bundle $manifest.companion.file
$manifestPath=Join-Path $bundle 'release-manifest.json'
$toolkitPath=Join-Path $bundle $manifest.toolkit.file
$version=$manifest.version
$prerelease=$version.Contains('-')

if ($Repository -cne 'clcdpc/clc-deployment') { throw 'Shared release publication is restricted to the configured repository.' }

$githubToken=$env:GH_TOKEN
if ([string]::IsNullOrWhiteSpace($githubToken)) { throw 'The GitHub release token is unavailable.' }

$githubClient=New-SharedReleaseHttpClient
$githubClient.Timeout=[TimeSpan]::FromMinutes(10)
$nugetClient=New-SharedReleaseHttpClient
$nugetClient.Timeout=[TimeSpan]::FromMinutes(10)
try {
    $githubClient.DefaultRequestHeaders.UserAgent.ParseAdd('clc-deployment-release/1')

    function Get-BoundedResponseHash([Net.Http.HttpContent] $Content,[long] $MaximumBytes) {
        if ($Content.Headers.ContentLength -gt $MaximumBytes) { throw 'Release service response exceeds its byte bound.' }
        $inputStream=$Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $hash=[Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
        $timeout=[Threading.CancellationTokenSource]::new([TimeSpan]::FromMinutes(5))
        try {
            $buffer=[byte[]]::new(65536)
            [long]$total=0
            while (($count=$inputStream.ReadAsync($buffer,0,$buffer.Length,$timeout.Token).GetAwaiter().GetResult()) -gt 0) {
                if ($count -gt ($MaximumBytes-$total)) { throw 'Release service response exceeds its byte bound.' }
                $hash.AppendData($buffer,0,$count)
                $total += $count
            }
            return [Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant()
        } finally {
            $timeout.Dispose()
            $hash.Dispose()
            $inputStream.Dispose()
        }
    }

    function Get-GitHubJson([string] $Method,[string] $Path,$Body=$null,[switch] $NotFoundIsNull) {
        $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method),'https://api.github.com'+$Path)
        try {
            $request.Headers.Accept.ParseAdd('application/vnd.github+json')
            $request.Headers.Add('X-GitHub-Api-Version','2022-11-28')
            if ($null -ne $Body) { $request.Content=[Net.Http.StringContent]::new(($Body | ConvertTo-Json -Depth 12 -Compress),[Text.Encoding]::UTF8,'application/json') }
            $response=Send-SharedReleaseHttpRequest -Client $githubClient -Request $request -GitHubToken $githubToken -GitHubAuthorization -AllowedRedirectHosts @('api.github.com')
            try {
                if ($NotFoundIsNull -and [int]$response.StatusCode -eq 404) { return $null }
                if (-not $response.IsSuccessStatusCode) { throw 'GitHub release API request failed.' }
                $responseBytes=Read-SharedReleaseBoundedResponseBytes -Content $response.Content -MaximumBytes 4194304
                $text=[Text.UTF8Encoding]::new($false,$true).GetString($responseBytes)
                return $text | ConvertFrom-Json -AsHashtable
            } finally { $response.Dispose() }
        } finally { $request.Dispose() }
    }
    function Get-Release([string] $ReleaseTag) {
        Get-SharedReleaseByTag -Repository $Repository -Tag $ReleaseTag -GetJson {
            param($Path)
            Get-GitHubJson GET $Path -NotFoundIsNull
        }
    }
    function Get-ReleaseAssetHash($Asset) {
        if ($Asset.id -isnot [long] -and $Asset.id -isnot [int]) { throw 'GitHub release asset identity is invalid.' }
        $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get,'https://api.github.com/repos/'+$Repository+'/releases/assets/'+$Asset.id)
        $request.Headers.Accept.Clear()
        $request.Headers.Accept.ParseAdd('application/octet-stream')
        try {
            $response=Send-SharedReleaseHttpRequest -Client $githubClient -Request $request -GitHubToken $githubToken -GitHubAuthorization -AllowedRedirectHosts @('api.github.com','release-assets.githubusercontent.com','objects.githubusercontent.com')
            try {
                if (-not $response.IsSuccessStatusCode) { throw 'Could not read existing GitHub Release asset bytes.' }
                return Get-BoundedResponseHash $response.Content 268435456
            } finally { $response.Dispose() }
        } finally { $request.Dispose() }
    }
    $githubIdentity=@{repository=$Repository;tag=$Tag;sourceCommit=$SourceCommit;prerelease=$prerelease}
    $githubAssets=@(
        @{name='release-manifest.json';path=$manifestPath;length=(Get-Item -LiteralPath $manifestPath).Length;sha256=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()},
        @{name=$manifest.toolkit.file;path=$toolkitPath;length=(Get-Item -LiteralPath $toolkitPath).Length;sha256=$manifest.toolkit.sha256},
        @{name=$manifest.companion.file;path=$packagePath;length=(Get-Item -LiteralPath $packagePath).Length;sha256=$manifest.companion.sha256}
    )
    function Assert-ReleaseAssets($Release,[switch] $AllowMissing) {
        Assert-SharedReleaseGitHubAssets $Release $githubIdentity $githubAssets {param($asset) Get-ReleaseAssetHash $asset} -AllowMissing:$AllowMissing
    }
    function Upload-ReleaseAsset($Release,[string] $Path) {
        $name=[IO.Path]::GetFileName($Path)
        $uploadBase=[string]$Release.upload_url
        if ($uploadBase -notmatch '\Ahttps://uploads\.github\.com/repos/clcdpc/clc-deployment/releases/[1-9][0-9]*/assets\{\?name,label\}\z') { throw 'GitHub Release upload endpoint is invalid.' }
        $uri=$uploadBase.Substring(0,$uploadBase.IndexOf('{',[StringComparison]::Ordinal))+'?name='+[Uri]::EscapeDataString($name)
        $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post,$uri)
        try {
            $assetStream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
            $request.Content=[Net.Http.StreamContent]::new($assetStream)
            if ($assetStream.Length -gt 268435456) { throw 'Release asset exceeds the publication bound.' }
            $request.Content.Headers.ContentType=[Net.Http.Headers.MediaTypeHeaderValue]::new('application/octet-stream')
            $request.Content.Headers.ContentLength=$assetStream.Length
            $response=Send-SharedReleaseHttpRequest -Client $githubClient -Request $request -GitHubToken $githubToken -GitHubAuthorization -AllowedRedirectHosts @('uploads.github.com')
            try { if (-not $response.IsSuccessStatusCode) { throw 'GitHub Release asset upload failed; the draft release can be retried after inspection.' } }
            finally { $response.Dispose() }
        } finally { $request.Dispose() }
    }

    $existingNuGetPackage=Get-SharedReleasePublishedNuGetPackage -Client $nugetClient -PackageVersion $version
    if ($null -ne $existingNuGetPackage -and -not (Test-SharedReleaseNuGetPackage -ExpectedPackagePath $packagePath -PublishedPackageBytes $existingNuGetPackage -ExpectedPackageId $manifest.companion.packageId -ExpectedVersion $version -ExpectedSourceCommit $SourceCommit)) {
        throw 'NuGet already contains this version with different identity or package contents; refusing publication.'
    }

    $release=Get-Release $Tag
    $releaseAlreadyPublished=$false
    if ($null -ne $release) {
        $null=Assert-ReleaseAssets $release -AllowMissing
        if (-not $release.draft) {
            $null=Assert-ReleaseAssets $release
            $releaseAlreadyPublished=$true
        }
    }
    if ($PreflightOnly) {
        [pscustomobject]@{
            preflightComplete=$true
            nuGet=$(if ($null -eq $existingNuGetPackage) {'version-not-downloadable'} else {'matching-contents-already-present'})
            githubRelease=$(if ($null -eq $release) {'absent'} elseif ($releaseAlreadyPublished) {'published-identical-assets'} else {'draft-compatible'})
            tag=$Tag
            version=$version
        }
        return
    }
    $nugetApiKey=$env:CLC_NUGET_API_KEY
    if ([string]::IsNullOrWhiteSpace($nugetApiKey)) { throw 'The NuGet trusted publishing action did not provide its temporary key.' }

    $nuGetResult='already-published-identical'
    if ($null -eq $existingNuGetPackage) {
        $dotnetPath=$env:CLC_RELEASE_DOTNET
        if ([string]::IsNullOrWhiteSpace($dotnetPath) -or -not [IO.File]::Exists($dotnetPath)) { throw 'The pinned .NET SDK executable is unavailable for NuGet publication.' }
        $pushPackage={
            param([string] $Path,[string] $ApiKey,[string] $DotnetExecutable)
            $null=& $DotnetExecutable nuget push $Path --api-key $ApiKey --source 'https://api.nuget.org/v3/index.json' 2>&1
            return [int]$LASTEXITCODE
        }
        $nuGetResult=Invoke-SharedReleaseNuGetPublication -PackagePath $packagePath -PackageId $manifest.companion.packageId -Version $version -SourceCommit $SourceCommit -NuGetClient $nugetClient -PushPackage $pushPackage -ApiKey $nugetApiKey -DotnetPath $dotnetPath
    }

    $githubResult=Invoke-SharedReleaseGitHubPublication $githubIdentity $githubAssets `
        {param($method,$path,$body) Get-GitHubJson $method $path $body -NotFoundIsNull:($method -ceq 'GET')} `
        {param($asset) Get-ReleaseAssetHash $asset} `
        {param($release,$asset) Upload-ReleaseAsset $release $asset.path}
    [pscustomobject]@{nuGet=$nuGetResult;githubRelease=$(if ($githubResult.status -ceq 'Preserved') {'already-published-identical'} else {'published'});tag=$Tag;version=$version}
} finally {
    $githubClient.Dispose()
    $nugetClient.Dispose()
}

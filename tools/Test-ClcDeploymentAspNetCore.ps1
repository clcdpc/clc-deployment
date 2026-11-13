[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $DotnetPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $OutputRoot,
    [string] $PackagePath,
    [string] $SourceCommit,
    [string] $ReleaseVersion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repository = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'Distribution.Common.ps1')
$dotnet = [IO.Path]::GetFullPath($DotnetPath)
if (-not [IO.File]::Exists($dotnet)) { throw 'The pinned .NET SDK executable was not found.' }
if ((& $dotnet --version).Trim() -cne '10.0.403' -or $LASTEXITCODE -ne 0) { throw 'The ASP.NET Core companion requires the pinned .NET SDK 10.0.403.' }

$version = if ($ReleaseVersion) { Assert-DistVersion $ReleaseVersion; $ReleaseVersion } else { Get-DistVersionFromBytes ([IO.File]::ReadAllBytes((Join-Path $repository 'VERSION'))) }
if (-not $SourceCommit) { $SourceCommit = Get-DistGit $repository @('rev-parse','HEAD') }
if ($SourceCommit -cnotmatch '\A[a-f0-9]{40}\z') { throw 'The companion source commit identity is invalid.' }

$output = [IO.Path]::GetFullPath($OutputRoot)
$runRoot = Join-Path $output ('clc-deployment-aspnetcore-' + [guid]::NewGuid().ToString('N'))
$feed = Join-Path $runRoot 'feed'
$packageCache = Join-Path $runRoot 'packages'
$candidateLockFile = Join-Path $runRoot 'candidate.packages.lock.json'
[void][IO.Directory]::CreateDirectory($feed)
[void][IO.Directory]::CreateDirectory($packageCache)

$packageProject = Join-Path $repository 'src/Clc.Deployment.AspNetCore/Clc.Deployment.AspNetCore.csproj'
$testProject = Join-Path $repository 'tests/Clc.Deployment.AspNetCore.Tests/Clc.Deployment.AspNetCore.Tests.csproj'
[xml]$testDefinition = [IO.File]::ReadAllText($testProject)
if ($testDefinition.SelectNodes('/Project/ItemGroup/ProjectReference').Count -gt 0) { throw 'Packed-package tests must not use a project reference.' }
$committedTestLock = Join-Path (Split-Path $testProject -Parent) 'packages.lock.json'
if ([IO.File]::Exists($committedTestLock)) { throw 'Candidate package tests must not pin mutable candidate bytes in a source-controlled lock file.' }

$packageName = 'Clc.Deployment.AspNetCore.' + $version + '.nupkg'
if (-not $PackagePath) {
    & $dotnet pack $packageProject --configuration Release --output $feed --nologo -warnaserror -p:RestoreLockedMode=true -p:RepositoryCommit=$SourceCommit -p:ContinuousIntegrationBuild=true -p:ClcReleaseVersion=$version | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'ASP.NET Core companion package creation failed.' }
    $package = Join-Path $feed $packageName
} else {
    $package = [IO.Path]::GetFullPath($PackagePath)
    if (-not [IO.File]::Exists($package)) { throw 'The supplied companion package was not found.' }
    if ([IO.Path]::GetFileName($package) -cne $packageName) { throw 'The supplied package filename does not match the shared version.' }
    $feedPackage = Join-Path $feed $packageName
    [IO.File]::Copy($package,$feedPackage,$false)
}
if (-not [IO.File]::Exists($package)) { throw 'The exact shared-version companion package was not created.' }

$packageIdentity=Get-DistNuGetPackageIdentity $package
if ($packageIdentity.id -cne 'Clc.Deployment.AspNetCore' -or $packageIdentity.version -cne $version -or
    $packageIdentity.licenseType -cne 'expression' -or $packageIdentity.licenseExpression -cne 'MIT' -or
    $packageIdentity.repositoryType -cne 'git' -or $packageIdentity.repositoryUrl -cne 'https://github.com/clcdpc/clc-deployment' -or
    $packageIdentity.repositoryCommit -cne $SourceCommit) {
    throw 'Companion package ID, version, license, repository or source commit metadata differs.'
}

$digest = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash.ToLowerInvariant()
$expectedContentHash = [Convert]::ToBase64String([Security.Cryptography.SHA512]::HashData([IO.File]::ReadAllBytes($package)))

& $dotnet clean $testProject --configuration Release --nologo -p:ClcReleaseVersion=$version | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Packed ASP.NET Core companion test clean failed.' }
& $dotnet restore $testProject --source $feed --packages $packageCache --lock-file-path $candidateLockFile --no-http-cache --nologo -p:ClcReleaseVersion=$version | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Packed ASP.NET Core companion restore failed.' }
$candidateLock = Get-Content -LiteralPath $candidateLockFile -Raw | ConvertFrom-Json -AsHashtable
$packageLock = $candidateLock.dependencies['net10.0']['Clc.Deployment.AspNetCore']
if (-not [string]::Equals([string]$packageLock.resolved,$version,[StringComparison]::OrdinalIgnoreCase) -or $packageLock.contentHash -cne $expectedContentHash) {
    throw 'Generated candidate lock does not identify the exact packed package bytes.'
}
& $dotnet restore $testProject --source $feed --packages $packageCache --lock-file-path $candidateLockFile --locked-mode --no-http-cache --nologo -p:ClcReleaseVersion=$version | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Locked restore of the exact ASP.NET Core companion candidate failed.' }
& $dotnet build $testProject --configuration Release --no-restore --nologo -warnaserror -p:ClcReleaseVersion=$version | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Packed ASP.NET Core companion test build failed.' }
$cachedPackage = Join-Path $packageCache ('clc.deployment.aspnetcore/' + $version.ToLowerInvariant() + '/lib/net10.0/Clc.Deployment.AspNetCore.dll')
if (-not [IO.File]::Exists($cachedPackage) -or
    (Get-FileHash -LiteralPath $cachedPackage -Algorithm SHA256).Hash -cne
    (Get-FileHash -LiteralPath (Join-Path (Split-Path $testProject -Parent) 'bin/Release/net10.0/Clc.Deployment.AspNetCore.dll') -Algorithm SHA256).Hash) {
    throw 'Test output does not contain the exact DLL restored from the packed package.'
}
& $dotnet run --project $testProject --configuration Release --no-build --no-restore -p:ClcReleaseVersion=$version | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Packed ASP.NET Core companion contract tests failed.' }

[pscustomobject]@{
    packageId = 'Clc.Deployment.AspNetCore'
    packageVersion = $version
    sourceCommit = $SourceCommit
    licenseExpression = 'MIT'
    package = $packageName
    packageSha256 = $digest
    nuGetContentHashSha512 = $expectedContentHash
    packageFeed = $feed
    testMode = 'PackageReference restored only from the exact local nupkg with an isolated cache; a generated exact-byte lock was restored again in locked mode'
}

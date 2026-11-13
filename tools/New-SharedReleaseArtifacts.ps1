[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RepositoryRoot,
    [Parameter(Mandatory)][string] $Tag,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string] $SourceCommit,
    [Parameter(Mandatory)][string] $DotnetPath,
    [Parameter(Mandatory)][string] $BundleRoot,
    [Parameter(Mandatory)][ValidateRange(1,[long]::MaxValue)][long] $ProducerRunId,
    [Parameter(Mandatory)][ValidateRange(1,1000)][int] $ProducerRunAttempt,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]{1,64}$')][string] $ProducerJob,
    [Parameter(Mandatory)][ValidatePattern('^clc-release-[a-f0-9]{40}-[1-9][0-9]*$')][string] $ArtifactName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root=[IO.Path]::GetFullPath($RepositoryRoot)
$bundle=[IO.Path]::GetFullPath($BundleRoot)
. (Join-Path $PSScriptRoot 'Distribution.Common.ps1')
$tagIdentity=& (Join-Path $PSScriptRoot 'Test-SharedReleaseTag.ps1') -RepositoryRoot $root -Tag $Tag -SourceCommit $SourceCommit
$version=$tagIdentity.version
Assert-DistLocalPath $bundle
if ([IO.Directory]::Exists($bundle) -or [IO.File]::Exists($bundle) -or -not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($bundle))) {
    throw 'Release bundle output must be a new directory with an existing parent.'
}

$work=$bundle+'.work-'+[guid]::NewGuid().ToString('N')
Assert-DistLocalPath $work
if ([IO.Directory]::Exists($work) -or [IO.File]::Exists($work)) { throw 'Release work directory already exists.' }
$null=[IO.Directory]::CreateDirectory($work)

$packageResult=& (Join-Path $PSScriptRoot 'Test-ClcDeploymentAspNetCore.ps1') -DotnetPath $DotnetPath -OutputRoot (Join-Path $work 'companion-test') -SourceCommit $SourceCommit -ReleaseVersion $version
if ($packageResult.packageVersion -cne $version -or $packageResult.sourceCommit -cne $SourceCommit -or $packageResult.licenseExpression -cne 'MIT') {
    throw 'Packed companion identity differs from the shared release.'
}
$packagePath=Join-Path $packageResult.packageFeed $packageResult.package
$packageIdentity=Get-DistNuGetPackageIdentity $packagePath
if ($packageIdentity.id -cne 'Clc.Deployment.AspNetCore' -or $packageIdentity.version -cne $version -or
    $packageIdentity.licenseType -cne 'expression' -or $packageIdentity.licenseExpression -cne 'MIT' -or
    $packageIdentity.repositoryType -cne 'git' -or $packageIdentity.repositoryUrl -cne 'https://github.com/clcdpc/clc-deployment' -or
    $packageIdentity.repositoryCommit -cne $SourceCommit) {
    throw 'Packed NuGet package metadata does not identify this shared source and version.'
}

$distributionWork=Join-Path $work 'toolkit'
$null=[IO.Directory]::CreateDirectory($distributionWork)
$distributionPath=Join-Path $distributionWork 'distribution.zip'
$toolkitIdentity=& (Join-Path $PSScriptRoot 'New-ToolkitDistribution.ps1') -RepositoryRoot $root -SourceCommit $SourceCommit -OutputPath $distributionPath -ReleaseVersion $version
if ($toolkitIdentity.moduleVersion -cne $version -or $toolkitIdentity.sourceCommit -cne $SourceCommit) {
    throw 'Toolkit distribution identity differs from the shared release.'
}
$null=& (Join-Path $PSScriptRoot 'Test-ToolkitDistribution.ps1') -ArchivePath $distributionPath -ExpectedSha256 $toolkitIdentity.distributionSha256 -ExpectedSourceCommit $SourceCommit -ExpectedVersion $version
$versions=Join-Path $work 'versions'
$null=[IO.Directory]::CreateDirectory($versions)
$installed=& (Join-Path $PSScriptRoot 'Expand-ToolkitDistribution.ps1') -ArchivePath $distributionPath -ExpectedSha256 $toolkitIdentity.distributionSha256 -ExpectedSourceCommit $SourceCommit -ExpectedVersion $version -VersionRoot (Join-Path $versions $version) -OperatorApprovalReference 'release-integrity-check'
if ($installed.activated -or -not $installed.extracted) { throw 'Release distribution extraction did not remain unactivated.' }

$candidateOutput=Join-Path $work 'candidate-probe-tests'
$candidateEvidence=& (Join-Path $PSScriptRoot 'Test-Candidate.ps1') -DotnetPath $DotnetPath -OutputRoot $candidateOutput -ProducerRunId $ProducerRunId -ProducerRunAttempt $ProducerRunAttempt -ProducerJob $ProducerJob -PrebuiltDistributionPath $distributionPath -PrebuiltDistributionSha256 $toolkitIdentity.distributionSha256 -PrebuiltVersion $version
if ($candidateEvidence.sourceCommit -cne $SourceCommit -or $candidateEvidence.toolkit.distributionSha256 -cne $toolkitIdentity.distributionSha256 -or $candidateEvidence.reproducible) {
    throw 'Candidate tests did not consume the exact prebuilt release distribution.'
}

$toolkitFile='CLC.Deployment-'+$version+'.zip'
$packageFile=$packageResult.package
[void][IO.Directory]::CreateDirectory($bundle)
[IO.File]::Copy($distributionPath,(Join-Path $bundle $toolkitFile),$false)
[IO.File]::Copy($packagePath,(Join-Path $bundle $packageFile),$false)
$toolkitDigest=(Get-FileHash -LiteralPath (Join-Path $bundle $toolkitFile) -Algorithm SHA256).Hash.ToLowerInvariant()
$packageDigest=(Get-FileHash -LiteralPath (Join-Path $bundle $packageFile) -Algorithm SHA256).Hash.ToLowerInvariant()
if ($toolkitDigest -cne $toolkitIdentity.distributionSha256 -or $packageDigest -cne $packageResult.packageSha256) {
    throw 'Copied release artifact bytes differ from the bytes that were tested.'
}

$manifest=[ordered]@{
    formatVersion=1
    repository='clcdpc/clc-deployment'
    tag=$Tag
    version=$version
    sourceCommit=$SourceCommit
    artifactName=$ArtifactName
    producer=[ordered]@{workflowPath='.github/workflows/build-test-publish.yaml';runId=$ProducerRunId;runAttempt=$ProducerRunAttempt;job=$ProducerJob}
    toolkit=[ordered]@{file=$toolkitFile;moduleVersion=$toolkitIdentity.moduleVersion;sourceCommit=$toolkitIdentity.sourceCommit;sha256=$toolkitDigest;inventorySha256=$toolkitIdentity.inventorySha256;sourceInventorySha256=$toolkitIdentity.sourceInventorySha256}
    companion=[ordered]@{file=$packageFile;packageId=$packageResult.packageId;packageVersion=$packageResult.packageVersion;licenseExpression=$packageResult.licenseExpression;sourceCommit=$packageResult.sourceCommit;sha256=$packageDigest;nuGetContentHashSha512=$packageResult.nuGetContentHashSha512}
    qualification=[ordered]@{actualIis='NOT RUN';authorizedForDeployment=$false}
}
[IO.File]::WriteAllText((Join-Path $bundle 'release-manifest.json'),($manifest | ConvertTo-Json -Depth 12 -Compress),[Text.UTF8Encoding]::new($false))
$null=& (Join-Path $PSScriptRoot 'Test-SharedReleaseArtifacts.ps1') -RepositoryRoot $root -BundleRoot $bundle -Tag $Tag -SourceCommit $SourceCommit -ArtifactName $ArtifactName -ProducerRunId $ProducerRunId -ProducerRunAttempt $ProducerRunAttempt
[pscustomobject]$manifest

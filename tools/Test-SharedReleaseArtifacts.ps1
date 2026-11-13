[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RepositoryRoot,
    [Parameter(Mandatory)][string] $BundleRoot,
    [Parameter(Mandatory)][string] $Tag,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string] $SourceCommit,
    [Parameter(Mandatory)][ValidatePattern('^clc-release-[a-f0-9]{40}-[1-9][0-9]*$')][string] $ArtifactName,
    [Parameter(Mandatory)][ValidateRange(1,[long]::MaxValue)][long] $ProducerRunId,
    [Parameter(Mandatory)][ValidateRange(1,1000)][int] $ProducerRunAttempt
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Distribution.Common.ps1')
$root=[IO.Path]::GetFullPath($RepositoryRoot)
$bundle=[IO.Path]::GetFullPath($BundleRoot)
$tagIdentity=& (Join-Path $PSScriptRoot 'Test-SharedReleaseTag.ps1') -RepositoryRoot $root -Tag $Tag -SourceCommit $SourceCommit
$null=Get-DistPathFacts $bundle -Directory
$version=$tagIdentity.version
$manifestPath=Join-Path $bundle 'release-manifest.json'
$null=Get-DistPathFacts $manifestPath
$manifest=Read-DistJson (Read-DistFileBytes $manifestPath 4194304)
Assert-DistFields $manifest @('formatVersion','repository','tag','version','sourceCommit','artifactName','producer','toolkit','companion','qualification')
Assert-DistFields $manifest.producer @('workflowPath','runId','runAttempt','job')
Assert-DistFields $manifest.toolkit @('file','moduleVersion','sourceCommit','sha256','inventorySha256','sourceInventorySha256')
Assert-DistFields $manifest.companion @('file','packageId','packageVersion','licenseExpression','sourceCommit','sha256','nuGetContentHashSha512')
Assert-DistFields $manifest.qualification @('actualIis','authorizedForDeployment')
if ($manifest.formatVersion -isnot [long] -or $manifest.formatVersion -ne 1 -or $manifest.repository -cne 'clcdpc/clc-deployment' -or
    $manifest.tag -cne $Tag -or $manifest.version -cne $version -or $manifest.sourceCommit -cne $SourceCommit -or $manifest.artifactName -cne $ArtifactName -or
    $manifest.producer.workflowPath -cne '.github/workflows/build-test-publish.yaml' -or $manifest.producer.runId -isnot [long] -or $manifest.producer.runId -ne $ProducerRunId -or
    $manifest.producer.runAttempt -isnot [long] -or $manifest.producer.runAttempt -ne $ProducerRunAttempt -or $manifest.producer.job -cne 'foundation' -or
    $manifest.toolkit.moduleVersion -cne $version -or $manifest.toolkit.sourceCommit -cne $SourceCommit -or
    $manifest.companion.packageId -cne 'Clc.Deployment.AspNetCore' -or $manifest.companion.packageVersion -cne $version -or
    $manifest.companion.licenseExpression -cne 'MIT' -or $manifest.companion.sourceCommit -cne $SourceCommit -or
    $manifest.qualification.actualIis -cne 'NOT RUN' -or $manifest.qualification.authorizedForDeployment -isnot [bool] -or $manifest.qualification.authorizedForDeployment) {
    throw 'Shared release manifest identity differs from the tag, source or expected artifacts.'
}
foreach ($hash in @($manifest.toolkit.sha256,$manifest.toolkit.inventorySha256,$manifest.toolkit.sourceInventorySha256,$manifest.companion.sha256)) {
    if ($hash -isnot [string] -or $hash -cnotmatch '\A[a-f0-9]{64}\z') { throw 'Release manifest contains an invalid SHA-256.' }
}
if ($manifest.companion.nuGetContentHashSha512 -isnot [string] -or $manifest.companion.nuGetContentHashSha512 -cnotmatch '\A[A-Za-z0-9+/]{86}==\z') {
    throw 'Release manifest contains an invalid NuGet SHA-512 content hash.'
}

$expectedToolkitFile='CLC.Deployment-'+$version+'.zip'
$expectedPackageFile='Clc.Deployment.AspNetCore.'+$version+'.nupkg'
if ($manifest.toolkit.file -cne $expectedToolkitFile -or $manifest.companion.file -cne $expectedPackageFile) { throw 'Release artifact filenames differ from the shared version.' }
$expectedFiles=[string[]]@($expectedToolkitFile,$expectedPackageFile,'release-manifest.json')
[Array]::Sort($expectedFiles,[StringComparer]::Ordinal)
$actualFiles=[string[]]@((Get-ChildItem -LiteralPath $bundle -File -Force | ForEach-Object { $_.Name }))
[Array]::Sort($actualFiles,[StringComparer]::Ordinal)
if ($actualFiles.Count -ne $expectedFiles.Count) { throw 'Release bundle contains missing or unexpected files.' }
for ($index=0; $index -lt $expectedFiles.Count; $index++) {
    if ($actualFiles[$index] -cne $expectedFiles[$index]) { throw 'Release bundle contains missing or unexpected files.' }
}

$toolkitPath=Join-Path $bundle $expectedToolkitFile
$packagePath=Join-Path $bundle $expectedPackageFile
$toolkitFacts=Get-DistPathFacts $toolkitPath
$packageFacts=Get-DistPathFacts $packagePath
$toolkitHash=(Get-FileHash -LiteralPath $toolkitPath -Algorithm SHA256).Hash.ToLowerInvariant()
$packageHash=(Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($toolkitHash -cne $manifest.toolkit.sha256 -or $packageHash -cne $manifest.companion.sha256) { throw 'Release artifact SHA-256 differs from the tested manifest.' }
$packageIdentity=Get-DistNuGetPackageIdentity $packagePath
$contentHash=[Convert]::ToBase64String([Security.Cryptography.SHA512]::HashData([IO.File]::ReadAllBytes($packagePath)))
if ($packageIdentity.id -cne $manifest.companion.packageId -or $packageIdentity.version -cne $version -or
    $packageIdentity.licenseType -cne 'expression' -or $packageIdentity.licenseExpression -cne $manifest.companion.licenseExpression -or
    $packageIdentity.repositoryType -cne 'git' -or $packageIdentity.repositoryUrl -cne 'https://github.com/clcdpc/clc-deployment' -or
    $packageIdentity.repositoryCommit -cne $SourceCommit -or $contentHash -cne $manifest.companion.nuGetContentHashSha512) {
    throw 'NuGet package identity or content hash differs from the release manifest.'
}
$toolkitIdentity=& (Join-Path $PSScriptRoot 'Test-ToolkitDistribution.ps1') -ArchivePath $toolkitPath -ExpectedSha256 $toolkitHash -ExpectedSourceCommit $SourceCommit -ExpectedVersion $version
if ($toolkitIdentity.moduleVersion -cne $manifest.toolkit.moduleVersion -or $toolkitIdentity.inventorySha256 -cne $manifest.toolkit.inventorySha256 -or
    $toolkitIdentity.sourceInventorySha256 -cne $manifest.toolkit.sourceInventorySha256) {
    throw 'Toolkit distribution inventory differs from the release manifest.'
}

[pscustomobject][ordered]@{
    verified = $true
    tag = $Tag
    version = $version
    sourceCommit = $SourceCommit
    artifactName = $ArtifactName
    toolkitSha256 = $toolkitHash
    companionPackageId = $packageIdentity.id
    companionVersion = $packageIdentity.version
    companionLicenseExpression = $packageIdentity.licenseExpression
    companionSha256 = $packageHash
    actualIisQualification = 'NOT RUN'
}

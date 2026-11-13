[CmdletBinding()]
param([Parameter(Mandatory)][string] $DotnetPath,[Parameter(Mandatory)][string] $OutputRoot,
    [Parameter(Mandatory)][ValidateRange(1,[long]::MaxValue)][long] $ProducerRunId,
    [Parameter(Mandatory)][ValidateRange(1,1000)][int] $ProducerRunAttempt,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]{1,64}$')][string] $ProducerJob,
    [string] $PrebuiltDistributionPath,
    [string] $PrebuiltDistributionSha256,
    [string] $PrebuiltVersion)
. "$PSScriptRoot/Distribution.Common.ps1"
$repository=[IO.Path]::GetDirectoryName($PSScriptRoot); $source=Get-DistGit $repository @('rev-parse','HEAD')
Assert-DistLocalPath $OutputRoot
if ([IO.Directory]::Exists($OutputRoot)) { throw 'Candidate output must be new.' }
$null=[IO.Directory]::CreateDirectory($OutputRoot)
if ($PrebuiltDistributionPath) {
    if ($PrebuiltDistributionSha256 -cnotmatch '^[a-f0-9]{64}$' -or -not $PrebuiltVersion) { throw 'A prebuilt distribution requires its exact digest and version.' }
    Assert-DistVersion $PrebuiltVersion
    $first=[IO.Path]::GetFullPath($PrebuiltDistributionPath)
    $identity=& "$PSScriptRoot/Test-ToolkitDistribution.ps1" -ArchivePath $first -ExpectedSha256 $PrebuiltDistributionSha256 -ExpectedSourceCommit $source -ExpectedVersion $PrebuiltVersion
    $reproducible=$false
} else {
    if ($PrebuiltDistributionSha256 -or $PrebuiltVersion) { throw 'Prebuilt distribution metadata requires a distribution path.' }
    $first=Join-Path $OutputRoot 'toolkit.zip'; $second=Join-Path $OutputRoot 'toolkit-reproduction.zip'
    $identity=& "$PSScriptRoot/New-ToolkitDistribution.ps1" -RepositoryRoot $repository -SourceCommit $source -OutputPath $first
    $reproduction=& "$PSScriptRoot/New-ToolkitDistribution.ps1" -RepositoryRoot $repository -SourceCommit $source -OutputPath $second
    if ($identity.distributionSha256 -cne $reproduction.distributionSha256) { throw 'Same-toolchain distribution bytes did not reproduce.' }
    $reproducible=$true
}
$versions=Join-Path $OutputRoot 'versions'; $null=[IO.Directory]::CreateDirectory($versions)
$extraction=& "$PSScriptRoot/Expand-ToolkitDistribution.ps1" -ArchivePath $first -ExpectedSha256 $identity.distributionSha256 -ExpectedSourceCommit $source -ExpectedVersion $identity.moduleVersion -VersionRoot (Join-Path $versions $identity.moduleVersion) -OperatorApprovalReference hosted-integrity-test
$releases=@()
foreach ($slot in @('initial','newer')) {
    $release=& "$repository/tests/Qualification/Scripts/New-ProbeRelease.ps1" -DotnetPath $DotnetPath -ToolkitManifestPath $extraction.moduleManifestPath -ToolkitSourceCommit $source -ToolkitDistributionSha256 $identity.distributionSha256 -ToolkitVersion $identity.moduleVersion -ReleaseId ('t4-'+$slot+'-'+$ProducerRunId) -SourceCommit $source -RunId $ProducerRunId -RunAttempt $ProducerRunAttempt -BuildJob $ProducerJob -OutputRoot (Join-Path $OutputRoot $slot)
    $releases += $release
}
foreach ($kind in @('WrongRelease','WrongSource','WrongRevision','Redirect','Authentication','Cookie','Timeout','Unavailable','StartupFailure')) {
    $label=([regex]::Replace($kind,'([a-z])([A-Z])','$1-$2')).ToLowerInvariant()
    $releases += & "$repository/tests/Qualification/Scripts/New-ProbeRelease.ps1" -DotnetPath $DotnetPath -ToolkitManifestPath $extraction.moduleManifestPath -ToolkitSourceCommit $source -ToolkitDistributionSha256 $identity.distributionSha256 -ToolkitVersion $identity.moduleVersion -ReleaseId ('t4-fault-'+$label+'-'+$ProducerRunId) -SourceCommit $source -RunId $ProducerRunId -RunAttempt $ProducerRunAttempt -BuildJob $ProducerJob -OutputRoot (Join-Path $OutputRoot ('fixture-'+$label)) -FailureKind $kind
}
foreach ($release in $releases) {
    $archive=[IO.Compression.ZipFile]::OpenRead($release.package.archivePath)
    try {
        $manifest=Read-DistJson (Read-DistEntry $archive.GetEntry('manifest.json') 4194304)
        $inputsBytes=Read-DistEntry $archive.GetEntry('application/qualification-build-inputs.json') 4194304
        $inputs=Read-DistJson $inputsBytes
        if ($inputs.project -cnotin @('tests/Qualification/ProbeApp/ProbeApp.csproj','tests/Qualification/FailureApp/FailureApp.csproj')) { throw 'Unexpected candidate project path.' }
        $actualLock=(Get-FileHash -LiteralPath (Join-Path ([IO.Path]::GetDirectoryName((Join-Path $repository $inputs.project))) 'packages.lock.json')).Hash.ToLowerInvariant()
        if ($manifest.build.dependencyLockSha256 -cne $actualLock -or $inputs.packageLockSha256 -cne $actualLock -or (Get-DistHash $inputsBytes) -cne $release.buildInputsSha256) { throw 'Actual dependency-lock or distinct build-input identity differs.' }
    } finally { $archive.Dispose() }
}
$evidence=[ordered]@{formatVersion=1;sourceCommit=$source;toolkit=$identity;reproducible=$reproducible;probeReleases=$releases;producer=@{runId=$ProducerRunId;runAttempt=$ProducerRunAttempt;job=$ProducerJob};actualIisQualification='NOT RUN';approvedForDeployment=$false}
[IO.File]::WriteAllText((Join-Path $OutputRoot 'candidate-evidence.json'),($evidence | ConvertTo-Json -Depth 20 -Compress),[Text.UTF8Encoding]::new($false))
$evidence

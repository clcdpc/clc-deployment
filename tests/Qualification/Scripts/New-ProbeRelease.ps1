[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $DotnetPath,
    [Parameter(Mandatory)][string] $ToolkitManifestPath,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string] $ToolkitSourceCommit,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string] $ToolkitDistributionSha256,
    [string] $ToolkitVersion='',
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9-]{0,63}$')][string] $ReleaseId,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string] $SourceCommit,
    [Parameter(Mandatory)][ValidateRange(1,[long]::MaxValue)][long] $RunId,
    [Parameter(Mandatory)][ValidateRange(1,1000)][int] $RunAttempt,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]{1,64}$')][string] $BuildJob,
    [Parameter(Mandatory)][string] $OutputRoot,
    [ValidateSet('Small','Comparable8MiB','FrameworkPublish','Large')][string] $Profile='Small',
    [ValidateSet('None','WrongRelease','WrongSource','WrongRevision','Redirect','Authentication','Cookie','Timeout','Unavailable','StartupFailure')][string] $FailureKind='None',
    [string] $RepresentativePublishRoot,[string] $RepresentativeInventorySha256,[string] $RepresentativeSourceRepository,[string] $RepresentativeSourceCommit,[string] $RepresentativeProducerReference
)
$ErrorActionPreference='Stop'; Set-StrictMode -Version Latest
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. "$repository/tools/Distribution.Common.ps1"
. "$repository/tools/Probe.Metadata.ps1"
if ([string]::IsNullOrEmpty($ToolkitVersion)) {
    $ToolkitVersion=Get-DistVersionFromBytes ([IO.File]::ReadAllBytes((Join-Path $repository 'VERSION')))
}
Assert-DistVersion $ToolkitVersion
foreach ($path in @($DotnetPath,$ToolkitManifestPath,$OutputRoot)) { Assert-DistLocalPath $path }
if ((Get-DistGit $repository @('rev-parse','HEAD')) -cne $SourceCommit -or (Get-DistGit $repository @('status','--porcelain=v1','--untracked-files=normal'))) { throw 'Probe releases require an exact clean committed source.' }
if ([IO.Directory]::Exists($OutputRoot)) { throw 'Probe output must be new.' }
$sdk=(& $DotnetPath --version).Trim(); if ($LASTEXITCODE -ne 0 -or $sdk -cne '10.0.403') { throw 'Wrong pinned probe SDK.' }
$null=[IO.Directory]::CreateDirectory($OutputRoot)
$publish=Join-Path $OutputRoot 'publish'
$project=if ($FailureKind -ceq 'None') {'tests/Qualification/ProbeApp/ProbeApp.csproj'} else {'tests/Qualification/FailureApp/FailureApp.csproj'}
& $DotnetPath publish (Join-Path $repository $project) -c Release -p:RestoreLockedMode=true --self-contained false -r win-x64 -o $publish ('-p:ProbeReleaseId='+$ReleaseId) ('-p:ProbeSourceCommit='+$SourceCommit) ('-p:ProbeFailureKind='+$FailureKind) -p:ContinuousIntegrationBuild=true | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Probe publish failed.' }
$embedded=Get-ProbeEmbeddedMetadata (Join-Path $publish 'ClcQualificationProbe.dll')
if ($embedded['ApplicationId'] -cne 'clc-qualification-probe' -or $embedded['ReleaseId'] -cne $ReleaseId -or $embedded['SourceCommit'] -cne $SourceCommit -or ($FailureKind -cne 'None' -and $embedded['FailureKind'] -cne $FailureKind)) { throw 'Actual embedded build identity differs.' }
$representative=$null
if ($RepresentativePublishRoot) {
    if ($Profile -cnotin @('FrameworkPublish','Large')) { throw 'Representative input is supported only by representative workload profiles.' }
    $representative=& "$repository/tools/Copy-QualificationPayload.ps1" -PublishRoot $RepresentativePublishRoot -ExpectedInventorySha256 $RepresentativeInventorySha256 -SourceRepository $RepresentativeSourceRepository -SourceCommit $RepresentativeSourceCommit -ProducerReference $RepresentativeProducerReference -DestinationRoot (Join-Path $publish 'assets\representative') -DisposableTestPayload
}
$toolkitModuleRoot=[IO.Path]::GetDirectoryName($ToolkitManifestPath)
$toolkitVersionRoot=[IO.Path]::GetDirectoryName($toolkitModuleRoot)
$null=& "$repository/tools/Test-ToolkitDistribution.ps1" -ArchivePath (Join-Path $toolkitVersionRoot 'distribution.zip') -ExpectedSha256 $ToolkitDistributionSha256 -ExpectedSourceCommit $ToolkitSourceCommit -ExpectedVersion $ToolkitVersion -InstalledModuleRoot $toolkitModuleRoot
if ([Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes((Join-Path $toolkitVersionRoot 'source.commit'))) -cne $ToolkitSourceCommit) { throw 'Builder toolkit source identity differs.' }
$toolkitModule=Import-Module $ToolkitManifestPath -Force -PassThru
$version=& $toolkitModule { Get-ClcToolkitVersion }
if ($version -cne $ToolkitVersion) { throw 'Imported toolkit identity differs from the verified distribution.' }
$metadata=[ordered]@{contractFamily='clc-file-iis-v1';schemaVersion=1;recordKind='release-metadata';applicationId='clc-qualification-probe';releaseId=$ReleaseId;
    source=@{repository='clcdpc/clc-deployment';commit=$SourceCommit};build=@{workflowPath='.github/workflows/build-test-publish.yaml';runId=$RunId;runAttempt=$RunAttempt;job=$BuildJob;sdkVersion=$sdk;dependencyLockSha256=(Get-FileHash -LiteralPath (Join-Path ([IO.Path]::GetDirectoryName((Join-Path $repository $project))) 'packages.lock.json')).Hash.ToLowerInvariant()};
    builder=@{module='CLC.Deployment';version=$version;sourceCommit=$ToolkitSourceCommit;distributionSha256=$ToolkitDistributionSha256};
    runtime=@{framework='net10.0';rid='win-x64';architecture='x64';hostingModel='inprocess';workerLimit=1};changeKind='files-only';validation=@{contractVersion=1;entryPoint='ClcQualificationProbe.dll'};readinessContractVersion=1}
$inputRoot=Join-Path $OutputRoot 'input'; $packageRoot=Join-Path $OutputRoot 'output'
$null=[IO.Directory]::CreateDirectory($inputRoot); $null=[IO.Directory]::CreateDirectory($packageRoot)
$buildInputs=[ordered]@{sourceCommit=$SourceCommit;project=$project;sdkPinSha256=(Get-FileHash -LiteralPath (Join-Path $repository 'tools/probe-sdk.lock.json')).Hash.ToLowerInvariant();packageLockSha256=$metadata.build.dependencyLockSha256;profile=$Profile;failureKind=$FailureKind;representative=$representative}
$buildInputsPath=Join-Path $inputRoot 'build-inputs.json'
[IO.File]::WriteAllText($buildInputsPath,($buildInputs | ConvertTo-Json -Depth 12 -Compress),[Text.UTF8Encoding]::new($false))
$buildInputsSha256=(Get-FileHash -LiteralPath $buildInputsPath).Hash.ToLowerInvariant()
[IO.File]::Copy($buildInputsPath,(Join-Path $publish 'qualification-build-inputs.json'),$false)
# The manifest's dependencyLockSha256 remains the actual packages.lock.json
# digest. The distinct build-input record is authenticated as an inventoried app
# file, and its separate digest is returned in producer evidence.
$padding=switch ($Profile) { Comparable8MiB { @{count=(68-@(Get-ChildItem -LiteralPath $publish -Recurse -File).Count);size=0} }; Large { @{count=512;size=262144} }; default { @{count=0;size=0} } }
if ($padding.count -lt 0) { throw 'Comparable fixture exceeds its intended count.' }
if ($padding.count) {
    $random=[Random]::new(4104)
    $remaining=8388608-[long]((Get-ChildItem -LiteralPath $publish -Recurse -File | Measure-Object Length -Sum).Sum)
    for ($i=0;$i -lt $padding.count;$i++) {
        $size=if ($Profile -ceq 'Comparable8MiB') { [int][Math]::Floor($remaining/($padding.count-$i)) } else {$padding.size}
        if ($size -lt 0) { throw 'Comparable fixture exceeds its intended size.' }
        $bytes=[byte[]]::new($size); $random.NextBytes($bytes); [IO.File]::WriteAllBytes((Join-Path $publish ('payload-'+$i.ToString('D4')+'.dat')),$bytes); $remaining-=$size
    }
}
$metadataPath=Join-Path $inputRoot 'metadata.json'
[IO.File]::WriteAllText($metadataPath,($metadata | ConvertTo-Json -Depth 16 -Compress),[Text.UTF8Encoding]::new($false))
$package=New-ClcRelease -PublishRoot $publish -MetadataPath $metadataPath -OutputPath (Join-Path $packageRoot 'release.zip')
$inspection=Test-ClcRelease -ArchivePath $package.archivePath
if ($inspection.sourceCommit -cne $SourceCommit -or $inspection.releaseId -cne $ReleaseId -or $inspection.authorizedForDeployment) { throw 'Probe inspection differs.' }
[pscustomobject]@{profile=$Profile;failureKind=$FailureKind;buildInputsSha256=$buildInputsSha256;representative=$representative;package=$package;inspection=$inspection;approvalCreated=$false}

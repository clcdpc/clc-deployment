[CmdletBinding(DefaultParameterSetName='Build')]
param(
    [Parameter(Mandatory)][string] $ConfigurationPath,
    [Parameter(Mandatory)][string] $SourceRoot,
    [Parameter(Mandatory)][string] $Reference,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string] $SourceCommit,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string] $SharedSourceCommit,
    [Parameter(Mandatory)][ValidateRange(1,[long]::MaxValue)][long] $RunId,
    [Parameter(Mandatory)][ValidateRange(1,1000)][long] $RunAttempt,
    [Parameter(Mandatory,ParameterSetName='Prequalified')][string] $QualifiedPublishRoot,
    [Parameter(Mandatory,ParameterSetName='Prequalified')][string] $SdkVersion,
    [Parameter(ParameterSetName='Prequalified')][string] $ValidationEntryPoint,
    [Parameter(Mandatory)][string] $OutputDirectory
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Workflow.Common.ps1')
$c=Read-ClcConsumerConfiguration $ConfigurationPath
if ($PSCmdlet.ParameterSetName -ceq 'Build' -and -not $c.Contains('project')) { throw 'The conventional build requires one application project.' }
if ([IO.Directory]::Exists($OutputDirectory) -or [IO.File]::Exists($OutputDirectory)) { throw 'Build output must be new.' }
$null=[IO.Directory]::CreateDirectory($OutputDirectory)
$api={param($method,$path,$body,[switch]$Bytes) Invoke-ClcReleaseApi -Repository $c.repository -Method $method -Path $path -Body $body -Bytes:$Bytes}
if ($Reference -ceq $c.integrationBranch) { $Reference='refs/heads/'+$Reference }
$source=Get-ClcVerifiedSource $c $Reference $SourceCommit $RunId $api
if ($PSCmdlet.ParameterSetName -ceq 'Prequalified') {
    $qualified=Get-ClcQualifiedPublishInputs $c $SourceRoot $QualifiedPublishRoot $SdkVersion $ValidationEntryPoint
    $publish=$qualified.publishRoot; $sdk=@{sdkVersion=$qualified.sdkVersion}
    $assembly=[IO.Path]::GetFileNameWithoutExtension($qualified.entryPoint)
    $lockPath=$qualified.dependencyLockPath
} else {
$env:DOTNET_GENERATE_ASPNET_CERTIFICATE='false'; $env:DOTNET_CLI_TELEMETRY_OPTOUT='1'; $env:DOTNET_NOLOGO='1'
$sdk=& (Join-Path $PSScriptRoot '../Initialize-ProbeSdk.ps1') -DestinationRoot (Join-Path $OutputDirectory 'sdk')
$dotnet=$sdk.dotnetPath
$project=Join-Path $SourceRoot $c.project
$properties=@(('-p:ClcApplicationId='+$c.applicationId),('-p:ClcReleaseId='+$source.identity.releaseId),('-p:ClcSourceCommit='+$SourceCommit))
Push-Location $SourceRoot
try {
    & $dotnet restore $project --locked-mode --runtime win-x64
    if ($LASTEXITCODE -ne 0) { throw 'Locked application restore failed.' }
    & $dotnet build $project --configuration Release --no-restore @properties
    if ($LASTEXITCODE -ne 0) { throw 'Application build failed.' }
    if ($c.Contains('testProject')) {
        $test=Join-Path $SourceRoot $c.testProject
        & $dotnet restore $test --locked-mode
        if ($LASTEXITCODE -ne 0) { throw 'Locked test restore failed.' }
        & $dotnet test $test --configuration Release --no-restore @properties
        if ($LASTEXITCODE -ne 0) { throw 'Application qualification failed.' }
    }
    $publish=Join-Path $OutputDirectory 'publish'
    & $dotnet publish $project --configuration Release --no-restore --runtime win-x64 --self-contained false --output $publish @properties
    if ($LASTEXITCODE -ne 0) { throw 'Application publish failed.' }
    $assembly=(& $dotnet msbuild $project -nologo -getProperty:AssemblyName).Trim()
    if ($LASTEXITCODE -ne 0 -or $assembly -cnotmatch '^[A-Za-z0-9_-][A-Za-z0-9_.-]*$') { throw 'Application assembly identity is invalid.' }
} finally { Pop-Location }
$lockDirectory=if ($c.Contains('project')) {[IO.Path]::GetDirectoryName((Join-Path $SourceRoot $c.project))} else {$SourceRoot}
$lockPath=Join-Path $lockDirectory 'packages.lock.json'
if (-not [IO.File]::Exists($lockPath)) { throw 'Application dependency lock is required.' }
}
$lockHash=if ($null -ne $lockPath) { (Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
$sharedRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$distribution=& (Join-Path $sharedRoot 'tools/New-ToolkitDistribution.ps1') -RepositoryRoot $sharedRoot -SourceCommit $SharedSourceCommit -OutputPath (Join-Path $OutputDirectory 'toolkit.zip')
Import-Module (Join-Path $sharedRoot 'src/CLC.Deployment/CLC.Deployment.psd1') -Force
$metadata=[ordered]@{contractFamily='clc-file-iis-v1';schemaVersion=2L;recordKind='release-metadata';applicationId=$c.applicationId;releaseId=$source.identity.releaseId;
    source=@{repository=$c.repository;commit=$SourceCommit};build=@{workflowPath=$c.producer.workflowPath;runId=$RunId;runAttempt=$RunAttempt;job=$c.producer.job;sdkVersion=$sdk.sdkVersion;dependencyLockSha256=$lockHash};
    builder=@{module='CLC.Deployment';version=$distribution.moduleVersion;sourceCommit=$SharedSourceCommit;distributionSha256=$distribution.distributionSha256};
    runtime=@{framework='net10.0';rid='win-x64';architecture='x64';hostingModel='inprocess';workerLimit=1L};changeKind='application-deployment';validation=@{contractVersion=1L;entryPoint=$assembly+'.dll'};readinessContractVersion=1L}
$parameters=@{PublishRoot=$publish;MetadataPath=(Join-Path $OutputDirectory 'metadata.json')}
if ($c.Contains('hooks')) { $metadata.hooks=$c.hooks; $parameters.HookRoot=Join-Path $SourceRoot '.clc/hooks' }
[IO.File]::WriteAllText($parameters.MetadataPath,($metadata | ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
$bundle=Join-Path $OutputDirectory 'qualified'; $null=[IO.Directory]::CreateDirectory($bundle)
$parameters.OutputPath=Join-Path $bundle 'release.zip'
$result=New-ClcRelease @parameters
if ($env:GITHUB_OUTPUT) {
    [IO.File]::AppendAllText($env:GITHUB_OUTPUT,'artifact_name=clc-package-'+$SourceCommit+'-'+$RunId+'-'+$RunAttempt+"`n"+'artifact_path='+$bundle+"`n",[Text.UTF8Encoding]::new($false))
}
return $result

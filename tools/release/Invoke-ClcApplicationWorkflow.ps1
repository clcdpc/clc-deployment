[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Route','Release','Deploy')][string] $Action,
    [Parameter(Mandatory)][string] $ClaimsJson,
    [Parameter(Mandatory)][string] $Repository,
    [Parameter(Mandatory)][string] $Reference,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string] $SourceCommit,
    [Parameter(Mandatory)][ValidateRange(1,[long]::MaxValue)][long] $RunId,
    [Parameter(Mandatory)][ValidateRange(1,1000)][long] $RunAttempt,
    [ValidateRange(0,[long]::MaxValue)][long] $ArtifactId=0,
    [string] $ExpectedRuntimeAccount,
    [string] $ExpectedConfigurationBlob,
    [Parameter(Mandatory)][string] $OutputDirectory
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Workflow.Common.ps1')
if ([IO.Directory]::Exists($OutputDirectory) -or [IO.File]::Exists($OutputDirectory)) { throw 'Workflow evidence directory must be new.' }
$null=[IO.Directory]::CreateDirectory($OutputDirectory)
$claims=$ClaimsJson | ConvertFrom-Json -AsHashtable -DateKind String
$api={param($method,$path,$body,[switch]$Bytes) Invoke-ClcReleaseApi -Repository $Repository -Method $method -Path $path -Body $body -Bytes:$Bytes}
function Write-WorkflowOutput([string] $Name,[string] $Value) {
    if ($Value.Contains("`n") -or $Value.Contains("`r")) { throw 'Workflow output contains a line break.' }
    if ($env:GITHUB_OUTPUT) { [IO.File]::AppendAllText($env:GITHUB_OUTPUT,$Name+'='+$Value+"`n",[Text.UTF8Encoding]::new($false)) }
}
$workflow=if ($Action -ceq 'Release') {'release'} else {'deploy'}
$trusted=Get-ClcProtectedWorkflowConfiguration $claims $Repository $workflow $OutputDirectory $api
$c=$trusted.configuration
Assert-ClcWorkflowSource $claims $c $Reference $SourceCommit $RunId $RunAttempt
if ($Action -ceq 'Deploy' -and ($ExpectedConfigurationBlob -cnotmatch '^[a-f0-9]{40}$' -or $trusted.blob -cne $ExpectedConfigurationBlob)) { throw 'Protected routing configuration changed while queued.' }
$qualified=Get-ClcWorkflowRelease $c $Reference $SourceCommit $RunId $RunAttempt $ArtifactId $api
$source=$qualified.source; $producer=$qualified.producer

$route=Get-ClcDeploymentRoute $c $source
if ($Action -ceq 'Route' -and $null -eq $route.targetId) {
    Write-WorkflowOutput deploy false
    return
}
if ($Action -ceq 'Deploy' -and ($null -eq $route.targetId -or -not $ExpectedRuntimeAccount -or
    -not $claims.Contains('environment') -or $claims.environment -cne $route.environment)) {
    throw 'The job lacks the matching deployment environment or expected runtime account.'
}
Import-Module (Join-Path $PSScriptRoot '../../src/Clc.Deployment/Clc.Deployment.psd1') -Force
$archive=Save-ClcVerifiedArtifact $Repository $producer (Join-Path $OutputDirectory 'artifact') $api
if ($Action -ceq 'Release') {
    $verified=Get-ClcVerifiedPackage $c $source $producer $archive
    # Reobserve mutable eligibility after the download and before publication.
    $again=Get-ClcWorkflowRelease $c $Reference $SourceCommit $RunId $RunAttempt $producer.artifactId $api
    if (($again.source.identity | ConvertTo-Json -Compress) -cne ($source.identity | ConvertTo-Json -Compress)) { throw 'Release source changed during verification.' }
    $asset=@{name='release.zip';path=$archive;length=[long](Get-Item -LiteralPath $archive).Length;sha256=$verified.archiveSha256}
    $hash={param($asset) $bytes=Invoke-ClcReleaseApi $Repository GET ('/repos/'+$Repository+'/releases/assets/'+$asset.id) -Bytes; return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]$bytes)).ToLowerInvariant()}
    $upload={param($release,$asset) Send-ClcApplicationReleaseAsset $Repository $release $asset}
    return Invoke-ClcApplicationPublication $source.identity @($asset) $api $hash $upload
}


$verified=Get-ClcVerifiedPackage $c $source $producer $archive
$again=Get-ClcWorkflowRelease $c $Reference $SourceCommit $RunId $RunAttempt $producer.artifactId $api
if (($again.source.identity | ConvertTo-Json -Compress) -cne ($source.identity | ConvertTo-Json -Compress) -or
    $again.producer.transportSha256 -cne $producer.transportSha256) { throw 'Source or artifact identity changed during deployment verification.' }
$expectedSha256=Assert-ClcPublishedPackage $again.source $verified $api
if ($Action -ceq 'Route') {
    Write-WorkflowOutput deploy true
    Write-WorkflowOutput configuration_blob $trusted.blob
    Write-WorkflowOutput artifact_id $producer.artifactId.ToString([Globalization.CultureInfo]::InvariantCulture)
    Write-WorkflowOutput environment $route.environment
    Write-WorkflowOutput runner_labels ($route.runnerLabels | ConvertTo-Json -Compress)
    Write-WorkflowOutput target_id $route.targetId
    return
}

$safePath=Join-Path $OutputDirectory 'deployment-summary.json'
try {
    $parameters=@{ApplicationId=$c.applicationId;TargetId=$route.targetId;ArchivePath=$archive;ExpectedSha256=$expectedSha256;
        ReleaseTag=$source.identity.tag;ExpectedSourceCommit=$source.identity.sourceCommit;ExpectedRepository=$Repository;
        RuntimeEnvironment=$route.runtimeEnvironment;ExpectedRuntimeAccount=$ExpectedRuntimeAccount}
    $result=Invoke-ClcIisDeployment @parameters
} catch {
    $code=if ($_.FullyQualifiedErrorId -like 'Clc.*') {$_.FullyQualifiedErrorId.Split(',')[0]} else {'Clc.OperationFailed'}
    try {
        [IO.File]::WriteAllText($safePath,(@{status='Failed';code=$code;targetId=$route.targetId;releaseId=$verified.releaseId;
            nextAction='InspectLocalAttemptEvidence'} | ConvertTo-Json))
    } catch { Write-Warning 'The diagnostic summary could not be written.' }
    throw 'Deployment failed. Inspect retained local host evidence before retry or explicit recovery.'
}


# Reporting follows the durable deployment outcome.
$result.PSObject.Properties.Remove('retainedPath')
try { [IO.File]::WriteAllText($safePath,($result | ConvertTo-Json -Depth 8)) }
catch { Write-Warning 'Deployment succeeded. The optional workflow summary could not be written.' }
return $result

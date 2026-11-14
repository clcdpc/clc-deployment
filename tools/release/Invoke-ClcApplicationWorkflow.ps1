[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Admit','Release','Deploy')][string] $Action,
    [Parameter(Mandatory)][string] $ClaimsJson,
    [Parameter(Mandatory)][string] $Repository,
    [Parameter(Mandatory)][string] $Reference,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string] $SourceCommit,
    [Parameter(Mandatory)][ValidateRange(1,[long]::MaxValue)][long] $RunId,
    [Parameter(Mandatory)][ValidateRange(1,1000)][long] $RunAttempt,
    [ValidateRange(0,[long]::MaxValue)][long] $ArtifactId=0,
    [bool] $Automatic=$true,
    [ValidateSet('Deploy','ValidateOnly')][string] $Operation='Deploy',
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
if ($Action -ceq 'Deploy' -and ($ExpectedConfigurationBlob -cnotmatch '^[a-f0-9]{40}$' -or $trusted.blob -cne $ExpectedConfigurationBlob)) { throw 'Protected routing configuration changed while queued.' }
$qualified=Get-ClcWorkflowRelease $c $Reference $SourceCommit $RunId $RunAttempt $ArtifactId $api
$source=$qualified.source; $producer=$qualified.producer
if ($Action -ceq 'Admit') {
    $route=Get-ClcDeploymentRoute $c $source $Automatic $claims $api
    if ($route.admitted) {
        $archive=Save-ClcVerifiedArtifact $Repository $producer (Join-Path $OutputDirectory 'artifact') $api
        Import-Module (Join-Path $PSScriptRoot '../../src/CLC.Deployment/CLC.Deployment.psd1') -Force
        $null=New-ClcVerifiedPackageIdentity $c $source $producer $archive $route.target.targetId
        $again=Get-ClcWorkflowRelease $c $Reference $SourceCommit $RunId $RunAttempt $producer.artifactId $api
        $route=Get-ClcDeploymentRoute $c $again.source $Automatic $claims $api
    }
    Write-WorkflowOutput admitted $route.admitted.ToString().ToLowerInvariant()
    Write-WorkflowOutput status $route.status
    Write-WorkflowOutput configuration_blob $trusted.blob
    Write-WorkflowOutput artifact_id $producer.artifactId.ToString([Globalization.CultureInfo]::InvariantCulture)
    if ($route.admitted) {
        Write-WorkflowOutput environment $route.target.environment
        Write-WorkflowOutput runner_group $route.target.runnerGroup
        Write-WorkflowOutput runner_labels ($route.target.runnerLabels | ConvertTo-Json -Compress)
        Write-WorkflowOutput target_id $route.target.targetId
    }
    return [pscustomobject]@{status=$route.status;admitted=$route.admitted}
}
if ($Action -ceq 'Deploy') {
    $route=Get-ClcDeploymentRoute $c $source $Automatic $claims $api
    if (-not $route.admitted) { return [pscustomobject]@{status=$route.status;admitted=$false} }
    if (-not $claims.Contains('environment') -or $claims.environment -cne $route.target.environment) { throw 'Queued job environment differs from protected target authorization.' }
}
$archive=Save-ClcVerifiedArtifact $Repository $producer (Join-Path $OutputDirectory 'artifact') $api
if ($Action -ceq 'Release') {
    Import-Module (Join-Path $PSScriptRoot '../../src/CLC.Deployment/CLC.Deployment.psd1') -Force
    $verified=New-ClcVerifiedPackageIdentity $c $source $producer $archive $c.applicationId
    # Reobserve mutable eligibility after the download and before publication.
    $again=Get-ClcWorkflowRelease $c $Reference $SourceCommit $RunId $RunAttempt $producer.artifactId $api
    if (($again.source.identity | ConvertTo-Json -Compress) -cne ($source.identity | ConvertTo-Json -Compress)) { throw 'Release source changed during verification.' }
    if ($source.identity.kind -ceq 'snapshot') { return [pscustomobject]@{status='ActionsArtifactRetained';releaseId=$verified.releaseId} }
    $asset=@{name='release.zip';path=$archive;length=[long](Get-Item -LiteralPath $archive).Length;sha256=$verified.releaseZipSha256}
    $hash={param($asset) $bytes=Invoke-ClcReleaseApi $Repository GET ('/repos/'+$Repository+'/releases/assets/'+$asset.id) -Bytes; return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]$bytes)).ToLowerInvariant()}
    $upload={param($release,$asset) Send-ClcApplicationReleaseAsset $Repository $release $asset}
    return Invoke-ClcApplicationPublication $source.identity @($asset) $api $hash $upload
}

# This fixed policy location is infrastructure-owned. No artifact/config input
# can choose an installed toolkit, target root, inbox, or approval catalog.
$toolkit=Open-ClcWorkflowToolkit
try {
$policy=$toolkit.policy
$verified=New-ClcVerifiedPackageIdentity $c $source $producer $archive $route.target.targetId
$baseName='workflow-'+$RunId+'-'+$RunAttempt+'-'+[guid]::NewGuid().ToString('N')
$bytes=[Text.Encoding]::UTF8.GetBytes(($verified | ConvertTo-Json -Depth 12 -Compress))
$handoff=& (Get-Module CLC.Deployment) {
    param($TargetId,$ApplicationId,$Archive,$BaseName,$Bytes)
    $context=$null
    try {
        $context=Open-ClcTrustedContext
        $file=Read-ClcProtectedTarget $context $TargetId; $target=$file.record
        if ($target.applicationId -cne $ApplicationId) { Stop-ClcError Clc.ApprovalMismatch }
        $null=Add-ClcProtectedPathPin $context $target.artifactInboxRoot -Directory -Mutable -RuntimeSid $target.runtimeIdentitySid
        $zip=Join-Path $target.artifactInboxRoot ($BaseName+'.zip'); $identity=Join-Path $target.artifactInboxRoot ($BaseName+'.json')
        Assert-ClcPathSpelling $zip; Assert-ClcPathSpelling $identity
        [IO.File]::Copy($Archive,$zip,$false)
        $out=[IO.File]::Open($identity,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try { $out.Write($Bytes); $out.Flush($true) } finally { $out.Dispose() }
        return @{target=$target;zip=$zip;identity=$identity}
    } finally { Close-ClcTrustedContext $context }
} $route.target.targetId $c.applicationId $archive $baseName $bytes
$target=$handoff.target; $inboxZip=$handoff.zip; $inboxIdentity=$handoff.identity
# Recheck current tag/PR/head, successful producer attempt and artifact identity
# immediately before protected host admission, after runner queue and download.
$again=Get-ClcWorkflowRelease $c $Reference $SourceCommit $RunId $RunAttempt $producer.artifactId $api
$finalRoute=Get-ClcDeploymentRoute $c $again.source $Automatic $claims $api
if (-not $finalRoute.admitted) { return [pscustomobject]@{status=$finalRoute.status;admitted=$false} }
if (($again.source.identity | ConvertTo-Json -Compress) -cne ($source.identity | ConvertTo-Json -Compress)) { throw 'Release source changed before host admission.' }
$safePath=Join-Path $OutputDirectory 'deployment-summary.json'
try {
    $result=Invoke-ClcIisDeployment -TargetId $target.targetId -StandingAuthorizationId $route.target.standingAuthorizationId `
        -ReleaseTag $source.identity.reference -ArchivePath $inboxZip -VerifiedReleasePath $inboxIdentity -Operation $Operation
    [IO.File]::WriteAllText($safePath,($result | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    if ($env:GITHUB_STEP_SUMMARY) { [IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY,'Deployment result: **'+$result.status+'**; target `'+$target.targetId+'`; release `'+$verified.releaseId+'`.'+"`n") }
    return $result
} catch {
    $code=if ($_.FullyQualifiedErrorId -like 'Clc.*') {$_.FullyQualifiedErrorId.Split(',')[0]} else {'Clc.RecoveryRequired'}
    [IO.File]::WriteAllText($safePath,(@{status='Failed';code=$code;targetId=$target.targetId;releaseId=$verified.releaseId;nextAction='InspectProtectedAttemptEvidence'} | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    throw 'Shared deployment failed. Inspect retained protected host evidence before retry or explicit recovery.'
}
} finally { foreach ($handle in $toolkit.handles) { $handle.Dispose() } }

# Synthetic data only. This is not an application, toolkit release or deployment.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if ($env:GITHUB_REPOSITORY -cne 'clcdpc/clc-deployment' -or $env:GITHUB_REF_NAME -cnotmatch '^v9999\.9999\.9999-dev\.[1-9][0-9]{0,3}$') {
    throw 'Only the reserved, nonpublishing receipt qualification tag is supported'
}
. ./tests/Support.ps1
$inputs=New-TestPublish $env:CLC_RELEASE_DIRECTORY
$metadata=Get-TestMetadata
$metadata.releaseId=$env:CLC_RELEASE_ID
$metadata.source.repository=$env:GITHUB_REPOSITORY
$metadata.source.commit=$env:GITHUB_SHA
$metadata.build.workflowPath=$env:CLC_RELEASE_WORKFLOW
$metadata.build.job=$env:CLC_RELEASE_JOB
$metadata.build.runId=[long]$env:GITHUB_RUN_ID
$metadata.build.runAttempt=[long]$env:GITHUB_RUN_ATTEMPT
Write-TestJson $inputs.MetadataPath $metadata
$inputs.OutputPath=Join-Path $env:CLC_RELEASE_DIRECTORY 'release.zip'
$null=New-ClcRelease @inputs

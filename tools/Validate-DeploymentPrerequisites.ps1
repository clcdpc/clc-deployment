#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $EnvironmentName,
    [string] $IntegrationBranch = 'master',
    [string] $ReleaseWorkflow = '.github/workflows/release.yml',
    [string] $DeploymentWorkflow = '.github/workflows/deploy-release.yml',
    [Parameter(Mandatory)][string] $RunnerGroup,
    [string] $RunnerLabels = 'self-hosted,Windows,X64',
    [string] $ActivationVariable = 'CLC_DEPLOYMENT_ENABLED',
    [ValidateSet('DEV','Production')][string] $DeploymentChannel = 'DEV',
    [ValidateSet('runner-workflow','required-reviewers')][string] $EnvironmentProtection = 'runner-workflow',
    [Parameter(Mandatory)][string] $YamlAssemblyPath,
    [switch] $Strict
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'deployment-prerequisites/Validation.psm1') -Force
$config=@{
    Repository=$env:GITHUB_REPOSITORY; EnvironmentName=$EnvironmentName; IntegrationBranch=$IntegrationBranch;
    ReleaseWorkflow=$ReleaseWorkflow; DeploymentWorkflow=$DeploymentWorkflow; RunnerGroup=$RunnerGroup;
    RunnerLabels=$RunnerLabels; ActivationVariable=$ActivationVariable; DeploymentChannel=$DeploymentChannel;
    EnvironmentProtection=$EnvironmentProtection; ActivationState=$(if ($env:CLC_ACTIVATION_STATE) { $env:CLC_ACTIVATION_STATE } else { 'unavailable' }); Strict=[bool]$Strict
}
$report=Invoke-DpValidation -Config $config -YamlAssemblyPath $YamlAssemblyPath
$summary=Format-DpSummary $report
if ($env:GITHUB_STEP_SUMMARY) { [IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY,$summary + "`n",[Text.UTF8Encoding]::new($false)) }
if ($env:GITHUB_OUTPUT) {
    $output="ready=$($report.ready.ToString().ToLowerInvariant())`npassed_count=$($report.passed_count)`nfailed_count=$($report.failed_count)`nunverified_count=$($report.unverified_count)`n"
    [IO.File]::AppendAllText($env:GITHUB_OUTPUT,$output,[Text.UTF8Encoding]::new($false))
}
Write-Host "Deployment prerequisites: ready=$($report.ready); passed=$($report.passed_count); failed=$($report.failed_count); unverified=$($report.unverified_count). See job summary."
exit $report.exit_code

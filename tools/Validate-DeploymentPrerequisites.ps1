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
    [ValidateSet('Standard','Administrative')][string] $AuthenticationMode='Standard',
    [string] $ApplicationId='',
    [string] $TargetId='',
    [string] $DiagnosticWorkflow='',
    [string] $ReportPath='',
    [switch] $Strict
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'deployment-prerequisites/Validation.psm1') -Force
$config=@{
    Repository=$env:GITHUB_REPOSITORY; EnvironmentName=$EnvironmentName; IntegrationBranch=$IntegrationBranch;
    ReleaseWorkflow=$ReleaseWorkflow; DeploymentWorkflow=$DeploymentWorkflow; RunnerGroup=$RunnerGroup;
    RunnerLabels=$RunnerLabels; ActivationVariable=$ActivationVariable; DeploymentChannel=$DeploymentChannel;
    EnvironmentProtection=$EnvironmentProtection; ActivationState=$(if ($env:CLC_ACTIVATION_STATE) { $env:CLC_ACTIVATION_STATE } else { 'unavailable' }); Strict=[bool]$Strict;
    ApplicationId=$ApplicationId;TargetId=$TargetId;DiagnosticWorkflow=$DiagnosticWorkflow
}
$report=Invoke-DpValidation -Config $config -YamlAssemblyPath $YamlAssemblyPath -AuthenticationMode $AuthenticationMode
Publish-DpReport $report
if ($ReportPath) { $report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ReportPath -Encoding utf8NoBOM }
Write-Host "Deployment prerequisites: ready=$($report.ready); passed=$($report.passed_count); failed=$($report.failed_count); unverified=$($report.unverified_count). See job summary."
exit $report.exit_code

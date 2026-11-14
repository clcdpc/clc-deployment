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
    [ValidateSet('DEV','Test','Production')][string] $DeploymentChannel = 'DEV',
    [Parameter(Mandatory)][string] $YamlAssemblyPath,
    [ValidateSet('Standard','Administrative')][string] $AuthenticationMode='Standard',
    [Parameter(Mandatory)][string] $ApplicationId,
    [Parameter(Mandatory)][string] $TargetId,
    [string] $DiagnosticWorkflow='',
    [string] $SharedRevision='',
    [string] $ReportPath=''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'deployment-prerequisites/Validation.psm1') -Force
$config=@{
    Repository=$env:GITHUB_REPOSITORY; EnvironmentName=$EnvironmentName; IntegrationBranch=$IntegrationBranch;
    ReleaseWorkflow=$ReleaseWorkflow; DeploymentWorkflow=$DeploymentWorkflow; RunnerGroup=$RunnerGroup;
    RunnerLabels=$RunnerLabels; ActivationVariable=$ActivationVariable; DeploymentChannel=$DeploymentChannel;
    ActivationState=$(if ($env:CLC_ACTIVATION_STATE) { $env:CLC_ACTIVATION_STATE } else { 'unavailable' });
    ApplicationId=$ApplicationId;TargetId=$TargetId;DiagnosticWorkflow=$DiagnosticWorkflow;SharedRevision=$SharedRevision
}
$report=Invoke-ClcDeploymentPrerequisiteGitHubInspection -Config $config -YamlAssemblyPath $YamlAssemblyPath -AuthenticationMode $AuthenticationMode
Publish-ClcDeploymentPrerequisiteReport $report
if ($ReportPath) { $report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ReportPath -Encoding utf8NoBOM }
# Missing prerequisites are normal diagnostic findings. Only command/report failures throw.
if (@($report.checks | Where-Object reason -CEQ 'inspection-error').Count) {exit 1}
exit 0

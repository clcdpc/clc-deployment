#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9-]{0,63}$')][string] $ApplicationId,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9-]{0,63}$')][string] $TargetId,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_. -]{0,99}$')][string] $EnvironmentName,
    [Parameter(Mandatory)][ValidateSet('DEV','Production')][string] $DeploymentChannel,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+$')][string] $Repository,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_./-]{0,127}$')][string] $IntegrationBranch='master',
    [Parameter(Mandatory)][ValidatePattern('^\.github/workflows/[A-Za-z0-9_-][A-Za-z0-9_.-]*\.ya?ml$')][string] $ReleaseWorkflow,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*$')][string] $BuildJob,
    [ValidatePattern('^$|^[a-z0-9][a-z0-9-]{0,63}$')][string] $StandingAuthorizationId='',
    # Independently reviewed workflow/operator literal, never an untrusted dispatch input.
    [Parameter(Mandatory)][string] $ToolkitManifestPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module "$PSScriptRoot/Validation.psm1" -Force
$config=@{ApplicationId=$ApplicationId;TargetId=$TargetId;EnvironmentName=$EnvironmentName;DeploymentChannel=$DeploymentChannel;
    Repository=$Repository;IntegrationBranch=$IntegrationBranch;ReleaseWorkflow=$ReleaseWorkflow;BuildJob=$BuildJob;StandingAuthorizationId=$StandingAuthorizationId}
$rows=[Collections.Generic.List[object]]::new()
try {
    if (-not $IsWindows) {Stop-ClcDeploymentPrerequisiteObservation FAIL 'Actual host inspection requires the enrolled Windows host.'}
    if (-not [IO.Path]::IsPathFullyQualified($ToolkitManifestPath) -or [IO.Path]::GetFileName($ToolkitManifestPath) -cne 'CLC.Deployment.psd1') {Stop-ClcDeploymentPrerequisiteObservation FAIL 'The installed manifest selector must be the exact independently approved absolute toolkit path.'}
    try {$null=Get-Item -LiteralPath $ToolkitManifestPath -ErrorAction Stop} catch [Management.Automation.ItemNotFoundException] {Stop-ClcDeploymentPrerequisiteObservation FAIL 'The expected installed toolkit manifest is missing.'}
    . (Join-Path $PSScriptRoot 'Import-TrustedToolkit.ps1')
    $null=Import-ClcDeploymentPrerequisiteTrustedToolkit $ToolkitManifestPath {
        param($Module)
        $observations=& $Module {
            param($Implementation,$Configuration)
            . $Implementation
            Invoke-ClcDeploymentPrerequisiteHostInspection $Configuration
        } (Join-Path $PSScriptRoot 'Host.ps1') $config
        foreach ($observation in $observations) {$rows.Add($observation)}
    }
    $rows.Add((New-ClcDeploymentPrerequisiteCheck 'host.toolkit.stability' PASS 'Independent authenticated files and physical identities remained held and stable through installed import and inspection.'))
} catch {
    $status='UNVERIFIED';$detail='Independent installed toolkit authentication or final stability observation could not be established; private error details were suppressed.'
    if ($_.Exception.Data.Contains('prerequisite_status')) {$status=$_.Exception.Data['prerequisite_status'];$detail=$_.Exception.Data['prerequisite_detail']}
    $id=if ($rows.Count) {'host.toolkit.stability'} else {'host.toolkit.authentication'}
    $rows.Add((New-ClcDeploymentPrerequisiteCheck $id $status $detail 'Authenticate and verify the exact protected toolkit policy, source/distribution/inventory, local access and deployment identity; rerun.'))
    if ($id -ceq 'host.toolkit.authentication') {
        $rows.Add((New-ClcDeploymentPrerequisiteCheck 'host.stage' SKIPPED 'Toolkit authentication failed before candidate import; dependent machine/identity/enrollment/IIS/state inspection did not execute.' 'Correct independent authentication before inspecting this host.' -Reason 'host.toolkit.authentication'))
    }
}
# Structured output only; this command does not write host files or GitHub command files.
$report=New-ClcDeploymentPrerequisiteReport $config $rows.ToArray()
Write-Output $report
if (@($report.checks | Where-Object reason -CEQ 'inspection-error').Count) {exit 1}
exit 0

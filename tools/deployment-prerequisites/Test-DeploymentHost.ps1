#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9-]{0,63}$')][string] $ApplicationId,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9-]{0,63}$')][string] $TargetId,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_. -]{0,99}$')][string] $EnvironmentName,
    [Parameter(Mandatory)][ValidateSet('DEV','Production')][string] $DeploymentChannel,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+$')][string] $Repository,
    [Parameter(Mandatory)][ValidatePattern('^\.github/workflows/[A-Za-z0-9_-][A-Za-z0-9_.-]*\.ya?ml$')][string] $ReleaseWorkflow,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*$')][string] $BuildJob,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9-]{0,63}$')][string] $StandingAuthorizationId,
    # Trusted operator/workflow literal; never expose this as an arbitrary dispatch input.
    [Parameter(Mandatory)][string] $ToolkitManifestPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module "$PSScriptRoot/Validation.psm1" -Force
$config=@{ApplicationId=$ApplicationId;TargetId=$TargetId;EnvironmentName=$EnvironmentName;DeploymentChannel=$DeploymentChannel;
    Repository=$Repository;ReleaseWorkflow=$ReleaseWorkflow;BuildJob=$BuildJob;StandingAuthorizationId=$StandingAuthorizationId;Strict=$false}
$rows=[Collections.Generic.List[object]]::new()
try {
    if (-not $IsWindows) { throw 'Host inspection requires Windows.' }
    if (-not [IO.Path]::IsPathFullyQualified($ToolkitManifestPath) -or [IO.Path]::GetFileName($ToolkitManifestPath) -cne 'CLC.Deployment.psd1') { throw 'Invalid trusted installed manifest selector.' }
    $null=Get-Item -LiteralPath $ToolkitManifestPath -ErrorAction Stop
    . (Join-Path $PSScriptRoot 'Import-TrustedToolkit.ps1')
    $null=Import-DhTrustedToolkit $ToolkitManifestPath {
        param($Module)
        $observations=& $Module {
            param($Implementation,$Configuration)
            . $Implementation
            Invoke-DhQualification $Configuration
        } (Join-Path $PSScriptRoot 'Host.ps1') $config
        # Preserve observed failures/actions even if the outer held toolkit
        # context's final stability check subsequently becomes unavailable.
        foreach ($observation in $observations) { $rows.Add($observation) }
    }
} catch {
    $status=if ($_.CategoryInfo.Category -eq [Management.Automation.ErrorCategory]::ObjectNotFound -or $_.Exception.Message -ceq 'Dp.BootstrapMismatch') {'FAIL'} else {'UNVERIFIED'}
    $check=if ($rows.Count) {'Independent toolkit stability'} else {'Compatible toolkit installation'}
    Add-DpResult $rows 'Host qualification' $check $status 'Actual host inspection or final independent toolkit stability could not be established; private exception details were suppressed.' 'Infrastructure: authenticate and verify the installed toolkit and diagnostic source, local host access and execution identity, then rerun.'
}
# Return only sanitized observations. The caller may publish this report as an artifact.
# This script itself writes no host files or GitHub command files.
Complete-DpReport $config $rows

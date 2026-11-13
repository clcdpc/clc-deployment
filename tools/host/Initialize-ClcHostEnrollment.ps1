[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $DeploymentConfigurationPath,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9-]{0,63}$')][string] $AuthorizationId,
    [ValidateSet('Plan','Apply')][string] $Operation='Plan',
    [string] $DistributionPath
)
. "$PSScriptRoot/HostEnrollment.Common.ps1"
Invoke-HEnrollment -DeploymentConfigurationPath $DeploymentConfigurationPath -AuthorizationId $AuthorizationId -Operation $Operation -DistributionPath $DistributionPath

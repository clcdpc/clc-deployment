[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $DeploymentConfigurationPath,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9-]{0,63}$')][string] $AuthorizationId
)
. "$PSScriptRoot/HostEnrollment.Common.ps1"
Invoke-HEnrollment -DeploymentConfigurationPath $DeploymentConfigurationPath -AuthorizationId $AuthorizationId -Operation Inspect

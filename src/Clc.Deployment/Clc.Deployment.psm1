Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/Private/Contracts.ps1"
. "$PSScriptRoot/Private/Paths.ps1"
. "$PSScriptRoot/Private/Inventory.ps1"
. "$PSScriptRoot/Private/Archive.ps1"
. "$PSScriptRoot/Private/ToolkitIdentity.ps1"
. "$PSScriptRoot/Private/NativeProcess.ps1"
. "$PSScriptRoot/Private/ReleaseTag.ps1"
. "$PSScriptRoot/Private/Access.ps1"
. "$PSScriptRoot/Private/Iis.ps1"
. "$PSScriptRoot/Private/Host.ps1"
. "$PSScriptRoot/Private/State.ps1"
. "$PSScriptRoot/Private/Files.ps1"
. "$PSScriptRoot/Private/Application.ps1"
. "$PSScriptRoot/Private/Deployment.ps1"
. "$PSScriptRoot/Public/Initialize-ClcDeploymentHost.ps1"
. "$PSScriptRoot/Public/Test-ClcDeploymentHost.ps1"
. "$PSScriptRoot/Public/New-ClcRelease.ps1"
. "$PSScriptRoot/Public/Test-ClcRelease.ps1"
. "$PSScriptRoot/Public/Invoke-ClcIisDeployment.ps1"
. "$PSScriptRoot/Public/Restore-ClcIisDeployment.ps1"

Export-ModuleMember -Function Initialize-ClcDeploymentHost, Test-ClcDeploymentHost, New-ClcRelease, Test-ClcRelease, Invoke-ClcIisDeployment, Restore-ClcIisDeployment

#requires -Version 7.4
[CmdletBinding()]
param([string] $GitHubReportPath='', [string] $HostReportPath='',
    [ValidateSet('success','failure','cancelled','skipped')][string] $GitHubJobResult='skipped',
    [ValidateSet('success','failure','cancelled','skipped')][string] $HostJobResult='skipped')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module "$PSScriptRoot/Validation.psm1" -Force
function Read-ClcDeploymentPrerequisiteReport {
    param([string] $Path)
    if (-not $Path) {return $null}
    try {
        # Hold and bound the bytes; reject duplicate keys rather than collapsing them.
        & (Get-Module Validation) {param($File) Read-DistJson (Read-DistFileBytes $File 1048576)} $Path
    } catch {return $null}
}
$report=Merge-ClcDeploymentPrerequisiteReports -GitHubReport (Read-ClcDeploymentPrerequisiteReport $GitHubReportPath) -HostReport (Read-ClcDeploymentPrerequisiteReport $HostReportPath) -GitHubJobResult $GitHubJobResult -HostJobResult $HostJobResult
Publish-ClcDeploymentPrerequisiteReport $report
if ($report.ready) {exit 0}
exit 1

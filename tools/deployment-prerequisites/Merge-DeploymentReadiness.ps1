#requires -Version 7.4
[CmdletBinding()]
param([string] $GitHubReportPath='', [string] $HostReportPath='',
    [ValidateSet('success','failure','cancelled','skipped')][string] $GitHubJobResult='skipped',
    [ValidateSet('success','failure','cancelled','skipped')][string] $HostJobResult='skipped', [switch] $Strict)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module "$PSScriptRoot/Validation.psm1" -Force
function Read-DiagnosticReport([string] $Path) {
    if (-not $Path) { return $null }
    try {
        if ((Get-Item -LiteralPath $Path).Length -gt 1048576) { return $null }
        Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -Depth 16
    } catch { return $null }
}
$report=Merge-DpReports -GitHubReport (Read-DiagnosticReport $GitHubReportPath) -HostReport (Read-DiagnosticReport $HostReportPath) -GitHubJobResult $GitHubJobResult -HostJobResult $HostJobResult -Strict:$Strict
Publish-DpReport $report
exit $report.exit_code

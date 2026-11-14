function Get-DpCategoryStatus {
    param([object[]] $Rows)
    if (@($Rows | Where-Object status -CEQ FAIL).Count) { return 'FAIL' }
    if ($Rows.Count -eq 0 -or @($Rows | Where-Object status -CEQ UNVERIFIED).Count) { return 'UNVERIFIED' }
    return 'PASS'
}

function ConvertTo-DpStageReport {
    param($Report)
    try {
        if ($null -eq $Report) { return $null }
        $json=ConvertTo-Json -InputObject $Report -Depth 16 -Compress
        if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 1048576) { return $null }
        $value=ConvertFrom-Json -InputObject $json -AsHashtable -Depth 16
        foreach ($key in @('contract_version','repository','environment','channel','application','target','observed_commit','results')) { if (-not $value.Contains($key)) { return $null } }
        if (($value.contract_version -isnot [int] -and $value.contract_version -isnot [long]) -or $value.contract_version -ne 2 -or $value.results -isnot [array] -or $value.results.Count -gt 500) { return $null }
        foreach ($key in @('repository','environment','channel','application','target','observed_commit')) { if ($value[$key] -isnot [string] -or $value[$key].Length -gt 256) { return $null } }
        if ($value.repository -cnotmatch '^[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+$' -or $value.environment -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_. -]{0,99}$' -or $value.channel -cnotin @('DEV','Production')) { return $null }
        foreach ($key in @('application','target')) { if ($value[$key] -and $value[$key] -cnotmatch '^[a-z0-9][a-z0-9-]{0,63}$') { return $null } }
        if ($value.observed_commit -and $value.observed_commit -cnotmatch '^[0-9a-f]{40}$') { return $null }
        foreach ($row in $value.results) {
            if ($row -isnot [Collections.IDictionary]) { return $null }
            foreach ($key in @('category','section','name','status','detail','action')) { if (-not $row.Contains($key) -or $row[$key] -isnot [string] -or $row[$key].Length -gt 4096) { return $null } }
            if ($row.category -cnotin @('github','host') -or $row.status -cnotin @('PASS','FAIL','UNVERIFIED') -or ($row.status -cne 'PASS' -and (-not $row.detail -or -not $row.action))) { return $null }
        }
        return $value
    } catch { return $null }
}

function Merge-DpReports {
    [CmdletBinding()]
    param($GitHubReport, $HostReport, [string] $GitHubJobResult = 'success', [string] $HostJobResult = 'skipped', [switch] $Strict)
    $GitHubReport=ConvertTo-DpStageReport $GitHubReport
    $HostReport=ConvertTo-DpStageReport $HostReport
    $rows=[Collections.Generic.List[object]]::new()
    foreach ($stage in @(
        @{report=$GitHubReport; job=$GitHubJobResult; category='github'},
        @{report=$HostReport; job=$HostJobResult; category='host'}
    )) {
        $valid=$null -ne $stage.report
        if ($valid) {
            foreach ($row in @($stage.report.results)) {
                if ($row.category -ceq $stage.category) { $rows.Add([pscustomobject]$row) }
                elseif ($stage.category -ceq 'github' -and $row.category -ceq 'host') {
                    # Preserve each hosted prerequisite/action unless the host
                    # stage actually returned its corresponding observation.
                    $replacement=@(if ($null -ne $HostReport) { $HostReport.results | Where-Object { $_.category -ceq 'host' -and $_.name -ceq $row.name } })
                    if ($replacement.Count -eq 0) { $rows.Add([pscustomobject]$row) }
                }
            }
        }
        if (-not $valid -or $stage.job -cne 'success' -or @($rows | Where-Object category -CEQ $stage.category).Count -eq 0) {
            Add-DpResult $rows $(if ($stage.category -ceq 'host') {'Host qualification'} else {'Repository configuration'}) `
                'Validation stage evidence' UNVERIFIED 'This stage was missing, skipped, unsuccessful or supplied no supported report.' `
                'Run the independently trusted diagnostic stage successfully for this exact application, environment and target.' -Category $stage.category
        }
    }
    $config=@{Repository='unavailable';EnvironmentName='unavailable';DeploymentChannel='DEV';Strict=[bool]$Strict}
    $commit=''
    if ($null -ne $GitHubReport) {
        $config.Repository=$GitHubReport.repository; $config.EnvironmentName=$GitHubReport.environment
        $config.DeploymentChannel=$GitHubReport.channel; $commit=$GitHubReport.observed_commit
        $config.ApplicationId=$GitHubReport.application; $config.TargetId=$GitHubReport.target
    } elseif ($null -ne $HostReport) {
        $config.Repository=$HostReport.repository; $config.EnvironmentName=$HostReport.environment; $config.DeploymentChannel=$HostReport.channel
        $config.ApplicationId=$HostReport.application; $config.TargetId=$HostReport.target
    }
    if ($null -ne $GitHubReport -and $null -ne $HostReport -and
        ($GitHubReport.repository -cne $HostReport.repository -or $GitHubReport.environment -cne $HostReport.environment -or
         $GitHubReport.channel -cne $HostReport.channel -or $GitHubReport.application -cne $HostReport.application -or $GitHubReport.target -cne $HostReport.target)) {
        Add-DpResult $rows 'Host qualification' 'Report target binding' FAIL 'The two stages describe different repository/application/environment/channel/target selections.' 'Rerun both stages with the same reviewed selection.'
    }
    Complete-DpReport $config $rows $commit
}

function Publish-DpReport {
    param($Report)
    $summary=Format-DpSummary $Report
    if ($env:GITHUB_STEP_SUMMARY) { [IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY,$summary+"`n",[Text.UTF8Encoding]::new($false)) }
    if ($env:GITHUB_OUTPUT) {
        $lines=foreach ($key in @('github_status','host_status','overall_ready','ready','passed_count','failed_count','unverified_count')) {
            "$key=$($Report.$key.ToString().ToLowerInvariant())"
        }
        # Status values are deliberately uppercase, readiness/counts retain existing string outputs.
        $lines[0]="github_status=$($Report.github_status)"; $lines[1]="host_status=$($Report.host_status)"
        [IO.File]::AppendAllText($env:GITHUB_OUTPUT,($lines -join "`n")+"`n",[Text.UTF8Encoding]::new($false))
    }
    Write-Host "GitHub configuration: $($Report.github_status); Host qualification: $($Report.host_status); Overall deployment readiness: $(if ($Report.ready) {'READY'} else {'NOT READY'})."
}

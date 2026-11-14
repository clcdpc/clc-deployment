# Expected validation failures carry an explicit classification and safe, authored detail.
function Stop-ClcDeploymentPrerequisiteObservation {
    param([ValidateSet('FAIL','UNVERIFIED')][string] $Status,[string] $Detail)
    $error=[InvalidOperationException]::new('Prerequisite observation did not satisfy the check.')
    $error.Data['prerequisite_status']=$Status;$error.Data['prerequisite_detail']=$Detail
    throw $error
}

# Source-owned checklist; serialized reports cannot alter these classifications.
function Get-ClcDeploymentPrerequisiteDefinitions {
    @{
        'github.repository.identity'=$true; 'github.branch.protection'=$true
        'github.branch.force-push'=$true; 'github.branch.deletion'=$true; 'github.branch.required-checks'=$true
        'github.branch.bypass'=$true; 'github.branch.reviews'=$false
        'github.tags.creation'=$true; 'github.tags.update'=$true; 'github.tags.deletion'=$true
        'github.tags.bypass'=$true; 'github.tags.authority'=$false
        'github.workflow.producer'=$true; 'github.workflow.caller'=$true
        'github.workflow.release-trigger'=$true; 'github.workflow.completion-trigger'=$true
        'github.workflow.manual-dispatch'=$false; 'github.workflow.runtime-semantics'=$false
        'github.workflow.shared-identity'=$true; 'github.workflow.shared-definition'=$true
        'github.workflow.additional-jobs'=$true
        'github.workflow.manual-selection'=$true
        'github.environment.exists'=$true; 'github.environment.restrictions'=$true
        'github.environment.protection'=$false
        'github.runner.visibility'=$true; 'github.runner.group'=$true; 'github.runner.repository-access'=$true
        'github.runner.workflow-access'=$true; 'github.runner.labels'=$true
        'github.runner.enterprise'=$false; 'github.runner.public-risk'=$false
        'github.routing.target'=$true; 'github.routing.activation'=$false
        'github.routing.channel'=$true
        'github.inspection'=$true
        'host.toolkit.authentication'=$true; 'host.toolkit.stability'=$true
        'host.identity.permissions'=$true; 'host.machine.binding'=$true
        'host.target.enrollment'=$true; 'host.iis.presence'=$true; 'host.iis.configuration'=$true
        'host.filesystem.permissions'=$true; 'host.identity.runtime'=$true
        'host.runtime.compatibility'=$true; 'host.iis.environment'=$true
        'host.standing.policy'=$false; 'host.standing.scope'=$false; 'host.standing.lineage'=$false
        'host.state.pending-admission'=$true; 'host.state.lock'=$true; 'host.state.consistency'=$true
        'host.state.current-release'=$true; 'host.state.inventory'=$true; 'host.state.stability'=$true
        'host.application.acceptance'=$false
        'github.stage'=$true; 'host.stage'=$true; 'host.report.subject'=$true
    }
}

function New-ClcDeploymentPrerequisiteCheck {
    param([Parameter(Mandatory)][string] $Id,
        [Parameter(Mandatory)][ValidateSet('PASS','FAIL','UNVERIFIED','SKIPPED','NOT_APPLICABLE')][string] $Status,
        [Parameter(Mandatory)][string] $Detail, [string] $Action='', [string] $Reason='', [string] $Name='')
    $definitions=Get-ClcDeploymentPrerequisiteDefinitions
    if (-not $definitions.ContainsKey($Id)) { throw 'Unknown prerequisite check identity.' }
    if ($Status -cin @('PASS','NOT_APPLICABLE')) { $Action='' }
    if (-not $Name) { $Name=($Id.Split('.') | Select-Object -Skip 1) -join ' '; $Name=$Name.Replace('-',' ');$Name=$Name.Substring(0,1).ToUpperInvariant()+$Name.Substring(1) }
    [pscustomobject][ordered]@{id=$Id;category=$Id.Split('.')[0];name=$Name;status=$Status;
        required=[bool]$definitions[$Id];detail=$Detail;action=$Action;reason=$Reason}
}

function Get-ClcDeploymentPrerequisiteCategoryStatus {
    param([object[]] $Checks, [ValidateSet('github','host')][string] $Category)
    $rows=@($Checks | Where-Object category -CEQ $Category)
    $required=@($rows | Where-Object required)
    if (@($required | Where-Object status -CEQ FAIL).Count) { return 'FAIL' }
    if (-not $required.Count -or @($required | Where-Object { $_.status -cin @('UNVERIFIED','SKIPPED') }).Count) { return 'UNVERIFIED' }
    $core=if ($Category -ceq 'github') {
        @('repository.identity','branch.protection','branch.force-push','branch.deletion','branch.required-checks','branch.bypass',
          'tags.creation','tags.update','tags.deletion','tags.bypass','workflow.producer','workflow.caller',
          'workflow.release-trigger','workflow.completion-trigger','workflow.shared-identity','workflow.shared-definition',
          'workflow.additional-jobs','workflow.manual-selection','environment.exists','environment.restrictions',
          'runner.visibility','runner.group','runner.repository-access','runner.workflow-access','runner.labels','routing.target','routing.channel')
    } else {
        @('toolkit.authentication','toolkit.stability','identity.permissions','machine.binding','target.enrollment',
          'iis.presence','iis.configuration','filesystem.permissions','identity.runtime','runtime.compatibility','iis.environment',
          'state.pending-admission','state.lock','state.consistency','state.current-release','state.inventory','state.stability')
    }
    if (@($core | Where-Object { $rows.id -cnotcontains "$Category.$_" }).Count) { return 'UNVERIFIED' }
    'PASS'
}

function New-ClcDeploymentPrerequisiteReport {
    param($Config, [object[]] $Checks, [string] $Commit='')
    $ordered=@($Checks | Sort-Object id -CaseSensitive)
    if (@($ordered.id | Select-Object -Unique).Count -ne $ordered.Count) { throw 'Duplicate prerequisite check identity.' }
    $counts=[ordered]@{}
    foreach ($pair in @(@('passed','PASS'),@('failed','FAIL'),@('unverified','UNVERIFIED'),@('skipped','SKIPPED'),@('not_applicable','NOT_APPLICABLE'))) {
        $counts[$pair[0]]=@($ordered | Where-Object status -CEQ $pair[1]).Count
    }
    $github=Get-ClcDeploymentPrerequisiteCategoryStatus $ordered github
    $hostStatus=Get-ClcDeploymentPrerequisiteCategoryStatus $ordered host
    [pscustomobject][ordered]@{
        contract_version=3
        subject=[ordered]@{repository=$Config.Repository;integration_branch=$Config.IntegrationBranch;
            application=$Config.ApplicationId;target=$Config.TargetId;environment=$Config.EnvironmentName;
            channel=$Config.DeploymentChannel;observed_commit=$Commit}
        checked_at_utc=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        github_status=$github;host_status=$hostStatus;ready=($github -ceq 'PASS' -and $hostStatus -ceq 'PASS')
        counts=$counts;checks=$ordered
    }
}

function ConvertTo-ClcDeploymentPrerequisiteStageReport {
    param($Report)
    try {
        if ($null -eq $Report) { return $null }
        $json=ConvertTo-Json -InputObject $Report -Depth 16 -Compress
        if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 1048576) { return $null }
        $value=Read-DistJson ([Text.Encoding]::UTF8.GetBytes($json))
        Assert-DistFields $value @('contract_version','subject','checked_at_utc','github_status','host_status','ready','counts','checks')
        if (($value.contract_version -isnot [int] -and $value.contract_version -isnot [long]) -or $value.contract_version -ne 3 -or
            $value.ready -isnot [bool] -or $value.checks -isnot [array] -or $value.checks.Count -gt 500) { return $null }
        $s=$value.subject
        Assert-DistFields $s @('repository','integration_branch','application','target','environment','channel','observed_commit')
        foreach ($key in $s.Keys) { if ($s[$key] -isnot [string] -or $s[$key].Length -gt 256) { return $null } }
        if ($s.repository -cnotmatch '^[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+$' -or $s.integration_branch -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_./-]{0,127}$' -or
            $s.environment -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_. -]{0,99}$' -or $s.channel -cnotin @('DEV','Test','Production')) { return $null }
        foreach ($key in @('application','target')) { if ($s[$key] -cnotmatch '^[a-z0-9][a-z0-9-]{0,63}$') { return $null } }
        if ($s.observed_commit -and $s.observed_commit -cnotmatch '^[a-f0-9]{40}$') { return $null }
        if ($value.checked_at_utc -isnot [string] -or $value.checked_at_utc -cnotmatch '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$') { return $null }
        $date=[datetime]::MinValue
        if (-not [datetime]::TryParse($value.checked_at_utc,[ref]$date)) { return $null }
        $definitions=Get-ClcDeploymentPrerequisiteDefinitions
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($row in $value.checks) {
            Assert-DistFields $row @('id','category','name','status','required','detail','action','reason')
            foreach ($key in @('id','category','name','status','detail','action','reason')) {
                if ($row[$key] -isnot [string] -or $row[$key].Length -gt 4096 -or $row[$key] -match '[\x00-\x08\x0b\x0c\x0e-\x1f]') { return $null }
            }
            if (-not $definitions.ContainsKey($row.id) -or -not $seen.Add($row.id) -or $row.category -cne $row.id.Split('.')[0] -or
                $row.required -isnot [bool] -or $row.required -ne $definitions[$row.id] -or
                $row.status -cnotin @('PASS','FAIL','UNVERIFIED','SKIPPED','NOT_APPLICABLE') -or -not $row.detail -or -not $row.name) { return $null }
            if ($row.status -cin @('SKIPPED','NOT_APPLICABLE') -and -not $row.reason) { return $null }
            if ($row.status -cin @('FAIL','UNVERIFIED','SKIPPED') -and -not $row.action) { return $null }
            if ($row.status -ceq 'NOT_APPLICABLE') {
                $allowed=@{
                    'host.state.current-release'='empty-target';'host.state.inventory'='empty-target'
                    'host.standing.policy'='not-selected';'host.standing.scope'='not-selected';'host.standing.lineage'='no-baseline-or-policy'
                    'github.workflow.shared-identity'='direct-workflow';'github.workflow.shared-definition'='direct-workflow'
                    'github.workflow.manual-selection'='no-dispatch'
                }
                if (-not $allowed.ContainsKey($row.id) -or $allowed[$row.id] -cne $row.reason) { return $null }
            }
        }
        $config=@{Repository=$s.repository;IntegrationBranch=$s.integration_branch;ApplicationId=$s.application;TargetId=$s.target;
            EnvironmentName=$s.environment;DeploymentChannel=$s.channel}
        $expected=New-ClcDeploymentPrerequisiteReport $config $value.checks $s.observed_commit
        if ($value.github_status -cne $expected.github_status -or $value.host_status -cne $expected.host_status -or $value.ready -ne $expected.ready) { return $null }
        Assert-DistFields $value.counts @('passed','failed','unverified','skipped','not_applicable')
        foreach ($key in $expected.counts.Keys) {
            if (($value.counts[$key] -isnot [int] -and $value.counts[$key] -isnot [long]) -or $value.counts[$key] -ne $expected.counts[$key]) { return $null }
        }
        $value
    } catch { return $null }
}

function Merge-ClcDeploymentPrerequisiteReports {
    [CmdletBinding()]
    param($GitHubReport, $HostReport, [string] $GitHubJobResult='success', [string] $HostJobResult='skipped')
    $g=ConvertTo-ClcDeploymentPrerequisiteStageReport $GitHubReport
    $h=ConvertTo-ClcDeploymentPrerequisiteStageReport $HostReport
    $rows=[Collections.Generic.List[object]]::new()
    foreach ($stage in @(@{report=$g;job=$GitHubJobResult;category='github'},@{report=$h;job=$HostJobResult;category='host'})) {
        $valid=$null -ne $stage.report
        if ($valid -and @($stage.report.checks | Where-Object category -CNE $stage.category).Count) { $valid=$false }
        if ($valid) { foreach ($row in $stage.report.checks) { $rows.Add([pscustomobject]$row) } }
        if (-not $valid -or $stage.job -cne 'success') {
            $status=if ($stage.job -ceq 'skipped' -or ($null -eq $stage.report -and $stage.job -ceq 'success')) {'SKIPPED'} else {'UNVERIFIED'}
            $rows.Add((New-ClcDeploymentPrerequisiteCheck "$($stage.category).stage" $status 'Inspection did not complete with a valid report for this category.' 'Run this inspection for the selected target; retain and correct available findings.' -Reason 'stage-incomplete' -Name "$($stage.category) inspection"))
        }
    }
    $subject=if ($null -ne $g) {$g.subject} elseif ($null -ne $h) {$h.subject} else {
        @{repository='unavailable/unavailable';integration_branch='unavailable';application='unavailable';target='unavailable';environment='unavailable';channel='DEV';observed_commit=''}
    }
    if ($null -ne $g -and $null -ne $h) {
        $mismatch=@('repository','integration_branch','application','target','environment','channel') | Where-Object { $g.subject[$_] -cne $h.subject[$_] }
        if ($mismatch -or ($g.subject.observed_commit -and $h.subject.observed_commit -and $g.subject.observed_commit -cne $h.subject.observed_commit)) {
            $rows.Add((New-ClcDeploymentPrerequisiteCheck 'host.report.subject' FAIL 'Reports describe different subjects or observed integration commits.' 'Rerun both stages for the same protected selection.' -Name 'Report subject binding'))
        }
    }
    $config=@{Repository=$subject.repository;IntegrationBranch=$subject.integration_branch;ApplicationId=$subject.application;TargetId=$subject.target;EnvironmentName=$subject.environment;DeploymentChannel=$subject.channel}
    New-ClcDeploymentPrerequisiteReport $config $rows.ToArray() $subject.observed_commit
}

function Format-ClcDeploymentPrerequisiteSummary {
    param($Report)
    $s=$Report.subject
    $lines=[Collections.Generic.List[string]]::new()
    $lines.Add("# $(if ($Report.ready) {'READY'} else {'NOT READY'})");$lines.Add('')
    $lines.Add("Repository: **$($s.repository)** · Application: **$($s.application)** · Environment: **$($s.environment)** · Target: **$($s.target)** · Channel: **$($s.channel)**")
    $lines.Add('');$lines.Add("GitHub prerequisites: **$($Report.github_status)** · Host prerequisites: **$($Report.host_status)**")
    foreach ($category in @('github','host')) {
        if (-not @($Report.checks | Where-Object category -CEQ $category).Count) {
            $lines.Add('');$lines.Add("$category inspection: **SKIPPED** — this report contains no observations from that inspector.")
        }
    }
    $lines.Add('');$lines.Add("Passed: $($Report.counts.passed) · Failed: $($Report.counts.failed) · Unverified: $($Report.counts.unverified) · Skipped: $($Report.counts.skipped) · Not applicable: $($Report.counts.not_applicable)")
    foreach ($group in @('Blocking problems','Nonblocking warnings','Successful and inapplicable checks')) {
        $rows=@($Report.checks | Where-Object {
            if ($group -ceq 'Blocking problems') {$_.required -and $_.status -cin @('FAIL','UNVERIFIED','SKIPPED')}
            elseif ($group -ceq 'Nonblocking warnings') {-not $_.required -and $_.status -cnotin @('PASS','NOT_APPLICABLE')}
            else {$_.status -cin @('PASS','NOT_APPLICABLE')}
        })
        if (-not $rows.Count) { continue }
        $lines.Add('');$lines.Add("## $group");$lines.Add('')
        if ($group -ceq 'Successful and inapplicable checks') { $lines.Add('<details><summary>Show checks</summary>');$lines.Add('') }
        foreach ($row in $rows) {
            $description=($row.name+': '+$row.detail+' '+$row.action).Trim().Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('|','&#124;').Replace("`r",' ').Replace("`n",' ')
            $lines.Add("- **$($row.status)** — $description")
        }
        if ($group -ceq 'Successful and inapplicable checks') { $lines.Add('');$lines.Add('</details>') }
    }
    $lines.Add('');$lines.Add('Read-only commissioning inspection. Findings do not authorize deployment. Proceed through separately authorized initial deployment and application deployment/recovery acceptance. Rerun after relevant infrastructure changes or for troubleshooting; routine deployment does not require this report.')
    $lines -join "`n"
}

function Publish-ClcDeploymentPrerequisiteReport {
    param($Report)
    if ($env:GITHUB_STEP_SUMMARY) { [IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY,(Format-ClcDeploymentPrerequisiteSummary $Report)+"`n",[Text.UTF8Encoding]::new($false)) }
    if ($env:GITHUB_OUTPUT) {
        $lines=@("github_status=$($Report.github_status)","host_status=$($Report.host_status)","ready=$($Report.ready.ToString().ToLowerInvariant())")
        foreach ($key in $Report.counts.Keys) {$lines+="$($key)_count=$($Report.counts[$key])"}
        [IO.File]::AppendAllText($env:GITHUB_OUTPUT,($lines -join "`n")+"`n",[Text.UTF8Encoding]::new($false))
    }
    Write-Host "$(if ($Report.ready) {'READY'} else {'NOT READY'}): GitHub $($Report.github_status); host $($Report.host_status)."
}

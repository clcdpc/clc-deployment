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
        'github.branch.bypass'=$true; 'github.branch.bypass-visibility'=$false; 'github.branch.reviews'=$false
        'github.tags.creation'=$true; 'github.tags.update'=$true; 'github.tags.deletion'=$true
        'github.tags.bypass'=$true; 'github.tags.bypass-visibility'=$false; 'github.tags.authority'=$false
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
            $s.environment -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_. -]{0,99}$' -or $s.channel -cnotin @('DEV','Production')) { return $null }
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

# Presentation only: label, confirmed-failure guidance, missing-evidence guidance.
# Empty guidance deliberately falls back to the original evidence in technical details.
function Get-ClcDeploymentPrerequisitePresentation {
    @{
        'github.repository.identity'=@('Repository identity','Verify the configured repository identity and API access.','Verify repository identity with authorized API access.')
        'github.branch.protection'=@('Branch protection','Protect the configured integration branch.','Verify integration-branch identity and protection with read-only API access.')
        'github.branch.force-push'=@('Branch force pushes','Enforce integration-branch force-push restrictions.','Verify effective branch force-push restrictions.')
        'github.branch.deletion'=@('Branch deletion','Enforce integration-branch deletion restrictions.','Verify effective branch deletion restrictions.')
        'github.branch.required-checks'=@('Branch status checks','Require CI status checks on the integration branch.','Verify effective required branch status checks.')
        'github.branch.bypass'=@('Branch bypass restrictions','Restrict broad bypass of required branch controls.','Verify observable branch bypass restrictions and independent enforcement.')
        'github.branch.bypass-visibility'=@('Branch bypass visibility','','Review available bypass evidence; retain independent infrastructure control.')
        'github.branch.reviews'=@('Optional branch reviews','','')
        'github.tags.creation'=@('Release tag creation','Enforce release-tag creation restrictions for the selected channel.','Verify effective release-tag creation restrictions for the selected channel.')
        'github.tags.update'=@('Release tag updates','Enforce release-tag update restrictions for the selected channel.','Verify effective release-tag update restrictions for the selected channel.')
        'github.tags.deletion'=@('Release tag deletion','Enforce release-tag deletion restrictions for the selected channel.','Verify effective release-tag deletion restrictions for the selected channel.')
        'github.tags.bypass'=@('Tag bypass restrictions','Restrict broad bypass of release-tag controls.','Verify observable release-tag bypass restrictions and independent enforcement.')
        'github.tags.bypass-visibility'=@('Tag bypass visibility','','Review available release bypass evidence; retain independent infrastructure control.')
        'github.tags.authority'=@('Release authority','','Retain independent control of release producers and authorized bypass identities.')
        'github.workflow.producer'=@('Release workflow','Correct the expected release workflow source or structure.','Inspect the expected release workflow at the observed integration commit.')
        'github.workflow.caller'=@('Deployment workflow','Correct the expected deployment workflow source or structure.','Inspect the expected deployment workflow at the observed integration commit.')
        'github.workflow.release-trigger'=@('Release trigger','Configure the required version-tag push trigger.','Verify the release workflow version-tag trigger.')
        'github.workflow.completion-trigger'=@('Producer handoff','Correct the release-to-deployment completion trigger.','Inspect the protected release-to-deployment handoff.')
        'github.workflow.manual-dispatch'=@('Manual dispatch authority','','Review independent manual-operation authorization in the pinned shared implementation.')
        'github.workflow.runtime-semantics'=@('Workflow runtime behavior','','Review the pinned shared revision; perform separately authorized consumer acceptance.')
        'github.workflow.shared-identity'=@('Shared workflow identity','Reconcile exact caller, protected configuration and immutable shared revision.','Verify the caller and protected configuration select the reviewed shared identity.')
        'github.workflow.shared-definition'=@('Shared workflow definition','','Inspect the exact pinned shared workflow definition and bounded YAML syntax.')
        'github.workflow.additional-jobs'=@('Additional privileged jobs','Restrict privileged runner use to independently admitted workflow definitions.','Inspect the caller for additional jobs selecting the privileged runner group.')
        'github.workflow.manual-selection'=@('Manual operation selection','Preserve the explicit shared manual-operation path and independent actor verification.','Verify the caller preserves independent manual-operation selection.')
        'github.environment.exists'=@('Deployment environment','Create the expected deployment environment under infrastructure authority.','Verify environment visibility with authorized read-only API access.')
        'github.environment.restrictions'=@('Environment branch rules','Restrict this environment to the integration branch.','Verify the environment admits only the configured integration branch.')
        'github.environment.protection'=@('Optional environment protection','','Review optional environment protection compatibility with infrastructure.')
        'github.runner.visibility'=@('Repository visibility','','Verify repository visibility with authorized API access.')
        'github.runner.group'=@('Runner group','Configure and independently provision the expected dedicated runner group.','Verify runner-group identity and settings with authorized read-only API access.')
        'github.runner.repository-access'=@('Runner repository access','Restrict the group to the caller; match public access to repository visibility.','Verify selected-repository admission and repository visibility.')
        'github.runner.workflow-access'=@('Runner workflow access','Reconcile exact workflow admission and cross-organization group ownership.','Verify the job-defining workflow identity, allowlist and group ownership.')
        'github.runner.labels'=@('Runner labels','Configure valid expected labels and an online group runner matching them.','Verify expected labels and online runner availability with read-only API access.')
        'github.runner.enterprise'=@('Enterprise runner enforcement','','Retain enterprise control of the configured admission restrictions.')
        'github.runner.public-risk'=@('Public runner risk','','Have infrastructure review public runner risk and exact repository/workflow admission.')
        'github.routing.target'=@('Deployment routing','Reconcile protected target, environment, runner and workflow routing.','Inspect protected target routing and the job-defining workflow.')
        'github.routing.activation'=@('Target activation','','Review pending activation with infrastructure under independent authority.')
        'github.routing.channel'=@('Channel isolation','Keep DEV and Production target, environment and runner scopes separate.','Inspect protected channel authority and independent channel routing.')
        'github.inspection'=@('GitHub inspection','','Retry read-only inspection; investigate incomplete source or API evidence.')
        'github.stage'=@('GitHub inspection stage','','Rerun GitHub inspection for this subject; retain available findings.')
        'host.toolkit.authentication'=@('Toolkit authentication','Have infrastructure independently authenticate the exact compatible toolkit.','Verify the independently installed toolkit and protected identity evidence.')
        'host.toolkit.stability'=@('Toolkit stability','','Verify the protected toolkit remained unchanged during inspection.')
        'host.identity.permissions'=@('Deployment identity','Use the policy-admitted deployment identity with its enabled elevated token.','Verify the admitted deployment identity and enabled elevated token.')
        'host.machine.binding'=@('Machine binding','Have infrastructure reconcile the actual machine and protected enrollment binding.','Verify actual machine identity against protected enrollment.')
        'host.target.enrollment'=@('Host enrollment','Have infrastructure independently enroll or reconcile this exact target.','Verify protected target enrollment and application/environment bindings.')
        'host.iis.presence'=@('IIS site and pool','Have infrastructure reconcile the exact enrolled dedicated IIS site and pool.','Verify the enrolled IIS site and pool through authorized read-only inspection.')
        'host.iis.configuration'=@('IIS configuration','Have infrastructure reconcile the dedicated IIS application and pool settings.','Verify dedicated IIS application, path, runtime identity and pool settings.')
        'host.filesystem.permissions'=@('Filesystem isolation','','Verify physical paths, protected ACLs and effective deployment/runtime access.')
        'host.identity.runtime'=@('Runtime identity','','Verify distinct nonadministrator runtime identity and effective write isolation.')
        'host.runtime.compatibility'=@('Hosting components','Have infrastructure reconcile supported Windows/IIS/PowerShell/.NET/ANCM components.','Verify supported hosting components through authorized read-only inspection.')
        'host.iis.environment'=@('Hosting environment','Have infrastructure reconcile HTTPS binding, pool environment and hosting settings.','Verify enrolled HTTPS binding, pool environment and host preflight evidence.')
        'host.standing.policy'=@('Optional standing policy','Reconcile the selected optional standing policy under independent authority.','Verify the selected optional standing policy; initial deployment does not require it.')
        'host.standing.scope'=@('Optional standing scope','Reconcile optional standing scope independently; keep DEV and Production separate.','Verify the optional standing policy channel, repository and producer scope.')
        'host.standing.lineage'=@('Optional standing lineage','Independently reconcile optional standing lineage with the current baseline.','Verify optional standing lineage against the current baseline.')
        'host.state.pending-admission'=@('Pending admission','','Preserve pending evidence; obtain independent infrastructure reconciliation.')
        'host.state.lock'=@('Deployment lock','Preserve lock evidence; have infrastructure reconcile the canonical lock and paths.','Fence concurrent deployment and inspect existing canonical lock/path permissions.')
        'host.state.consistency'=@('Deployment state','','Preserve state; obtain separately authorized recovery or infrastructure reconciliation.')
        'host.state.current-release'=@('Current release approval','Preserve and independently reconcile current approval, manifest and release bindings.','Verify current approval, manifest and any required active standing authority.')
        'host.state.inventory'=@('Installed release files','Preserve drift; follow separately authorized recovery without diagnostic cleanup.','Verify installed bytes against the current approved inventory; preserve unexpected files.')
        'host.state.stability'=@('Host state stability','','Freeze competing trusted writers, investigate drift and rerun inspection.')
        'host.application.acceptance'=@('Application acceptance','','Perform separately authorized application deployment/recovery acceptance.')
        'host.stage'=@('Host inspection stage','','Authorize and run the host inspection separately; retain available findings.')
        'host.report.subject'=@('Report subject binding','Rerun both inspections for the same protected subject and integration commit.','')
    }
}

function ConvertTo-ClcDeploymentPrerequisiteText {
    param([AllowNull()][AllowEmptyString()][string] $Value)
    # One pass over raw values only. Entities neutralize HTML, table delimiters,
    # Markdown syntax, autolinks and backslashes without discarding evidence.
    $normalized=[regex]::Replace($Value,'[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]+',' ')
    [regex]::Replace($normalized,'[!-/:-@\[-`{-~]',[Text.RegularExpressions.MatchEvaluator]{
        param($match)
        '&#'+([int][char]$match.Value).ToString([Globalization.CultureInfo]::InvariantCulture)+';'
    })
}

function Get-ClcDeploymentPrerequisiteNextStep {
    param($Row, [hashtable] $Presentation)
    if ($Row.status -ceq 'SKIPPED') {
        if ($Presentation.ContainsKey($Row.reason)) { return "Resolve prerequisite: $($Presentation[$Row.reason][0])." }
        switch -CaseSensitive ($Row.reason) {
            'workflow-source' { return 'Establish release and deployment workflow source first.' }
            'host.filesystem.permissions/runtime.compatibility' { return 'Establish filesystem isolation and hosting components first.' }
            'inspection-incomplete' { return 'Complete the corresponding read-only protection inspection first.' }
            'stage-incomplete' {
                if ($Row.id -ceq 'host.stage') { return 'Authorize and run the host inspection separately.' }
                if ($Row.id -ceq 'github.stage') { return 'Run GitHub inspection for the selected subject.' }
            }
        }
        return 'See technical details.'
    }
    if ($Presentation.ContainsKey($Row.id)) {
        $index=if ($Row.status -ceq 'FAIL') {1} else {2}
        $guidance=$Presentation[$Row.id][$index]
        if ($guidance) { return $guidance }
    }
    'See technical details.'
}

function Format-ClcDeploymentPrerequisiteSummary {
    param($Report)
    $s=$Report.subject
    $presentation=Get-ClcDeploymentPrerequisitePresentation
    # Sort copies with ordinal keys; never reorder report.checks or recalculate readiness.
    $technical=[Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal)
    $outstanding=[Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal)
    $successful=[Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($row in $Report.checks) {
        $label=if ($presentation.ContainsKey($row.id)) {$presentation[$row.id][0]} else {$row.id}
        $display=[pscustomobject]@{row=$row;label=$label;impact=$(if ($row.required) {'Required'} else {'Advisory'})}
        $technical.Add($row.id,$display)
        if ($row.status -cin @('PASS','NOT_APPLICABLE')) { $successful.Add($row.id,$display);continue }
        $statusOrder=switch -CaseSensitive ($row.status) {FAIL {0} UNVERIFIED {1} SKIPPED {2}}
        $impactOrder=if ($row.required) {0} else {1}
        $categoryOrder=if ($row.category -ceq 'github') {0} else {1}
        $outstanding.Add("${statusOrder}:${impactOrder}:${categoryOrder}:$($row.id)",$display)
    }
    $lines=[Collections.Generic.List[string]]::new()
    $lines.Add("# $(if ($Report.ready) {'READY'} else {'NOT READY'})");$lines.Add('')
    foreach ($field in @('repository','application','target','environment','channel')) {
        $lines.Add("$($field.Substring(0,1).ToUpperInvariant()+$field.Substring(1)): $(ConvertTo-ClcDeploymentPrerequisiteText $s.$field)  ")
    }
    $lines.Add('');$lines.Add("GitHub: **$(ConvertTo-ClcDeploymentPrerequisiteText $Report.github_status)** | Host: **$(ConvertTo-ClcDeploymentPrerequisiteText $Report.host_status)**")
    foreach ($category in @('github','host')) {
        if (-not @($Report.checks | Where-Object category -CEQ $category).Count) {
            $lines.Add('');$lines.Add("$category inspection: **SKIPPED** — this report contains no observations from that inspector.")
        }
    }
    $countText=foreach ($pair in @(@('Failed','failed'),@('Unverified','unverified'),@('Skipped','skipped'),@('Passed','passed'),@('N/A','not_applicable'))) {
        $key=$pair[1]
        "$($pair[0]): $(ConvertTo-ClcDeploymentPrerequisiteText $Report.counts.$key)"
    }
    $lines.Add('');$lines.Add($countText -join ' | ')
    $lines.Add('');$lines.Add('## Outstanding prerequisites');$lines.Add('')
    if ($outstanding.Count) {
        $lines.Add('| Status | Impact | Prerequisite | Next step |')
        $lines.Add('|--------|--------|--------------|-----------|')
        foreach ($display in $outstanding.Values) {
            $row=$display.row
            $next=Get-ClcDeploymentPrerequisiteNextStep $row $presentation
            $lines.Add("| **$(ConvertTo-ClcDeploymentPrerequisiteText $row.status)** | $($display.impact) | $(ConvertTo-ClcDeploymentPrerequisiteText $display.label) | $(ConvertTo-ClcDeploymentPrerequisiteText $next) |")
        }
        $lines.Add('');$lines.Add('Required findings affect readiness. Advisory findings do not block readiness.')
    } else { $lines.Add('No outstanding prerequisites.') }
    if ($successful.Count) {
        $lines.Add('');$lines.Add("<details><summary>Passed and not applicable checks ($($successful.Count))</summary>");$lines.Add('')
        $lines.Add('| Status | Impact | Prerequisite |');$lines.Add('|---|---|---|')
        foreach ($display in $successful.Values) {
            $lines.Add("| $(ConvertTo-ClcDeploymentPrerequisiteText $display.row.status) | $($display.impact) | $(ConvertTo-ClcDeploymentPrerequisiteText $display.label) |")
        }
        $lines.Add('');$lines.Add('</details>')
    }
    $technicalStart=$lines.Count
    $lines.Add('');$lines.Add('<details><summary>Technical details</summary>');$lines.Add('')
    $lines.Add("Integration branch: $(ConvertTo-ClcDeploymentPrerequisiteText $s.integration_branch)")
    $lines.Add('');$lines.Add("Observed commit: $(ConvertTo-ClcDeploymentPrerequisiteText $s.observed_commit)")
    foreach ($display in $technical.Values) {
        $row=$display.row
        $lines.Add('');$lines.Add("### $(ConvertTo-ClcDeploymentPrerequisiteText $row.id)");$lines.Add('')
        foreach ($field in @('category','status')) { $lines.Add("- ${field}: $(ConvertTo-ClcDeploymentPrerequisiteText $row.$field)") }
        $lines.Add("- Impact: $($display.impact)")
        foreach ($field in @('name','detail','action')) { $lines.Add("- ${field}: $(ConvertTo-ClcDeploymentPrerequisiteText $row.$field)") }
        if ($row.reason) { $lines.Add("- Dependency reason: $(ConvertTo-ClcDeploymentPrerequisiteText $row.reason)") }
    }
    $lines.Add('');$lines.Add('</details>')
    $footer='Read-only commissioning inspection. Findings do not authorize deployment. Initial deployment and application deployment/recovery acceptance require separate authorization. Rerun after relevant infrastructure changes or for troubleshooting; routine deployment does not require this report.'
    $lines.Add('');$lines.Add($footer)
    $summary=$lines -join "`n"
    # A valid near-limit JSON report can expand beyond GitHub's 1 MiB per-step
    # limit when escaped. Keep every checklist row and an explicit evidence index;
    # never silently truncate diagnostics or change JSON/outputs/readiness.
    # Reserve one byte for Publish's appended LF.
    if ([Text.Encoding]::UTF8.GetByteCount($summary) -gt 1048575) {
        $lines.RemoveRange($technicalStart,$lines.Count-$technicalStart)
        $lines.Add('');$lines.Add('<details><summary>Technical details</summary>');$lines.Add('')
        $lines.Add('Complete escaped evidence exceeds the step-summary size limit. See the unchanged JSON report for every original name, detail, action and dependency reason; no diagnostic values were truncated in JSON.')
        $lines.Add('');$lines.Add("Integration branch: $(ConvertTo-ClcDeploymentPrerequisiteText $s.integration_branch)")
        $lines.Add('');$lines.Add("Observed commit: $(ConvertTo-ClcDeploymentPrerequisiteText $s.observed_commit)")
        $lines.Add('');$lines.Add('| Check ID | Category | Status | Impact |');$lines.Add('|---|---|---|---|')
        foreach ($display in $technical.Values) {
            $row=$display.row
            $lines.Add("| $(ConvertTo-ClcDeploymentPrerequisiteText $row.id) | $(ConvertTo-ClcDeploymentPrerequisiteText $row.category) | $(ConvertTo-ClcDeploymentPrerequisiteText $row.status) | $($display.impact) |")
        }
        $lines.Add('');$lines.Add('</details>');$lines.Add('');$lines.Add($footer)
        $summary=$lines -join "`n"
    }
    $summary
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

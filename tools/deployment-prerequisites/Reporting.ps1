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

# Presentation only. Destinations, descriptions and groups are source-owned; never derive URLs from observations.
# Grouping is opt-in by setup task, then constrained by status, impact and category.
function Get-ClcDeploymentPrerequisitePresentation {
    @{
        'github.repository.identity'=@{label='Repository identity';anchor='1-before-you-begin';group=''
            finding='The observed repository identity does not match the configured consumer.';failure='Verify the configured repository identity and API access.'
            unverified='Verify repository identity with authorized API access.'}
        'github.branch.protection'=@{label='Branch protection';anchor='protect-the-integration-branch';group='Integration branch protection'
            finding='The configured integration branch is missing or its required protection is not established.';failure='Protect the configured integration branch.'
            unverified='Verify integration-branch identity and protection with read-only API access.'}
        'github.branch.force-push'=@{label='Branch force pushes';anchor='restrict-force-pushes-and-deletion';group='Integration branch protection'
            finding='Force-push restrictions do not protect the integration branch.';failure='Enforce integration-branch force-push restrictions.'
            unverified='Verify effective branch force-push restrictions.'}
        'github.branch.deletion'=@{label='Branch deletion';anchor='restrict-force-pushes-and-deletion';group='Integration branch protection'
            finding='Deletion restrictions do not protect the integration branch.';failure='Enforce integration-branch deletion restrictions.'
            unverified='Verify effective branch deletion restrictions.'}
        'github.branch.required-checks'=@{label='Branch status checks';anchor='configure-required-status-checks';group='Integration branch protection'
            finding='Required CI status checks are not enforced on the integration branch.';failure='Require CI status checks on the integration branch.'
            unverified='Verify effective required branch status checks.'}
        'github.branch.bypass'=@{label='Branch bypass restrictions';anchor='restrict-branch-bypass-access';group='Integration branch protection'
            finding='Observed bypass access defeats required integration-branch controls.';failure='Restrict broad bypass of required branch controls.'
            unverified='Verify observable branch bypass restrictions and independent enforcement.'}
        'github.branch.bypass-visibility'=@{label='Branch bypass visibility';anchor='restrict-branch-bypass-access';group=''
            finding='Bypass visibility requires independent review.';failure='Review bypass visibility under independent infrastructure control.'
            unverified='Review available bypass evidence; retain independent infrastructure control.'}
        'github.branch.reviews'=@{label='Optional branch reviews';anchor='configure-required-status-checks';group=''
            finding='Optional branch review settings require application-policy review.';failure='Review optional branch checks and application review policy.'
            unverified=''}
        'github.tags.creation'=@{label='Release tag creation';anchor='configure-release-tag-creation-restrictions';group='Release tag protection'
            finding='Release-tag creation is not restricted for the selected channel.';failure='Enforce release-tag creation restrictions for the selected channel.'
            unverified='Verify effective release-tag creation restrictions for the selected channel.'}
        'github.tags.update'=@{label='Release tag updates';anchor='configure-release-tag-update-restrictions';group='Release tag protection'
            finding='Release-tag updates are not restricted for the selected channel.';failure='Enforce release-tag update restrictions for the selected channel.'
            unverified='Verify effective release-tag update restrictions for the selected channel.'}
        'github.tags.deletion'=@{label='Release tag deletion';anchor='configure-release-tag-deletion-restrictions';group='Release tag protection'
            finding='Release-tag deletion is not restricted for the selected channel.';failure='Enforce release-tag deletion restrictions for the selected channel.'
            unverified='Verify effective release-tag deletion restrictions for the selected channel.'}
        'github.tags.bypass'=@{label='Tag bypass restrictions';anchor='restrict-tag-bypass-access';group='Release tag protection'
            finding='Observed bypass access defeats required release-tag controls.';failure='Restrict broad bypass of release-tag controls.'
            unverified='Verify observable release-tag bypass restrictions and independent enforcement.'}
        'github.tags.bypass-visibility'=@{label='Tag bypass visibility';anchor='restrict-tag-bypass-access';group=''
            finding='Release-tag bypass visibility requires independent review.';failure='Review release-tag bypass visibility under infrastructure control.'
            unverified='Review available release bypass evidence; retain independent infrastructure control.'}
        'github.tags.authority'=@{label='Release authority';anchor='restrict-tag-bypass-access';group=''
            finding='Release-creation authority requires independent review.';failure='Review independent release authority and permitted tag creators.'
            unverified='Retain independent control of release producers and authorized bypass identities.'}
        'github.workflow.producer'=@{label='Release workflow';anchor='configure-the-release-workflow';group=''
            finding='The expected producer workflow is missing or has invalid or unsupported structure.';failure='Correct the expected release workflow source or structure.'
            unverified='Inspect the expected release workflow at the observed integration commit.'}
        'github.workflow.caller'=@{label='Deployment workflow';anchor='configure-the-deployment-workflow';group=''
            finding='The expected deployment caller is missing or has invalid or unsupported structure.';failure='Correct the expected deployment workflow source or structure.'
            unverified='Inspect the expected deployment workflow at the observed integration commit.'}
        'github.workflow.release-trigger'=@{label='Release trigger';anchor='review-intentional-workflow-differences';group=''
            finding='The producer has no tag-push filter matching the checker''s supported automatic arrangement.';failure='Review the supported trigger model and resolve intentional workflow differences.'
            unverified='Verify the release workflow version-tag trigger.'}
        'github.workflow.completion-trigger'=@{label='Producer handoff';anchor='configure-producer-handoff';group=''
            finding='The producer-to-deployment completion relationship does not match the supported arrangement.';failure='Review producer handoff and intentional workflow differences before changing triggers.'
            unverified='Inspect the protected release-to-deployment handoff.'}
        'github.workflow.manual-dispatch'=@{label='Manual dispatch authority';anchor='configure-producer-handoff';group=''
            finding='Manual dispatch authorization requires independent review.';failure='Review protected manual dispatch and independent actor authorization.'
            unverified='Review independent manual-operation authorization in the pinned shared implementation.'}
        'github.workflow.runtime-semantics'=@{label='Workflow runtime behavior';anchor='authorize-first-deployment-and-acceptance';group=''
            finding='Workflow runtime behavior requires separately authorized acceptance.';failure='Perform separately authorized application deployment/recovery acceptance.'
            unverified='Review the pinned shared revision; perform separately authorized consumer acceptance.'}
        'github.workflow.shared-identity'=@{label='Shared workflow identity';anchor='configure-the-deployment-workflow';group=''
            finding='The caller, protected configuration and immutable shared revision do not agree.';failure='Reconcile exact caller, protected configuration and immutable shared revision.'
            unverified='Verify the caller and protected configuration select the reviewed shared identity.'}
        'github.workflow.shared-definition'=@{label='Shared workflow definition';anchor='configure-the-deployment-workflow';group=''
            finding='The pinned shared workflow definition is incompatible with the expected deployment structure.';failure='Review the exact pinned shared workflow definition and configuration.'
            unverified='Inspect the exact pinned shared workflow definition and bounded YAML syntax.'}
        'github.workflow.additional-jobs'=@{label='Additional privileged jobs';anchor='restrict-runner-workflow-access';group=''
            finding='Additional caller jobs directly select the privileged runner group.';failure='Restrict privileged runner use to independently admitted workflow definitions.'
            unverified='Inspect the caller for additional jobs selecting the privileged runner group.'}
        'github.workflow.manual-selection'=@{label='Manual operation selection';anchor='configure-producer-handoff';group=''
            finding='A dispatch-capable caller selects automatic deployment instead of preserving explicit actor verification.';failure='Preserve the explicit shared manual-operation path and independent actor verification.'
            unverified='Verify the caller preserves independent manual-operation selection.'}
        'github.environment.exists'=@{label='Deployment environment';anchor='create-deployment-environments';group='Deployment environment'
            finding='The exact deployment environment was not found in the complete accessible list.';failure='Create the expected deployment environment under infrastructure authority.'
            unverified='Verify environment visibility with authorized read-only API access.'}
        'github.environment.restrictions'=@{label='Environment branch rules';anchor='restrict-environment-branches';group='Deployment environment'
            finding='The deployment environment admits unrestricted refs or unexpected branch/tag rules.';failure='Restrict this environment to the integration branch.'
            unverified='Verify the environment admits only the configured integration branch.'}
        'github.environment.protection'=@{label='Optional environment protection';anchor='create-deployment-environments';group=''
            finding='Optional environment protections require application-policy review.';failure='Review optional protection settings against the intended unattended policy.'
            unverified='Review optional environment protection compatibility with infrastructure.'}
        'github.runner.visibility'=@{label='Repository visibility';anchor='restrict-runner-repository-access';group=''
            finding='The repository visibility selection is inconsistent with runner admission.';failure='Verify caller visibility and exact runner repository admission.'
            unverified='Verify repository visibility with authorized API access.'}
        'github.runner.group'=@{label='Runner group';anchor='create-a-dedicated-runner-group';group=''
            finding='The expected group name is not configured or the group is absent from the complete accessible list.';failure='Configure and independently provision the expected dedicated runner group.'
            unverified='Verify runner-group identity and settings with authorized read-only API access.'}
        'github.runner.repository-access'=@{label='Runner repository access';anchor='restrict-runner-repository-access';group=''
            finding='Runner repository access or public eligibility does not match the exact caller.';failure='Restrict the group to the caller; match public access to repository visibility.'
            unverified='Verify selected-repository admission and repository visibility.'}
        'github.runner.workflow-access'=@{label='Runner workflow access';anchor='restrict-runner-workflow-access';group=''
            finding='Runner workflow restrictions or cross-organization ownership do not meet the required admission boundary.';failure='Reconcile exact workflow admission and cross-organization group ownership.'
            unverified='Verify the job-defining workflow identity, allowlist and group ownership.'}
        'github.runner.labels'=@{label='Runner labels';anchor='register-runners-and-configure-labels';group=''
            finding='Expected labels are missing or invalid, or no online group runner matches them.';failure='Configure valid expected labels and an online group runner matching them.'
            unverified='Verify expected labels and online runner availability with read-only API access.'}
        'github.runner.enterprise'=@{label='Enterprise runner enforcement';anchor='restrict-runner-workflow-access';group=''
            finding='Enterprise runner enforcement requires infrastructure review.';failure='Review inherited enterprise runner restrictions with infrastructure.'
            unverified='Retain enterprise control of the configured admission restrictions.'}
        'github.runner.public-risk'=@{label='Public runner risk';anchor='restrict-runner-repository-access';group=''
            finding='Public self-hosted runner exposure requires infrastructure review.';failure='Review public runner risk and exact repository/workflow admission.'
            unverified='Have infrastructure review public runner risk and exact repository/workflow admission.'}
        'github.routing.target'=@{label='Deployment routing';anchor='configure-protected-deployment-routing';group=''
            finding='Protected or directly observed job routing conflicts with the selected target.';failure='Reconcile protected target, environment, runner and workflow routing.'
            unverified='Inspect protected target routing and the job-defining workflow.'}
        'github.routing.activation'=@{label='Target activation';anchor='activate-only-under-independent-authority';group=''
            finding='Target activation indicators require independent infrastructure review.';failure='Review activation later under independent infrastructure authority.'
            unverified='Review pending activation with infrastructure under independent authority.'}
        'github.routing.channel'=@{label='Channel isolation';anchor='configure-protected-deployment-routing';group=''
            finding='Protected source policy or DEV/Production routing does not preserve separate scopes.';failure='Keep DEV and Production target, environment and runner scopes separate.'
            unverified='Inspect protected channel authority and independent channel routing.'}
        'github.inspection'=@{label='GitHub inspection';anchor='troubleshoot-incomplete-inspection';group=''
            finding='GitHub inspection did not establish complete valid evidence.';failure='Investigate incomplete inspection and rerun the read-only diagnostic.'
            unverified='Retry read-only inspection; investigate incomplete source or API evidence.'}
        'github.stage'=@{label='GitHub inspection stage';anchor='troubleshoot-incomplete-inspection';group=''
            finding='The GitHub inspection stage did not complete with a valid report.';failure='Rerun GitHub inspection for the selected protected subject.'
            unverified='Rerun GitHub inspection for this subject; retain available findings.'}
        'host.toolkit.authentication'=@{label='Toolkit authentication';anchor='install-and-verify-the-toolkit';group=''
            finding='The installed toolkit selector, bytes, authority or required compatible readers failed authentication.';failure='Have infrastructure independently authenticate the exact compatible toolkit.'
            unverified='Verify the independently installed toolkit and protected identity evidence.'}
        'host.toolkit.stability'=@{label='Toolkit stability';anchor='troubleshoot-host-trust-and-enrollment';group=''
            finding='The protected toolkit did not remain stable through inspection.';failure='Independently investigate toolkit drift and reauthenticate before inspection.'
            unverified='Verify the protected toolkit remained unchanged during inspection.'}
        'host.identity.permissions'=@{label='Deployment identity';anchor='configure-deployment-and-runtime-identities';group=''
            finding='The inspection identity is not the admitted deployment SID with an enabled elevated token.';failure='Use the policy-admitted deployment identity with its enabled elevated token.'
            unverified='Verify the admitted deployment identity and enabled elevated token.'}
        'host.machine.binding'=@{label='Machine binding';anchor='troubleshoot-host-trust-and-enrollment';group=''
            finding='The actual machine identity differs from protected enrollment.';failure='Have infrastructure reconcile the actual machine and protected enrollment binding.'
            unverified='Verify actual machine identity against protected enrollment.'}
        'host.target.enrollment'=@{label='Host enrollment';anchor='enroll-the-target';group=''
            finding='The protected target is missing, has an unsupported contract or disagrees with the selected application/environment.';failure='Have infrastructure independently enroll or reconcile this exact target.'
            unverified='Verify protected target enrollment and application/environment bindings.'}
        'host.iis.presence'=@{label='IIS site and pool';anchor='prepare-windows-and-iis';group='IIS configuration'
            finding='The enrolled dedicated IIS site or pool is missing or ambiguous.';failure='Have infrastructure reconcile the exact enrolled dedicated IIS site and pool.'
            unverified='Verify the enrolled IIS site and pool through authorized read-only inspection.'}
        'host.iis.configuration'=@{label='IIS configuration';anchor='prepare-windows-and-iis';group='IIS configuration'
            finding='Observed IIS root, path, runtime identity or pool settings disagree with enrollment.';failure='Have infrastructure reconcile the dedicated IIS application and pool settings.'
            unverified='Verify dedicated IIS application, path, runtime identity and pool settings.'}
        'host.filesystem.permissions'=@{label='Filesystem isolation';anchor='protect-directories-and-external-configuration';group=''
            finding='Physical path or effective filesystem isolation does not satisfy enrollment.';failure='Have infrastructure inspect physical paths, protected ACLs and effective access.'
            unverified='Verify physical paths, protected ACLs and effective deployment/runtime access.'}
        'host.identity.runtime'=@{label='Runtime identity';anchor='configure-deployment-and-runtime-identities';group=''
            finding='Runtime identity or effective protected-resource write isolation does not satisfy enrollment.';failure='Have infrastructure reconcile runtime identity and effective write isolation.'
            unverified='Verify distinct nonadministrator runtime identity and effective write isolation.'}
        'host.runtime.compatibility'=@{label='Hosting components';anchor='prepare-windows-and-iis';group=''
            finding='Required Windows/x64 PowerShell/.NET/ASP.NET Core/ANCM components are missing or incompatible.';failure='Have infrastructure reconcile supported Windows/IIS/PowerShell/.NET/ANCM components.'
            unverified='Verify supported hosting components through authorized read-only inspection.'}
        'host.iis.environment'=@{label='Hosting environment';anchor='prepare-windows-and-iis';group='IIS configuration'
            finding='The enrolled HTTPS, runtime environment or observed pool/worker state is incompatible.';failure='Have infrastructure reconcile HTTPS binding, pool environment and hosting settings.'
            unverified='Verify enrolled HTTPS binding, pool environment and host preflight evidence.'}
        'host.standing.policy'=@{label='Optional standing policy';anchor='configure-optional-standing-authorization';group=''
            finding='The selected optional standing policy does not satisfy protected target authority.';failure='Reconcile the selected optional standing policy under independent authority.'
            unverified='Verify the selected optional standing policy; initial deployment does not require it.'}
        'host.standing.scope'=@{label='Optional standing scope';anchor='configure-optional-standing-authorization';group=''
            finding='The selected optional standing policy has a different channel, repository or producer scope.';failure='Reconcile optional standing scope independently; keep DEV and Production separate.'
            unverified='Verify the optional standing policy channel, repository and producer scope.'}
        'host.standing.lineage'=@{label='Optional standing lineage';anchor='configure-optional-standing-authorization';group=''
            finding='Optional standing lineage disagrees with the current baseline.';failure='Independently reconcile optional standing lineage with the current baseline.'
            unverified='Verify optional standing lineage against the current baseline.'}
        'host.state.pending-admission'=@{label='Pending admission';anchor='inspect-existing-deployment-state';group='Deployment state'
            finding='An unresolved admission intent blocks deployment; preserve its evidence.';failure='Preserve pending evidence and obtain independent reconciliation.'
            unverified='Preserve pending evidence; obtain independent infrastructure reconciliation.'}
        'host.state.lock'=@{label='Deployment lock';anchor='inspect-existing-deployment-state';group='Deployment state'
            finding='The existing canonical deployment lock or its path does not satisfy enrollment.';failure='Preserve lock evidence; have infrastructure reconcile the canonical lock and paths.'
            unverified='Fence concurrent deployment and inspect existing canonical lock/path permissions.'}
        'host.state.consistency'=@{label='Deployment state';anchor='inspect-existing-deployment-state';group='Deployment state'
            finding='Canonical state, helper evidence or unexpected application files require reconciliation.';failure='Preserve state and obtain separately authorized recovery or maintenance.'
            unverified='Preserve state; obtain separately authorized recovery or infrastructure reconciliation.'}
        'host.state.current-release'=@{label='Current release approval';anchor='inspect-existing-deployment-state';group='Deployment state'
            finding='Current approval, retained manifest or exact release bindings are missing or invalid.';failure='Preserve and independently reconcile current approval, manifest and release bindings.'
            unverified='Verify current approval, manifest and any required active standing authority.'}
        'host.state.inventory'=@{label='Installed release files';anchor='inspect-existing-deployment-state';group='Deployment state'
            finding='Installed application bytes differ from the approved current inventory.';failure='Preserve drift; follow separately authorized recovery without diagnostic cleanup.'
            unverified='Verify installed bytes against the current approved inventory; preserve unexpected files.'}
        'host.state.stability'=@{label='Host state stability';anchor='inspect-existing-deployment-state';group='Deployment state'
            finding='Host state changed during inspection; preserve the observed drift.';failure='Fence competing trusted writers, investigate drift and rerun inspection.'
            unverified='Freeze competing trusted writers, investigate drift and rerun inspection.'}
        'host.application.acceptance'=@{label='Application acceptance';anchor='authorize-first-deployment-and-acceptance';group=''
            finding='Application deployment/recovery acceptance remains outstanding.';failure='Perform separately authorized application deployment/recovery acceptance.'
            unverified='Perform separately authorized application deployment/recovery acceptance.'}
        'host.stage'=@{label='Host inspection stage';anchor='troubleshoot-host-trust-and-enrollment';group=''
            finding='The host inspection stage did not complete with a valid report.';failure='Separately authorize and run trusted host inspection.'
            unverified='Authorize and run the host inspection separately; retain available findings.'}
        'host.report.subject'=@{label='Report subject binding';anchor='rerun-matching-inspections';group=''
            finding='GitHub and host reports select different subjects or observed integration commits.';failure='Rerun both inspections for the same protected subject and integration commit.'
            unverified=''}
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
        if ($Row.reason -and $Presentation.ContainsKey($Row.reason)) { return "Resolve prerequisite: $($Presentation[$Row.reason].label)." }
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
        $guidance=if ($Row.status -ceq 'FAIL') {$Presentation[$Row.id].failure} else {$Presentation[$Row.id].unverified}
        if ($guidance) { return $guidance }
    }
    'See technical details.'
}

function Format-ClcDeploymentPrerequisiteExplanation {
    param($Row, [hashtable] $Presentation)
    $next=Get-ClcDeploymentPrerequisiteNextStep $Row $Presentation
    if (-not $Presentation.ContainsKey($Row.id)) {
        return 'This finding requires review of its original evidence. See technical details.'
    }
    $entry=$Presentation[$Row.id]
    if ($Row.status -ceq 'FAIL') {
        $finding=$entry.finding
        # Exact source-authored variants clarify common commissioning failures.
        # Unrecognized prose uses the conservative check-specific description, never a truncated excerpt.
        if ($Row.id -ceq 'github.runner.group') {
            switch -CaseSensitive ($Row.detail) {
                'The expected deployment runner-group name was not configured.' { $finding='The expected deployment runner-group name is not configured.' }
                'Expected group absent from the complete accessible organization list.' { $finding='The configured runner group is absent from the complete accessible organization list.' }
            }
        } elseif ($Row.id -ceq 'github.runner.labels') {
            switch -CaseSensitive ($Row.detail) {
                'The expected deployment runner labels were not configured.' { $finding='The expected deployment runner labels are not configured.' }
                'No online group runner has all expected labels.' { $finding='No online runner in the selected group has every expected label.' }
            }
        }
        $url='https://github.com/clcdpc/clc-deployment/blob/master/docs/setup-guide.md#'+$entry.anchor
        # Only source-owned URL/HTML is structural; all observed strings remain escaped text.
        return "$(ConvertTo-ClcDeploymentPrerequisiteText $finding) <a href=`"$url`">$(ConvertTo-ClcDeploymentPrerequisiteText $next)</a>"
    }
    if ($Row.status -ceq 'SKIPPED') {
        return "$(ConvertTo-ClcDeploymentPrerequisiteText ($entry.label+' was not inspected.')) $(ConvertTo-ClcDeploymentPrerequisiteText $next)"
    }
    $finding=$entry.label+' could not be verified with the available evidence.'
    if ($Row.id -ceq 'github.routing.activation') { $finding='Target activation remains pending or unverified; indicators do not supply deployment authority.' }
    if ($Row.id -ceq 'host.application.acceptance') { $finding='Static inspection does not establish application deployment/recovery acceptance.' }
    "$(ConvertTo-ClcDeploymentPrerequisiteText $finding) $(ConvertTo-ClcDeploymentPrerequisiteText $next)"
}

function Format-ClcDeploymentPrerequisiteSummary {
    param($Report)
    $s=$Report.subject
    $presentation=Get-ClcDeploymentPrerequisitePresentation
    # Sort copies with ordinal keys; never reorder report.checks or recalculate readiness.
    $technical=[Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal)
    $outstanding=[Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal)
    $successful=[Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal)
    $groups=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($row in $Report.checks) {
        $label=if ($presentation.ContainsKey($row.id)) {$presentation[$row.id].label} else {$row.id}
        $display=[pscustomobject]@{row=$row;label=$label;impact=$(if ($row.required) {'Required'} else {'Advisory'})}
        $technical.Add($row.id,$display)
        if ($row.status -cin @('PASS','NOT_APPLICABLE')) { $successful.Add($row.id,$display);continue }
    }
    # Ordinal technical copies also establish deterministic bullet order and group identity.
    foreach ($display in $technical.Values) {
        $row=$display.row
        if ($row.status -cin @('PASS','NOT_APPLICABLE')) {continue}
        $statusOrder=switch -CaseSensitive ($row.status) {FAIL {0} UNVERIFIED {1} SKIPPED {2}}
        $impactOrder=if ($row.required) {0} else {1}
        $categoryOrder=if ($row.category -ceq 'github') {0} else {1}
        $area=if ($presentation.ContainsKey($row.id)) {$presentation[$row.id].group} else {''}
        $groupKey="${statusOrder}:${impactOrder}:${categoryOrder}:$(if ($area) {$area} else {$row.id})"
        if (-not $groups.ContainsKey($groupKey)) {
            $group=[pscustomobject]@{label=$area;members=[Collections.Generic.List[object]]::new()}
            $groups.Add($groupKey,$group)
            # First member is the smallest ordinal check ID, used as the stable row sort identity.
            $outstanding.Add("${statusOrder}:${impactOrder}:${categoryOrder}:$($row.id)",$group)
        }
        $groups[$groupKey].members.Add($display)
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
        $lines.Add('| Status | Prerequisite | Explanation |')
        $lines.Add('|---|---|---|')
        foreach ($group in $outstanding.Values) {
            $display=$group.members[0];$row=$display.row
            $label=$display.label
            if ($group.members.Count -gt 1) {
                $label=$group.label
                $bullets=foreach ($member in $group.members) {
                    '<li>'+(Format-ClcDeploymentPrerequisiteExplanation $member.row $presentation)+'</li>'
                }
                $explanation='The following findings need attention:<ul>'+($bullets -join '')+'</ul>'
            } else { $explanation=Format-ClcDeploymentPrerequisiteExplanation $row $presentation }
            $lines.Add("| **$(ConvertTo-ClcDeploymentPrerequisiteText $row.status)** · $($display.impact) | $(ConvertTo-ClcDeploymentPrerequisiteText $label) | $explanation |")
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

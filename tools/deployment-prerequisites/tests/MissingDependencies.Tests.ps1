BeforeDiscovery {Import-Module (Join-Path $PSScriptRoot '../Validation.psm1') -Force}

Describe 'Commissioning without configured infrastructure' {
    InModuleScope Validation {
        BeforeAll {
            . (Join-Path $PSScriptRoot 'Fixtures.ps1')
            function Set-DirectCaller {
                $config.Remove('SharedRevision')
                $fixture[('/repos/example/app/contents/.github/workflows/deploy-release.yml?ref='+('b'*40))]=New-WorkflowFile @'
name: Deploy
on: {workflow_run: {workflows: [Release], types: [completed]}}
jobs:
  deploy:
    runs-on: {group: app-deployment, labels: [self-hosted, Windows, X64]}
    environment: app-dev
    steps: [{run: 'echo synthetic'}]
'@
                $fixture['/orgs/example/actions/runner-groups/7'].data.selected_workflows=@(
                    'example/app/.github/workflows/deploy-release.yml@refs/heads/master',
                    'example/app/.github/workflows/diagnose.yml@refs/heads/master')
            }
        }
        BeforeEach {
            $config=New-ValidationConfig;$fixture=New-ValidationFixture
            Mock Get-ClcDeploymentPrerequisiteApi {
                param($Context,$Path)
                $key=$Path -replace '[?&]per_page=(30|100)&page=\d+$',''
                if (-not $fixture.ContainsKey($key)) {return New-ApiFailure 403}
                $fixture[$key]
            }
        }
        It 'reports missing group configuration and continues all independent inspection: <Kind>' -ForEach @(
            @{Kind='empty'},@{Kind='null'},@{Kind='omitted'}
        ) {
            switch ($Kind) {empty {$config.RunnerGroup=''};null {$config.RunnerGroup=$null};omitted {$config.Remove('RunnerGroup')}}
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            $group=$r.checks | Where-Object id -CEQ github.runner.group
            $group.status | Should -Be FAIL;$group.required | Should -BeTrue
            $group.detail | Should -Match 'name was not configured'
            $group.action | Should -Match 'independent infrastructure authority'
            foreach ($id in @('repository.identity','branch.protection','tags.creation','workflow.producer','workflow.caller','environment.exists','environment.restrictions')) {
                ($r.checks | Where-Object id -CEQ "github.$id").status | Should -Be PASS
            }
            foreach ($id in @('runner.repository-access','runner.workflow-access','runner.labels','routing.target','workflow.additional-jobs')) {
                $row=$r.checks | Where-Object id -CEQ "github.$id"
                $row.status | Should -Be SKIPPED;$row.reason | Should -Be github.runner.group
                $row.detail | Should -Not -BeNullOrEmpty;$row.action | Should -Not -BeNullOrEmpty
            }
            Should -Invoke Get-ClcDeploymentPrerequisiteApi -Times 0 -Exactly -ParameterFilter {$Path -like '/orgs/*/actions/runner-groups*'}
            @($r.checks | Where-Object id -CEQ github.inspection).Count | Should -Be 0
            $r.github_status | Should -Be FAIL;$r.ready | Should -BeFalse
            ConvertTo-ClcDeploymentPrerequisiteStageReport $r | Should -Not -BeNullOrEmpty
        }
        It 'retains repository-level inspection when integration source is unavailable: <Code>' -ForEach @(@{Code=404},@{Code=403},@{Code=200}) {
            $config.RunnerGroup='';$config.RunnerLabels=''
            $fixture['/repos/example/app/branches/master']=New-ApiFailure $Code
            if ($Code -eq 200) {$fixture['/repos/example/app/branches/master']=New-ApiSuccess $null}
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -CEQ github.branch.protection).status | Should -Be $(if ($Code -eq 404) {'FAIL'} else {'UNVERIFIED'})
            foreach ($id in @('repository.identity','runner.visibility','tags.creation','environment.exists','environment.restrictions')) {
                ($r.checks | Where-Object id -CEQ "github.$id").status | Should -Be PASS
            }
            foreach ($id in @('runner.group','runner.labels')) {($r.checks | Where-Object id -CEQ "github.$id").status | Should -Be FAIL}
            ($r.checks | Where-Object id -CEQ github.inspection).status | Should -Be SKIPPED
            Should -Invoke Get-ClcDeploymentPrerequisiteApi -Times 0 -Exactly -ParameterFilter {$Path -match '/contents/|/runner-groups'}
            ConvertTo-ClcDeploymentPrerequisiteStageReport $r | Should -Not -BeNullOrEmpty
        }
        It 'emits group-dependent identities for <Kind> evidence' -ForEach @(
            @{Kind='absent';Expected='FAIL'},@{Kind='list denied';Expected='UNVERIFIED'},
            @{Kind='list concealed';Expected='UNVERIFIED'},@{Kind='malformed list';Expected='UNVERIFIED'},
            @{Kind='detail denied';Expected='UNVERIFIED'},@{Kind='detail concealed';Expected='UNVERIFIED'},
            @{Kind='null detail';Expected='UNVERIFIED'},@{Kind='empty detail';Expected='UNVERIFIED'},
            @{Kind='wrong detail identity';Expected='UNVERIFIED'},@{Kind='coerced detail ID';Expected='UNVERIFIED'}
        ) {
            $path='/orgs/example/actions/runner-groups'
            switch ($Kind) {
                absent {$fixture[$path]=New-ApiSuccess @{runner_groups=@();total_count=0}}
                'list denied' {$fixture[$path]=New-ApiFailure 403}
                'list concealed' {$fixture[$path]=New-ApiFailure 404}
                'malformed list' {$fixture[$path]=New-ApiSuccess @{runner_groups=@($null);total_count=1}}
                'detail denied' {$fixture["$path/7"]=New-ApiFailure 403}
                'detail concealed' {$fixture["$path/7"]=New-ApiFailure 404}
                'null detail' {$fixture["$path/7"]=New-ApiSuccess $null}
                'empty detail' {$fixture["$path/7"]=New-ApiSuccess @{}}
                'wrong detail identity' {$fixture["$path/7"].data.name='other'}
                'coerced detail ID' {$fixture["$path/7"].data.id='7'}
            }
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -CEQ github.runner.group).status | Should -Be $Expected
            foreach ($id in @('repository-access','workflow-access','labels')) {
                ($r.checks | Where-Object id -CEQ "github.runner.$id").status | Should -Be SKIPPED
            }
            ($r.checks | Where-Object id -CEQ github.environment.restrictions).status | Should -Be PASS
            @($r.checks | Where-Object id -CEQ github.inspection).Count | Should -Be 0
            ConvertTo-ClcDeploymentPrerequisiteStageReport $r | Should -Not -BeNullOrEmpty
        }
        It 'reports missing or invalid expected labels safely: <Kind>' -ForEach @(
            @{Kind='empty';Value='';Detail='not configured'},@{Kind='null';Value=$null;Detail='not configured'},
            @{Kind='omitted';Value=$null;Detail='not configured'},@{Kind='whitespace';Value='self-hosted, Windows';Detail='invalid'},
            @{Kind='empty element';Value='Windows,';Detail='invalid'},@{Kind='count';Value=((1..11) -join ',');Detail='invalid'},
            @{Kind='length';Value=('x'*65);Detail='invalid'},@{Kind='expression';Value='${{ vars.LABEL }}';Detail='invalid'},
            @{Kind='type';Value=@('Windows');Detail='invalid'}
        ) {
            $config.RunnerLabels=$Value
            if ($Kind -ceq 'omitted') {$config.Remove('RunnerLabels')}
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            $row=$r.checks | Where-Object id -CEQ github.runner.labels
            $row.status | Should -Be FAIL;$row.required | Should -BeTrue
            $row.detail | Should -Match $Detail;$row.action | Should -Match 'Configure.*expected runner labels'
            ($r.checks | Where-Object id -CEQ github.runner.workflow-access).status | Should -Be PASS
            ($r.checks | Where-Object id -CEQ github.routing.target).status | Should -Be SKIPPED
            Should -Invoke Get-ClcDeploymentPrerequisiteApi -Times 0 -Exactly -ParameterFilter {$Path -match '/runner-groups/7/runners'}
            @($r.checks | Where-Object id -CEQ github.inspection).Count | Should -Be 0
            $r.github_status | Should -Be FAIL
        }
        It 'does not turn unavailable runner label or availability evidence into absence: <Kind>' -ForEach @(
            @{Kind='denied'},@{Kind='concealed'},@{Kind='missing labels'},@{Kind='missing availability'},@{Kind='malformed label'}
        ) {
            $key='/orgs/example/actions/runner-groups/7/runners'
            switch ($Kind) {
                denied {$fixture[$key]=New-ApiFailure 403}
                concealed {$fixture[$key]=New-ApiFailure 404}
                'missing labels' {$fixture[$key].data.runners[0].Remove('labels')}
                'missing availability' {$fixture[$key].data.runners[0].Remove('status')}
                'malformed label' {$fixture[$key].data.runners[0].labels=@($null)}
            }
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -CEQ github.runner.labels).status | Should -Be UNVERIFIED
            @($r.checks | Where-Object id -CEQ github.inspection).Count | Should -Be 0
        }
        It 'retains bounded valid label configurations with <Count> labels' -ForEach @(@{Count=1},@{Count=10}) {
            $labels=@(1..$Count | ForEach-Object {"label-$_"})
            $config.RunnerLabels=$labels -join ','
            $fixture['/orgs/example/actions/runner-groups/7/runners'].data.runners[0].labels=@($labels | ForEach-Object {@{name=$_}})
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -CEQ github.runner.labels).status | Should -Be PASS
        }
        It 'preserves excessive <Access> authority FAIL when labels are missing' -ForEach @(@{Access='repository'},@{Access='workflow'}) {
            $config.RunnerLabels=''
            $g=$fixture['/orgs/example/actions/runner-groups/7'].data
            if ($Access -ceq 'repository') {$g.visibility='all'} else {$g.selected_workflows+='example/app/.github/workflows/extra.yml@refs/heads/master'}
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -CEQ "github.runner.$Access-access").status | Should -Be FAIL
            ($r.checks | Where-Object id -CEQ github.runner.labels).status | Should -Be FAIL
        }
        It 'retains direct workflow applicability without a shared revision and blocks incomplete comparisons: <Missing>' -ForEach @(
            @{Missing='none'},@{Missing='group'},@{Missing='labels'}
        ) {
            Set-DirectCaller
            if ($Missing -ceq 'group') {$config.RunnerGroup=''}
            if ($Missing -ceq 'labels') {$config.RunnerLabels=''}
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -CEQ github.workflow.shared-identity).status | Should -Be NOT_APPLICABLE
            ($r.checks | Where-Object id -CEQ github.routing.target).status | Should -Be $(if ($Missing -ceq 'none') {'PASS'} else {'SKIPPED'})
            ($r.checks | Where-Object id -CEQ github.runner.workflow-access).status | Should -Be $(if ($Missing -ceq 'group') {'SKIPPED'} else {'PASS'})
            Should -Invoke Get-ClcDeploymentPrerequisiteApi -Times 0 -Exactly -ParameterFilter {$Path -match 'contents/.clc/release.json|/repos/clcdpc/'}
        }
        It 'keeps observed shared calls incomplete when the reviewed revision is missing' {
            $config.SharedRevision=''
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -CEQ github.workflow.shared-identity).status | Should -Be UNVERIFIED
            ($r.checks | Where-Object id -CEQ github.workflow.shared-definition).status | Should -Be SKIPPED
            ($r.checks | Where-Object id -CEQ github.runner.workflow-access).status | Should -Not -Be PASS
            $r.ready | Should -BeFalse
        }
        It 'preserves direct-route evidence with missing <Missing> expectations and <Selector> selectors' -ForEach @(
            @{Missing='group';Selector='wrong environment';Expected='FAIL'},
            @{Missing='labels';Selector='wrong environment';Expected='FAIL'},
            @{Missing='group';Selector='wrong labels';Expected='FAIL'},
            @{Missing='group';Selector='dynamic environment';Expected='SKIPPED'}
        ) {
            Set-DirectCaller
            if ($Missing -ceq 'group') {$config.RunnerGroup=''} else {$config.RunnerLabels=''}
            $key='/repos/example/app/contents/.github/workflows/deploy-release.yml?ref='+('b'*40)
            $text=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($fixture[$key].data.content))
            switch ($Selector) {
                'wrong environment' {$text=$text.Replace('environment: app-dev','environment: app-prod')}
                'wrong labels' {$text=$text.Replace('self-hosted, Windows, X64','ubuntu')}
                'dynamic environment' {$text=$text.Replace('environment: app-dev','environment: ${{ vars.ENVIRONMENT }}')}
            }
            $fixture[$key]=New-WorkflowFile $text
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -CEQ github.routing.target).status | Should -Be $Expected
            @($r.checks | Where-Object reason -CEQ inspection-error).Count | Should -Be 0
        }
        It 'retains independent observations when <Workflow> source is <Evidence>' -ForEach @(
            foreach ($workflow in @('release','deploy-release')) {
                @{Workflow=$workflow;Evidence='missing';Code=404;Expected='FAIL'}
                @{Workflow=$workflow;Evidence='inaccessible';Code=403;Expected='UNVERIFIED'}
            }
        ) {
            $fixture[("/repos/example/app/contents/.github/workflows/$Workflow.yml?ref="+('b'*40))]=New-ApiFailure $Code
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            $id=if ($Workflow -ceq 'release') {'producer'} else {'caller'}
            ($r.checks | Where-Object id -CEQ "github.workflow.$id").status | Should -Be $Expected
            foreach ($id in @('repository.identity','branch.protection','tags.creation','runner.group','environment.exists')) {
                ($r.checks | Where-Object id -CEQ "github.$id").status | Should -Be PASS
            }
            ($r.checks | Where-Object id -CEQ github.workflow.completion-trigger).status | Should -Be SKIPPED
            if ($Workflow -ceq 'deploy-release') {
                ($r.checks | Where-Object id -CEQ github.workflow.manual-selection).status | Should -Be SKIPPED
                ($r.checks | Where-Object id -CEQ github.runner.workflow-access).status | Should -Be UNVERIFIED
            }
            @($r.checks | Where-Object id -CEQ github.inspection).Count | Should -Be 0
        }
        It 'classifies environment <Evidence> without losing unrelated findings' -ForEach @(
            @{Evidence='absent';Expected='FAIL';Dependent='SKIPPED'},
            @{Evidence='inaccessible';Expected='UNVERIFIED';Dependent='SKIPPED'},
            @{Evidence='detail absent';Expected='PASS';Dependent='UNVERIFIED'},
            @{Evidence='malformed list';Expected='UNVERIFIED';Dependent='SKIPPED'},
            @{Evidence='malformed policy';Expected='PASS';Dependent='UNVERIFIED'},
            @{Evidence='empty settings';Expected='PASS';Dependent='UNVERIFIED'},
            @{Evidence='malformed admission rule';Expected='PASS';Dependent='UNVERIFIED'},
            @{Evidence='restrictions absent';Expected='PASS';Dependent='FAIL'}
        ) {
            switch ($Evidence) {
                absent {$fixture['/repos/example/app/environments']=New-ApiSuccess @{environments=@();total_count=0}}
                inaccessible {$fixture['/repos/example/app/environments']=New-ApiFailure 404}
                'detail absent' {$fixture['/repos/example/app/environments/app-dev']=New-ApiSuccess $null}
                'malformed list' {$fixture['/repos/example/app/environments']=New-ApiSuccess @{environments=@($null);total_count=1}}
                'malformed policy' {$fixture['/repos/example/app/environments/app-dev'].data.deployment_branch_policy=42}
                'empty settings' {$fixture['/repos/example/app/environments/app-dev']=New-ApiSuccess @{}}
                'malformed admission rule' {$fixture['/repos/example/app/environments/app-dev/deployment-branch-policies']=New-ApiSuccess @{branch_policies=@($null);total_count=1}}
                'restrictions absent' {$fixture['/repos/example/app/environments/app-dev'].data.deployment_branch_policy=$null}
            }
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -CEQ github.environment.exists).status | Should -Be $Expected
            ($r.checks | Where-Object id -CEQ github.environment.restrictions).status | Should -Be $Dependent
            ($r.checks | Where-Object id -CEQ github.runner.workflow-access).status | Should -Be PASS
            @($r.checks | Where-Object id -CEQ github.inspection).Count | Should -Be 0
        }
        It 'preserves confirmed security failures despite missing runner configuration' {
            $config.RunnerGroup='';$config.RunnerLabels=''
            $fixture['/repos/example/app/branches/master/protection'].data.enforce_admins.enabled=$false
            $record=Get-FixtureProtectedConfiguration $fixture;$record.targets[0].targetId='wrong';Set-FixtureProtectedConfiguration $fixture $record
            $fixture['/repos/example/app'].data.visibility='public';$fixture['/repos/example/app'].data.private=$false
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            foreach ($id in @('branch.bypass','routing.target','runner.group','runner.labels')) {
                ($r.checks | Where-Object id -CEQ "github.$id").status | Should -Be FAIL
            }
            ($r.checks | Where-Object id -CEQ github.runner.public-risk).status | Should -Be UNVERIFIED
        }
        It 'retains protected cross-channel scope failures without expected runner configuration: <Scope>' -ForEach @(
            @{Scope='runnerGroup'},@{Scope='targetId'},@{Scope='environment'}
        ) {
            $config.RunnerGroup=''
            $record=Get-FixtureProtectedConfiguration $fixture
            $other=@{channel='Production';targetId='app-prod';standingAuthorizationId='app-prod';environment='app-prod';runnerGroup='app-prod';runnerLabels=@('self-hosted','Windows','X64');enabled=$false;runnerAdmissionReady=$false}
            $other[$Scope]=$record.targets[0][$Scope]
            $record.targets+=@($other);Set-FixtureProtectedConfiguration $fixture $record
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -CEQ github.routing.channel).status | Should -Be FAIL
            $r.github_status | Should -Be FAIL
        }
        It 'skips channel separation when the protected configuration has no selected channel route' {
            $record=Get-FixtureProtectedConfiguration $fixture;$record.targets[0].channel='Production'
            $record.targets[0].targetId='app-prod';$record.targets[0].environment='app-prod';$record.targets[0].runnerGroup='app-prod'
            Set-FixtureProtectedConfiguration $fixture $record
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -CEQ github.routing.target).status | Should -Be FAIL
            # No selected protected route exists to establish channel separation.
            ($r.checks | Where-Object id -CEQ github.routing.channel).status | Should -Be SKIPPED
        }
        It 'retains findings and blocks READY on unexpected inspection exceptions' {
            Mock Get-ClcDeploymentPrerequisiteRunnerChecks {throw 'PRIVATE-INTERNAL-ERROR'}
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -CEQ github.repository.identity).status | Should -Be PASS
            ($r.checks | Where-Object id -CEQ github.environment.exists).status | Should -Be PASS
            ($r.checks | Where-Object id -CEQ github.inspection).status | Should -Be UNVERIFIED
            $r.github_status | Should -Be UNVERIFIED;$r.ready | Should -BeFalse
            ($r | ConvertTo-Json -Depth 12) | Should -Not -Match 'PRIVATE-INTERNAL-ERROR'
            (Merge-ClcDeploymentPrerequisiteReports $r (New-ClcDeploymentPrerequisiteReport $config @(New-PassingStageChecks host)) -HostJobResult success).ready | Should -BeFalse
        }
        It 'preserves emitted runner findings when a later runner observation unexpectedly throws' {
            Mock Get-ClcDeploymentPrerequisiteRunnerChecks {
                New-ClcDeploymentPrerequisiteCheck github.runner.group FAIL 'Confirmed missing group.' 'Provision independently.'
                throw 'PRIVATE-INTERNAL-ERROR'
            }
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -CEQ github.runner.group).status | Should -Be FAIL
            ($r.checks | Where-Object id -CEQ github.inspection).status | Should -Be UNVERIFIED
            ($r.checks | Where-Object id -CEQ github.environment.exists).status | Should -Be PASS
            $r.github_status | Should -Be FAIL
        }
        It 'produces a valid contract-3 NOT READY report for a completely unconfigured target' {
            $config.RunnerGroup='';$config.RunnerLabels='';$config.SharedRevision='';$config.ActivationState='missing-or-empty'
            $fixture['/repos/example/app/branches/master'].data.protected=$false
            $fixture['/repos/example/app/branches/master/protection']=New-ApiFailure 404
            $fixture['/repos/example/app/rulesets?includes_parents=true']=New-ApiSuccess @()
            $fixture['/repos/example/app/environments']=New-ApiSuccess @{environments=@();total_count=0}
            foreach ($path in @('release','deploy-release')) {$fixture[("/repos/example/app/contents/.github/workflows/$path.yml?ref="+('b'*40))]=New-ApiFailure 404}
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            $r.contract_version | Should -Be 3;$r.subject.observed_commit | Should -Be ('b'*40)
            ($r.checks | Where-Object id -CEQ github.repository.identity).status | Should -Be PASS
            foreach ($id in @('runner.group','runner.labels','environment.exists','workflow.producer','workflow.caller','branch.protection','tags.creation','tags.update','tags.deletion')) {
                $row=$r.checks | Where-Object id -CEQ "github.$id"
                $row.status | Should -Be FAIL;$row.action | Should -Not -BeNullOrEmpty
            }
            foreach ($id in @('runner.repository-access','runner.workflow-access','environment.restrictions','workflow.release-trigger','workflow.completion-trigger','workflow.shared-identity','workflow.manual-selection')) {
                $row=$r.checks | Where-Object id -CEQ "github.$id"
                $row.status | Should -Be SKIPPED;$row.reason | Should -Not -BeNullOrEmpty
            }
            @($r.checks | Where-Object id -CEQ github.inspection).Count | Should -Be 0
            ConvertTo-ClcDeploymentPrerequisiteStageReport $r | Should -Not -BeNullOrEmpty
            $merged=Merge-ClcDeploymentPrerequisiteReports $r $null
            $merged.github_status | Should -Be FAIL;$merged.host_status | Should -Be UNVERIFIED;$merged.ready | Should -BeFalse
            ($merged.checks | Where-Object id -CEQ host.stage).status | Should -Be SKIPPED
            (Format-ClcDeploymentPrerequisiteSummary $merged) | Should -Match '^# NOT READY'
            $path=Join-Path $TestDrive 'unconfigured.json';$r | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path
            & (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $PSScriptRoot '../Merge-DeploymentReadiness.ps1') -GitHubReportPath $path
            $LASTEXITCODE | Should -Be 1
        }
    }
}

Describe 'Actual hosted diagnostic entry-point binding' {
    BeforeAll {. (Join-Path $PSScriptRoot 'Fixtures.ps1')}
    BeforeEach {
        Mock Import-Module {}
        Mock Invoke-ClcDeploymentPrerequisiteGitHubInspection {
            param($Config)
            New-ClcDeploymentPrerequisiteReport $Config @(
                New-ClcDeploymentPrerequisiteCheck github.runner.group FAIL 'Missing group.' 'Configure the dedicated group.'
            )
        }
        Mock Publish-ClcDeploymentPrerequisiteReport {}
    }
    It 'accepts an empty group and preserves <Labels> labels at the actual script boundary' -ForEach @(
        @{Labels='omitted';Expected='self-hosted,Windows,X64'},@{Labels='explicitly empty';Expected=''}
    ) {
        $parameters=@{ApplicationId='app';TargetId='app-dev';EnvironmentName='app-dev';RunnerGroup='';YamlAssemblyPath=$env:CLC_PREREQUISITES_YAML;ReportPath=(Join-Path $TestDrive 'entry.json')}
        if ($Labels -ceq 'explicitly empty') {$parameters.RunnerLabels=''}
        & (Join-Path $PSScriptRoot '../../Validate-DeploymentPrerequisites.ps1') @parameters
        $LASTEXITCODE | Should -Be 0
        Should -Invoke Invoke-ClcDeploymentPrerequisiteGitHubInspection -Times 1 -Exactly -ParameterFilter {$Config.RunnerGroup -ceq '' -and $Config.RunnerLabels -ceq $Expected}
        (Get-Content -LiteralPath $parameters.ReportPath -Raw | ConvertFrom-Json).contract_version | Should -Be 3
    }
}

BeforeDiscovery {Import-Module (Join-Path $PSScriptRoot '../Validation.psm1') -Force}

Describe 'Commissioning GitHub observations' {
    InModuleScope Validation {
        BeforeAll {. (Join-Path $PSScriptRoot 'Fixtures.ps1')}
        BeforeEach {
            $config=New-ValidationConfig;$fixture=New-ValidationFixture
            Mock Get-ClcDeploymentPrerequisiteApi {
                param($Context,$Path)
                $key=$Path -replace '[?&]per_page=(30|100)&page=\d+$',''
                if (-not $fixture.ContainsKey($key)) {return New-ApiFailure 403}
                $fixture[$key]
            }
        }
        It 'passes sufficient initial GitHub infrastructure without inventing host observations or requiring activation' {
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            $r.github_status | Should -BeExactly PASS -Because ($r.checks | ConvertTo-Json -Depth 6)
            $r.host_status | Should -BeExactly UNVERIFIED
            $r.ready | Should -BeFalse
            @($r.checks | Where-Object category -EQ host).Count | Should -Be 0
            ($r.checks | Where-Object id -EQ github.routing.activation).status | Should -Be UNVERIFIED
            ($r.checks | Where-Object id -EQ github.routing.activation).required | Should -BeFalse
            ($r.checks | Where-Object id -EQ github.runner.workflow-access).status | Should -Be PASS
            ($r.checks | Where-Object id -EQ github.runner.enterprise).required | Should -BeFalse
        }
        It 'does not require PR reviews or CODEOWNERS to protect the integration source' {
            $fixture['/repos/example/app/branches/master/protection'].data.Remove('required_pull_request_reviews')
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            $r.github_status | Should -Be PASS
            ($r.checks | Where-Object id -EQ github.branch.reviews).required | Should -BeFalse
        }
        It 'reports optional configured review controls' {
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -EQ github.branch.reviews).detail | Should -Match 'configured'
        }
        It 'rejects a missing critical branch restriction: <Field>' -ForEach @(
            @{Field='allow_force_pushes';Id='github.branch.force-push'},@{Field='allow_deletions';Id='github.branch.deletion'},@{Field='required_status_checks';Id='github.branch.required-checks'}
        ) {
            $fixture['/repos/example/app/branches/master/protection'].data.Remove($Field)
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -EQ $Id).status | Should -Be FAIL
            $r.github_status | Should -Be FAIL
        }
        It 'does not treat denied administrative evidence as a confirmed absence' {
            $fixture['/repos/example/app/branches/master/protection']=New-ApiFailure 403
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -EQ github.branch.required-checks).status | Should -Be UNVERIFIED
            $r.github_status | Should -Be UNVERIFIED
        }
        It 'uses the configured main branch rather than hardcoding master' {
            $config.IntegrationBranch='main'
            foreach ($key in @($fixture.Keys)) {$fixture[$key.Replace('/master','/main')]= $fixture[$key]}
            $fixture['/repos/example/app/environments/app-dev/deployment-branch-policies'].data.branch_policies[0].name='main'
            $group=$fixture['/orgs/example/actions/runner-groups/7'].data
            $group.selected_workflows[1]=$group.selected_workflows[1].Replace('/master','/main')
            $record=Get-FixtureProtectedConfiguration $fixture;$record.integrationBranch='main';Set-FixtureProtectedConfiguration $fixture $record
            (Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML).github_status | Should -Be PASS
        }
        It 'rejects ineffective or overbroad tag policy: <Kind>' -ForEach @(@{Kind='evaluate'},@{Kind='empty'},@{Kind='role-bypass'},@{Kind='narrow'}) {
            $rule=$fixture['/repos/example/app/rulesets/12?includes_parents=true'].data
            switch ($Kind) {
                evaluate {$rule.enforcement='evaluate'}
                empty {$rule.rules=@()}
                'role-bypass' {$rule.bypass_actors=@(@{actor_type='RepositoryRole';actor_id=5})}
                narrow {$rule.conditions.ref_name.include=@('refs/tags/v1*')}
            }
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            $r.github_status | Should -Be FAIL
        }
        It 'does not approximate complex excluded tag patterns' {
            $fixture['/repos/example/app/rulesets/12?includes_parents=true'].data.conditions.ref_name.exclude=@('refs/tags/v1*')
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -EQ github.tags.update).status | Should -Be UNVERIFIED
        }
        It 'accepts DEV-only protection without requiring other release channels' {
            $fixture['/repos/example/app/rulesets/12?includes_parents=true'].data.conditions.ref_name.include=@('refs/tags/v*-dev.*')
            (Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML).github_status | Should -Be PASS
        }
        It 'rejects incorrect or excessive exact workflow allowlists: <Kind>' -ForEach @(@{Kind='extra'},@{Kind='caller'},@{Kind='wrong-sha'},@{Kind='disabled'}) {
            $g=$fixture['/orgs/example/actions/runner-groups/7'].data
            switch ($Kind) {
                extra {$g.selected_workflows+='example/app/.github/workflows/other.yml@refs/heads/master'}
                caller {$g.selected_workflows[0]='example/app/.github/workflows/deploy-release.yml@refs/heads/master'}
                'wrong-sha' {$g.selected_workflows[0]=$g.selected_workflows[0].Replace('a'*40,'c'*40)}
                disabled {$g.restricted_to_workflows=$false}
            }
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -EQ github.runner.workflow-access).status | Should -Be FAIL
        }
        It 'keeps excess runner authority FAIL even when protected config is inaccessible' {
            $fixture[('/repos/example/app/contents/.clc/release.json?ref='+('b'*40))]=New-ApiFailure
            $fixture['/orgs/example/actions/runner-groups/7'].data.selected_workflows+='example/app/.github/workflows/other.yml@refs/heads/master'
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -EQ github.runner.workflow-access).status | Should -Be FAIL
        }
        It 'classifies inaccessible workflow allowlists as UNVERIFIED' {
            $fixture['/orgs/example/actions/runner-groups/7'].data.Remove('selected_workflows')
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -EQ github.runner.workflow-access).status | Should -Be UNVERIFIED
        }
        It 'requires enterprise ownership evidence for cross-organization shared admission: <Kind>' -ForEach @(@{Kind='non-inherited'},@{Kind='unknown'}) {
            $g=$fixture['/orgs/example/actions/runner-groups/7'].data
            if ($Kind -eq 'unknown') {$g.Remove('inherited')} else {$g.inherited=$false}
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -EQ github.runner.workflow-access).status | Should -Be $(if ($Kind -eq 'unknown') {'UNVERIFIED'} else {'FAIL'})
        }
        It 'rejects wrong shared workflow source or orchestration identity: <Kind>' -ForEach @(@{Kind='caller'},@{Kind='config'},@{Kind='producer'},@{Kind='job-route'}) {
            switch ($Kind) {
                caller {$key='/repos/example/app/contents/.github/workflows/deploy-release.yml?ref='+('b'*40);$text=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($fixture[$key].data.content));$fixture[$key]=New-WorkflowFile ($text.Replace('a'*40,'c'*40))}
                config {$p=Get-FixtureProtectedConfiguration $fixture;$p.orchestration.sharedRevision='c'*40;Set-FixtureProtectedConfiguration $fixture $p}
                producer {$p=Get-FixtureProtectedConfiguration $fixture;$p.producer.workflowPath='.github/workflows/wrong.yml';Set-FixtureProtectedConfiguration $fixture $p}
                'job-route' {$key='/repos/clcdpc/clc-deployment/contents/.github/workflows/application-deploy.yml?ref='+('a'*40);$fixture[$key]=New-WorkflowFile 'on: workflow_call' }
            }
            (Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML).github_status | Should -Be FAIL
        }
        It 'rejects configuration that the shared workflow cannot accept: <Kind>' -ForEach @(
            @{Kind='toolkit contract'},@{Kind='trusted files'},@{Kind='producer job'},@{Kind='unknown field'}
        ) {
            $p=Get-FixtureProtectedConfiguration $fixture
            switch ($Kind) {
                'toolkit contract' {$p.requiredToolkitContractVersion=1}
                'trusted files' {$p.trustedFiles=@('.clc/release.json','.github/workflows/release.yml')}
                'producer job' {$p.producer.job='invalid job?'}
                'unknown field' {$p.unexpected=$true}
            }
            Set-FixtureProtectedConfiguration $fixture $p
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -EQ github.workflow.shared-identity).status | Should -Be FAIL
            $r.ready | Should -BeFalse
        }
        It 'rejects contradictory protected target routing: <Field>' -ForEach @(@{Field='targetId'},@{Field='environment'},@{Field='runnerGroup'},@{Field='runnerLabels'}) {
            $p=Get-FixtureProtectedConfiguration $fixture
            $p.targets[0][$Field]=if ($Field -eq 'runnerLabels') {@('self-hosted','Windows','X64','wrong')} else {'wrong'}
            Set-FixtureProtectedConfiguration $fixture $p
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -EQ github.routing.target).status | Should -Be FAIL
        }
        It 'independently supports the explicitly scoped channel <Channel>' -ForEach @(@{Channel='DEV'},@{Channel='Test'},@{Channel='Production'}) {
            $config.DeploymentChannel=$Channel
            $p=Get-FixtureProtectedConfiguration $fixture;$p.targets[0].channel=$Channel;$p.sourcePolicy.allowTestTags=($Channel -eq 'Test');Set-FixtureProtectedConfiguration $fixture $p
            (Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML).github_status | Should -Be PASS
        }
        It 'cannot infer Test authority from a DEV target or a disabled Test source policy: <Kind>' -ForEach @(@{Kind='DEV target'},@{Kind='disabled Test'}) {
            $config.DeploymentChannel='Test'
            if ($Kind -eq 'disabled Test') {$p=Get-FixtureProtectedConfiguration $fixture;$p.targets[0].channel='Test';Set-FixtureProtectedConfiguration $fixture $p}
            (Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML).github_status | Should -Be FAIL
        }
        It 'rejects extra environment tag admission and broad runner repository access' {
            $fixture['/repos/example/app/environments/app-dev/deployment-branch-policies'].data.branch_policies+=@{name='v*';type='tag'}
            $fixture['/repos/example/app/environments/app-dev/deployment-branch-policies'].data.total_count=2
            $fixture['/orgs/example/actions/runner-groups/7'].data.visibility='all'
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -EQ github.environment.restrictions).status | Should -Be FAIL
            ($r.checks | Where-Object id -EQ github.runner.repository-access).status | Should -Be FAIL
        }
        It 'requires an online group runner with the expected labels' {
            $fixture['/orgs/example/actions/runner-groups/7/runners'].data.runners[0].status='offline'
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -EQ github.runner.labels).status | Should -Be FAIL
        }
        It 'treats dispatch as a request and rejects an always-automatic dispatch caller' {
            $key='/repos/example/app/contents/.github/workflows/deploy-release.yml?ref='+('b'*40)
            $fixture[$key]=New-WorkflowFile "on: {workflow_dispatch: {}}`njobs: {deployment: {uses: clcdpc/clc-deployment/.github/workflows/application-deploy.yml@$('a'*40), with: {automatic: true}}}"
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -EQ github.workflow.manual-selection).status | Should -Be FAIL
            ($r.checks | Where-Object id -EQ github.workflow.manual-dispatch).required | Should -BeFalse
        }
        It 'preserves malformed or inaccessible observations conservatively without private data' {
            $fixture['/repos/example/app/environments/app-dev'].data=42
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            $r.ready | Should -BeFalse
            ($r.checks | Where-Object id -EQ github.inspection).status | Should -Be UNVERIFIED
        }
    }
}

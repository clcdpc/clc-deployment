BeforeDiscovery {Import-Module (Join-Path $PSScriptRoot '../Validation.psm1') -Force}

Describe 'Bounded data-only observation and input contracts' {
    InModuleScope Validation {
        BeforeAll {. (Join-Path $PSScriptRoot 'Fixtures.ps1');Add-Type -LiteralPath $env:CLC_PREREQUISITES_YAML}
        BeforeEach {
            $config=New-ValidationConfig;$fixture=New-ValidationFixture;$context=@{}
            Mock Get-ClcDeploymentPrerequisiteApi {
                param($Context,$Path)
                $key=$Path -replace '[?&]per_page=(30|100)&page=\d+$',''
                if (-not $fixture.ContainsKey($key)) {return New-ApiFailure 403}
                $fixture[$key]
            }
        }
        It 'rejects invalid selectors before any API request: <Key>' -ForEach @(
            @{Key='Repository';Value='owner/repo/../../settings'},@{Key='EnvironmentName';Value=''},
            @{Key='EnvironmentName';Value="app`ninjected"},@{Key='IntegrationBranch';Value='master?evil'},
            @{Key='IntegrationBranch';Value='../master'},@{Key='ReleaseWorkflow';Value='https://attacker.invalid/run.ps1'},
            @{Key='DeploymentWorkflow';Value='.github/workflows/../run.yml'},@{Key='RunnerGroup';Value='../unsafe'},
            @{Key='RunnerGroup';Value=42},@{Key='ActivationVariable';Value='GITHUB_TOKEN'},
            @{Key='DeploymentChannel';Value='production'},@{Key='TargetId';Value='../../other'},
            @{Key='ApplicationId';Value=''},@{Key='SharedRevision';Value='master'},
            @{Key='DiagnosticWorkflow';Value='.github/workflows/../evil.yml'}
        ) {
            $config[$Key]=$Value
            {Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML} | Should -Throw
            Should -Invoke Get-ClcDeploymentPrerequisiteApi -Times 0 -Exactly
        }
        It 'bounds pagination rather than calling an incomplete list absent' {
            Mock Get-ClcDeploymentPrerequisiteApi {New-ApiSuccess (@(1..100 | ForEach-Object {@{id=$_}}))}
            $r=Get-ClcDeploymentPrerequisiteCollection $context '/repos/example/app/rulesets'
            $r.ok | Should -BeFalse
            Should -Invoke Get-ClcDeploymentPrerequisiteApi -Times 20 -Exactly
        }
        It 'retains single-item and empty collection types' {
            (Get-ClcDeploymentPrerequisiteCollection $context '/repos/example/app/rules/branches/master').data.Count | Should -Be 0
            (Get-ClcDeploymentPrerequisiteCollection $context '/repos/example/app/rulesets?includes_parents=true').data.Count | Should -Be 1
        }
        It 'rejects inconsistent collection totals' {
            $fixture['/repos/example/app/environments'].data.total_count=2
            (Get-ClcDeploymentPrerequisiteCollection $context '/repos/example/app/environments' environments).ok | Should -BeFalse
        }
        It 'rejects missing or malformed workflow file evidence: <Kind>' -ForEach @(
            @{Kind='size type'},@{Kind='length mismatch'},@{Kind='oversize'},@{Kind='encoding'},@{Kind='invalid UTF8'}
        ) {
            $key='/repos/example/app/contents/.github/workflows/release.yml?ref='+('b'*40)
            switch ($Kind) {
                'size type' {$fixture[$key].data.size='12'}
                'length mismatch' {$fixture[$key].data.size=1}
                oversize {$fixture[$key]=New-WorkflowFile ('x'*262145)}
                encoding {$fixture[$key].data.encoding='binary'}
                'invalid UTF8' {$fixture[$key].data.size=1;$fixture[$key].data.content='/w=='}
            }
            (Get-ClcDeploymentPrerequisiteFile $context $config.Repository $config.ReleaseWorkflow ('b'*40)).ok | Should -BeFalse
        }
        It 'never constructs objects or follows YAML aliases for consumer policy: <Kind>' -ForEach @(
            @{Kind='alias';Text="on: push`njobs: {a: &x {run: never}, b: *x}"},
            @{Kind='tag';Text='!!System.IO.FileInfo never'},
            @{Kind='merge';Text='jobs: {<<: {run: never}}'},
            @{Kind='duplicate';Text='jobs: {}, jobs: {}'},
            @{Kind='depth';Text=(('['*40)+'never'+(']'*40))},
            @{Kind='size';Text=('x'*262145)}
        ) {
            {ConvertFrom-ClcDeploymentPrerequisiteYaml $Text} | Should -Throw
        }
        It 'classifies malformed workflow YAML as FAIL and unsupported aliases as UNVERIFIED' {
            $key='/repos/example/app/contents/.github/workflows/release.yml?ref='+('b'*40)
            $fixture[$key]=New-WorkflowFile 'jobs: [unterminated'
            (Get-ClcDeploymentPrerequisiteWorkflowObservation $context $config $config.ReleaseWorkflow ('b'*40) github.workflow.producer).check.status | Should -Be FAIL
            $fixture[$key]=New-WorkflowFile "on: push`njobs: {a: &x {runs-on: windows-2022}, b: *x}"
            (Get-ClcDeploymentPrerequisiteWorkflowObservation $context $config $config.ReleaseWorkflow ('b'*40) github.workflow.producer).check.status | Should -Be UNVERIFIED
        }
        It 'does not mistake comments or scripts for a producer trigger' {
            $key='/repos/example/app/contents/.github/workflows/release.yml?ref='+('b'*40)
            $fixture[$key]=New-WorkflowFile "# push tags v*`non: workflow_dispatch`njobs: {build: {runs-on: windows-2022, steps: [{run: 'echo push tags v*'}]}}"
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -EQ github.workflow.release-trigger).status | Should -Be FAIL
        }
        It 'uses explicit administrative authentication without falling back to ordinary credentials' {
            $original=$env:CLC_GITHUB_INSPECTION_TOKEN;$standard=$env:GH_TOKEN
            $client=[Net.Http.HttpClient]::new()
            try {
                $env:GH_TOKEN='synthetic-standard';$env:CLC_GITHUB_INSPECTION_TOKEN=''
                {Set-ClcDeploymentPrerequisiteAuthentication $client Administrative} | Should -Throw
                $env:CLC_GITHUB_INSPECTION_TOKEN='synthetic-administrative'
                Set-ClcDeploymentPrerequisiteAuthentication $client Administrative
                $client.DefaultRequestHeaders.Authorization.Parameter | Should -Be synthetic-administrative
                Set-ClcDeploymentPrerequisiteAuthentication $client Standard
                $client.DefaultRequestHeaders.Authorization.Parameter | Should -Be synthetic-standard
            } finally {$client.Dispose();$env:GH_TOKEN=$standard;$env:CLC_GITHUB_INSPECTION_TOKEN=$original}
        }
    }
}

Describe 'Observable public/private and repository admission restrictions' {
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
        It 'requires public access appropriate to the verified caller <Visibility> / <Allows>' -ForEach @(
            @{Visibility='private';Allows=$false;Expected='PASS'},@{Visibility='private';Allows=$true;Expected='FAIL'},
            @{Visibility='public';Allows=$true;Expected='PASS'},@{Visibility='public';Allows=$false;Expected='FAIL'}
        ) {
            $fixture['/repos/example/app'].data.visibility=$Visibility;$fixture['/repos/example/app'].data.private=($Visibility -eq 'private')
            $fixture['/orgs/example/actions/runner-groups/7'].data.allows_public_repositories=$Allows
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -EQ github.runner.repository-access).status | Should -Be $Expected
            if ($Visibility -eq 'public' -and $Allows) {
                ($r.checks | Where-Object id -EQ github.runner.public-risk).required | Should -BeFalse
                $r.github_status | Should -Be PASS
            }
        }
        It 'supports each typed repository visibility observation <Kind>' -ForEach @(@{Kind='private flag'},@{Kind='explicit visibility'}) {
            if ($Kind -eq 'private flag') {$fixture['/repos/example/app'].data.Remove('visibility')} else {$fixture['/repos/example/app'].data.Remove('private')}
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -EQ github.runner.repository-access).status | Should -Be PASS
        }
        It 'never coerces malformed or contradictory repository visibility: <Kind>' -ForEach @(
            @{Kind='contradictory'},@{Kind='string private'},@{Kind='internal'},@{Kind='missing'},@{Kind='wrong repository'}
        ) {
            $data=$fixture['/repos/example/app'].data
            switch ($Kind) {
                contradictory {$data.private=$false}
                'string private' {$data.private='false'}
                internal {$data.visibility='internal'}
                missing {$data.Remove('visibility');$data.Remove('private')}
                'wrong repository' {$data.full_name='attacker/app'}
            }
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            $r.github_status | Should -Not -Be PASS
            $r.ready | Should -BeFalse
        }
        It 'rejects additional selected repositories' {
            $fixture['/orgs/example/actions/runner-groups/7/repositories'].data.repositories+=@{full_name='other/app'}
            $fixture['/orgs/example/actions/runner-groups/7/repositories'].data.total_count=2
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -EQ github.runner.repository-access).status | Should -Be FAIL
        }
        It 'keeps inaccessible selected repository settings UNVERIFIED' {
            $fixture['/orgs/example/actions/runner-groups/7/repositories']=New-ApiFailure 403
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -EQ github.runner.repository-access).status | Should -Be UNVERIFIED
        }
        It 'makes missing group evidence FAIL only after a complete accessible list' {
            $fixture['/orgs/example/actions/runner-groups'].data.runner_groups=@();$fixture['/orgs/example/actions/runner-groups'].data.total_count=0
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -EQ github.runner.group).status | Should -Be FAIL
            $fixture['/orgs/example/actions/runner-groups']=New-ApiFailure 403
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -EQ github.runner.group).status | Should -Be UNVERIFIED
        }
    }
}

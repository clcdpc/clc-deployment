BeforeDiscovery {
    $modulePath=Join-Path $PSScriptRoot '../Validation.psm1'
    Import-Module $modulePath -Force
}

Describe 'Read-only deployment prerequisites diagnostics' {
    InModuleScope Validation {
        BeforeAll {
            . (Join-Path $PSScriptRoot 'Fixtures.ps1')
            $script:assembly=$env:CLC_PREREQUISITES_YAML
        }
        BeforeEach {
            $script:config=New-ValidationConfig
            $script:fixture=New-ValidationFixture
            $script:seen=[Collections.Generic.List[string]]::new()
            Mock Get-DpApi {
                param($Path)
                $script:seen.Add($Path)
                $key=$Path -replace '[?&]per_page=(30|100)&page=\d+$',''
                if (-not $script:fixture.ContainsKey($key)) { throw "Unexpected test API path: $key" }
                return $script:fixture[$key]
            }
        }

        It 'reports a fully configured GitHub fixture honestly without qualifying the host' {
            $report=Invoke-DpValidation $config $assembly
            $report.failed_count | Should -Be 0
            $report.passed_count | Should -BeGreaterThan 15
            $report.unverified_count | Should -BeGreaterThan 7
            $report.ready | Should -BeFalse
            $report.exit_code | Should -Be 0
            $report.observed_commit | Should -Be ('b'*40)
            @($report.results | Where-Object name -EQ 'Incomplete configuration observation').Count | Should -Be 0
            @($report.results | Where-Object { $_.status -ne 'PASS' -and (-not $_.action -or -not $_.detail) }).Count | Should -Be 0
            ($report.results | Where-Object name -EQ 'Privileged job environment binding').status | Should -Be PASS
            $script:seen | Should -Contain ('/repos/example/app/contents/.github/workflows/release.yml?ref='+('b'*40))
            $script:seen | Should -Not -Contain '/repos/clcdpc/clc-deployment'
        }

        It 'fails verified absent branch protections' {
            $fixture['/repos/example/app/branches/master'].data.protected=$false
            $fixture['/repos/example/app/branches/master/protection']=New-ApiFailure 404
            $report=Invoke-DpValidation $config $assembly
            ($report.results | Where-Object name -EQ 'Required pull requests').status | Should -Be FAIL
            ($report.results | Where-Object name -EQ 'Force pushes restricted').status | Should -Be FAIL
        }

        It 'combines active inherited branch rules when classic protection is inaccessible' {
            $fixture['/repos/example/app/branches/master/protection']=New-ApiFailure 403
            $fixture['/repos/example/app/rules/branches/master']=New-ApiSuccess @(
                @{ type='pull_request'; parameters=@{ required_approving_review_count=2; require_code_owner_review=$true } },
                @{ type='non_fast_forward' },@{ type='deletion' }
            )
            $report=Invoke-DpValidation $config $assembly
            ($report.results | Where-Object name -EQ 'Required independent reviews').status | Should -Be PASS
            ($report.results | Where-Object name -EQ 'Code-owner review enforced').status | Should -Be PASS
            ($report.results | Where-Object name -EQ 'Branch deletion restricted').status | Should -Be PASS
        }

        It 'does not infer review requirements from a protected branch flag' {
            $fixture['/repos/example/app/branches/master/protection']=New-ApiFailure 403
            $report=Invoke-DpValidation $config $assembly
            ($report.results | Where-Object name -EQ 'Required independent reviews').status | Should -Be UNVERIFIED
        }

        It 'reports inaccessible inherited branch rules as unverified' {
            $fixture['/repos/example/app/branches/master/protection']=New-ApiFailure 404
            $fixture['/repos/example/app/rules/branches/master']=New-ApiFailure 403
            $report=Invoke-DpValidation $config $assembly
            ($report.results | Where-Object name -EQ 'Required pull requests').status | Should -Be UNVERIFIED
        }

        It 'rejects missing tag rulesets' {
            $fixture['/repos/example/app/rulesets?includes_parents=true']=New-ApiSuccess @()
            $report=Invoke-DpValidation $config $assembly
            @($report.results | Where-Object { $_.name -like 'Release tag * restricted' -and $_.status -eq 'FAIL' }).Count | Should -Be 3
        }

        It 'does not pass tag restrictions from a ruleset name or a matching ref alone' {
            $fixture['/repos/example/app/rulesets/12?includes_parents=true'].data.rules=@(@{ type='required_signatures' })
            $report=Invoke-DpValidation $config $assembly
            @($report.results | Where-Object { $_.name -like 'Release tag * restricted' -and $_.status -eq 'FAIL' }).Count | Should -Be 3
        }

        It 'rejects evaluate-only tag rules' {
            $fixture['/repos/example/app/rulesets/12?includes_parents=true'].data.enforcement='evaluate'
            $report=Invoke-DpValidation $config $assembly
            ($report.results | Where-Object name -EQ 'Release tag update restricted').status | Should -Be FAIL
        }

        It 'does not pass broader tag pattern coverage from a narrower prefix' {
            $fixture['/repos/example/app/rulesets/12?includes_parents=true'].data.conditions.ref_name.include=@('refs/tags/v1*')
            $report=Invoke-DpValidation $config $assembly
            ($report.results | Where-Object name -EQ 'Release tag update restricted').status | Should -Be FAIL
        }

        It 'leaves nontrivial tag exclusions unverified rather than approximating fnmatch' {
            $fixture['/repos/example/app/rulesets/12?includes_parents=true'].data.conditions.ref_name.exclude=@('refs/tags/v1*')
            $report=Invoke-DpValidation $config $assembly
            ($report.results | Where-Object name -EQ 'Release tag update restricted').status | Should -Be UNVERIFIED
        }

        It 'separates tag creation protection from mutation protection' {
            $fixture['/repos/example/app/rulesets/12?includes_parents=true'].data.rules=@(@{ type='update' },@{ type='deletion' })
            $report=Invoke-DpValidation $config $assembly
            ($report.results | Where-Object name -EQ 'Release tag creation restricted').status | Should -Be FAIL
            ($report.results | Where-Object name -EQ 'Release tag deletion restricted').status | Should -Be PASS
        }

        It 'reports inaccessible inherited tag details as unverified' {
            $fixture['/repos/example/app/rulesets/12?includes_parents=true']=New-ApiFailure 404
            $report=Invoke-DpValidation $config $assembly
            ($report.results | Where-Object name -EQ 'Release tag update restricted').status | Should -Be UNVERIFIED
        }

        It 'rejects a missing environment only with a complete accessible list' {
            $fixture['/repos/example/app/environments']=New-ApiSuccess @{ environments=@(); total_count=0 }
            $report=Invoke-DpValidation $config $assembly
            ($report.results | Where-Object name -EQ 'Environment exists').status | Should -Be FAIL
        }

        It 'does not equate environment existence with protected deployment refs' {
            $fixture['/repos/example/app/environments/app-dev'].data.deployment_branch_policy=$null
            $report=Invoke-DpValidation $config $assembly
            ($report.results | Where-Object name -EQ 'Environment exists').status | Should -Be PASS
            ($report.results | Where-Object name -EQ 'Environment branch restrictions').status | Should -Be FAIL
        }

        It 'does not pass protected-branches-only as exact branch admission' {
            $fixture['/repos/example/app/environments/app-dev'].data.deployment_branch_policy=@{ protected_branches=$true; custom_branch_policies=$false }
            $report=Invoke-DpValidation $config $assembly
            ($report.results | Where-Object name -EQ 'Environment branch restrictions').status | Should -Be UNVERIFIED
        }

        It 'rejects tag or PR deployment policies for the trusted branch workflow' {
            $fixture['/repos/example/app/environments/app-dev/deployment-branch-policies'].data.branch_policies+=@{ name='v*'; type='tag' }
            $fixture['/repos/example/app/environments/app-dev/deployment-branch-policies'].data.total_count=2
            $report=Invoke-DpValidation $config $assembly
            ($report.results | Where-Object name -EQ 'Environment branch restrictions').status | Should -Be FAIL
        }

        It 'does not impose manual review on unattended deployments' {
            $fixture['/repos/example/app/environments/app-dev'].data.protection_rules=@()
            $report=Invoke-DpValidation $config $assembly
            @($report.results | Where-Object { $_.section -eq 'GitHub Environment' -and $_.status -eq 'FAIL' }).Count | Should -Be 0
        }

        It 'checks reviewers, self-review and administrator bypass when that model is selected' {
            $config.EnvironmentProtection='required-reviewers'
            $report=Invoke-DpValidation $config $assembly
            ($report.results | Where-Object name -EQ 'Required reviewers and no self-review').status | Should -Be PASS
            ($report.results | Where-Object name -EQ 'Environment administrator bypass disabled').status | Should -Be PASS
            $fixture['/repos/example/app/environments/app-dev'].data.protection_rules[0].prevent_self_review=$false
            $fixture['/repos/example/app/environments/app-dev'].data.can_admins_bypass=$true
            $report=Invoke-DpValidation $config $assembly
            ($report.results | Where-Object name -EQ 'Required reviewers and no self-review').status | Should -Be FAIL
            ($report.results | Where-Object name -EQ 'Environment administrator bypass disabled').status | Should -Be FAIL
        }

        It 'reports hidden bypass settings as unverified' {
            $config.EnvironmentProtection='required-reviewers'
            $fixture['/repos/example/app/environments/app-dev'].data.Remove('can_admins_bypass')
            $report=Invoke-DpValidation $config $assembly
            ($report.results | Where-Object name -EQ 'Environment administrator bypass disabled').status | Should -Be UNVERIFIED
        }

        It 'rejects a missing runner group with accessible organization settings' {
            $fixture['/orgs/example/actions/runner-groups']=New-ApiSuccess @{ runner_groups=@(); total_count=0 }
            $report=Invoke-DpValidation $config $assembly
            ($report.results | Where-Object name -EQ 'Restricted runner group').status | Should -Be FAIL
        }

        It 'reports inaccessible organization settings as unverified without requesting credentials' {
            $fixture['/orgs/example/actions/runner-groups']=New-ApiFailure 403
            $report=Invoke-DpValidation $config $assembly
            $row=$report.results | Where-Object name -EQ 'Restricted runner group'
            $row.status | Should -Be UNVERIFIED
            $row.action | Should -Match 'Self-hosted runners: read'
            $row.action | Should -Match 'no administrator credential'
        }

        It 'does not confuse selected repository access with workflow protection' {
            $fixture['/orgs/example/actions/runner-groups/7'].data.restricted_to_workflows=$false
            $report=Invoke-DpValidation $config $assembly
            ($report.results | Where-Object name -EQ 'Runner repository access').status | Should -Be PASS
            ($report.results | Where-Object name -EQ 'Runner selected-workflow access').status | Should -Be FAIL
        }

        It 'rejects extra selected workflows and tag pinned privileged code' {
            $fixture['/orgs/example/actions/runner-groups/7'].data.selected_workflows=@('example/app/.github/workflows/deploy-release.yml@refs/tags/v1')
            $report=Invoke-DpValidation $config $assembly
            ($report.results | Where-Object name -EQ 'Runner selected-workflow access').status | Should -Be FAIL
        }

        It 'requires all labels on one runner without claiming host installation or availability' {
            $fixture['/orgs/example/actions/runner-groups/7/runners'].data.runners=@(
                @{ labels=@(@{ name='self-hosted' },@{ name='Windows' }) },@{ labels=@(@{ name='X64' }) }
            )
            $fixture['/orgs/example/actions/runner-groups/7/runners'].data.total_count=2
            $report=Invoke-DpValidation $config $assembly
            ($report.results | Where-Object name -EQ 'Expected runner labels').status | Should -Be FAIL
        }

        It 'classifies disabled activation as a failure with an authorization-aware action' {
            $config.ActivationState='disabled'
            $report=Invoke-DpValidation $config $assembly
            ($report.results | Where-Object name -EQ 'Activation indicator').status | Should -Be FAIL
            ($report.results | Where-Object name -EQ 'Activation indicator').detail | Should -Match 'intentionally disabled'
            $report.ready | Should -BeFalse
        }

        It 'rejects an environment-scoped activation override without printing its value' {
            $fixture['/repos/example/app/environments/app-dev/variables'].data.variables=@(@{ name='CLC_DEPLOYMENT_ENABLED'; value='PRIVATE-DO-NOT-LOG' })
            $fixture['/repos/example/app/environments/app-dev/variables'].data.total_count=1
            $report=Invoke-DpValidation $config $assembly
            ($report.results | Where-Object name -EQ 'Environment activation override').status | Should -Be FAIL
            (Format-DpSummary $report) | Should -Not -Match 'PRIVATE-DO-NOT-LOG'
        }

        It 'reports production gating as unverified independently of activation' {
            $config.DeploymentChannel='Production'
            $report=Invoke-DpValidation $config $assembly
            ($report.results | Where-Object name -EQ 'Explicit production gate').status | Should -Be UNVERIFIED
        }

        It 'reports inaccessible environment variables as unverified' {
            $fixture['/repos/example/app/environments/app-dev/variables']=New-ApiFailure 403
            $report=Invoke-DpValidation $config $assembly
            ($report.results | Where-Object name -EQ 'Environment activation override').status | Should -Be UNVERIFIED
        }

        It 'finds an activation override on page two using the environment-variable 30-item limit' {
            Mock Get-DpApi {
                param($Path)
                if ($Path -like '*/variables?per_page=30&page=1') {
                    return New-ApiSuccess @{ total_count=31; variables=@(1..30 | ForEach-Object { @{ name="OTHER_$_"; value='private' } }) }
                }
                if ($Path -like '*/variables?per_page=30&page=2') {
                    return New-ApiSuccess @{ total_count=31; variables=@(@{ name='CLC_DEPLOYMENT_ENABLED'; value='private' }) }
                }
                $key=$Path -replace '[?&]per_page=(30|100)&page=\d+$',''
                return $script:fixture[$key]
            }
            $report=Invoke-DpValidation $config $assembly
            ($report.results | Where-Object name -EQ 'Environment activation override').status | Should -Be FAIL
            Should -Invoke Get-DpApi -Times 1 -Exactly -ParameterFilter { $Path -eq '/repos/example/app/environments/app-dev/variables?per_page=30&page=2' }
        }

        It 'does not report a partial administrative list as complete when total_count disagrees' {
            $fixture['/orgs/example/actions/runner-groups'].data.total_count=2
            $report=Invoke-DpValidation $config $assembly
            ($report.results | Where-Object name -EQ 'Restricted runner group').status | Should -Be UNVERIFIED
        }

        It 'rejects a missing workflow' {
            $fixture[('/repos/example/app/contents/.github/workflows/release.yml?ref='+('b'*40))]=New-ApiFailure 404
            $report=Invoke-DpValidation $config $assembly
            ($report.results | Where-Object name -EQ 'Release workflow present').status | Should -Be FAIL
        }

        It 'rejects invalid workflow YAML' {
            $fixture[('/repos/example/app/contents/.github/workflows/release.yml?ref='+('b'*40))]=New-WorkflowFile 'jobs: [unclosed'
            $report=Invoke-DpValidation $config $assembly
            ($report.results | Where-Object name -EQ 'Release workflow structure').status | Should -Be FAIL
        }

        It 'leaves YAML anchors unverified and never constructs application objects' {
            $fixture[('/repos/example/app/contents/.github/workflows/release.yml?ref='+('b'*40))]=New-WorkflowFile "on: push`njobs: &jobs`n  build: {runs-on: ubuntu-latest}"
            $report=Invoke-DpValidation $config $assembly
            ($report.results | Where-Object name -EQ 'Release workflow structure').status | Should -Be UNVERIFIED
        }

        It 'rejects routine deployment dispatch but permits fresh-build release dispatch' {
            $key='/repos/example/app/contents/.github/workflows/deploy-release.yml?ref='+('b'*40)
            $fixture[$key]=New-WorkflowFile "on: [workflow_dispatch]`njobs: {deploy: {runs-on: ubuntu-latest}}"
            $report=Invoke-DpValidation $config $assembly
            ($report.results | Where-Object name -EQ 'Routine deployment has no manual dispatch').status | Should -Be FAIL
            ($report.results | Where-Object name -EQ 'Version-tag release trigger').status | Should -Be PASS
        }

        It 'does not pass a workflow trigger from a comment or run script' {
            $key='/repos/example/app/contents/.github/workflows/release.yml?ref='+('b'*40)
            $fixture[$key]=New-WorkflowFile "on: workflow_dispatch`n# push: {tags: ['v*']}`njobs: {build: {runs-on: ubuntu-latest}}"
            $report=Invoke-DpValidation $config $assembly
            ($report.results | Where-Object name -EQ 'Version-tag release trigger').status | Should -Be FAIL
        }

        It 'does not turn insufficient API permissions into configuration failures' {
            foreach ($key in @($fixture.Keys)) { $fixture[$key]=New-ApiFailure 403 }
            $report=Invoke-DpValidation $config $assembly
            $report.failed_count | Should -Be 0
            $report.unverified_count | Should -BeGreaterThan 10
            $report.exit_code | Should -Be 0
        }

        It 'does not turn unexpected API failure status into missing prerequisites' {
            foreach ($key in @($fixture.Keys)) { $fixture[$key]=New-ApiFailure 503 }
            $report=Invoke-DpValidation $config $assembly
            $report.failed_count | Should -Be 0
            $report.ready | Should -BeFalse
            $report.unverified_count | Should -BeGreaterThan 10
        }

        It 'keeps malformed source metadata and runner label fields unverified' {
            $fixture['/repos/example/app/branches/master'].data=@{}
            $fixture['/orgs/example/actions/runner-groups/7/runners'].data.runners=@(@{})
            $report=Invoke-DpValidation $config $assembly
            ($report.results | Where-Object name -EQ 'Integration source inspection').status | Should -Be UNVERIFIED
            ($report.results | Where-Object name -EQ 'Expected runner labels').status | Should -Be UNVERIFIED
        }

        It 'fails strict mode after collecting a complete report' {
            $config.Strict=$true
            $config.ActivationState='disabled'
            $report=Invoke-DpValidation $config $assembly
            $report.exit_code | Should -Be 1
            $report.results.Count | Should -BeGreaterThan 25
            (Format-DpSummary $report) | Should -Match 'Deployment readiness: NOT READY'
        }

        It 'only reports ready when every requirement passes' {
            $results=[Collections.Generic.List[object]]::new()
            Add-DpResult $results 'Repository configuration' 'Example' PASS 'Verified'
            $config.Strict=$true
            $report=Complete-DpReport $config $results
            $report.ready | Should -BeTrue
            $report.exit_code | Should -Be 0
            Add-DpResult $results 'Host and toolkit' 'Unknown' UNVERIFIED 'No evidence' 'Verify independently'
            (Complete-DpReport $config $results).ready | Should -BeFalse
        }

        It 'rejects incorrect inputs before any API call' -ForEach @(
            @{ Key='Repository'; Value='owner/repo/../../settings' },
            @{ Key='EnvironmentName'; Value='' },
            @{ Key='EnvironmentName'; Value="app`ninjected" },
            @{ Key='IntegrationBranch'; Value='master?endpoint=evil' },
            @{ Key='IntegrationBranch'; Value='../master' },
            @{ Key='ReleaseWorkflow'; Value='https://attacker.invalid/run.ps1' },
            @{ Key='DeploymentWorkflow'; Value='.github/workflows/../run.yml' },
            @{ Key='RunnerGroup'; Value='' },
            @{ Key='RunnerLabels'; Value='self-hosted, Windows' },
            @{ Key='ActivationVariable'; Value='GITHUB_TOKEN' },
            @{ Key='DeploymentChannel'; Value='production' },
            @{ Key='EnvironmentProtection'; Value='none' }
        ) {
            $config[$Key]=$Value
            { Invoke-DpValidation $config $assembly } | Should -Throw
            Should -Invoke Get-DpApi -Times 0 -Exactly
        }

        It 'bounds pagination without treating an incomplete collection as absent' {
            Mock Get-DpApi { New-ApiSuccess (@(1..100 | ForEach-Object { @{ id=$_ } })) }
            $result=Get-DpCollection '/repos/example/app/rulesets'
            $result.ok | Should -BeFalse
            $result.reason | Should -Match 'incomplete'
            Should -Invoke Get-DpApi -Times 20 -Exactly
        }

        It 'preserves one-item and empty collections' {
            (Get-DpCollection '/repos/example/app/rules/branches/master').data.Count | Should -Be 0
            (Get-DpCollection '/repos/example/app/rulesets?includes_parents=true').data.Count | Should -Be 1
        }

        It 'never invokes external state mutation or consumer code' {
            Mock Invoke-WebRequest { throw 'External web command must not run' }
            Mock Invoke-RestMethod { throw 'External REST command must not run' }
            $report=Invoke-DpValidation $config $assembly
            $report.failed_count | Should -Be 0
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly
            $script:seen | ForEach-Object { $_ | Should -Match '^/(repos/example/app|orgs/example/actions/runner-groups)(/|\?|$)' }
            $source=Get-Content -LiteralPath (Join-Path $PSScriptRoot '../Validation.psm1') -Raw
            $source | Should -Not -Match '\.(PostAsync|PutAsync|DeleteAsync|PatchAsync)|Invoke-Expression|Start-Process|Invoke-ClcIisDeployment'
        }
    }
}

Describe 'Bounded GitHub GET transport without network access' {
    BeforeAll {
        Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
public sealed class DpFixtureHandler : HttpMessageHandler {
    public string Body = "[]";
    public HttpStatusCode Code = HttpStatusCode.OK;
    public bool ThrowTransport = false;
    public string LastMethod;
    public string LastUri;
    public int Count;
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) {
        Count++;
        LastMethod = request.Method.Method;
        LastUri = request.RequestUri.AbsoluteUri;
        if (ThrowTransport) throw new HttpRequestException("PRIVATE-DO-NOT-LOG");
        return Task.FromResult(new HttpResponseMessage(Code) { Content = new StringContent(Body) });
    }
}
'@
    }
    InModuleScope Validation {
        BeforeEach {
            $script:Requests=0
            $script:Timer=[Diagnostics.Stopwatch]::StartNew()
            $script:fake=[DpFixtureHandler]::new()
            $script:Client=[Net.Http.HttpClient]::new($script:fake)
            $script:Client.MaxResponseContentBufferSize=1024
        }
        AfterEach { $script:Client.Dispose(); $script:Timer.Stop() }

        It 'uses GET and the fixed GitHub API origin and preserves array JSON shapes' {
            $script:fake.Body='[{"id":1}]'
            $result=Get-DpApi '/repos/example/app/rulesets'
            $result.ok | Should -BeTrue
            ($result.data -is [array]) | Should -BeTrue
            $result.data.Count | Should -Be 1
            $script:fake.LastMethod | Should -Be GET
            $script:fake.LastUri | Should -Be 'https://api.github.com/repos/example/app/rulesets'
            $script:fake.Body='[]'
            (Get-DpApi '/repos/example/app/rulesets').data.Count | Should -Be 0
        }

        It 'suppresses raw response bodies on errors' -ForEach @(401,403,404,429,500,503,302) {
            $script:fake.Code=[Net.HttpStatusCode]$_
            $script:fake.Body='PRIVATE-DO-NOT-LOG'
            $result=Get-DpApi '/repos/example/app/rulesets'
            $result.ok | Should -BeFalse
            $result.code | Should -Be $_
            ($result | ConvertTo-Json) | Should -Not -Match 'PRIVATE-DO-NOT-LOG'
            $script:fake.Count | Should -Be 1
        }

        It 'classifies transport, JSON and response bounds without exposing private exceptions' {
            $script:fake.ThrowTransport=$true
            $result=Get-DpApi '/repos/example/app/rulesets'
            $result.ok | Should -BeFalse
            $result.code | Should -Be 0
            ($result | ConvertTo-Json) | Should -Not -Match 'PRIVATE-DO-NOT-LOG'
            $script:fake.ThrowTransport=$false
            $script:fake.Body='invalid-json'
            (Get-DpApi '/repos/example/app/rulesets').ok | Should -BeFalse
            $script:fake.Body=' ' * 2048
            (Get-DpApi '/repos/example/app/rulesets').ok | Should -BeFalse
        }

        It 'rejects arbitrary endpoints before sending a request' {
            { Get-DpApi 'https://attacker.invalid/collect' } | Should -Throw
            { Get-DpApi '/repos/example/app?x=bad#fragment' } | Should -Throw
            $script:fake.Count | Should -Be 0
        }

        It 'stops when the request or overall time budget is exhausted' {
            $script:Requests=150
            (Get-DpApi '/repos/example/app/rulesets').ok | Should -BeFalse
            $script:fake.Count | Should -Be 0
            $script:Requests=0
            $script:Timer=[pscustomobject]@{ Elapsed=[pscustomobject]@{ TotalSeconds=241 } }
            $script:Timer | Add-Member -MemberType ScriptMethod -Name Stop -Value {}
            (Get-DpApi '/repos/example/app/rulesets').ok | Should -BeFalse
            $script:fake.Count | Should -Be 0
        }
    }
}

Describe 'Reusable workflow trust boundary and syntax' {
    BeforeAll {
        $root=Join-Path $PSScriptRoot '../../..'
        $workflowPath=Join-Path $root '.github/workflows/validate-deployment.yml'
        $workflowText=Get-Content -LiteralPath $workflowPath -Raw
    }
    It 'parses all workflow YAML using the bounded data-only parser' {
        InModuleScope Validation -Parameters @{ Root=$root; Assembly=$env:CLC_PREREQUISITES_YAML } {
            Add-Type -LiteralPath $Assembly
            foreach ($path in Get-ChildItem -LiteralPath (Join-Path $Root '.github/workflows') -File) {
                $yaml=ConvertFrom-DpYaml (Get-Content -LiteralPath $path.FullName -Raw)
                $yaml['jobs'].Count | Should -BeGreaterThan 0
                $yaml.Contains('on') | Should -BeTrue
            }
        }
    }
    It 'checks out the exact shared implementation and has no caller checkout or privileged runner' {
        $workflowText | Should -Match 'repository: clcdpc/clc-deployment'
        $workflowText | Should -Match "workflow_repository.*-cne 'clcdpc/clc-deployment'"
        $workflowText | Should -Match 'workflow_sha'
        $workflowText | Should -Match 'ref: \$\{\{ steps.source.outputs.sha \}\}'
        $workflowText | Should -Match 'persist-credentials: false'
        $workflowText | Should -Not -Match 'pull_request_target|id-token: write|contents: write|actions: write|secrets: inherit|runs-on: self-hosted'
        $workflowText | Should -Not -Match '(?m)^\s+environment: \$\{\{ inputs.environment_name'
    }
}

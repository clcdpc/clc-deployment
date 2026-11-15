BeforeAll {
    $checker = Join-Path $PSScriptRoot '../Check-GitHubSetup.ps1'
    $repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    function New-ApiFixture {
        $base = '/repos/example-org/example'
        @{
            "$base/branches?per_page=100&page=1" = @(@{name='master';protected=$true})
            "$base/branches/master/protection" = @{enforce_admins=@{enabled=$true};allow_force_pushes=@{enabled=$false};allow_deletions=@{enabled=$false};required_status_checks=@{contexts=@('build');checks=@()}}
            "$base/rules/branches/master?per_page=100&page=1" = @()
            "$base/rulesets?includes_parents=true&per_page=100&page=1" = @(@{id=1;target='tag';enforcement='active'})
            "$base/rulesets/1" = @{id=1;target='tag';enforcement='active';bypass_actors=@();conditions=@{ref_name=@{include=@('refs/tags/v*');exclude=@()}};rules=@(@{type='creation'},@{type='update'},@{type='deletion'})}
            "$base/environments?per_page=100&page=1" = @{total_count=1;environments=@(@{name='example-dev';deployment_branch_policy=@{custom_branch_policies=$true;protected_branches=$false};protection_rules=@(@{type='branch_policy'})})}
            "$base/environments/example-dev/deployment-branch-policies?per_page=100&page=1" = @{total_count=1;branch_policies=@(@{name='master';type='branch'})}
            '/orgs/example-org/actions/runner-groups?per_page=100&page=1' = @{total_count=1;runner_groups=@(@{id=5;name='example-dev';visibility='selected';allows_public_repositories=$false;restricted_to_workflows=$true;selected_workflows=@('example-org/example/.github/workflows/deploy.yml@refs/heads/master')})}
            '/orgs/example-org/actions/runner-groups/5/repositories?per_page=100&page=1' = @{total_count=1;repositories=@(@{full_name='example-org/example'})}
            '/orgs/example-org/actions/runner-groups/5/runners?per_page=100&page=1' = @{total_count=1;runners=@(@{status='online';labels=@(@{name='self-hosted'},@{name='Windows'},@{name='X64'},@{name='example-dev'})})}
            $base = @{private=$true}
            "$base/actions/variables?per_page=30&page=1" = @{total_count=4;variables=@(@{name='GROUP';value='example-dev'},@{name='LABELS';value='Windows,example-dev,self-hosted,X64'},@{name='DEPLOYMENT_ENABLED';value='false'},@{name='UNRELATED';value='PRIVATE-DO-NOT-PRINT'})}
            "$base/immutable-releases" = @{enabled=$true;enforced_by_owner=$false}
        }
    }
    function Invoke-Check([hashtable] $Overrides = @{}) {
        $parameters = @{EnvironmentName='example-dev';RunnerGroup='example-dev';RunnerLabels='self-hosted,Windows,X64,example-dev';RunnerGroupVariable='GROUP';RunnerLabelsVariable='LABELS';AdditionalVariableNames='DEPLOYMENT_ENABLED'}
        foreach ($key in $Overrides.Keys) { $parameters[$key] = $Overrides[$key] }
        $env:GITHUB_STEP_SUMMARY = Join-Path $TestDrive 'summary.md'
        $env:GITHUB_OUTPUT = Join-Path $TestDrive 'outputs.txt'
        [IO.File]::WriteAllText($env:GITHUB_STEP_SUMMARY,'')
        [IO.File]::WriteAllText($env:GITHUB_OUTPUT,'')
        $summary = & $checker @parameters
        $outputs = ConvertFrom-StringData ([IO.File]::ReadAllText($env:GITHUB_OUTPUT))
        @{Summary=$summary;Outputs=$outputs;File=[IO.File]::ReadAllText($env:GITHUB_STEP_SUMMARY)}
    }
    function Row($Result,[string] $Name) { @($Result.Summary -split "`n" | Where-Object { $_ -match ('\| \[' + [regex]::Escape($Name) + '\]') })[0] }
    $savedEnvironment = @{}
    foreach ($name in @('GITHUB_REPOSITORY','GITHUB_SERVER_URL','GITHUB_TOKEN','CLC_INSPECTION_TOKEN','GITHUB_STEP_SUMMARY','GITHUB_OUTPUT')) { $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name) }
}
AfterAll {
    foreach ($name in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name,$savedEnvironment[$name]) }
    Remove-Variable GitHubSetupTest -Scope Global -ErrorAction SilentlyContinue
}

Describe 'GitHub setup inspection' {
    BeforeEach {
        $global:GitHubSetupTest = @{Api=(New-ApiFixture);HttpStatus=@{};NextPages=@{};SeenHeaders=[Collections.Generic.List[string]]::new()}
        $api=$global:GitHubSetupTest.Api; $httpStatus=$global:GitHubSetupTest.HttpStatus
        $nextPages=$global:GitHubSetupTest.NextPages; $seenHeaders=$global:GitHubSetupTest.SeenHeaders
        $env:GITHUB_REPOSITORY='example-org/example'; $env:GITHUB_SERVER_URL='https://github.com'
        $env:GITHUB_TOKEN='DEFAULT-TEST-TOKEN'; $env:CLC_INSPECTION_TOKEN=''
        Mock Invoke-WebRequest {
            param($Uri,$Method,$Headers,$MaximumRedirection,$ConnectionTimeoutSeconds,$OperationTimeoutSeconds)
            $Method | Should -Be 'Get'; $MaximumRedirection | Should -Be 0
            $ConnectionTimeoutSeconds | Should -Be 20; $OperationTimeoutSeconds | Should -Be 20
            ([uri]$Uri).Host | Should -Be 'api.github.com'
            $global:GitHubSetupTest.SeenHeaders.Add($Headers.Authorization)
            $path = ([uri]$Uri).PathAndQuery
            $api=$global:GitHubSetupTest.Api; $httpStatus=$global:GitHubSetupTest.HttpStatus; $nextPages=$global:GitHubSetupTest.NextPages
            if ($httpStatus.Contains($path)) { return @{StatusCode=$httpStatus[$path];Content='PRIVATE-ERROR-DO-NOT-PRINT';Headers=@{}} }
            if (-not $api.Contains($path)) { throw "Unexpected mocked route: $path" }
            @{StatusCode=200;Content=(ConvertTo-Json -InputObject $api[$path] -Depth 30 -Compress);Headers=@{Link=$(if ($nextPages.Contains($path)) { '<https://api.github.com/unused>; rel="next"' } else { '' })}}
        }
    }
    It 'generates the actual concise summary and four outputs, with activation intentionally false' {
        $result = Invoke-Check
        $result.Outputs.status | Should -BeExactly 'CONFIGURED'
        $result.Outputs.Keys.Count | Should -Be 4
        $result.Outputs.configured_count | Should -Be '7'
        $result.Outputs.needs_configuration_count | Should -Be '0'
        $result.Outputs.manual_count | Should -Be '0'
        $result.File | Should -BeExactly $result.Summary
        @($result.Summary -split "`n" | Where-Object { $_ -match '^\| (CONFIGURED|NEEDS CONFIGURATION|CHECK MANUALLY) \|' }).Count | Should -Be 7
        $result.Summary | Should -Not -Match 'PRIVATE-DO-NOT-PRINT|DEFAULT-TEST-TOKEN|"total_count"|DEPLOYMENT READY'
        Write-Host $result.Summary
    }
    It 'reports missing branch controls: <Control>' -ForEach @(@{Control='checks'},@{Control='force push'},@{Control='deletion'}) {
        $classic = $api['/repos/example-org/example/branches/master/protection']
        switch ($Control) { 'checks' { $classic.required_status_checks=$null }; 'force push' { $classic.allow_force_pushes.enabled=$true }; 'deletion' { $classic.allow_deletions.enabled=$true } }
        Row (Invoke-Check) 'Branch protection' | Should -Match 'NEEDS CONFIGURATION.*Missing enforced'
    }
    It 'supports active effective branch rules, while treating hidden bypass as manual' {
        $httpStatus['/repos/example-org/example/branches/master/protection']=403
        $api['/repos/example-org/example/rules/branches/master?per_page=100&page=1']=@(@{type='required_status_checks';ruleset_id=2;parameters=@{required_status_checks=@(@{context='build'})}},@{type='non_fast_forward';ruleset_id=2},@{type='deletion';ruleset_id=2})
        $api['/repos/example-org/example/rulesets/2']=@{id=2;target='branch';enforcement='active';bypass_actors=@()}
        Row (Invoke-Check) 'Branch protection' | Should -Match 'CONFIGURED'
        $api['/repos/example-org/example/rulesets/2'].Remove('bypass_actors')
        Row (Invoke-Check) 'Branch protection' | Should -Match 'CHECK MANUALLY.*bypass'
    }
    It 'preserves branch API denial reasons and confirms an explicitly unprotected branch' {
        $httpStatus['/repos/example-org/example/branches/master/protection']=404
        Row (Invoke-Check) 'Branch protection' | Should -Match 'CHECK MANUALLY.*Classic protection: GitHub HTTP 404'
        $api['/repos/example-org/example/branches?per_page=100&page=1'][0].protected=$false
        Row (Invoke-Check) 'Branch protection' | Should -Match 'NEEDS CONFIGURATION.*no effective branch protection'
    }
    It 'treats malformed classic and ruleset check contexts as missing evidence' {
        $classic=$api['/repos/example-org/example/branches/master/protection']
        $classic.required_status_checks.contexts=@('')
        Row (Invoke-Check) 'Branch protection' | Should -Match 'CHECK MANUALLY.*Malformed required status-check context'
        $classic.required_status_checks.contexts=@(); $classic.required_status_checks.checks=@(@{})
        Row (Invoke-Check) 'Branch protection' | Should -Match 'CHECK MANUALLY.*fields are unavailable'
        $api['/repos/example-org/example/rules/branches/master?per_page=100&page=1']=@(@{type='required_status_checks';ruleset_id=2;parameters=@{required_status_checks=@(@{})}})
        Row (Invoke-Check) 'Branch protection' | Should -Match 'CHECK MANUALLY.*Effective rules: Required API fields'
    }
    It 'reports known broad bypass while accepting an independently enforcing rule' {
        $api['/repos/example-org/example/branches/master/protection'].enforce_admins.enabled=$false
        Row (Invoke-Check) 'Branch protection' | Should -Match 'NEEDS CONFIGURATION.*Broad administrator/role bypass'
        $set=$api['/repos/example-org/example/rulesets/1']
        $set.bypass_actors=@(@{actor_type='OrganizationAdmin';bypass_mode='always'})
        Row (Invoke-Check) 'Tag protection' | Should -Match 'NEEDS CONFIGURATION.*Broad administrator/role bypass'
        $set.bypass_actors[0].bypass_mode='pull_request'
        Row (Invoke-Check) 'Tag protection' | Should -Match '^\| CHECK MANUALLY'
        $set.bypass_actors[0].bypass_mode='always'
        $independent=$set.Clone(); $independent.id=3; $independent.bypass_actors=@()
        $api['/repos/example-org/example/rulesets/3']=$independent
        $api['/repos/example-org/example/rulesets?includes_parents=true&per_page=100&page=1']+=@{id=3;target='tag';enforcement='active'}
        Row (Invoke-Check) 'Tag protection' | Should -Match '^\| CONFIGURED'
    }
    It 'reports missing release-tag restriction: <Control>' -ForEach @(@{Control='creation'},@{Control='update'},@{Control='deletion'}) {
        $set=$api['/repos/example-org/example/rulesets/1']; $set.rules=@($set.rules | Where-Object type -NE $Control)
        Row (Invoke-Check) 'Tag protection' | Should -Match "NEEDS CONFIGURATION.*$Control"
    }
    It 'does not accept evaluation-only tag rules, hidden bypass or complex exclusions' {
        $api['/repos/example-org/example/rulesets?includes_parents=true&per_page=100&page=1'][0].enforcement='evaluate'
        Row (Invoke-Check) 'Tag protection' | Should -Match 'NEEDS CONFIGURATION'
        $global:GitHubSetupTest.Api=New-ApiFixture; $api=$global:GitHubSetupTest.Api; $api['/repos/example-org/example/rulesets/1'].Remove('bypass_actors')
        Row (Invoke-Check) 'Tag protection' | Should -Match 'CHECK MANUALLY'
        $global:GitHubSetupTest.Api=New-ApiFixture; $api=$global:GitHubSetupTest.Api; $api['/repos/example-org/example/rulesets/1'].conditions.ref_name.exclude=@('refs/tags/v1*')
        Row (Invoke-Check) 'Tag protection' | Should -Match 'CHECK MANUALLY'
    }
    It 'distinguishes a confirmed missing environment from wrong rules and approval gates' {
        $api['/repos/example-org/example/environments?per_page=100&page=1']=@{total_count=0;environments=@()}
        Row (Invoke-Check) 'Environment' | Should -Match 'NEEDS CONFIGURATION.*does not exist'
        $global:GitHubSetupTest.Api=New-ApiFixture; $api=$global:GitHubSetupTest.Api; $api['/repos/example-org/example/environments/example-dev/deployment-branch-policies?per_page=100&page=1'].branch_policies[0].name='*'
        Row (Invoke-Check) 'Environment' | Should -Match 'NEEDS CONFIGURATION.*branch/tag rules'
        $global:GitHubSetupTest.Api=New-ApiFixture; $api=$global:GitHubSetupTest.Api; $api['/repos/example-org/example/environments?per_page=100&page=1'].environments[0].protection_rules=@(@{type='required_reviewers'})
        Row (Invoke-Check) 'Environment' | Should -Match 'NEEDS CONFIGURATION.*reviewers'
    }
    It 'accepts a valid unattended wait timer and keeps malformed policy names manual' {
        $api['/repos/example-org/example/environments?per_page=100&page=1'].environments[0].protection_rules=@(@{type='wait_timer';wait_timer=10})
        Row (Invoke-Check) 'Environment' | Should -Match '^\| CONFIGURED'
        $api['/repos/example-org/example/environments/example-dev/deployment-branch-policies?per_page=100&page=1'].branch_policies[0].name=42
        Row (Invoke-Check) 'Environment' | Should -Match 'CHECK MANUALLY.*Malformed string'
    }
    It 'reports a missing group once and explains unavailable runner observations' {
        $api['/orgs/example-org/actions/runner-groups?per_page=100&page=1']=@{total_count=0;runner_groups=@()}
        $result=Invoke-Check
        Row $result 'Runner group' | Should -Match 'NEEDS CONFIGURATION.*does not exist'
        Row $result 'Runners' | Should -Match 'CHECK MANUALLY.*group'
    }
    It 'rejects incorrect runner repository, workflow and public access' {
        $api['/orgs/example-org/actions/runner-groups/5/repositories?per_page=100&page=1'].repositories[0].full_name='example-org/other'
        $group=$api['/orgs/example-org/actions/runner-groups?per_page=100&page=1'].runner_groups[0]
        $group.allows_public_repositories=$true; $group.restricted_to_workflows=$false
        $row=Row (Invoke-Check) 'Runner group'
        $row | Should -Match 'NEEDS CONFIGURATION.*not admitted.*Public-repository.*Selected workflows'
    }
    It 'accepts shared immutable and direct protected workflow definitions without reading contents' {
        $api['/orgs/example-org/actions/runner-groups?per_page=100&page=1'].runner_groups[0].selected_workflows=@('other-org/shared/.github/workflows/release.yml@' + ('a'*40))
        Row (Invoke-Check) 'Runner group' | Should -Match '^\| CONFIGURED'
        Should -Invoke Invoke-WebRequest -Times 0 -ParameterFilter { $Uri -match '/contents/|/secrets' }
    }
    It 'requires the expected labels on one online runner in the selected group' {
        $runner=$api['/orgs/example-org/actions/runner-groups/5/runners?per_page=100&page=1'].runners[0]
        $runner.labels=@(@{name='self-hosted'},@{name='Linux'})
        Row (Invoke-Check) 'Runners' | Should -Match 'NEEDS CONFIGURATION.*expected labels'
        $runner.status='offline'
        Row (Invoke-Check) 'Runners' | Should -Match 'NEEDS CONFIGURATION.*online'
    }
    It 'identifies missing variables and selected value mismatches without printing values' {
        $vars=$api['/repos/example-org/example/actions/variables?per_page=30&page=1']
        $vars.variables=@($vars.variables | Where-Object name -NE 'DEPLOYMENT_ENABLED'); $vars.total_count=3
        $vars.variables[0].value='PRIVATE-WRONG-GROUP'
        $vars.variables[1].value='wrong'
        $row=Row (Invoke-Check) 'Actions variables'
        $row | Should -Match 'NEEDS CONFIGURATION.*DEPLOYMENT&#95;ENABLED does not exist.*differs.*differs'
        $row | Should -Not -Match 'PRIVATE-WRONG-GROUP'
        Row (Invoke-Check @{RunnerGroupVariable=' GROUP ';RunnerLabelsVariable=' LABELS '}) 'Actions variables' | Should -Match 'Runner-group variable GROUP differs.*Runner-label variable LABELS differs'
    }
    It 'handles permission denial and ambiguous 404 as manual with exact UI instructions: <Code>' -ForEach @(@{Code=403},@{Code=404},@{Code=500}) {
        $httpStatus['/orgs/example-org/actions/runner-groups?per_page=100&page=1']=$Code
        $httpStatus['/repos/example-org/example/immutable-releases']=$Code
        $result=Invoke-Check
        Row $result 'Runner group' | Should -Match "CHECK MANUALLY.*HTTP $Code.*Organization Settings.*Workflow access"
        Row $result 'Release immutability' | Should -Match 'CHECK MANUALLY.*Release immutability'
        $result.Outputs.status | Should -BeExactly 'CHECK MANUALLY'
        $result.Summary | Should -Not -Match 'PRIVATE-ERROR'
    }
    It 'rejects incomplete pagination, malformed and contradictory successful responses' {
        $api['/repos/example-org/example/actions/variables?per_page=30&page=1'].total_count=100
        Row (Invoke-Check) 'Actions variables' | Should -Match 'CHECK MANUALLY.*Incomplete API pagination'
        $global:GitHubSetupTest.Api=New-ApiFixture; $api=$global:GitHubSetupTest.Api; $api['/repos/example-org/example/environments?per_page=100&page=1']='invalid'
        Row (Invoke-Check) 'Environment' | Should -Match 'CHECK MANUALLY.*Malformed'
        $global:GitHubSetupTest.Api=New-ApiFixture; $api=$global:GitHubSetupTest.Api; $api['/repos/example-org/example/immutable-releases']=@{enabled=$false;enforced_by_owner=$true}
        Row (Invoke-Check) 'Release immutability' | Should -Match 'CHECK MANUALLY.*Contradictory'
    }
    It 'follows bounded pages and rejects an unfinished final page' {
        $path='/repos/example-org/example/actions/variables?per_page=30&page=1'
        $nextPages[$path]=$true
        $api[$path].total_count=5
        $api['/repos/example-org/example/actions/variables?per_page=30&page=2']=@{total_count=5;variables=@(@{name='EXTRA'})}
        Row (Invoke-Check) 'Actions variables' | Should -Match '^\| CONFIGURED'
        $api['/repos/example-org/example/actions/variables?per_page=30&page=2'].total_count=6
        Row (Invoke-Check) 'Actions variables' | Should -Match 'CHECK MANUALLY.*Contradictory'
    }
    It 'rejects repeated pages before they can falsely establish a requested resource is absent' {
        $path='/repos/example-org/example/environments?per_page=100&page=1'
        $nextPages[$path]=$true; $api[$path].total_count=2
        $api['/repos/example-org/example/environments?per_page=100&page=2']=$api[$path]
        Row (Invoke-Check @{EnvironmentName='other'}) 'Environment' | Should -Match 'CHECK MANUALLY.*duplicate resource'
    }
    It 'uses the default token when optional inspection credentials are absent, and the optional token when present' {
        $null=Invoke-Check
        @($seenHeaders | Select-Object -Unique) | Should -Be @('Bearer DEFAULT-TEST-TOKEN')
        $seenHeaders.Clear(); $env:CLC_INSPECTION_TOKEN='OPTIONAL-TEST-TOKEN'
        $result=Invoke-Check
        @($seenHeaders | Select-Object -Unique) | Should -Be @('Bearer OPTIONAL-TEST-TOKEN')
        $result.Summary | Should -Not -Match 'OPTIONAL-TEST-TOKEN'
    }
    It 'checks the supported immutability setting and can omit that optional category' {
        $api['/repos/example-org/example/immutable-releases'].enabled=$false
        Row (Invoke-Check) 'Release immutability' | Should -Match 'NEEDS CONFIGURATION.*not enabled'
        $result=Invoke-Check @{CheckReleaseImmutability=$false}
        $result.Summary | Should -Not -Match '\| \[Release immutability\]'
        $result.Outputs.configured_count | Should -Be '6'
    }
    It 'escapes dynamic Markdown, formats deterministically and gives precedence to confirmed discrepancies' {
        $first=Invoke-Check @{EnvironmentName='bad|[link](https://evil.invalid)<script>'}
        $second=Invoke-Check @{EnvironmentName='bad|[link](https://evil.invalid)<script>'}
        $first.Summary | Should -BeExactly $second.Summary
        $first.Summary | Should -Match '&#124;.*&#91;link&#93;.*&lt;script&gt;'
        $httpStatus['/repos/example-org/example/immutable-releases']=404
        $result=Invoke-Check @{EnvironmentName='absent'}
        $result.Outputs.status | Should -BeExactly 'NEEDS CONFIGURATION'
        $result.Outputs.needs_configuration_count | Should -Be '1'
        $result.Outputs.manual_count | Should -Be '1'
    }
    It 'fails unexpected execution errors instead of returning a successful report' {
        $env:GITHUB_SERVER_URL='https://unsupported.invalid'
        { Invoke-Check } | Should -Throw '*Only GitHub.com*'
    }
}

Describe 'Workflow and guide contract' {
    It 'uses a fixed own-source commit, hosted infrastructure, read permissions and only four outputs' {
        $workflow=Get-Content -LiteralPath (Join-Path $repositoryRoot '.github/workflows/check-github-setup.yml') -Raw
        $workflow | Should -Match 'workflow_call:'
        $workflow | Should -Match 'runs-on: windows-2022'
        $workflow | Should -Match 'repository: clcdpc/clc-deployment\r?\n.*\r?\n\s+ref: [a-f0-9]{40}'
        $workflow | Should -Match 'contents: read\r?\n  actions: read'
        $workflow | Should -Not -Match 'id-token:|: write|report_json|ready:|host_status|self-hosted|(?m)^\s+environment:|Invoke-Clc|secrets: inherit'
        foreach ($name in @('status','configured_count','needs_configuration_count','manual_count')) { $workflow | Should -Match "steps.check.outputs.$name" }
        $example=Get-Content -LiteralPath (Join-Path $repositoryRoot 'docs/examples/check-github-setup.yml') -Raw
        $example | Should -Match 'workflow_dispatch:'
        $example | Should -Match 'check-github-setup.yml@[a-f0-9]{40}'
        $example | Should -Not -Match 'needs:|runs-on:|push:|pull_request:'
    }
    It 'keeps every reported setup-guide anchor valid and retains host and deployment instructions' {
        $source=Get-Content -LiteralPath $checker -Raw
        $guide=Get-Content -LiteralPath (Join-Path $repositoryRoot 'docs/setup-guide.md') -Raw
        $anchors=@([regex]::Matches($guide,'(?m)^#{1,6} (.+?)\r?$') | ForEach-Object { ($_.Groups[1].Value.ToLowerInvariant() -replace '[^a-z0-9 -]','') -replace ' ','-' })
        foreach ($match in [regex]::Matches($source,"Add-Category '[^']+' '([^']+)'")) { $match.Groups[1].Value | Should -BeIn $anchors }
        foreach ($text in @('Prepare the Windows/IIS host','Install and verify the toolkit','Enroll the target','Authorize first deployment and acceptance')) { $guide | Should -Match ([regex]::Escape($text)) }
    }
}

BeforeAll {
    $checker = Join-Path $PSScriptRoot '../Check-GitHubSetup.ps1'
    $repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    function New-ApiFixture {
        $base = '/repos/example-org/example'
        @{
            "$base/branches?per_page=100&page=1" = @(@{name='master';protected=$true})
            "$base/branches/master/protection" = @{enforce_admins=@{enabled=$true};allow_force_pushes=@{enabled=$false};allow_deletions=@{enabled=$false};required_status_checks=@{contexts=@('build');checks=@()}}
            "$base/rules/branches/master?per_page=100&page=1" = @()
            "$base/rulesets?includes_parents=true&targets=tag&per_page=100&page=1" = @(@{id=1;name='release creators';source_type='Repository';source='example-org/example';enforcement='active'},@{id=3;name='immutable release tags';source_type='Repository';source='example-org/example';enforcement='active'})
            "$base/rulesets/1" = @{id=1;target='tag';enforcement='active';bypass_actors=@(@{actor_id=42;actor_type='Team';bypass_mode='always'});conditions=@{ref_name=@{include=@('refs/tags/v*');exclude=@()}};rules=@(@{type='creation'})}
            "$base/rulesets/3" = @{id=3;target='tag';enforcement='active';bypass_actors=@();conditions=@{ref_name=@{include=@('refs/tags/v*');exclude=@()}};rules=@(@{type='update'},@{type='deletion'})}
            "$base/environments?per_page=100&page=1" = @{total_count=1;environments=@(@{name='example-dev';deployment_branch_policy=$null;protection_rules=@(@{type='branch_policy'})})}
            "$base/environments/example-dev/deployment-branch-policies?per_page=100&page=1" = @{total_count=1;branch_policies=@(@{name='master';type='branch'})}
            '/orgs/example-org/actions/runner-groups?per_page=100&page=1' = @{total_count=1;runner_groups=@(@{id=5;name='example-dev';visibility='selected';allows_public_repositories=$false;restricted_to_workflows=$true;selected_workflows=@('example-org/example/.github/workflows/deploy.yml@refs/heads/master')})}
            '/orgs/example-org/actions/runner-groups/5/repositories?per_page=100&page=1' = @{total_count=1;repositories=@(@{full_name='example-org/example'})}
            "$base/actions/runners?per_page=100&page=1" = @{total_count=1;runners=@(@{status='online';labels=@(@{name='self-hosted'},@{name='Windows'},@{name='X64'},@{name='example-dev'})})}
            $base = @{private=$true}
            "$base/actions/variables?per_page=30&page=1" = @{total_count=4;variables=@(@{name='GROUP';value='example-dev'},@{name='LABELS';value='Windows,example-dev,self-hosted,X64'},@{name='DEPLOYMENT_ENABLED';value='false'},@{name='UNRELATED';value='PRIVATE-DO-NOT-PRINT'})}
            "$base/immutable-releases" = @{enabled=$true;enforced_by_owner=$false}
        }
    }
    function Add-TagFixture([int] $Id, [string[]] $Types, [object[]] $Bypass = @(), [string[]] $Include = @('refs/tags/v*'), [string[]] $Exclude = @(), [string] $Source = 'Repository') {
        $global:GitHubSetupTest.Api['/repos/example-org/example/rulesets?includes_parents=true&targets=tag&per_page=100&page=1'] += @{id=$Id;source_type=$Source;enforcement='active'}
        $global:GitHubSetupTest.Api["/repos/example-org/example/rulesets/$Id"] = @{id=$Id;target='tag';enforcement='active';bypass_actors=$Bypass;conditions=@{ref_name=@{include=$Include;exclude=$Exclude}};rules=@($Types | ForEach-Object { @{type=$_} })}
    }
    function Invoke-Check([hashtable] $Overrides = @{}) {
        $parameters = @{ApplicationId='example'}
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
    It 'keeps seven concise categories and four outputs with policy inspection limits explicit' {
        $result = Invoke-Check
        $result.Outputs.status | Should -BeExactly 'CHECK MANUALLY'
        $result.Outputs.Keys.Count | Should -Be 4
        $result.Outputs.configured_count | Should -Be '4'
        $result.Outputs.needs_configuration_count | Should -Be '0'
        $result.Outputs.manual_count | Should -Be '3'
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
    It 'reports known broad branch bypass' {
        $api['/repos/example-org/example/branches/master/protection'].enforce_admins.enabled=$false
        Row (Invoke-Check) 'Branch protection' | Should -Match 'NEEDS CONFIGURATION.*Broad administrator/role bypass'
    }
    It 'reports missing release-tag restriction: <Control>' -ForEach @(@{Control='creation'},@{Control='update'},@{Control='deletion'}) {
        $id=if ($Control -ceq 'creation') {1} else {3}
        $set=$api["/repos/example-org/example/rulesets/$id"]; $set.rules=@($set.rules | Where-Object type -NE $Control)
        Row (Invoke-Check) 'Tag protection' | Should -Match "NEEDS CONFIGURATION.*$Control"
    }
    It 'distinguishes creator authorization from independently protected immutability' {
        $row=Row (Invoke-Check) 'Tag protection'
        $row | Should -Match '^\| CHECK MANUALLY.*designated release creators.*exact permitted creators'
        $row | Should -Match 'Independent update/deletion restrictions without tag bypass are visible'
        $row | Should -Not -Match 'blocks all|Creation bypass also permits|Confirm independent (update|deletion)'
        $api['/repos/example-org/example/rulesets/1'].bypass_actors=@()
        $row=Row (Invoke-Check) 'Tag protection'
        $row | Should -Match '^\| NEEDS CONFIGURATION.*no tag-creation bypass.*blocks all'
        $row | Should -Match 'Independent update/deletion restrictions without tag bypass are visible'
    }
    It 'rejects a combined no-bypass ruleset despite all three restriction types being present' {
        $set=$api['/repos/example-org/example/rulesets/1']
        $set.rules=@(@{type='creation'},@{type='update'},@{type='deletion'}); $set.bypass_actors=@()
        $api['/repos/example-org/example/rulesets?includes_parents=true&targets=tag&per_page=100&page=1']=@(@{id=1})
        $row=Row (Invoke-Check) 'Tag protection'
        $row | Should -Match '^\| NEEDS CONFIGURATION.*ruleset 1 has no tag-creation bypass'
        $row | Should -Not -Match 'Missing.*restriction'
    }
    It 'requires independent protection when the same creator bypass covers all three rules: <Actor>' -ForEach @(@{Actor='Team'},@{Actor='Integration'},@{Actor='OrganizationAdmin'}) {
        $set=$api['/repos/example-org/example/rulesets/1']
        $set.rules=@(@{type='creation'},@{type='update'},@{type='deletion'})
        $set.bypass_actors=@(@{actor_id=42;actor_type=$Actor;bypass_mode='always'})
        $api['/repos/example-org/example/rulesets?includes_parents=true&targets=tag&per_page=100&page=1']=@(@{id=1})
        $row=Row (Invoke-Check) 'Tag protection'
        $row | Should -Match '^\| NEEDS CONFIGURATION.*Creation bypass also permits update'
        $row | Should -Match 'Creation bypass also permits deletion'
        $row | Should -Not -Match 'no tag-creation bypass'
    }
    It 'accepts independently visible immutability while leaving creator-specific bypass manual: <Actor>/<Mode>' -ForEach @(@{Actor='Team';Mode='always'},@{Actor='Integration';Mode='always'},@{Actor='Team';Mode='exempt'},@{Actor='RepositoryRole';Mode='always'}) {
        $api['/repos/example-org/example/rulesets/1'].bypass_actors=@(@{actor_id=42;actor_type=$Actor;bypass_mode=$Mode})
        $row=Row (Invoke-Check) 'Tag protection'
        $row | Should -Match '^\| CHECK MANUALLY.*effective permissions'
        $row | Should -Match 'Independent update/deletion restrictions without tag bypass are visible'
        $row | Should -Not -Match 'blocks all|Creation bypass also permits'
    }
    It 'does not mistake pull-request-only bypass for permission to create tags' {
        $api['/repos/example-org/example/rulesets/1'].bypass_actors[0].bypass_mode='pull_request'
        Row (Invoke-Check) 'Tag protection' | Should -Match '^\| NEEDS CONFIGURATION.*no tag-creation bypass'
        $api['/repos/example-org/example/rulesets/1'].bypass_actors+=@{actor_id=43;actor_type='Integration';bypass_mode='always'}
        Row (Invoke-Check) 'Tag protection' | Should -Match '^\| CHECK MANUALLY.*designated release creators'
    }
    It 'does not mistake hidden or partial bypass evidence for creator authority: <Kind>' -ForEach @(@{Kind='hidden'},@{Kind='null'},@{Kind='partial'},@{Kind='mode'}) {
        $set=$api['/repos/example-org/example/rulesets/1']
        switch ($Kind) {
            hidden {$set.Remove('bypass_actors')}
            null {$set.bypass_actors=$null}
            partial {$set.bypass_actors=@(@{actor_type='Team'})}
            mode {$set.bypass_actors[0].bypass_mode='unsupported'}
        }
        $row=Row (Invoke-Check) 'Tag protection'
        $row | Should -Match '^\| CHECK MANUALLY'
        $row | Should -Not -Match 'blocks all|Creation bypass also permits'
    }
    It 'requires manual review of hidden immutability bypass despite visible creator bypass' {
        $api['/repos/example-org/example/rulesets/3'].Remove('bypass_actors')
        $row=Row (Invoke-Check) 'Tag protection'
        $row | Should -Match '^\| CHECK MANUALLY.*Confirm independent update.*Confirm independent deletion'
        $row | Should -Not -Match 'restrictions without tag bypass are visible'
    }
    It 'retains an overlapping creation blocker regardless of source or rule order: <Source>/<First>' -ForEach @(@{Source='Repository';First=$false},@{Source='Organization';First=$false},@{Source='Organization';First=$true}) {
        Add-TagFixture 4 @('creation') -Source $Source
        $path='/repos/example-org/example/rulesets?includes_parents=true&targets=tag&per_page=100&page=1'
        if ($First) { $api[$path]=@($api[$path][2],$api[$path][0],$api[$path][1]) }
        $row=Row (Invoke-Check) 'Tag protection'
        $row | Should -Match '^\| NEEDS CONFIGURATION.*ruleset 4 has no tag-creation bypass'
        $row | Should -Match 'Independent update/deletion restrictions without tag bypass are visible'
    }
    It 'detects known partial creation blockers instead of dropping narrower scopes: <Pattern>' -ForEach @(@{Pattern='refs/tags/v1*'},@{Pattern='refs/tags/v1.2.3'},@{Pattern='~ALL'}) {
        Add-TagFixture 4 @('creation') -Include @($Pattern)
        Row (Invoke-Check) 'Tag protection' | Should -Match '^\| NEEDS CONFIGURATION.*ruleset 4 has no tag-creation bypass'
    }
    It 'ignores provably disjoint or fully excluded creation blockers: <Kind>' -ForEach @(@{Kind='other-prefix'},@{Kind='case'},@{Kind='excluded'},@{Kind='narrow-excluded'},@{Kind='literal-excluded'}) {
        switch ($Kind) {
            other-prefix {Add-TagFixture 4 @('creation') -Include @('refs/tags/other*')}
            case {Add-TagFixture 4 @('creation') -Include @('refs/tags/V*')}
            excluded {Add-TagFixture 4 @('creation') -Include @('~ALL') -Exclude @('refs/tags/v*')}
            narrow-excluded {Add-TagFixture 4 @('creation') -Include @('refs/tags/v1*') -Exclude @('refs/tags/v1*')}
            literal-excluded {Add-TagFixture 4 @('creation') -Include @('refs/tags/v1.2.3') -Exclude @('refs/tags/v1.2.3')}
        }
        $row=Row (Invoke-Check) 'Tag protection'
        $row | Should -Match '^\| CHECK MANUALLY.*designated release creators'
        $row | Should -Not -Match 'blocks all|overlapping tag scopes'
    }
    It 'keeps uncertain include/exclude coverage manual: <Kind>' -ForEach @(@{Kind='include'},@{Kind='exclude'},@{Kind='partial-exclude'}) {
        switch ($Kind) {
            include {Add-TagFixture 4 @('creation') -Include @('refs/tags/v[12]*')}
            exclude {Add-TagFixture 4 @('creation') -Exclude @('refs/tags/v[12]*')}
            partial-exclude {Add-TagFixture 4 @('creation') -Exclude @('refs/tags/v1*')}
        }
        $row=Row (Invoke-Check) 'Tag protection'
        $row | Should -Match '^\| CHECK MANUALLY.*overlapping tag scopes and exclusions'
        $row | Should -Not -Match 'blocks all'
    }
    It 'does not infer a common permitted creator from overlapping selected-actor rulesets' {
        Add-TagFixture 4 @('creation') -Bypass @(@{actor_id=99;actor_type='Team';bypass_mode='always'}) -Source Organization
        Row (Invoke-Check) 'Tag protection' | Should -Match '^\| CHECK MANUALLY.*every applicable repository and inherited organization ruleset'
    }
    It 'retains proven blockers when another ruleset cannot be inspected: <Kind>' -ForEach @(@{Kind='hidden'},@{Kind='denied'},@{Kind='malformed'}) {
        $api['/repos/example-org/example/rulesets/1'].bypass_actors=@()
        switch ($Kind) {
            hidden {$api['/repos/example-org/example/rulesets/3'].Remove('bypass_actors')}
            denied {$httpStatus['/repos/example-org/example/rulesets/3']=403}
            malformed {$api['/repos/example-org/example/rulesets/3'].Remove('enforcement')}
        }
        Row (Invoke-Check) 'Tag protection' | Should -Match '^\| NEEDS CONFIGURATION.*ruleset 1 has no tag-creation bypass'
    }
    It 'does not let a broad or combined bypass defeat independent no-bypass immutability' {
        $set=$api['/repos/example-org/example/rulesets/1']
        $set.rules=@(@{type='creation'},@{type='update'},@{type='deletion'})
        $set.bypass_actors=@(@{actor_type='OrganizationAdmin';bypass_mode='always'})
        $row=Row (Invoke-Check) 'Tag protection'
        $row | Should -Match '^\| CHECK MANUALLY.*Independent update/deletion restrictions without tag bypass are visible'
        $row | Should -Not -Match 'Creation bypass also permits|Broad administrator/role bypass defeats'
    }
    It 'does not count inactive rules as creation authority or immutability: <Enforcement>/<Id>' -ForEach @(@{Enforcement='disabled';Id=1},@{Enforcement='evaluate';Id=1},@{Enforcement='disabled';Id=3},@{Enforcement='evaluate';Id=3}) {
        $set=$api["/repos/example-org/example/rulesets/$Id"]; $set.enforcement=$Enforcement
        $row=Row (Invoke-Check) 'Tag protection'
        if ($Id -eq 1) { $row | Should -Match '^\| NEEDS CONFIGURATION.*Missing enforced creation' }
        else { $row | Should -Match '^\| NEEDS CONFIGURATION.*Missing independently enforced update.*Missing independently enforced deletion' }
        $set.enforcement='active'
        Add-TagFixture 4 @('creation'); $api['/repos/example-org/example/rulesets/4'].enforcement=$Enforcement
        Row (Invoke-Check) 'Tag protection' | Should -Match '^\| CHECK MANUALLY.*designated release creators'
    }
    It 'evaluates tag details from documented summaries without target, including inherited rulesets' {
        $path='/repos/example-org/example/rulesets?includes_parents=true&targets=tag&per_page=100&page=1'
        $api[$path][0].Contains('target') | Should -BeFalse
        Row (Invoke-Check) 'Tag protection' | Should -Match '^\| CHECK MANUALLY.*designated release creators'
        $api[$path][0].source_type='Organization'; $api[$path][0].source='example-org'
        Row (Invoke-Check) 'Tag protection' | Should -Match '^\| CHECK MANUALLY.*designated release creators'
        Should -Invoke Invoke-WebRequest -Times 2 -Exactly -ParameterFilter { $Uri -like '*rulesets?includes_parents=true&targets=tag&per_page=100&page=1' }
        Should -Invoke Invoke-WebRequest -Times 2 -Exactly -ParameterFilter { $Uri -eq 'https://api.github.com/repos/example-org/example/rulesets/1' }
    }
    It 'does not trust summary enforcement over the authoritative detail' {
        $api['/repos/example-org/example/rulesets?includes_parents=true&targets=tag&per_page=100&page=1'][0].enforcement='disabled'
        Row (Invoke-Check) 'Tag protection' | Should -Match '^\| CHECK MANUALLY.*designated release creators'
    }
    It 'keeps wrong-target and missing enforcement details manual' {
        $set=$api['/repos/example-org/example/rulesets/1']; $set.target='branch'
        Row (Invoke-Check) 'Tag protection' | Should -Match '^\| CHECK MANUALLY.*Contradictory tag ruleset'
        $set.target='tag'; $set.Remove('enforcement')
        Row (Invoke-Check) 'Tag protection' | Should -Match '^\| CHECK MANUALLY.*fields are unavailable'
    }
    It 'keeps inaccessible tag details manual: <Code>' -ForEach @(@{Code=403},@{Code=404}) {
        $httpStatus['/repos/example-org/example/rulesets/1']=$Code
        Row (Invoke-Check) 'Tag protection' | Should -Match "^\| CHECK MANUALLY.*HTTP $Code"
    }
    It 'keeps incomplete tag pagination and malformed details manual' {
        $path='/repos/example-org/example/rulesets?includes_parents=true&targets=tag&per_page=100&page=1'
        $nextPages[$path]=$true
        $api['/repos/example-org/example/rulesets?includes_parents=true&targets=tag&per_page=100&page=2']=@()
        $nextPages['/repos/example-org/example/rulesets?includes_parents=true&targets=tag&per_page=100&page=2']=$true
        Row (Invoke-Check) 'Tag protection' | Should -Match '^\| CHECK MANUALLY.*Incomplete API pagination'
        $nextPages.Clear(); $api['/repos/example-org/example/rulesets/1']=@{}
        Row (Invoke-Check) 'Tag protection' | Should -Match '^\| CHECK MANUALLY.*fields are unavailable'
    }
    It 'does not accept evaluation-only tag rules, hidden bypass or complex exclusions' {
        $api['/repos/example-org/example/rulesets/1'].enforcement='evaluate'
        Row (Invoke-Check) 'Tag protection' | Should -Match 'NEEDS CONFIGURATION'
        $global:GitHubSetupTest.Api=New-ApiFixture; $api=$global:GitHubSetupTest.Api; $api['/repos/example-org/example/rulesets/1'].Remove('bypass_actors')
        Row (Invoke-Check) 'Tag protection' | Should -Match 'CHECK MANUALLY'
        $global:GitHubSetupTest.Api=New-ApiFixture; $api=$global:GitHubSetupTest.Api; $api['/repos/example-org/example/rulesets/1'].conditions.ref_name.exclude=@('refs/tags/v1*')
        Row (Invoke-Check) 'Tag protection' | Should -Match 'CHECK MANUALLY'
    }
    It 'accepts repository-scoped runners without any organization group or variables' {
        $result=Invoke-Check
        Row $result 'Runners' | Should -Match '^\| CONFIGURED'
        $result.Summary | Should -Not -Match '\| \[Runner group\]|Actions variables'
        Should -Invoke Invoke-WebRequest -Times 0 -ParameterFilter { $Uri -match '/orgs/|/variables|/contents/|/collaborators/' }
    }
    It 'leaves native Restrict actors and workflow review manual with direct links' {
        $result=Invoke-Check
        Row $result 'Restrict actors' | Should -Match 'CHECK MANUALLY.*settings/actions/policies'
        Row $result 'Workflow trigger' | Should -Match 'CHECK MANUALLY.*tagged consumer workflow'
    }
    It 'accepts optional organization repository access without an exact workflow allowlist' {
        $group=$api['/orgs/example-org/actions/runner-groups?per_page=100&page=1'].runner_groups[0]
        $group.restricted_to_workflows=$false; $group.Remove('selected_workflows')
        Row (Invoke-Check @{RunnerGroup='example-dev'}) 'Runner group' | Should -Match '^\| CONFIGURED'
        $api['/orgs/example-org/actions/runner-groups/5/repositories?per_page=100&page=1'].repositories=@(); $api['/orgs/example-org/actions/runner-groups/5/repositories?per_page=100&page=1'].total_count=0
        Row (Invoke-Check @{RunnerGroup='example-dev'}) 'Runner group' | Should -Match '^\| NEEDS CONFIGURATION'
    }
    It 'reports missing environments, branch restrictions and human gates' -ForEach @(@{Kind='missing'},@{Kind='branch'},@{Kind='reviewer'},@{Kind='timer'}) {
        $environment=$api['/repos/example-org/example/environments?per_page=100&page=1'].environments[0]
        switch ($Kind) {
            missing {$api['/repos/example-org/example/environments?per_page=100&page=1']=@{total_count=0;environments=@()}}
            branch {$environment.deployment_branch_policy=@{protected_branches=$true;custom_branch_policies=$false}}
            reviewer {$environment.protection_rules=@(@{type='required_reviewers'})}
            timer {$environment.protection_rules=@(@{type='wait_timer';wait_timer=10})}
        }
        Row (Invoke-Check) 'Environment' | Should -Match '^\| NEEDS CONFIGURATION'
    }
    It 'requires all labels on one online repository-accessible runner' -ForEach @(@{Kind='offline'},@{Kind='labels'}) {
        $runner=$api['/repos/example-org/example/actions/runners?per_page=100&page=1'].runners[0]
        if ($Kind -ceq 'offline') {$runner.status='offline'} else {$runner.labels=@(@{name='self-hosted'},@{name='Linux'})}
        Row (Invoke-Check) 'Runners' | Should -Match '^\| NEEDS CONFIGURATION'
    }
    It 'derives the Production environment and runner label from the application ID' {
        $api['/repos/example-org/example/environments?per_page=100&page=1'].environments[0].name='example-production'
        $api['/repos/example-org/example/actions/runners?per_page=100&page=1'].runners[0].labels[3].name='example-production'
        $result=Invoke-Check @{Channel='Production'}
        Row $result 'Environment' | Should -Match '^\| CONFIGURED'
        Row $result 'Runners' | Should -Match '^\| CONFIGURED'
    }
    It 'keeps denied read APIs manual without disclosing responses or tokens' -ForEach @(@{Code=401},@{Code=403},@{Code=404}) {
        $httpStatus['/repos/example-org/example/actions/runners?per_page=100&page=1']=$Code
        $result=Invoke-Check
        Row $result 'Runners' | Should -Match "CHECK MANUALLY.*HTTP $Code"
        $result.Summary | Should -Not -Match 'PRIVATE-ERROR|DEFAULT-TEST-TOKEN'
    }
    It 'uses an optional read-only inspection token without printing it' {
        $env:CLC_INSPECTION_TOKEN='OPTIONAL-TEST-TOKEN'
        $result=Invoke-Check
        @($seenHeaders | Where-Object {$_ -cne 'Bearer OPTIONAL-TEST-TOKEN'}).Count | Should -Be 0
        $result.Summary | Should -Not -Match 'OPTIONAL-TEST-TOKEN'
    }
    It 'checks the supported immutability setting and can omit that optional category' {
        $api['/repos/example-org/example/immutable-releases'].enabled=$false
        Row (Invoke-Check) 'Release immutability' | Should -Match 'NEEDS CONFIGURATION.*not enabled'
        $result=Invoke-Check @{CheckReleaseImmutability=$false}
        $result.Summary | Should -Not -Match '\| \[Release immutability\]'
        $result.Outputs.configured_count | Should -Be '3'
    }
    It 'formats deterministically and gives discrepancies precedence over manual checks' {
        (Invoke-Check).Summary | Should -BeExactly (Invoke-Check).Summary
        $api['/repos/example-org/example/environments?per_page=100&page=1']=@{total_count=0;environments=@()}
        $result=Invoke-Check
        $result.Outputs.status | Should -BeExactly 'NEEDS CONFIGURATION'
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
        $workflow | Should -Match 'application_id:'
        $workflow | Should -Not -Match 'expected_workflows:|runner_labels:|runner_group_variable:|additional_variable_names:'
        $example | Should -Not -Match 'needs:|runs-on:|push:|pull_request:'
    }
    It 'keeps every reported setup-guide anchor valid and retains host and deployment instructions' {
        $source=Get-Content -LiteralPath $checker -Raw
        $guide=Get-Content -LiteralPath (Join-Path $repositoryRoot 'docs/setup-guide.md') -Raw
        $anchors=@([regex]::Matches($guide,'(?m)^#{1,6} (.+?)\r?$') | ForEach-Object { ($_.Groups[1].Value.ToLowerInvariant() -replace '[^a-z0-9 -]','') -replace ' ','-' })
        foreach ($match in [regex]::Matches($source,"Add-Category '[^']+' '([^']+)'")) { $match.Groups[1].Value | Should -BeIn $anchors }
        foreach ($text in @('Prepare deployment hosts','standing authorization','Verify the setup','Routine operation')) { $guide | Should -Match ([regex]::Escape($text)) }
    }
}

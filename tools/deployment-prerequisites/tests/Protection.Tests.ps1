BeforeDiscovery {Import-Module (Join-Path $PSScriptRoot '../Validation.psm1') -Force}

Describe 'Selected-channel release tag protection' -Tag ReleaseChannel,TagApplicability {
    InModuleScope Validation {
        BeforeAll {. (Join-Path $PSScriptRoot 'Fixtures.ps1')}
        BeforeEach {
            $config=New-ValidationConfig;$fixture=New-ValidationFixture
            $config.DeploymentChannel='DEV'
            $record=Get-FixtureProtectedConfiguration $fixture
            $record.targets[0].channel='DEV'
            Set-FixtureProtectedConfiguration $fixture $record
            $tag=$fixture['/repos/example/app/rulesets/12?includes_parents=true'].data
            $tag.conditions.ref_name.include=@('refs/tags/v*-dev.*')
            Mock Get-ClcDeploymentPrerequisiteApi {
                param($Context,$Path)
                $key=$Path -replace '[?&]per_page=(30|100)&page=\d+$',''
                if (-not $fixture.ContainsKey($key)) {return New-ApiFailure 403}
                $fixture[$key]
            }
        }
        It 'accepts sufficient DEV coverage <Pattern> without beta or RC protection' -ForEach @(
            @{Pattern='refs/tags/v*-dev.*'},@{Pattern='refs/tags/v*.*.*-dev.*'},
            @{Pattern='refs/tags/v*'},@{Pattern='refs/tags/*'},@{Pattern='~ALL'}
        ) {
            $tag.conditions.ref_name.include=@($Pattern)
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            $r.github_status | Should -Be PASS -Because ($r.checks | ConvertTo-Json -Depth 6)
            $r.contract_version | Should -Be 3
            foreach ($id in @('creation','update','deletion','bypass')) {
                ($r.checks | Where-Object id -EQ "github.tags.$id").status | Should -Be PASS
            }
        }
        It 'rejects protection for the wrong DEV release pattern: <Pattern>' -ForEach @(
            @{Pattern='refs/tags/v*-beta.*'},@{Pattern='refs/tags/v*-rc.*'},
            @{Pattern='refs/tags/v1.2.3'},@{Pattern='refs/tags/v1*'}
        ) {
            $tag.conditions.ref_name.include=@($Pattern)
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            $r.github_status | Should -Be FAIL
            ($r.checks | Where-Object id -EQ github.tags.creation).status | Should -Be FAIL
        }
        It 'rejects combined beta and RC protection as DEV deployment authority' {
            $tag.conditions.ref_name.include=@('refs/tags/v*-beta.*','refs/tags/v*-rc.*')
            (Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML).github_status | Should -Be FAIL
        }
        It 'rejects the unsupported Test diagnostic channel before GitHub inspection' {
            $config.DeploymentChannel='Test'
            { Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML } | Should -Throw '*channel*'
            Should -Invoke Get-ClcDeploymentPrerequisiteApi -Times 0 -Exactly
        }
        It 'ignores legacy Test-only <Pattern> for <Channel> before <Evidence> evidence' -Tag LegacyTestPattern -ForEach @(
            foreach ($channel in @('DEV','Production')) {
                foreach ($pattern in @('refs/tags/v*-test.*','refs/tags/v*.*.*-test.*')) {
                    foreach ($evidence in @('visible','exclusions','omitted actors','malformed actors')) {
                        @{Channel=$channel;Pattern=$pattern;Evidence=$evidence}
                    }
                }
            }
        ) {
            $config.DeploymentChannel=$Channel;$record.targets[0].channel=$Channel
            Set-FixtureProtectedConfiguration $fixture $record
            $tag.conditions.ref_name.include=@('refs/tags/v*')
            $legacy=@{target='tag';enforcement='active';conditions=@{ref_name=@{include=@($Pattern);exclude=@()}}
                rules=@(@{type='creation'},@{type='update'},@{type='deletion'});bypass_actors=@()}
            switch ($Evidence) {
                exclusions {$legacy.conditions.ref_name.exclude=@('refs/tags/v1*')}
                'omitted actors' {$legacy.Remove('bypass_actors')}
                'malformed actors' {$legacy.bypass_actors=$null;$legacy.rules='unavailable'}
            }
            $fixture['/repos/example/app/rulesets?includes_parents=true'].data+=@{id=13}
            $fixture['/repos/example/app/rulesets/13?includes_parents=true']=New-ApiSuccess $legacy
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            $r.github_status | Should -Be PASS
            foreach ($id in @('creation','update','deletion','bypass','bypass-visibility')) {
                ($r.checks | Where-Object id -EQ "github.tags.$id").status | Should -Be PASS
            }
        }
        It 'cannot satisfy <Channel> protection with only legacy Test pattern <Pattern>' -Tag LegacyTestPattern -ForEach @(
            foreach ($channel in @('DEV','Production')) {
                foreach ($pattern in @('refs/tags/v*-test.*','refs/tags/v*.*.*-test.*')) {@{Channel=$channel;Pattern=$pattern}}
            }
        ) {
            $config.DeploymentChannel=$Channel;$record.targets[0].channel=$Channel
            Set-FixtureProtectedConfiguration $fixture $record
            $tag.conditions.ref_name.include=@($Pattern)
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            foreach ($id in @('creation','update','deletion')) {
                ($r.checks | Where-Object id -EQ "github.tags.$id").status | Should -Be FAIL
            }
            $r.github_status | Should -Be FAIL
        }
        It 'keeps ambiguous Test-like overlap <Pattern> inconclusive for <Channel>' -Tag LegacyTestPattern -ForEach @(
            foreach ($channel in @('DEV','Production')) {
                foreach ($pattern in @('refs/tags/v*test*','refs/tags/v*-test.?')) {@{Channel=$channel;Pattern=$pattern}}
            }
        ) {
            $config.DeploymentChannel=$Channel;$record.targets[0].channel=$Channel
            Set-FixtureProtectedConfiguration $fixture $record
            $tag.conditions.ref_name.include=@('refs/tags/v*',$Pattern)
            (Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML).github_status | Should -Be UNVERIFIED
        }
        It 'still rejects legacy Test release tags before release verification' -Tag LegacyTestPattern {
            {Get-ClcApplicationTag 'v1.2.3-test.1'} | Should -Throw -ErrorId 'Clc.InvalidContract*'
        }
        It 'reports omitted <Channel> bypass actors as advisory while preserving READY' -Tag BypassVisibility -ForEach @(
            @{Channel='DEV'},@{Channel='Production'}
        ) {
            $config.DeploymentChannel=$Channel;$record.targets[0].channel=$Channel
            Set-FixtureProtectedConfiguration $fixture $record
            $tag.conditions.ref_name.include=@('refs/tags/v*');$tag.Remove('bypass_actors')
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            $r.github_status | Should -Be PASS
            foreach ($id in @('creation','update','deletion','bypass')) {
                ($r.checks | Where-Object id -EQ "github.tags.$id").status | Should -Be PASS
            }
            $warning=$r.checks | Where-Object id -EQ github.tags.bypass-visibility
            $warning.status | Should -Be UNVERIFIED;$warning.required | Should -BeFalse
            $warning.detail | Should -Match 'GitHub omitted bypass_actors.*read-only'
            $warning.action | Should -Match 'Write-capable credentials are not required'
            ($r.checks | Where-Object id -EQ github.tags.bypass).detail | Should -Match 'does not verify hidden actors'
            $merged=Merge-ClcDeploymentPrerequisiteReports $r (New-ClcDeploymentPrerequisiteReport $config @(New-PassingStageChecks host)) -HostJobResult success
            $merged.ready | Should -BeTrue;$merged.contract_version | Should -Be 3
            $summary=Format-ClcDeploymentPrerequisiteSummary $merged
            $summary | Should -Match '# READY';$summary | Should -Match 'Nonblocking warnings[\s\S]*GitHub omitted bypass_actors'
            $summary | Should -Match 'Hidden actors were not verified'
        }
        It 'observes visible tag actors <Type> in mode <Mode>' -Tag BypassVisibility -ForEach @(
            @{Type='empty';Mode='none'}
            foreach ($type in @('Team','User','Integration')) {
                foreach ($mode in @('always','exempt')) {@{Type=$type;Mode=$mode}}
            }
        ) {
            $tag.bypass_actors=@()
            if ($Type -cne 'empty') {$tag.bypass_actors=@(@{actor_type=$Type;actor_id=42;bypass_mode=$Mode})}
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -EQ github.tags.bypass-visibility).status | Should -Be PASS
            $r.github_status | Should -Be PASS
        }
        It 'keeps malformed tag bypass evidence blocking: <Kind>' -Tag BypassVisibility -ForEach @(
            @{Kind='null'},@{Kind='non-array'},@{Kind='non-object'},@{Kind='unknown actor'},@{Kind='unknown mode'},@{Kind='invalid ID'}
        ) {
            switch ($Kind) {
                null {$tag.bypass_actors=$null}
                'non-array' {$tag.bypass_actors=@{}}
                'non-object' {$tag.bypass_actors=@(42)}
                'unknown actor' {$tag.bypass_actors[0].actor_type='FutureRole'}
                'unknown mode' {$tag.bypass_actors[0].bypass_mode='future'}
                'invalid ID' {$tag.bypass_actors[0].actor_id='1'}
            }
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -EQ github.tags.bypass).status | Should -Be UNVERIFIED
            ($r.checks | Where-Object id -EQ github.tags.bypass-visibility).status | Should -Be UNVERIFIED
            $r.github_status | Should -Be UNVERIFIED
        }
        It 'does not let omitted actors hide <Kind> tag restriction evidence' -Tag BypassVisibility -ForEach @(
            @{Kind='missing';Expected='FAIL'},@{Kind='malformed';Expected='UNVERIFIED'}
        ) {
            $tag.Remove('bypass_actors')
            $tag.rules=if ($Kind -ceq 'missing') {@(@{type='creation'},@{type='deletion'})} else {@(@{})}
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -EQ github.tags.update).status | Should -Be $Expected
            $r.github_status | Should -Be $Expected
        }
        It 'retains unsafe tag bypass despite <Kind> evidence elsewhere' -Tag BypassVisibility -ForEach @(
            @{Kind='omitted actors'},@{Kind='unavailable detail'},@{Kind='malformed rules'},@{Kind='exclusions'}
        ) {
            $tag.bypass_actors=@(@{actor_type='DeployKey';actor_id=$null;bypass_mode='always'})
            $fixture['/repos/example/app/rulesets?includes_parents=true'].data+=@{id=13}
            $fixture['/repos/example/app/rulesets/13?includes_parents=true']=New-ApiSuccess @{
                target='tag';enforcement='active';conditions=@{ref_name=@{include=@('refs/tags/v*');exclude=@()}}
                rules=@(@{type='creation'},@{type='update'},@{type='deletion'})
            }
            switch ($Kind) {
                'unavailable detail' {$fixture['/repos/example/app/rulesets/13?includes_parents=true']=New-ApiFailure 403}
                'malformed rules' {$tag.rules=$null}
                exclusions {$tag.conditions.ref_name.exclude=@('refs/tags/v1*')}
            }
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -EQ github.tags.bypass).status | Should -Be FAIL
            $r.github_status | Should -Be FAIL
        }
        It 'does not pass contradictory tag summary/detail <Kind> with omitted actors' -Tag BypassVisibility -ForEach @(
            @{Kind='target'},@{Kind='enforcement'},@{Kind='id'}
        ) {
            $fixture['/repos/example/app/rulesets?includes_parents=true'].data+=@{id=13;target='tag';enforcement='active'}
            $detail=@{target='tag';enforcement='active';conditions=@{ref_name=@{include=@('refs/tags/v*');exclude=@()}};rules=@(@{type='update'})}
            switch ($Kind) {target {$detail.target='branch'};enforcement {$detail.enforcement='disabled'};id {$detail.id=14}}
            $fixture['/repos/example/app/rulesets/13?includes_parents=true']=New-ApiSuccess $detail
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -EQ github.tags.bypass).status | Should -Be UNVERIFIED
            $r.github_status | Should -Be UNVERIFIED
        }
        It 'passes independently configured <Channel> routing and tag scope' -ForEach @(
            @{Channel='DEV';Pattern='refs/tags/v*-dev.*'},
            @{Channel='Production';Pattern='refs/tags/v*.*.*'}
        ) {
            $config.DeploymentChannel=$Channel;$record.targets[0].channel=$Channel
            Set-FixtureProtectedConfiguration $fixture $record
            $tag.conditions.ref_name.include=@($Pattern)
            (Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML).github_status | Should -Be PASS
        }
        It 'ignores demonstrably disjoint policies before exclusions or unavailable bypass data: <Pattern>' -ForEach @(
            @{Pattern='refs/tags/docs/*'},@{Pattern='refs/tags/other*'},@{Pattern='refs/heads/v*'},
            @{Pattern='refs/tags/version*'},
            @{Pattern='refs/tags/v*-beta.*'},@{Pattern='refs/tags/v*-rc.*'},
            @{Pattern='refs/tags/v1.2.3'},@{Pattern='refs/tags/v1.2.3-rc.1'}
        ) {
            $fixture['/repos/example/app/rulesets?includes_parents=true'].data+=@{id=13}
            $fixture['/repos/example/app/rulesets/13?includes_parents=true']=New-ApiSuccess @{
                target='tag';enforcement='active';conditions=@{ref_name=@{include=@($Pattern);exclude=@('refs/tags/private*')}}
                rules='unavailable';bypass_actors=$null
            }
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            $r.github_status | Should -Be PASS
            ($r.checks | Where-Object id -EQ github.tags.bypass).status | Should -Be PASS
        }
        It 'does not ignore applicable exclusions' {
            $tag.conditions.ref_name.exclude=@('refs/tags/v1*')
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            foreach ($id in @('creation','update','deletion','bypass')) {
                ($r.checks | Where-Object id -EQ "github.tags.$id").status | Should -Be UNVERIFIED
            }
            $r.github_status | Should -Be UNVERIFIED
        }
        It 'keeps ambiguous overlaps blocking even alongside complete DEV coverage: <Pattern>' -ForEach @(
            @{Pattern='refs/tags/v*dev*'},@{Pattern='refs/tags/v*-dev.?'},@{Pattern='refs/tags/*-dev.*'}
        ) {
            $fixture['/repos/example/app/rulesets?includes_parents=true'].data+=@{id=13}
            $fixture['/repos/example/app/rulesets/13?includes_parents=true']=New-ApiSuccess @{
                target='tag';enforcement='active';conditions=@{ref_name=@{include=@($Pattern);exclude=@()}}
                rules=@(@{type='update'});bypass_actors=@()
            }
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -EQ github.tags.creation).status | Should -Be PASS
            ($r.checks | Where-Object id -EQ github.tags.bypass).status | Should -Be UNVERIFIED
            $r.github_status | Should -Be UNVERIFIED
        }
        It 'combines applicable inherited and repository tag rules for exact creation/update/deletion requirements' {
            $tag.rules=@(@{type='creation'});$tag.source_type='Organization';$tag.source='example'
            foreach ($item in @(@{id=13;type='update'},@{id=14;type='deletion'})) {
                $fixture['/repos/example/app/rulesets?includes_parents=true'].data+=@{id=$item.id}
                $fixture["/repos/example/app/rulesets/$($item.id)?includes_parents=true"]=New-ApiSuccess @{
                    target='tag';enforcement='active';conditions=@{ref_name=@{include=@('refs/tags/v*-dev.*');exclude=@()}}
                    rules=@(@{type=$item.type});bypass_actors=@()
                }
            }
            (Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML).github_status | Should -Be PASS
            Should -Invoke Get-ClcDeploymentPrerequisiteApi -Times 1 -Exactly -ParameterFilter {$Path -ceq '/repos/example/app/rulesets/14?includes_parents=true'}
        }
        It 'requires each selected-channel restriction: <Type>' -ForEach @(@{Type='creation'},@{Type='update'},@{Type='deletion'}) {
            $tag.rules=@($tag.rules | Where-Object type -CNE $Type)
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -EQ "github.tags.$Type").status | Should -Be FAIL
        }
        It 'rejects ineffective enforcement <Enforcement>' -ForEach @(@{Enforcement='evaluate'},@{Enforcement='disabled'}) {
            $tag.enforcement=$Enforcement
            (Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML).github_status | Should -Be FAIL
        }
        It 'keeps missing relevant details or collections inconclusive: <Kind>' -ForEach @(
            @{Kind='details'},@{Kind='collection'},@{Kind='conditions'},@{Kind='enforcement'},@{Kind='malformed detail'}
        ) {
            switch ($Kind) {
                details {$fixture['/repos/example/app/rulesets/12?includes_parents=true']=New-ApiFailure 404}
                collection {$fixture['/repos/example/app/rulesets?includes_parents=true']=New-ApiFailure 403}
                conditions {$tag.conditions=$null}
                enforcement {$tag.Remove('enforcement')}
                'malformed detail' {$fixture['/repos/example/app/rulesets/12?includes_parents=true']=New-ApiSuccess 42}
            }
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -EQ github.tags.bypass).status | Should -Be UNVERIFIED
            $r.github_status | Should -Be UNVERIFIED
        }
        It 'ignores inaccessible details of a summary known to be unrelated or inactive: <Kind>' -ForEach @(
            @{Kind='branch'},@{Kind='evaluate'}
        ) {
            $fixture['/repos/example/app/rulesets?includes_parents=true'].data+=if ($Kind -ceq 'branch') {@{id=13;target='branch'}} else {@{id=13;target='tag';enforcement='evaluate'}}
            (Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML).github_status | Should -Be PASS
            Should -Invoke Get-ClcDeploymentPrerequisiteApi -Times 0 -Exactly -ParameterFilter {$Path -ceq '/repos/example/app/rulesets/13?includes_parents=true'}
        }
        It 'does not accept PR-only tag bypass' {
            $tag.bypass_actors[0].bypass_mode='pull_request'
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -EQ github.tags.bypass).status | Should -Be UNVERIFIED
        }
        It 'blocks effective DeployKey tag bypass with <Mode> while retaining restriction observations' -Tag DeployKey -ForEach @(@{Mode='always'},@{Mode='exempt'}) {
            $tag.bypass_actors=@(@{actor_type='DeployKey';actor_id=$null;bypass_mode=$Mode})
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            foreach ($id in @('creation','update','deletion')) {
                ($r.checks | Where-Object id -EQ "github.tags.$id").status | Should -Be PASS
            }
            ($r.checks | Where-Object id -EQ github.tags.bypass).status | Should -Be FAIL
            $r.github_status | Should -Be FAIL
        }
        It 'rejects broad tag administrator bypass' {
            $tag.bypass_actors=@(@{actor_type='OrganizationAdmin';actor_id=$null;bypass_mode='always'})
            (Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML).github_status | Should -Be FAIL
        }
    }
}

Describe 'Effective integration branch protection and bypass' -Tag BranchProtection {
    InModuleScope Validation {
        BeforeAll {
            . (Join-Path $PSScriptRoot 'Fixtures.ps1')
            function Set-BranchRules([string[]] $Types=@('non_fast_forward','deletion','required_status_checks'),[int] $Id=21,$Actors=@()) {
                $fixture['/repos/example/app/rules/branches/master'].data+=@(foreach ($type in $Types) {
                    $rule=@{type=$type;ruleset_id=$Id;ruleset_source_type='Organization';ruleset_source='example'}
                    if ($type -ceq 'required_status_checks') {$rule.parameters=@{required_status_checks=@(@{context='CI';integration_id=1})}}
                    $rule
                })
                $fixture["/repos/example/app/rulesets/$($Id)?includes_parents=true"]=New-ApiSuccess @{
                    target='branch';enforcement='active';bypass_actors=$Actors
                }
            }
        }
        BeforeEach {
            $config=New-ValidationConfig;$fixture=New-ValidationFixture
            $classic=$fixture['/repos/example/app/branches/master/protection'].data
            Mock Get-ClcDeploymentPrerequisiteApi {
                param($Context,$Path)
                $key=$Path -replace '[?&]per_page=(30|100)&page=\d+$',''
                if (-not $fixture.ContainsKey($key)) {return New-ApiFailure 403}
                $fixture[$key]
            }
        }
        It 'passes classic protection with enforced administrators and no mandatory reviews' {
            $classic.Remove('required_pull_request_reviews')
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            $r.github_status | Should -Be PASS
            ($r.checks | Where-Object id -EQ github.branch.bypass).status | Should -Be PASS
            ($r.checks | Where-Object id -EQ github.branch.reviews).required | Should -BeFalse
        }
        It 'preserves observable branch protection with omitted actors and classic <ClassicEvidence> evidence' -Tag BypassVisibility -ForEach @(
            @{ClassicEvidence='enforced'},@{ClassicEvidence='inaccessible'}
        ) {
            Set-BranchRules
            $fixture['/repos/example/app/rulesets/21?includes_parents=true'].data.Remove('bypass_actors')
            if ($ClassicEvidence -ceq 'inaccessible') {$fixture['/repos/example/app/branches/master/protection']=New-ApiFailure 403}
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            foreach ($id in @('protection','force-push','deletion','required-checks','bypass')) {
                ($r.checks | Where-Object id -EQ "github.branch.$id").status | Should -Be PASS
            }
            $warning=$r.checks | Where-Object id -EQ github.branch.bypass-visibility
            $warning.status | Should -Be UNVERIFIED;$warning.required | Should -BeFalse
            $warning.detail | Should -Match 'GitHub omitted bypass_actors.*read-only'
            ($r.checks | Where-Object id -EQ github.branch.bypass).detail | Should -Match 'does not verify hidden actors'
            $r.github_status | Should -Be PASS
            $merged=Merge-ClcDeploymentPrerequisiteReports $r (New-ClcDeploymentPrerequisiteReport $config @(New-PassingStageChecks host)) -HostJobResult success
            $merged.ready | Should -BeTrue
            (Format-ClcDeploymentPrerequisiteSummary $merged) | Should -Match 'Nonblocking warnings[\s\S]*Hidden actors were not verified'
        }
        It 'does not let an omitted actor list independently defeat confirmed broad <Layer> bypass' -Tag BypassVisibility -ForEach @(
            @{Layer='classic'},@{Layer='ruleset'},@{Layer='partial safe ruleset'}
        ) {
            Set-BranchRules
            $fixture['/repos/example/app/rulesets/21?includes_parents=true'].data.Remove('bypass_actors')
            if ($Layer -ceq 'classic') {$classic.enforce_admins.enabled=$false} else {
                $fixture['/repos/example/app/branches/master/protection']=New-ApiFailure 403
                Set-BranchRules -Id 22 -Actors @(@{actor_type='DeployKey';actor_id=$null;bypass_mode='always'})
                if ($Layer -ceq 'partial safe ruleset') {Set-BranchRules -Id 23 -Types deletion}
            }
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -EQ github.branch.bypass).status | Should -Be FAIL
            ($r.checks | Where-Object id -EQ github.branch.bypass-visibility).status | Should -Be UNVERIFIED
            $r.github_status | Should -Be FAIL
        }
        It 'requires all branch controls despite omitted bypass actors' -Tag BypassVisibility {
            $fixture['/repos/example/app/branches/master/protection']=New-ApiFailure 404
            Set-BranchRules -Types deletion
            $fixture['/repos/example/app/rulesets/21?includes_parents=true'].data.Remove('bypass_actors')
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -EQ github.branch.required-checks).status | Should -Be UNVERIFIED
            $r.github_status | Should -Be UNVERIFIED
        }
        It 'keeps <Kind> branch detail blocking alongside an omitted actor layer' -Tag BypassVisibility -ForEach @(
            @{Kind='target'},@{Kind='enforcement'},@{Kind='id'},@{Kind='malformed actors'},@{Kind='inaccessible'}
        ) {
            $fixture['/repos/example/app/branches/master/protection']=New-ApiFailure 403
            Set-BranchRules;Set-BranchRules -Id 22
            $fixture['/repos/example/app/rulesets/21?includes_parents=true'].data.Remove('bypass_actors')
            $detail=$fixture['/repos/example/app/rulesets/22?includes_parents=true'].data
            switch ($Kind) {
                target {$detail.target='tag'}
                enforcement {$detail.enforcement='disabled'}
                id {$detail.id=23}
                'malformed actors' {$detail.bypass_actors=$null}
                inaccessible {$fixture['/repos/example/app/rulesets/22?includes_parents=true']=New-ApiFailure 403}
            }
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -EQ github.branch.bypass).status | Should -Be UNVERIFIED
            $r.github_status | Should -Be UNVERIFIED
        }
        It 'keeps branch visibility advisory when classic protection independently enforces every control' -Tag BypassVisibility {
            $fixture['/repos/example/app/rules/branches/master']=New-ApiFailure 403
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -EQ github.branch.bypass-visibility).status | Should -Be UNVERIFIED
            $r.github_status | Should -Be PASS
        }
        It 'reports bypass visibility SKIPPED only when source-dependent ruleset inspections did not run' -Tag BypassVisibility {
            $fixture['/repos/example/app/branches/master']=New-ApiFailure 404
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            foreach ($area in @('branch','tags')) {
                $row=$r.checks | Where-Object id -EQ "github.$area.bypass-visibility"
                $row.status | Should -Be SKIPPED;$row.required | Should -BeFalse
                $row.reason | Should -Not -BeNullOrEmpty
            }
            Should -Invoke Get-ClcDeploymentPrerequisiteApi -Times 0 -Exactly -ParameterFilter {$Path -match '/rulesets|/rules/branches'}
        }
        It 'rejects classic administrator bypass' {
            $classic.enforce_admins.enabled=$false
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -EQ github.branch.bypass).status | Should -Be FAIL
            $r.github_status | Should -Be FAIL
        }
        It 'accepts independently enforcing rulesets with classic endpoint status <Code>' -ForEach @(
            @{Code=404},@{Code=403},@{Code=401}
        ) {
            Set-BranchRules
            $fixture['/repos/example/app/branches/master/protection']=New-ApiFailure $Code
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            $r.github_status | Should -Be PASS -Because ($r.checks | ConvertTo-Json -Depth 6)
            @($r.checks | Where-Object { $_.id.StartsWith('github.branch.') -and $_.status -cne 'PASS' }).Count | Should -Be 0
        }
        It 'combines classic and applicable ruleset controls' {
            $classic.Remove('allow_deletions');Set-BranchRules -Types deletion
            (Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML).github_status | Should -Be PASS
        }
        It 'accepts classic protection despite inaccessible effective rules when it independently enforces every required control' {
            $fixture['/repos/example/app/rules/branches/master']=New-ApiFailure
            (Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML).github_status | Should -Be PASS
        }
        It 'accepts independent full ruleset enforcement despite disabled classic administrator enforcement' {
            $classic.enforce_admins.enabled=$false;Set-BranchRules
            (Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML).github_status | Should -Be PASS
        }
        It 'does not let partial independent enforcement conceal classic administrator bypass' {
            $classic.enforce_admins.enabled=$false;Set-BranchRules -Types deletion
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -EQ github.branch.bypass).status | Should -Be FAIL
        }
        It 'does not infer classic absence from a concealed 404 with incomplete independent enforcement' {
            $fixture['/repos/example/app/branches/master/protection']=New-ApiFailure 404
            Set-BranchRules -Types deletion
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -EQ github.branch.required-checks).status | Should -Be UNVERIFIED
            $r.github_status | Should -Be UNVERIFIED
        }
        It 'rejects confirmed missing protections on an unprotected branch' {
            $fixture['/repos/example/app/branches/master'].data.protected=$false
            $fixture['/repos/example/app/branches/master/protection']=New-ApiFailure 404
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            foreach ($id in @('protection','force-push','deletion','required-checks')) {
                ($r.checks | Where-Object id -EQ "github.branch.$id").status | Should -Be FAIL
            }
        }
        It 'preserves required uncertainty for inaccessible ruleset details' {
            Set-BranchRules
            $fixture['/repos/example/app/branches/master/protection']=New-ApiFailure 403
            $fixture['/repos/example/app/rulesets/21?includes_parents=true']=New-ApiFailure 403
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -EQ github.branch.required-checks).status | Should -Be PASS
            ($r.checks | Where-Object id -EQ github.branch.bypass).status | Should -Be UNVERIFIED
            $r.github_status | Should -Be UNVERIFIED
        }
        It 'rejects broad <Type> bypass in mode <Mode>' -ForEach @(
            foreach ($type in @('RepositoryRole','OrganizationAdmin','EnterpriseOwner','EnterpriseRole')) {
                foreach ($mode in @('always','pull_request','exempt')) {@{Type=$type;Mode=$mode}}
            }
        ) {
            Set-BranchRules -Actors @(@{actor_type=$Type;actor_id=5;bypass_mode=$Mode})
            $fixture['/repos/example/app/branches/master/protection']=New-ApiFailure 404
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -EQ github.branch.bypass).status | Should -Be FAIL
            $r.github_status | Should -Be FAIL
        }
        It 'accepts specifically restricted <Type> bypass in mode <Mode>' -ForEach @(
            foreach ($type in @('Integration','Team','User')) {
                foreach ($mode in @('always','pull_request','exempt')) {
                    @{Type=$type;Mode=$mode}
                }
            }
        ) {
            Set-BranchRules -Actors @(@{actor_type=$Type;actor_id=42;bypass_mode=$Mode})
            $fixture['/repos/example/app/branches/master/protection']=New-ApiFailure 404
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            $r.github_status | Should -Be PASS
            ($r.checks | Where-Object id -EQ github.branch.bypass-visibility).status | Should -Be PASS
        }
        It 'keeps malformed or missing bypass information inconclusive: <Kind>' -ForEach @(
            @{Kind='null list'},@{Kind='non-array'},@{Kind='non-object'},
            @{Kind='missing actor type'},@{Kind='unknown actor type'},@{Kind='missing actor ID'},
            @{Kind='invalid actor ID'},@{Kind='missing mode'},@{Kind='unknown mode'},@{Kind='deploy key PR mode'}
        ) {
            Set-BranchRules -Actors @(@{actor_type='Team';actor_id=42;bypass_mode='always'})
            $fixture['/repos/example/app/branches/master/protection']=New-ApiFailure 404
            $detail=$fixture['/repos/example/app/rulesets/21?includes_parents=true'].data
            switch ($Kind) {
                'null list' {$detail.bypass_actors=$null}
                'non-array' {$detail.bypass_actors=@{}}
                'non-object' {$detail.bypass_actors=@('Team')}
                'missing actor type' {$detail.bypass_actors[0].Remove('actor_type')}
                'unknown actor type' {$detail.bypass_actors[0].actor_type='FutureRole'}
                'missing actor ID' {$detail.bypass_actors[0].Remove('actor_id')}
                'invalid actor ID' {$detail.bypass_actors[0].actor_id='42'}
                'missing mode' {$detail.bypass_actors[0].Remove('bypass_mode')}
                'unknown mode' {$detail.bypass_actors[0].bypass_mode='never'}
                'deploy key PR mode' {$detail.bypass_actors[0].actor_type='DeployKey';$detail.bypass_actors[0].actor_id=$null;$detail.bypass_actors[0].bypass_mode='pull_request'}
            }
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -EQ github.branch.bypass).status | Should -Be UNVERIFIED
            $r.github_status | Should -Be UNVERIFIED
        }
        It 'blocks documented DeployKey bypass in mode <Mode> unless <Layer> independently enforces every operation' -Tag DeployKey -ForEach @(
            foreach ($mode in @('always','exempt')) {
                foreach ($layer in @('none','classic','ruleset','partial')) {@{Mode=$mode;Layer=$layer}}
            }
        ) {
            Set-BranchRules -Actors @(@{actor_type='DeployKey';actor_id=$null;bypass_mode=$Mode})
            if ($Layer -cne 'classic') {$fixture['/repos/example/app/branches/master/protection']=New-ApiFailure 404}
            if ($Layer -ceq 'ruleset') {Set-BranchRules -Id 22}
            if ($Layer -ceq 'partial') {Set-BranchRules -Id 22 -Types deletion}
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            $expected=if ($Layer -cin @('classic','ruleset')) {'PASS'} else {'FAIL'}
            ($r.checks | Where-Object id -EQ github.branch.bypass).status | Should -Be $expected
            $r.github_status | Should -Be $expected
        }
        It 'requires classic administrator enforcement evidence: <Kind>' -ForEach @(@{Kind='missing'},@{Kind='malformed'}) {
            if ($Kind -ceq 'missing') {$classic.Remove('enforce_admins')} else {$classic.enforce_admins.enabled='true'}
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -EQ github.branch.bypass).status | Should -Be UNVERIFIED
        }
        It 'does not accept malformed effective status checks as required CI evidence' {
            Set-BranchRules
            $fixture['/repos/example/app/branches/master/protection']=New-ApiFailure 404
            $fixture['/repos/example/app/rules/branches/master'].data[2].parameters.required_status_checks=@(@{})
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -EQ github.branch.required-checks).status | Should -Be UNVERIFIED
            $r.github_status | Should -Be UNVERIFIED
        }
        It 'requires effective rule source identity before bypass can pass' {
            Set-BranchRules
            $fixture['/repos/example/app/branches/master/protection']=New-ApiFailure 404
            $fixture['/repos/example/app/rules/branches/master'].data[0].Remove('ruleset_id')
            $r=Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML
            ($r.checks | Where-Object id -EQ github.branch.bypass).status | Should -Be UNVERIFIED
        }
        It 'combines independently enforcing rulesets instead of assuming one bypass grants access through all policies' {
            Set-BranchRules -Actors @(@{actor_type='RepositoryRole';actor_id=5;bypass_mode='always'})
            Set-BranchRules -Id 22
            $fixture['/repos/example/app/branches/master/protection']=New-ApiFailure 404
            (Invoke-ClcDeploymentPrerequisiteGitHubInspection $config $env:CLC_PREREQUISITES_YAML).github_status | Should -Be PASS
        }
    }
}

Describe 'GitHub DeployKey API representations' -Tag DeployKey {
    InModuleScope Validation {
        It 'classifies <Kind> as <Expected> for <Target>' -ForEach @(
            foreach ($target in @('branch','tag')) {
                foreach ($case in @(
                    @{Kind='null always';Id=$null;Mode='always';Expected='FAIL'},
                    @{Kind='null exempt';Id=$null;Mode='exempt';Expected='FAIL'},
                    @{Kind='numeric';Id=42;Mode='always';Expected='UNVERIFIED'},
                    @{Kind='zero';Id=0;Mode='always';Expected='UNVERIFIED'},
                    @{Kind='string';Id='42';Mode='always';Expected='UNVERIFIED'},
                    @{Kind='boolean';Id=$false;Mode='always';Expected='UNVERIFIED'},
                    @{Kind='missing';Id=$null;Mode='always';Expected='UNVERIFIED'},
                    @{Kind='PR only';Id=$null;Mode='pull_request';Expected='UNVERIFIED'}
                )) { $case.Clone()+@{Target=$target} }
            }
        ) {
            # Round-trip JSON so fixtures use the API's explicit null/numeric shapes.
            $actor=@{actor_type='DeployKey';actor_id=$Id;bypass_mode=$Mode}
            if ($Kind -ceq 'missing') {$actor.Remove('actor_id')}
            $rule=@{bypass_actors=@($actor)} | ConvertTo-Json -Depth 4 | ConvertFrom-Json -AsHashtable
            Get-ClcDeploymentPrerequisiteBypassStatus $rule $Target | Should -Be $Expected
        }
    }
}

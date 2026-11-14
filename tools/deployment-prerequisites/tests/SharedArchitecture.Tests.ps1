BeforeDiscovery { Import-Module (Join-Path $PSScriptRoot '../Validation.psm1') -Force }

Describe 'Protected shared orchestration compatibility' {
    InModuleScope Validation {
        BeforeAll { . (Join-Path $PSScriptRoot 'Fixtures.ps1') }
        BeforeEach {
            $config=New-ValidationConfig
            $config.Repository='clcdpc/app'; $config.ApplicationId='app'; $config.TargetId='app-dev'
            $config.SharedRevision='a'*40; $config.DiagnosticWorkflow='.github/workflows/diagnose.yml'
            $config.ActivationState='missing-or-empty' # Shared targets use protected configuration.
            $fixture=@{}
            foreach ($entry in (New-ValidationFixture).GetEnumerator()) {
                $fixture[$entry.Key.Replace('example/app','clcdpc/app').Replace('/orgs/example/','/orgs/clcdpc/')]= $entry.Value
            }
            $fixture['/repos/clcdpc/app'].data.full_name='clcdpc/app'
            $fixture['/orgs/clcdpc/actions/runner-groups/7/repositories'].data.repositories[0].full_name='clcdpc/app'
            $group=$fixture['/orgs/clcdpc/actions/runner-groups/7'].data
            $group.selected_workflows=@(('clcdpc/clc-deployment/.github/workflows/application-deploy.yml@'+('a'*40)),'clcdpc/app/.github/workflows/diagnose.yml@refs/heads/master')
            $caller=@'
name: Publication and deployment
on:
  workflow_run:
    workflows: [Release]
    types: [completed]
  workflow_dispatch:
jobs:
  publication:
    uses: clcdpc/clc-deployment/.github/workflows/application-release.yml@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    with:
      reference: ${{ github.event.workflow_run.head_branch || inputs.reference }}
      source-commit: ${{ github.event.workflow_run.head_sha || inputs.source-commit }}
      producer-run-id: ${{ github.event.workflow_run.id || fromJSON(inputs.producer-run-id) }}
      producer-run-attempt: ${{ github.event.workflow_run.run_attempt || fromJSON(inputs.producer-run-attempt) }}
  deployment:
    uses: clcdpc/clc-deployment/.github/workflows/application-deploy.yml@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    with:
      reference: ${{ github.event.workflow_run.head_branch || inputs.reference }}
      source-commit: ${{ github.event.workflow_run.head_sha || inputs.source-commit }}
      producer-run-id: ${{ github.event.workflow_run.id || fromJSON(inputs.producer-run-id) }}
      producer-run-attempt: ${{ github.event.workflow_run.run_attempt || fromJSON(inputs.producer-run-attempt) }}
      automatic: ${{ github.event_name != 'workflow_dispatch' }}
'@
            $callerKey='/repos/clcdpc/app/contents/.github/workflows/deploy-release.yml?ref='+('b'*40)
            $fixture[$callerKey]=New-WorkflowFile $caller
            # Projection of PR4 protected release contract, not executable fixture code.
            $releaseConfig=@{contractVersion=1;applicationId='app';repository='clcdpc/app';integrationBranch='master';
                sourcePolicy=@{allowUnmergedDevTags=$true;allowSnapshots=$true;allowTestTags=$false};
                trustedFiles=@('.clc/release.json','.github/workflows/release.yml','.github/workflows/deploy-release.yml');requiredToolkitContractVersion=2;
                project='src/App/App.csproj';testProject='tests/App.Tests/App.Tests.csproj';
                orchestration=@{sharedRevision=('a'*40);deploymentWorkflowPath='.github/workflows/deploy-release.yml'};
                producer=@{workflowPath='.github/workflows/release.yml';job='package';jobName='package / build'};
                targets=@(@{channel='DEV';targetId='app-dev';environment='app-dev';runnerGroup='app-deployment';runnerLabels=@('self-hosted','Windows','X64');enabled=$true;runnerAdmissionReady=$true})}
            $configKey='/repos/clcdpc/app/contents/.clc/release.json?ref='+('b'*40)
            $fixture[$configKey]=New-WorkflowFile ($releaseConfig | ConvertTo-Json -Depth 10)
            $sharedKey='/repos/clcdpc/clc-deployment/contents/.github/workflows/application-deploy.yml?ref='+('a'*40)
            # PR4 uses anchors; reading immutable bytes does not prove executable semantics.
            $fixture[$sharedKey]=New-WorkflowFile "on: {workflow_call: {}}`njobs: {deploy: &job {runs-on: self-hosted}}"
            Mock Get-DpApi {
                param($Path)
                $key=$Path -replace '[?&]per_page=(30|100)&page=\d+$',''
                if (-not $fixture.ContainsKey($key)) { return New-ApiFailure 403 }
                $fixture[$key]
            }
        }
        It 'admits the exact defining shared revision plus separate diagnostic and recognizes automatic completion and dispatch' {
            $r=Invoke-DpValidation $config $env:CLC_PREREQUISITES_YAML
            @($r.results | Where-Object status -EQ FAIL).Count | Should -Be 0 -Because (($r.results | Where-Object status -EQ FAIL | ConvertTo-Json -Compress) -join '')
            foreach ($name in @('Shared privileged workflow identity','Runner selected-workflow access','Protected shared deployment routing','Activation indicator','Automatic release-completion trigger')) {
                ($r.results | Where-Object name -EQ $name).status | Should -Be PASS
            }
            ($r.results | Where-Object name -EQ 'Protected manual deployment dispatch').status | Should -Be UNVERIFIED
            ($r.results | Where-Object name -EQ 'Shared deployment implementation inspection').status | Should -Be UNVERIFIED
            $r.contract_version | Should -Be 2
            $r.ready | Should -BeFalse
        }
        It 'rejects a wrong privileged caller <Mutation>' -ForEach @(
            @{Mutation='revision'},@{Mutation='repository'},@{Mutation='workflow'}
        ) {
            $changed=switch ($Mutation) {
                revision {$caller.Replace('a'*40,'c'*40)}
                repository {$caller.Replace('clcdpc/clc-deployment/','clcdpc/other/')}
                workflow {$caller.Replace('application-deploy.yml','other.yml')}
                'extra job' {$caller+"`n  extra: {runs-on: self-hosted, steps: [{run: unsafe}]}"}
            }
            $fixture[$callerKey]=New-WorkflowFile $changed
            $r=Invoke-DpValidation $config $env:CLC_PREREQUISITES_YAML
            ($r.results | Where-Object name -EQ 'Shared privileged workflow identity').status | Should -Be FAIL
        }
        It 'allows an independent hosted caller job without claiming its semantics are verified' {
            $fixture[$callerKey]=New-WorkflowFile ($caller+"`n  metadata: {runs-on: windows-2022, steps: [{run: 'echo metadata'}]}")
            $r=Invoke-DpValidation $config $env:CLC_PREREQUISITES_YAML
            ($r.results | Where-Object name -EQ 'Shared privileged workflow identity').status | Should -Be PASS
            @($r.results | Where-Object status -EQ FAIL).Count | Should -Be 0 -Because (($r.results | Where-Object status -EQ FAIL | ConvertTo-Json -Compress) -join '')
        }
        It 'rejects an additional caller job selecting the privileged group' {
            $fixture[$callerKey]=New-WorkflowFile ($caller+"`n  extra: {runs-on: {group: app-deployment}, steps: [{run: unsafe}]}")
            $r=Invoke-DpValidation $config $env:CLC_PREREQUISITES_YAML
            ($r.results | Where-Object name -EQ 'Additional privileged caller jobs').status | Should -Be FAIL
        }
        It 'rejects broader, caller-only or differently pinned runner selections: <Kind>' -ForEach @(
            @{Kind='extra'},@{Kind='caller'},@{Kind='revision'},@{Kind='repository'},@{Kind='disabled'}
        ) {
            switch ($Kind) {
                extra {$group.selected_workflows+= 'clcdpc/app/.github/workflows/other.yml@refs/heads/master'}
                caller {$group.selected_workflows[0]='clcdpc/app/.github/workflows/deploy-release.yml@refs/heads/master'}
                revision {$group.selected_workflows[0]=$group.selected_workflows[0].Replace('a'*40,'c'*40)}
                repository {$group.selected_workflows[0]=$group.selected_workflows[0].Replace('clc-deployment','other')}
                disabled {$group.restricted_to_workflows=$false}
            }
            $r=Invoke-DpValidation $config $env:CLC_PREREQUISITES_YAML
            ($r.results | Where-Object name -EQ 'Runner selected-workflow access').status | Should -Be FAIL
        }
        It 'leaves missing, malformed or inaccessible admission evidence unverified: <Kind>' -ForEach @(
            @{Kind='flag'},@{Kind='malformed'},@{Kind='malformed entry'},@{Kind='allowlist'},@{Kind='config'},@{Kind='expected revision'},@{Kind='implementation'}
        ) {
            switch ($Kind) {
                flag {$group.Remove('restricted_to_workflows')}
                malformed {$group.restricted_to_workflows='true'}
                'malformed entry' {$group.selected_workflows=@(42)}
                allowlist {$group.Remove('selected_workflows')}
                config {$fixture[$configKey]=New-ApiFailure 403}
                'expected revision' {$config.SharedRevision=''}
                implementation {$fixture[$sharedKey]=New-ApiFailure 404}
            }
            $r=Invoke-DpValidation $config $env:CLC_PREREQUISITES_YAML
            $name=if ($Kind -eq 'implementation') {'Shared deployment implementation inspection'} else {'Runner selected-workflow access'}
            ($r.results | Where-Object name -EQ $name).status | Should -Be UNVERIFIED
            $r.ready | Should -BeFalse
        }
        It 'rejects mismatched protected orchestration and route <Field>' -ForEach @(
            @{Field='sharedRevision'},@{Field='repository'},@{Field='integrationBranch'},@{Field='environment'},@{Field='runnerGroup'},@{Field='enabled'},@{Field='runnerAdmissionReady'}
        ) {
            switch ($Field) {
                sharedRevision {$releaseConfig.orchestration.sharedRevision='c'*40}
                repository {$releaseConfig.repository='clcdpc/other'}
                integrationBranch {$releaseConfig.integrationBranch='unsafe'}
                enabled {$releaseConfig.targets[0].enabled=$false}
                runnerAdmissionReady {$releaseConfig.targets[0].runnerAdmissionReady=$false}
                default {$releaseConfig.targets[0][$Field]='other'}
            }
            $fixture[$configKey]=New-WorkflowFile ($releaseConfig | ConvertTo-Json -Depth 10)
            $r=Invoke-DpValidation $config $env:CLC_PREREQUISITES_YAML
            $r.failed_count | Should -BeGreaterThan 0
            $r.ready | Should -BeFalse
        }
        It 'does not classify malformed protected JSON as verified admission' {
            $fixture[$configKey]=New-WorkflowFile '{"contractVersion":1,"contractVersion":1}'
            $r=Invoke-DpValidation $config $env:CLC_PREREQUISITES_YAML
            ($r.results | Where-Object name -EQ 'Shared privileged workflow identity').status | Should -Be UNVERIFIED
        }
        It 'preserves a verified disabled restriction even when other admission evidence is missing' {
            $group.restricted_to_workflows=$false
            $group.Remove('selected_workflows')
            $fixture[$configKey]=New-ApiFailure 403
            $r=Invoke-DpValidation $config $env:CLC_PREREQUISITES_YAML
            ($r.results | Where-Object name -EQ 'Runner selected-workflow access').status | Should -Be FAIL
            $r.github_status | Should -Be FAIL
        }
        It 'assesses cross-organization shared admission using observed inheritance: <Kind>' -ForEach @(
            @{Kind='non-inherited organization group';Inherited=$false;Expected='FAIL'},
            @{Kind='inherited enterprise group';Inherited=$true;Expected='UNVERIFIED'},
            @{Kind='missing ownership evidence';Inherited=$null;Expected='UNVERIFIED'},
            @{Kind='malformed ownership evidence';Inherited='false';Expected='UNVERIFIED'}
        ) {
            $config.Repository='other/app'
            $crossOrgFixture=@{}
            foreach ($entry in $fixture.GetEnumerator()) {
                $crossOrgFixture[$entry.Key.Replace('clcdpc/app','other/app').Replace('/orgs/clcdpc/','/orgs/other/')]= $entry.Value
            }
            $fixture=$crossOrgFixture
            $fixture['/repos/other/app'].data.full_name='other/app'
            $fixture['/orgs/other/actions/runner-groups/7/repositories'].data.repositories[0].full_name='other/app'
            $group.selected_workflows[1]='other/app/.github/workflows/diagnose.yml@refs/heads/master'
            if ($null -eq $Inherited) { $group.Remove('inherited') } else { $group.inherited=$Inherited }
            $releaseConfig.repository='other/app'
            $crossConfigKey=$configKey.Replace('clcdpc/app','other/app')
            $fixture[$crossConfigKey]=New-WorkflowFile ($releaseConfig | ConvertTo-Json -Depth 10)
            $r=Invoke-DpValidation $config $env:CLC_PREREQUISITES_YAML
            ($r.results | Where-Object name -EQ 'Shared privileged workflow identity').status | Should -Be PASS
            ($r.results | Where-Object name -EQ 'Runner selected-workflow access').status | Should -BeExactly $Expected
            if ($Expected -ceq 'UNVERIFIED') { $r.failed_count | Should -Be 0 }
            $r.ready | Should -BeFalse
        }
        It 'preserves known allowlist mismatches when protected configuration is unavailable: <Kind>' -ForEach @(
            @{Kind='exact expected selection';Expected='UNVERIFIED'},
            @{Kind='additional workflow';Expected='FAIL'},
            @{Kind='wrong shared workflow';Expected='FAIL'},
            @{Kind='wrong shared revision';Expected='FAIL'}
        ) {
            $fixture[$configKey]=New-ApiFailure 403
            switch ($Kind) {
                'additional workflow' {$group.selected_workflows+='clcdpc/app/.github/workflows/untrusted.yml@refs/heads/master'}
                'wrong shared workflow' {$group.selected_workflows[0]=$group.selected_workflows[0].Replace('application-deploy.yml','untrusted.yml')}
                'wrong shared revision' {$group.selected_workflows[0]=$group.selected_workflows[0].Replace('a'*40,'c'*40)}
            }
            $r=Invoke-DpValidation $config $env:CLC_PREREQUISITES_YAML
            ($r.results | Where-Object name -EQ 'Shared privileged workflow identity').status | Should -Be UNVERIFIED
            ($r.results | Where-Object name -EQ 'Runner selected-workflow access').status | Should -BeExactly $Expected
            $r.github_status | Should -BeExactly $Expected
            $r.ready | Should -BeFalse
        }
        It 'does not claim full configuration validity from a malformed version or activation type' -ForEach @('version','activation') {
            if ($_ -ceq 'version') { $releaseConfig.contractVersion='1' }
            else { $releaseConfig.targets[0].enabled='true' }
            $fixture[$configKey]=New-WorkflowFile ($releaseConfig | ConvertTo-Json -Depth 10)
            $r=Invoke-DpValidation $config $env:CLC_PREREQUISITES_YAML
            $name=if ($_ -ceq 'version') {'Shared privileged workflow identity'} else {'Activation indicator'}
            ($r.results | Where-Object name -EQ $name).status | Should -Be UNVERIFIED
        }
        It 'rejects an unprotected dispatch source through existing branch enforcement' {
            $fixture['/repos/clcdpc/app/branches/master'].data.protected=$false
            $fixture['/repos/clcdpc/app/branches/master/protection']=New-ApiFailure 404
            $r=Invoke-DpValidation $config $env:CLC_PREREQUISITES_YAML
            ($r.results | Where-Object name -EQ 'Required pull requests').status | Should -Be FAIL
        }
        It 'rejects a dispatch caller that always selects automatic admission' {
            $fixture[$callerKey]=New-WorkflowFile ($caller.Replace("automatic: `${{ github.event_name != 'workflow_dispatch' }}",'automatic: true'))
            $r=Invoke-DpValidation $config $env:CLC_PREREQUISITES_YAML
            ($r.results | Where-Object name -EQ 'Manual shared operation selection').status | Should -Be FAIL
        }
        It 'does not invent automatic completion evidence for an inconclusive handoff' {
            $fixture[$callerKey]=New-WorkflowFile ($caller.Replace('  workflow_run:', '  unsupported_handoff:'))
            $r=Invoke-DpValidation $config $env:CLC_PREREQUISITES_YAML
            ($r.results | Where-Object name -EQ 'Automatic release-completion trigger').status | Should -Be UNVERIFIED
        }
    }
}

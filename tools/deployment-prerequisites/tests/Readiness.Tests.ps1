BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '../Validation.psm1') -Force
    $root=Join-Path $PSScriptRoot '../../..'
    Import-Module (Join-Path $root 'src/CLC.Deployment/CLC.Deployment.psd1') -Force
    $m=Get-Module CLC.Deployment
    . $m {param($Path) . $Path} (Join-Path $root 'tools/deployment-prerequisites/Host.ps1')
}

Describe 'Contract 3 commissioning reports' {
    BeforeAll {. (Join-Path $PSScriptRoot 'Fixtures.ps1')}
    BeforeEach {
        $config=New-ValidationConfig
        $g=@(New-PassingStageChecks github);$h=@(New-PassingStageChecks host)
    }
    It 'returns READY for sufficient initial infrastructure with no deployed application or standing authorization' {
        foreach ($id in @('host.state.current-release','host.state.inventory')) {
            $row=$h | Where-Object id -EQ $id;$row.status='NOT_APPLICABLE';$row.reason='empty-target';$row.detail='Verified empty target.'
        }
        $h+=New-ClcDeploymentPrerequisiteCheck host.standing.policy NOT_APPLICABLE 'Not needed for independently approved initial deployment.' -Reason not-selected
        $h+=New-ClcDeploymentPrerequisiteCheck host.application.acceptance UNVERIFIED 'Application deployment/recovery acceptance remains separate.' 'Perform separately authorized application acceptance.'
        $r=Merge-ClcDeploymentPrerequisiteReports (New-ClcDeploymentPrerequisiteReport $config $g) (New-ClcDeploymentPrerequisiteReport $config $h) -HostJobResult success
        $r.contract_version | Should -Be 3
        $r.ready | Should -BeTrue
        $r.github_status | Should -Be PASS
        $r.host_status | Should -Be PASS
        $r.counts.not_applicable | Should -Be 3
        $summary=Format-ClcDeploymentPrerequisiteSummary $r
        $summary | Should -Match '^# READY'
        $summary | Should -Match '\| \*\*UNVERIFIED\*\* · Advisory \| Application acceptance \|'
    }
    It 'blocks required <Status> with category <Expected>' -ForEach @(
        @{Status='FAIL';Expected='FAIL'},@{Status='UNVERIFIED';Expected='UNVERIFIED'},@{Status='SKIPPED';Expected='UNVERIFIED'}
    ) {
        $row=$h | Where-Object id -EQ host.state.consistency;$row.status=$Status;$row.action='Reconcile protected state.';$row.reason='state-unavailable'
        $r=Merge-ClcDeploymentPrerequisiteReports (New-ClcDeploymentPrerequisiteReport $config $g) (New-ClcDeploymentPrerequisiteReport $config $h) -HostJobResult success
        $r.ready | Should -BeFalse;$r.host_status | Should -Be $Expected
    }
    It 'allows visible advisory <Status> without blocking READY' -ForEach @(@{Status='UNVERIFIED'},@{Status='SKIPPED'},@{Status='FAIL'}) {
        $g+=New-ClcDeploymentPrerequisiteCheck github.routing.activation $Status 'Optional activation remains pending.' 'Enable when independently authorized.' -Reason pending-activation
        $r=Merge-ClcDeploymentPrerequisiteReports (New-ClcDeploymentPrerequisiteReport $config $g) (New-ClcDeploymentPrerequisiteReport $config $h) -HostJobResult success
        $r.ready | Should -BeTrue
        (Format-ClcDeploymentPrerequisiteSummary $r) | Should -Match 'Optional activation remains pending'
    }
    It 'cannot establish overall readiness from a single <Category> inspector' -ForEach @(@{Category='github'},@{Category='host'}) {
        $rows=if ($Category -eq 'github') {$g} else {$h}
        $report=New-ClcDeploymentPrerequisiteReport $config $rows
        $report.ready | Should -BeFalse
        (Format-ClcDeploymentPrerequisiteSummary $report) | Should -Match 'inspection: \*\*SKIPPED\*\*'
    }
    It 'reports missing host inspection as SKIPPED without fabricating its checks' {
        $r=Merge-ClcDeploymentPrerequisiteReports (New-ClcDeploymentPrerequisiteReport $config $g) $null
        $r.ready | Should -BeFalse
        @($r.checks | Where-Object category -EQ host).Count | Should -Be 1
        ($r.checks | Where-Object id -EQ host.stage).status | Should -Be SKIPPED
    }
    It 'retains a confirmed FAIL from an unsuccessful host stage' {
        $h[0].status='FAIL';$h[0].action='Correct actual missing component.'
        $r=Merge-ClcDeploymentPrerequisiteReports (New-ClcDeploymentPrerequisiteReport $config $g) (New-ClcDeploymentPrerequisiteReport $config $h) -HostJobResult failure
        $r.host_status | Should -Be FAIL
        ($r.checks | Where-Object id -EQ $h[0].id).action | Should -Be 'Correct actual missing component.'
    }
    It 'rejects contradictory <Mutation> serialized report data' -ForEach @(
        @{Mutation='v2'},@{Mutation='missing field'},@{Mutation='invalid status'},@{Mutation='wrong category'},@{Mutation='duplicate id'},
        @{Mutation='required override'},@{Mutation='false counts'},@{Mutation='false ready'},@{Mutation='large'},@{Mutation='unknown id'},@{Mutation='false inapplicable'},@{Mutation='Test channel'}
    ) {
        $r=New-ClcDeploymentPrerequisiteReport $config $g
        $r=$r | ConvertTo-Json -Depth 16 | ConvertFrom-Json -AsHashtable
        switch ($Mutation) {
            v2 {$r.contract_version=2}
            'Test channel' {$r.subject.channel='Test'}
            'missing field' {$r.Remove('subject')}
            'invalid status' {$r.checks[0].status='READY_WITH_WARNINGS'}
            'wrong category' {$r.checks[0].category='host'}
            'duplicate id' {$r.checks+= $r.checks[0]}
            'required override' {$r.checks[0].required=$false}
            'false counts' {$r.counts.passed=0}
            'false ready' {$r.ready=$true}
            large {$r.checks[0].detail='x'*1048577}
            'unknown id' {$r.checks[0].id='github.invented'}
            'false inapplicable' {$r.checks[0].status='NOT_APPLICABLE';$r.checks[0].reason='caller-waiver'}
        }
        ConvertTo-ClcDeploymentPrerequisiteStageReport $r | Should -BeNullOrEmpty
    }
    It 'does not allow omitted required check identities to grant PASS' {
        $report=New-ClcDeploymentPrerequisiteReport $config @($g | Select-Object -First 1)
        $report.github_status | Should -Be UNVERIFIED
    }
    It 'rejects duplicate IDs at construction' {
        {New-ClcDeploymentPrerequisiteReport $config @($g[0],$g[0])} | Should -Throw
    }
    It 'uses IDs independently of human titles and orders findings deterministically' {
        $g[0].name='Renamed operator title'
        $r=Merge-ClcDeploymentPrerequisiteReports (New-ClcDeploymentPrerequisiteReport $config @($g | Sort-Object id -Descending)) (New-ClcDeploymentPrerequisiteReport $config $h) -HostJobResult success
        $r.ready | Should -BeTrue
        ($r.checks.id -join ',') | Should -Be (@($r.checks.id | Sort-Object -CaseSensitive) -join ',')
        (Format-ClcDeploymentPrerequisiteSummary $r) | Should -Match 'Renamed operator title'
    }
    It 'prevents cross-subject aggregation for <Field>' -ForEach @(
        @{Field='Repository';Value='other/app'},@{Field='ApplicationId';Value='other'},@{Field='TargetId';Value='other'},
        @{Field='EnvironmentName';Value='other'},@{Field='DeploymentChannel';Value='Production'},@{Field='IntegrationBranch';Value='main'}
    ) {
        $github=New-ClcDeploymentPrerequisiteReport $config $g
        $config[$Field]=$Value
        $r=Merge-ClcDeploymentPrerequisiteReports $github (New-ClcDeploymentPrerequisiteReport $config $h) -HostJobResult success
        $r.ready | Should -BeFalse
        ($r.checks | Where-Object id -EQ host.report.subject).status | Should -Be FAIL
    }
    It 'rejects a stage claiming observations from the other category' {
        $github=New-ClcDeploymentPrerequisiteReport $config @($g+$h)
        $r=Merge-ClcDeploymentPrerequisiteReports $github (New-ClcDeploymentPrerequisiteReport $config $h) -HostJobResult success
        $r.ready | Should -BeFalse
        ($r.checks | Where-Object id -EQ github.stage).status | Should -Be UNVERIFIED
    }
    It 'publishes available findings and exits nonzero for NOT READY, zero only for READY' {
        $github=Join-Path $TestDrive 'github.json';$hostReport=Join-Path $TestDrive 'host.json';$summary=Join-Path $TestDrive 'summary.md'
        New-ClcDeploymentPrerequisiteReport $config $g | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $github
        New-ClcDeploymentPrerequisiteReport $config $h | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $hostReport
        $original=$env:GITHUB_STEP_SUMMARY;$env:GITHUB_STEP_SUMMARY=$summary
        try {
            $entry=Join-Path $PSScriptRoot '../Merge-DeploymentReadiness.ps1'
            & (Get-Process -Id $PID).Path -NoProfile -File $entry -GitHubReportPath $github -HostReportPath $hostReport -GitHubJobResult success -HostJobResult success
            $LASTEXITCODE | Should -Be 0
            & (Get-Process -Id $PID).Path -NoProfile -File $entry -GitHubReportPath $github -GitHubJobResult success
            $LASTEXITCODE | Should -Be 1
            Get-Content -LiteralPath $summary -Raw | Should -Match 'READY|NOT READY|SKIPPED'
        } finally {$env:GITHUB_STEP_SUMMARY=$original}
    }
}

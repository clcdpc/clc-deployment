BeforeAll {
    . "$PSScriptRoot/../../Support.ps1"
    . "$PSScriptRoot/../../T2Support.ps1"
    . "$PSScriptRoot/../../T3Support.ps1"
    . "$PSScriptRoot/../Scripts/Qualification.Scenarios.ps1"
}
Describe 'Retained qualification assertions against synthetic IIS and real phase/filesystem state' {
    BeforeEach {
        $fixture=New-T2Fixture; Set-T2FixtureInModule $fixture; Set-T3Mocks
        Write-TestJson $fixture.target.operationalConfigPath @{configurationRevision='example-001'}
        $initial=New-T3Approval $fixture -Nested
        $newer=New-T3Approval $fixture probe-approval-002 2L
        $configuration=$fixture.target.Clone(); $configuration.probeReleases=@{}
        foreach ($entry in @(@{slot='initial';approval=$initial},@{slot='newer';approval=$newer})) {
            $a=$entry.approval
            $configuration.probeReleases[$entry.slot]=@{approvalId=$a.record.approvalId;releaseId=$a.record.releaseId;
                sourceCommit=$a.record.sourceCommit;archiveSha256=$a.package.archiveSha256;manifestSha256=$a.record.manifestSha256}
        }
        Mock Get-QControlRoot { $global:ClcTestFixture.controlRoot }
        Mock Get-QPoolObservation { @{poolState=$global:ClcTestFixture.iis.poolState;workers=$global:ClcTestFixture.iis.workers} }
    }
    AfterEach { Remove-TestWorkspace $fixture.workspace }
    It 'verifies initial and upgrade backups and terminal state without per-file ownership records' {
        $before=Get-QSnapshot $configuration
        $result=Invoke-ClcIisDeployment example $initial.record.approvalId
        $installed=Get-QSnapshot $configuration
        Assert-QLifecycleResult $configuration @{success=$true;result=$result} $installed Deployed initial
        (Assert-QBackupAndPublication $configuration $before $installed).terminalVerified | Should -BeTrue

        $result=Invoke-ClcIisDeployment example $newer.record.approvalId
        $upgraded=Get-QSnapshot $configuration
        Assert-QLifecycleResult $configuration @{success=$true;result=$result} $upgraded Deployed newer
        (Assert-QBackupAndPublication $configuration $installed $upgraded).backupVerified | Should -BeTrue
        Get-QCurrentSlot $configuration $upgraded | Should -BeExactly newer
        $attemptRoot=Join-Path $fixture.controlRoot ('attempts\'+$result.attemptId)
        @(Get-ChildItem -LiteralPath $attemptRoot -Filter 'temporary-*.json').Count | Should -Be 0

        $result=Invoke-ClcIisDeployment example $newer.record.approvalId
        $noOp=Get-QSnapshot $configuration
        Assert-QLifecycleResult $configuration @{success=$true;result=$result} $noOp NoOp newer
        $noOp.state.current.sha256 | Should -BeExactly $upgraded.state.current.sha256
        Get-QCurrentSlot $configuration $noOp | Should -BeExactly newer

        # A changed terminal record must still be rejected by the harness.
        [IO.File]::AppendAllText((Join-Path $attemptRoot 'deployment.json'),' ')
        { Assert-QBackupAndPublication $configuration $installed $upgraded } | Should -Throw '*terminal snapshot differ*'
        $upgraded.state.current.safe.release.sourceCommit='f'*40
        { Get-QCurrentSlot $configuration $upgraded } | Should -Throw '*exact campaign release*'
    }
    It 'checks failed-readiness backup preservation and explicit recovery without inbox or historical ZIPs' {
        $null=Invoke-ClcIisDeployment example $initial.record.approvalId
        $global:ClcLifecycle.ready=$false
        Mock -ModuleName CLC.Deployment Get-ClcReadinessElapsed { 121 }
        Test-TestRejection { Invoke-ClcIisDeployment example $newer.record.approvalId } 'Clc.ReadinessFailed*'
        $failed=Get-QSnapshot $configuration
        $failed.poolState | Should -BeExactly Stopped
        $failed.state.journal.safe.phase | Should -BeExactly RecoveryRequired
        $failed.state.journal.safe.backup.verified | Should -BeTrue
        $backup=Join-Path $fixture.controlRoot ('backups\'+$failed.state.journal.safe.attemptId+'\application')
        $before=Get-TestTreeHashes $backup
        Test-TestRejection { Invoke-ClcIisDeployment example $newer.record.approvalId } 'Clc.RecoveryRequired*'
        foreach ($a in @($initial,$newer)) { Remove-Item -LiteralPath (Join-Path $fixture.target.artifactInboxRoot ($a.record.approvalId+'.zip')) }
        @(Get-ChildItem -LiteralPath (Join-Path $fixture.controlRoot 'releases') -Filter '*.zip').Count | Should -Be 0

        $global:ClcLifecycle.ready=$true
        Mock -ModuleName CLC.Deployment Get-ClcReadinessElapsed { 0 }
        $result=Restore-ClcIisDeployment example $failed.state.journal.safe.attemptId RestorePrevious incident
        $restored=Get-QSnapshot $configuration
        Assert-QLifecycleResult $configuration @{success=$true;result=$result} $restored RestoredPrevious initial
        (Get-TestTreeHashes $backup) | Should -BeExactly $before
        $manifest=Join-Path $fixture.controlRoot ('releases\'+$initial.record.approvalId+'.json')
        [IO.File]::AppendAllText($manifest,' ')
        { Read-QRetainedManifest $configuration initial } | Should -Throw '*Retained manifest differs*'
    }
}

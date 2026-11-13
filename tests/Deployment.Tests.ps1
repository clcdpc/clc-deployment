BeforeAll { . "$PSScriptRoot/Support.ps1"; . "$PSScriptRoot/T2Support.ps1"; . "$PSScriptRoot/T3Support.ps1" }
Describe 'Complete file-only IIS deployment with synthetic IIS and actual NTFS effects' {
    BeforeEach {
        $fixture=New-T2Fixture; Set-T2FixtureInModule $fixture; Set-T3Mocks
        $approval=New-T3Approval $fixture
    }
    AfterEach { Remove-TestWorkspace $fixture.workspace }
    It 'deploys a first installation, starts idle then verifies a worker and durable ready generation' {
        $result=Invoke-ClcIisDeployment example $approval.record.approvalId
        $result.status | Should -Be Deployed; $result.currentGeneration | Should -Be 1; $result.workerCount | Should -Be 1
        (Get-TestTreeHashes $fixture.target.applicationRoot) | Should -BeExactly (Get-TestTreeHashes $approval.publish)
        $journal=Get-Content -LiteralPath (Join-Path $fixture.controlRoot 'journal.json') -Raw | ConvertFrom-Json
        $journal.phase | Should -Be Completed; $journal.outcome | Should -Be Deployed
        (Get-FileHash -LiteralPath (Join-Path $fixture.controlRoot ('attempts\'+$result.attemptId+'\deployment.json'))).Hash | Should -Be ((Get-FileHash -LiteralPath (Join-Path $fixture.controlRoot 'journal.json')).Hash)
        # An initially stopped pool needs no stop dispatch.
        @($global:ClcLifecycle.operations) | Should -Contain Start
    }
    It 'completes <Repetitions> healthy NoOps without staging or changing application files and current state' -ForEach @(@{Repetitions=1},@{Repetitions=3}) {
        $first=Invoke-ClcIisDeployment example $approval.record.approvalId
        $applicationBefore=Get-TestTreeHashes $fixture.target.applicationRoot
        $applicationWritesBefore=@(Get-ChildItem -LiteralPath $fixture.target.applicationRoot -Recurse -File | ForEach-Object { $_.LastWriteTimeUtc.Ticks })
        $currentPath=Join-Path $fixture.controlRoot 'current.json'
        $currentBefore=(Get-FileHash -LiteralPath $currentPath).Hash
        $currentWriteBefore=(Get-Item -LiteralPath $currentPath).LastWriteTimeUtc.Ticks
        $stageRoot=Join-Path $fixture.controlRoot 'staging'
        $stageEntriesBefore=@(Get-ChildItem -LiteralPath $stageRoot -Recurse -Force | ForEach-Object FullName)
        $stageFilesBefore=Get-TestTreeHashes $stageRoot
        Mock -ModuleName CLC.Deployment Expand-ClcApprovedRelease { throw 'A healthy NoOp must not extract or stage.' }
        Mock -ModuleName CLC.Deployment New-ClcVerifiedBackup { throw 'A healthy NoOp must not back up.' }
        Mock -ModuleName CLC.Deployment Invoke-ClcManagedReplacement { throw 'A healthy NoOp must not replace files.' }
        for ($i=0;$i -lt $Repetitions;$i++) {
            $fixture.iis.workers=@(); $global:ClcLifecycle.operations.Clear()
            $noop=Invoke-ClcIisDeployment example $approval.record.approvalId
            $noop.status | Should -BeExactly NoOp
            $noop.currentGeneration | Should -Be $first.currentGeneration
            $noop.observedPoolState | Should -BeExactly Started; $noop.workerCount | Should -Be 1
            @($global:ClcLifecycle.operations) | Should -Be @('Validate','Ready')
            Test-Path -LiteralPath (Join-Path $stageRoot $noop.attemptId) | Should -BeFalse
            @(Get-ChildItem -LiteralPath $stageRoot -Recurse -Force | ForEach-Object FullName) | Should -Be $stageEntriesBefore
            (Get-TestTreeHashes $stageRoot) | Should -BeExactly $stageFilesBefore
            (Get-TestTreeHashes $fixture.target.applicationRoot) | Should -BeExactly $applicationBefore
            @(Get-ChildItem -LiteralPath $fixture.target.applicationRoot -Recurse -File | ForEach-Object { $_.LastWriteTimeUtc.Ticks }) | Should -Be $applicationWritesBefore
            (Get-FileHash -LiteralPath $currentPath).Hash | Should -BeExactly $currentBefore
            (Get-Item -LiteralPath $currentPath).LastWriteTimeUtc.Ticks | Should -Be $currentWriteBefore
            $journalPath=Join-Path $fixture.controlRoot 'journal.json'
            $journal=Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
            $journal.phase | Should -BeExactly Completed; $journal.outcome | Should -BeExactly NoOp
            $journal.previous.attemptId | Should -BeExactly $first.attemptId
            $journal.liveMutationIntent | Should -BeFalse
            $journal.backup | Should -BeNullOrEmpty; $journal.publishedGeneration | Should -BeNullOrEmpty
            (Get-FileHash -LiteralPath (Join-Path $fixture.controlRoot ('attempts\'+$noop.attemptId+'\deployment.json'))).Hash | Should -BeExactly (Get-FileHash -LiteralPath $journalPath).Hash
        }
        Should -Invoke Expand-ClcApprovedRelease -ModuleName CLC.Deployment -Times 0 -Exactly
        Should -Invoke New-ClcVerifiedBackup -ModuleName CLC.Deployment -Times 0 -Exactly
        Should -Invoke Invoke-ClcManagedReplacement -ModuleName CLC.Deployment -Times 0 -Exactly
        Should -Invoke Start-ClcApplicationValidator -ModuleName CLC.Deployment -Times $Repetitions -Exactly -ParameterFilter {
            $Dll -ceq (Join-Path $global:ClcTestFixture.target.applicationRoot 'Probe.dll')
        }
    }
    It 'upgrades, performs fresh idle-pool NoOp, restarts for new configuration and explicitly restores the latest prior backup offline' {
        $first=Invoke-ClcIisDeployment example $approval.record.approvalId
        $stagesBefore=@(Get-ChildItem -LiteralPath (Join-Path $fixture.controlRoot 'staging') -Directory).Count
        $global:ClcTestFixture.iis.workers=@()
        $global:ClcLifecycle.operations.Clear()
        $noop=Invoke-ClcIisDeployment example $approval.record.approvalId
        $noop.status | Should -Be NoOp; $noop.currentGeneration | Should -Be 1
        $noop.workerCount | Should -Be 1
        @($global:ClcLifecycle.operations) | Should -Contain Ready
        @($global:ClcLifecycle.operations) | Should -Not -Contain Stop
        @($global:ClcLifecycle.operations) | Should -Not -Contain Start
        @(Get-ChildItem -LiteralPath (Join-Path $fixture.controlRoot 'staging') -Directory).Count | Should -Be $stagesBefore
        $global:ClcLifecycle.revision='example-002'
        [IO.File]::WriteAllText($fixture.target.operationalConfigPath,'Changed synthetic configuration with a new revision')
        $global:ClcLifecycle.operations.Clear()
        $restart=Invoke-ClcIisDeployment example $approval.record.approvalId
        $restart.status | Should -Be Deployed; $restart.currentGeneration | Should -Be 2
        @($global:ClcLifecycle.operations) | Should -Contain Stop
        @($global:ClcLifecycle.operations) | Should -Contain Start
        @(Get-ChildItem -LiteralPath (Join-Path $fixture.controlRoot 'staging') -Directory).Count | Should -Be ($stagesBefore+1)
        $newer=New-T3Approval $fixture probe-approval-002 2L
        $upgrade=Invoke-ClcIisDeployment example $newer.record.approvalId
        $upgrade.status | Should -BeExactly Deployed; $upgrade.currentGeneration | Should -Be 3
        @(Get-ChildItem -LiteralPath (Join-Path $fixture.controlRoot 'staging') -Directory).Count | Should -Be ($stagesBefore+2)
        (Get-TestTreeHashes $fixture.target.applicationRoot) | Should -BeExactly (Get-TestTreeHashes $newer.publish)
        # Exact retained manifest, verified backup and protected approvals must be sufficient with no inbox.
        Get-ChildItem -LiteralPath $fixture.target.artifactInboxRoot -File | Remove-Item -Force
        $restored=Restore-ClcIisDeployment example $upgrade.attemptId RestorePrevious synthetic-incident
        $restored.status | Should -Be RestoredPrevious; $restored.currentGeneration | Should -Be 4
        (Get-TestTreeHashes $fixture.target.applicationRoot) | Should -BeExactly (Get-TestTreeHashes $approval.publish)
    }
    It 'restarts an unchanged release when only the configuration revision changes' {
        $null=Invoke-ClcIisDeployment example $approval.record.approvalId
        $configBefore=(Get-FileHash -LiteralPath $fixture.target.operationalConfigPath).Hash
        $global:ClcLifecycle.revision='example-002'; $global:ClcLifecycle.operations.Clear()
        $restart=Invoke-ClcIisDeployment example $approval.record.approvalId
        $restart.status | Should -BeExactly Deployed; $restart.currentGeneration | Should -Be 2
        @($global:ClcLifecycle.operations) | Should -Contain Stop
        @($global:ClcLifecycle.operations) | Should -Contain Start
        Test-Path -LiteralPath (Join-Path $fixture.controlRoot ('staging\'+$restart.attemptId+'\application')) | Should -BeTrue
        (Get-FileHash -LiteralPath $fixture.target.operationalConfigPath).Hash | Should -BeExactly $configBefore
        (Get-Content -LiteralPath (Join-Path $fixture.controlRoot 'current.json') -Raw | ConvertFrom-Json).configuration.revision | Should -BeExactly example-002
    }
    It 'uses normal staging and deployment after a failed NoOp probe with readiness after restart <ReadyAfterRestart>' -ForEach @(@{ReadyAfterRestart=$true},@{ReadyAfterRestart=$false}) {
        $null=Invoke-ClcIisDeployment example $approval.record.approvalId
        $currentPath=Join-Path $fixture.controlRoot 'current.json'; $currentBefore=(Get-FileHash -LiteralPath $currentPath).Hash
        $global:ClcLifecycle.operations.Clear(); $global:ClcReadyAfterRestart=$ReadyAfterRestart
        Mock -ModuleName CLC.Deployment Invoke-ClcReadinessRequest {
            $global:ClcLifecycle.ready=$global:ClcReadyAfterRestart -and $global:ClcLifecycle.operations.Contains('Start')
            return Get-T3SyntheticReadiness
        }
        Mock -ModuleName CLC.Deployment Get-ClcReadinessElapsed {
            if (-not $global:ClcReadyAfterRestart -and $global:ClcLifecycle.operations.Contains('Start')) { return 120 }
            return 0
        }
        if ($ReadyAfterRestart) {
            $result=Invoke-ClcIisDeployment example $approval.record.approvalId
            $result.status | Should -BeExactly Deployed; $result.currentGeneration | Should -Be 2
        } else {
            Test-TestRejection { Invoke-ClcIisDeployment example $approval.record.approvalId } 'Clc.ReadinessFailed*'
            $fixture.iis.poolState | Should -BeExactly Stopped
            (Get-FileHash -LiteralPath $currentPath).Hash | Should -BeExactly $currentBefore
        }
        @($global:ClcLifecycle.operations)[0..1] | Should -Be @('Validate','Ready')
        @($global:ClcLifecycle.operations) | Should -Contain Stop
        @($global:ClcLifecycle.operations) | Should -Contain Start
        $journal=Get-Content -LiteralPath (Join-Path $fixture.controlRoot 'journal.json') -Raw | ConvertFrom-Json
        $journal.backup.verified | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $fixture.controlRoot ('staging\'+$journal.attemptId+'\application')) | Should -BeTrue
        if ($ReadyAfterRestart) {
            $journal.phase | Should -BeExactly Completed; $journal.outcome | Should -BeExactly Deployed
        } else {
            $journal.phase | Should -BeExactly RecoveryRequired
            $before=Get-T2TreeHashes $fixture; $global:ClcLifecycle.operations.Clear()
            Test-TestRejection { Invoke-ClcIisDeployment example $approval.record.approvalId } 'Clc.RecoveryRequired*'
            (Get-T2TreeHashes $fixture) | Should -BeExactly $before
            $global:ClcLifecycle.operations.Count | Should -Be 0
        }
    }
    It 'rechecks the approved ZIP before an otherwise healthy NoOp' {
        $null=Invoke-ClcIisDeployment example $approval.record.approvalId
        [IO.File]::AppendAllText((Join-Path $fixture.target.artifactInboxRoot ($approval.record.approvalId+'.zip')),'changed')
        $before=Get-T2TreeHashes $fixture; $global:ClcLifecycle.operations.Clear()
        Test-TestRejection { Invoke-ClcIisDeployment example $approval.record.approvalId }
        (Get-T2TreeHashes $fixture) | Should -BeExactly $before
        $global:ClcLifecycle.operations.Count | Should -Be 0
    }
    It 'rejects a disabled approval without IIS, control or application writes' {
        $approval.record.enabled=$false; Write-TestJson $approval.path $approval.record
        $before=Get-T2TreeHashes $fixture
        Test-TestRejection { Invoke-ClcIisDeployment example $approval.record.approvalId } 'Clc.ApprovalDisabled*'
        (Get-T2TreeHashes $fixture) | Should -BeExactly $before
        @($global:ClcLifecycle.operations).Count | Should -Be 0
        @([IO.Directory]::EnumerateFileSystemEntries($fixture.controlRoot)).Count | Should -Be 0
    }
    It 'preserves an initially <Initial> pool on approved validator failure' -ForEach @(@{Initial='Started'},@{Initial='Stopped'}) {
        $fixture.iis.poolState=$Initial; $fixture.iis.workers=@()
        Mock -ModuleName CLC.Deployment Start-ClcApplicationValidator { return Start-T3HarmlessHelper 'secret-output-sentinel' 1 }
        Test-TestRejection { Invoke-ClcIisDeployment example $approval.record.approvalId } 'Clc.ConfigurationInvalid*'
        $fixture.iis.poolState | Should -Be $Initial
        @($global:ClcLifecycle.operations) | Should -Not -Contain Stop
        @($global:ClcLifecycle.operations) | Should -Not -Contain Start
        @([IO.Directory]::EnumerateFileSystemEntries($fixture.target.applicationRoot)).Count | Should -Be 0
        $j=Get-Content -LiteralPath (Join-Path $fixture.controlRoot 'journal.json') -Raw | ConvertFrom-Json
        $j.outcome | Should -Be FailedPreserved
        (Get-Content -LiteralPath (Join-Path $fixture.controlRoot 'journal.json') -Raw) | Should -Not -Match 'secret-output-sentinel'
    }
    It 'retains a stopped complete candidate after failed readiness and explicitly accepts it with fresh readiness' {
        $global:ClcLifecycle.ready=$false
        Mock -ModuleName CLC.Deployment Get-ClcReadinessElapsed { if ($global:ClcLifecycle.ready) { return 0 }; return 120 }
        Test-TestRejection { Invoke-ClcIisDeployment example $approval.record.approvalId } 'Clc.ReadinessFailed*'
        $j=Get-Content -LiteralPath (Join-Path $fixture.controlRoot 'journal.json') -Raw | ConvertFrom-Json
        $j.phase | Should -Be RecoveryRequired; $fixture.iis.poolState | Should -Be Stopped
        $before=Get-T2TreeHashes $fixture; $global:ClcLifecycle.operations.Clear()
        Test-TestRejection { Invoke-ClcIisDeployment example $approval.record.approvalId } 'Clc.RecoveryRequired*'
        (Get-T2TreeHashes $fixture) | Should -BeExactly $before
        @($global:ClcLifecycle.operations).Count | Should -Be 0
        $global:ClcLifecycle.ready=$true
        $recovered=Restore-ClcIisDeployment example $j.attemptId AcceptCandidate synthetic-incident
        $recovered.status | Should -Be AcceptedCandidate; $recovered.workerCount | Should -Be 1
    }
    It 'retains a partial first install and explicitly restores its empty stopped guard baseline' {
        $global:ClcCopyOriginal=& (Get-Module CLC.Deployment) { (Get-Command Copy-ClcPayloadFile).ScriptBlock }
        $global:ClcFailCopy=$true
        Mock -ModuleName CLC.Deployment Copy-ClcPayloadFile {
            if ($global:ClcFailCopy -and $Destination.StartsWith($global:ClcTestFixture.target.applicationRoot) -and $Destination.EndsWith('Probe.dll')) {
                [IO.File]::WriteAllText($Destination,'partial')
                throw 'Injected copy failure'
            }
            & $global:ClcCopyOriginal $Source $Destination $Overwrite
        }
        Test-TestRejection { Invoke-ClcIisDeployment example $approval.record.approvalId }
        $j=Get-Content -LiteralPath (Join-Path $fixture.controlRoot 'journal.json') -Raw | ConvertFrom-Json
        $fixture.iis.poolState | Should -Be Stopped
        Test-TestRejection { Restore-ClcIisDeployment example $j.attemptId AcceptCandidate synthetic-incident }
        $global:ClcFailCopy=$false
        $empty=Restore-ClcIisDeployment example $j.attemptId RestoreEmpty synthetic-incident
        $empty.status | Should -Be RestoredEmpty; $empty.currentGeneration | Should -Be 0
        @(Get-ChildItem -LiteralPath $fixture.target.applicationRoot -File).Name | Should -Be @('web.config')
        [IO.File]::Exists((Join-Path $fixture.controlRoot 'current.json')) | Should -BeFalse
        $next=Invoke-ClcIisDeployment example $approval.record.approvalId
        $next.status | Should -Be Deployed
    }
}

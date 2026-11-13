BeforeAll {
    . "$PSScriptRoot/Support.ps1"; . "$PSScriptRoot/T2Support.ps1"; . "$PSScriptRoot/T3Support.ps1"
    function Copy-ClcTestTarget($Fixture) {
        $target=$Fixture.target | ConvertTo-Json | ConvertFrom-Json -AsHashtable
        $target.targetId='alternate'; Write-TestJson (Join-Path $Fixture.layout.targetCatalogRoot 'alternate.json') $target
    }
}
Describe 'Practical deployment failure and recovery boundaries' {
    BeforeEach {
        $fixture=New-T2Fixture; Set-T2FixtureInModule $fixture; Set-T3Mocks
        $approval=New-T3Approval $fixture -Nested
        $global:ClcOriginalCopy=& (Get-Module CLC.Deployment) { (Get-Command Copy-ClcPayloadFile).ScriptBlock }
    }
    AfterEach { Remove-TestWorkspace $fixture.workspace }
    It 'rejects a downloaded ZIP that differs from its protected expected SHA-256 before staging or IIS mutation' {
        $path=Join-Path $fixture.target.artifactInboxRoot ($approval.record.approvalId+'.zip')
        [IO.File]::AppendAllText($path,'wrong')
        Test-TestRejection { Invoke-ClcIisDeployment example $approval.record.approvalId }
        $global:ClcLifecycle.operations.Count | Should -Be 0
        @([IO.Directory]::EnumerateFileSystemEntries($fixture.controlRoot)).Count | Should -Be 0
    }
    It 'rejects an incorrect IIS target before changing application files' {
        $fixture.iis.applications[0].physicalPath=$fixture.target.dataProtectionRoot
        Test-TestRejection { Invoke-ClcIisDeployment example $approval.record.approvalId } 'Clc.HostPreflightFailed*'
        $global:ClcLifecycle.operations.Count | Should -Be 0
    }
    It 'preserves an unexpected live file instead of treating it as a cleanup candidate' {
        $null=Invoke-ClcIisDeployment example $approval.record.approvalId
        $foreign=Join-Path $fixture.target.applicationRoot 'unknown.txt'; [IO.File]::WriteAllText($foreign,'preserve')
        $global:ClcLifecycle.operations.Clear()
        Test-TestRejection { Invoke-ClcIisDeployment example $approval.record.approvalId } 'Clc.ContentDrift*'
        [IO.File]::ReadAllText($foreign) | Should -BeExactly preserve
        $global:ClcLifecycle.operations.Count | Should -Be 0
    }
    It 'restores the prior running pool after a backup failure before replacement' {
        $null=Invoke-ClcIisDeployment example $approval.record.approvalId
        $newer=New-T3Approval $fixture probe-approval-002 2L
        Mock -ModuleName CLC.Deployment New-ClcVerifiedBackup { throw 'Synthetic storage failure' }
        Test-TestRejection { Invoke-ClcIisDeployment example $newer.record.approvalId }
        $fixture.iis.poolState | Should -BeExactly Started
        (Get-TestTreeHashes $fixture.target.applicationRoot) | Should -BeExactly (Get-TestTreeHashes $approval.publish)
        (Get-Content -LiteralPath (Join-Path $fixture.controlRoot 'journal.json') -Raw | ConvertFrom-Json).outcome | Should -BeExactly FailedPreserved
    }
    It 'retains a complete backup after a partial upgrade and explicitly restores it without the inbox ZIP' {
        $null=Invoke-ClcIisDeployment example $approval.record.approvalId
        $newer=New-T3Approval $fixture probe-approval-002 2L
        $global:ClcFailReplacement=$true
        Mock -ModuleName CLC.Deployment Copy-ClcPayloadFile {
            if ($global:ClcFailReplacement -and $Destination.StartsWith($global:ClcTestFixture.target.applicationRoot) -and $Destination.EndsWith('Probe.dll')) {
                [IO.File]::WriteAllText($Destination,'partial candidate'); throw 'Synthetic storage failure'
            }
            & $global:ClcOriginalCopy $Source $Destination $Overwrite
        }
        Test-TestRejection { Invoke-ClcIisDeployment example $newer.record.approvalId }
        $j=Get-Content -LiteralPath (Join-Path $fixture.controlRoot 'journal.json') -Raw | ConvertFrom-Json
        $fixture.iis.poolState | Should -BeExactly Stopped; $j.backup.verified | Should -BeTrue
        $backup=Join-Path $fixture.controlRoot ('backups\'+$j.attemptId+'\application')
        (Get-TestTreeHashes $backup) | Should -BeExactly (Get-TestTreeHashes $approval.publish)
        Test-TestRejection { Restore-ClcIisDeployment example $j.attemptId AcceptCandidate incident }
        $global:ClcFailReplacement=$false
        Get-ChildItem -LiteralPath $fixture.target.artifactInboxRoot -File | Remove-Item -Force
        $restored=Restore-ClcIisDeployment example $j.attemptId RestorePrevious incident
        $restored.status | Should -BeExactly RestoredPrevious
        (Get-TestTreeHashes $fixture.target.applicationRoot) | Should -BeExactly (Get-TestTreeHashes $approval.publish)
        (Get-TestTreeHashes $backup) | Should -BeExactly (Get-TestTreeHashes $approval.publish)
    }
    It 'preserves external configuration and Data Protection bytes through upgrade and explicit recovery' {
        $key=Join-Path $fixture.target.dataProtectionRoot 'persistent.xml'; [IO.File]::WriteAllText($key,'persistent synthetic key')
        $config=(Get-FileHash -LiteralPath $fixture.target.operationalConfigPath).Hash; $keyHash=(Get-FileHash -LiteralPath $key).Hash
        $null=Invoke-ClcIisDeployment example $approval.record.approvalId
        $newer=New-T3Approval $fixture probe-approval-002 2L
        $upgrade=Invoke-ClcIisDeployment example $newer.record.approvalId
        $null=Restore-ClcIisDeployment example $upgrade.attemptId RestorePrevious incident
        (Get-FileHash -LiteralPath $fixture.target.operationalConfigPath).Hash | Should -BeExactly $config
        (Get-FileHash -LiteralPath $key).Hash | Should -BeExactly $keyHash
    }
    It 'blocks both a retry and an alternate target selector after an unresolved attempt' {
        $global:ClcLifecycle.ready=$false
        Mock -ModuleName CLC.Deployment Get-ClcReadinessElapsed { return 120 }
        Test-TestRejection { Invoke-ClcIisDeployment example $approval.record.approvalId } 'Clc.ReadinessFailed*'
        $alias=Copy-ClcTestTarget $fixture
        $before=Get-T2TreeHashes $fixture
        Test-TestRejection { Invoke-ClcIisDeployment alternate anything } 'Clc.RecoveryRequired*'
        (Get-T2TreeHashes $fixture) | Should -BeExactly $before
    }
    It 'serializes the actual pool through one exclusive OS lock' {
        $context=Invoke-T2Private Open-ClcTrustedContext; $lock=$null
        try {
            $lock=Invoke-T2Private Enter-ClcDeploymentLock @($context,'example')
            Test-TestRejection { Invoke-T2Private Enter-ClcDeploymentLock @($context,'example') } 'Clc.ConcurrentDeployment*'
        } finally { Invoke-T2Private Exit-ClcDeploymentLock @($lock); Invoke-T2Private Close-ClcTrustedContext @($context) }
    }
    It 'rejects an unknown native launch before any recovery effects' {
        $global:ClcLifecycle.ready=$false
        Mock -ModuleName CLC.Deployment Get-ClcReadinessElapsed { return 120 }
        Test-TestRejection { Invoke-ClcIisDeployment example $approval.record.approvalId }
        $path=Join-Path $fixture.controlRoot 'journal.json'; $j=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
        $j.nativeCall=@{callId=[guid]::NewGuid().ToString('D');operation='Start';launchState='Intent';processId=$null;creationUtc=$null;exitCode=$null}
        Write-TestJson $path $j; $global:ClcLifecycle.operations.Clear()
        Test-TestRejection { Restore-ClcIisDeployment example $j.attemptId AcceptCandidate incident } 'Clc.HelperQuiescenceUnknown*'
        $global:ClcLifecycle.operations.Count | Should -Be 0
    }
    It 'rejects changed configuration bytes under the same revision before shutdown' {
        $null=Invoke-ClcIisDeployment example $approval.record.approvalId
        [IO.File]::WriteAllText($fixture.target.operationalConfigPath,'changed without a new revision')
        $global:ClcLifecycle.operations.Clear()
        Test-TestRejection { Invoke-ClcIisDeployment example $approval.record.approvalId } 'Clc.ConfigurationRevisionDrift*'
        @($global:ClcLifecycle.operations) | Should -Not -Contain Stop
        $fixture.iis.poolState | Should -BeExactly Started
    }
    It 'reports failed terminal persistence and requires explicit recovery of its published candidate' {
        $global:ClcOriginalComplete=& (Get-Module CLC.Deployment) { (Get-Command Complete-ClcAttempt).ScriptBlock }
        $global:ClcFailComplete=$true
        Mock -ModuleName CLC.Deployment Complete-ClcAttempt {
            if ($Outcome -ceq 'Deployed' -and $global:ClcFailComplete) { throw 'Synthetic terminal write failure' }
            & $global:ClcOriginalComplete $Session $Outcome $Pool
        }
        Test-TestRejection { Invoke-ClcIisDeployment example $approval.record.approvalId }
        $j=Get-Content -LiteralPath (Join-Path $fixture.controlRoot 'journal.json') -Raw | ConvertFrom-Json
        $j.phase | Should -BeExactly RecoveryRequired; $fixture.iis.poolState | Should -BeExactly Stopped
        Test-Path -LiteralPath (Join-Path $fixture.controlRoot 'current.json') | Should -BeTrue
        Test-TestRejection { Invoke-ClcIisDeployment example $approval.record.approvalId } 'Clc.RecoveryRequired*'
        $global:ClcFailComplete=$false
        (Restore-ClcIisDeployment example $j.attemptId AcceptCandidate incident).status | Should -BeExactly AcceptedCandidate
    }
}

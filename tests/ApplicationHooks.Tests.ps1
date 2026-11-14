BeforeAll {
    . "$PSScriptRoot/Support.ps1"; . "$PSScriptRoot/T2Support.ps1"; . "$PSScriptRoot/T3Support.ps1"; . "$PSScriptRoot/HookSupport.ps1"
}
Describe 'Version-two routine deployment and explicitly authorized lifecycle hooks' {
    BeforeEach { $fixture=New-T2Fixture; Set-T2FixtureInModule $fixture; Set-HookMocks; $policy=New-HookPolicy $fixture }
    AfterEach { Remove-TestWorkspace $fixture.workspace }
    It 'deploys SSRS and Polaris no-hook v2 packages with a complete stop/start cycle on exact repeats' {
        $approval=New-HookApproval $fixture
        $first=Invoke-ClcIisDeployment example $approval.record.approvalId
        $global:ClcLifecycle.operations.Clear()
        $again=Invoke-ClcIisDeployment example $approval.record.approvalId
        $again.status | Should -BeExactly Deployed; $again.currentGeneration | Should -Be ($first.currentGeneration+1)
        @($global:ClcLifecycle.operations | Where-Object {$_ -cin @('Stop','Start')}) | Should -Be @('Stop','Start')
        $global:ClcHooks.calls.Count | Should -Be 0
    }
    It 'executes only four declared hooks in lifecycle order with exact stopped observations after Stop' {
        $baseline=New-HookApproval $fixture
        $null=Invoke-ClcIisDeployment example $baseline.record.approvalId
        $global:ClcLifecycle.operations.Clear()
        $approval=New-HookApproval $fixture hooks-002 2 -Stages Preflight,BeforeStop,AfterStop,AfterStart
        $result=Invoke-ClcIisDeployment example $approval.record.approvalId
        $result.status | Should -BeExactly Deployed
        @($global:ClcLifecycle.operations | Where-Object {$_ -notlike 'Validate'}) | Should -Be @('Hook:Preflight','Hook:BeforeStop','Stop','Hook:AfterStop','Start','Ready','Hook:AfterStart')
        $j=Get-HookJournal $fixture; $j.schemaVersion | Should -Be 3
        $j.hooks.executions.Count | Should -Be 4; @($j.hooks.executions | Where-Object status -CNE Succeeded).Count | Should -Be 0
        $j.hooks.externalStateMayHaveChanged | Should -BeTrue
        [IO.Directory]::Exists((Join-Path $fixture.target.applicationRoot 'hooks')) | Should -BeFalse
    }
    It 'reruns Favorite Authors BeforeStop on identical web files and reports the still-running state' {
        $approval=New-HookApproval $fixture -Stages BeforeStop
        $null=Invoke-ClcIisDeployment example $approval.record.approvalId
        $global:ClcHooks.calls.Clear(); $global:ClcLifecycle.operations.Clear()
        $null=Invoke-ClcIisDeployment example $approval.record.approvalId
        @($global:ClcHooks.calls) | Should -Be @('BeforeStop')
        $global:ClcHooks.observations[-1].poolState | Should -BeExactly Started
        @($global:ClcLifecycle.operations | Where-Object {$_ -cin @('Hook:BeforeStop','Stop','Start')}) | Should -Be @('Hook:BeforeStop','Stop','Start')
    }
    It 'retains uncertainty after BeforeStop failure without an unnecessary IIS operation or automatic retry' {
        $baseline=New-HookApproval $fixture; $null=Invoke-ClcIisDeployment example $baseline.record.approvalId
        $approval=New-HookApproval $fixture hooks-002 2 -Stages BeforeStop
        $global:ClcHooks.mode='Failure'; $global:ClcLifecycle.operations.Clear()
        Test-TestRejection { Invoke-ClcIisDeployment example $approval.record.approvalId } 'Clc.HookFailed*'
        @($global:ClcLifecycle.operations | Where-Object {$_ -cin @('Stop','Start')}).Count | Should -Be 0
        $fixture.iis.poolState | Should -BeExactly Started
        $j=Get-HookJournal $fixture; $j.phase | Should -BeExactly RecoveryRequired; $j.backup.verified | Should -BeTrue
        $j.hooks.externalStateMayHaveChanged | Should -BeTrue
        $j.hooks.executions[0].status | Should -BeExactly Failed
        $j.hooks.executions[0].result.diagnosticId | Should -BeExactly synthetic-hook
        $calls=$global:ClcHooks.calls.Count
        Test-TestRejection { Invoke-ClcIisDeployment example $baseline.record.approvalId } 'Clc.RecoveryRequired*'
        $global:ClcHooks.calls.Count | Should -Be $calls
    }
    It 'retains ASAP AfterStop uncertainty after <Mode> and proves bounded helper exit before stopping' -ForEach @(@{Mode='Malformed'},@{Mode='Crash'},@{Mode='Timeout'}) {
        $approval=New-HookApproval $fixture -Stages AfterStop
        $policy.record.timeoutSeconds=1L; Write-TestJson $policy.path $policy.record
        $global:ClcHooks.mode=$Mode
        Test-TestRejection { Invoke-ClcIisDeployment example $approval.record.approvalId } $(if ($Mode -ceq 'Malformed') {'Clc.HookResultInvalid*'} else {'Clc.HookFailed*'})
        $fixture.iis.poolState | Should -BeExactly Stopped; $fixture.iis.workers.Count | Should -Be 0
        $j=Get-HookJournal $fixture; $j.phase | Should -BeExactly RecoveryRequired; $j.hooks.executions[0].status | Should -BeExactly Intent
        $j.nativeCall.launchState | Should -BeExactly Exited
        Test-TestRejection { Invoke-ClcIisDeployment example $approval.record.approvalId } 'Clc.RecoveryRequired*'
    }
    It 'retains a safe failure diagnostic from valid hook JSON even when the helper exits nonzero' {
        $approval=New-HookApproval $fixture -Stages AfterStop
        $global:ClcHooks.mode='FailureExit'
        Test-TestRejection { Invoke-ClcIisDeployment example $approval.record.approvalId } 'Clc.HookFailed*'
        $j=Get-HookJournal $fixture; $j.phase | Should -BeExactly RecoveryRequired
        $j.hooks.executions[0].status | Should -BeExactly Failed
        $j.hooks.executions[0].result.diagnosticId | Should -BeExactly synthetic-hook
        $fixture.iis.poolState | Should -BeExactly Stopped
    }
    It 'retains the previous backup after persistent work and a later readiness failure, requiring independent recovery authority' {
        $baseline=New-HookApproval $fixture; $null=Invoke-ClcIisDeployment example $baseline.record.approvalId
        $approval=New-HookApproval $fixture hooks-002 2 -Stages AfterStop
        $global:ClcLifecycle.ready=$false; Mock -ModuleName CLC.Deployment Get-ClcReadinessElapsed { if ($global:ClcLifecycle.ready) { return 0 } else { return 120 } }
        Test-TestRejection { Invoke-ClcIisDeployment example $approval.record.approvalId } 'Clc.ReadinessFailed*'
        $j=Get-HookJournal $fixture; $backup=Join-Path $fixture.controlRoot ('backups\'+$j.attemptId+'\application')
        (Get-TestTreeHashes $backup) | Should -BeExactly (Get-TestTreeHashes $baseline.publish)
        $before=Get-TestTreeHashes $backup; $calls=$global:ClcHooks.calls.Count
        Test-TestRejection { Restore-ClcIisDeployment -TargetId example -AttemptId $j.attemptId -Mode RestorePrevious -Reason incident } 'Clc.PersistentStateApprovalRequired*'
        $authority=New-HookRecoveryApproval $fixture $baseline
        $authority.record.enabled=$false; Write-TestJson $authority.path $authority.record
        Test-TestRejection { Restore-ClcIisDeployment -TargetId example -AttemptId $j.attemptId -Mode RestorePrevious -Reason incident -PersistentStateApprovalId $authority.record.approvalId } 'Clc.PersistentStateApprovalRequired*'
        $authority.record.enabled=$true; $authority.record.journalSha256='0'*64; Write-TestJson $authority.path $authority.record
        Test-TestRejection { Restore-ClcIisDeployment -TargetId example -AttemptId $j.attemptId -Mode RestorePrevious -Reason incident -PersistentStateApprovalId $authority.record.approvalId } 'Clc.PersistentStateApprovalRequired*'
        $authority.record.journalSha256=(Get-FileHash -LiteralPath (Join-Path $fixture.controlRoot 'journal.json') -Algorithm SHA256).Hash.ToLowerInvariant()
        Write-TestJson $authority.path $authority.record
        $global:ClcLifecycle.ready=$true
        $restored=Restore-ClcIisDeployment -TargetId example -AttemptId $j.attemptId -Mode RestorePrevious -Reason incident -PersistentStateApprovalId $authority.record.approvalId
        $restored.status | Should -BeExactly RestoredPrevious; $global:ClcHooks.calls.Count | Should -Be $calls
        (Get-TestTreeHashes $backup) | Should -BeExactly $before
    }
    It 'runs a separately declared plan without mutation hooks, IIS changes, or current generation publication' {
        $baseline=New-HookApproval $fixture; $initial=Invoke-ClcIisDeployment example $baseline.record.approvalId
        $approval=New-HookApproval $fixture hooks-002 2 -Stages BeforeStop,AfterStop -Plan
        $before=[IO.File]::ReadAllBytes((Join-Path $fixture.controlRoot 'current.json'))
        $global:ClcLifecycle.operations.Clear()
        $result=Invoke-ClcIisDeployment example $approval.record.approvalId -Operation ValidateOnly
        $result.status | Should -BeExactly Planned; $result.currentGeneration | Should -Be $initial.currentGeneration
        @($global:ClcHooks.calls) | Should -Be @('Plan')
        @($global:ClcLifecycle.operations | Where-Object {$_ -cin @('Stop','Start','Ready')}).Count | Should -Be 0
        [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $fixture.controlRoot 'current.json'))) | Should -BeExactly ([Convert]::ToBase64String($before))
        (Get-HookJournal $fixture).outcome | Should -BeExactly Planned
        $context=Invoke-T2Private Open-ClcTrustedContext; $lock=$null
        try {
            $lock=Invoke-T2Private Enter-ClcDeploymentLock @($context,'example')
            (Invoke-T2Private Get-ClcReconciliationDecision @($lock)).classification | Should -BeExactly Clean
        } finally { Invoke-T2Private Exit-ClcDeploymentLock @($lock); Invoke-T2Private Close-ClcTrustedContext @($context) }
    }
    It 'keeps case-insensitive ValidateOnly input out of the mutating lifecycle' {
        $approval=New-HookApproval $fixture -Stages BeforeStop,AfterStop -Plan
        $result=Invoke-ClcIisDeployment example $approval.record.approvalId -Operation vAlIdAtEoNlY
        $result.status | Should -BeExactly Planned
        @($global:ClcHooks.calls) | Should -Be @('Plan')
        @($global:ClcLifecycle.operations | Where-Object {$_ -cin @('Stop','Start','Ready')}).Count | Should -Be 0
        (Get-HookJournal $fixture).hooks.operation | Should -BeExactly ValidateOnly
    }
    It 'blocks ordinary deployment after a planning script fails, despite its read-only contract label' {
        $approval=New-HookApproval $fixture -Plan
        $global:ClcHooks.mode='Crash'
        Test-TestRejection { Invoke-ClcIisDeployment example $approval.record.approvalId -Operation ValidateOnly } 'Clc.HookFailed*'
        $j=Get-HookJournal $fixture; $j.phase | Should -BeExactly RecoveryRequired; $j.hooks.externalStateMayHaveChanged | Should -BeTrue
        @($global:ClcLifecycle.operations | Where-Object {$_ -cin @('Stop','Start')}).Count | Should -Be 0
        Test-TestRejection { Invoke-ClcIisDeployment example $approval.record.approvalId } 'Clc.RecoveryRequired*'
    }
    It 'retains reported plan mutation and refuses to label it a successful read-only plan' {
        $approval=New-HookApproval $fixture -Plan
        $global:ClcHooks.mode='ExternalMutation'
        Test-TestRejection { Invoke-ClcIisDeployment example $approval.record.approvalId -Operation ValidateOnly } 'Clc.PlanningMutationReported*'
        $j=Get-HookJournal $fixture; $j.phase | Should -BeExactly RecoveryRequired
        $j.hooks.executions[0].status | Should -BeExactly Failed
        $j.hooks.executions[0].result.externalStateMayHaveChanged | Should -BeTrue
        @($global:ClcLifecycle.operations | Where-Object {$_ -cin @('Stop','Start')}).Count | Should -Be 0
    }
    It 'rejects unauthorized hook scope before hook or IIS execution <Scope>' -ForEach @(@{Scope='stage'},@{Scope='channel'},@{Scope='source'},@{Scope='disabled'},@{Scope='interpreter'}) {
        $approval=New-HookApproval $fixture -Stages AfterStop
        switch ($Scope) {
            stage {$policy.record.stages=@('BeforeStop')}
            channel {$policy.record.channels=@('Production')}
            source {$policy.record.sourceClasses=@('UnmergedDevTag')}
            disabled {$policy.record.enabled=$false}
            interpreter {$policy.record.pwshSha256='0'*64}
        }
        Write-TestJson $policy.path $policy.record
        Test-TestRejection { Invoke-ClcIisDeployment example $approval.record.approvalId } 'Clc.HookAuthorizationRejected*'
        $global:ClcHooks.calls.Count | Should -Be 0; @($global:ClcLifecycle.operations | Where-Object {$_ -cin @('Stop','Start')}).Count | Should -Be 0
    }
    It 'executes an approved harmless packaged PowerShell hook through the actual bounded native boundary' {
        $policy=New-HookPolicy $fixture -Native
        $approval=New-HookApproval $fixture -Stages AfterStop
        $global:ClcHooks.native=$true
        (Invoke-ClcIisDeployment example $approval.record.approvalId).status | Should -BeExactly Deployed
        (Get-HookJournal $fixture).hooks.executions[0].result.diagnosticId | Should -BeExactly synthetic-ok
    }
}

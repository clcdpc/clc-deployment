BeforeAll {
    . "$PSScriptRoot/Support.ps1"
    function Get-HookContractFixture([string] $Kind) {
        $authority=@{authoritySid='S-1-5-32-544';reference='example-independent-review';approvedUtc='2026-01-01T00:00:00Z'}
        switch ($Kind) {
            hook-policy { return @{contractFamily='clc-file-iis-v1';schemaVersion=1;recordKind=$Kind;targetId='example';applicationId='probe';
                environmentName='arbitrary-dev-label';enabled=$true;channels=@('DEV');exactApprovalChannel='DEV';
                sourceClasses=@('ExactApproval','ReviewedPr');stages=@('BeforeStop','AfterStop');allowPlanning=$true;
                pwshPath='C:\Independent\PowerShell\pwsh.exe';pwshSha256=('0'*64);timeoutSeconds=30;authorization=$authority} }
            hook-result { return @{contractVersion=1;outcome='Success';stage='BeforeStop';externalStateMayHaveChanged=$false;diagnosticId='example.applied';requiresOperatorIntervention=$false} }
            persistent-state-approval { return @{contractFamily='clc-file-iis-v1';schemaVersion=1;recordKind=$Kind;approvalId='reconcile-001';enabled=$true;
                targetId='example';attemptId='11111111-1111-1111-1111-111111111111';journalSha256=('0'*64);mode='RestorePrevious';
                selectedManifestSha256=('1'*64);externalStateCompatible=$true;helpersQuiescentConfirmed=$true;authorization=$authority} }
            journal {
                $journal=Get-Content -LiteralPath (Join-Path $script:FixtureRoot 'journal.json') -Raw | ConvertFrom-Json -AsHashtable -DateKind String
                $journal.schemaVersion=3; $journal.hooks=@{policySha256=('0'*64);operation='Deploy';externalStateMayHaveChanged=$true;
                    executions=@(@{stage='BeforeStop';entryPoint='hooks/before.ps1';status='Intent';result=$null})}
                $journal.intent.operation='Hook'; $journal.nativeCall.operation='Hook'
                $journal.recovery.persistentStateApproval=@{approvalId='reconcile-001';sha256=('1'*64)}
                return $journal
            }
        }
    }
    function Assert-HookContractAccepted($Value,[string] $Kind) {
        $json=$Value | ConvertTo-Json -Depth 32 -Compress
        $null=Invoke-TestRecord ([Text.Encoding]::UTF8.GetBytes($json)) $Kind
        Test-Json -Json $json -SchemaFile (Join-Path $script:RepositoryRoot ('schemas/'+$Kind+'.schema.json')) -ErrorAction Stop | Should -BeTrue
    }
    function Assert-HookContractRejected($Value,[string] $Kind) {
        $json=$Value | ConvertTo-Json -Depth 32 -Compress
        Test-TestRejection { Invoke-TestRecord ([Text.Encoding]::UTF8.GetBytes($json)) $Kind }
        Test-Json -Json $json -SchemaFile (Join-Path $script:RepositoryRoot ('schemas/'+$Kind+'.schema.json')) -ErrorAction SilentlyContinue | Should -BeFalse
    }
}
Describe 'Strict hook authority, results and journal contracts' {
    It 'accepts the standalone schema and strict parser for <Kind>' -ForEach @(@{Kind='hook-policy'},@{Kind='hook-result'},@{Kind='persistent-state-approval'},@{Kind='journal'}) {
        Assert-HookContractAccepted (Get-HookContractFixture $Kind) $Kind
    }
    It 'requires every exact root field and rejects extra fields in <Kind>' -ForEach @(@{Kind='hook-policy'},@{Kind='hook-result'},@{Kind='persistent-state-approval'}) {
        $value=Get-HookContractFixture $Kind
        foreach ($key in @($value.Keys)) {
            $copy=$value | ConvertTo-Json -Depth 16 | ConvertFrom-Json -AsHashtable -DateKind String
            $copy.Remove($key); Assert-HookContractRejected $copy $Kind
        }
        $value.untrustedExtra=$true; Assert-HookContractRejected $value $Kind
    }
    It 'keeps arbitrary environment labels separate from an explicit permitted exact-approval channel' {
        $policy=Get-HookContractFixture hook-policy
        $policy.exactApprovalChannel='Production'
        Assert-HookContractRejected $policy hook-policy
        $policy.channels=@('Production'); Assert-HookContractAccepted $policy hook-policy
        $policy.Remove('exactApprovalChannel'); Assert-HookContractRejected $policy hook-policy
    }
    It 'rejects malformed policy process pins, scope and bounds <Mode>' -ForEach @(
        @{Mode='timeout'},@{Mode='executable'},@{Mode='hash'},@{Mode='stage'},@{Mode='source'},@{Mode='duplicate-channel'},@{Mode='boolean'}
    ) {
        $policy=Get-HookContractFixture hook-policy
        switch ($Mode) {
            timeout {$policy.timeoutSeconds=301}
            executable {$policy.pwshPath='C:\Independent\PowerShell\arbitrary.exe'}
            hash {$policy.pwshSha256='self-declared'}
            stage {$policy.stages=@('AfterDatabase')}
            source {$policy.sourceClasses=@('AnyPr')}
            duplicate-channel {$policy.channels=@('DEV','DEV')}
            boolean {$policy.enabled='true'}
        }
        Assert-HookContractRejected $policy hook-policy
    }
    It 'rejects unsafe diagnostic content and unsupported result versions <Mode>' -ForEach @(@{Mode='diagnostic'},@{Mode='version'},@{Mode='outcome'},@{Mode='coercion'}) {
        $result=Get-HookContractFixture hook-result
        switch ($Mode) {
            diagnostic {$result.diagnosticId='raw database exception with secrets'}
            version {$result.contractVersion=2}
            outcome {$result.outcome='AlmostSucceeded'}
            coercion {$result.externalStateMayHaveChanged='false'}
        }
        Assert-HookContractRejected $result hook-result
    }
    It 'preserves exact schema-two journals and refuses newly introduced state in them <Mode>' -ForEach @(@{Mode='hooks'},@{Mode='intent'},@{Mode='native'},@{Mode='planned'},@{Mode='recovery'}) {
        $journal=Get-Content -LiteralPath (Join-Path $script:FixtureRoot 'journal.json') -Raw | ConvertFrom-Json -AsHashtable -DateKind String
        Assert-HookContractAccepted $journal journal
        switch ($Mode) {
            hooks {$journal.hooks=$null}
            intent {$journal.intent.operation='Hook'}
            native {$journal.nativeCall.operation='Hook'}
            planned {$journal.phase='Completed';$journal.outcome='Planned'}
            recovery {$journal.recovery.persistentStateApproval=$null}
        }
        Assert-HookContractRejected $journal journal
    }
    It 'requires the schema-three hooks field and permits null for a no-hook deployment' {
        $journal=Get-HookContractFixture journal; $journal.hooks=$null
        Assert-HookContractAccepted $journal journal
        $journal.Remove('hooks'); Assert-HookContractRejected $journal journal
    }
    It 'rejects inconsistent hook journal evidence <Mode>' -ForEach @(
        @{Mode='cleared-uncertainty'},@{Mode='duplicate-stage'},@{Mode='undeclared-stage'},@{Mode='unsafe-path'},
        @{Mode='non-script'},@{Mode='result-at-intent'},@{Mode='failed-succeeded-result'},@{Mode='wrong-result-stage'},
        @{Mode='requires-intervention'},@{Mode='plan-in-deployment'},@{Mode='lifecycle-in-plan'},@{Mode='missing-recovery-evidence'},
        @{Mode='failed-without-result'},@{Mode='successful-plan-reports-mutation'}
    ) {
        $journal=Get-HookContractFixture journal
        switch ($Mode) {
            cleared-uncertainty {$journal.hooks.externalStateMayHaveChanged=$false}
            duplicate-stage {$journal.hooks.executions+=@{stage='BeforeStop';entryPoint='hooks/before.ps1';status='Intent';result=$null}}
            undeclared-stage {$journal.hooks.executions[0].stage='ApplyDatabase'}
            unsafe-path {$journal.hooks.executions[0].entryPoint='hooks/../outside.ps1'}
            non-script {$journal.hooks.executions[0].entryPoint='hooks/data.sql'}
            result-at-intent {$journal.hooks.executions[0].result=Get-HookContractFixture hook-result}
            failed-succeeded-result {
                $journal.hooks.executions[0].status='Succeeded';$journal.hooks.executions[0].result=Get-HookContractFixture hook-result
                $journal.hooks.executions[0].result.outcome='Failure'
            }
            wrong-result-stage {
                $journal.hooks.executions[0].status='Succeeded';$journal.hooks.executions[0].result=Get-HookContractFixture hook-result
                $journal.hooks.executions[0].result.stage='AfterStop'
            }
            requires-intervention {
                $journal.hooks.executions[0].status='Succeeded';$journal.hooks.executions[0].result=Get-HookContractFixture hook-result
                $journal.hooks.executions[0].result.requiresOperatorIntervention=$true
            }
            plan-in-deployment {$journal.hooks.executions[0].stage='Plan'}
            lifecycle-in-plan {$journal.hooks.operation='ValidateOnly'}
            missing-recovery-evidence {$journal.recovery.Remove('persistentStateApproval')}
            failed-without-result {$journal.hooks.executions[0].status='Failed'}
            successful-plan-reports-mutation {
                $journal.hooks.operation='ValidateOnly';$journal.hooks.executions[0].stage='Plan';$journal.hooks.executions[0].status='Succeeded'
                $journal.hooks.executions[0].result=Get-HookContractFixture hook-result
                $journal.hooks.executions[0].result.stage='Plan';$journal.hooks.executions[0].result.externalStateMayHaveChanged=$true
            }
        }
        Assert-HookContractRejected $journal journal
    }
    It 'records a successful plan separately while retaining conservative external-state evidence' {
        $journal=Get-HookContractFixture journal
        $journal.hooks.operation='ValidateOnly';$journal.hooks.executions[0].stage='Plan';$journal.hooks.executions[0].status='Succeeded'
        $journal.hooks.executions[0].result=Get-HookContractFixture hook-result;$journal.hooks.executions[0].result.stage='Plan'
        $journal.phase='Completed';$journal.outcome='Planned';$journal.liveMutationIntent=$false
        Assert-HookContractAccepted $journal journal
        $journal.liveMutationIntent=$true; Assert-HookContractRejected $journal journal
    }
    It 'refuses FailedPreserved after any recorded hook execution' {
        $journal=Get-HookContractFixture journal; $journal.phase='Completed';$journal.outcome='FailedPreserved'
        Assert-HookContractRejected $journal journal
    }
    It 'retains a valid safe failure result, including a plan that reports external mutation' {
        $journal=Get-HookContractFixture journal
        $journal.hooks.operation='ValidateOnly';$journal.hooks.executions[0].stage='Plan';$journal.hooks.executions[0].status='Failed'
        $journal.hooks.executions[0].result=Get-HookContractFixture hook-result
        $journal.hooks.executions[0].result.stage='Plan';$journal.hooks.executions[0].result.externalStateMayHaveChanged=$true
        Assert-HookContractAccepted $journal journal
        $journal.hooks.executions[0].result.outcome='Failure';$journal.hooks.executions[0].result.requiresOperatorIntervention=$true
        Assert-HookContractAccepted $journal journal
    }
}

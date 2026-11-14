function Get-ClcUtcTimestamp { return [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ',[Globalization.CultureInfo]::InvariantCulture) }
function Copy-ClcRecord {
    param($Record)
    return ($Record | ConvertTo-Json -Depth 24 -Compress | ConvertFrom-Json -AsHashtable -DateKind String)
}
function Test-ClcHelpersExited {
    param($Journal)
    $native=$Journal.nativeCall
    if ($null -eq $native -or $native.launchState -ceq 'Exited') { return $true }
    if ($native.launchState -ceq 'Intent') { return $false }
    return (Get-ClcNativeProcessObservation $native.processId $native.creationUtc) -ceq 'Exited'
}
function Read-ClcLatestAttemptEvidence {
    param($Lock,$State)
    $j=$State.journal.record
    $name=if ($null -eq $j.recovery) {'deployment.json'} else {'recovery-'+$j.recovery.sequence+'.json'}
    $file=Read-ClcStatePath $Lock (Join-Path $Lock.identity.controlRoot ('attempts\'+$j.attemptId+'\'+$name)) journal
    if ($file.sha256 -cne $State.journal.sha256) { Stop-ClcError Clc.RecoveryRequired }
    return $file
}
function Get-ClcReconciliationDecision {
    param($Lock)
    $state=Read-ClcDeploymentState $Lock; $Lock.state=$state
    if ($null -eq $state.journal) {
        if ($null -ne $state.current) { return @{classification='RecoveryRequired'} }
        foreach ($name in @('attempts','backups','staging','releases')) {
            $path=Join-Path $Lock.identity.controlRoot $name
            if ([IO.Directory]::Exists($path) -and @([IO.Directory]::EnumerateFileSystemEntries($path)).Count) { return @{classification='RecoveryRequired'} }
        }
        return @{classification='Clean'}
    }
    $j=$state.journal.record
    if ($j.phase -cne 'Completed' -or -not (Test-ClcHelpersExited $j)) { return @{classification='RecoveryRequired'} }
    $null=Read-ClcLatestAttemptEvidence $Lock $state
    if ($j.outcome -ceq 'RestoredEmpty') { return @{classification='EmptyRecoveryNeedsVerification'} }
    if ($j.outcome -cin @('FailedPreserved','Planned')) {
        $matches=if ($null -eq $j.previous) {$null -eq $state.current} else {
            $null -ne $state.current -and $state.current.record.generation -eq $j.previous.generation -and
            (Test-ClcValueEqual $state.current.record.release $j.previous.release)
        }
        if ($matches) { return @{classification='Clean'} }
    } elseif ($null -ne $state.current) {
        $c=$state.current.record
        if ($j.outcome -ceq 'NoOp') {
            if ($null -ne $j.previous -and $c.generation -eq $j.previous.generation -and (Test-ClcValueEqual $c.release $j.candidate)) { return @{classification='Clean'} }
        } elseif ($c.attemptId -ceq $j.attemptId -and $c.generation -eq $j.publishedGeneration -and
            (Test-ClcValueEqual $c.release $(if ($j.outcome -ceq 'RestoredPrevious') {$j.previous.release} else {$j.candidate}))) { return @{classification='Clean'} }
    }
    return @{classification='RecoveryRequired'}
}
function New-ClcPreparedJournal {
    param($Session,$Previous,$HostFacts)
    $lock=$Session.lock; $approval=$Session.release.approvalFile
    $now=Get-ClcUtcTimestamp
    $version=if ($Session.release.manifest.schemaVersion -eq 2) {3L} else {2L}
    $j=[ordered]@{contractFamily='clc-file-iis-v1';schemaVersion=$version;recordKind='journal';attemptId=$Session.attemptId;
        targetKey=$lock.identity.targetKey;targetSnapshot=$lock.identity.snapshot;executingToolkit=$lock.context.executingToolkit;
        policyGeneration=$lock.context.policyFile.record.generation;policySha256=$lock.context.policyFile.sha256;
        approvalSnapshot=@{approvalId=$approval.record.approvalId;sha256=$approval.sha256;lineageId=$approval.record.lineageId;releaseSequence=$approval.record.releaseSequence};
        candidate=(Get-ClcReleaseIdentity $Session.release);previous=$Previous;initialPoolState=$HostFacts.poolState;initialTargetEmpty=($null -eq $Previous);
        phase='Prepared';outcome=$null;liveMutationIntent=$false;intent=@{sequence=1L;operation='Stage';recordedUtc=$now};
        observation=$null;nativeCall=$null;configuration=$Session.configuration.record;backup=$null;recovery=$null;publishedGeneration=$null;
        createdUtc=$now;updatedUtc=$now;failure=$null}
    if ($version -eq 3) {
        $j.hooks=if ($Session.ContainsKey('hookPolicy')) {@{policySha256=$Session.hookPolicy.sha256;operation=$Session.operation;externalStateMayHaveChanged=$false;executions=@()}} else {$null}
    }
    $state=Read-ClcDeploymentState $lock
    return Write-ClcStateRecord $lock journal $j $(if ($null -ne $state.journal) {$state.journal.sha256})
}
function Write-ClcJournalIntent {
    param($Lock,[ValidateSet('Stage','Validate','Stop','Backup','Replace','Start','CheckReady','PublishCurrent','Complete','Hook')][string] $Operation)
    $file=Read-ClcStateFile $Lock journal; $j=$file.record
    if ($j.intent.sequence -eq [long]::MaxValue -or -not (Test-ClcHelpersExited $j)) { Stop-ClcError Clc.RecoveryRequired }
    $j.intent=@{sequence=($j.intent.sequence+1L);operation=$Operation;recordedUtc=(Get-ClcUtcTimestamp)}
    $j.updatedUtc=$j.intent.recordedUtc; $j.observation=$null; $j.outcome=$null
    if ($Operation -cin @('Stop','Replace','Start')) { $j.liveMutationIntent=$true }
    if ($j.liveMutationIntent -and $j.phase -cne 'RecoveryRequired') { $j.phase='Mutating' }
    return Write-ClcStateRecord $Lock journal $j $file.sha256
}
function Write-ClcNativeCallIntent {
    param($Lock,[ValidateSet('Validate','Stop','Start','Hook')][string] $Operation)
    $file=Write-ClcJournalIntent $Lock $Operation; $j=$file.record
    $j.nativeCall=@{callId=[guid]::NewGuid().ToString('D');operation=$Operation;launchState='Intent';processId=$null;creationUtc=$null;exitCode=$null}
    return Write-ClcStateRecord $Lock journal $j $file.sha256
}
function Write-ClcNativeCallStarted {
    param($Lock,[Diagnostics.Process] $Process)
    $identity=Get-ClcProcessIdentity $Process
    $file=Read-ClcStateFile $Lock journal; $j=$file.record
    $j.nativeCall.launchState='Started'; $j.nativeCall.processId=$identity.processId; $j.nativeCall.creationUtc=$identity.creationUtc
    return Write-ClcStateRecord $Lock journal $j $file.sha256
}
function Write-ClcNativeCallExited {
    param($Lock,[Diagnostics.Process] $Process,[int] $TimeoutMilliseconds=0,[int] $KillWaitMilliseconds=30000)
    $file=Read-ClcStateFile $Lock journal; $j=$file.record
    if ($j.nativeCall.launchState -cne 'Started') { Stop-ClcError Clc.HelperQuiescenceUnknown }
    $result=Wait-ClcTrackedProcess $Process $j.nativeCall.creationUtc $TimeoutMilliseconds $KillWaitMilliseconds
    $j.nativeCall.launchState='Exited'; $j.nativeCall.exitCode=[long]$result
    return Write-ClcStateRecord $Lock journal $j $file.sha256
}

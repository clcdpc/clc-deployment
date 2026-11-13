function Restore-ClcIisDeployment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9-]{0,63}$')][string] $TargetId,
        [Parameter(Mandatory)][guid] $AttemptId,
        [Parameter(Mandatory)][ValidateSet('RestorePrevious','AcceptCandidate','RestoreEmpty')][string] $Mode,
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9-]{0,127}$')][string] $Reason
    )
    $context=$null; $lock=$null; $session=@{}
    try {
        if ($AttemptId -eq [guid]::Empty) { Stop-ClcError Clc.InvalidContract }
        $context=Open-ClcTrustedContext
        $lock=Enter-ClcDeploymentLock $context $TargetId; $session.lock=$lock
        $outcome=Invoke-ClcRecoveryCore $session $AttemptId.ToString('D') $Mode $Reason
        $j=$outcome.state.journal.record; $releaseId=$null; $generation=0L
        if ($null -ne $outcome.state.current) { $releaseId=$outcome.state.current.record.release.releaseId; $generation=$outcome.state.current.record.generation }
        return [pscustomobject][ordered]@{status=$outcome.status;attemptId=$j.attemptId;recoverySequence=$j.recovery.sequence;releaseId=$releaseId;
            executingToolkit=[pscustomobject]$context.executingToolkit;currentGeneration=$generation;observedPoolState=$j.observation.observedPoolState;workerCount=$j.observation.workerCount}
    } catch {
        $original=$_
        if ($session.ContainsKey('recoveryEffectsStarted') -and $session.recoveryEffectsStarted) {
            try { Invoke-ClcAttemptFailure $session $(if ($original.FullyQualifiedErrorId -like 'Clc.*') {$original.FullyQualifiedErrorId.Split(',')[0]} else {'Clc.RecoveryRequired'}) } catch { }
        }
        $PSCmdlet.ThrowTerminatingError((New-ClcLifecycleError $original $lock))
    } finally { Exit-ClcDeploymentLock $lock; Close-ClcTrustedContext $context }
}

function Invoke-ClcIisDeployment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9-]{0,63}$')][string] $TargetId,
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9-]{0,63}$')][string] $ReleaseApprovalId,
        [switch] $AllowDowngrade,
        [ValidatePattern('^[a-z0-9][a-z0-9-]{0,127}$')][string] $Reason
    )
    $context=$null; $lock=$null; $session=@{}
    try {
        if (($AllowDowngrade -and -not $Reason) -or ($Reason -and -not $AllowDowngrade)) { Stop-ClcError Clc.DowngradeRejected }
        $context=Open-ClcTrustedContext
        $lock=Enter-ClcDeploymentLock $context $TargetId; $session.lock=$lock
        $outcome=Invoke-ClcDeploymentCore $session $ReleaseApprovalId ([bool]$AllowDowngrade) $Reason
        $current=$outcome.state.current.record; $j=$outcome.state.journal.record
        return [pscustomobject][ordered]@{status=$outcome.status;attemptId=$j.attemptId;targetId=$TargetId;releaseId=$current.release.releaseId;
            sourceCommit=$current.release.sourceCommit;executingToolkit=[pscustomobject]$context.executingToolkit;currentGeneration=$current.generation;
            observedPoolState=$j.observation.observedPoolState;workerCount=$j.observation.workerCount}
    } catch {
        $original=$_
        try { Invoke-ClcAttemptFailure $session $(if ($original.FullyQualifiedErrorId -like 'Clc.*') {$original.FullyQualifiedErrorId.Split(',')[0]} else {'Clc.RecoveryRequired'}) } catch { }
        $PSCmdlet.ThrowTerminatingError((New-ClcLifecycleError $original $lock))
    } finally { Exit-ClcDeploymentLock $lock; Close-ClcTrustedContext $context }
}

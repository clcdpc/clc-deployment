function Invoke-ClcIisDeployment {
    [CmdletBinding(DefaultParameterSetName='Exact')]
    param(
        [Parameter(Mandatory,Position=0)][ValidatePattern('^[a-z0-9][a-z0-9-]{0,63}$')][string] $TargetId,
        [Parameter(Mandatory,ParameterSetName='Exact',Position=1)][ValidatePattern('^[a-z0-9][a-z0-9-]{0,63}$')][string] $ReleaseApprovalId,
        [Parameter(Mandatory,ParameterSetName='Automated')][ValidatePattern('^[a-z0-9][a-z0-9-]{0,63}$')][string] $StandingAuthorizationId,
        [Parameter(Mandatory,ParameterSetName='Automated')][ValidateNotNullOrEmpty()][string] $ReleaseTag,
        [Parameter(Mandatory,ParameterSetName='Automated')][ValidateNotNullOrEmpty()][string] $ArchivePath,
        [Parameter(Mandatory,ParameterSetName='Automated')][ValidateNotNullOrEmpty()][string] $VerifiedReleasePath,
        [Parameter(ParameterSetName='Exact')][switch] $AllowDowngrade,
        [Parameter(ParameterSetName='Exact')][ValidatePattern('^[a-z0-9][a-z0-9-]{0,127}$')][string] $Reason
    )
    $context=$null; $lock=$null; $session=@{}
    try {
        if (($AllowDowngrade -and -not $Reason) -or ($Reason -and -not $AllowDowngrade)) { Stop-ClcError Clc.DowngradeRejected }
        $context=Open-ClcTrustedContext
        $lock=Enter-ClcDeploymentLock $context $TargetId; $session.lock=$lock
        $pending=Join-Path $context.layout.approvalCatalogRoot ('standing\'+$TargetId+'.pending')
        if ([IO.File]::Exists($pending) -or [IO.Directory]::Exists($pending)) { Stop-ClcError Clc.AdmissionIncomplete }
        if ($PSCmdlet.ParameterSetName -ceq 'Automated') {
            $admission=New-ClcAutomatedApproval $lock $StandingAuthorizationId $ReleaseTag $ArchivePath $VerifiedReleasePath
            $ReleaseApprovalId=$admission.approvalId; $session.admittedRelease=$admission.release
        }
        $outcome=Invoke-ClcDeploymentCore $session $ReleaseApprovalId ([bool]$AllowDowngrade) $Reason
        $current=$outcome.state.current.record; $j=$outcome.state.journal.record
        return [pscustomobject][ordered]@{status=$outcome.status;attemptId=$j.attemptId;targetId=$TargetId;releaseId=$current.release.releaseId;
            sourceCommit=$current.release.sourceCommit;executingToolkit=[pscustomobject]$context.executingToolkit;currentGeneration=$current.generation;
            observedPoolState=$j.observation.observedPoolState;workerCount=$j.observation.workerCount}
    } catch {
        $original=$_
        if ($PSCmdlet.ParameterSetName -ceq 'Automated' -and -not $session.ContainsKey('attemptId')) {
            $code=if ($original.FullyQualifiedErrorId -like 'Clc.*') {$original.FullyQualifiedErrorId.Split(',')[0]} else {'Clc.AdmissionIncomplete'}
            $message='Automated admission or preflight failed before a new lifecycle attempt. Preserve the inbox ZIP/verified identity and protected approval catalog. Inspect standing policy, provenance and exact approval; reconcile any pending admission through infrastructure maintenance before retry. Do not delete intent or edit deployment journals.'
            if ($null -ne $lock) { $message+=' Admission intent: '+(Join-Path $context.layout.approvalCatalogRoot ('standing\'+$TargetId+'.pending'))+'. Pool/worker state was not reobserved.' }
            $PSCmdlet.ThrowTerminatingError([Management.Automation.ErrorRecord]::new([IO.InvalidDataException]::new($message),$code,[Management.Automation.ErrorCategory]::InvalidOperation,$null))
        }
        try { Invoke-ClcAttemptFailure $session $(if ($original.FullyQualifiedErrorId -like 'Clc.*') {$original.FullyQualifiedErrorId.Split(',')[0]} else {'Clc.RecoveryRequired'}) } catch { }
        $PSCmdlet.ThrowTerminatingError((New-ClcLifecycleError $original $lock))
    } finally { Exit-ClcDeploymentLock $lock; Close-ClcTrustedContext $context }
}

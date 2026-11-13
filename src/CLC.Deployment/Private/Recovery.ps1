function Get-ClcEmptyBaselineEligibility {
    param($Lock,$Release)
    try {
        $state=Read-ClcDeploymentState $Lock; $j=$state.journal.record
        if ($null -ne $state.current -or $j.phase -cne 'Completed' -or $j.outcome -cne 'RestoredEmpty' -or -not $j.initialTargetEmpty -or
            -not (Test-ClcValueEqual $j.candidate (Get-ClcReleaseIdentity $Release))) { return @{eligible=$false} }
        $null=Read-ClcLatestAttemptEvidence $Lock $state
        $guard=@($Release.manifest.files | Where-Object path -CEQ 'application/web.config')
        $null=Get-ClcTreeInventory $Lock.targetFile.record.applicationRoot $guard
        Assert-ClcIisQuiescent $Lock
        return @{eligible=$true}
    } catch { return @{eligible=$false} }
}
function Invoke-ClcRecoveryCore {
    param($Session,[string] $AttemptId,[string] $Mode,[string] $Reason)
    $lock=$Session.lock; $state=Read-ClcDeploymentState $lock
    if ($null -eq $state.journal -or $state.journal.record.attemptId -cne $AttemptId) { Stop-ClcError Clc.RecoveryRequired }
    $j=$state.journal.record
    if (-not (Test-ClcHelpersExited $j)) { Stop-ClcError Clc.HelperQuiescenceUnknown }
    if ($j.phase -ceq 'Completed') {
        $null=Read-ClcLatestAttemptEvidence $lock $state
        if ($Mode -ceq 'RestoreEmpty' -or $j.outcome -cin @('FailedPreserved','RestoredEmpty')) { Stop-ClcError Clc.RecoveryRequired }
        if ($null -eq $state.current -or $state.current.record.attemptId -cne $j.attemptId -or
            $state.current.record.generation -ne $j.publishedGeneration) { Stop-ClcError Clc.RecoveryRequired }
    }
    if ($null -ne $state.current) {
        $c=$state.current.record
        $prior=$null -ne $j.previous -and $c.generation -eq $j.previous.generation -and (Test-ClcValueEqual $c.release $j.previous.release)
        $published=$null -ne $j.publishedGeneration -and $c.attemptId -ceq $j.attemptId -and $c.generation -eq $j.publishedGeneration
        if (-not $prior -and -not $published) { Stop-ClcError Clc.RecoveryRequired }
    } elseif ($null -ne $j.previous) { Stop-ClcError Clc.RecoveryRequired }
    $Session.release=Read-ClcApprovedManifest $lock $j.candidate.approvalId
    Assert-ClcReleaseBinding $Session.release $j.candidate $j.approvalSnapshot
    $Session.previousRelease=$null; $Session.baselineFiles=@(); $Session.replacementBegun=$false
    $Session.configuration=Open-ClcConfiguration $lock
    if ($Session.configuration.file.sha256 -cne $j.configuration.privateSha256 -or $j.configuration.revision -ceq 'pending-validation') { Stop-ClcError Clc.PreviousConfigurationIncompatible }
    $Session.configuration.record=$j.configuration
    $hostFacts=Get-ClcHostPreflight $lock.context $lock.targetFile $lock.identity $Session.release.manifest.runtime.framework
    $Session.hostDigest=$hostFacts.hostObservationSha256; $Session.iisConfigurationSha256=$hostFacts.iisConfigurationSha256
    $candidate=$Session.release; $selected=$candidate; $source=$lock.targetFile.record.applicationRoot
    $other=@()
    if ($null -ne $j.previous) {
        $Session.previousRelease=Read-ClcApprovedManifest $lock $j.previous.release.approvalId
        Assert-ClcReleaseBinding $Session.previousRelease $j.previous.release $j.previous.approvalSnapshot
        $other=@($Session.previousRelease.manifest.files)
    }
    switch ($Mode) {
        RestorePrevious {
            if ($null -eq $j.previous) { Stop-ClcError Clc.BackupInvalid }
            $source=Assert-ClcBackup $Session $j; $selected=$Session.previousRelease
        }
        AcceptCandidate { $null=Get-ClcTreeInventory $source $candidate.manifest.files }
        RestoreEmpty {
            if (-not $j.initialTargetEmpty -or $null -ne $j.previous) { Stop-ClcError Clc.RecoveryRequired }
            $null=Assert-ClcBackup $Session $j
            $source=Join-Path $lock.identity.controlRoot ('staging\'+$AttemptId+'\application')
            $null=Get-ClcTreeInventory $source $candidate.manifest.files
        }
    }
    $sequence=if ($null -eq $j.recovery) {1L} else {$j.recovery.sequence+1L}
    if ($sequence -le 0) { Stop-ClcError Clc.StatePersistenceFailed }
    New-ClcOwnedDirectory $lock (Join-Path $lock.identity.controlRoot ('attempts\'+$AttemptId))
    $before=Join-Path $lock.identity.controlRoot ('attempts\'+$AttemptId+'\before-recovery-'+$sequence+'.json')
    $null=Write-ClcStateBytes $lock $before $state.journal.bytes journal $null -CreateNew
    $j.phase='RecoveryRequired'; $j.outcome=$null; $j.nativeCall=$null; $j.updatedUtc=Get-ClcUtcTimestamp
    $j.recovery=@{sequence=$sequence;mode=$Mode;reason=$Reason;originalJournalSha256=$state.journal.sha256;
        executingToolkit=$lock.context.executingToolkit;policyGeneration=$lock.context.policyFile.record.generation;policySha256=$lock.context.policyFile.sha256;
        baselineGeneration=$(if ($null -eq $state.current) {0L} else {$state.current.record.generation})}
    $null=Write-ClcStateRecord $lock journal $j $state.journal.sha256
    $Session.attemptId=$AttemptId; $Session.recoveryAdmitted=$true
    $null=Invoke-ClcApplicationValidation $Session $selected $source
    $Session.recoveryEffectsStarted=$true
    $null=Invoke-ClcIisLifecycle $Session Stop
    if ($Mode -ceq 'RestoreEmpty') {
        $guard=@($candidate.manifest.files | Where-Object path -CEQ 'application/web.config')
        Invoke-ClcManagedReplacement $Session $source $guard $candidate.manifest.files -Partial -AllowChanged
        $current=Read-ClcStateFile $lock current
        if ($null -ne $current) {
            $saved=Join-Path $lock.identity.controlRoot ('attempts\'+$AttemptId+'\current-before-empty-'+$sequence+'.json')
            $null=Write-ClcStateBytes $lock $saved $current.bytes current $null -CreateNew
            Assert-ClcFilePath (Get-ClcStateRecordPath $lock current)
            [IO.File]::Delete((Get-ClcStateRecordPath $lock current))
        }
        $final=Complete-ClcAttempt $Session RestoredEmpty (Assert-ClcEffectAuthority $Session -Stopped)
        return @{status='RestoredEmpty';state=$final}
    }
    if ($Mode -ceq 'RestorePrevious') {
        Invoke-ClcManagedReplacement $Session $source $selected.manifest.files $candidate.manifest.files -Partial -OtherFiles $other -AllowChanged
    }
    $null=Invoke-ClcIisLifecycle $Session Start
    $ready=Wait-ClcApplicationReady $Session $selected
    $outcome=if ($Mode -ceq 'RestorePrevious') {'RestoredPrevious'} else {'AcceptedCandidate'}
    return @{status=$outcome;state=(Publish-ClcReadyCurrent $Session $selected $ready $outcome)}
}

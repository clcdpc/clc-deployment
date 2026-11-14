function Get-ClcReleaseIdentity {
    param($Release)
    $a=$Release.approvalFile.record; $m=$Release.manifest
    return @{approvalId=$a.approvalId;applicationId=$m.applicationId;releaseId=$m.releaseId;sourceCommit=$m.source.commit;
        archiveSha256=$a.releaseZipSha256;manifestSha256=$a.manifestSha256;inventorySha256=$m.inventorySha256}
}
function Assert-ClcReleaseBinding {
    param($Release,$Identity,$ApprovalSnapshot)
    if (-not (Test-ClcValueEqual (Get-ClcReleaseIdentity $Release) $Identity) -or $Release.approvalFile.sha256 -cne $ApprovalSnapshot.sha256 -or
        $Release.approvalFile.record.lineageId -cne $ApprovalSnapshot.lineageId -or $Release.approvalFile.record.releaseSequence -ne $ApprovalSnapshot.releaseSequence) { Stop-ClcError Clc.ApprovalMismatch }
}
function Assert-ClcEffectAuthority {
    param($Session,[switch] $Stopped)
    $lock=$Session.lock
    $actual=Assert-ClcLockedTarget $lock
    foreach ($release in @($Session.release,$Session.previousRelease)) {
        if ($null -ne $release) { Assert-ClcApprovedReleaseUnchanged $lock.context $release }
    }
    if ($Session.ContainsKey('recoveryApproval')) { Assert-ClcHeldRecordUnchanged $lock.context $Session.recoveryApproval 'Clc.ApprovalMismatch' }
    if ($Session.ContainsKey('persistentStateApproval')) { Assert-ClcHeldRecordUnchanged $lock.context $Session.persistentStateApproval 'Clc.PersistentStateApprovalRequired' }
    Assert-ClcConfigurationUnchanged $Session
    Assert-ClcStableIisObservation $lock.targetFile.record $actual.iis $lock.identity.snapshot.applicationPoolName
    if ((Get-ClcIisConfigurationHash $actual.iis) -cne $Session.iisConfigurationSha256) { Stop-ClcError Clc.HostPreflightFailed }
    if ($Stopped -and ($actual.iis.poolState -cne 'Stopped' -or $actual.iis.workers.Count -ne 0)) { Stop-ClcError Clc.ShutdownTimeout }
    return @{poolState=$actual.iis.poolState;workerCount=[long]$actual.iis.workers.Count;hostObservationSha256=$Session.hostDigest}
}
function Save-ClcAttemptSnapshot {
    param($Lock)
    $file=Read-ClcStateFile $Lock journal; $j=$file.record
    $name=if ($null -eq $j.recovery) {'deployment.json'} else {'recovery-'+$j.recovery.sequence+'.json'}
    $path=Join-Path $Lock.identity.controlRoot ('attempts\'+$j.attemptId+'\'+$name)
    $null=Write-ClcStateBytes $Lock $path $file.bytes journal $null -CreateNew
}
function Complete-ClcAttempt {
    param($Session,[string] $Outcome,$Pool)
    $lock=$Session.lock; $file=Write-ClcJournalIntent $lock Complete; $j=$file.record
    $j.phase='Completed'; $j.outcome=$Outcome; $j.updatedUtc=Get-ClcUtcTimestamp
    $j.observation=@{sequence=$j.intent.sequence;result=$Outcome;observedPoolState=$Pool.poolState;workerCount=$Pool.workerCount;observedUtc=$j.updatedUtc}
    $null=Write-ClcStateRecord $lock journal $j $file.sha256
    Save-ClcAttemptSnapshot $lock
    return Read-ClcDeploymentState $lock
}
function Publish-ClcReadyCurrent {
    param($Session,$Release,$Readiness,[string] $Outcome)
    $lock=$Session.lock
    $null=Get-ClcTreeInventory $lock.targetFile.record.applicationRoot $Release.manifest.files
    $pool=Assert-ClcEffectAuthority $Session; Assert-ClcReadyPool $pool
    $state=Read-ClcDeploymentState $lock
    $generation=if ($null -eq $state.current) {0L} else {$state.current.record.generation}
    if ($generation -eq [long]::MaxValue) { Stop-ClcError Clc.StatePersistenceFailed }
    $file=Write-ClcJournalIntent $lock PublishCurrent; $j=$file.record
    # Pin the prospective generation before publication. A crash in either write
    # remains pending and requires explicit recovery, even if current was saved.
    $j.publishedGeneration=$generation+1L
    $file=Write-ClcStateRecord $lock journal $j $file.sha256
    $approval=if ($Outcome -ceq 'RestoredPrevious') {$j.previous.approvalSnapshot} else {$j.approvalSnapshot}
    $record=[ordered]@{contractFamily='clc-file-iis-v1';schemaVersion=1L;recordKind='current';generation=$generation+1L;
        targetKey=$j.targetKey;targetSnapshot=$j.targetSnapshot;attemptId=$j.attemptId;recoverySequence=$(if ($null -eq $j.recovery) {0L} else {$j.recovery.sequence});
        approvalSnapshot=$approval;release=(Get-ClcReleaseIdentity $Release);executingToolkit=$lock.context.executingToolkit;
        configuration=$Session.configuration.record;hostObservationSha256=$Session.hostDigest;readiness=$Readiness;completedUtc=(Get-ClcUtcTimestamp)}
    $null=Write-ClcStateRecord $lock current $record $(if ($null -ne $state.current) {$state.current.sha256})
    $result=Complete-ClcAttempt $Session $Outcome $pool
    $null=Assert-ClcEffectAuthority $Session
    return $result
}
function Assert-ClcReadyPool {
    param($Pool)
    if ($Pool.poolState -cne 'Started' -or $Pool.workerCount -ne 1) { Stop-ClcError Clc.ReadinessFailed }
}
function Invoke-ClcAttemptFailure {
    param($Session,[string] $Code)
    if (-not $Session.ContainsKey('attemptId')) { return }
    $lock=$Session.lock; $file=Read-ClcStateFile $lock journal
    if ($null -eq $file -or $file.record.attemptId -cne $Session.attemptId) { return }
    $j=$file.record; $pool=@{poolState='Unknown';workerCount=$null}
    $canObserve=Test-ClcHelpersExited $j
    $preserved=$false
    if ($canObserve) {
        try {
            $pool=Get-ClcLivePool $lock
            # Reopen prior code only after an ordinary pre-replacement failure,
            # with verified prior files, compatible configuration and authority.
            if (-not $Session.replacementBegun -and -not $Session.ContainsKey('recoveryAdmitted') -and -not (Test-ClcExternalMutationIntent $j)) {
                $files=if ($null -eq $Session.previousRelease) {@($Session.baselineFiles)} else {@($Session.previousRelease.manifest.files)}
                $null=Get-ClcTreeInventory $lock.targetFile.record.applicationRoot $files
                $null=Assert-ClcEffectAuthority $Session
                if ($j.initialPoolState -ceq 'Started' -and $pool.poolState -ceq 'Stopped') { $pool=Invoke-ClcIisLifecycle $Session Start }
                $preserved=$pool.poolState -ceq $j.initialPoolState -and ($pool.poolState -ceq 'Started' -or $pool.workerCount -eq 0)
            }
            if (-not $preserved -and $j.liveMutationIntent) { $pool=Invoke-ClcIisLifecycle $Session Stop -Safety }
        } catch { try { $pool=Get-ClcLivePool $lock } catch { } }
    }
    $file=Read-ClcStateFile $lock journal; $j=$file.record
    # Do not overwrite a saved terminal snapshot. Preserve it and leave the
    # active journal pending if a return-path check failed after completion.
    $j.phase='RecoveryRequired'; $j.outcome=$null; $j.updatedUtc=Get-ClcUtcTimestamp
    $j.failure=@{code=$Code;nextAction='InspectRetainedMaterialAndRecover';observedPoolState=$pool.poolState;workerCount=$pool.workerCount}
    $null=Write-ClcStateRecord $lock journal $j $file.sha256
    if ($preserved -and (Test-ClcHelpersExited $j)) {
        $name=if ($null -eq $j.recovery) {'deployment.json'} else {'recovery-'+$j.recovery.sequence+'.json'}
        if (-not [IO.File]::Exists((Join-Path $lock.identity.controlRoot ('attempts\'+$j.attemptId+'\'+$name)))) {
            $null=Complete-ClcAttempt $Session FailedPreserved $pool
        }
    }
}
function New-ClcLifecycleError {
    param($Original,$Lock)
    $code=if ($Original.FullyQualifiedErrorId -like 'Clc.*') {$Original.FullyQualifiedErrorId.Split(',')[0]} else {'Clc.RecoveryRequired'}
    $message='Deployment failed. Preserve the application, staging, backup and attempt records; inspect the latest journal and use explicit recovery.'
    if ($null -ne $Lock) {
        try {
            $j=(Read-ClcStateFile $Lock journal).record; $pool=Get-ClcLivePool $Lock
            $message='Attempt '+$j.attemptId+'; pool '+$pool.poolState+'; workers '+$pool.workerCount+'. Retain '+$Lock.identity.controlRoot+'; inspect journal.json and select explicit recovery.'
        } catch { $message+=' Pool/worker observation unavailable; operator intervention required.' }
    }
    return [Management.Automation.ErrorRecord]::new([IO.InvalidDataException]::new($message),$code,[Management.Automation.ErrorCategory]::InvalidOperation,$null)
}
function Invoke-ClcDeploymentCore {
    param($Session,[string] $ReleaseApprovalId,[bool] $AllowDowngrade,[string] $Reason)
    if (-not $Session.ContainsKey('operation')) { $Session.operation='Deploy' }
    $lock=$Session.lock; $decision=Get-ClcReconciliationDecision $lock
    if ($decision.classification -cnotin @('Clean','EmptyRecoveryNeedsVerification')) { Stop-ClcError Clc.RecoveryRequired }
    $state=$lock.state
    if ($Session.ContainsKey('admittedRelease')) {
        # Admission authenticated these exact held bytes under this same lock.
        # This private handoff avoids a second archive inspection; public callers
        # cannot supply an approval, inspection result or session object.
        $Session.release=$Session.admittedRelease
        if ($Session.release.approvalFile.record.approvalId -cne $ReleaseApprovalId) { Stop-ClcError Clc.ApprovalMismatch }
        Assert-ClcApprovedReleaseUnchanged $lock.context $Session.release
    } else { $Session.release=Read-ClcApprovedRelease $lock.context $lock.targetFile.record.targetId $ReleaseApprovalId }
    if ($AllowDowngrade -and $Session.release.approvalFile.record.schemaVersion -ge 2) { Stop-ClcError Clc.DowngradeRejected }
    $Session.previousRelease=$null; $Session.replacementBegun=$false; $Session.baselineFiles=@()
    $Session.configuration=Open-ClcConfiguration $lock
    $hostFacts=Get-ClcHostPreflight $lock.context $lock.targetFile $lock.identity $Session.release.manifest.runtime.framework
    $Session.hostDigest=$hostFacts.hostObservationSha256; $Session.iisConfigurationSha256=$hostFacts.iisConfigurationSha256
    Initialize-ClcHookAuthorization $Session
    $previous=$null
    if ($null -ne $state.current) {
        $c=$state.current.record
        $Session.previousRelease=Read-ClcApprovedManifest $lock $c.release.approvalId
        Assert-ClcReleaseBinding $Session.previousRelease $c.release $c.approvalSnapshot
        $null=Get-ClcTreeInventory $lock.targetFile.record.applicationRoot $Session.previousRelease.manifest.files
        $a=$Session.release.approvalFile.record
        if ($a.schemaVersion -ge 2) { Assert-ClcAutomatedOrdering $a $Session.previousRelease.approvalFile.record }
        if (($a.lineageId -cne $c.approvalSnapshot.lineageId -or $a.releaseSequence -lt $c.approvalSnapshot.releaseSequence) -and -not $AllowDowngrade) { Stop-ClcError Clc.DowngradeRejected }
        if ($a.lineageId -ceq $c.approvalSnapshot.lineageId -and $a.releaseSequence -eq $c.approvalSnapshot.releaseSequence -and
            -not (Test-ClcValueEqual (Get-ClcReleaseIdentity $Session.release) $c.release)) {
            if ($a.schemaVersion -lt 2) { Stop-ClcError Clc.ApprovalMismatch }
        }
        $previous=@{generation=$c.generation;attemptId=$c.attemptId;approvalSnapshot=$c.approvalSnapshot;release=$c.release;configuration=$c.configuration}
    } elseif ($decision.classification -ceq 'EmptyRecoveryNeedsVerification') {
        $guardRelease=Read-ClcApprovedManifest $lock $state.journal.record.candidate.approvalId
        if (-not (Get-ClcEmptyBaselineEligibility $lock $guardRelease).eligible) { Stop-ClcError Clc.RecoveryRequired }
        $Session.baselineFiles=@($guardRelease.manifest.files | Where-Object path -CEQ 'application/web.config')
    } else { $null=Get-ClcTreeInventory $lock.targetFile.record.applicationRoot -ExpectedFiles @() }
    $oldFiles=if ($null -eq $Session.previousRelease) {$Session.baselineFiles} else {$Session.previousRelease.manifest.files}
    Assert-ClcPayloadLayout $oldFiles $Session.release.manifest.files
    $Session.attemptId=[guid]::NewGuid().ToString('D')
    # Persist an unresolved attempt before any new attempt material or app code.
    $null=New-ClcPreparedJournal $Session $previous $hostFacts
    New-ClcOwnedDirectory $lock (Join-Path $lock.identity.controlRoot ('attempts\'+$Session.attemptId)) -CreateNew
    Save-ClcRetainedRelease $lock $Session.release
    if ($Session.release.manifest.schemaVersion -eq 1 -and $null -ne $previous -and (Test-ClcValueEqual (Get-ClcReleaseIdentity $Session.release) $previous.release) -and
        $hostFacts.poolState -ceq 'Started' -and $state.current.record.hostObservationSha256 -ceq $Session.hostDigest) {
        # Validate the approved installed bytes before creating any staging material.
        $null=Invoke-ClcApplicationValidation $Session $Session.release $lock.targetFile.record.applicationRoot -BindConfiguration
        if (Test-ClcValueEqual $Session.configuration.record $previous.configuration) {
            $ready=Wait-ClcApplicationReady $Session $Session.release -NoOpProbe
            if ($null -ne $ready) {
                $final=Complete-ClcAttempt $Session NoOp (Assert-ClcEffectAuthority $Session)
                return @{status='NoOp';state=$final}
            }
        }
    }
    $stage=Expand-ClcApprovedRelease $lock $Session.release (Join-Path $lock.identity.controlRoot ('staging\'+$Session.attemptId))
    $Session.packageRoot=[IO.Path]::GetDirectoryName($stage)
    $null=Invoke-ClcApplicationValidation $Session $Session.release $stage -BindConfiguration
    if ($null -ne $previous) {
        if ($Session.configuration.record.privateSha256 -cne $previous.configuration.privateSha256 -and $Session.configuration.record.revision -ceq $previous.configuration.revision) { Stop-ClcError Clc.ConfigurationRevisionDrift }
        if ($Session.configuration.record.keyStoreCompatibilityId -cne $previous.configuration.keyStoreCompatibilityId) { Stop-ClcError Clc.PreviousConfigurationIncompatible }
        $null=Invoke-ClcApplicationValidation $Session $Session.previousRelease $lock.targetFile.record.applicationRoot
    }
    $null=Assert-ClcEffectAuthority $Session
    if ($Session.operation -ceq 'ValidateOnly') {
        Invoke-ClcDeploymentHook $Session Plan
        return @{status='Planned';state=(Complete-ClcAttempt $Session Planned (Assert-ClcEffectAuthority $Session))}
    }
    if ($Session.ContainsKey('hookPolicy')) {
        # The runtime cannot write managed files. Retain exact verified approved
        # bytes before any hook, without unnecessarily stopping a healthy site.
        $null=New-ClcVerifiedBackup $Session -Online
        Invoke-ClcDeploymentHook $Session Preflight
        Invoke-ClcDeploymentHook $Session BeforeStop
    }
    $null=Invoke-ClcIisLifecycle $Session Stop
    if (-not $Session.ContainsKey('hookPolicy')) { $null=New-ClcVerifiedBackup $Session }
    Invoke-ClcDeploymentHook $Session AfterStop
    Invoke-ClcManagedReplacement $Session $stage $Session.release.manifest.files $oldFiles
    $null=Assert-ClcEffectAuthority $Session -Stopped
    $null=Invoke-ClcIisLifecycle $Session Start
    $ready=Wait-ClcApplicationReady $Session $Session.release
    Invoke-ClcDeploymentHook $Session AfterStart
    $final=Publish-ClcReadyCurrent $Session $Session.release $ready Deployed
    return @{status='Deployed';state=$final}
}


function Restore-ClcIisDeployment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $ApplicationId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $TargetId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $ExpectedRuntimeAccount,
        [Parameter(Mandatory)][ValidateSet('Staging','Production')][string] $RuntimeEnvironment,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $AttemptId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $Reason
    )
    Assert-ClcGuid $AttemptId
    Assert-ClcCode $Reason
    Assert-ClcId $TargetId
    Assert-ClcPlatform
    $layout=Get-ClcHostLayout $ApplicationId
    $handles=[Collections.Generic.List[IDisposable]]::new()
    $lock=$null; $recovering=$false; $iisEffects=$false
    try {
        $target=Read-ClcLocalRecord $layout.hostRecord host
        if ($target.targetId -cne $TargetId -or $target.applicationId -cne $ApplicationId) { Stop-ClcError Clc.TargetMismatch 'Select the initialized application and deployment target.' }
        $lock=Enter-ClcDeploymentLock $layout
        $context=Open-ClcHostContext $ApplicationId $TargetId $ExpectedRuntimeAccount $RuntimeEnvironment -Recovery
        Assert-ClcRunnableContext $context
        $reference=$context.state.pending
        if ($null -eq $reference -or $reference.attemptId -cne $AttemptId) {
            Stop-ClcError Clc.RecoveryUnavailable 'Select the unresolved attempt. Completed and already recovered attempts cannot be replayed.'
        }
        $paths=Get-ClcAttemptPaths $layout $AttemptId
        $attempt=Read-ClcLocalRecord $paths.journal attempt
        $priorReference=if ($null -ne $context.state.current) {$context.state.current.release}
        if ($attempt.applicationId -cne $ApplicationId -or $attempt.targetId -cne $TargetId -or
            -not (Test-ClcSameReference $attempt.release $reference) -or
            (($null -eq $attempt.previous) -ne ($null -eq $priorReference)) -or
            ($null -ne $priorReference -and -not (Test-ClcSameReference $attempt.previous $priorReference)) -or
            $attempt.phase -cin @('Recovering','Restored') -or (Test-ClcStorageEntry $paths.beforeRecovery)) {
            Stop-ClcError Clc.RecoveryUnavailable 'The attempt and current state disagree or recovery already began. Preserve the evidence and reconcile manually.'
        }
        Assert-ClcHelperExited $attempt.helper
        $iis=$context.iis
        if ($iis.siteState -cnotin @('Started','Stopped') -or $iis.poolState -cnotin @('Started','Stopped') -or
            $iis.workerCount -gt 1 -or ($iis.poolState -ceq 'Stopped' -and $iis.workerCount -ne 0)) {
            Stop-ClcError Clc.IisStateUnknown 'Wait for stable IIS state and reconcile unexpected workers before explicit recovery.'
        }
        $context.configurationFile=Read-ClcHeldFile $layout.config $handles 4194304 -NoCapture
        $priorFiles=@(if ($null -ne $context.previous) {$context.previous.files})
        $candidateFiles=@()
        $mayHaveReplaced=$attempt.phase -cin @('Replacing','Checking','Ready')
        if ($mayHaveReplaced) {
            $candidate=Read-ClcRetainedManifest $context $reference
            $candidateFiles=$candidate.files
            Assert-ClcCompatibleLayout $priorFiles $candidateFiles
        }
        $null=Get-ClcTreeInventory $layout.application $priorFiles -OtherFiles $candidateFiles -Partial:$mayHaveReplaced -RuntimeSid $context.runtimeSid
        if ($attempt.backupVerified) {
            $null=Get-ClcTreeInventory $paths.backup $priorFiles -RuntimeSid $context.runtimeSid -Protected
        } elseif ($mayHaveReplaced) {
            Stop-ClcError Clc.BackupInvalid 'Replacement may have begun and no verified backup is recorded. Preserve the attempt for manual reconciliation.'
        }
        Assert-ClcEffectContext $context
        Write-ClcLocalRecord $paths.beforeRecovery $attempt
        $attempt.phase='Recovering'
        $attempt.reason=$Reason
        Write-ClcLocalRecord $paths.journal $attempt -Replace
        $recovering=$true
        if ($null -ne $context.previous) {
            $source=if ($attempt.backupVerified) {$paths.backup} else {$layout.application}
            $configuration=Invoke-ClcApplicationValidation $context $attempt $paths $context.previous $source
            if ($configuration.keyStoreCompatibilityId -cne $context.state.current.keyStoreCompatibilityId) {
                Stop-ClcError Clc.ConfigurationInvalid 'The previous release did not validate with the recorded persistent key compatibility identity.'
            }
        }
        $iisEffects=$true
        Stop-ClcApplication $context
        if ($mayHaveReplaced) {
            Set-ClcApplicationFiles $context $paths.backup $priorFiles $priorFiles (Join-Path $paths.root 'restore.tmp') -Candidate $candidateFiles -Partial
        }
        if ($null -ne $context.previous) {
            $iis=Start-ClcApplication $context $context.previous $configuration
            $context.state.current=New-ClcCurrent $priorReference $configuration
            $status='RestoredPrevious'
            $releaseId=$context.previous.releaseId
        } else {
            Assert-ClcQuiescent $context
            $null=Get-ClcTreeInventory $layout.application @()
            $iis=Get-ClcLiveIisState $context
            $status='RestoredEmpty'
            $releaseId=$null
        }
        $attempt.phase='Restored'
        Write-ClcLocalRecord $paths.journal $attempt -Replace
        $context.state.pending=$null
        Write-ClcLocalRecord $layout.state $context.state -Replace
        $recovering=$false
        return New-ClcDeploymentResult $status $context $reference $paths $iis $releaseId
    } catch {
        if ($recovering) { Stop-ClcFailedAttempt $_ $context $attempt $paths $iisEffects }
        $finding=Get-ClcSafeFinding $_
        Stop-ClcError $finding.code $finding.message
    } finally {
        foreach ($handle in $handles) { $handle.Dispose() }
        if ($null -ne $lock) { $lock.Dispose() }
    }
}

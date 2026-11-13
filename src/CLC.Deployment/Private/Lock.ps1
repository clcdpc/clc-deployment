function Assert-ClcLockOwned {
    param($Lock)
    if ($null -eq $Lock -or $Lock.ownerProcessId -ne $PID -or $Lock.closed -or $Lock.stream.SafeFileHandle.IsClosed -or $Lock.stream.SafeFileHandle.IsInvalid) { Stop-ClcError Clc.ConcurrentDeployment }
    $facts=[Clc.Foundation.NativePaths]::Observe($Lock.stream.SafeFileHandle)
    if ($facts.VolumeId -cne $Lock.lockFacts.VolumeId -or $facts.FileId -cne $Lock.lockFacts.FileId -or
        -not $facts.CanonicalPath.Equals($Lock.identity.lockPath,[StringComparison]::OrdinalIgnoreCase) -or $facts.LinkCount -ne 1 -or ($facts.Attributes -band 0x410) -ne 0) { Stop-ClcError Clc.UnsafePath }
}

function Enter-ClcDeploymentLock {
    [CmdletBinding()]
    param($Context, [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9-]{0,63}$')][string] $TargetId)
    $stream=$null
    try {
        $target=Read-ClcProtectedTarget $Context $TargetId
        $identity=Get-ClcTargetIdentity $Context $target
        # OPEN_REPARSE_POINT observes the opened leaf itself without following an alias.
        # Do not pre-open an existing lock: its owner's exclusive handle forbids that.
        try { $stream=[Clc.Host.Native]::OpenLock($identity.lockPath) }
        catch { Stop-ClcError Clc.ConcurrentDeployment }
        $facts=[Clc.Foundation.NativePaths]::Observe($stream.SafeFileHandle)
        if (-not $facts.CanonicalPath.Equals($identity.lockPath,[StringComparison]::OrdinalIgnoreCase) -or $facts.LinkCount -ne 1 -or ($facts.Attributes -band 0x410) -ne 0) { Stop-ClcError Clc.UnsafePath }
        [Clc.Foundation.NativePaths]::CheckStreams($identity.lockPath)
        $policy=$Context.policyFile.record
        $null=Assert-ClcAccess $identity.lockPath ([string[]]($policy.infrastructureOwnerSids+$policy.deploymentSids)) ([string[]]($policy.infrastructureOwnerSids+$policy.deploymentSids)) ([string[]]$policy.deploymentSids) @($target.record.runtimeIdentitySid)
        $lockedIdentity=Get-ClcTargetIdentity $Context $target
        if ($lockedIdentity.targetKey -cne $identity.targetKey -or -not (Test-ClcValueEqual $lockedIdentity.snapshot $identity.snapshot)) { Stop-ClcError Clc.HostPreflightFailed }
        $lock=@{ context=$Context; targetFile=$target; identity=$lockedIdentity; stream=$stream; lockFacts=$facts;
            ownerProcessId=$PID; closed=$false; state=$null }
        $lock.state=Read-ClcDeploymentState $lock
        return $lock
    } catch {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($_.FullyQualifiedErrorId -like 'Clc.*') { throw }
        Stop-ClcError Clc.RecoveryRequired
    }
}

function Exit-ClcDeploymentLock {
    param($Lock)
    if ($null -ne $Lock) { $Lock.stream.Dispose(); $Lock.closed=$true }
}

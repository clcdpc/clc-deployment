# State is one atomic attempt record, one current record and a retained backup
# index. A pending phase blocks retries; individual file copies are not journaled.
function Assert-ClcStatePathBudget {
    param($Policy)
    try {
        Assert-ClcPathSpelling (Join-Path $Policy.controlStateRoot (('0'*64)+'\attempts\'+[guid]::Empty.ToString('D')+'\state-'+[guid]::Empty.ToString('D')+'.tmp'))
        Assert-ClcPathSpelling (Join-Path $Policy.lockRoot (('0'*64)+'.lock'))
    } catch { Stop-ClcError Clc.HostPreflightFailed }
}
function Get-ClcStateRecordPath {
    param($Lock,[ValidateSet('journal','current','backup-index')][string] $Kind,[string] $AttemptId)
    Assert-ClcLockOwned $Lock
    if ($Kind -ceq 'backup-index') {
        Assert-ClcGuid $AttemptId
        return Join-Path $Lock.identity.controlRoot ('backups\'+$AttemptId+'\index.json')
    }
    return Join-Path $Lock.identity.controlRoot ($Kind+'.json')
}
function Assert-ClcStateIdentity {
    param($Lock,$Record)
    if ($Record.targetKey -cne $Lock.identity.targetKey -or
        ($Record.recordKind -cne 'backup-index' -and -not (Test-ClcValueEqual $Record.targetSnapshot $Lock.identity.snapshot))) { Stop-ClcError Clc.RecoveryRequired }
}
function Read-ClcStatePath {
    param($Lock,[string] $Path,[string] $Kind)
    Assert-ClcLockOwned $Lock
    if (-not (Test-ClcPathAncestry $Lock.identity.controlRoot $Path)) { Stop-ClcError Clc.UnsafePath }
    $handles=[Collections.Generic.List[IDisposable]]::new()
    try {
        Assert-ClcControlAncestorAccess $Lock.context $Lock.identity.controlRoot $Path $Lock.targetFile.record.runtimeIdentitySid $handles
        Assert-ClcPathAccess $Lock.context $Path $Lock.targetFile.record.runtimeIdentitySid Mutable
        $file=Read-ClcHeldRecord $Path $Kind $handles
        Assert-ClcStateIdentity $Lock $file.record
        return @{record=$file.record;bytes=$file.bytes;sha256=$file.sha256}
    } finally { foreach ($handle in $handles) { $handle.Dispose() } }
}
function Read-ClcStateFile {
    param($Lock,[string] $Kind,[string] $AttemptId)
    $path=Get-ClcStateRecordPath $Lock $Kind $AttemptId
    if (-not [IO.File]::Exists($path)) { return $null }
    return Read-ClcStatePath $Lock $path $Kind
}
function Read-ClcDeploymentState {
    param($Lock)
    Assert-ClcLockOwned $Lock
    try {
        Assert-ClcControlRootBoundary $Lock.context $Lock.identity $Lock.targetFile.record.runtimeIdentitySid
        return @{journal=(Read-ClcStateFile $Lock journal);current=(Read-ClcStateFile $Lock current)}
    } catch { Stop-ClcError Clc.RecoveryRequired }
}
function Write-ClcStateBytes {
    param($Lock,[string] $Path,[byte[]] $Bytes,[string] $Kind,[string] $ExpectedSha256,[switch] $CreateNew)
    Assert-ClcLockOwned $Lock
    $record=Read-ClcJson $Bytes $Kind
    Assert-ClcStateIdentity $Lock $record
    Assert-ClcPathSpelling $Path
    if (-not (Test-ClcPathAncestry $Lock.identity.controlRoot $Path)) { Stop-ClcError Clc.UnsafePath }
    $handles=[Collections.Generic.List[IDisposable]]::new(); $stream=$null
    # A single temporary state file is retained on failed publication. Its presence
    # blocks admission and requires operator reconciliation, never silent cleanup.
    $temporary=Join-Path ([IO.Path]::GetDirectoryName($Path)) ('state-'+[guid]::NewGuid().ToString('D')+'.tmp')
    try {
        Assert-ClcControlAncestorAccess $Lock.context $Lock.identity.controlRoot $Path $Lock.targetFile.record.runtimeIdentitySid $handles
        $null=Get-ClcPathObservation ([IO.Path]::GetDirectoryName($Path)) $handles -Directory
        if ([IO.File]::Exists($Path)) {
            if ($CreateNew) { Stop-ClcError Clc.StatePersistenceFailed }
            $old=Read-ClcStatePath $Lock $Path $Kind
            if (-not $ExpectedSha256 -or $old.sha256 -cne $ExpectedSha256) { Stop-ClcError Clc.StatePersistenceFailed }
        } elseif ($ExpectedSha256) { Stop-ClcError Clc.StatePersistenceFailed }
        $stream=[IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $stream.Write($Bytes); $stream.Flush($true); $stream.Dispose(); $stream=$null
        [IO.File]::Move($temporary,$Path,(-not $CreateNew))
        $saved=Read-ClcStatePath $Lock $Path $Kind
        if ($saved.sha256 -cne (Get-ClcBytesHash $Bytes)) { Stop-ClcError Clc.StatePersistenceFailed }
        return $saved
    } catch {
        if ($_.FullyQualifiedErrorId -like 'Clc.*') { throw }
        Stop-ClcError Clc.StatePersistenceFailed
    } finally { if ($null -ne $stream) { $stream.Dispose() }; foreach ($handle in $handles) { $handle.Dispose() } }
}
function Write-ClcStateRecord {
    param($Lock,[string] $Kind,$Record,[string] $ExpectedSha256,[string] $AttemptId)
    $bytes=[Text.Encoding]::UTF8.GetBytes(($Record | ConvertTo-Json -Depth 24 -Compress))
    return Write-ClcStateBytes $Lock (Get-ClcStateRecordPath $Lock $Kind $AttemptId) $bytes $Kind $ExpectedSha256
}

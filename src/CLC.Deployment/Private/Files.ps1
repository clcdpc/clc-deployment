function Get-ClcManagedPath {
    param([string] $Root,[string] $RelativePath)
    Assert-ClcArchiveName $RelativePath -PayloadOnly
    $path=Join-Path $Root ($RelativePath.Substring(12).Replace('/','\'))
    Assert-ClcPathSpelling $path
    return $path
}
function Assert-ClcLockedTarget {
    param($Lock)
    Assert-ClcLockOwned $Lock
    $actual=Get-ClcTargetIdentity $Lock.context $Lock.targetFile
    if ($actual.targetKey -cne $Lock.identity.targetKey -or -not (Test-ClcValueEqual $actual.snapshot $Lock.identity.snapshot)) { Stop-ClcError Clc.HostPreflightFailed }
    return $actual
}
function Assert-ClcFilePath {
    param([string] $Path,[switch] $Directory)
    $handles=[Collections.Generic.List[IDisposable]]::new()
    try { $null=Get-ClcPathObservation $Path $handles -Directory:$Directory }
    finally { foreach ($handle in $handles) { $handle.Dispose() } }
}
function New-ClcOwnedDirectory {
    param($Lock,[string] $Path,[switch] $CreateNew)
    Assert-ClcLockOwned $Lock
    Assert-ClcPathSpelling $Path
    $root=$Lock.identity.controlRoot
    if (-not (Test-ClcPathAncestry $root $Path) -or $root -ceq $Path) { Stop-ClcError Clc.UnsafePath }
    $current=$root
    foreach ($part in $Path.Substring($root.Length+1).Split('\')) {
        Assert-ClcFilePath $current -Directory
        $current=Join-Path $current $part
        if ($CreateNew -and $current -ceq $Path -and ([IO.File]::Exists($current) -or [IO.Directory]::Exists($current))) { Stop-ClcError Clc.ContentDrift }
        if (-not [IO.Directory]::Exists($current)) { $null=[IO.Directory]::CreateDirectory($current) }
        Assert-ClcFilePath $current -Directory
    }
}
function Get-ClcTreeInventory {
    param([string] $Root,[object[]] $ExpectedFiles,[switch] $Partial,[object[]] $OtherFiles=@(),[switch] $AllowChanged,
        [Diagnostics.Stopwatch] $DeadlineClock=$null,[int] $DeadlineSeconds=300)
    if ($null -eq $ExpectedFiles) { $ExpectedFiles=@() }
    if ($null -eq $DeadlineClock) { $DeadlineClock=[Diagnostics.Stopwatch]::StartNew() }
    $handles=[Collections.Generic.List[IDisposable]]::new()
    try {
        $rootFacts=Get-ClcPathObservation $Root $handles -Directory
        $allowed=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        $directories=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($file in @($ExpectedFiles)+@($OtherFiles)) {
            if ($null -eq $file) { continue }
            if (-not $allowed.ContainsKey($file.path)) { $allowed.Add($file.path,[Collections.Generic.List[object]]::new()) }
            $allowed[$file.path].Add($file)
            foreach ($prefix in Get-ClcNamePrefixes $file.path) { $null=$directories.Add($prefix) }
        }
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $queue=[Collections.Generic.Queue[object]]::new(); $queue.Enqueue(@{path=$Root;facts=$rootFacts})
        $files=[Collections.Generic.List[object]]::new(); $total=0L; $count=0
        while ($queue.Count) {
            $parent=$queue.Dequeue()
            foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($parent.path)) {
                Assert-ClcDeadline $DeadlineClock $DeadlineSeconds
                $count++; if ($count -gt $script:ClcLimits.Entries) { Stop-ClcError Clc.ContentDrift }
                $relative='application/'+$entry.Substring($Root.Length+1).Replace('\','/')
                Assert-ClcArchiveName $relative -PayloadOnly
                if (-not $seen.Add($relative)) { Stop-ClcError Clc.ContentDrift }
                $directory=([IO.File]::GetAttributes($entry) -band [IO.FileAttributes]::Directory) -ne 0
                $facts=Get-ClcChildPathObservation $entry $parent.facts $handles -Directory:$directory
                if ($directory) {
                    if (-not $directories.Contains($relative)) { Stop-ClcError Clc.ContentDrift }
                    $queue.Enqueue(@{path=$entry;facts=$facts}); continue
                }
                if (-not $allowed.ContainsKey($relative)) { Stop-ClcError Clc.ContentDrift }
                $stream=Open-ClcReadFile $entry $facts $handles
                $digest=Read-ClcStream $stream $script:ClcLimits.File $DeadlineClock -Seconds $DeadlineSeconds
                if (-not $AllowChanged -and @($allowed[$relative] | Where-Object { $_.length -eq $digest.length -and $_.sha256 -ceq $digest.sha256 }).Count -eq 0) { Stop-ClcError Clc.ContentDrift }
                $total+=$digest.length; if ($total -gt $script:ClcLimits.Expanded) { Stop-ClcError Clc.ContentDrift }
                $files.Add(@{path=$relative;length=$digest.length;sha256=$digest.sha256})
            }
        }
        $digest=Get-ClcInventoryHash $files.ToArray()
        if (-not $Partial -and ($files.Count -ne $ExpectedFiles.Count -or $digest -cne (Get-ClcInventoryHash $ExpectedFiles))) { Stop-ClcError Clc.ContentDrift }
        Assert-ClcDeadline $DeadlineClock $DeadlineSeconds
        return @{files=$files.ToArray();inventorySha256=$digest;rootFacts=$rootFacts}
    } finally { foreach ($handle in $handles) { $handle.Dispose() } }
}
function Save-ClcRetainedRelease {
    param($Lock,$Release)
    $root=Join-Path $Lock.identity.controlRoot 'releases'
    New-ClcOwnedDirectory $Lock $root
    $path=Join-Path $root ($Release.approvalFile.record.approvalId+'.json')
    if ([IO.File]::Exists($path)) {
        $handles=[Collections.Generic.List[IDisposable]]::new()
        try { if ((Read-ClcHeldRecord $path release-manifest $handles).sha256 -cne $Release.approvalFile.record.manifestSha256) { Stop-ClcError Clc.ContentDrift } }
        finally { foreach ($handle in $handles) { $handle.Dispose() } }
    } else {
        $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try { $stream.Write($Release.manifestBytes); $stream.Flush($true) } finally { $stream.Dispose() }
    }
    # The exact approval-pinned manifest and verified backup suffice for recovery.
    # Historical ZIPs are neither copied nor rehashed on each deployment.
}
function Expand-ClcApprovedRelease {
    param($Lock,$Release,[string] $StageRoot)
    Assert-ClcApprovedReleaseUnchanged $Lock.context $Release
    $clock=[Diagnostics.Stopwatch]::StartNew()
    New-ClcOwnedDirectory $Lock $StageRoot -CreateNew
    $root=Join-Path $StageRoot 'application'; New-ClcOwnedDirectory $Lock $root
    foreach ($file in $Release.manifest.files) { $null=Get-ClcManagedPath $root $file.path }
    $Release.archive.stream.Position=0
    $zip=[IO.Compression.ZipArchive]::new($Release.archive.stream,[IO.Compression.ZipArchiveMode]::Read,$true)
    try {
        foreach ($file in $Release.manifest.files) {
            Assert-ClcDeadline $clock
            $path=Get-ClcManagedPath $root $file.path
            New-ClcOwnedDirectory $Lock ([IO.Path]::GetDirectoryName($path))
            $source=$zip.GetEntry($file.path).Open(); $output=$null
            try {
                $output=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                $digest=Read-ClcStream $source $file.length $clock -Destination $output
                $output.Flush($true)
                if ($digest.length -ne $file.length -or $digest.sha256 -cne $file.sha256) { Stop-ClcError Clc.HashMismatch }
            } finally { $source.Dispose(); if ($null -ne $output) { $output.Dispose() } }
        }
    } finally { $zip.Dispose(); $Release.archive.stream.Position=0 }
    $null=Get-ClcTreeInventory $root $Release.manifest.files -DeadlineClock $clock
    Assert-ClcSafeDescendants $root $Lock.context $Lock.targetFile.record.runtimeIdentitySid Mutable
    return $root
}
function Copy-ClcPayloadFile {
    param([string] $Source,[string] $Destination,[bool] $Overwrite)
    Assert-ClcFilePath $Source
    Assert-ClcFilePath ([IO.Path]::GetDirectoryName($Destination)) -Directory
    if ([IO.File]::Exists($Destination)) { Assert-ClcFilePath $Destination }
    [IO.File]::Copy($Source,$Destination,$Overwrite)
}
function New-ClcVerifiedBackup {
    param($Session)
    $lock=$Session.lock; $j=(Read-ClcStateFile $lock journal).record
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $null=Write-ClcJournalIntent $lock Backup
    Assert-ClcIisQuiescent $lock
    $files=@(if ($null -ne $Session.previousRelease) {$Session.previousRelease.manifest.files})
    $null=Get-ClcTreeInventory $lock.targetFile.record.applicationRoot $(if ($null -eq $Session.previousRelease) {$Session.baselineFiles} else {$files}) -DeadlineClock $clock
    $backup=Join-Path $lock.identity.controlRoot ('backups\'+$Session.attemptId)
    New-ClcOwnedDirectory $lock $backup -CreateNew
    $payload=Join-Path $backup 'application'; New-ClcOwnedDirectory $lock $payload
    foreach ($file in $files) {
        Assert-ClcDeadline $clock
        $destination=Get-ClcManagedPath $payload $file.path
        New-ClcOwnedDirectory $lock ([IO.Path]::GetDirectoryName($destination))
        Copy-ClcPayloadFile (Get-ClcManagedPath $lock.targetFile.record.applicationRoot $file.path) $destination $false
    }
    $null=Get-ClcTreeInventory $payload $files -DeadlineClock $clock
    $index=[ordered]@{contractFamily='clc-file-iis-v1';schemaVersion=1L;recordKind='backup-index';attemptId=$j.attemptId;targetKey=$j.targetKey;
        priorEmpty=($null -eq $j.previous);priorApprovalId=$(if ($null -ne $j.previous) {$j.previous.release.approvalId});
        priorManifestSha256=$(if ($null -ne $j.previous) {$j.previous.release.manifestSha256});files=$files;inventorySha256=(Get-ClcInventoryHash $files)}
    $saved=Write-ClcStateRecord $lock backup-index $index $null $j.attemptId
    $file=Read-ClcStateFile $lock journal; $j=$file.record
    $j.backup=@{verified=$true;indexSha256=$saved.sha256;inventorySha256=$index.inventorySha256;priorEmpty=$index.priorEmpty}
    $null=Write-ClcStateRecord $lock journal $j $file.sha256
    Assert-ClcDeadline $clock
    return $payload
}
function Assert-ClcBackup {
    param($Session,$Journal)
    if ($null -eq $Journal.backup -or -not $Journal.backup.verified) { Stop-ClcError Clc.BackupInvalid }
    $file=Read-ClcStateFile $Session.lock backup-index $Journal.attemptId
    if ($null -eq $file -or $file.sha256 -cne $Journal.backup.indexSha256 -or
        $file.record.inventorySha256 -cne $Journal.backup.inventorySha256 -or $file.record.priorEmpty -ne $Journal.initialTargetEmpty) { Stop-ClcError Clc.BackupInvalid }
    if ($null -ne $Journal.previous -and ($file.record.priorApprovalId -cne $Journal.previous.release.approvalId -or
        $file.record.priorManifestSha256 -cne $Journal.previous.release.manifestSha256 -or $file.record.inventorySha256 -cne $Journal.previous.release.inventorySha256)) { Stop-ClcError Clc.BackupInvalid }
    $root=Join-Path $Session.lock.identity.controlRoot ('backups\'+$Journal.attemptId+'\application')
    $null=Get-ClcTreeInventory $root $file.record.files
    Assert-ClcSafeDescendants $root $Session.lock.context $Session.lock.targetFile.record.runtimeIdentitySid Mutable
    return $root
}

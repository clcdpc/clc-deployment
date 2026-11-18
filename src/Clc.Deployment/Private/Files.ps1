function Get-ClcManagedPath {
    param([string] $Root,[string] $RelativePath)
    Assert-ClcArchiveName $RelativePath -PayloadOnly
    $path=Join-Path $Root ($RelativePath.Substring(12).Replace('/','\'))
    Assert-ClcPathSpelling $path
    return $path
}
function Get-ClcTreeInventory {
    param([string] $Root,[object[]] $ExpectedFiles,[switch] $Partial,[object[]] $OtherFiles=@(),
        [Diagnostics.Stopwatch] $DeadlineClock=$null,[int] $DeadlineSeconds=300, [string] $RuntimeSid, [switch] $Protected)
    if ($null -eq $ExpectedFiles) { $ExpectedFiles=@() }
    if ($null -eq $DeadlineClock) { $DeadlineClock=[Diagnostics.Stopwatch]::StartNew() }
    $handles=[Collections.Generic.List[IDisposable]]::new()
    try {
        $rootFacts=Get-ClcPathObservation $Root $handles -Directory

        $aclCache=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $readers=@()
        if ($RuntimeSid -and -not $Protected) { $readers=@($RuntimeSid) }
        if ($RuntimeSid) { $null=Assert-ClcAccess $Root $script:ClcAdministrators $script:ClcAdministrators $readers @($RuntimeSid) -ReadMask 0x1200A9 -Cache $aclCache }
        $allowed=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        $directories=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($file in @($ExpectedFiles)+@($OtherFiles)) {
            if ($null -eq $file) { continue }
            if (-not $allowed.ContainsKey($file.path)) { $allowed.Add($file.path,[Collections.Generic.List[object]]::new()) }
            $allowed[$file.path].Add($file)
            foreach ($prefix in Get-ClcNamePrefixes $file.path) { $null=$directories.Add($prefix) }
        }
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $actualDirectories=[Collections.Generic.List[string]]::new()
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
                if ($RuntimeSid) { $null=Assert-ClcAccess $entry $script:ClcAdministrators $script:ClcAdministrators $readers @($RuntimeSid) -ReadMask 0x1200A9 -Cache $aclCache }
                if ($directory) {
                    if (-not $directories.Contains($relative)) { Stop-ClcError Clc.ContentDrift }
                    $actualDirectories.Add($relative)
                    $queue.Enqueue(@{path=$entry;facts=$facts}); continue
                }
                if (-not $allowed.ContainsKey($relative)) { Stop-ClcError Clc.ContentDrift }
                $stream=Open-ClcReadFile $entry $facts $handles
                $digest=Read-ClcStream $stream $script:ClcLimits.File $DeadlineClock -Seconds $DeadlineSeconds
                if (@($allowed[$relative] | Where-Object { $_.length -eq $digest.length -and $_.sha256 -ceq $digest.sha256 }).Count -eq 0) { Stop-ClcError Clc.ContentDrift }
                $total+=$digest.length; if ($total -gt $script:ClcLimits.Expanded) { Stop-ClcError Clc.ContentDrift }
                $files.Add(@{path=$relative;length=$digest.length;sha256=$digest.sha256})
            }
        }
        $digest=Get-ClcInventoryHash $files.ToArray()
        if (-not $Partial -and ($files.Count -ne $ExpectedFiles.Count -or $digest -cne (Get-ClcInventoryHash $ExpectedFiles))) { Stop-ClcError Clc.ContentDrift }
        Assert-ClcDeadline $DeadlineClock $DeadlineSeconds
        return @{files=$files.ToArray();inventorySha256=$digest;directories=$actualDirectories.ToArray()}
    } finally { foreach ($handle in $handles) { $handle.Dispose() } }
}

function New-ClcPayloadParent {
    param([string] $Root,[string] $FilePath)
    $parent=[IO.Path]::GetDirectoryName($FilePath)
    if ($parent -ieq $Root) { return }
    $current=$Root
    foreach ($part in $parent.Substring($Root.Length+1).Split('\')) {
        Assert-ClcStoragePath $current -Directory
        $current=Join-Path $current $part
        if (-not (Test-ClcStorageEntry $current)) {
            $null=[IO.Directory]::CreateDirectory($current)
            Set-ClcManagedOwner $current
        }
        Assert-ClcStoragePath $current -Directory
    }
}

function Write-ClcPayload {
    param([IO.Stream] $Source,[string] $Destination,$File,[Diagnostics.Stopwatch] $Clock)
    $output=[IO.File]::Open($Destination,'CreateNew','Write','None')
    try {
        $digest=Read-ClcStream $Source $File.length $Clock -Destination $output
        if ($digest.length -ne $File.length -or $digest.sha256 -cne $File.sha256) {
            Stop-ClcError Clc.ContentDrift 'Application content changed during copy. Preserve the attempt and inspect the retained files.'
        }
        $output.Flush($true)
    } finally { $output.Dispose() }
    Set-ClcManagedOwner $Destination
}

function Expand-ClcApplication {
    param([IO.Stream] $Archive,$Manifest,[string] $Stage)
    New-ClcHostDirectory $Stage
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $Archive.Position=0
    $zip=[IO.Compression.ZipArchive]::new($Archive,'Read',$true)
    try {
        foreach ($file in $Manifest.files) {
            Assert-ClcDeadline $clock
            $destination=Get-ClcManagedPath $Stage $file.path
            New-ClcPayloadParent $Stage $destination
            $source=$zip.GetEntry($file.path).Open()
            try { Write-ClcPayload $source $destination $file $clock }
            finally { $source.Dispose() }
        }
    } finally { $zip.Dispose() }
    $null=Get-ClcTreeInventory $Stage $Manifest.files -DeadlineClock $clock
}

function Copy-ClcVerifiedPayload {
    param([string] $Source,[string] $Destination,$File,[Diagnostics.Stopwatch] $Clock)
    $handles=[Collections.Generic.List[IDisposable]]::new()
    try {
        $facts=Get-ClcPathObservation $Source $handles
        $stream=Open-ClcReadFile $Source $facts $handles
        Write-ClcPayload $stream $Destination $File $Clock
    } finally { foreach ($handle in $handles) { $handle.Dispose() } }
}

function New-ClcBackup {
    param($Context,[string] $Backup,[object[]] $Files)
    Assert-ClcReplacementSafe $Context
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $root=$Context.layout.application
    $null=Get-ClcTreeInventory $root $Files -DeadlineClock $clock -RuntimeSid $Context.runtimeSid
    New-ClcHostDirectory $Backup
    foreach ($file in $Files) {
        Assert-ClcDeadline $clock
        $destination=Get-ClcManagedPath $Backup $file.path
        New-ClcPayloadParent $Backup $destination
        Copy-ClcVerifiedPayload (Get-ClcManagedPath $root $file.path) $destination $file $clock
    }
    $null=Get-ClcTreeInventory $Backup $Files -DeadlineClock $clock -RuntimeSid $Context.runtimeSid -Protected
}

function Assert-ClcCompatibleLayout {
    param([object[]] $OldFiles,[object[]] $NewFiles)
    $paths=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    $files=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in @($OldFiles)+@($NewFiles)) {
        $null=$files.Add($file.path)
        foreach ($part in @($file.path)+@(Get-ClcNamePrefixes $file.path)) {
            if ($paths.ContainsKey($part) -and $paths[$part] -cne $part) {
                Stop-ClcError Clc.ContentDrift 'A release changes only the case of an existing application path.'
            }
            $paths[$part]=$part
        }
    }
    foreach ($name in $files) {
        foreach ($prefix in Get-ClcNamePrefixes $name) {
            if ($files.Contains($prefix)) { Stop-ClcError Clc.ContentDrift 'A release changes an existing application file into a directory or vice versa.' }
        }
    }
}

function Set-ClcInstalledFileAcl {
    param([string] $Path,[string] $RuntimeSid)
    # A same-volume rename preserves the temporary file's ACL. Grant the
    # intended rights before the file is published into the application tree.
    $acl=Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true,$false)
    foreach ($id in $script:ClcAdministrators+@($RuntimeSid)) {
        $rights=if ($id -ceq $RuntimeSid) {'ReadAndExecute'} else {'FullControl'}
        $rule=[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($id),$rights,'Allow')
        $acl.SetAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Set-ClcApplicationFiles {
    param($Context,[string] $Source,[object[]] $Selected,[object[]] $Previous,[string] $Temporary,
        [object[]] $Candidate=@(),[switch] $Partial)
    $root=$Context.layout.application
    $clock=[Diagnostics.Stopwatch]::StartNew()
    Assert-ClcReplacementSafe $Context
    $null=Get-ClcTreeInventory $Source $Selected -DeadlineClock $clock -RuntimeSid $Context.runtimeSid -Protected
    $live=Get-ClcTreeInventory $root $Previous -OtherFiles $Candidate -Partial:$Partial -DeadlineClock $clock -RuntimeSid $Context.runtimeSid
    $old=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($file in $live.files) { $old.Add($file.path,$file) }
    $needed=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($file in $Selected) {
        foreach ($directory in Get-ClcNamePrefixes $file.path) { $null=$needed.Add($directory) }
    }
    foreach ($file in @($Selected | Sort-Object @{Expression={if ($_.path -ceq 'application/web.config') {0} else {1}}},path)) {
        Assert-ClcDeadline $clock
        $destination=Get-ClcManagedPath $root $file.path
        New-ClcPayloadParent $root $destination
        Copy-ClcVerifiedPayload (Get-ClcManagedPath $Source $file.path) $Temporary $file $clock
        Set-ClcInstalledFileAcl $Temporary $Context.runtimeSid
        Assert-ClcQuiescent $Context
        if ($old.ContainsKey($file.path)) {
            Assert-ClcPayloadUnchanged $destination $old[$file.path] $clock
            [IO.File]::Move($Temporary,$destination,$true)
            $null=$old.Remove($file.path)
        } else { [IO.File]::Move($Temporary,$destination,$false) }
    }
    foreach ($file in @($old.Values | Sort-Object @{Expression={if ($_.path -ceq 'application/web.config') {1} else {0}}},path)) {
        Assert-ClcDeadline $clock
        $destination=Get-ClcManagedPath $root $file.path
        Assert-ClcQuiescent $Context
        Assert-ClcPayloadUnchanged $destination $file $clock
        [IO.File]::Delete($destination)
    }
    foreach ($directory in @($live.directories | Sort-Object Length -Descending)) {
        if ($needed.Contains($directory)) { continue }
        Assert-ClcDeadline $clock
        Assert-ClcQuiescent $Context
        $destination=Get-ClcManagedPath $root $directory
        Assert-ClcStoragePath $destination -Directory
        [IO.Directory]::Delete($destination,$false)
    }
    $null=Get-ClcTreeInventory $root $Selected -DeadlineClock $clock
    Assert-ClcReplacementSafe $Context
}
function Assert-ClcPayloadUnchanged {
    param([string] $Path,$File,[Diagnostics.Stopwatch] $Clock)
    $handles=[Collections.Generic.List[IDisposable]]::new()
    try {
        $observed=Read-ClcHeldFile $Path $handles $File.length -NoCapture -Clock $Clock
        if ($observed.sha256 -cne $File.sha256 -or $observed.stream.Length -ne $File.length) { Stop-ClcError Clc.ContentDrift }
    } finally { foreach ($handle in $handles) { $handle.Dispose() } }
}

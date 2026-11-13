. "$PSScriptRoot/Qualification.Common.ps1"
function Get-QAccessPathObservation([string] $Path,$Handles,[bool] $Directory) {
    & (Get-Module CLC.Deployment) { param($p,$h,$d) Get-ClcPathObservation $p $h -Directory:$d } $Path $Handles $Directory
}
function Read-QAccessFile([string] $Path,$Handles) {
    & (Get-Module CLC.Deployment) { param($p,$h) Read-ClcHeldFile $p $h 1073741824 -NoCapture } $Path $Handles
}
function Get-QNativeAccess([string] $Path,[bool] $Directory,[uint32] $Mask) {
    [Clc.Distribution.Paths]::ProbeAccess($Path,$Directory,$Mask)
}
function Assert-QAccessPolicy($Configuration,$Layout,$Policy,[string[]] $InfrastructureSids) {
    foreach ($name in @('machineIdentity','dotnetPath','appcmdPath')) {
        if ($Policy[$name] -cne $Configuration[$name]) { throw 'Protected host/helper identity drift.' }
    }
    foreach ($name in @('targetCatalogRoot','approvalCatalogRoot','controlStateRoot','lockRoot')) {
        if ($Policy[$name] -cne $Layout[$name]) { throw 'Protected policy path drift.' }
    }
    foreach ($name in @('version','sourceCommit','distributionSha256','inventorySha256')) {
        if ($Policy.activeToolkit[$name] -cne $Configuration.toolkit[$name]) { throw 'Active toolkit drift.' }
    }
    if ($Policy.activeToolkit.moduleManifestPath -cne (Get-QInstalledManifest $Configuration) -or
        ($Policy.deploymentSids -join ',') -cne $Configuration.deploymentSid -or
        (($Policy.infrastructureOwnerSids | Sort-Object) -join ',') -cne (($InfrastructureSids | Sort-Object) -join ',')) { throw 'Protected policy identity drift.' }
}
function Get-QAccessRights([string] $Path,[bool] $Directory,[string] $Role,[bool] $Keys) {
    $rights=@()
    $requested=@(@{name='WriteDataOrCreate';mask=2},@{name='AppendOrCreateSubdirectory';mask=4},@{name='WriteExtendedAttributes';mask=16},@{name='WriteAttributes';mask=256},
        @{name='Delete';mask=0x10000},@{name='WriteDacl';mask=0x40000},@{name='WriteOwner';mask=0x80000})
    if ($Directory) { $requested+=@{name='DeleteChild';mask=0x40} }
    foreach ($right in $requested) {
        # Open the actual object for this right, without changing it. No probes
        # create/delete catalog fixtures or write authoritative protected bytes.
        $granted=Get-QNativeAccess $Path $Directory ([uint32]$right.mask)
        $expected=$Role -cne 'Runtime' -or ($Keys -and ($right.mask -band 0x1301bfL) -eq $right.mask)
        $rights+=@{right=$right.name;granted=$granted;expected=$expected;passed=($granted -eq $expected)}
    }
    return ,$rights
}
function Get-QRuntimeAccessEvidence($Configuration,$Layout) {
    # State/lock trees deliberately need not be listable/readable by runtime.
    # Structural inventory/owner/ACE verification belongs to the administrative
    # role reports. Here request actual rights on fixed, previously initialized
    # objects without requiring read-control or directory traversal inventories.
    $control=Get-QControlRoot $Configuration
    $resources=@(
        @{name='application';path=$Configuration.applicationRoot;directory=$true},
        @{name='control';path=$control;directory=$true},
        @{name='locks';path=$Layout.lockRoot;directory=$true},
        @{name='toolkit';path=$Layout.root;directory=$true},
        @{name='approvals';path=$Layout.approvalCatalogRoot;directory=$true},
        @{name='policy';path=$Layout.policyRoot;directory=$true},
        @{name='configuration';path=[IO.Path]::GetDirectoryName($Configuration.operationalConfigPath);directory=$true},
        @{name='keys';path=$Configuration.dataProtectionRoot;directory=$true},
        @{name='inbox';path=$Configuration.artifactInboxRoot;directory=$true},
        @{name='manifest';path=$Layout.manifestPath;directory=$false},
        @{name='policy-file';path=$Layout.policyPath;directory=$false},
        @{name='source';path=$Layout.sourcePath;directory=$false},
        @{name='configuration-file';path=$Configuration.operationalConfigPath;directory=$false},
        @{name='journal';path=(Join-Path $control 'journal.json');directory=$false},
        @{name='current';path=(Join-Path $control 'current.json');directory=$false},
        @{name='lock-file';path=(Join-Path $Layout.lockRoot ((Get-QTargetKey $Configuration)+'.lock'));directory=$false})
    foreach ($slot in @('initial','newer')) { $resources+=@{name=('approval-'+$slot);path=(Join-Path $Layout.approvalCatalogRoot ($Configuration.probeReleases[$slot].approvalId+'.json'));directory=$false} }
    # Binaries/toolkit/catalog/config are normally runtime-readable. Probe every
    # existing leaf so a file-specific write ACE cannot hide behind a safe root.
    $clock=[Diagnostics.Stopwatch]::StartNew(); $entries=0
    foreach ($root in @(@{name='application';path=$Configuration.applicationRoot},@{name='toolkit';path=$Layout.root},@{name='configuration';path=[IO.Path]::GetDirectoryName($Configuration.operationalConfigPath)})) {
        $queue=[Collections.Generic.Queue[string]]::new(); $queue.Enqueue($root.path)
        while ($queue.Count) {
            foreach ($path in [IO.Directory]::EnumerateFileSystemEntries($queue.Dequeue())) {
                $entries++; if ($entries -gt 20000 -or $clock.Elapsed.TotalSeconds -ge 300) { throw 'Runtime access inventory exceeded its bound.' }
                $directory=[IO.Directory]::Exists($path); $handles=[Collections.Generic.List[IDisposable]]::new()
                try { $null=Get-QAccessPathObservation $path $handles $directory } finally { foreach ($handle in $handles) { $handle.Dispose() } }
                $resources+=@{name=($root.name+'-leaf');path=$path;directory=$directory;relativePath=$path.Substring($root.path.Length)}
                if ($directory) { $queue.Enqueue($path) }
            }
        }
    }
    $observations=[Collections.Generic.List[object]]::new()
    foreach ($resource in $resources) {
        if ($clock.Elapsed.TotalSeconds -ge 300) { throw 'Runtime access probes exceeded their bound.' }
        Assert-DistLocalPath $resource.path
        $rights=Get-QAccessRights $resource.path $resource.directory Runtime ($resource.name -ceq 'keys')
        $parent=[IO.Path]::GetDirectoryName($resource.path)
        while ($parent) {
            foreach ($right in @(@{name='ParentDeleteChild';mask=0x40},@{name='ParentWriteDacl';mask=0x40000},@{name='ParentWriteOwner';mask=0x80000})) {
                $granted=Get-QNativeAccess $parent $true ([uint32]$right.mask)
                $rights+=@{right=$right.name;granted=$granted;expected=$false;passed=(-not $granted)}
            }
            $parent=[IO.Path]::GetDirectoryName($parent)
        }
        $observations.Add(@{resource=$resource.name;leafName=[IO.Path]::GetFileName($resource.path);relativePath=$(if ($resource.Contains('relativePath')) {$resource.relativePath} else {$null});rights=$rights;structuralProtectionVerified=$false;structuralEvidence='Requires independent administrative role report'})
    }
    return ,$observations
}

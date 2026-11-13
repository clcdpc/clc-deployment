# Narrow filesystem operations. Existing directories are verified, never reset.
function Assert-HPathSeparation($Session) {
    $paths=@($Session.target.applicationRoot,[IO.Path]::GetDirectoryName($Session.target.operationalConfigPath),$Session.target.dataProtectionRoot,$Session.target.artifactInboxRoot,
        $Session.layout.root,$Session.layout.controlStateRoot,$Session.layout.lockRoot,$Session.authorityRoot)
    if ($null -ne $Session.authorization.cutover) { $paths += $Session.authorization.cutover.backupRoot }
    for ($i=0;$i -lt $paths.Count;$i++) {
        Assert-ClcPathSpelling $paths[$i]
        for ($j=$i+1;$j -lt $paths.Count;$j++) {
            if ((Test-ClcPathAncestry $paths[$i] $paths[$j]) -or (Test-ClcPathAncestry $paths[$j] $paths[$i])) { Stop-ClcError Clc.UnsafePath }
        }
    }
    $physical=@($paths | ForEach-Object {Get-HProspectivePhysicalPath $_ $Session.handles})
    for ($i=0;$i -lt $physical.Count;$i++) {for ($j=$i+1;$j -lt $physical.Count;$j++) {
        if ((Test-ClcPathAncestry $physical[$i] $physical[$j]) -or (Test-ClcPathAncestry $physical[$j] $physical[$i])) {Stop-ClcError Clc.UnsafePath}
    }}
}
function Get-HProspectivePhysicalPath([string] $Path,$Handles) {
    Assert-ClcPathSpelling $Path;Assert-ClcProtectedPath $Path
    $cursor=$Path;$parts=[Collections.Generic.List[string]]::new()
    while (-not (Test-HExists $cursor)) {
        if ($parts.Count -ge 32) {Stop-ClcError Clc.UnsafePath}
        $parts.Insert(0,[IO.Path]::GetFileName($cursor));$cursor=[IO.Path]::GetDirectoryName($cursor)
        if (-not $cursor) {Stop-ClcError Clc.UnsafePath}
    }
    $facts=Get-ClcPathObservation $cursor $Handles -Directory -AllowVolumeRoot:($cursor.Length -eq 3)
    $physical=$facts.PhysicalPath
    foreach ($part in $parts) {$physical=Join-Path $physical $part}
    $physical
}
function Get-HBootstrapInventory {
    # Exact executable bootstrap dependencies, all from the independently
    # authenticated directory. Unknown files in these namespaces also change it.
    $files=[Collections.Generic.List[object]]::new();$count=0;$total=0L;$clock=[Diagnostics.Stopwatch]::StartNew()
    foreach ($root in @(@{path=$script:HModuleRoot;prefix='CLC.Deployment/'},@{path=$PSScriptRoot;prefix='tools/host/'})) {
        $queue=[Collections.Generic.Queue[string]]::new();$queue.Enqueue($root.path)
        while ($queue.Count) {
            foreach ($path in [IO.Directory]::EnumerateFileSystemEntries($queue.Dequeue())) {
                Assert-ClcDeadline $clock;$count++;if ($count -gt 20000) {Stop-ClcError Clc.EnrollmentBootstrapMismatch}
                $directory=([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::Directory) -ne 0
                $null=Get-DistPathFacts $path -Directory:$directory
                if ($directory) {$queue.Enqueue($path);continue}
                $length=([IO.FileInfo]$path).Length;$total += $length
                if ($length -gt 268435456 -or $total -gt 1073741824) {Stop-ClcError Clc.EnrollmentBootstrapMismatch}
                $name=$path.Substring($root.path.Length+1).Replace('\','/')
                $files.Add(@{path=$root.prefix+$name;length=[long]$length;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()})
            }
        }
    }
    foreach ($name in @('Distribution.Common.ps1','Test-ToolkitDistribution.ps1','Expand-ToolkitDistribution.ps1')) {
        $path=Join-Path $PSScriptRoot ('../'+$name)
        $files.Add(@{path='tools/'+$name;length=[long]([IO.FileInfo]$path).Length;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()})
    }
    Get-DistInventoryHash (Sort-DistFiles $files.ToArray())
}
function Get-HBootstrapSourceCommit {
    $path=Join-Path ([IO.Path]::GetDirectoryName($script:HModuleRoot)) 'source.commit'
    $bytes=Read-DistFileBytes $path 40
    $source=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)
    Assert-ClcCommit $source
    $source
}
function Assert-HNoPriorIntent($Session) {
    $root=Join-Path $Session.authorityRoot 'evidence'
    Assert-HAuthorityProtection $root $Session.handles -Directory
    $count=0; $clock=[Diagnostics.Stopwatch]::StartNew()
    foreach ($path in [IO.Directory]::EnumerateFileSystemEntries($root)) {
        Assert-ClcDeadline $clock; $count++
        if ($count -gt 20000 -or [IO.Path]::GetFileName($path) -cnotmatch '^[a-z0-9][a-z0-9-]{0,63}\.json$') { Stop-ClcError Clc.EnrollmentPriorEvidence }
        Assert-HAuthorityProtection $path $Session.handles
        $file=Read-ClcHeldFile $path $Session.handles
        $intent=Read-HJson $file.bytes
        Assert-ClcObject $intent @('contractFamily','schemaVersion','recordKind','authorizationId','authorizationSha256','deploymentConfigurationSha256','machineIdentity','targetKey','recordedUtc','operations','toolkit','originalPoolState','cutover')
        Assert-HHeader $intent host-enrollment-intent
        Assert-ClcId $intent.authorizationId;Assert-ClcHash $intent.authorizationSha256;Assert-ClcHash $intent.deploymentConfigurationSha256
        Assert-ClcGuid $intent.machineIdentity -Machine;Assert-ClcHash $intent.targetKey;Assert-ClcTimestamp $intent.recordedUtc
        Assert-ClcToolkit $intent.toolkit -Active;Assert-ClcEnum $intent.originalPoolState @('Unknown','Started','Stopped')
        if ($intent.authorizationId -cne [IO.Path]::GetFileNameWithoutExtension($path) -or $intent.operations -isnot [array] -or $intent.operations.Count -gt 6) {Stop-ClcError Clc.EnrollmentPriorEvidence}
        foreach ($operation in $intent.operations) {Assert-ClcEnum $operation @('install-toolkit','enroll-target','configure-iis','create-site','create-pool','first-cutover')}
        if ($intent.machineIdentity -ceq $Session.authorization.hostPolicy.machineIdentity -and
            ($intent.targetKey -ceq $Session.targetKey -or (-not (Test-HExists $Session.layout.policyPath) -and $intent.operations -ccontains 'install-toolkit'))) { Stop-ClcError Clc.EnrollmentPriorEvidence }
    }
}
function New-HPreflightContext($Session) {
    $bytes=[Text.Encoding]::UTF8.GetBytes(($Session.authorization.hostPolicy | ConvertTo-Json -Depth 16 -Compress))
    $stream=[IO.MemoryStream]::new($bytes,$false); $Session.handles.Add($stream)
    $root=$Session.configuration.enrollmentRoot
    while (-not [IO.Directory]::Exists($root)) { $root=[IO.Path]::GetDirectoryName($root); if (-not $root) { Stop-ClcError Clc.UnsafePath } }
    # Independent authorization pins this in-memory prospective policy. This
    # context permits protected prerequisite reads; it never imports a candidate.
    @{layout=@{root=$root};policyFile=@{record=$Session.authorization.hostPolicy;stream=$stream;sha256=(Get-ClcBytesHash $bytes)};
        handles=$Session.handles;pathPins=@{};ancestorPins=@{};pinGeneration=0L;
        helperRuntimeSids=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);
        closed=$false}
}
function Get-HResourceBinding([string] $Path,$Handles,[switch] $Directory) {
    $facts=Get-ClcPathObservation $Path $Handles -Directory:$Directory
    @{volumeId=$facts.VolumeId;fileId=$facts.FileId;canonicalPath=$facts.CanonicalPath;securityDescriptorSha256=(Get-ClcSecurityObservation $Path).sha256}
}
function Assert-HResourceAccess($Session,[string] $Path,[ValidateSet('Protected','Application','Mutable','Control','Keys','Configuration')][string] $Role) {
    $policy=$Session.authorization.hostPolicy; $infra=[string[]]$policy.infrastructureOwnerSids; $deploy=[string[]]$policy.deploymentSids; $runtime=$Session.target.runtimeIdentitySid
    switch ($Role) {
        Protected { $null=Assert-ClcAccess $Path $infra $infra $deploy @($runtime) }
        {$_ -cin @('Mutable','Control')} { $null=Assert-ClcAccess $Path ($infra+$deploy) ($infra+$deploy) $deploy @($runtime) -WriteMask 0x1301bf }
        Application {
            $null=Assert-ClcAccess $Path ($infra+$deploy) ($infra+$deploy) $deploy @($runtime) -WriteMask 0x1301bf
            $null=Assert-ClcAccess $Path ($infra+$deploy) ($infra+$deploy) @($runtime) @($runtime) -ReadMask 0x1200a9
        }
        Configuration { $null=Assert-ClcAccess $Path $infra $infra ($deploy+@($runtime)) @($runtime) }
        Keys {
            $null=Assert-ClcAccess $Path $infra ($infra+@($runtime)) ($deploy+@($runtime))
            $mask=Get-ClcEffectiveAccess (Get-ClcSecurityObservation $Path).bytes $runtime
            if (($mask -band 0x1301bf) -ne 0x1301bf -or ($mask -band 0x000C0000L) -ne 0) { Stop-ClcError Clc.HostPreflightFailed }
        }
    }
    $context=if ($null -ne $Session.context) {$Session.context} else {New-HPreflightContext $Session}
    Assert-ClcTrustAncestors $context $Path $runtime
}
function Assert-HInitialResources($Session) {
    $context=if ($null -ne $Session.context) {$Session.context} else {New-HPreflightContext $Session}
    Assert-ClcRuntimeIdentity $context $Session.target.runtimeIdentitySid
    $facts=[Collections.Generic.List[object]]::new()
    foreach ($name in @('applicationRoot','operationalConfigPath','dataProtectionRoot','artifactInboxRoot')) {
        $path=$Session.target[$name]; $binding=$Session.authorization.resourceBindings[$name]
        $exists=Test-HExists $path
        if ($exists -ne ($null -ne $binding)) { Stop-ClcError Clc.EnrollmentResourceMismatch }
        if ($exists) {
            $actual=Get-HResourceBinding $path $Session.handles -Directory:($name -cne 'operationalConfigPath')
            if (-not (Test-ClcValueEqual $actual $binding)) { Stop-ClcError Clc.EnrollmentResourceMismatch }
            $facts.Add((Get-ClcPathObservation $path $Session.handles -Directory:($name -cne 'operationalConfigPath')))
            $role=switch ($name) {applicationRoot {'Application'};operationalConfigPath {'Configuration'};dataProtectionRoot {'Keys'};artifactInboxRoot {'Mutable'}}
            Assert-HResourceAccess $Session $path $role
        } else {
            if ($name -ceq 'operationalConfigPath') { Stop-ClcError Clc.EnrollmentPrerequisiteMissing }
            $parent=[IO.Path]::GetDirectoryName($path)
            $null=Get-ClcPathObservation $parent $Session.handles -Directory
            Assert-HResourceAccess $Session $parent Protected
        }
    }
    # Hold external application configuration against byte/path substitution.
    $Session.operationalConfig=Read-ClcHeldFile $Session.target.operationalConfigPath $Session.handles
    Assert-HResourceAccess $Session ([IO.Path]::GetDirectoryName($Session.target.operationalConfigPath)) Configuration
    foreach ($name in @('dataProtectionRoot','artifactInboxRoot')) {
        if ([IO.Directory]::Exists($Session.target[$name])) {
            $role=if ($name -ceq 'dataProtectionRoot') {'Keys'} else {'Mutable'}
            Assert-ClcSafeDescendants $Session.target[$name] $context $Session.target.runtimeIdentitySid $role
        }
    }
    for ($i=0;$i -lt $facts.Count;$i++) { for ($j=$i+1;$j -lt $facts.Count;$j++) { Assert-ClcDisjoint $facts[$i] $facts[$j] } }
    if ([IO.Directory]::Exists($Session.target.applicationRoot)) {
        Assert-ClcSafeDescendants $Session.target.applicationRoot $context $Session.target.runtimeIdentitySid Mutable
        $inventory=Get-HLegacyInventory $Session.target.applicationRoot
        if ($inventory.files.Count -gt 0 -or $inventory.directories.Count -gt 0) {
            if ($null -eq $Session.authorization.cutover) { Stop-ClcError Clc.EnrollmentCutoverRequired }
            Assert-HCutoverInventory $Session $inventory
        } elseif ($null -ne $Session.authorization.cutover) { Stop-ClcError Clc.EnrollmentResourceMismatch }
    } elseif ($null -ne $Session.authorization.cutover) { Stop-ClcError Clc.EnrollmentResourceMismatch }
}
function Assert-HTargetCatalog($Session) {
    $context=$Session.context
    $allowed=@('host-policy.json','targets','approvals','activation-history')
    foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($Session.layout.policyRoot)) {
        if ([IO.Path]::GetFileName($entry) -cnotin $allowed) { Stop-ClcError Clc.EnrollmentConfigurationDrift }
        if ([IO.Path]::GetFileName($entry) -ceq 'activation-history') {Assert-ClcProtectedDependencyTree $context $entry $Session.target.runtimeIdentitySid}
    }
    $count=0
    foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($Session.layout.targetCatalogRoot)) {
        $count++; if ($count -gt 4096 -or [IO.Path]::GetFileName($entry) -cnotmatch '^([a-z0-9][a-z0-9-]{0,63})\.json$') { Stop-ClcError Clc.EnrollmentConfigurationDrift }
        $id=[IO.Path]::GetFileNameWithoutExtension($entry)
        $other=Read-ClcHeldRecord $entry target $Session.handles
        Assert-HResourceAccess $Session $entry Protected
        if ($other.record.targetId -cne $id) { Stop-ClcError Clc.EnrollmentConfigurationDrift }
        if ($id -ceq $Session.target.targetId) { continue }
        $target=$other.record
        if ($target.applicationPoolName -ieq $Session.target.applicationPoolName -or $target.siteName -ieq $Session.target.siteName -or $target.runtimeIdentitySid -ceq $Session.target.runtimeIdentitySid) { Stop-ClcError Clc.EnrollmentTargetCollision }
        foreach ($left in @($target.applicationRoot,[IO.Path]::GetDirectoryName($target.operationalConfigPath),$target.dataProtectionRoot,$target.artifactInboxRoot)) {
            $leftFacts=Get-ClcPathObservation $left $Session.handles -Directory
            foreach ($right in @($Session.target.applicationRoot,[IO.Path]::GetDirectoryName($Session.target.operationalConfigPath),$Session.target.dataProtectionRoot,$Session.target.artifactInboxRoot)) {
                if ((Test-ClcPathAncestry $left $right) -or (Test-ClcPathAncestry $right $left)) { Stop-ClcError Clc.EnrollmentTargetCollision }
                if (Test-HExists $right) {$rightPhysical=(Get-ClcPathObservation $right $Session.handles -Directory).PhysicalPath}
                else {$rightPhysical=Join-Path (Get-ClcPathObservation ([IO.Path]::GetDirectoryName($right)) $Session.handles -Directory).PhysicalPath ([IO.Path]::GetFileName($right))}
                if ((Test-ClcPathAncestry $leftFacts.PhysicalPath $rightPhysical) -or (Test-ClcPathAncestry $rightPhysical $leftFacts.PhysicalPath)) {Stop-ClcError Clc.EnrollmentTargetCollision}
            }
        }
    }
    $count=0
    foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($Session.layout.approvalCatalogRoot)) {
        $count++; if ($count -gt 20000 -or [IO.Path]::GetFileName($entry) -cnotmatch '^[a-z0-9][a-z0-9-]{0,63}\.json$') { Stop-ClcError Clc.EnrollmentConfigurationDrift }
        $approval=Read-ClcHeldRecord $entry release-approval $Session.handles
        Assert-HResourceAccess $Session $entry Protected
        if ($approval.record.approvalId -cne [IO.Path]::GetFileNameWithoutExtension($entry)) { Stop-ClcError Clc.EnrollmentConfigurationDrift }
        if ($approval.record.targetId -ceq $Session.target.targetId -and -not (Test-HExists (Join-Path $Session.layout.targetCatalogRoot ($Session.target.targetId+'.json')))) { Stop-ClcError Clc.EnrollmentPriorEvidence }
    }
}
function Open-HReadLock($Session,$TargetFile,$Identity) {
    $stream=$null
    try {
    if (Test-HExists $Identity.lockPath) {
        # Open-only: inspection never creates a lock, directory or state file.
        $stream=[IO.FileStream]::new($Identity.lockPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $facts=[Clc.Foundation.NativePaths]::Observe($stream.SafeFileHandle)
        [Clc.Foundation.NativePaths]::CheckStreams($Identity.lockPath)
        Assert-HResourceAccess $Session $Identity.lockPath Mutable
    } else {
        if (@([IO.Directory]::EnumerateFileSystemEntries($Identity.controlRoot)).Count -or @([IO.Directory]::EnumerateFileSystemEntries($Session.target.applicationRoot)).Count) { Stop-ClcError Clc.RecoveryRequired }
        return @{stream=$null;state=@{journal=$null;current=$null};closed=$false}
    }
    $lock=@{context=$Session.context;targetFile=$TargetFile;identity=$Identity;stream=$stream;lockFacts=$facts;ownerProcessId=$PID;closed=$false;state=$null}
    Assert-ClcLockOwned $lock; $lock.state=Read-ClcDeploymentState $lock; return $lock
    } catch {if ($null -ne $stream) {$stream.Dispose()};throw}
}
function Set-HNewResourceAcl($Session,[string] $Path,[string] $Role,[switch] $File) {
    $acl=if ($File) {[Security.AccessControl.FileSecurity]::new()} else {[Security.AccessControl.DirectorySecurity]::new()}
    $acl.SetAccessRuleProtection($true,$false)
    $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    $inherit=if ($File) {[Security.AccessControl.InheritanceFlags]::None} else {[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'}
    $infrastructureWriters=if ($Role -ceq 'Authority') {@('S-1-5-18','S-1-5-32-544')} else {$Session.authorization.hostPolicy.infrastructureOwnerSids}
    foreach ($sid in $infrastructureWriters) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl',$inherit,'None','Allow'))
    }
    if ($Role -cin @('Application','Mutable','Keys')) {
        foreach ($sid in $Session.authorization.hostPolicy.deploymentSids) {
            $rights=if ($Role -ceq 'Keys') {'ReadAndExecute'} else {'Modify'}
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),$rights,$inherit,'None','Allow'))
        }
    }
    if ($Role -cin @('Application','Keys')) {
        $rights=if ($Role -ceq 'Keys') {'Modify'} else {'ReadAndExecute'}
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($Session.target.runtimeIdentitySid),$rights,$inherit,'None','Allow'))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
}
function New-HDirectory($Session,[string] $Path,[string] $Role='Protected') {
    Assert-HSessionUnchanged $Session -Mutation
    Assert-ClcPathSpelling $Path
    if (Test-HExists $Path) { Stop-ClcError Clc.EnrollmentPartialInitialization }
    $null=Get-ClcPathObservation ([IO.Path]::GetDirectoryName($Path)) $Session.handles -Directory
    $null=New-Item -ItemType Directory -Path $Path -ErrorAction Stop
    Set-HNewResourceAcl $Session $Path $Role
    $null=Get-ClcPathObservation $Path $Session.handles -Directory
    Assert-HResourceAccess $Session $Path $Role
}
function Write-HNewRecord($Session,[string] $Path,$Record) {
    Assert-HSessionUnchanged $Session -Mutation
    $bytes=[Text.Encoding]::UTF8.GetBytes(($Record | ConvertTo-Json -Depth 32 -Compress)+"`n")
    $parent=[IO.Path]::GetDirectoryName($Path); $temporary=Join-Path $parent ('.clc-enrollment-'+[guid]::NewGuid().ToString('D')+'.tmp')
    $stream=$null
    try {
        $stream=[Clc.Foundation.NativePaths]::CreateOutput($temporary)
        $stream.Write($bytes); $stream.Flush($true)
        $facts=[Clc.Foundation.NativePaths]::Observe($stream.SafeFileHandle)
        $stream.Dispose(); $stream=$null
        $authorityRecord=Test-ClcPathAncestry $Session.authorityRoot $Path
        $role=if ($authorityRecord) {'Authority'} else {'Protected'}
        Set-HNewResourceAcl $Session $temporary $role -File
        $stream=[IO.File]::Open($temporary,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
        $observed=[Clc.Foundation.NativePaths]::Observe($stream.SafeFileHandle)
        if ($observed.VolumeId -cne $facts.VolumeId -or $observed.FileId -cne $facts.FileId -or (Read-ClcStream $stream 4194304 ([Diagnostics.Stopwatch]::StartNew())).sha256 -cne (Get-ClcBytesHash $bytes)) { Stop-ClcError Clc.EnrollmentVerificationFailed }
        Assert-HSessionUnchanged $Session -Mutation
        $stream.Dispose(); $stream=$null
        [IO.File]::Move($temporary,$Path,$false)
    } finally { if ($null -ne $stream) { $stream.Dispose() } }
    Assert-HResourceAccess $Session $Path Protected
    if ($authorityRecord) {Assert-HAuthorityProtection $Path $Session.handles}
    $file=Read-ClcHeldFile $Path $Session.handles
    if ($file.facts.VolumeId -cne $facts.VolumeId -or $file.facts.FileId -cne $facts.FileId -or $file.sha256 -cne (Get-ClcBytesHash $bytes)) { Stop-ClcError Clc.EnrollmentVerificationFailed }
    return $file
}
function Install-HToolkit($Session,[string] $DistributionPath) {
    Assert-HOperation $Session install-toolkit
    $pin=$Session.authorization.hostPolicy.activeToolkit
    $distribution=Read-ClcHeldFile $DistributionPath $Session.handles 1073741824 -NoCapture
    if ($distribution.sha256 -cne $pin.distributionSha256) { Stop-ClcError Clc.EnrollmentAuthorizationMismatch }
    $verified=& "$PSScriptRoot/../Test-ToolkitDistribution.ps1" -ArchivePath $DistributionPath -ExpectedSha256 $pin.distributionSha256 -ExpectedSourceCommit $pin.sourceCommit -ExpectedVersion $pin.version -RequireInfrastructureTools
    if ($verified.inventorySha256 -cne $pin.inventorySha256) { Stop-ClcError Clc.EnrollmentAuthorizationMismatch }
    if (-not (Test-HExists $Session.configuration.enrollmentRoot)) { New-HDirectory $Session $Session.configuration.enrollmentRoot }
    foreach ($path in @($Session.layout.root,(Join-Path $Session.layout.root 'versions'),$Session.layout.policyRoot,$Session.layout.targetCatalogRoot,$Session.layout.approvalCatalogRoot)) { New-HDirectory $Session $path }
    foreach ($path in @($Session.layout.controlStateRoot,$Session.layout.lockRoot)) { New-HDirectory $Session $path Control }
    $null=& "$PSScriptRoot/../Expand-ToolkitDistribution.ps1" -ArchivePath $DistributionPath -ExpectedSha256 $pin.distributionSha256 -ExpectedSourceCommit $pin.sourceCommit -ExpectedVersion $pin.version -VersionRoot $Session.layout.versionRoot -OperatorApprovalReference $Session.authorization.reference
    # Only our new immutable version is traversed. No historical tree ACL reset.
    Set-HNewResourceAcl $Session $Session.layout.versionRoot Protected
    $queue=[Collections.Generic.Queue[string]]::new(); $queue.Enqueue($Session.layout.versionRoot); $count=0; $clock=[Diagnostics.Stopwatch]::StartNew()
    while ($queue.Count) {
        foreach ($path in [IO.Directory]::EnumerateFileSystemEntries($queue.Dequeue())) {
            Assert-ClcDeadline $clock; $count++; if ($count -gt 20000) { Stop-ClcError Clc.EnrollmentVerificationFailed }
            $directory=([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::Directory) -ne 0
            Set-HNewResourceAcl $Session $path Protected -File:(-not $directory)
            if ($directory) { $queue.Enqueue($path) }
        }
    }
    $null=Write-HNewRecord $Session $Session.layout.policyPath $Session.authorization.hostPolicy
    Open-HInstalledContext $Session
}
function Invoke-HApply($Session,[string] $DistributionPath) {
    Assert-HOperation $Session enroll-target
    $lockPath=Join-Path $Session.authorityRoot 'host-enrollment.lock'
    $lockHandles=[Collections.Generic.List[IDisposable]]::new()
    try { Assert-HAuthorityProtection $lockPath $lockHandles; $lockFacts=Get-ClcPathObservation $lockPath $lockHandles }
    finally { foreach ($handle in $lockHandles) { $handle.Dispose() } }
    $Session.globalLock=[IO.FileStream]::new($lockPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $opened=[Clc.Foundation.NativePaths]::Observe($Session.globalLock.SafeFileHandle)
    if ($opened.VolumeId -cne $lockFacts.VolumeId -or $opened.FileId -cne $lockFacts.FileId -or $opened.LinkCount -ne 1 -or ($opened.Attributes -band 0x410) -ne 0) { Stop-ClcError Clc.UnsafePath }
    Assert-HAuthorityProtection (Join-Path $Session.authorityRoot 'evidence') $Session.handles -Directory
    Assert-HSessionUnchanged $Session -Mutation
    $state=Get-HEnrollmentState $Session
    if ($state.ReadyForDeployment) { return }
    if ($state.HostState -cnotin @('ToolkitNotInitialized','TargetNotEnrolled')) { Stop-ClcError Clc.EnrollmentReconciliationRequired }
    if ($state.HostState -ceq 'ToolkitNotInitialized') {
        Assert-HOperation $Session install-toolkit
        $pin=$Session.authorization.hostPolicy.activeToolkit
        $verified=& "$PSScriptRoot/../Test-ToolkitDistribution.ps1" -ArchivePath $DistributionPath -ExpectedSha256 $pin.distributionSha256 -ExpectedSourceCommit $pin.sourceCommit -ExpectedVersion $pin.version -RequireInfrastructureTools
        if ($verified.inventorySha256 -cne $pin.inventorySha256) { Stop-ClcError Clc.EnrollmentAuthorizationMismatch }
    }
    elseif (-not $Session.policyMatchesAuthorization) { Stop-ClcError Clc.EnrollmentPolicyAuthorizationMismatch }
    $plan=Get-HIisPlan $Session
    foreach ($operation in $plan.operations) { Assert-HOperation $Session $operation }
    if ($null -ne $Session.authorization.cutover) { Assert-HOperation $Session first-cutover; Assert-HCutoverStopped $Session }
    # One immutable infrastructure operation intent, consumed create-new before
    # provisioning. It is retained audit/recovery evidence, never readiness state.
    $evidencePath=Join-Path $Session.authorityRoot ('evidence\'+$Session.authorization.authorizationId+'.json')
    if (Test-HExists $evidencePath) { Stop-ClcError Clc.EnrollmentAuthorizationConsumed }
    $intent=@{contractFamily='clc-host-enrollment-v1';schemaVersion=1;recordKind='host-enrollment-intent';authorizationId=$Session.authorization.authorizationId;
        authorizationSha256=$Session.authorizationFile.sha256;deploymentConfigurationSha256=$Session.configurationFile.sha256;machineIdentity=$Session.authorization.hostPolicy.machineIdentity;
        targetKey=$Session.targetKey;recordedUtc=(Get-HNow).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ',[Globalization.CultureInfo]::InvariantCulture);operations=@($state.PlannedOperations);toolkit=$Session.authorization.hostPolicy.activeToolkit;
        originalPoolState=$Session.initialPoolState;cutover=$Session.authorization.cutover}
    $null=Write-HNewRecord $Session $evidencePath $intent
    $Session.performed=$true
    if ($state.HostState -ceq 'ToolkitNotInitialized') { Install-HToolkit $Session $DistributionPath }
    $lockPath=Join-Path $Session.layout.lockRoot ($Session.targetKey+'.lock')
    # A missing target must not adopt an orphan lock that appears after inspection.
    $Session.poolLock=[IO.FileStream]::new($lockPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $poolLockFacts=[Clc.Foundation.NativePaths]::Observe($Session.poolLock.SafeFileHandle)
    if ($poolLockFacts.LinkCount -ne 1 -or ($poolLockFacts.Attributes -band 0x410) -ne 0 -or -not $poolLockFacts.CanonicalPath.Equals($lockPath,[StringComparison]::OrdinalIgnoreCase)) { Stop-ClcError Clc.UnsafePath }
    [Clc.Foundation.NativePaths]::CheckStreams($lockPath)
    Assert-HResourceAccess $Session $lockPath Mutable
    if (Test-HExists $Session.controlRoot) { Stop-ClcError Clc.EnrollmentPriorEvidence }
    Assert-HTargetCatalog $Session
    Assert-HInitialResources $Session
    foreach ($pair in @(@('applicationRoot','Application'),@('artifactInboxRoot','Mutable'),@('dataProtectionRoot','Keys'))) {
        if (-not (Test-HExists $Session.target[$pair[0]])) { New-HDirectory $Session $Session.target[$pair[0]] $pair[1] }
    }
    Invoke-HIisApply $Session $plan
    if ($null -ne $Session.authorization.cutover) { Invoke-HCutover $Session }
    Assert-HIisReady $Session
    New-HDirectory $Session $Session.controlRoot Control
    $prospective=@{record=$Session.target;stream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes(($Session.target | ConvertTo-Json -Compress)))}
    $Session.handles.Add($prospective.stream); $prospective.sha256=Get-ClcBytesHash $prospective.stream.ToArray()
    $identity=Get-ClcTargetIdentity $Session.context $prospective
    $null=Get-ClcHostPreflight $Session.context $prospective $identity net10.0
    Assert-HActiveCompatibility $Session $prospective
    $Session.operationalConfig.stream.Position=0
    if ((Read-ClcStream $Session.operationalConfig.stream 4194304 ([Diagnostics.Stopwatch]::StartNew())).sha256 -cne $Session.operationalConfig.sha256) { Stop-ClcError Clc.EnrollmentResourceMismatch }
    if (@([IO.Directory]::EnumerateFileSystemEntries($Session.target.applicationRoot)).Count) { Stop-ClcError Clc.EnrollmentCutoverRequired }
    # Final enrollment publication. No application approval or deployment occurs.
    $null=Write-HNewRecord $Session (Join-Path $Session.layout.targetCatalogRoot ($Session.target.targetId+'.json')) $Session.target
    $Session.poolLock.Dispose(); $Session.poolLock=$null
}
function Get-HLegacyInventory([string] $Root) {
    $handles=[Collections.Generic.List[IDisposable]]::new(); $clock=[Diagnostics.Stopwatch]::StartNew()
    try {
        $rootFacts=Get-ClcPathObservation $Root $handles -Directory
        $files=[Collections.Generic.List[object]]::new(); $directories=[Collections.Generic.List[string]]::new(); $identities=@{}; $queue=[Collections.Generic.Queue[string]]::new(); $queue.Enqueue($Root); $count=0; $total=0L
        while ($queue.Count) {
            foreach ($path in [IO.Directory]::EnumerateFileSystemEntries($queue.Dequeue())) {
                Assert-ClcDeadline $clock; $count++; if ($count -gt 20000) { Stop-ClcError Clc.EnrollmentCutoverRequired }
                $relative=$path.Substring($Root.Length+1).Replace('\','/'); Assert-DistName $relative
                $directory=([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::Directory) -ne 0
                $identities[$relative]=Get-ClcPathObservation $path $handles -Directory:$directory
                if ($directory) { $directories.Add($relative); $queue.Enqueue($path) }
                else {
                    $file=Read-ClcHeldFile $path $handles 268435456 -NoCapture -Clock $clock; $total += $file.stream.Length
                    if ($total -gt 1073741824) { Stop-ClcError Clc.EnrollmentCutoverRequired }
                    $files.Add(@{path=$relative;length=$file.stream.Length;sha256=$file.sha256})
                }
            }
        }
        @{rootIdentity=(ConvertTo-ClcRootIdentity $rootFacts);files=(Sort-DistFiles $files.ToArray());directories=$directories.ToArray();identities=$identities}
    } finally { foreach ($handle in $handles) { $handle.Dispose() } }
}
function Assert-HCutoverInventory($Session,$Inventory) {
    $cutover=$Session.authorization.cutover
    if (-not (Test-ClcValueEqual $cutover.applicationRootIdentity $Inventory.rootIdentity) -or
        -not (Test-ClcValueEqual $cutover.files $Inventory.files) -or (Get-DistInventoryHash $Inventory.files) -cne $cutover.inventorySha256) { Stop-ClcError Clc.EnrollmentCutoverRequired }
    foreach ($directory in $Inventory.directories) {
        if (@($Inventory.files | Where-Object {$_.path.StartsWith($directory+'/',[StringComparison]::Ordinal)}).Count -eq 0) { Stop-ClcError Clc.EnrollmentCutoverRequired }
    }
    if (Test-HExists $cutover.backupRoot) { Stop-ClcError Clc.EnrollmentPartialInitialization }
    $parent=[IO.Path]::GetDirectoryName($cutover.backupRoot)
    $null=Get-ClcPathObservation $parent $Session.handles -Directory
    Assert-HResourceAccess $Session $parent Protected
}
function Invoke-HCutover($Session) {
    Assert-HOperation $Session first-cutover
    Assert-HCutoverStopped $Session
    $cutover=$Session.authorization.cutover; $original=Get-HLegacyInventory $Session.target.applicationRoot
    Assert-HCutoverInventory $Session $original
    New-HDirectory $Session $cutover.backupRoot
    $filesRoot=Join-Path $cutover.backupRoot 'original'; New-HDirectory $Session $filesRoot
    $clock=[Diagnostics.Stopwatch]::StartNew()
    foreach ($file in $original.files) {
        Assert-ClcDeadline $clock; Assert-HCutoverStopped $Session
        $destination=Join-Path $filesRoot $file.path.Replace('/','\'); $parent=[IO.Path]::GetDirectoryName($destination)
        $relative=$parent.Substring($filesRoot.Length).TrimStart('\'); $cursor=$filesRoot
        if ($relative) { foreach ($part in $relative.Split('\')) { $cursor=Join-Path $cursor $part; if (-not (Test-HExists $cursor)) { New-HDirectory $Session $cursor } } }
        $handles=[Collections.Generic.List[IDisposable]]::new()
        try {
            $source=Read-ClcHeldFile (Join-Path $Session.target.applicationRoot $file.path.Replace('/','\')) $handles $file.length -NoCapture -Clock $clock
            if ($source.sha256 -cne $file.sha256 -or $source.stream.Length -ne $file.length) { Stop-ClcError Clc.EnrollmentResourceMismatch }
            Assert-ClcFilePath ([IO.Path]::GetDirectoryName($destination)) -Directory
            $output=[IO.File]::Open($destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try {
                $copied=Read-ClcStream $source.stream $file.length $clock -Destination $output
                $output.Flush($true)
                if ($copied.length -ne $file.length -or $copied.sha256 -cne $file.sha256) { Stop-ClcError Clc.BackupInvalid }
            } finally { $output.Dispose() }
            Set-HNewResourceAcl $Session $destination Protected -File
        } finally { foreach ($handle in $handles) { $handle.Dispose() } }
    }
    $backup=Get-HLegacyInventory $filesRoot
    if (-not (Test-ClcValueEqual $backup.files $original.files)) { Stop-ClcError Clc.BackupInvalid }
    $null=Write-HNewRecord $Session (Join-Path $cutover.backupRoot 'backup-index.json') @{
        contractFamily='clc-host-enrollment-v1';schemaVersion=1;recordKind='legacy-cutover-backup';authorizationId=$Session.authorization.authorizationId;
        authorizationSha256=$Session.authorizationFile.sha256;originalRootIdentity=$original.rootIdentity;files=$original.files;inventorySha256=$cutover.inventorySha256;toolkitApprovedRelease=$false}
    # Recheck the full original and backup before the first destructive effect.
    $rechecked=Get-HLegacyInventory $Session.target.applicationRoot
    if (-not (Test-ClcValueEqual $rechecked.files $original.files) -or -not (Test-ClcValueEqual $rechecked.rootIdentity $original.rootIdentity)) { Stop-ClcError Clc.EnrollmentResourceMismatch }
    foreach ($file in $original.files) {
        Assert-HOperation $Session first-cutover; Assert-HCutoverStopped $Session; Assert-ClcDeadline $clock
        Assert-HCutoverRoot $Session
        $path=Join-Path $Session.target.applicationRoot $file.path.Replace('/','\')
        $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
        try {
            $facts=[Clc.Foundation.NativePaths]::Observe($stream.SafeFileHandle)
            $expected=$original.identities[$file.path]
            if ($facts.VolumeId -cne $expected.VolumeId -or $facts.FileId -cne $expected.FileId -or $facts.LinkCount -ne 1 -or ($facts.Attributes -band 0x410) -ne 0 -or -not $facts.CanonicalPath.Equals($path,[StringComparison]::OrdinalIgnoreCase)) { Stop-ClcError Clc.UnsafePath }
            $digest=Read-ClcStream $stream $file.length $clock
            if ($digest.length -ne $file.length -or $digest.sha256 -cne $file.sha256) { Stop-ClcError Clc.EnrollmentResourceMismatch }
            Assert-ClcNoNamedStreams $path
            $stream.Dispose(); $stream=$null
            Assert-ClcFilePath $path
            [IO.File]::Delete($path)
        } finally { if ($null -ne $stream) { $stream.Dispose() } }
    }
    foreach ($directory in @($original.directories | Sort-Object Length -Descending)) {
        Assert-HCutoverStopped $Session; Assert-ClcDeadline $clock
        Assert-HCutoverRoot $Session
        $path=Join-Path $Session.target.applicationRoot $directory.Replace('/','\')
        $handle=[Clc.Foundation.NativePaths]::Open($path)
        try {
            $facts=[Clc.Foundation.NativePaths]::Observe($handle)
            $expected=$original.identities[$directory]
            if ($facts.VolumeId -cne $expected.VolumeId -or $facts.FileId -cne $expected.FileId -or ($facts.Attributes -band 0x410) -ne 16 -or -not $facts.CanonicalPath.Equals($path,[StringComparison]::OrdinalIgnoreCase)) { Stop-ClcError Clc.UnsafePath }
            Assert-ClcNoNamedStreams $path
            $handle.Dispose(); $handle=$null
            Assert-ClcFilePath $path -Directory
            [IO.Directory]::Delete($path,$false)
        } finally { if ($null -ne $handle) { $handle.Dispose() } }
    }
    if (@([IO.Directory]::EnumerateFileSystemEntries($Session.target.applicationRoot)).Count -or -not (Test-ClcValueEqual (Get-HLegacyInventory $filesRoot).files $original.files)) { Stop-ClcError Clc.EnrollmentVerificationFailed }
    Assert-HCutoverStopped $Session
}
function Assert-HCutoverRoot($Session) {
    $handles=[Collections.Generic.List[IDisposable]]::new()
    try {
        $facts=Get-ClcPathObservation $Session.target.applicationRoot $handles -Directory
        if (-not (Test-ClcValueEqual (ConvertTo-ClcRootIdentity $facts) $Session.authorization.cutover.applicationRootIdentity)) { Stop-ClcError Clc.EnrollmentResourceMismatch }
    } finally { foreach ($handle in $handles) {$handle.Dispose()} }
}

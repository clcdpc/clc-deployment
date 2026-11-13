function Get-ClcPlatformObservation {
    $systems=@(Get-CimInstance -ClassName Win32_OperatingSystem -Property BuildNumber,ProductType -OperationTimeoutSec 10 -ErrorAction Stop)
    if ($systems.Count -ne 1) { Stop-ClcError Clc.HostPreflightFailed }
    return @{ build=[string]$systems[0].BuildNumber; productType=[long]$systems[0].ProductType;
        is64Bit=[Environment]::Is64BitProcess; powershellMajor=[long]$PSVersionTable.PSVersion.Major }
}

function Get-ClcFileX64 {
    param($Context, [string] $Path)
    $file=Read-ClcHeldFile $Path $Context.handles 268435456 -SystemFile -NoCapture
    $stream=$file.stream; $header=[byte[]]::new(64); $stream.ReadExactly($header)
    if ($header[0] -ne 0x4d -or $header[1] -ne 0x5a) { Stop-ClcError Clc.HostPreflightFailed }
    $offset=[BitConverter]::ToInt32($header,60)
    if ($offset -lt 64 -or $offset -gt $stream.Length-6) { Stop-ClcError Clc.HostPreflightFailed }
    $stream.Position=$offset; $pe=[byte[]]::new(6); $stream.ReadExactly($pe)
    return [BitConverter]::ToUInt32($pe,0) -eq 0x00004550 -and [BitConverter]::ToUInt16($pe,4) -eq 0x8664
}

function Invoke-ClcRuntimeReadQuery {
    param($Context)
    Assert-ClcHelperProtection $Context
    try { return [Clc.Host.Native]::Query($Context.policyFile.record.dotnetPath,'Runtimes',$null) }
    catch { Stop-ClcError Clc.HostPreflightFailed }
}

function Get-ClcRuntimeObservation {
    param($Context, [string] $AncmPath, [string] $RuntimeSid)
    Assert-ClcHelperDependencies $Context $RuntimeSid
    $null=Add-ClcProtectedPathPin $Context $AncmPath -SystemFile -RuntimeSid $RuntimeSid
    $null=Add-ClcProtectedPathPin $Context ([IO.Path]::GetDirectoryName($AncmPath)) -Directory -SystemDirectory -RuntimeSid $RuntimeSid
    try {
        $dotnetX64=Get-ClcFileX64 $Context $Context.policyFile.record.dotnetPath
        $ancmX64=Get-ClcFileX64 $Context $AncmPath
        if (-not $dotnetX64 -or -not $ancmX64) { Stop-ClcError Clc.HostPreflightFailed }
        $bytes=Invoke-ClcRuntimeReadQuery $Context
        $text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)
        $frameworks=[Collections.Generic.List[object]]::new()
        foreach ($line in ($text -split '\r?\n')) {
            if (-not $line) { continue }
            if ($line -cnotmatch '^(Microsoft\.(NETCore|AspNetCore)\.App) ([0-9]+\.[0-9]+\.[0-9]+) \[([^\x00-\x1f]+)\]$') { Stop-ClcError Clc.HostPreflightFailed }
            $frameworks.Add(@{name=$Matches[1];version=$Matches[3]})
        }
        $version=[Diagnostics.FileVersionInfo]::GetVersionInfo($AncmPath).FileMajorPart
        Assert-ClcTrustedContextUnchanged $Context
        return @{ frameworks=$frameworks.ToArray(); ancmMajor=[long]$version; ancmX64=$ancmX64; dotnetX64=$dotnetX64 }
    } catch { Stop-ClcError Clc.HostPreflightFailed }
}

function Assert-ClcStableIisObservation {
    param($Target, $Iis, [string] $NormalizedPool)
    Assert-ClcIisTargetBinding $Target $Iis $NormalizedPool
    if ($Iis.siteState -cne 'Started' -or $Iis.poolState -cnotin @('Started','Stopped') -or $Iis.maxProcesses -ne 1 -or
        -not $Iis.disallowOverlappingRotation -or $Iis.enable32Bit -or $Iis.runtimeSid -cne $Target.runtimeIdentitySid -or
        ($Iis.poolState -ceq 'Stopped' -and $Iis.workers.Count -ne 0) -or $Iis.workers.Count -gt 1) { Stop-ClcError Clc.HostPreflightFailed }
    foreach ($pidValue in $Iis.workers) { Assert-ClcInteger $pidValue 1 4294967295 }
}

# The mutable IIS facts relevant to file effects are independently bound from
# runtime discovery. Pool state/workers remain fresh, separate observations.
function Get-ClcIisConfigurationHash {
    param($Iis)
    $value=[ordered]@{}
    foreach ($name in @('siteName','siteState','poolName','runtimeSid','maxProcesses','disallowOverlappingRotation','enable32Bit','ancmPath')) { $value[$name]=$Iis[$name] }
    $value.applications=@($Iis.applications | Sort-Object siteName,path,poolName,physicalPath -CaseSensitive -Culture '' | ForEach-Object {
        [ordered]@{siteName=$_.siteName;path=$_.path;poolName=$_.poolName;physicalPath=$_.physicalPath}
    })
    $value.bindings=@($Iis.bindings | Sort-Object protocol,host,port,address -CaseSensitive -Culture '' | ForEach-Object {
        [ordered]@{protocol=$_.protocol;host=$_.host;port=$_.port;address=$_.address}
    })
    $value.environment=@($Iis.environment | Sort-Object scope,name -CaseSensitive -Culture '' | ForEach-Object {
        [ordered]@{scope=$_.scope;name=$_.name;value=$_.value}
    })
    return Get-ClcBytesHash ([Text.Encoding]::UTF8.GetBytes(($value | ConvertTo-Json -Depth 16 -Compress)))
}

function Assert-ClcSafeDescendants {
    param([string] $Root, $Context=$null, [string] $RuntimeSid, [ValidateSet('Mutable','Configuration','Keys')][string] $AccessRole='Mutable', [string] $OwnedTemporary,
        [Diagnostics.Stopwatch] $Clock=$null, [int] $DeadlineSeconds=300)
    if ($null -eq $Clock) { $Clock=[Diagnostics.Stopwatch]::StartNew() }
    $directoryHandles=[Collections.Generic.List[IDisposable]]::new()
    try {
    $rootFacts=Get-ClcPathObservation $Root $directoryHandles -Directory
    $queue=[Collections.Generic.Queue[object]]::new(); $queue.Enqueue($rootFacts)
    $count=0
    while ($queue.Count -gt 0) {
        $parent=$queue.Dequeue()
        foreach ($path in [IO.Directory]::EnumerateFileSystemEntries($parent.CanonicalPath)) {
            Assert-ClcDeadline $Clock $DeadlineSeconds; $count++; if ($count -gt 20000) { Stop-ClcError Clc.UnsafePath }
            $directory=([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::Directory) -ne 0
            $handles=[Collections.Generic.List[IDisposable]]::new()
            try {
                $facts=Get-ClcChildPathObservation $path $parent $handles -Directory:$directory -Temporary:($path -ceq $OwnedTemporary)
            if ($null -ne $Context) {
                Assert-ClcPathAccess $Context $path $RuntimeSid $AccessRole
            }
                if ($directory) { $queue.Enqueue($facts); foreach ($handle in $handles) { $directoryHandles.Add($handle) }; $handles.Clear() }
            } finally { foreach ($handle in $handles) { $handle.Dispose() } }
        }
    }
    Assert-ClcDeadline $Clock $DeadlineSeconds
    } finally { foreach ($handle in $directoryHandles) { $handle.Dispose() } }
}

function Assert-ClcPathAccess {
    param($Context, [string] $Path, [string] $RuntimeSid,
        [ValidateSet('Mutable','Configuration','Keys')][string] $AccessRole='Mutable')
    $null=Get-ClcPathAccessHash $Context $Path $RuntimeSid $AccessRole
}

function Get-ClcPathAccessHash {
    param($Context, [string] $Path, [string] $RuntimeSid,
        [ValidateSet('Mutable','Configuration','Keys')][string] $AccessRole='Mutable')
    $infra=[string[]]$Context.policyFile.record.infrastructureOwnerSids; $deploy=[string[]]$Context.policyFile.record.deploymentSids
    switch ($AccessRole) {
        Mutable { return Assert-ClcAccess $Path ($infra+$deploy) ($infra+$deploy) $deploy @($RuntimeSid) }
        Configuration { return Assert-ClcAccess $Path $infra $infra ($deploy+@($RuntimeSid)) @($RuntimeSid) }
        Keys { return Assert-ClcAccess $Path ($infra+@($RuntimeSid)) ($infra+@($RuntimeSid)) $deploy }
    }
}

# Validate only the selected path's short, canonical control ancestry. Callers
# separately check the leaf bytes/ACL and, for a selected tree, each descendant.
# This deliberately never enumerates sibling attempts, stages, backups or ZIPs.
function Assert-ClcControlAncestorAccess {
    param($Context, [string] $ControlRoot, [string] $Path, [string] $RuntimeSid,
        [Collections.Generic.List[IDisposable]] $Handles=$null, [Diagnostics.Stopwatch] $Clock=$null, [int] $DeadlineSeconds=300)
    if (-not (Test-ClcPathAncestry $ControlRoot $Path)) { Stop-ClcError Clc.UnsafePath }
    if ($null -eq $Clock) { $Clock=[Diagnostics.Stopwatch]::StartNew() }
    $ownedHandles=$null -eq $Handles
    if ($ownedHandles) { $Handles=[Collections.Generic.List[IDisposable]]::new() }
    try {
        Assert-ClcDeadline $Clock $DeadlineSeconds
        $current=$ControlRoot
        $null=Get-ClcPathObservation $current $Handles -Directory
        Assert-ClcPathAccess $Context $current $RuntimeSid Mutable
        Assert-ClcDeadline $Clock $DeadlineSeconds
        if ($Path.Equals($ControlRoot,[StringComparison]::OrdinalIgnoreCase)) { return }
        $relative=$Path.Substring($ControlRoot.Length).TrimStart('\')
        $parts=$relative.Split('\')
        for ($i=0;$i -lt $parts.Count-1;$i++) {
            Assert-ClcDeadline $Clock $DeadlineSeconds
            $current=Join-Path $current $parts[$i]
            $null=Get-ClcPathObservation $current $Handles -Directory
            Assert-ClcPathAccess $Context $current $RuntimeSid Mutable
        }
        Assert-ClcDeadline $Clock $DeadlineSeconds
    } finally { if ($ownedHandles) { foreach ($handle in $Handles) { $handle.Dispose() } } }
}

# Keep canonical control-state admission bounded even when ordinary retained
# history is large. Exact historical evidence is verified by its reader; only
# these six direct children define the state namespace's boundary.
function Assert-ClcControlRootBoundary {
    param($Context, $Identity, [string] $RuntimeSid, [Diagnostics.Stopwatch] $Clock=$null, [int] $DeadlineSeconds=300)
    if ($null -eq $Clock) { $Clock=[Diagnostics.Stopwatch]::StartNew() }
    $handles=[Collections.Generic.List[IDisposable]]::new()
    try {
        Assert-ClcDeadline $Clock $DeadlineSeconds
        $root=$Identity.controlRoot
        $facts=Get-ClcPathObservation $root $handles -Directory
        if ($facts.VolumeId -cne $Identity.facts.controlRoot.VolumeId -or $facts.FileId -cne $Identity.facts.controlRoot.FileId) { Stop-ClcError Clc.UnsafePath }
        Assert-ClcPathAccess $Context $root $RuntimeSid Mutable
        if (-not $Identity.ContainsKey('controlContainerFacts')) {
            $Identity.controlContainerFacts=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
        }
        if (-not $Identity.ContainsKey('controlContainerHandles')) {
            $Identity.controlContainerHandles=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
        }
        if (-not $Identity.ContainsKey('controlContainerBoundaryInitialized')) { $Identity.controlContainerBoundaryInitialized=$false }
        $allowed=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($name in @('journal.json','current.json','staging','backups','releases','attempts')) { $null=$allowed.Add($name) }
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($root)) {
            Assert-ClcDeadline $Clock $DeadlineSeconds
            if ($seen.Count -ge 6) { Stop-ClcError Clc.UnsafePath }
            $name=[IO.Path]::GetFileName($entry)
            if (-not $allowed.Contains($name) -or -not $seen.Add($name)) { Stop-ClcError Clc.UnsafePath }
            $directory=$name -iin @('staging','backups','releases','attempts')
            if ($directory) {
                # Hold each observed fixed container with LIST_DIRECTORY access
                # and no write/delete sharing so it cannot be renamed away.
                $entryHandles=[Collections.Generic.List[IDisposable]]::new()
                try {
                    $entryFacts=Get-ClcPathObservation $entry $entryHandles -Directory -PinnedDirectory
                    if ([IO.Path]::GetDirectoryName($entryFacts.CanonicalPath) -cne $root) { Stop-ClcError Clc.UnsafePath }
                    $aclHash=Get-ClcPathAccessHash $Context $entry $RuntimeSid Mutable
                    if ($Identity.controlContainerFacts.ContainsKey($name)) {
                        $prior=$Identity.controlContainerFacts[$name]
                        if ($prior.volumeId -cne $entryFacts.VolumeId -or $prior.fileId -cne $entryFacts.FileId -or
                            $prior.physicalPath -cne $entryFacts.PhysicalPath -or $prior.aclSha256 -cne $aclHash) { Stop-ClcError Clc.UnsafePath }
                        $held=$Identity.controlContainerHandles[$name]
                        if ($null -eq $held -or $held.IsClosed) { Stop-ClcError Clc.UnsafePath }
                        $heldFacts=[Clc.Foundation.NativePaths]::Observe($held)
                        if ($heldFacts.VolumeId -cne $entryFacts.VolumeId -or $heldFacts.FileId -cne $entryFacts.FileId -or
                            $heldFacts.PhysicalPath -cne $entryFacts.PhysicalPath) { Stop-ClcError Clc.UnsafePath }
                    } else {
                        $Identity.controlContainerFacts.Add($name,@{volumeId=$entryFacts.VolumeId;fileId=$entryFacts.FileId;
                            physicalPath=$entryFacts.PhysicalPath;aclSha256=$aclHash})
                        $leaf=$entryHandles[$entryHandles.Count-1]
                        for ($i=0;$i -lt $entryHandles.Count-1;$i++) { $entryHandles[$i].Dispose() }
                        $entryHandles.Clear(); $entryHandles.Add($leaf)
                        $Context.handles.Add($leaf)
                        $Identity.controlContainerHandles.Add($name,$leaf)
                        $entryHandles.Clear()
                    }
                    if ($Identity.controlContainerFacts.ContainsKey($name)) {
                        Assert-ClcPathAccess $Context $entry $RuntimeSid Mutable
                    }
                } finally { foreach ($handle in $entryHandles) { $handle.Dispose() } }
            } else {
                $entryFacts=Get-ClcPathObservation $entry $handles
                if ([IO.Path]::GetDirectoryName($entryFacts.CanonicalPath) -cne $root) { Stop-ClcError Clc.UnsafePath }
                Assert-ClcPathAccess $Context $entry $RuntimeSid Mutable
            }
        }
        # A container absent on the first boundary is optional. Once observed,
        # however, it remains part of this invocation's namespace and may not
        # disappear while later phases continue to rely on the same control root.
        if ($Identity.controlContainerBoundaryInitialized) {
            foreach ($name in $Identity.controlContainerFacts.Keys) {
                if (-not $seen.Contains($name)) { Stop-ClcError Clc.UnsafePath }
            }
        } else { $Identity.controlContainerBoundaryInitialized=$true }
        Assert-ClcDeadline $Clock $DeadlineSeconds
    } finally { foreach ($handle in $handles) { $handle.Dispose() } }
}

function Assert-ClcHostAccess {
    param($Context, $Target, $Identity, [Diagnostics.Stopwatch] $Clock=$null, [int] $DeadlineSeconds=300)
    if ($null -eq $Clock) { $Clock=[Diagnostics.Stopwatch]::StartNew() }
    $policy=$Context.policyFile.record; $runtime=$Target.runtimeIdentitySid
    Assert-ClcRuntimeIdentity $Context $runtime
    $infra=[string[]]$policy.infrastructureOwnerSids; $deploy=[string[]]$policy.deploymentSids
    foreach ($path in @($Context.layout.root,$Context.layout.policyRoot,$policy.targetCatalogRoot,$policy.approvalCatalogRoot,$Context.layout.policyPath)) {
        Assert-ClcDeadline $Clock $DeadlineSeconds
        $null=Assert-ClcAccess $path $infra $infra $deploy @($runtime)
    }
    foreach ($path in @($Target.applicationRoot,$Target.artifactInboxRoot,$policy.lockRoot,$policy.controlStateRoot,$Identity.controlRoot)) {
        Assert-ClcDeadline $Clock $DeadlineSeconds
        $null=Assert-ClcAccess $path ($infra+$deploy) ($infra+$deploy) $deploy @($runtime) -WriteMask 0x1301bf
    }
    $null=Assert-ClcAccess $Target.applicationRoot ($infra+$deploy) ($infra+$deploy) @($runtime) @($runtime) -ReadMask 0x1200a9
    foreach ($path in @($Target.operationalConfigPath,[IO.Path]::GetDirectoryName($Target.operationalConfigPath))) {
        Assert-ClcDeadline $Clock $DeadlineSeconds
        $null=Assert-ClcAccess $path $infra $infra ($deploy+@($runtime)) @($runtime)
    }
    $null=Assert-ClcAccess $Target.dataProtectionRoot $infra ($infra+@($runtime)) ($deploy+@($runtime))
    $keyAccess=Get-ClcEffectiveAccess (Get-ClcSecurityObservation $Target.dataProtectionRoot).bytes $runtime
    if (($keyAccess -band 0x1301bf) -ne 0x1301bf -or ($keyAccess -band 0x000C0000L) -ne 0) { Stop-ClcError Clc.HostPreflightFailed }
    # Parent delete-child/DACL/owner access must not let runtime replace protected roots.
    foreach ($root in @($Context.layout.root,$Target.applicationRoot,$Target.operationalConfigPath,$Target.dataProtectionRoot,$policy.controlStateRoot,$policy.lockRoot,$Target.artifactInboxRoot)) {
        $parent=[IO.Path]::GetDirectoryName($root)
        while ($parent) {
            Assert-ClcDeadline $Clock $DeadlineSeconds
            $security=Get-ClcSecurityObservation $parent
            if ($security.ownerSid -ceq $runtime -or ((Get-ClcEffectiveAccess $security.bytes $runtime) -band 0x000D0040) -ne 0) { Stop-ClcError Clc.HostPreflightFailed }
            $parent=[IO.Path]::GetDirectoryName($parent)
        }
    }
    Assert-ClcDeadline $Clock $DeadlineSeconds
}

function Get-ClcHostPreflight {
    param($Context, $TargetFile, $Identity, [string] $Framework,
        [Diagnostics.Stopwatch] $Clock=$null, [int] $DeadlineSeconds=300)
    if ($null -eq $Clock) { $Clock=[Diagnostics.Stopwatch]::StartNew() }
    try {
        Assert-ClcDeadline $Clock $DeadlineSeconds
        Assert-ClcHeldRecordUnchanged $Context $TargetFile 'Clc.HostPreflightFailed'
        $target=$TargetFile.record; $iis=Get-ClcIisObservation $Context $target
        Assert-ClcIisTargetBinding $target $iis $Identity.snapshot.applicationPoolName
        if ((Get-ClcMachineIdentity $Context.policyFile.record.machineIdentity) -cne $Identity.snapshot.machineIdentity -or
            (Get-ClcCanonicalPoolName $target.applicationPoolName (Get-ClcIisPoolNames $Context)) -cne $Identity.snapshot.applicationPoolName) { Stop-ClcError Clc.HostPreflightFailed }
        $platform=Get-ClcPlatformObservation
        Assert-ClcDeadline $Clock $DeadlineSeconds
        if ($platform.build -cne '20348' -or $platform.productType -notin @(2,3) -or -not $platform.is64Bit -or $platform.powershellMajor -ne 7) { Stop-ClcError Clc.HostPreflightFailed }
        Assert-ClcStableIisObservation $target $iis $Identity.snapshot.applicationPoolName
        $uri=[Uri]$target.readinessUri
        $bindings=@($iis.bindings | Where-Object { $_.protocol -ceq 'https' -and $_.port -eq $uri.Port -and
            (([string]::Equals($_.host,$uri.DnsSafeHost,[StringComparison]::OrdinalIgnoreCase)) -or ($_.host -ceq '' -and $_.address -ceq $uri.Host)) })
        if ($bindings.Count -ne 1) { Stop-ClcError Clc.HostPreflightFailed }
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase); $selectors=0
        foreach ($variable in $iis.environment) {
            if (-not $seen.Add($variable.scope+':'+$variable.name)) { Stop-ClcError Clc.HostPreflightFailed }
            if ($variable.name -iin @('DOTNET_ENVIRONMENT','ASPNETCORE_ENVIRONMENT')) {
                $selectors++; if ($variable.value -cne $target.runtimeEnvironment) { Stop-ClcError Clc.HostPreflightFailed }
            } elseif ($variable.name -imatch '^(DOTNET_|ASPNETCORE_|COMPlus_|CORECLR_)') { Stop-ClcError Clc.HostPreflightFailed }
        }
        if ($selectors -eq 0 -and $target.runtimeEnvironment -cne 'Production') { Stop-ClcError Clc.HostPreflightFailed }
        $runtime=Get-ClcRuntimeObservation $Context $iis.ancmPath $target.runtimeIdentitySid
        Assert-ClcDeadline $Clock $DeadlineSeconds
        # V1's first supported framework line; patch qualification remains T4 infrastructure work.
        if ($Framework -cne 'net10.0' -or -not $runtime.dotnetX64 -or -not $runtime.ancmX64 -or $runtime.ancmMajor -ne 20) { Stop-ClcError Clc.HostPreflightFailed }
        foreach ($name in @('Microsoft.NETCore.App','Microsoft.AspNetCore.App')) {
            if (@($runtime.frameworks | Where-Object { $_.name -ceq $name -and $_.version -cmatch '^10\.0\.[0-9]+$' }).Count -lt 1) { Stop-ClcError Clc.HostPreflightFailed }
        }
        Assert-ClcSafeDescendants $target.applicationRoot $Context $target.runtimeIdentitySid Mutable $null $Clock $DeadlineSeconds
        Assert-ClcSafeDescendants $target.artifactInboxRoot $Context $target.runtimeIdentitySid Mutable $null $Clock $DeadlineSeconds
        Assert-ClcControlRootBoundary $Context $Identity $target.runtimeIdentitySid $Clock $DeadlineSeconds
        Assert-ClcSafeDescendants ([IO.Path]::GetDirectoryName($target.operationalConfigPath)) $Context $target.runtimeIdentitySid Configuration $null $Clock $DeadlineSeconds
        Assert-ClcSafeDescendants $target.dataProtectionRoot $Context $target.runtimeIdentitySid Keys $null $Clock $DeadlineSeconds
        Assert-ClcHostAccess $Context $target $Identity $Clock $DeadlineSeconds
        Assert-ClcTrustedContextUnchanged $Context
        Assert-ClcDeadline $Clock $DeadlineSeconds
        # Configuration identity only. Pool state and workers are checked live and
        # returned separately; startup, idle timeout and demand must not change this digest.
        $observation=[ordered]@{ targetKey=$Identity.targetKey; targetSnapshot=$Identity.snapshot;
            runtimeIdentitySid=$iis.runtimeSid; runtimeEnvironment=$target.runtimeEnvironment; readinessUri=$target.readinessUri;
            maxProcesses=$iis.maxProcesses; disallowOverlappingRotation=$iis.disallowOverlappingRotation; enable32Bit=$iis.enable32Bit;
            framework=$Framework; ancmPath=$iis.ancmPath; ancmMajor=$runtime.ancmMajor;
            frameworks=@($runtime.frameworks | Sort-Object name,version -CaseSensitive -Culture '' | ForEach-Object {
                [ordered]@{name=$_.name;version=$_.version}
            });
            bindings=@($iis.bindings | Sort-Object protocol,host,port,address -CaseSensitive -Culture '' | ForEach-Object {
                [ordered]@{protocol=$_.protocol;host=$_.host;port=$_.port;address=$_.address}
            });
            environment=@($iis.environment | Sort-Object scope,name -CaseSensitive -Culture '' | ForEach-Object {
                [ordered]@{scope=$_.scope;name=$_.name;value=$_.value}
            }) }
        return @{ poolState=$iis.poolState; workerCount=[long]$iis.workers.Count; iisConfigurationSha256=(Get-ClcIisConfigurationHash $iis);
            hostObservationSha256=(Get-ClcBytesHash ([Text.Encoding]::UTF8.GetBytes(($observation | ConvertTo-Json -Depth 16 -Compress)))); qualified=$false }
    } catch {
        if ($_.FullyQualifiedErrorId -like 'Clc.UnsafePath*') { throw }
        Stop-ClcError Clc.HostPreflightFailed
    }
}

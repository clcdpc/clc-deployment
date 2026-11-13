# The independent infrastructure installation authenticates the FIRST import.
# These checks reject drift in already installed code; they cannot authenticate themselves.
function Get-ClcInstalledLayout {
    $moduleRoot = $ExecutionContext.SessionState.Module.ModuleBase
    $versionRoot = [IO.Path]::GetDirectoryName($moduleRoot)
    $versionsRoot = [IO.Path]::GetDirectoryName($versionRoot)
    if ([IO.Path]::GetFileName($moduleRoot) -cne 'CLC.Deployment' -or
        [IO.Path]::GetFileName($versionRoot) -cne (Get-ClcToolkitVersion) -or
        [IO.Path]::GetFileName($versionsRoot) -cne 'versions') { Stop-ClcError Clc.ToolkitNotActive }
    $root = [IO.Path]::GetDirectoryName($versionsRoot)
    return @{ root=$root; moduleRoot=$moduleRoot; versionRoot=$versionRoot;
        manifestPath=(Join-Path $moduleRoot 'CLC.Deployment.psd1');
        policyRoot=(Join-Path $root 'policy'); policyPath=(Join-Path $root 'policy\host-policy.json');
        targetCatalogRoot=(Join-Path $root 'policy\targets'); approvalCatalogRoot=(Join-Path $root 'policy\approvals');
        sourcePath=(Join-Path $versionRoot 'source.commit'); distributionPath=(Join-Path $versionRoot 'distribution.zip');
        controlStateRoot=(Join-Path ([IO.Path]::GetDirectoryName($root)) 'control'); lockRoot=(Join-Path ([IO.Path]::GetDirectoryName($root)) 'locks') }
}

function Get-ClcCallerSid {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { return $identity.User.Value } finally { $identity.Dispose() }
}

function Test-ClcAdministratorToken {
    # IsInRole tests the enabled role in THIS token. A deny-only Administrators
    # SID in a UAC-filtered token is not admission. Never attempt self-elevation.
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { return [Security.Principal.WindowsPrincipal]::new($identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
    finally { $identity.Dispose() }
}

function Assert-ClcDeploymentToken {
    param($Policy)
    if ($Policy.deploymentSids -cnotcontains (Get-ClcCallerSid) -or
        @($Policy.infrastructureOwnerSids | Where-Object { $Policy.deploymentSids -ccontains $_ }).Count -ne 0 -or
        -not (Test-ClcAdministratorToken)) { Stop-ClcError Clc.HostPreflightFailed }
}

function Get-ClcProtectedDeniedWriters {
    param($Context, [string] $RuntimeSid)
    Assert-ClcDeploymentToken $Context.policyFile.record
    # Only the admitted current caller is exempt from effective write isolation.
    # Assert-ClcAccess still rejects its direct write ACEs and ownership on
    # infrastructure resources. Other deployment SIDs and runtime stay denied.
    $caller=Get-ClcCallerSid
    $denied=@($Context.policyFile.record.deploymentSids | Where-Object { $_ -cne $caller })
    if ($RuntimeSid) { $denied += $RuntimeSid }
    return ,([string[]]$denied)
}

function Assert-ClcRuntimeIdentity {
    param($Context, [string] $RuntimeSid)
    $policy=$Context.policyFile.record
    $privileged=[string[]]@($policy.infrastructureOwnerSids+$policy.deploymentSids+@('S-1-5-32-544','S-1-5-18'))
    if (-not $RuntimeSid -or $privileged -ccontains $RuntimeSid) { Stop-ClcError Clc.HostPreflightFailed }
    # S4U-backed Authz expands group membership, including indirect membership.
    # A synthetic descriptor tests authority even when real resources deny it.
    $aces=($privileged | Select-Object -Unique | ForEach-Object { '(A;;0x1;;;'+$_+')' }) -join ''
    $descriptor=[Security.AccessControl.RawSecurityDescriptor]::new(('O:SYG:SYD:'+ $aces))
    $bytes=[byte[]]::new($descriptor.BinaryLength); $descriptor.GetBinaryForm($bytes,0)
    if ((Get-ClcEffectiveAccess $bytes $RuntimeSid) -ne 0) { Stop-ClcError Clc.HostPreflightFailed }
}

function Get-ClcSecurityObservation {
    param([string] $Path)
    try {
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        $bytes = $acl.GetSecurityDescriptorBinaryForm()
        $raw = [Security.AccessControl.RawSecurityDescriptor]::new($bytes,0)
        if ($null -eq $raw.DiscretionaryAcl -or -not $acl.AreAccessRulesCanonical) { Stop-ClcError Clc.HostPreflightFailed }
        foreach ($ace in $raw.DiscretionaryAcl) {
            if ($ace -isnot [Security.AccessControl.CommonAce] -or $ace.IsCallback -or
                $ace.AceQualifier -notin @([Security.AccessControl.AceQualifier]::AccessAllowed,[Security.AccessControl.AceQualifier]::AccessDenied)) { Stop-ClcError Clc.HostPreflightFailed }
        }
        return @{ ownerSid=$raw.Owner.Value; sha256=(Get-ClcBytesHash $bytes); bytes=$bytes; dacl=$raw.DiscretionaryAcl }
    } catch { Stop-ClcError Clc.HostPreflightFailed }
}

function Get-ClcEffectiveAccess {
    param([byte[]] $Descriptor, [string] $Sid)
    try { return [long][Clc.Host.Native]::AccessBounded($Descriptor,$Sid,($Sid -ceq (Get-ClcCallerSid))) }
    catch { Stop-ClcError Clc.HostPreflightFailed }
}

function Assert-ClcAccess {
    param([string] $Path, [string[]] $Owners, [string[]] $Writers, [string[]] $Readers,
        [string[]] $DeniedWriters = @(), [long] $ReadMask = 0x120089, [long] $WriteMask = 0)
    try {
    $security = Get-ClcSecurityObservation $Path
    if ($Owners -cnotcontains $security.ownerSid) { Stop-ClcError Clc.HostPreflightFailed }
    # Conservatively refuse unknown writable trustees, even when a deny happens to mask them.
    # This also avoids treating omitted logon groups as proof of runtime non-write access.
    $mutationMask = 0x000D0156L # data/append/EA/attributes/delete-child/delete/DACL/owner
    foreach ($ace in $security.dacl) {
        if ($ace.AceQualifier -eq [Security.AccessControl.AceQualifier]::AccessAllowed -and
            (([long]$ace.AccessMask -band $mutationMask) -ne 0 -or ([long]$ace.AccessMask -band 0xF0000000L) -ne 0) -and
            $Writers -cnotcontains $ace.SecurityIdentifier.Value) { Stop-ClcError Clc.HostPreflightFailed }
    }
    foreach ($sid in $Readers) {
        $mask = Get-ClcEffectiveAccess $security.bytes $sid
        if (($mask -band $ReadMask) -ne $ReadMask) { Stop-ClcError Clc.HostPreflightFailed }
    }
    foreach ($sid in $DeniedWriters) {
        if (((Get-ClcEffectiveAccess $security.bytes $sid) -band $mutationMask) -ne 0 -or $security.ownerSid -ceq $sid) { Stop-ClcError Clc.HostPreflightFailed }
    }
    if ($WriteMask -ne 0 -and ((Get-ClcEffectiveAccess $security.bytes (Get-ClcCallerSid)) -band $WriteMask) -ne $WriteMask) { Stop-ClcError Clc.HostPreflightFailed }
    return $security.sha256
    } catch { Stop-ClcError Clc.HostPreflightFailed }
}

function Read-ClcHeldFile {
    param([string] $Path, [Collections.Generic.List[IDisposable]] $Handles, [long] $Limit = 4194304, [switch] $SystemFile, [switch] $NoCapture, [switch] $Temporary,
        [Diagnostics.Stopwatch] $Clock=$null, [int] $Seconds=300)
    if ($null -eq $Clock) { $Clock=[Diagnostics.Stopwatch]::StartNew() }
    $facts = Get-ClcPathObservation $Path $Handles -SystemFile:$SystemFile -Temporary:$Temporary
    $stream = Open-ClcReadFile $Path $facts $Handles
    $digest = Read-ClcStream $stream $Limit $Clock -Capture:(-not $NoCapture) -Seconds $Seconds
    $stream.Position = 0
    return @{ path=$Path; facts=$facts; stream=$stream; bytes=$digest.bytes; sha256=$digest.sha256 }
}

function Read-ClcHeldRecord {
    param([string] $Path, [string] $Kind, [Collections.Generic.List[IDisposable]] $Handles)
    $file = Read-ClcHeldFile $Path $Handles
    $file.record = Read-ClcJson $file.bytes $Kind
    return $file
}

function Add-ClcProtectedPathPin {
    param($Context, [string] $Path, [switch] $Directory, [switch] $Mutable, [string] $RuntimeSid, [switch] $SystemFile, [switch] $SystemDirectory)
    # Read-only dependency directories may be in Windows/Program Files. Never use this
    # capability for mutable application, lock, state, inbox, configuration or key roots.
    if ($SystemDirectory -and (-not $Directory -or $Mutable -or $SystemFile -or $Path.Length -le 3)) { Stop-ClcError Clc.UnsafePath }
    $policy = $Context.policyFile.record
    $owners = [string[]]$policy.infrastructureOwnerSids
    $writers = $owners
    $denied = Get-ClcProtectedDeniedWriters $Context
    if ($Mutable) { $owners += [string[]]$policy.deploymentSids; $writers = $owners; $denied = @() }
    if ($RuntimeSid) { $denied += $RuntimeSid }
    # A repeated observation must not overwrite the original identity/descriptor
    # or accumulate another complete ancestry. Authentication is still fresh.
    if ($Context.pathPins.ContainsKey($Path)) {
        $pin=$Context.pathPins[$Path]
        if ($pin.directory -ne [bool]$Directory -or $pin.mutable -ne [bool]$Mutable -or $pin.handle.IsClosed) { Stop-ClcError Clc.ToolkitNotActive }
        $facts=[Clc.Foundation.NativePaths]::Observe($pin.handle)
        Assert-ClcPathSpelling $Path
        if ($facts.VolumeId -cne $pin.facts.VolumeId -or $facts.FileId -cne $pin.facts.FileId -or $facts.Attributes -ne $pin.facts.Attributes -or
            -not $facts.CanonicalPath.Equals($Path,[StringComparison]::OrdinalIgnoreCase) -or
            ($Directory -and (Get-ClcDirectoryCaseFlags $pin.handle) -ne 0) -or (-not $Directory -and $facts.LinkCount -ne 1) -or
            [Clc.Foundation.NativePaths]::SecurityHash($pin.handle) -cne $pin.nativeAclSha256 -or
            (Assert-ClcAccess $Path $owners $writers ([string[]]$policy.deploymentSids) $denied) -cne $pin.aclSha256) { Stop-ClcError Clc.ToolkitNotActive }
        Assert-ClcNoNamedStreams $Path
        return $facts
    }
    $handles=[Collections.Generic.List[IDisposable]]::new()
    try {
    $facts = Get-ClcPathObservation $Path $handles -Directory:$Directory -SystemFile:$SystemFile -AllowVolumeRoot:$SystemDirectory
    $aclHash = Assert-ClcAccess $Path $owners $writers ([string[]]$policy.deploymentSids) $denied
    $leafHandle=$handles[$handles.Count-1]
    $nativeAclHash=[Clc.Foundation.NativePaths]::SecurityHash($leafHandle)
    # Get-Acl may normalize inherited descriptor/control-bit representation. Bind
    # its checked result to a separately captured exact native descriptor rather
    # than assuming those serializations have identical bytes on every DACL.
    if ((Get-ClcSecurityObservation $Path).sha256 -cne $aclHash) { Stop-ClcError Clc.HostPreflightFailed }
    $Context.pathPins[$Path] = @{ facts=$facts; handle=$leafHandle; aclSha256=$aclHash; checkedAclSha256=$aclHash; nativeAclSha256=$nativeAclHash;
        directory=[bool]$Directory; systemFile=[bool]$SystemFile; systemDirectory=[bool]$SystemDirectory; mutable=[bool]$Mutable }
    $Context.handles.Add($leafHandle); $handles.RemoveAt($handles.Count-1)
    $Context.pinGeneration++
    return $facts
    } finally { foreach ($handle in $handles) { $handle.Dispose() } }
}

function Get-ClcToolkitInventory {
    param($Context)
    $root = $Context.layout.moduleRoot
    $files = [Collections.Generic.List[object]]::new()
    $queue = [Collections.Generic.Queue[string]]::new(); $queue.Enqueue($root)
    $clock = [Diagnostics.Stopwatch]::StartNew(); $count=0; $total=0L
    while ($queue.Count -gt 0) {
        foreach ($path in [IO.Directory]::EnumerateFileSystemEntries($queue.Dequeue())) {
            Assert-ClcDeadline $clock
            $count++; if ($count -gt 20000) { Stop-ClcError Clc.ToolkitNotActive }
            $relative = $path.Substring($root.Length+1).Replace('\','/')
            Assert-ClcArchiveName $relative
            $directory = ([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::Directory) -ne 0
            $facts = Add-ClcProtectedPathPin $Context $path -Directory:$directory
            if ($directory) { $queue.Enqueue($path) } else {
                $stream = Open-ClcReadFile $path $facts $Context.handles
                $digest = Read-ClcStream $stream 268435456 $clock
                $stream.Position=0; $total += $digest.length
                if ($total -gt 1073741824) { Stop-ClcError Clc.ToolkitNotActive }
                $files.Add(@{ path=$relative; length=$digest.length; sha256=$digest.sha256 })
            }
        }
    }
    if ($files.Count -lt 1) { Stop-ClcError Clc.ToolkitNotActive }
    return Get-ClcInventoryHash $files.ToArray()
}

function Assert-ClcTrustAncestors {
    param($Context, [string] $ProtectedPath=$Context.layout.root, [string] $RuntimeSid)
    # A protected leaf can still be replaced through DELETE_CHILD on a parent.
    $path = [IO.Path]::GetDirectoryName($ProtectedPath)
    while ($path) {
        $security = Get-ClcSecurityObservation $path
        $policy=$Context.policyFile.record
        # Preserve structural ancestor protection even though the elevated caller
        # can inherit administrator replacement authority. Ordinary create rights
        # on e.g. the volume root do not grant parent replacement authority.
        if ($policy.infrastructureOwnerSids -cnotcontains $security.ownerSid) { Stop-ClcError Clc.HostPreflightFailed }
        foreach ($ace in $security.dacl) {
            if ($ace.AceQualifier -eq [Security.AccessControl.AceQualifier]::AccessAllowed -and
                ($ace.AceFlags -band [Security.AccessControl.AceFlags]::InheritOnly) -eq 0 -and
                (([long]$ace.AccessMask -band 0x000D0040L) -ne 0 -or ([long]$ace.AccessMask -band 0xF0000000L) -ne 0) -and
                $policy.infrastructureOwnerSids -cnotcontains $ace.SecurityIdentifier.Value) { Stop-ClcError Clc.HostPreflightFailed }
        }
        $denied=Get-ClcProtectedDeniedWriters $Context $RuntimeSid
        foreach ($sid in $denied) {
            if (((Get-ClcEffectiveAccess $security.bytes $sid) -band 0x000D0040L) -ne 0 -or $security.ownerSid -ceq $sid) { Stop-ClcError Clc.HostPreflightFailed }
        }
        $Context.ancestorPins[$path] = $security.sha256
        $path = [IO.Path]::GetDirectoryName($path)
    }
}

function Assert-ClcHelperDependencies {
    param($Context,[string] $RuntimeSid)
    if ($Context.helperRuntimeSids.Contains($RuntimeSid)) { return }
    Assert-ClcTrustedContextUnchanged $Context
    Assert-ClcRuntimeIdentity $Context $RuntimeSid
    $policy=$Context.policyFile.record
    foreach ($path in @($policy.dotnetPath,$policy.appcmdPath,(Join-Path ([IO.Path]::GetDirectoryName($policy.appcmdPath)) 'Microsoft.Web.Administration.dll'))) {
        $null=Add-ClcProtectedPathPin $Context $path -SystemFile -RuntimeSid $RuntimeSid
        $parent=[IO.Path]::GetDirectoryName($path)
        $null=Add-ClcProtectedPathPin $Context $parent -Directory -SystemDirectory -RuntimeSid $RuntimeSid
        Assert-ClcTrustAncestors $Context $path $RuntimeSid
    }
    # Infrastructure owns the installed .NET/IIS runtime and toolkit. Deployment
    # validates their version and access; it does not authenticate a runtime loader.
    foreach ($path in @($Context.pathPins.Keys)) {
        if (-not $Context.pathPins[$path].mutable) {
            $null=Assert-ClcAccess $path ([string[]]$policy.infrastructureOwnerSids) ([string[]]$policy.infrastructureOwnerSids) ([string[]]$policy.deploymentSids) (Get-ClcProtectedDeniedWriters $Context $RuntimeSid)
        }
    }
    $null=$Context.helperRuntimeSids.Add($RuntimeSid)
}



function Assert-ClcHelperProtection {
    param($Context)
    if ($Context.helperRuntimeSids.Count -eq 0) { Stop-ClcError Clc.HostPreflightFailed }
    foreach ($sid in $Context.helperRuntimeSids) { Assert-ClcRuntimeIdentity $Context $sid }
    Assert-ClcTrustedContextUnchanged $Context
}

function Open-ClcTrustedContext {
    [CmdletBinding()]
    param()
    $context = @{ layout=(Get-ClcInstalledLayout); handles=[Collections.Generic.List[IDisposable]]::new(); pathPins=@{}; ancestorPins=@{}; pinGeneration=0L;
        helperRuntimeSids=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal); closed=$false }
    try {
        $context.policyFile = Read-ClcHeldRecord $context.layout.policyPath 'host-policy' $context.handles
        $policy = $context.policyFile.record
        Assert-ClcDeploymentToken $policy
        foreach ($key in @('targetCatalogRoot','approvalCatalogRoot','controlStateRoot','lockRoot')) {
            if (-not $policy[$key].Equals($context.layout[$key],[StringComparison]::Ordinal)) { Stop-ClcError Clc.ToolkitNotActive }
        }
        Assert-ClcStatePathBudget $policy
        foreach ($path in @($context.layout.root,$context.layout.versionRoot,[IO.Path]::GetDirectoryName($context.layout.versionRoot),$context.layout.moduleRoot,
                $context.layout.policyRoot,$policy.targetCatalogRoot,$policy.approvalCatalogRoot)) { $null = Add-ClcProtectedPathPin $context $path -Directory }
        $null = Add-ClcProtectedPathPin $context $context.layout.policyPath
        Assert-ClcTrustAncestors $context
        $pin = $policy.activeToolkit
        if ($pin.version -cne (Get-ClcToolkitVersion) -or -not $pin.moduleManifestPath.Equals($context.layout.manifestPath,[StringComparison]::Ordinal)) { Stop-ClcError Clc.ToolkitNotActive }
        foreach ($path in @($context.layout.sourcePath,$context.layout.distributionPath)) { $null = Add-ClcProtectedPathPin $context $path }
        $source = Read-ClcHeldFile $context.layout.sourcePath $context.handles 40
        if ([Text.UTF8Encoding]::new($false,$true).GetString($source.bytes) -cne $pin.sourceCommit) { Stop-ClcError Clc.ToolkitNotActive }
        $distributionFacts = Get-ClcPathObservation $context.layout.distributionPath $context.handles
        $distribution = Open-ClcReadFile $context.layout.distributionPath $distributionFacts $context.handles
        if ((Read-ClcStream $distribution 1073741824 ([Diagnostics.Stopwatch]::StartNew())).sha256 -cne $pin.distributionSha256 -or
            (Get-ClcToolkitInventory $context) -cne $pin.inventorySha256) { Stop-ClcError Clc.ToolkitNotActive }
        $context.executingToolkit = [ordered]@{}
        foreach ($key in @('version','sourceCommit','distributionSha256','inventorySha256')) { $context.executingToolkit[$key] = $pin[$key] }
        $context.rootFacts = @{}
        foreach ($key in @('controlStateRoot','lockRoot')) { $context.rootFacts[$key] = Add-ClcProtectedPathPin $context $policy[$key] -Directory -Mutable }
        Assert-ClcDisjoint $context.rootFacts.controlStateRoot $context.rootFacts.lockRoot
        foreach ($facts in $context.rootFacts.Values) { Assert-ClcDisjoint $facts $context.pathPins[$context.layout.root].facts }
        foreach ($key in @('dotnetPath','appcmdPath')) {
            $context.rootFacts[$key] = Add-ClcProtectedPathPin $context $policy[$key] -SystemFile
            Assert-ClcTrustAncestors $context $policy[$key]
        }
        Assert-ClcTrustedContextUnchanged $context
        return $context
    } catch {
        Close-ClcTrustedContext $context
        if ($_.FullyQualifiedErrorId -like 'Clc.*') { throw }
        Stop-ClcError Clc.ToolkitNotActive
    }
}

function Assert-ClcTrustedContextUnchanged {
    param($Context)
    if ($Context.closed) { Stop-ClcError Clc.ToolkitNotActive }
    Assert-ClcDeploymentToken $Context.policyFile.record
    $Context.policyFile.stream.Position=0
    $digest = Read-ClcStream $Context.policyFile.stream 4194304 ([Diagnostics.Stopwatch]::StartNew()) -Capture
    $Context.policyFile.stream.Position=0
    if ($digest.sha256 -cne $Context.policyFile.sha256) { Stop-ClcError Clc.ToolkitNotActive }
    # Open-ClcTrustedContext validated this exact record. Equal held bytes do
    # not need another JSON/schema pass on every state/file boundary.
    foreach ($path in $Context.pathPins.Keys) {
        $pin = $Context.pathPins[$path]
        # The original component handles stay open without write/delete sharing.
        # Reobserve their exact leaf handles instead of reopening every ancestor
        # for every pin on every boundary. ACLs remain fresh; no mutable authority
        # or application/configuration observation is cached.
        $facts=[Clc.Foundation.NativePaths]::Observe($pin.handle)
        Assert-ClcPathSpelling $path
        if ($facts.VolumeId -cne $pin.facts.VolumeId -or $facts.FileId -cne $pin.facts.FileId -or $facts.Attributes -ne $pin.facts.Attributes -or
            -not $facts.CanonicalPath.Equals($path,[StringComparison]::OrdinalIgnoreCase) -or
            (-not $pin.directory -and $facts.LinkCount -ne 1) -or
            ($pin.directory -and (Get-ClcDirectoryCaseFlags $pin.handle) -ne 0) -or
            $pin.aclSha256 -cne $pin.checkedAclSha256 -or [Clc.Foundation.NativePaths]::SecurityHash($pin.handle) -cne $pin.nativeAclSha256) { Stop-ClcError Clc.ToolkitNotActive }
        Assert-ClcNoNamedStreams $path
    }
    foreach ($path in $Context.ancestorPins.Keys) { if ((Get-ClcSecurityObservation $path).sha256 -cne $Context.ancestorPins[$path]) { Stop-ClcError Clc.ToolkitNotActive } }
}

function Close-ClcTrustedContext {
    param($Context)
    if ($null -ne $Context) {
        foreach ($handle in $Context.handles) { $handle.Dispose() }; $Context.closed=$true
    }
}

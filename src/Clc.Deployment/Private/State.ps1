
function Assert-ClcDeploymentUri {
    param($Value)
    Assert-ClcText $Value 256 '^https://[^/?#@\\]+/health/ready$'
    $uri=[uri]$Value
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -cne 'https' -or $uri.HostNameType -ne 'Dns' -or
        $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -cne '/health/ready') {
        Stop-ClcError Clc.InvalidReadinessUri 'Supply an absolute HTTPS DNS hostname and /health/ready.'
    }
}
function Assert-ClcSiteName {
    param($Value)
    Assert-ClcText $Value 64 '^[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}$'
    if ($Value.EndsWith(' ') -or $Value.EndsWith('.')) { Stop-ClcError Clc.InvalidContract 'Use an IIS site name without a trailing period or space.' }
}

function Assert-ClcReleaseReference {
    param($Value)
    Assert-ClcObject $Value @('attemptId','tag','archiveSha256','manifestSha256')
    Assert-ClcGuid $Value.attemptId
    $tag=Get-ClcDeploymentTag $Value.tag
    if ($tag.channel -ceq 'ArtifactOnly') { Stop-ClcError Clc.InvalidState }
    Assert-ClcHash $Value.archiveSha256
    Assert-ClcHash $Value.manifestSha256
}

function Assert-ClcHostRecord {
    param($Value,[string] $Kind)
    if ($Value -isnot [Collections.IDictionary] -or -not $Value.Contains('schemaVersion') -or
        $Value.schemaVersion -isnot [long] -or $Value.schemaVersion -ne 1 -or -not $Value.Contains('recordKind') -or
        $Value.recordKind -cne $Kind) { Stop-ClcError Clc.InvalidState 'The local deployment record is missing, unsupported or inconsistent.' }
    switch -CaseSensitive ($Kind) {
        host {
            Assert-ClcObject $Value @('schemaVersion','recordKind','applicationId','targetId','siteName','applicationPoolName','applicationRoot','readinessUri','siteId')
            Assert-ClcId $Value.applicationId
            Assert-ClcId $Value.targetId
            Assert-ClcSiteName $Value.siteName
            Assert-ClcCode $Value.applicationPoolName 64
            Assert-ClcAbsolutePath $Value.applicationRoot
            Assert-ClcDeploymentUri $Value.readinessUri
            Assert-ClcInteger $Value.siteId 1 4294967295
        }
        state {
            Assert-ClcObject $Value @('schemaVersion','recordKind','applicationId','targetId','current','highWater','pending')
            Assert-ClcId $Value.applicationId
            Assert-ClcId $Value.targetId
            if ($null -ne $Value.highWater) { Assert-ClcReleaseReference $Value.highWater }
            if ($null -ne $Value.pending) { Assert-ClcReleaseReference $Value.pending }
            if ($null -ne $Value.current) {
                Assert-ClcObject $Value.current @('release','configurationRevision','keyStoreCompatibilityId','environment','readyUtc')
                Assert-ClcReleaseReference $Value.current.release
                Assert-ClcCode $Value.current.configurationRevision 64
                Assert-ClcCode $Value.current.keyStoreCompatibilityId 128
                Assert-ClcEnum $Value.current.environment @('Staging','Production')
                Assert-ClcTimestamp $Value.current.readyUtc
            }
        }
        attempt {
            Assert-ClcObject $Value @('schemaVersion','recordKind','applicationId','targetId','release','previous','phase','backupVerified','helper','startedUtc','toolkitVersion','reason','errorCode')
            Assert-ClcId $Value.applicationId
            Assert-ClcId $Value.targetId
            Assert-ClcReleaseReference $Value.release
            if ($null -ne $Value.previous) { Assert-ClcReleaseReference $Value.previous }
            Assert-ClcEnum $Value.phase @('Preparing','Stopping','Replacing','Checking','Ready','Recovering','Restored')
            Assert-ClcBoolean $Value.backupVerified
            Assert-ClcTimestamp $Value.startedUtc
            Assert-ClcVersion $Value.toolkitVersion
            if ($null -ne $Value.helper) {
                Assert-ClcObject $Value.helper @('status','processId','creationUtc')
                Assert-ClcEnum $Value.helper.status @('Intent','Started','Exited')
                if ($Value.helper.status -ceq 'Intent') {
                    if ($null -ne $Value.helper.processId -or $null -ne $Value.helper.creationUtc) { Stop-ClcError Clc.InvalidState }
                } else {
                    Assert-ClcInteger $Value.helper.processId 1 4294967295
                    Assert-ClcTimestamp $Value.helper.creationUtc -Native
                }
            }
            if ($null -ne $Value.reason) { Assert-ClcCode $Value.reason }
            if ($null -ne $Value.errorCode) { Assert-ClcCode $Value.errorCode }
        }
        default { Stop-ClcError Clc.UnsupportedContract }
    }
}

function Read-ClcLocalRecord {
    param([string] $Path,[string] $Kind)
    $handles=[Collections.Generic.List[IDisposable]]::new()
    try {
        $file=Read-ClcHeldFile $Path $handles
        $null=Assert-ClcAccess $Path $script:ClcAdministrators $script:ClcAdministrators @()
        return ,(Read-ClcJson $file.bytes $Kind)
    } finally { foreach ($handle in $handles) { $handle.Dispose() } }
}
function Set-ClcManagedOwner {
    param([string] $Path)
    $acl=Get-Acl -LiteralPath $Path
    $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    Set-Acl -LiteralPath $Path -AclObject $acl
}
function Write-ClcLocalBytes {
    param([string] $Path,[byte[]] $Bytes,[switch] $Replace)
    Assert-ClcPathSpelling $Path
    $parent=[IO.Path]::GetDirectoryName($Path)
    Assert-ClcStoragePath $parent -Directory
    if ($Replace) { Assert-ClcStoragePath $Path }
    $temp=Join-Path $parent ('.clc-record-'+[guid]::NewGuid().ToString('N')+'.tmp')
    $stream=[IO.File]::Open($temp,'CreateNew','Write','None')
    try { $stream.Write($Bytes); $stream.Flush($true) }
    finally { $stream.Dispose() }
    Set-ClcManagedOwner $temp
    [IO.File]::Move($temp,$Path,[bool]$Replace)
}
function Write-ClcLocalRecord {
    param([string] $Path,$Record,[switch] $Replace)
    $bytes=[Text.Encoding]::UTF8.GetBytes(($Record | ConvertTo-Json -Depth 16 -Compress))
    $null=Read-ClcJson $bytes $Record.recordKind
    Write-ClcLocalBytes $Path $bytes -Replace:$Replace
}
function Get-ClcUtc {
    [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ',[Globalization.CultureInfo]::InvariantCulture)
}

function Enter-ClcDeploymentLock {
    param($Layout)
    Assert-ClcStoragePath $Layout.deployment -Directory
    $null=Assert-ClcAccess $Layout.deployment $script:ClcAdministrators $script:ClcAdministrators @()
    try {
        # FileShare.None is held by the mutator through the final state write.
        # Open the leaf itself, including a reparse point, to avoid following it.
        $stream=[Clc.Foundation.NativePaths]::OpenDeploymentLock($Layout.lock)
    } catch { Stop-ClcError Clc.DeploymentLocked 'The deployment lock is busy or unsafe. Inspect the active runner and lock path; preserve the lock file.' }
    try {
        $facts=[Clc.Foundation.NativePaths]::Observe($stream.SafeFileHandle)
        if ($facts.CanonicalPath -ine $Layout.lock -or ($facts.Attributes -band 0x410) -ne 0 -or $facts.LinkCount -ne 1 -or $stream.Length -ne 0) {
            Stop-ClcError Clc.UnsafePath 'The deployment lock does not identify the expected regular file.'
        }
        Assert-ClcNoNamedStreams $Layout.lock
        return $stream
    } catch { $stream.Dispose(); throw }
}

function Get-ClcAttemptPaths {
    param($Layout,[string] $AttemptId)
    Assert-ClcGuid $AttemptId
    $root=Join-Path $Layout.deployment ('attempt-'+$AttemptId)
    return @{root=$root;journal=(Join-Path $root 'attempt.json');manifest=(Join-Path $root 'manifest.json');
        stage=(Join-Path $root 'stage');backup=(Join-Path $root 'backup');work=(Join-Path $root 'replace.tmp');
        beforeRecovery=(Join-Path $root 'before-recovery.json')}
}
function Read-ClcRetainedManifest {
    param($HostContext,$Reference)
    $paths=Get-ClcAttemptPaths $HostContext.layout $Reference.attemptId
    $handles=[Collections.Generic.List[IDisposable]]::new()
    try {
        $file=Read-ClcHeldFile $paths.manifest $handles
        $null=Assert-ClcAccess $paths.root $script:ClcAdministrators $script:ClcAdministrators @()
        $null=Assert-ClcAccess $paths.manifest $script:ClcAdministrators $script:ClcAdministrators @()
        if ($file.sha256 -cne $Reference.manifestSha256) { Stop-ClcError Clc.ContentDrift 'The retained release manifest no longer matches the recorded digest.' }
        $manifest=Read-ClcJson $file.bytes 'release-manifest'
        $tag=Get-ClcDeploymentTag $Reference.tag
        if ($manifest.releaseId -cne $tag.releaseId -or $manifest.targetId -cne $HostContext.target.targetId -or
            $manifest.applicationId -cne $HostContext.target.applicationId) { Stop-ClcError Clc.InvalidState }
        return ,$manifest
    } finally { foreach ($handle in $handles) { $handle.Dispose() } }
}

function Test-ClcSameReference {
    param($First,$Second)
    return $First.attemptId -ceq $Second.attemptId -and $First.tag -ceq $Second.tag -and
        $First.archiveSha256 -ceq $Second.archiveSha256 -and $First.manifestSha256 -ceq $Second.manifestSha256
}
function Assert-ClcHostState {
    param($Context,[switch] $Recovery)
    $state=$Context.state; $iis=$Context.iis
    if ($state.applicationId -cne $Context.target.applicationId -or $state.targetId -cne $Context.target.targetId -or
        ($null -ne $state.pending -and ($null -eq $state.highWater -or -not (Test-ClcSameReference $state.pending $state.highWater))) -or
        ($null -ne $state.current -and ($null -eq $state.highWater -or
            (Get-ClcDeploymentTag $state.current.release.tag).releaseSequence -gt (Get-ClcDeploymentTag $state.highWater.tag).releaseSequence))) {
        Stop-ClcError Clc.InvalidState 'Local host and deployment records disagree. Preserve the state and inspect it.'
    }
    if ($null -ne $state.pending -and -not $Recovery) {
        Stop-ClcError Clc.RecoveryRequired ('Inspect retained attempt '+$state.pending.attemptId+' and use explicit recovery when the evidence permits.')
    }
    if ($null -ne $state.current) {
        if ($state.current.environment -cne $Context.environment) { Stop-ClcError Clc.TargetMismatch 'Use the runtime environment recorded by the current deployment.' }
        $Context.previous=Read-ClcRetainedManifest $Context $state.current.release
    } else { $Context.previous=$null }
    if ($Recovery) { return }
    if ($iis.siteState -cnotin @('Started','Stopped') -or $iis.poolState -cnotin @('Started','Stopped') -or
        $iis.workerCount -gt 1 -or ($iis.poolState -ceq 'Stopped' -and $iis.workerCount -ne 0)) {
        Stop-ClcError Clc.IisStateUnknown 'Wait for a stable site and pool with at most one worker before retrying.'
    }
    if ($null -eq $state.current -and ($iis.siteState -cne 'Stopped' -or $iis.poolState -cne 'Stopped' -or
        $iis.siteAutoStart -or $iis.poolAutoStart)) {
        Stop-ClcError Clc.IisSettings 'Before the first deployment, stop the site and pool and keep both automatic-start flags disabled.'
    }
    if ($null -ne $state.current -and (-not $iis.siteAutoStart -or -not $iis.poolAutoStart)) {
        Stop-ClcError Clc.IisSettings 'Verify both automatic-start flags on the commissioned site and pool.'
    }
    $files=@(if ($null -ne $Context.previous) { $Context.previous.files })
    $null=Get-ClcTreeInventory $Context.layout.application $files -RuntimeSid $Context.runtimeSid
}

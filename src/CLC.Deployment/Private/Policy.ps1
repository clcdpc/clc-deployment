function Read-ClcProtectedTarget {
    [CmdletBinding()]
    param($Context, [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9-]{0,63}$')][string] $TargetId)
    Assert-ClcTrustedContextUnchanged $Context
    $path = Join-Path $Context.layout.targetCatalogRoot ($TargetId + '.json')
    $null = Add-ClcProtectedPathPin $Context $path
    $file = Read-ClcHeldRecord $path 'target' $Context.handles
    if ($file.record.targetId -cne $TargetId) { Stop-ClcError Clc.HostPreflightFailed }
    Assert-ClcRuntimeIdentity $Context $file.record.runtimeIdentitySid
    Assert-ClcHelperDependencies $Context $file.record.runtimeIdentitySid
    return $file
}

function Read-ClcProtectedApproval {
    [CmdletBinding()]
    param($Context, [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9-]{0,63}$')][string] $ApprovalId)
    Assert-ClcTrustedContextUnchanged $Context
    $path = Join-Path $Context.layout.approvalCatalogRoot ($ApprovalId + '.json')
    try {
        $null = Add-ClcProtectedPathPin $Context $path
        $file = Read-ClcHeldRecord $path 'release-approval' $Context.handles
    } catch {
        if (-not [IO.File]::Exists($path)) { Stop-ClcError Clc.ApprovalMissing }
        throw
    }
    if ($file.record.approvalId -cne $ApprovalId -or $Context.policyFile.record.infrastructureOwnerSids -cnotcontains $file.record.authorization.authoritySid) { Stop-ClcError Clc.ApprovalMismatch }
    return $file
}

function Assert-ClcHeldRecordUnchanged {
    param($Context, $File, [string] $Code)
    Assert-ClcTrustedContextUnchanged $Context
    $File.stream.Position=0
    $digest = Read-ClcStream $File.stream 4194304 ([Diagnostics.Stopwatch]::StartNew()) -Capture
    $File.stream.Position=0
    if ($digest.sha256 -cne $File.sha256) { Stop-ClcError $Code }
    # The record was strictly parsed at selection. Exact unchanged bytes retain
    # that shape; re-running schema validation cannot add authority.
}

function Read-ClcApprovedRelease {
    [CmdletBinding()]
    param($Context, [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9-]{0,63}$')][string] $TargetId,
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9-]{0,63}$')][string] $ReleaseApprovalId, $Lock=$null)
    $targetFile = Read-ClcProtectedTarget $Context $TargetId
    $approvalFile = Read-ClcProtectedApproval $Context $ReleaseApprovalId
    $target = $targetFile.record; $approval = $approvalFile.record
    if (-not $approval.enabled) { Stop-ClcError Clc.ApprovalDisabled }
    if ($approval.targetId -cne $TargetId -or $approval.applicationId -cne $target.applicationId) { Stop-ClcError Clc.ApprovalMismatch }
    $standing=if ($approval.schemaVersion -ge 2) { Read-ClcActiveStandingForApproval $Context $target $approvalFile } else { $null }
    $null = Add-ClcProtectedPathPin $Context $target.artifactInboxRoot -Directory -Mutable -RuntimeSid $target.runtimeIdentitySid
    $archiveRoot=$target.artifactInboxRoot
    if ($null -ne $Lock) {
        Assert-ClcLockOwned $Lock
        if ($Lock.context -ne $Context -or -not (Test-ClcValueEqual $Lock.targetFile.record $target)) { Stop-ClcError Clc.ApprovalMismatch }
        $archiveRoot=Join-Path $Lock.identity.controlRoot 'releases'
    }
    $archivePath=Join-Path $archiveRoot ($ReleaseApprovalId + '.zip')
    if ($null -ne $Lock) {
        Assert-ClcControlAncestorAccess $Context $Lock.identity.controlRoot $archivePath $target.runtimeIdentitySid $Context.handles
    }
    $archiveAcl=Assert-ClcAccess $archivePath ([string[]]($Context.policyFile.record.infrastructureOwnerSids+$Context.policyFile.record.deploymentSids)) `
        ([string[]]($Context.policyFile.record.infrastructureOwnerSids+$Context.policyFile.record.deploymentSids)) `
        ([string[]]$Context.policyFile.record.deploymentSids) @($target.runtimeIdentitySid)
    $archiveFacts=Get-ClcPathObservation $archivePath $Context.handles
    $archiveStream=Open-ClcReadFile $archivePath $archiveFacts $Context.handles
    if ((Get-ClcSecurityObservation $archivePath).sha256 -cne $archiveAcl) { Stop-ClcError Clc.HostPreflightFailed }
    $archive=@{path=$archivePath;facts=$archiveFacts;stream=$archiveStream;aclSha256=$archiveAcl;
        controlRoot=$(if ($null -ne $Lock) {$Lock.identity.controlRoot} else {$null});runtimeSid=$target.runtimeIdentitySid}
    $inspection = Test-ClcArchiveStream $archive.stream ([Diagnostics.Stopwatch]::StartNew())
    if ($inspection.archiveSha256 -cne $approval.releaseZipSha256 -or $inspection.manifestSha256 -cne $approval.manifestSha256) { Stop-ClcError Clc.ApprovalMismatch }
    $archive.stream.Position=0
    $zip = [IO.Compression.ZipArchive]::new($archive.stream,[IO.Compression.ZipArchiveMode]::Read,$true)
    try {
        $entry = $zip.GetEntry('manifest.json'); $input = $entry.Open()
        try { $manifestBytes = (Read-ClcStream $input 4194304 ([Diagnostics.Stopwatch]::StartNew()) -Capture).bytes }
        finally { $input.Dispose() }
    } finally { $zip.Dispose(); $archive.stream.Position=0 }
    $manifest = Read-ClcJson $manifestBytes 'release-manifest'
    if ($manifest.applicationId -cne $approval.applicationId -or $manifest.releaseId -cne $approval.releaseId -or
        $manifest.source.repository -cne $approval.sourceRepository -or $manifest.source.commit -cne $approval.sourceCommit -or
        $manifest.build.workflowPath -cne $approval.provenance.workflowPath -or $manifest.build.runId -ne $approval.provenance.runId -or
        $manifest.build.runAttempt -ne $approval.provenance.runAttempt -or $manifest.build.job -cne $approval.provenance.buildJob) { Stop-ClcError Clc.ApprovalMismatch }
    Assert-ClcHeldRecordUnchanged $Context $targetFile 'Clc.HostPreflightFailed'
    Assert-ClcHeldRecordUnchanged $Context $approvalFile 'Clc.ApprovalMismatch'
    $archive.sha256=$inspection.archiveSha256; $archive.length=$archive.stream.Length
    return @{ targetFile=$targetFile; approvalFile=$approvalFile; archive=$archive; manifest=$manifest; manifestBytes=$manifestBytes;
        inspection=$inspection; approvalVerified=$true; authorizedForDeployment=$false; standing=$standing }
}

function Assert-ClcApprovedReleaseUnchanged {
    param($Context, $Release)
    Assert-ClcHeldRecordUnchanged $Context $Release.targetFile 'Clc.HostPreflightFailed'
    Assert-ClcHeldRecordUnchanged $Context $Release.approvalFile 'Clc.ApprovalMismatch'
    if (-not $Release.approvalFile.record.enabled) { Stop-ClcError Clc.ApprovalDisabled }
    if ($Release.ContainsKey('standing') -and $null -ne $Release.standing) { Assert-ClcHeldRecordUnchanged $Context $Release.standing 'Clc.StandingAuthorizationRejected' }
    if ($null -eq $Release.archive) { return }
    $archive=$Release.archive
    if ($archive.stream.SafeFileHandle.IsClosed -or $archive.stream.SafeFileHandle.IsInvalid -or
        $archive.sha256 -cne $Release.approvalFile.record.releaseZipSha256) { Stop-ClcError Clc.ApprovalMismatch }
    $facts=[Clc.Foundation.NativePaths]::Observe($archive.stream.SafeFileHandle)
    if ($facts.VolumeId -cne $archive.facts.VolumeId -or $facts.FileId -cne $archive.facts.FileId -or
        $facts.LinkCount -ne 1 -or ($facts.Attributes -band 0x410) -ne 0 -or
        -not $facts.CanonicalPath.Equals($archive.path,[StringComparison]::OrdinalIgnoreCase)) { Stop-ClcError Clc.UnsafePath }
    if ($archive.controlRoot) { Assert-ClcControlAncestorAccess $Context $archive.controlRoot $archive.path $archive.runtimeSid }
    $policy=$Context.policyFile.record
    $acl=Assert-ClcAccess $archive.path ([string[]]($policy.infrastructureOwnerSids+$policy.deploymentSids)) `
        ([string[]]($policy.infrastructureOwnerSids+$policy.deploymentSids)) ([string[]]$policy.deploymentSids) @($archive.runtimeSid)
    if ($acl -cne $archive.aclSha256 -or (Get-ClcSecurityObservation $archive.path).sha256 -cne $acl) { Stop-ClcError Clc.HostPreflightFailed }
    Assert-ClcNoNamedStreams $archive.path
}

function Read-ClcEmptyBaselineRelease {
    param($Lock,[string] $ApprovalId)
    return Read-ClcApprovedManifest $Lock $ApprovalId
}

function Read-ClcApprovedManifest {
    param($Lock,[string] $ApprovalId)
    $context=$Lock.context
    $target=Read-ClcProtectedTarget $context $Lock.targetFile.record.targetId
    $approval=Read-ClcProtectedApproval $context $ApprovalId
    $a=$approval.record
    if (-not $a.enabled) { Stop-ClcError Clc.ApprovalDisabled }
    if ($a.targetId -cne $target.record.targetId -or $a.applicationId -cne $target.record.applicationId) { Stop-ClcError Clc.ApprovalMismatch }
    $path=Join-Path $Lock.identity.controlRoot ('releases\'+$ApprovalId+'.json')
    Assert-ClcControlAncestorAccess $context $Lock.identity.controlRoot $path $target.record.runtimeIdentitySid
    Assert-ClcPathAccess $context $path $target.record.runtimeIdentitySid Mutable
    $file=Read-ClcHeldRecord $path release-manifest $context.handles
    $m=$file.record
    if ($file.sha256 -cne $a.manifestSha256 -or $m.applicationId -cne $a.applicationId -or $m.releaseId -cne $a.releaseId -or
        $m.source.repository -cne $a.sourceRepository -or $m.source.commit -cne $a.sourceCommit -or
        $m.build.workflowPath -cne $a.provenance.workflowPath -or $m.build.runId -ne $a.provenance.runId -or
        $m.build.runAttempt -ne $a.provenance.runAttempt -or $m.build.job -cne $a.provenance.buildJob) { Stop-ClcError Clc.ApprovalMismatch }
    return @{targetFile=$target;approvalFile=$approval;manifest=$m;manifestBytes=$file.bytes;archive=$null}
}

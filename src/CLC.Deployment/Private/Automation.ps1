# Protected standing policy authorizes trusted elevated workflow admission.
# Caller identity evidence never grants authority independently of that policy.
function Get-ClcDeploymentTag {
    param($Tag)
    Assert-ClcText $Tag 64 '^v(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})(-(dev|beta|rc)\.([1-9][0-9]{0,3}))?$'
    $m=[regex]::Match($Tag,'^v([0-9]+)\.([0-9]+)\.([0-9]+)(?:-(dev|beta|rc)\.([0-9]+))?$')
    $kind=$m.Groups[4].Value
    $channel=if ($kind -ceq 'dev') {'DEV'} elseif ($kind -ceq '') {'Production'} else {'ArtifactOnly'}
    $ordinal=if ($kind -ceq '') {9999L} else {[long]$m.Groups[5].Value}
    if ($ordinal -gt 9998 -and $kind) { Stop-ClcError Clc.InvalidContract }
    $sequence=(([long]$m.Groups[1].Value*10000L+[long]$m.Groups[2].Value)*10000L+[long]$m.Groups[3].Value)*10000L+$ordinal
    return @{tag=$Tag;channel=$channel;releaseId=$Tag.Replace('.','-');releaseSequence=$sequence}
}

function Assert-ClcStandingAuthorization {
    param($Value)
    Assert-ClcObject $Value @('contractFamily','schemaVersion','recordKind','standingAuthorizationId','enabled','targetId','applicationId','environmentName','channel','sourceRepository','buildWorkflowPath','buildJob','lineageId','authorization')
    foreach ($key in @('standingAuthorizationId','targetId','applicationId','lineageId')) { Assert-ClcId $Value[$key] }
    Assert-ClcBoolean $Value.enabled
    Assert-ClcText $Value.environmentName
    Assert-ClcEnum $Value.channel @('DEV','Production')
    Assert-ClcRepository $Value.sourceRepository
    Assert-ClcWorkflow $Value.buildWorkflowPath
    Assert-ClcCode $Value.buildJob
    Assert-ClcObject $Value.authorization @('authoritySid','reference','approvedUtc')
    Assert-ClcSid $Value.authorization.authoritySid
    Assert-ClcCode $Value.authorization.reference
    Assert-ClcTimestamp $Value.authorization.approvedUtc
}

function Assert-ClcVerifiedRelease {
    param($Value)
    Assert-ClcObject $Value @('contractFamily','schemaVersion','recordKind','targetId','applicationId','releaseId','tag','sourceRepository','sourceCommit','releaseZipSha256','manifestSha256','provenance')
    foreach ($key in @('targetId','applicationId','releaseId')) { Assert-ClcId $Value[$key] }
    $null=Get-ClcDeploymentTag $Value.tag
    Assert-ClcRepository $Value.sourceRepository
    Assert-ClcCommit $Value.sourceCommit
    foreach ($key in @('releaseZipSha256','manifestSha256')) { Assert-ClcHash $Value[$key] }
    Assert-ClcObject $Value.provenance @('workflowPath','runId','runAttempt','buildJob','artifactId','transportSha256')
    Assert-ClcWorkflow $Value.provenance.workflowPath
    foreach ($key in @('runId','runAttempt','artifactId')) { Assert-ClcInteger $Value.provenance[$key] 1 }
    Assert-ClcCode $Value.provenance.buildJob
    Assert-ClcHash $Value.provenance.transportSha256
}

function Read-ClcStandingAuthorization {
    param($Context,$Target,[string] $Id)
    Assert-ClcId $Id
    Assert-ClcTrustedContextUnchanged $Context
    $root=Join-Path $Context.layout.approvalCatalogRoot 'standing'
    $path=Join-Path $root ($Id+'.json')
    try {
        foreach ($item in @($root,$path)) { $null=Add-ClcProtectedPathPin $Context $item -Directory:($item -ceq $root) -RuntimeSid $Target.runtimeIdentitySid }
        $file=Read-ClcHeldRecord $path standing-authorization $Context.handles
        $s=$file.record
        if (-not $s.enabled -or $s.standingAuthorizationId -cne $Id -or $s.targetId -cne $Target.targetId -or
            $s.applicationId -cne $Target.applicationId -or $s.environmentName -cne $Target.environmentName -or
            $Context.policyFile.record.infrastructureOwnerSids -cnotcontains $s.authorization.authoritySid -or
            $Context.policyFile.record.deploymentSids -ccontains $s.authorization.authoritySid) { Stop-ClcError Clc.StandingAuthorizationRejected }
        return $file
    } catch { Stop-ClcError Clc.StandingAuthorizationRejected }
}

function Read-ClcActiveStandingForApproval {
    param($Context,$Target,$ApprovalFile)
    $a=$ApprovalFile.record
    $pending=Join-Path $Context.layout.approvalCatalogRoot ('standing\'+$Target.targetId+'.pending')
    if ([IO.File]::Exists($pending) -or [IO.Directory]::Exists($pending)) { Stop-ClcError Clc.AdmissionIncomplete }
    $file=Read-ClcStandingAuthorization $Context $Target $a.admission.standingAuthorizationId
    $s=$file.record; $tag=Get-ClcDeploymentTag $a.admission.tag
    if ($file.sha256 -cne $a.admission.standingAuthorizationSha256 -or $tag.channel -cne $s.channel -or
        $a.releaseSequence -ne $tag.releaseSequence -or $a.lineageId -cne $s.lineageId -or
        $a.sourceRepository -cne $s.sourceRepository -or $a.provenance.workflowPath -cne $s.buildWorkflowPath -or
        $a.provenance.buildJob -cne $s.buildJob) { Stop-ClcError Clc.StandingAuthorizationRejected }
    $null=Read-ClcTagBinding $Context $Target $a -Required
    $null=Read-ClcAdmissionEvidence $Context $Target $a
    return $file
}

function Read-ClcAdmissionEvidence {
    param($Context,$Target,$Approval)
    $path=Join-Path $Context.layout.approvalCatalogRoot ('standing\'+$Approval.approvalId+'.verified.json')
    $null=Add-ClcProtectedPathPin $Context $path -RuntimeSid $Target.runtimeIdentitySid
    $file=Read-ClcHeldRecord $path verified-release $Context.handles
    if ($file.sha256 -cne $Approval.admission.verifiedReleaseSha256) { Stop-ClcError Clc.AdmissionIncomplete }
    return $file
}

function Get-ClcTagBinding {
    param($Context,$Target,$Approval)
    $binding=[ordered]@{contractFamily='clc-file-iis-v1';schemaVersion=1L;recordKind='release-tag-binding';
        targetId=$Target.targetId;applicationId=$Target.applicationId;lineageId=$Approval.lineageId;
        tag=$Approval.admission.tag;sourceRepository=$Approval.sourceRepository;sourceCommit=$Approval.sourceCommit}
    $key=Get-ClcBytesHash ([Text.Encoding]::UTF8.GetBytes($Target.targetId+[char]0+$Approval.lineageId+[char]0+$Approval.admission.tag))
    return @{path=(Join-Path $Context.layout.approvalCatalogRoot ('standing\tag-'+$key+'.json'));record=$binding}
}

function Read-ClcTagBinding {
    param($Context,$Target,$Approval,[switch] $Required)
    $binding=Get-ClcTagBinding $Context $Target $Approval
    if (-not [IO.File]::Exists($binding.path)) {
        if ($Required -or [IO.Directory]::Exists($binding.path)) { Stop-ClcError Clc.AdmissionIncomplete }
        return $null
    }
    $null=Add-ClcProtectedPathPin $Context $binding.path -RuntimeSid $Target.runtimeIdentitySid
    $file=Read-ClcHeldRecord $binding.path release-tag-binding $Context.handles
    if (-not (Test-ClcValueEqual $file.record $binding.record)) { Stop-ClcError Clc.ReleaseIdentityConflict }
    return $file
}

function Assert-ClcAutomatedOrdering {
    param($Approval,$Previous)
    if ($Approval.lineageId -cne $Previous.lineageId -or $Approval.releaseSequence -lt $Previous.releaseSequence) { Stop-ClcError Clc.DowngradeRejected }
    if ($Approval.releaseSequence -ne $Previous.releaseSequence) { return }
    if ($Approval.sourceRepository -cne $Previous.sourceRepository -or $Approval.sourceCommit -cne $Previous.sourceCommit) { Stop-ClcError Clc.ReleaseIdentityConflict }
    if ($Approval.approvalId -ceq $Previous.approvalId) { return }
    # Same-tag rebuilds must be a later build, not changed bytes for the same run.
    if ($Approval.provenance.runId -lt $Previous.provenance.runId -or
        ($Approval.provenance.runId -eq $Previous.provenance.runId -and $Approval.provenance.runAttempt -le $Previous.provenance.runAttempt)) { Stop-ClcError Clc.ReleaseIdentityConflict }
}

function Open-ClcAutomationInput {
    param($Lock,[string] $Path,[long] $Limit,[switch] $Archive)
    $context=$Lock.context; $target=$Lock.targetFile.record; $policy=$context.policyFile.record
    Assert-ClcAbsolutePath $Path
    Assert-ClcPathSpelling $Path
    if ([IO.Path]::GetDirectoryName($Path) -cne $target.artifactInboxRoot) { Stop-ClcError Clc.UnsafePath }
    $acl=Assert-ClcAccess $Path ([string[]]($policy.infrastructureOwnerSids+$policy.deploymentSids)) `
        ([string[]]($policy.infrastructureOwnerSids+$policy.deploymentSids)) ([string[]]$policy.deploymentSids) @($target.runtimeIdentitySid)
    $facts=Get-ClcPathObservation $Path $context.handles
    $stream=Open-ClcReadFile $Path $facts $context.handles
    if ($stream.Length -le 0 -or $stream.Length -gt $Limit) { Stop-ClcError Clc.InvalidContract }
    $sha256=$null
    if (-not $Archive) {
        $sha256=(Read-ClcStream $stream $Limit ([Diagnostics.Stopwatch]::StartNew())).sha256
        $stream.Position=0
    }
    $file=@{path=$Path;facts=$facts;stream=$stream;sha256=$sha256;length=$stream.Length;aclSha256=$acl;controlRoot=$null}
    if ((Get-ClcSecurityObservation $Path).sha256 -cne $acl) { Stop-ClcError Clc.HostPreflightFailed }
    $file.runtimeSid=$target.runtimeIdentitySid
    return $file
}

function Get-ClcAutomatedSelection {
    param($Lock,$Approval,$Archive,$Manifest,[byte[]] $ManifestBytes,$Inspection,$Standing)
    return @{approvalId=$Approval.record.approvalId;
        release=@{targetFile=$Lock.targetFile;approvalFile=$Approval;archive=$Archive;manifest=$Manifest;manifestBytes=$ManifestBytes;
            inspection=$Inspection;approvalVerified=$true;authorizedForDeployment=$false;standing=$Standing}}
}

function Publish-ClcAutomatedApproval {
    param([string] $PendingPath,[string] $ApprovalPath)
    [IO.File]::Move($PendingPath,$ApprovalPath,$false)
}

function New-ClcAutomatedApproval {
    param($Lock,[string] $StandingAuthorizationId,[string] $ReleaseTag,[string] $ArchivePath,[string] $VerifiedReleasePath)
    $decision=Get-ClcReconciliationDecision $Lock
    if ($decision.classification -cne 'Clean' -or $null -eq $Lock.state.current) { Stop-ClcError Clc.AutomationRequiresBaseline }
    $context=$Lock.context; $target=$Lock.targetFile.record
    $standing=Read-ClcStandingAuthorization $context $target $StandingAuthorizationId; $s=$standing.record
    $tag=Get-ClcDeploymentTag $ReleaseTag
    if ($tag.channel -cne $s.channel) { Stop-ClcError Clc.StandingAuthorizationRejected }
    $current=$Lock.state.current.record
    if ($current.approvalSnapshot.lineageId -cne $s.lineageId -or $tag.releaseSequence -lt $current.approvalSnapshot.releaseSequence) { Stop-ClcError Clc.DowngradeRejected }
    $null=Add-ClcProtectedPathPin $context $target.artifactInboxRoot -Directory -Mutable -RuntimeSid $target.runtimeIdentitySid
    $evidence=Open-ClcAutomationInput $Lock $VerifiedReleasePath 4194304
    $evidenceBytes=(Read-ClcStream $evidence.stream 4194304 ([Diagnostics.Stopwatch]::StartNew()) -Capture).bytes
    $p=Read-ClcJson $evidenceBytes verified-release
    $evidence.stream.Position=0
    $input=Open-ClcAutomationInput $Lock $ArchivePath 1073741824 -Archive
    $inspection=Test-ClcArchiveStream $input.stream ([Diagnostics.Stopwatch]::StartNew())
    $input.sha256=$inspection.archiveSha256
    $input.stream.Position=0
    $zip=[IO.Compression.ZipArchive]::new($input.stream,[IO.Compression.ZipArchiveMode]::Read,$true)
    try {
        $stream=$zip.GetEntry('manifest.json').Open()
        try { $bytes=(Read-ClcStream $stream 4194304 ([Diagnostics.Stopwatch]::StartNew()) -Capture).bytes } finally { $stream.Dispose() }
    } finally { $zip.Dispose(); $input.stream.Position=0 }
    $manifest=Read-ClcJson $bytes release-manifest
    if ($p.targetId -cne $target.targetId -or $p.applicationId -cne $target.applicationId -or $p.tag -cne $ReleaseTag -or
        $manifest.releaseId -cne $p.releaseId -or $manifest.applicationId -cne $p.applicationId -or
        $p.sourceRepository -cne $s.sourceRepository -or $manifest.source.repository -cne $p.sourceRepository -or $manifest.source.commit -cne $p.sourceCommit -or
        $inspection.archiveSha256 -cne $p.releaseZipSha256 -or $inspection.manifestSha256 -cne $p.manifestSha256 -or
        $p.provenance.workflowPath -cne $s.buildWorkflowPath -or $p.provenance.buildJob -cne $s.buildJob -or
        $manifest.build.workflowPath -cne $p.provenance.workflowPath -or $manifest.build.job -cne $p.provenance.buildJob -or
        $manifest.build.runId -ne $p.provenance.runId -or $manifest.build.runAttempt -ne $p.provenance.runAttempt) { Stop-ClcError Clc.ApprovalMismatch }
    # Fixed field order makes identity independent of input JSON property order.
    $identity=[ordered]@{}
    foreach ($key in @('targetId','applicationId','releaseId','tag','sourceRepository','sourceCommit','releaseZipSha256','manifestSha256')) { $identity[$key]=$p[$key] }
    $identity.provenance=[ordered]@{}
    foreach ($key in @('workflowPath','runId','runAttempt','buildJob','artifactId','transportSha256')) { $identity.provenance[$key]=$p.provenance[$key] }
    $identity.lineageId=$s.lineageId; $identity.standingAuthorizationId=$StandingAuthorizationId; $identity.standingAuthorizationSha256=$standing.sha256
    $id='auto-'+(Get-ClcBytesHash ([Text.Encoding]::UTF8.GetBytes(($identity | ConvertTo-Json -Depth 8 -Compress)))).Substring(0,59)
    $a=[ordered]@{contractFamily='clc-file-iis-v1';schemaVersion=2L;recordKind='release-approval';approvalId=$id;targetId=$target.targetId;enabled=$true;
        applicationId=$p.applicationId;releaseId=$p.releaseId;sourceRepository=$p.sourceRepository;sourceCommit=$p.sourceCommit;
        lineageId=$s.lineageId;releaseSequence=$tag.releaseSequence;releaseZipSha256=$p.releaseZipSha256;manifestSha256=$p.manifestSha256;
        provenance=$p.provenance;authorization=$s.authorization;
        admission=@{standingAuthorizationId=$StandingAuthorizationId;standingAuthorizationSha256=$standing.sha256;tag=$ReleaseTag;verifiedReleaseSha256=$evidence.sha256}}
    $path=Join-Path $context.layout.approvalCatalogRoot ($id+'.json')
    $pending=Join-Path $context.layout.approvalCatalogRoot ('standing\'+$target.targetId+'.pending')
    if ([IO.File]::Exists($pending) -or [IO.Directory]::Exists($pending)) { Stop-ClcError Clc.AdmissionIncomplete }
    $bound=Read-ClcTagBinding $context $target $a
    $previous=Read-ClcApprovedManifest $Lock $current.release.approvalId
    Assert-ClcReleaseBinding $previous $current.release $current.approvalSnapshot
    if ($previous.approvalFile.record.schemaVersion -eq 2) { $null=Read-ClcTagBinding $context $target $previous.approvalFile.record -Required }
    Assert-ClcAutomatedOrdering $a $previous.approvalFile.record
    if ([IO.File]::Exists($path)) {
        if ($null -eq $bound) { Stop-ClcError Clc.AdmissionIncomplete }
        $existing=Read-ClcProtectedApproval $context $id
        if (-not (Test-ClcValueEqual $existing.record $a)) { Stop-ClcError Clc.ReleaseIdentityConflict }
        $null=Read-ClcAdmissionEvidence $context $target $a
        $retained=Open-ClcAutomationInput $Lock (Join-Path $target.artifactInboxRoot ($id+'.zip')) 1073741824
        if ($retained.sha256 -cne $a.releaseZipSha256) { Stop-ClcError Clc.AdmissionIncomplete }
        return Get-ClcAutomatedSelection $Lock $existing $input $manifest $bytes $inspection $standing
    }
    $encoded=[Text.Encoding]::UTF8.GetBytes(($a | ConvertTo-Json -Depth 24 -Compress))
    $null=Read-ClcJson $encoded release-approval
    Assert-ClcLockOwned $Lock
    Assert-ClcHeldRecordUnchanged $context $standing 'Clc.StandingAuthorizationRejected'
    Assert-ClcHeldRecordUnchanged $context $Lock.targetFile 'Clc.HostPreflightFailed'
    $destination=Join-Path $target.artifactInboxRoot ($id+'.zip')
    foreach ($item in @($path,$pending,$destination)) { Assert-ClcPathSpelling $item }
    # A create-new durable intent precedes catalog/inbox effects. Interrupted
    # admission retains this exact record and refuses automatic repair.
    $out=[IO.File]::Open($pending,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $out.Write($encoded); $out.Flush($true) } finally { $out.Dispose() }
    $evidencePath=Join-Path $context.layout.approvalCatalogRoot ('standing\'+$id+'.verified.json')
    Assert-ClcPathSpelling $evidencePath
    $out=[IO.File]::Open($evidencePath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $out.Write($evidenceBytes); $out.Flush($true) } finally { $out.Dispose() }
    $null=Read-ClcAdmissionEvidence $context $target $a
    if ($null -eq $bound) {
        $binding=Get-ClcTagBinding $context $target $a
        Assert-ClcPathSpelling $binding.path
        $bindingBytes=[Text.Encoding]::UTF8.GetBytes(($binding.record | ConvertTo-Json -Depth 8 -Compress))
        $null=Read-ClcJson $bindingBytes release-tag-binding
        $out=[IO.File]::Open($binding.path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try { $out.Write($bindingBytes); $out.Flush($true) } finally { $out.Dispose() }
        $null=Read-ClcTagBinding $context $target $a -Required
    }
    $out=[IO.File]::Open($destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try {
        $input.stream.Position=0
        $digest=Read-ClcStream $input.stream 1073741824 ([Diagnostics.Stopwatch]::StartNew()) -Destination $out
        $out.Flush($true)
        if ($digest.sha256 -cne $p.releaseZipSha256) { Stop-ClcError Clc.HashMismatch }
    } finally { $out.Dispose(); $input.stream.Position=0 }
    Assert-ClcTrustedContextUnchanged $context
    # Validate inherited structural protection before publishing executable authority.
    $null=Add-ClcProtectedPathPin $context $pending -RuntimeSid $target.runtimeIdentitySid
    # Release only the pending leaf handle for atomic rename; its ancestors stay pinned.
    $pin=$context.pathPins[$pending]; $pin.handle.Dispose(); $context.pathPins.Remove($pending)
    Publish-ClcAutomatedApproval $pending $path
    $saved=Read-ClcProtectedApproval $context $id
    if ($saved.sha256 -cne (Get-ClcBytesHash $encoded)) { Stop-ClcError Clc.StatePersistenceFailed }
    return Get-ClcAutomatedSelection $Lock $saved $input $manifest $bytes $inspection $standing
}

function Assert-ClcAutomatedRecoveryAuthority {
    param($Session,$Selected)
    if ($Selected.approvalFile.record.schemaVersion -ne 2) { return }
    if (-not $Session.ContainsKey('recoveryApprovalId') -or -not $Session.recoveryApprovalId) { Stop-ClcError Clc.RecoveryApprovalRequired }
    $manual=Read-ClcProtectedApproval $Session.lock.context $Session.recoveryApprovalId
    $a=$manual.record; $selected=$Selected.approvalFile.record
    if ($a.schemaVersion -ne 1 -or -not $a.enabled) { Stop-ClcError Clc.RecoveryApprovalRequired }
    foreach ($key in @('targetId','applicationId','releaseId','sourceRepository','sourceCommit','lineageId','releaseSequence','releaseZipSha256','manifestSha256','provenance')) {
        if (-not (Test-ClcValueEqual $a[$key] $selected[$key])) { Stop-ClcError Clc.ApprovalMismatch }
    }
    $Session.recoveryApproval=$manual
}

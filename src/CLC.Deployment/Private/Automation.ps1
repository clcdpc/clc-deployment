# Standing policy is infrastructure authority. A bundle and its predicate remain
# untrusted until the protected, byte-pinned verifier authenticates the signer.
$script:ClcAutomatedPredicateType='https://clcdpc.github.io/clc-deployment/attestations/release/v1'

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
    Assert-ClcObject $Value @('contractFamily','schemaVersion','recordKind','standingAuthorizationId','enabled','targetId','applicationId','environmentName','channel','sourceRepository','sourceRepositoryId','sourceOwnerId','producer','lineageId','verifier','authorization')
    foreach ($key in @('standingAuthorizationId','targetId','applicationId','lineageId')) { Assert-ClcId $Value[$key] }
    Assert-ClcBoolean $Value.enabled
    Assert-ClcText $Value.environmentName
    Assert-ClcEnum $Value.channel @('DEV','Production')
    Assert-ClcRepository $Value.sourceRepository
    foreach ($key in @('sourceRepositoryId','sourceOwnerId')) { Assert-ClcText $Value[$key] 20 '^[1-9][0-9]{0,19}$' }
    Assert-ClcObject $Value.producer @('repository','workflowPath','sourceCommit','buildWorkflowPath','buildJob')
    Assert-ClcRepository $Value.producer.repository
    foreach ($key in @('workflowPath','buildWorkflowPath')) { Assert-ClcWorkflow $Value.producer[$key] }
    Assert-ClcCommit $Value.producer.sourceCommit
    Assert-ClcCode $Value.producer.buildJob
    Assert-ClcObject $Value.verifier @('version','path','sha256','trustedRootPath','trustedRootSha256')
    Assert-ClcEnum $Value.verifier.version @('2.97.0')
    foreach ($key in @('path','trustedRootPath')) { Assert-ClcAbsolutePath $Value.verifier[$key] }
    foreach ($key in @('sha256','trustedRootSha256')) { Assert-ClcHash $Value.verifier[$key] }
    Assert-ClcObject $Value.authorization @('authoritySid','reference','approvedUtc')
    Assert-ClcSid $Value.authorization.authoritySid
    Assert-ClcCode $Value.authorization.reference
    Assert-ClcTimestamp $Value.authorization.approvedUtc
}

function Assert-ClcAutomatedProvenance {
    param($Value)
    Assert-ClcObject $Value @('contractFamily','schemaVersion','recordKind','targetId','applicationId','releaseId','tag','sourceRepository','sourceCommit','releaseZipSha256','manifestSha256','provenance')
    foreach ($key in @('targetId','applicationId','releaseId')) { Assert-ClcId $Value[$key] }
    $tag=Get-ClcDeploymentTag $Value.tag
    if ($Value.releaseId -cne $tag.releaseId) { Stop-ClcError Clc.ApprovalMismatch }
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
        $a.releaseId -cne $tag.releaseId -or $a.releaseSequence -ne $tag.releaseSequence -or $a.lineageId -cne $s.lineageId -or
        $a.sourceRepository -cne $s.sourceRepository -or $a.provenance.workflowPath -cne $s.producer.buildWorkflowPath -or
        $a.provenance.buildJob -cne $s.producer.buildJob) { Stop-ClcError Clc.StandingAuthorizationRejected }
    return $file
}

function Start-ClcAttestationVerifier {
    param([string] $Path,[string[]] $Arguments)
    return [Clc.Lifecycle.Native]::Attestation($Path,$Arguments)
}

function Get-ClcAttestationArguments {
    param($s,[string] $ArchivePath,[string] $BundlePath,$Manifest,[string] $Tag)
    return @('attestation','verify',$ArchivePath,'--bundle',$BundlePath,'--repo',$s.sourceRepository,
        '--hostname','github.com','--signer-workflow',($s.producer.repository+'/'+$s.producer.workflowPath),
        '--signer-digest',$s.producer.sourceCommit,'--source-ref',('refs/tags/'+$Tag),'--source-digest',$Manifest.source.commit,
        '--cert-oidc-issuer','https://token.actions.githubusercontent.com','--deny-self-hosted-runners',
        '--custom-trusted-root',$s.verifier.trustedRootPath,'--predicate-type',$script:ClcAutomatedPredicateType,
        '--format','json','--jq','[.[] | {predicate: .verificationResult.statement.predicate, certificate: .verificationResult.signature.certificate}]')
}

function ConvertFrom-ClcAttestationOutput {
    param([byte[]] $Bytes,$s,$Manifest,[string] $Tag)
    try {
        $options=[Text.Json.JsonDocumentOptions]::new(); $options.MaxDepth=32
        $document=[Text.Json.JsonDocument]::Parse([Text.UTF8Encoding]::new($false,$true).GetString($Bytes),$options)
        try { $values=ConvertFrom-ClcJsonElement $document.RootElement } finally { $document.Dispose() }
        if ($values -isnot [object[]] -or $values.Count -ne 1) { Stop-ClcError Clc.ProvenanceRejected }
        Assert-ClcObject $values[0] @('predicate','certificate')
        $p=$values[0].predicate; $c=$values[0].certificate
        # Certificate extensions come from GitHub OIDC, not the signed predicate.
        $ref='refs/tags/'+$Tag
        $expected=@{issuer='https://token.actions.githubusercontent.com';sourceRepositoryURI=('https://github.com/'+$s.sourceRepository);sourceRepositoryDigest=$Manifest.source.commit;
            sourceRepositoryRef=$ref;sourceRepositoryIdentifier=$s.sourceRepositoryId;sourceRepositoryOwnerIdentifier=$s.sourceOwnerId;
            buildSignerURI=('https://github.com/'+$s.producer.repository+'/'+$s.producer.workflowPath+'@'+$s.producer.sourceCommit);
            buildSignerDigest=$s.producer.sourceCommit;buildTrigger='push';runnerEnvironment='github-hosted';
            buildConfigURI=('https://github.com/'+$s.sourceRepository+'/'+$s.producer.buildWorkflowPath+'@'+$ref);
            runInvocationURI=('https://github.com/'+$s.sourceRepository+'/actions/runs/'+$p.provenance.runId+'/attempts/'+$p.provenance.runAttempt)}
        foreach ($key in $expected.Keys) { if ($c[$key] -isnot [string] -or $c[$key] -cne $expected[$key]) { Stop-ClcError Clc.ProvenanceRejected } }
        Assert-ClcRecord $p automated-provenance
        return $p
    } catch { Stop-ClcError Clc.ProvenanceRejected }
}

function Invoke-ClcAttestationVerification {
    param($Context,$Standing,$Archive,$Bundle,$Manifest,[string] $Tag)
    $s=$Standing.record
    foreach ($item in @(@{path=$s.verifier.path;sha256=$s.verifier.sha256;limit=268435456L},
            @{path=$s.verifier.trustedRootPath;sha256=$s.verifier.trustedRootSha256;limit=4194304L})) {
        $null=Add-ClcProtectedPathPin $Context $item.path -RuntimeSid $Archive.runtimeSid -SystemFile
        $parent=[IO.Path]::GetDirectoryName($item.path)
        $null=Add-ClcProtectedPathPin $Context $parent -Directory -SystemDirectory -RuntimeSid $Archive.runtimeSid
        Assert-ClcTrustAncestors $Context $item.path $Archive.runtimeSid
        $held=Read-ClcHeldFile $item.path $Context.handles $item.limit -NoCapture -SystemFile
        if ($held.sha256 -cne $item.sha256) { Stop-ClcError Clc.ProvenanceRejected }
    }
    $arguments=Get-ClcAttestationArguments $s $Archive.path $Bundle.path $Manifest $Tag
    $running=$null
    try {
        Assert-ClcHeldRecordUnchanged $Context $Standing 'Clc.StandingAuthorizationRejected'
        $running=Start-ClcAttestationVerifier $s.verifier.path $arguments
        $output=Complete-ClcHelperOutput $running
        if ($output.Failed) { Stop-ClcError Clc.ProvenanceRejected }
        return ConvertFrom-ClcAttestationOutput $output.Bytes $s $Manifest $Tag
    } catch { Stop-ClcError Clc.ProvenanceRejected }
    finally {
        if ($null -ne $running) {
            try {
                $identity=Get-ClcProcessIdentity $running.Process
                $null=Wait-ClcTrackedProcess $running.Process $identity.creationUtc 0 30000
            } finally { $running.Process.Dispose() }
        }
    }
}

function Open-ClcAutomationInput {
    param($Lock,[string] $Path,[long] $Limit,[switch] $Archive)
    $context=$Lock.context; $target=$Lock.targetFile.record; $policy=$context.policyFile.record
    Assert-ClcPathSpelling $Path
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

function New-ClcAutomatedApproval {
    param($Lock,[string] $StandingAuthorizationId,[string] $ReleaseTag)
    $decision=Get-ClcReconciliationDecision $Lock
    if ($decision.classification -cne 'Clean' -or $null -eq $Lock.state.current) { Stop-ClcError Clc.AutomationRequiresBaseline }
    $context=$Lock.context; $target=$Lock.targetFile.record
    $standing=Read-ClcStandingAuthorization $context $target $StandingAuthorizationId; $s=$standing.record
    $tag=Get-ClcDeploymentTag $ReleaseTag
    if ($tag.channel -cne $s.channel) { Stop-ClcError Clc.StandingAuthorizationRejected }
    $current=$Lock.state.current.record
    if ($current.approvalSnapshot.lineageId -cne $s.lineageId -or $tag.releaseSequence -lt $current.approvalSnapshot.releaseSequence) { Stop-ClcError Clc.DowngradeRejected }
    $null=Add-ClcProtectedPathPin $context $target.artifactInboxRoot -Directory -Mutable -RuntimeSid $target.runtimeIdentitySid
    $input=Open-ClcAutomationInput $Lock (Join-Path $target.artifactInboxRoot ($tag.releaseId+'.zip')) 1073741824 -Archive
    $bundle=Open-ClcAutomationInput $Lock (Join-Path $target.artifactInboxRoot ($tag.releaseId+'.sigstore.json')) 4194304
    $inspection=Test-ClcArchiveStream $input.stream ([Diagnostics.Stopwatch]::StartNew())
    $input.sha256=$inspection.archiveSha256
    $input.stream.Position=0
    $zip=[IO.Compression.ZipArchive]::new($input.stream,[IO.Compression.ZipArchiveMode]::Read,$true)
    try {
        $stream=$zip.GetEntry('manifest.json').Open()
        try { $bytes=(Read-ClcStream $stream 4194304 ([Diagnostics.Stopwatch]::StartNew()) -Capture).bytes } finally { $stream.Dispose() }
    } finally { $zip.Dispose(); $input.stream.Position=0 }
    $manifest=Read-ClcJson $bytes release-manifest
    $p=Invoke-ClcAttestationVerification $context $standing $input $bundle $manifest $ReleaseTag
    if ($p.targetId -cne $target.targetId -or $p.applicationId -cne $target.applicationId -or $p.tag -cne $ReleaseTag -or
        $p.releaseId -cne $tag.releaseId -or $manifest.releaseId -cne $p.releaseId -or $manifest.applicationId -cne $p.applicationId -or
        $p.sourceRepository -cne $s.sourceRepository -or $manifest.source.repository -cne $p.sourceRepository -or $manifest.source.commit -cne $p.sourceCommit -or
        $inspection.archiveSha256 -cne $p.releaseZipSha256 -or $inspection.manifestSha256 -cne $p.manifestSha256 -or
        $p.provenance.workflowPath -cne $s.producer.buildWorkflowPath -or $p.provenance.buildJob -cne $s.producer.buildJob -or
        $manifest.build.workflowPath -cne $p.provenance.workflowPath -or $manifest.build.job -cne $p.provenance.buildJob -or
        $manifest.build.runId -ne $p.provenance.runId -or $manifest.build.runAttempt -ne $p.provenance.runAttempt) { Stop-ClcError Clc.ApprovalMismatch }
    $id='auto-'+(Get-ClcBytesHash ([Text.Encoding]::UTF8.GetBytes($target.targetId+[char]0+$p.releaseId))).Substring(0,59)
    $a=[ordered]@{contractFamily='clc-file-iis-v1';schemaVersion=2L;recordKind='release-approval';approvalId=$id;targetId=$target.targetId;enabled=$true;
        applicationId=$p.applicationId;releaseId=$p.releaseId;sourceRepository=$p.sourceRepository;sourceCommit=$p.sourceCommit;
        lineageId=$s.lineageId;releaseSequence=$tag.releaseSequence;releaseZipSha256=$p.releaseZipSha256;manifestSha256=$p.manifestSha256;
        provenance=$p.provenance;authorization=$s.authorization;
        admission=@{standingAuthorizationId=$StandingAuthorizationId;standingAuthorizationSha256=$standing.sha256;tag=$ReleaseTag;bundleSha256=$bundle.sha256}}
    $path=Join-Path $context.layout.approvalCatalogRoot ($id+'.json')
    $pending=Join-Path $context.layout.approvalCatalogRoot ('standing\'+$target.targetId+'.pending')
    if ([IO.File]::Exists($pending) -or [IO.Directory]::Exists($pending)) { Stop-ClcError Clc.AdmissionIncomplete }
    if ([IO.File]::Exists($path)) {
        $existing=Read-ClcProtectedApproval $context $id
        if (-not (Test-ClcValueEqual $existing.record $a)) { Stop-ClcError Clc.ReleaseIdentityConflict }
        return Get-ClcAutomatedSelection $Lock $existing $input $manifest $bytes $inspection $standing
    }
    # Same-sequence identity must be the already installed exact release, not a
    # second approval name for different bytes or a differently scoped policy.
    if ($tag.releaseSequence -eq $current.approvalSnapshot.releaseSequence) { Stop-ClcError Clc.ReleaseIdentityConflict }
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
    [IO.File]::Move($pending,$path,$false)
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

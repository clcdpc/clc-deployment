# Infrastructure tooling, outside the public module. Authenticate this ENTIRE
# bootstrap (including adjacent helpers) independently before its first execution.
# Candidate archive code is never loaded to establish its own trust.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../Distribution.Common.ps1"
$script:HModuleRoot=Join-Path $PSScriptRoot '../../CLC.Deployment'
if (-not [IO.Directory]::Exists($script:HModuleRoot)) { throw 'Use the independently authenticated packaged bootstrap layout, not a source checkout.' }
$script:HModuleRoot=[IO.Path]::GetFullPath($script:HModuleRoot)
foreach ($helper in @('Contracts','Paths','Inventory','Hooks.Package','Archive','NativeProcess','Trust','Policy','Iis','TargetIdentity','Host','Lock','State','Journal','Files','Application','Hooks','IisLifecycle','Replacement','Deployment','Recovery','Automation')) {
    . (Join-Path $script:HModuleRoot ('Private/'+$helper+'.ps1'))
}
. "$PSScriptRoot/HostEnrollment.Iis.ps1"
. "$PSScriptRoot/HostEnrollment.Resources.ps1"

# These private helpers run in this infrastructure script's scope, never in the
# public module's session state. Its four exports and fixed layout are unchanged.
function Get-ClcInstalledLayout { return $script:HLayout }
function Get-ClcToolkitVersion { return $script:HVersion }
function Get-HAuthorityRoot {
    Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) 'CLC\Deployment\host-authorizations'
}
function Get-HCanonicalEnrollmentRoot {
    Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) 'CLC\Deployment\Enrollment'
}
function Get-HNow { [DateTimeOffset]::UtcNow }
function Test-HExists([string] $Path) { [IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path) }
function Get-HLayout([string] $EnrollmentRoot,[string] $Version) {
    $root=Join-Path $EnrollmentRoot 'toolkit'; $versionRoot=Join-Path $root ('versions\'+$Version)
    @{root=$root;versionRoot=$versionRoot;moduleRoot=(Join-Path $versionRoot 'CLC.Deployment');
        manifestPath=(Join-Path $versionRoot 'CLC.Deployment\CLC.Deployment.psd1');policyRoot=(Join-Path $root 'policy');policyPath=(Join-Path $root 'policy\host-policy.json');
        targetCatalogRoot=(Join-Path $root 'policy\targets');approvalCatalogRoot=(Join-Path $root 'policy\approvals');
        sourcePath=(Join-Path $versionRoot 'source.commit');distributionPath=(Join-Path $versionRoot 'distribution.zip');
        controlStateRoot=(Join-Path $EnrollmentRoot 'control');lockRoot=(Join-Path $EnrollmentRoot 'locks')}
}
function Read-HJson([byte[]] $Bytes) {
    if ($Bytes.Length -eq 0 -or $Bytes.Length -gt 4194304) { Stop-ClcError Clc.InvalidContract }
    $document=$null
    try {
        $options=[Text.Json.JsonDocumentOptions]::new();$options.MaxDepth=32
        $document=[Text.Json.JsonDocument]::Parse([Text.UTF8Encoding]::new($false,$true).GetString($Bytes),$options)
        return ,(ConvertFrom-ClcJsonElement $document.RootElement)
    } finally { if ($null -ne $document) { $document.Dispose() } }
}
function Assert-HHeader($Record,[string] $Kind) {
    if ($Record.contractFamily -cne 'clc-host-enrollment-v1' -or $Record.schemaVersion -isnot [long] -or $Record.schemaVersion -ne 1 -or $Record.recordKind -cne $Kind) { Stop-ClcError Clc.UnsupportedContract }
}
function Assert-HConfiguration($Value) {
    Assert-ClcObject $Value @('contractFamily','schemaVersion','recordKind','applicationId','targetId','environmentName','runtimeEnvironment','siteName','applicationPoolName','applicationRoot','operationalConfigPath','dataProtectionRoot','artifactInboxRoot','runtimeIdentitySid','readinessUri','runtimeAccountName','enrollmentRoot')
    Assert-HHeader $Value deployment-configuration
    $target=Get-HTarget $Value
    Assert-ClcRecord $target target
    Assert-ClcAbsolutePath $Value.enrollmentRoot
    Assert-ClcText $Value.runtimeAccountName 256 '^[^\x00-\x1f\x7f"/;]+$'
    if ([Uri]::CheckHostName(([uri]$Value.readinessUri).DnsSafeHost) -ne [UriHostNameType]::Dns) { Stop-ClcError Clc.InvalidContract }
}
function Get-HTarget($Configuration) {
    $target=[ordered]@{contractFamily='clc-file-iis-v1';schemaVersion=1L;recordKind='target'}
    foreach ($key in @('targetId','applicationId','environmentName','runtimeEnvironment','siteName','applicationPoolName','applicationRoot','operationalConfigPath','dataProtectionRoot','artifactInboxRoot','runtimeIdentitySid','readinessUri')) { $target[$key]=$Configuration[$key] }
    return ,$target
}
function Assert-HAuthorization($Value,[string] $Id) {
    Assert-ClcObject $Value @('contractFamily','schemaVersion','recordKind','authorizationId','enabled','approvedUtc','expiresUtc','authoritySid','reference','targetId','deploymentConfigurationSha256','enrollmentRoot','hostPolicy','bootstrap','permittedOperations','iis','resourceBindings','cutover')
    Assert-HHeader $Value host-enrollment-authorization
    Assert-ClcId $Value.authorizationId; Assert-ClcId $Value.targetId; Assert-ClcBoolean $Value.enabled
    Assert-ClcTimestamp $Value.approvedUtc; Assert-ClcTimestamp $Value.expiresUtc
    Assert-ClcSid $Value.authoritySid; Assert-ClcCode $Value.reference
    Assert-ClcHash $Value.deploymentConfigurationSha256; Assert-ClcAbsolutePath $Value.enrollmentRoot
    Assert-ClcRecord $Value.hostPolicy host-policy
    Assert-ClcObject $Value.bootstrap @('sourceCommit','inventorySha256')
    Assert-ClcCommit $Value.bootstrap.sourceCommit; Assert-ClcHash $Value.bootstrap.inventorySha256
    foreach ($required in @('S-1-5-18','S-1-5-32-544')) { if ($Value.hostPolicy.infrastructureOwnerSids -cnotcontains $required) { Stop-ClcError Clc.EnrollmentAuthorizationInvalid } }
    if ($Value.authorizationId -cne $Id -or $Value.hostPolicy.infrastructureOwnerSids -cnotcontains $Value.authoritySid -or
        $Value.hostPolicy.deploymentSids -ccontains $Value.authoritySid -or ([DateTimeOffset]$Value.expiresUtc) -le ([DateTimeOffset]$Value.approvedUtc)) { Stop-ClcError Clc.EnrollmentAuthorizationInvalid }
    if ($Value.permittedOperations -isnot [array] -or $Value.permittedOperations.Count -gt 6) { Stop-ClcError Clc.InvalidContract }
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($operation in $Value.permittedOperations) {
        Assert-ClcEnum $operation @('install-toolkit','enroll-target','configure-iis','create-site','create-pool','first-cutover')
        if (-not $seen.Add($operation)) { Stop-ClcError Clc.InvalidContract }
    }
    Assert-ClcObject $Value.iis @('bindingAddress','certificateThumbprint','newPoolIdentityType','expectedSnapshotSha256')
    Assert-ClcText $Value.iis.bindingAddress 64
    $address=$null; if (-not [Net.IPAddress]::TryParse($Value.iis.bindingAddress,[ref]$address)) { Stop-ClcError Clc.InvalidContract }
    Assert-ClcText $Value.iis.certificateThumbprint 40 '^[A-F0-9]{40}$'
    Assert-ClcEnum $Value.iis.newPoolIdentityType @('ExistingOnly','ManagedServiceAccount')
    Assert-ClcHash $Value.iis.expectedSnapshotSha256
    Assert-ClcObject $Value.resourceBindings @('applicationRoot','operationalConfigPath','dataProtectionRoot','artifactInboxRoot')
    foreach ($binding in $Value.resourceBindings.Values) {
        if ($null -ne $binding) {
            Assert-ClcObject $binding @('volumeId','fileId','canonicalPath','securityDescriptorSha256')
            Assert-ClcAbsolutePath $binding.canonicalPath; Assert-ClcText $binding.volumeId 49; Assert-ClcText $binding.fileId 16 '^[a-f0-9]{16}$'; Assert-ClcHash $binding.securityDescriptorSha256
        }
    }
    if ($null -ne $Value.cutover) {
        Assert-ClcObject $Value.cutover @('applicationRootIdentity','files','inventorySha256','backupRoot')
        Assert-ClcObject $Value.cutover.applicationRootIdentity @('volumeId','fileId','canonicalPath')
        Assert-ClcAbsolutePath $Value.cutover.applicationRootIdentity.canonicalPath
        Assert-ClcText $Value.cutover.applicationRootIdentity.volumeId 49; Assert-ClcText $Value.cutover.applicationRootIdentity.fileId 16 '^[a-f0-9]{16}$'
        Assert-DistInventory $Value.cutover.files; Assert-ClcHash $Value.cutover.inventorySha256; Assert-ClcAbsolutePath $Value.cutover.backupRoot
        if ((Get-DistInventoryHash $Value.cutover.files) -cne $Value.cutover.inventorySha256 -or $Value.permittedOperations -cnotcontains 'first-cutover') { Stop-ClcError Clc.EnrollmentAuthorizationInvalid }
    }
}
function Assert-HAuthorityProtection([string] $Path,$Handles,[switch] $Directory) {
    # This fixed, independently provisioned handoff is the first trust anchor.
    # No owner or writer allowlist is taken from the file being authenticated.
    $trusted=[string[]]@('S-1-5-18','S-1-5-32-544')
    $null=Get-ClcPathObservation $Path $Handles -Directory:$Directory
    $null=Assert-ClcAccess $Path $trusted $trusted @()
    $cursor=[IO.Path]::GetDirectoryName($Path)
    $trustedInstaller='S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
    while ($cursor) {
        $security=Get-ClcSecurityObservation $cursor
        if (@($trusted+$trustedInstaller) -cnotcontains $security.ownerSid) { Stop-ClcError Clc.EnrollmentAuthorizationInvalid }
        foreach ($ace in $security.dacl) {
            if ($ace.AceQualifier -eq [Security.AccessControl.AceQualifier]::AccessAllowed -and
                ($ace.AceFlags -band [Security.AccessControl.AceFlags]::InheritOnly) -eq 0 -and
                (([long]$ace.AccessMask -band 0x000D0040L) -ne 0 -or ([long]$ace.AccessMask -band 0xF0000000L) -ne 0) -and
                @($trusted+$trustedInstaller) -cnotcontains $ace.SecurityIdentifier.Value) { Stop-ClcError Clc.EnrollmentAuthorizationInvalid }
        }
        $cursor=[IO.Path]::GetDirectoryName($cursor)
    }
}
function Open-HSession([string] $ConfigurationPath,[string] $AuthorizationId) {
    $handles=[Collections.Generic.List[IDisposable]]::new()
    try {
        $authorityRoot=Get-HAuthorityRoot
        Assert-HAuthorityProtection $authorityRoot $handles -Directory
        $authorizationPath=Join-Path $authorityRoot ($AuthorizationId+'.json')
        Assert-HAuthorityProtection $authorizationPath $handles
        $authorizationFile=Read-ClcHeldFile $authorizationPath $handles
        $authorization=Read-HJson $authorizationFile.bytes; Assert-HAuthorization $authorization $AuthorizationId
        if ((Get-HBootstrapInventory) -cne $authorization.bootstrap.inventorySha256) { Stop-ClcError Clc.EnrollmentBootstrapMismatch }
        if ((Get-HBootstrapSourceCommit) -cne $authorization.bootstrap.sourceCommit) { Stop-ClcError Clc.EnrollmentBootstrapMismatch }
        Assert-ClcDeploymentToken $authorization.hostPolicy
        $null=Get-ClcMachineIdentity $authorization.hostPolicy.machineIdentity
        $configurationFile=Read-ClcHeldFile $ConfigurationPath $handles
        if ($configurationFile.sha256 -cne $authorization.deploymentConfigurationSha256) { Stop-ClcError Clc.EnrollmentAuthorizationMismatch }
        $configuration=Read-HJson $configurationFile.bytes; Assert-HConfiguration $configuration
        if ($configuration.targetId -cne $authorization.targetId -or $configuration.enrollmentRoot -cne $authorization.enrollmentRoot -or
            $configuration.enrollmentRoot -cne (Get-HCanonicalEnrollmentRoot)) { Stop-ClcError Clc.EnrollmentAuthorizationMismatch }
        $layout=Get-HLayout $configuration.enrollmentRoot $authorization.hostPolicy.activeToolkit.version
        foreach ($key in @('targetCatalogRoot','approvalCatalogRoot','controlStateRoot','lockRoot')) {
            if ($authorization.hostPolicy[$key] -cne $layout[$key]) { Stop-ClcError Clc.EnrollmentAuthorizationMismatch }
        }
        if ($authorization.hostPolicy.activeToolkit.moduleManifestPath -cne $layout.manifestPath) { Stop-ClcError Clc.EnrollmentAuthorizationMismatch }
        Assert-ClcStatePathBudget $authorization.hostPolicy
        $target=Get-HTarget $configuration
        $key=Get-ClcTargetKey $authorization.hostPolicy.machineIdentity $target.applicationPoolName.ToUpperInvariant()
        $session=@{handles=$handles;authorization=$authorization;authorizationFile=$authorizationFile;configuration=$configuration;configurationFile=$configurationFile;
            layout=$layout;target=$target;targetKey=$key;controlRoot=(Join-Path $layout.controlStateRoot $key);authorityRoot=$authorityRoot;
            context=$null;poolLock=$null;globalLock=$null;performed=$false;initialPoolState='Unknown';workerCount=$null;plan=$null;policyMatchesAuthorization=$false}
        Assert-HPathSeparation $session
        return $session
    } catch { foreach ($handle in $handles) { $handle.Dispose() }; throw }
}
function Assert-HSessionUnchanged($Session,[switch] $Mutation) {
    Assert-ClcDeploymentToken $Session.authorization.hostPolicy
    $null=Get-ClcMachineIdentity $Session.authorization.hostPolicy.machineIdentity
    foreach ($file in @($Session.authorizationFile,$Session.configurationFile)) {
        $file.stream.Position=0; $digest=Read-ClcStream $file.stream 4194304 ([Diagnostics.Stopwatch]::StartNew()); $file.stream.Position=0
        if ($digest.sha256 -cne $file.sha256) { Stop-ClcError Clc.EnrollmentAuthorizationMismatch }
    }
    if ($Mutation -and (-not $Session.authorization.enabled -or (Get-HNow) -ge ([DateTimeOffset]$Session.authorization.expiresUtc) -or (Get-HNow) -lt ([DateTimeOffset]$Session.authorization.approvedUtc))) { Stop-ClcError Clc.EnrollmentAuthorizationExpired }
}
function Assert-HOperation($Session,[string] $Operation) {
    Assert-HSessionUnchanged $Session -Mutation
    if ($Session.authorization.permittedOperations -cnotcontains $Operation) { Stop-ClcError Clc.EnrollmentOperationNotApproved }
}
function New-HResult($Session,[string] $State,[string] $Code,[string] $Action,[bool] $Toolkit=$false,[bool] $Target=$false) {
    $operations=@(); $resources=@()
    if ($State -cin @('ToolkitNotInitialized','TargetNotEnrolled')) {
        if ($State -ceq 'ToolkitNotInitialized') { $operations += 'install-toolkit'; $resources += 'toolkit','policy','approvals','control','locks' }
        $operations += 'enroll-target'; $resources += 'target-record','canonical-control-root'
        foreach ($name in @('applicationRoot','artifactInboxRoot','dataProtectionRoot')) { if (-not (Test-HExists $Session.target[$name])) { $resources += $name } }
        if ($null -ne $Session.plan) { $operations += $Session.plan.operations }
        if ($null -ne $Session.authorization.cutover) { $operations += 'first-cutover'; $resources += 'legacy-cutover-backup' }
    }
    [pscustomobject][ordered]@{contractFamily='clc-host-enrollment-v1';schemaVersion=1;recordKind='host-enrollment-result';HostState=$State;Code=$Code;NextAction=$Action;
        ToolkitInitialized=$Toolkit;TargetInitialized=$Target;InitializationPerformed=$Session.performed;TargetId=$Session.target.targetId;
        ActiveToolkitVersion=$(if ($Toolkit) {$Session.context.executingToolkit.version} else {$null});
        ActiveToolkitSourceCommit=$(if ($Toolkit) {$Session.context.executingToolkit.sourceCommit} else {$null});
        ReadyForDeployment=($State -ceq 'Ready');RequiresOperatorIntervention=($State -cin @('Incomplete','DriftDetected','RecoveryRequired'));
        ObservedPoolState=$Session.initialPoolState;WorkerCount=$Session.workerCount;ApplicationReleaseApproved=$false;ApplicationReadinessVerified=$false;
        PlannedOperations=@($operations);ResourceKindsToCreate=@($resources)}
}
function Open-HInstalledContext($Session) {
    $policyFile=Read-ClcHeldRecord $Session.layout.policyPath host-policy $Session.handles
    $policy=$policyFile.record
    $Session.policyMatchesAuthorization=Test-ClcValueEqual $policy $Session.authorization.hostPolicy
    # Authorization establishes the fixed shared installation, but is never an
    # implicit upgrade request. Reuse the actual protected active installation.
    foreach ($name in @('machineIdentity','targetCatalogRoot','approvalCatalogRoot','controlStateRoot','lockRoot','dotnetPath','appcmdPath','infrastructureOwnerSids','deploymentSids')) {
        if (-not (Test-ClcValueEqual $policy[$name] $Session.authorization.hostPolicy[$name])) { Stop-ClcError Clc.EnrollmentConfigurationDrift }
    }
    $script:HLayout=Get-HLayout $Session.configuration.enrollmentRoot $policy.activeToolkit.version
    $script:HVersion=$policy.activeToolkit.version
    if ($policy.activeToolkit.moduleManifestPath -cne $script:HLayout.manifestPath) { Stop-ClcError Clc.ToolkitNotActive }
    # Verify the entire distribution and installed bytes before any candidate import.
    $null=& "$PSScriptRoot/../Test-ToolkitDistribution.ps1" -ArchivePath $script:HLayout.distributionPath -ExpectedSha256 $policy.activeToolkit.distributionSha256 -ExpectedSourceCommit $policy.activeToolkit.sourceCommit -ExpectedVersion $policy.activeToolkit.version -InstalledModuleRoot $script:HLayout.moduleRoot
    $Session.layout=$script:HLayout
    $Session.context=Open-ClcTrustedContext
    Assert-ClcHelperDependencies $Session.context $Session.target.runtimeIdentitySid
    Assert-HActiveCompatibility $Session
}
function Assert-HActiveCompatibility($Session,$TargetFile=$null) {
    # The prospective/active policy and complete installed code have already
    # been independently authenticated and pinned by Open-HInstalledContext.
    Assert-ClcTrustedContextUnchanged $Session.context
    $active=Import-Module -Name $Session.context.layout.manifestPath -Force -Scope Local -PassThru
    & $active {
        param($Context,$Target,$TargetFile)
        foreach ($name in @('applicationRoot','operationalConfigPath','dataProtectionRoot','artifactInboxRoot')) {
            Assert-ClcPathSpelling $Target[$name]; Assert-ClcProtectedPath $Target[$name]
        }
        if ($null -ne $TargetFile) {
            $identity=Get-ClcTargetIdentity $Context $TargetFile
            $null=Get-ClcHostPreflight $Context $TargetFile $identity net10.0
        }
    } $Session.context $Session.target $TargetFile
}
function Get-HEnrollmentState($Session) {
    Assert-HSessionUnchanged $Session
    if (-not (Test-HExists $Session.layout.policyPath)) {
        Assert-HNoPriorIntent $Session
        foreach ($path in @($Session.layout.root,$Session.layout.controlStateRoot,$Session.layout.lockRoot)) {
            if (Test-HExists $path) { return New-HResult $Session Incomplete PartialToolkitInstallation ReconcileRetainedInfrastructure }
        }
        if (Test-HExists $Session.configuration.enrollmentRoot) {
            $null=Get-ClcPathObservation $Session.configuration.enrollmentRoot $Session.handles -Directory
            Assert-HResourceAccess $Session $Session.configuration.enrollmentRoot Protected
            if (@([IO.Directory]::EnumerateFileSystemEntries($Session.configuration.enrollmentRoot)).Count) { return New-HResult $Session Incomplete UnexpectedEnrollmentContents ReconcileRetainedInfrastructure }
        } else {
            $parent=[IO.Path]::GetDirectoryName($Session.configuration.enrollmentRoot)
            $null=Get-ClcPathObservation $parent $Session.handles -Directory
            Assert-HResourceAccess $Session $parent Protected
        }
        Assert-HInitialResources $Session
        $Session.plan=Get-HIisPlan $Session
        return New-HResult $Session ToolkitNotInitialized InstallationAuthorizationRequired PlanAuthorizedInitialization
    }
    if ($null -eq $Session.context) { Open-HInstalledContext $Session }
    Assert-HTargetCatalog $Session
    $targetPath=Join-Path $Session.layout.targetCatalogRoot ($Session.target.targetId+'.json')
    if (-not (Test-HExists $targetPath)) {
        if ((Test-HExists $Session.controlRoot) -or (Test-HExists (Join-Path $Session.layout.lockRoot ($Session.targetKey+'.lock')))) { return New-HResult $Session RecoveryRequired MissingTargetWithState ReconcileCanonicalPoolState $true }
        Assert-HNoPriorIntent $Session
        Assert-HInitialResources $Session
        $Session.plan=Get-HIisPlan $Session
        return New-HResult $Session TargetNotEnrolled EnrollmentAuthorizationRequired PlanAuthorizedInitialization $true
    }
    $targetFile=Read-ClcProtectedTarget $Session.context $Session.target.targetId
    if (-not (Test-ClcValueEqual $targetFile.record $Session.target)) { return New-HResult $Session DriftDetected ProtectedTargetMismatch ReconcileConfiguration $true $true }
    $identity=Get-ClcTargetIdentity $Session.context $targetFile
    $hostResult=Get-ClcHostPreflight $Session.context $targetFile $identity net10.0
    Assert-HActiveCompatibility $Session $targetFile
    $Session.initialPoolState=$hostResult.poolState; $Session.workerCount=$hostResult.workerCount
    Assert-HIisReady $Session
    $lock=Open-HReadLock $Session $targetFile $identity
    try {
        $decision=if ($null -eq $lock.stream) {@{classification='Clean'}} else {Get-ClcReconciliationDecision $lock}
        if ($decision.classification -cnotin @('Clean','EmptyRecoveryNeedsVerification')) { return New-HResult $Session RecoveryRequired UnresolvedDeploymentState UseExistingExplicitRecovery $true $true }
        if ($decision.classification -ceq 'EmptyRecoveryNeedsVerification') {
            $release=Read-ClcEmptyBaselineRelease $lock $lock.state.journal.record.candidate.approvalId
            if (-not (Get-ClcEmptyBaselineEligibility $lock $release).eligible) { return New-HResult $Session RecoveryRequired UnresolvedDeploymentState UseExistingExplicitRecovery $true $true }
        }
        if ($null -ne $lock.state.journal) { $null=Read-ClcLatestAttemptEvidence $lock $lock.state }
        if ($null -eq $lock.state.journal -and @([IO.Directory]::EnumerateFileSystemEntries($Session.target.applicationRoot)).Count) { return New-HResult $Session RecoveryRequired UnmanagedApplicationContent ReconcileRetainedInfrastructure $true $true }
        if ($null -ne $lock.state.current) {
            $selection=Read-ClcApprovedManifest $lock $lock.state.current.record.release.approvalId
            if (-not (Test-ClcValueEqual (Get-ClcReleaseIdentity $selection) $lock.state.current.record.release)) { Stop-ClcError Clc.ContentDrift }
            $null=Get-ClcTreeInventory $Session.target.applicationRoot $selection.manifest.files
        } elseif ($decision.classification -ceq 'Clean') {
            $null=Get-ClcTreeInventory $Session.target.applicationRoot -ExpectedFiles @()
        }
        Assert-HSessionUnchanged $Session
        return New-HResult $Session Ready VerifiedEnrollment InvokeSeparatelyApprovedRelease $true $true
    } finally { if ($null -ne $lock.stream) { $lock.stream.Dispose() }; $lock.closed=$true }
}
function Invoke-HEnrollment {
    [CmdletBinding()]
    param([string] $DeploymentConfigurationPath,[string] $AuthorizationId,[ValidateSet('Inspect','Plan','Apply')][string] $Operation,[string] $DistributionPath)
    $session=$null
    try {
        $session=Open-HSession $DeploymentConfigurationPath $AuthorizationId
        try { $state=Get-HEnrollmentState $session }
        catch {
            $code=($_.FullyQualifiedErrorId -split ',')[0]
            if ($code -cnotmatch '^Clc\.[A-Za-z]+$') { $code='Clc.EnrollmentVerificationFailed' }
            if ($Operation -ceq 'Apply') { throw }
            $stateName=if ($code -cin @('Clc.RecoveryRequired','Clc.EnrollmentPriorEvidence')) {'RecoveryRequired'} else {'DriftDetected'}
            return New-HResult $session $stateName $code ReconcileConfiguration ($null -ne $session.context)
        }
        if ($Operation -cne 'Apply' -or $state.ReadyForDeployment) { return $state }
        if ($state.HostState -cnotin @('ToolkitNotInitialized','TargetNotEnrolled')) { Stop-ClcError Clc.EnrollmentReconciliationRequired }
        Invoke-HApply $session $DistributionPath
        $result=Get-HEnrollmentState $session
        if (-not $result.ReadyForDeployment) { Stop-ClcError Clc.EnrollmentVerificationFailed }
        return $result
    } catch {
        $code=($_.FullyQualifiedErrorId -split ',')[0]
        if ($code -cnotmatch '^Clc\.[A-Za-z]+$') { $code='Clc.EnrollmentFailed' }
        $poolState=if ($null -ne $session) {$session.initialPoolState} else {'Unknown'}
        $workers=if ($null -ne $session) {$session.workerCount} else {$null}
        if ($null -ne $session -and $session.performed) {
            $poolState='Unknown';$workers=$null
            try {
                $observation=Get-HIisSnapshot $session
                if ($observation.poolExists) {$poolState=$observation.pool.state;$workers=$observation.pool.workers.Count}
            } catch {} # An unavailable observation is explicitly Unknown, never Stopped.
        }
        $failure=[pscustomobject]@{HostState='RecoveryRequired';ReadyForDeployment=$false;RequiresOperatorIntervention=$true;
            TargetId=$(if ($null -ne $session) {$session.target.targetId} else {$null});AuthorizationId=$AuthorizationId;
            InitializationPerformed=($null -ne $session -and $session.performed);ObservedPoolState=$poolState;WorkerCount=$workers;
            NextAction='RetainAuthorizationEvidenceAndResourcesForIndependentReconciliation'}
        $errorRecord=[Management.Automation.ErrorRecord]::new([IO.InvalidDataException]::new('Enrollment refused. Retain authorization evidence and all resources; independently reconcile prerequisites or partial effects. No application release was approved or invoked.'),$code,[Management.Automation.ErrorCategory]::InvalidData,$failure)
        $PSCmdlet.ThrowTerminatingError($errorRecord)
    } finally {
        if ($null -ne $session) {
            if ($null -ne $session.poolLock) { $session.poolLock.Dispose() }
            if ($null -ne $session.globalLock) { $session.globalLock.Dispose() }
            Close-ClcTrustedContext $session.context
            foreach ($handle in $session.handles) { $handle.Dispose() }
        }
    }
}

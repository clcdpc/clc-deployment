Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$script:QualificationRepository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. "$script:QualificationRepository/tools/Distribution.Common.ps1"

function Read-QConfiguration([string] $Path) {
    Assert-DistLocalPath $Path
    $bytes=[IO.File]::ReadAllBytes($Path); $configuration=Read-DistJson $bytes
    $schema=Join-Path $script:QualificationRepository 'tests/Qualification/Configuration/qualification.schema.json'
    if (-not (Test-Json -Json ([Text.Encoding]::UTF8.GetString($bytes)) -SchemaFile $schema -ErrorAction Stop)) { throw 'Invalid qualification configuration.' }
    if ($configuration.templateOnly -or -not $configuration.disposable -or $configuration.machineIdentity -ceq [guid]::Empty.ToString('D') -or $configuration.machineIdentity -ceq 'ffffffff-ffff-ffff-ffff-ffffffffffff') { throw 'A concrete disposable target is required.' }
    if ($configuration.siteName -cne ('clc-t4-'+$configuration.campaignId) -or $configuration.poolName -cne $configuration.siteName) { throw 'Test resource names must match the exact campaign.' }
    foreach ($name in @('ownedRoot','evidenceRoot','operationalConfigPath','dataProtectionRoot','artifactInboxRoot','applicationRoot')) { Assert-DistLocalPath $configuration[$name] }
    $root=$configuration.ownedRoot
    if ($root.Length -gt 58 -or $root.Length -lt 8 -or $root -imatch '^C:\\(Windows|Program Files|ProgramData)(\\|$)') { throw 'Use an explicit short test-only root.' }
    foreach ($name in @('applicationRoot','operationalConfigPath','dataProtectionRoot','artifactInboxRoot')) {
        if (-not $configuration[$name].StartsWith($root+'\',[StringComparison]::Ordinal)) { throw 'Test root escapes owned scope.' }
    }
    $paths=@($configuration.applicationRoot,[IO.Path]::GetDirectoryName($configuration.operationalConfigPath),$configuration.dataProtectionRoot,$configuration.artifactInboxRoot,(Join-Path $root 'toolkit'),(Join-Path $root 'control'),(Join-Path $root 'locks'),$configuration.evidenceRoot)
    for ($i=0;$i -lt $paths.Count;$i++) { for ($j=$i+1;$j -lt $paths.Count;$j++) {
        if ($paths[$i].Equals($paths[$j],[StringComparison]::OrdinalIgnoreCase) -or $paths[$i].StartsWith($paths[$j]+'\',[StringComparison]::OrdinalIgnoreCase) -or $paths[$j].StartsWith($paths[$i]+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Qualification roots overlap.' }
    } }
    if ($configuration.evidenceRoot.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Retain evidence outside removable owned resources.' }
    $ids=@($configuration.infrastructureSid,$configuration.deploymentSid,$configuration.runtimeSid)
    if (@($ids | Select-Object -Unique).Count -ne 3) { throw 'Independent identities are required.' }
    $uri=[uri]$configuration.readinessUri
    if ($uri.Scheme -cne 'https' -or $uri.AbsolutePath -cne '/health/ready' -or $uri.Query -or $uri.Fragment -or $uri.UserInfo) { throw 'Invalid readiness binding.' }
    $configuration['_sha256']=Get-DistHash $bytes
    $configuration['_path']=$Path
    $configuration
}
function Get-QCallerSid {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    try { $identity.User.Value } finally { $identity.Dispose() }
}
function Get-QTokenObservation {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        @{actualSid=$identity.User.Value;
          administratorSidPresent=(@($identity.Groups | ForEach-Object Value) -ccontains 'S-1-5-32-544');
          administratorRoleEnabled=[Security.Principal.WindowsPrincipal]::new($identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)}
    } finally { $identity.Dispose() }
}
function Assert-QRoleToken($Configuration,[ValidateSet('Deployment','Runtime','Infrastructure')][string] $Role) {
    $expected=switch ($Role) { Deployment {$Configuration.deploymentSid}; Runtime {$Configuration.runtimeSid}; Infrastructure {$Configuration.infrastructureSid} }
    $token=Get-QTokenObservation
    if (@($Configuration.infrastructureSid,$Configuration.deploymentSid,$Configuration.runtimeSid | Select-Object -Unique).Count -ne 3 -or $token.actualSid -cne $expected) { throw 'The distinct selected actual logon token is required.' }
    if ($Role -ceq 'Runtime') {
        if ($token.administratorSidPresent -or $token.administratorRoleEnabled) { throw 'Runtime must be nonadministrator, including filtered administrator tokens.' }
    } elseif (-not $token.administratorRoleEnabled) { throw 'An enabled elevated local administrator token is required; the harness never elevates itself.' }
    $token
}
function Get-QInfrastructureSids($Configuration) {
    $trustedInstaller=[Security.Principal.NTAccount]::new('NT SERVICE\TrustedInstaller').Translate([Security.Principal.SecurityIdentifier]).Value
    return ,([string[]]@($Configuration.infrastructureSid,'S-1-5-18','S-1-5-32-544',$trustedInstaller))
}
function Assert-QReadinessAddresses([Net.IPAddress[]] $Addresses) {
    if ($Addresses.Count -eq 0 -or @($Addresses | Where-Object { $_.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $_.ToString() -cne '127.0.0.1' }).Count -ne 0) { throw 'Disposable readiness must resolve exclusively to the owned 127.0.0.1 binding.' }
}
function Assert-QReadinessNetwork($Configuration) {
    $task=[Net.Dns]::GetHostAddressesAsync(([uri]$Configuration.readinessUri).DnsSafeHost)
    if (-not $task.Wait(5000)) { throw 'Readiness name resolution exceeded its bound.' }
    Assert-QReadinessAddresses @($task.GetAwaiter().GetResult())
}
function Assert-QMachine($Configuration) {
    if (-not $IsWindows -or -not [Environment]::Is64BitProcess -or $PSVersionTable.PSVersion.Major -ne 7) { throw 'Requires Windows x64 and PowerShell 7.' }
    $os=@(Get-CimInstance Win32_OperatingSystem -Property BuildNumber,ProductType -OperationTimeoutSec 10)
    $machine=@(Get-CimInstance Win32_ComputerSystemProduct -Property UUID -OperationTimeoutSec 10)
    if ($os.Count -ne 1 -or $os[0].BuildNumber -cne '20348' -or $os[0].ProductType -notin @(2,3) -or $machine.Count -ne 1 -or
        ([guid]$machine[0].UUID).ToString('D') -cne $Configuration.machineIdentity -or [Environment]::MachineName -ine $Configuration.computerName) { throw 'The exact designated disposable Server 2022 host is required.' }
}
function Assert-QProtectedAuthorization([string] $Path, $Configuration) {
    Assert-DistLocalPath $Path
    $trustedInstaller=[Security.Principal.NTAccount]::new('NT SERVICE\TrustedInstaller').Translate([Security.Principal.SecurityIdentifier]).Value
    $allowed=@($Configuration.infrastructureSid,'S-1-5-18','S-1-5-32-544',$trustedInstaller)
    $cursor=$Path; $leaf=$true
    while ($cursor) {
        $acl=Get-Acl -LiteralPath $cursor
        $owner=$acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
        if ($allowed -cnotcontains $owner) { throw 'Authorization ownership is not independent.' }
        $mask=if ($leaf) {0x000D0156L} else {0x000D0040L}
        foreach ($ace in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
            if ($ace.AccessControlType -eq 'Allow' -and ($leaf -or ($ace.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -eq 0) -and
                ([long]$ace.FileSystemRights -band $mask) -ne 0 -and $allowed -cnotcontains $ace.IdentityReference.Value) { throw 'Authorization or ancestor is writable outside infrastructure.' }
        }
        $cursor=[IO.Path]::GetDirectoryName($cursor); $leaf=$false
    }
}
function Assert-QAuthorization($Configuration, [string] $AuthorizationPath, [string[]] $Permissions) {
    Assert-QMachine $Configuration
    if (-not $AuthorizationPath) { throw 'Mutating qualification requires an independent operator authorization record.' }
    Assert-QProtectedAuthorization $AuthorizationPath $Configuration
    $authorization=Read-DistJson ([IO.File]::ReadAllBytes($AuthorizationPath))
    Assert-DistFields $authorization @('formatVersion','configurationSha256','reference','machineIdentity','computerName','campaignId','grantedBySid','expiresUtc','permissions','isolationConfirmed','cleanupRetainsEvidence')
    if ($authorization.formatVersion -ne 1 -or $authorization.configurationSha256 -cne $Configuration._sha256 -or $authorization.reference -cne $Configuration.authorizationReference -or
        $authorization.machineIdentity -cne $Configuration.machineIdentity -or $authorization.computerName -ine $Configuration.computerName -or
        $authorization.campaignId -cne $Configuration.campaignId -or $authorization.grantedBySid -cne $Configuration.infrastructureSid -or
        $authorization.isolationConfirmed -isnot [bool] -or -not $authorization.isolationConfirmed -or $authorization.cleanupRetainsEvidence -isnot [bool] -or -not $authorization.cleanupRetainsEvidence -or
        [DateTimeOffset]::Parse($authorization.expiresUtc) -le [DateTimeOffset]::UtcNow -or
        [DateTimeOffset]::Parse($authorization.expiresUtc) -gt [DateTimeOffset]::UtcNow.AddDays(7)) { throw 'Authorization does not cover this exact campaign/configuration and time.' }
    foreach ($permission in $Permissions) { if ($authorization.permissions -cnotcontains $permission) { throw 'Authorization omits a required infrastructure action.' } }
    $authorization
}
function Get-QTargetKey($Configuration) {
    Get-DistHash ([Text.Encoding]::UTF8.GetBytes($Configuration.machineIdentity+[char]0+$Configuration.poolName.ToUpperInvariant()))
}
function Get-QControlRoot($Configuration) { Join-Path (Join-Path $Configuration.ownedRoot 'control') (Get-QTargetKey $Configuration) }
function Get-QInstalledManifest($Configuration) { Join-Path $Configuration.ownedRoot ('toolkit\versions\'+$Configuration.toolkit.version+'\CLC.Deployment\CLC.Deployment.psd1') }
function Import-QVerifiedToolkit($Configuration) {
    $manifest=Get-QInstalledManifest $Configuration; $versionRoot=[IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($manifest))
    $verified=& "$script:QualificationRepository/tools/Test-ToolkitDistribution.ps1" -ArchivePath (Join-Path $versionRoot 'distribution.zip') -ExpectedSha256 $Configuration.toolkit.distributionSha256 -ExpectedSourceCommit $Configuration.toolkit.sourceCommit -ExpectedVersion $Configuration.toolkit.version -InstalledModuleRoot ([IO.Path]::GetDirectoryName($manifest))
    if ($verified.inventorySha256 -cne $Configuration.toolkit.inventorySha256) { throw 'Installed candidate differs from campaign pin.' }
    Import-Module $manifest -Force
    $exports=@((Get-Module CLC.Deployment).ExportedFunctions.Keys | Sort-Object)
    if (($exports -join ',') -cne 'Invoke-ClcIisDeployment,New-ClcRelease,Restore-ClcIisDeployment,Test-ClcRelease') { throw 'Unexpected module export surface.' }
}
function Invoke-QPrivate([string] $Name, [object[]] $Arguments=@()) {
    # All call sites are fixed read-only observations. JSON cannot choose Name.
    & (Get-Module CLC.Deployment) { param($N,$A) & $N @A } $Name $Arguments
}
function Read-QOwnership($Configuration) {
    $path=Join-Path $Configuration.ownedRoot '.clc-t4-owner.json'
    Assert-QProtectedAuthorization $path $Configuration
    $marker=Read-DistJson ([IO.File]::ReadAllBytes($path))
    Assert-DistFields $marker @('formatVersion','campaignId','configurationSha256','machineIdentity','ownedRoot','siteName','poolName','createdBySid','rootIdentity','ownedRootIdentities','iisOwnership')
    if ($marker.formatVersion -ne 1 -or $marker.campaignId -cne $Configuration.campaignId -or $marker.configurationSha256 -cne $Configuration._sha256 -or
        $marker.machineIdentity -cne $Configuration.machineIdentity -or $marker.ownedRoot -cne $Configuration.ownedRoot -or $marker.siteName -cne $Configuration.siteName -or $marker.poolName -cne $Configuration.poolName -or $marker.createdBySid -cne $Configuration.infrastructureSid) { throw 'Campaign ownership does not match.' }
    if ((Get-DistPathFacts $Configuration.ownedRoot -Directory).Identity -cne $marker.rootIdentity) { throw 'Owned root physical identity changed.' }
    $marker
}
function Write-QJson([string] $Path, $Value) {
    Assert-DistLocalPath $Path
    $bytes=[Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 24 -Compress))
    if ($bytes.Length -gt 4194304) { throw 'Evidence exceeds bound.' }
    $file=[IO.FileStream]::new($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try { $file.Write($bytes); $file.Flush($true) } finally { $file.Dispose() }
}
function Get-QEvidenceInventory([string] $Root) {
    $null=Get-DistPathFacts $Root -Directory
    $files=[Collections.Generic.List[object]]::new(); $queue=[Collections.Generic.Queue[string]]::new(); $queue.Enqueue($Root); $entries=0
    while ($queue.Count) {
        foreach ($path in [IO.Directory]::EnumerateFileSystemEntries($queue.Dequeue())) {
            $entries++; if ($entries -gt 20000) { throw 'Evidence inventory exceeds its bound.' }
            $directory=([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::Directory) -ne 0
            $null=Get-DistPathFacts $path -Directory:$directory
            if ($directory) { $queue.Enqueue($path); continue }
            $relative=$path.Substring($Root.Length+1).Replace('\','/'); Assert-DistName $relative
            if ($relative -ceq 'operator-review.json') { continue }
            $files.Add(@{path=$relative;length=[long][IO.FileInfo]::new($path).Length;sha256=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()})
        }
    }
    $ordered=Sort-DistFiles $files.ToArray(); Assert-DistInventory $ordered; return ,$ordered
}
function Resolve-QArchivedEvidencePath([string] $ClaimedPath,$Review,[string] $ArchiveRoot) {
    Assert-DistLocalPath $ClaimedPath
    if (-not $ClaimedPath.StartsWith($Review.sourceRoot+'\',[StringComparison]::Ordinal)) { throw 'Primary evidence escapes its reviewed source root.' }
    $path=Join-Path $ArchiveRoot $ClaimedPath.Substring($Review.sourceRoot.Length+1)
    $null=Get-DistPathFacts $path
    $path
}
function Confirm-QCandidateEvidence($Candidate,$Definition,$Review,[string] $ArchiveRoot) {
    if ($Candidate.status -ceq 'NOT RUN') { return }
    if ($Candidate.sourceCommit -cne $Review.sourceCommit -or $Candidate.installedDistributionSha256 -cne $Review.distributionSha256 -or $Candidate.environmentFingerprint -cnotmatch '^[a-f0-9]{64}$') { throw 'Candidate evidence pin/environment differs.' }
    if ($null -eq $Candidate.actual -or -not $Candidate.actual.Contains('evidenceKind')) { throw 'Execution evidence kind is missing.' }
    if ($Candidate.actual.evidenceKind -ceq 'Automatic') {
        if ($Definition.action -cin @('Operator','Security','Transport')) { throw 'This operator-controlled case cannot be promoted as an automatic execution.' }
        $claimed=Join-Path $Candidate.supportingEvidencePath 'scenario-result.json'
        $path=Resolve-QArchivedEvidencePath $claimed $Review $ArchiveRoot
        if ($Candidate.supportingEvidenceSha256 -cnotmatch '^[a-f0-9]{64}$' -or (Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() -cne $Candidate.supportingEvidenceSha256) { throw 'Automatic case receipt is missing or changed.' }
        $receipt=Read-DistJson (Read-DistFileBytes $path)
        foreach ($name in @('scenarioId','status','sourceCommit','installedDistributionSha256','environmentFingerprint')) { if ($receipt[$name] -cne $Candidate[$name]) { throw 'Automatic case receipt is not bound to its report.' } }
        if ($Candidate.evidenceArtifacts.Count -lt 1) { throw 'Automatic primary artifacts are missing.' }
        $artifacts=$Candidate.evidenceArtifacts
    } elseif ($Candidate.actual.evidenceKind -ceq 'OperatorObserved') {
        if ($Definition.action -cnotin @('Operator','Security','Transport') -or $Candidate.actual.observerSid -cne $Review.approvedBySid -or $Candidate.actual.artifacts.Count -lt 1) { throw 'Operator observation has no matching independent observer/primary evidence.' }
        $artifacts=$Candidate.actual.artifacts
    } else { throw 'Unsupported execution evidence kind.' }
    foreach ($artifact in $artifacts) {
        Assert-DistFields $artifact @('path','sha256')
        $path=Resolve-QArchivedEvidencePath $artifact.path $Review $ArchiveRoot
        if ($artifact.sha256 -cnotmatch '^[a-f0-9]{64}$' -or (Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() -cne $artifact.sha256) { throw 'Primary evidence bytes differ from the reviewed record.' }
    }
}
function Read-QReviewedReport([string] $ReportPath,$Configuration) {
    if (-not $ReportPath.StartsWith((Join-Path $Configuration.evidenceRoot 'operator-evidence')+'\',[StringComparison]::Ordinal)) { throw 'Reviewed reports must reside in the protected campaign evidence archive.' }
    $archiveRoot=[IO.Path]::GetDirectoryName($ReportPath); $reviewPath=Join-Path $archiveRoot 'operator-review.json'
    Assert-QProtectedAuthorization $ReportPath $Configuration
    Assert-QProtectedAuthorization $reviewPath $Configuration
    $null=Get-DistPathFacts $reviewPath
    $review=Read-DistJson (Read-DistFileBytes $reviewPath)
    Assert-DistFields $review @('formatVersion','recordKind','campaignId','configurationSha256','sourceCommit','distributionSha256','approvedBySid','reference','sourceRoot','reportName','reportSha256','rootIdentity','files','inventorySha256','reviewedUtc')
    if ($review.formatVersion -ne 1 -or $review.recordKind -cne 'qualification-evidence-review' -or $review.campaignId -cne $Configuration.campaignId -or $review.configurationSha256 -cne $Configuration._sha256 -or
        $review.sourceCommit -cne $Configuration.toolkit.sourceCommit -or $review.distributionSha256 -cne $Configuration.toolkit.distributionSha256 -or $review.approvedBySid -cne $Configuration.infrastructureSid -or
        $review.reference -cne $Configuration.authorizationReference -or $review.reportName -cne [IO.Path]::GetFileName($ReportPath) -or $review.rootIdentity -cne (Get-DistPathFacts $archiveRoot -Directory).Identity) { throw 'Independent evidence review does not bind this exact campaign/report.' }
    $inventory=Get-QEvidenceInventory $archiveRoot
    Assert-DistInventory $review.files
    if ((Get-DistInventoryHash $inventory) -cne $review.inventorySha256 -or (Get-DistInventoryHash $review.files) -cne $review.inventorySha256 -or (Get-FileHash -LiteralPath $ReportPath).Hash.ToLowerInvariant() -cne $review.reportSha256) { throw 'Reviewed evidence inventory/report changed.' }
    @{review=$review;document=(Read-DistJson (Read-DistFileBytes $ReportPath));archiveRoot=$archiveRoot}
}
function Select-QReportCampaign([string] $ReportPath,[object[]] $Configurations) {
    Assert-DistLocalPath $ReportPath
    $matches=@($Configurations | Where-Object { $ReportPath.StartsWith((Join-Path $_.evidenceRoot 'operator-evidence')+'\',[StringComparison]::Ordinal) })
    if ($matches.Count -ne 1) { throw 'Report must select exactly one independently authorized campaign archive.' }
    $matches[0]
}
function Get-QPoolObservation($Configuration) {
    Invoke-QPrivate Get-ClcIisObservation @($script:QContext,$script:QTarget)
}
function Get-QSnapshot($Configuration) {
    $pool=Get-QPoolObservation $Configuration
    $stateRoot=Get-QControlRoot $Configuration; $records=[ordered]@{}
    foreach ($name in @('journal','current')) {
        $path=Join-Path $stateRoot ($name+'.json')
        if ([IO.File]::Exists($path)) {
            $bytes=[IO.File]::ReadAllBytes($path); $record=Read-DistJson $bytes
            $projection=if ($name -ceq 'journal') { @{attemptId=$record.attemptId;phase=$record.phase;outcome=$record.outcome;intent=$record.intent;observation=$record.observation;nativeCall=$record.nativeCall;backup=$record.backup;publishedGeneration=$record.publishedGeneration;recovery=$record.recovery} }
                else { @{generation=$record.generation;attemptId=$record.attemptId;release=$record.release;readiness=$record.readiness} }
            $records[$name]=@{sha256=(Get-DistHash $bytes);safe=$projection}
        } else { $records[$name]=$null }
    }
    $inventory=[Collections.Generic.List[object]]::new()
    foreach ($file in Get-ChildItem -LiteralPath $Configuration.applicationRoot -File -Recurse -Force) {
        Assert-DistLocalPath $file.FullName
        if ($inventory.Count -ge 20000) { throw 'Application inventory exceeds bound.' }
        $inventory.Add(@{path=$file.FullName.Substring($Configuration.applicationRoot.Length+1).Replace('\','/');length=[long]$file.Length;sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()})
    }
    @{poolState=$pool.poolState;workerCount=$pool.workers.Count;workers=$pool.workers;state=$records;applicationFiles=$inventory.ToArray();applicationInventorySha256=(Get-DistInventoryHash $inventory.ToArray())}
}
function Get-QPreflight($Configuration) {
    Assert-QMachine $Configuration
    Assert-QReadinessNetwork $Configuration
    $deploymentToken=Assert-QRoleToken $Configuration Deployment
    $null=Read-QOwnership $Configuration
    Import-QVerifiedToolkit $Configuration
    $context=Invoke-QPrivate Open-ClcTrustedContext
    try {
        $targetFile=Invoke-QPrivate Read-ClcProtectedTarget @($context,$Configuration.targetId)
        foreach ($name in @('applicationRoot','operationalConfigPath','dataProtectionRoot','artifactInboxRoot','siteName','readinessUri','runtimeEnvironment')) {
            if ($targetFile.record[$name] -cne $Configuration[$name]) { throw 'Protected target differs from selected campaign scope.' }
        }
        if ($targetFile.record.applicationPoolName -cne $Configuration.poolName -or $targetFile.record.runtimeIdentitySid -cne $Configuration.runtimeSid -or $targetFile.record.applicationId -cne 'clc-qualification-probe') { throw 'Protected application identity differs.' }
        $identity=Invoke-QPrivate Get-ClcTargetIdentity @($context,$targetFile)
        if ($identity.targetKey -cne (Get-QTargetKey $Configuration)) { throw 'Canonical target differs.' }
        $facts=Invoke-QPrivate Get-ClcHostPreflight @($context,$targetFile,$identity,'net10.0')
        $iis=Invoke-QPrivate Get-ClcIisObservation @($context,$targetFile.record)
        $uri=[uri]$Configuration.readinessUri
        if ($iis.bindings.Count -ne 1 -or $iis.bindings[0].protocol -cne 'https' -or $iis.bindings[0].address -cne '127.0.0.1' -or $iis.bindings[0].port -ne $uri.Port -or $iis.bindings[0].host -ine $uri.DnsSafeHost) { throw 'The exact owned loopback HTTPS binding is required.' }
        $runtime=Invoke-QPrivate Get-ClcRuntimeObservation @($context,$iis.ancmPath,$Configuration.runtimeSid)
        $os=Get-CimInstance Win32_OperatingSystem -Property Caption,Version,BuildNumber -OperationTimeoutSec 10
        $volume=Get-Volume -DriveLetter $Configuration.ownedRoot.Substring(0,1)
        if ($volume.FileSystem -cne 'NTFS') { throw 'NTFS is required.' }
        $required=[long]$Configuration.capacityBytes
        if ($volume.SizeRemaining -lt $required) { throw 'Insufficient qualified retention capacity.' }
        $certificate=Get-Item -LiteralPath ('Cert:\LocalMachine\My\'+$Configuration.certificateThumbprint)
        # Certificate metadata is public; private key objects are never exported.
        $certificateFacts=@{thumbprint=$certificate.Thumbprint;notBefore=$certificate.NotBefore.ToUniversalTime().ToString('o');notAfter=$certificate.NotAfter.ToUniversalTime().ToString('o');hasPrivateKey=$certificate.HasPrivateKey}
        $assembly=Invoke-QPrivate Get-ClcMwaAssemblyObservation
        $manager=Invoke-QPrivate New-ClcMwaServerManager @($assembly.type)
        try {
            $actualPool=$manager.ApplicationPools[$Configuration.poolName]; $actualSite=$manager.Sites[$Configuration.siteName]
            $profile=@{loadUserProfile=[bool]$actualPool.ProcessModel.LoadUserProfile;idleTimeoutSeconds=$actualPool.ProcessModel.IdleTimeout.TotalSeconds;startMode=$actualPool.StartMode.ToString()}
            $tls=@($actualSite.Bindings | Where-Object Protocol -CEQ 'https' | ForEach-Object { @{host=$_.Host;port=$_.EndPoint.Port;certificateThumbprint=[Convert]::ToHexString($_.CertificateHash);certificateStore=$_.CertificateStoreName;sslFlags=$_.SslFlags.ToString()} })
        } finally { $manager.Dispose() }
        $workerIdentities=@()
        foreach ($workerId in $iis.workers) {
            $process=Get-CimInstance Win32_Process -Filter ('ProcessId='+[long]$workerId) -OperationTimeoutSec 10
            $owner=Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid -OperationTimeoutSec 10
            if ($owner.ReturnValue -ne 0 -or $owner.Sid -cne $Configuration.runtimeSid) { throw 'Actual IIS worker token owner differs or is inaccessible.' }
            $workerIdentities += @{processId=[long]$workerId;runtimeSid=$owner.Sid;creationUtc=$process.CreationDate.ToUniversalTime().ToString('o')}
        }
        $ancm=[Diagnostics.FileVersionInfo]::GetVersionInfo($iis.ancmPath)
        @{qualified=$false;securityModel='ElevatedV1';deploymentToken=$deploymentToken;approvalSeparation='Procedural; administrator containment unavailable';runtimeIsolation='Required';machineIdentity=$Configuration.machineIdentity;computerName=$Configuration.computerName;
            os=@{caption=$os.Caption;version=$os.Version;build=$os.BuildNumber};powershell=$PSVersionTable.PSVersion.ToString();frameworks=$runtime.frameworks;
            ancmVersion=$ancm.FileVersion;targetKey=$identity.targetKey;targetSnapshot=$identity.snapshot;poolState=$facts.poolState;workerCount=$facts.workerCount;
            maxProcesses=$iis.maxProcesses;disallowOverlappingRotation=$iis.disallowOverlappingRotation;runtimeSid=$iis.runtimeSid;bindings=$iis.bindings;profile=$profile;tls=$tls;workerIdentities=$workerIdentities;
            toolkit=$context.executingToolkit;policyOwner=(Get-Acl -LiteralPath $context.layout.policyPath).GetOwner([Security.Principal.SecurityIdentifier]).Value;
            certificate=$certificateFacts;storage=@{fileSystem=$volume.FileSystem;size=[long]$volume.Size;available=[long]$volume.SizeRemaining;required=$required};hostObservationSha256=$facts.hostObservationSha256}
    } finally { Invoke-QPrivate Close-ClcTrustedContext @($context) }
}
function Get-QScenarioDefinitions {
    $path=Join-Path $script:QualificationRepository 'tests/Qualification/Scenarios/matrix.json'
    $definitions=Read-DistJson ([IO.File]::ReadAllBytes($path))
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $actions=@('Deploy','Upgrade','NoOp','ConfigurationRestart','RejectSameRevision','Drift','Recovery','Idle','Dpapi','Security','Transport','Performance','Operator')
    foreach ($case in $definitions) {
        Assert-DistFields $case @('id','area','action','variant','initialState','mandatory','expected','procedure','walkthrough')
        if ($case.id -cnotmatch '^[a-z][a-z0-9-]{1,95}$' -or -not $seen.Add($case.id) -or $actions -cnotcontains $case.action -or $case.initialState -cnotin @('Started','Stopped','Either') -or $case.mandatory -isnot [bool]) { throw 'Invalid qualification scenario definition.' }
    }
    return ,$definitions
}
function New-QResult($Definition, [string] $RunId, $Configuration=$null) {
    [ordered]@{scenarioId=$Definition.id;runId=$RunId;sourceCommit=$(if ($null -eq $Configuration) {$null} else {$Configuration.toolkit.sourceCommit});
        installedDistributionSha256=$(if ($null -eq $Configuration) {$null} else {$Configuration.toolkit.distributionSha256});probeReleases=@();environmentFingerprint=$null;
        initialPoolState=$null;expected=$Definition.expected;actual=$null;safeErrorCode=$null;finalPoolState='Unknown';finalWorkerCount=$null;
        currentSha256=$null;journalSha256=$null;applicationInventoryVerified=$null;protectedSentinelPreserved=$null;elapsedSeconds=0;
        status='NOT RUN';supportingEvidencePath=$null;supportingEvidenceSha256=$null;evidenceArtifacts=@();cleanup='No resources created';reason='No authorized disposable host execution';mandatory=$Definition.mandatory}
}
function Write-QReport([string] $OutputRoot, [object[]] $Results, [string] $RunId,[switch] $IndependentEvidenceVerified) {
    Assert-DistLocalPath $OutputRoot
    if (-not [IO.Directory]::Exists($OutputRoot)) { $null=[IO.Directory]::CreateDirectory($OutputRoot) }
    $definitions=Get-QScenarioDefinitions
    if ($Results.Count -ne $definitions.Count -or @($Results.scenarioId | Select-Object -Unique).Count -ne $definitions.Count -or @($definitions.id | Where-Object { $_ -cnotin @($Results.scenarioId) }).Count) { throw 'A report must account for every mandatory matrix case exactly once.' }
    $statuses=@{}
    foreach ($result in $Results) {
        if ($result.status -cnotin @('PASS','FAIL','BLOCKED','NOT RUN')) { throw 'Invalid qualification status.' }
        $definition=@($definitions | Where-Object id -CEQ $result.scenarioId)[0]
        if ($result.mandatory -isnot [bool] -or $result.mandatory -ne $definition.mandatory) { throw 'Result cannot change canonical mandatory matrix membership.' }
        $statuses[$result.scenarioId]=$result.status
    }
    $assertions=@($definitions | Where-Object { $_.mandatory -and $statuses[$_.id] -cne 'PASS' }).Count -eq 0
    $executed=$assertions -and [bool]$IndependentEvidenceVerified
    # Even all executed assertions need independent source/evidence acceptance.
    $qualified=$false
    Write-QJson (Join-Path $OutputRoot 'report.json') @{formatVersion=1;runId=$RunId;realHostQualified=$false;mandatoryAssertionsPassed=$assertions;mandatoryExecutionComplete=$executed;independentAcceptance='Required';results=$Results}
    $lines=[Collections.Generic.List[string]]::new(); $lines.Add('# Retained IIS verification evidence'); $lines.Add(''); $lines.Add('Real-host qualification: '+$(if ($qualified) {'PASS'} else {'INCOMPLETE'})); $lines.Add('The retained scenario catalog is not the required qualification campaign for the simplified engine. Use docs/iis-verification.md for the practical procedure.'); $lines.Add(''); $lines.Add('| Scenario | Status | Reason |'); $lines.Add('| --- | --- | --- |')
    foreach ($result in $Results) { $lines.Add('| '+$result.scenarioId+' | '+$result.status+' | '+$result.reason+' |') }
    [IO.File]::WriteAllLines((Join-Path $OutputRoot 'report.md'),$lines,[Text.UTF8Encoding]::new($false))
}

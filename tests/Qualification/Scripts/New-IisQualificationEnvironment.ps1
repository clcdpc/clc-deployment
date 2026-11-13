[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $ConfigurationPath,
    [ValidateSet('Plan','Provision')][string] $Operation='Plan',
    [string] $AuthorizationPath,
    [string] $DistributionPath,
    [Management.Automation.PSCredential] $RuntimeCredential
)
. "$PSScriptRoot/Qualification.Ownership.ps1"
$configuration=Read-QConfiguration $ConfigurationPath
if ($Operation -ceq 'Plan') {
    [pscustomobject]@{operation='Plan';mutations=$false;campaignId=$configuration.campaignId;ownedRoot=$configuration.ownedRoot;
        site=$configuration.siteName;pool=$configuration.poolName;securityModel='ElevatedV1';prerequisites=@('Explicit disposable-host authorization','Distinct existing infrastructure and elevated deployment accounts; separate nonadministrator runtime','Preinstalled IIS/ANCM/.NET','Existing disposable TLS certificate and trust','Independently authenticated distribution','Independent release approvals')}
    return
}
$null=Assert-QAuthorization $configuration $AuthorizationPath @('enroll','change-owned-iis','change-owned-fixtures')
if ((Get-QCallerSid) -cne $configuration.infrastructureSid) { throw 'Provisioning requires the designated infrastructure token.' }
$null=Assert-QRoleToken $configuration Infrastructure
if ([IO.Directory]::Exists($configuration.ownedRoot) -or [IO.File]::Exists($configuration.ownedRoot) -or -not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($configuration.ownedRoot))) { throw 'Provisioning refuses existing roots and missing approved parents.' }
$null=Get-DistPathFacts ([IO.Path]::GetDirectoryName($configuration.ownedRoot)) -Directory
if ($null -eq $RuntimeCredential -or ([Security.Principal.NTAccount]::new($RuntimeCredential.UserName).Translate([Security.Principal.SecurityIdentifier]).Value) -cne $configuration.runtimeSid) { throw 'An ephemeral credential for the exact test runtime identity is required.' }
$null=& "$script:QualificationRepository/tools/Test-ToolkitDistribution.ps1" -ArchivePath $DistributionPath -ExpectedSha256 $configuration.toolkit.distributionSha256 -ExpectedSourceCommit $configuration.toolkit.sourceCommit -ExpectedVersion $configuration.toolkit.version
$assembly=Join-Path ([IO.Path]::GetDirectoryName($configuration.appcmdPath)) 'Microsoft.Web.Administration.dll'
$null=Get-DistPathFacts $assembly
Add-Type -LiteralPath $assembly
$manager=[Microsoft.Web.Administration.ServerManager]::new()
$uri=[uri]$configuration.readinessUri
try {
    if ($null -ne $manager.Sites[$configuration.siteName] -or $null -ne $manager.ApplicationPools[$configuration.poolName]) { throw 'Qualification refuses existing IIS resources.' }
    foreach ($site in $manager.Sites) { foreach ($binding in $site.Bindings) {
        if ($binding.Protocol -ceq 'https' -and $binding.EndPoint.Port -eq $uri.Port) { throw 'Qualification requires an unused HTTPS port.' }
    } }
    $certificate=Get-Item -LiteralPath ('Cert:\LocalMachine\My\'+$configuration.certificateThumbprint)
    if (-not $certificate.HasPrivateKey -or $certificate.NotAfter -le [DateTime]::Now -or $certificate.NotBefore -gt [DateTime]::Now) { throw 'A current disposable TLS certificate is required.' }
    function Set-QDirectoryAcl([string] $Path, [string[]] $Writers, [string[]] $Readers) {
        $acl=[Security.AccessControl.DirectorySecurity]::new(); $acl.SetAccessRuleProtection($true,$false)
        $acl.SetOwner([Security.Principal.SecurityIdentifier]::new($configuration.infrastructureSid))
        foreach ($sid in @($configuration.infrastructureSid,'S-1-5-18','S-1-5-32-544')) {
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
        }
        foreach ($sid in $Writers) { $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'Modify','ContainerInherit,ObjectInherit','None','Allow')) }
        foreach ($sid in $Readers) { $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow')) }
        Set-Acl -LiteralPath $Path -AclObject $acl
    }
    $root=$configuration.ownedRoot; $null=[IO.Directory]::CreateDirectory($root)
    Set-QDirectoryAcl $root @() @($configuration.deploymentSid,$configuration.runtimeSid)
    $toolkit=Join-Path $root 'toolkit'; $version=Join-Path $toolkit ('versions\'+$configuration.toolkit.version)
    foreach ($path in @($toolkit,$version,(Join-Path $toolkit 'policy\targets'),(Join-Path $toolkit 'policy\approvals'),
            $configuration.applicationRoot,[IO.Path]::GetDirectoryName($configuration.operationalConfigPath),$configuration.dataProtectionRoot,$configuration.artifactInboxRoot,(Join-Path $root 'locks'),(Get-QControlRoot $configuration))) { $null=[IO.Directory]::CreateDirectory($path) }
    foreach ($path in @($configuration.applicationRoot,$configuration.artifactInboxRoot,(Join-Path $root 'locks'),(Join-Path $root 'control'))) { Set-QDirectoryAcl $path @($configuration.deploymentSid) @() }
    Set-QDirectoryAcl $configuration.applicationRoot @($configuration.deploymentSid) @($configuration.runtimeSid)
    Set-QDirectoryAcl $configuration.dataProtectionRoot @($configuration.runtimeSid) @($configuration.deploymentSid)
    $archive=[IO.Compression.ZipFile]::OpenRead($DistributionPath)
    try {
        foreach ($entry in $archive.Entries) {
            if (-not $entry.FullName.StartsWith('CLC.Deployment/',[StringComparison]::Ordinal) -and $entry.FullName -cnotin (Get-DistInfrastructureNames)) { continue }
            $destination=Join-Path $version $entry.FullName.Replace('/','\'); Assert-DistLocalPath $destination
            $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
            $inputStream=$entry.Open(); $outputStream=[IO.FileStream]::new($destination,[IO.FileMode]::CreateNew)
            try { $inputStream.CopyTo($outputStream); $outputStream.Flush($true) } finally { $inputStream.Dispose(); $outputStream.Dispose() }
        }
    } finally { $archive.Dispose() }
    [IO.File]::Copy($DistributionPath,(Join-Path $version 'distribution.zip'),$false)
    [IO.File]::WriteAllText((Join-Path $version 'source.commit'),$configuration.toolkit.sourceCommit,[Text.Encoding]::ASCII)
    $manifest=Get-QInstalledManifest $configuration
    $null=& "$script:QualificationRepository/tools/Test-ToolkitDistribution.ps1" -ArchivePath (Join-Path $version 'distribution.zip') -ExpectedSha256 $configuration.toolkit.distributionSha256 -ExpectedSourceCommit $configuration.toolkit.sourceCommit -ExpectedVersion $configuration.toolkit.version -InstalledModuleRoot ([IO.Path]::GetDirectoryName($manifest))
    # First import follows independent verification. This script remains outside
    # the module and never creates application approvals.
    Import-Module $manifest -Force
    $trustedInstaller=[Security.Principal.NTAccount]::new('NT SERVICE\TrustedInstaller').Translate([Security.Principal.SecurityIdentifier]).Value
    $policy=[ordered]@{contractFamily='clc-file-iis-v1';schemaVersion=1;recordKind='host-policy';generation=1;machineIdentity=$configuration.machineIdentity;
        activeToolkit=@{version=$configuration.toolkit.version;sourceCommit=$configuration.toolkit.sourceCommit;distributionSha256=$configuration.toolkit.distributionSha256;inventorySha256=$configuration.toolkit.inventorySha256;moduleManifestPath=$manifest};
        targetCatalogRoot=(Join-Path $toolkit 'policy\targets');approvalCatalogRoot=(Join-Path $toolkit 'policy\approvals');controlStateRoot=(Join-Path $root 'control');lockRoot=(Join-Path $root 'locks');
        dotnetPath=$configuration.dotnetPath;appcmdPath=$configuration.appcmdPath;infrastructureOwnerSids=@($configuration.infrastructureSid,'S-1-5-18','S-1-5-32-544',$trustedInstaller);deploymentSids=@($configuration.deploymentSid)}
    Invoke-QPrivate Assert-ClcRuntimeIdentity @(@{policyFile=@{record=$policy}},$configuration.runtimeSid)
    $target=[ordered]@{contractFamily='clc-file-iis-v1';schemaVersion=1;recordKind='target';targetId=$configuration.targetId;applicationId='clc-qualification-probe';environmentName='disposable-qualification';runtimeEnvironment=$configuration.runtimeEnvironment;siteName=$configuration.siteName;applicationPoolName=$configuration.poolName;
        applicationRoot=$configuration.applicationRoot;operationalConfigPath=$configuration.operationalConfigPath;dataProtectionRoot=$configuration.dataProtectionRoot;artifactInboxRoot=$configuration.artifactInboxRoot;runtimeIdentitySid=$configuration.runtimeSid;readinessUri=$configuration.readinessUri}
    Write-QJson (Join-Path $toolkit 'policy\host-policy.json') $policy
    Write-QJson (Join-Path $policy.targetCatalogRoot ($target.targetId+'.json')) $target
    $target.targetId=$configuration.alternateTargetId; Write-QJson (Join-Path $policy.targetCatalogRoot ($target.targetId+'.json')) $target
    Write-QJson $configuration.operationalConfigPath @{configurationRevision='probe-config-001';keyStoreCompatibilityId='clc-probe-dpapi-user-v1';syntheticSecret='CLC_SYNTHETIC_SECRET_SENTINEL_T4'}
    # Exact root ownership is recorded before IIS effects. Partial provisioning is
    # retained for operator inspection; it is never automatically removed.
    $identity=Get-DistPathFacts $root -Directory
    $marker=@{formatVersion=1;campaignId=$configuration.campaignId;configurationSha256=$configuration._sha256;machineIdentity=$configuration.machineIdentity;ownedRoot=$root;siteName=$configuration.siteName;poolName=$configuration.poolName;createdBySid=$configuration.infrastructureSid;rootIdentity=$identity.Identity;ownedRootIdentities=(Get-QOwnedRootIdentities $configuration);iisOwnership=$null}
    Write-QJson (Join-Path $root '.clc-t4-owner.json') $marker
    $pool=$manager.ApplicationPools.Add($configuration.poolName)
    $pool.ManagedRuntimeVersion=''; $pool.Enable32BitAppOnWin64=$false; $pool.ProcessModel.MaxProcesses=1; $pool.Recycling.DisallowOverlappingRotation=$true
    $pool.ProcessModel.IdentityType='SpecificUser'; $pool.ProcessModel.UserName=$RuntimeCredential.UserName; $pool.ProcessModel.Password=$RuntimeCredential.GetNetworkCredential().Password; $pool.ProcessModel.LoadUserProfile=$true
    foreach ($pair in @(@('ASPNETCORE_ENVIRONMENT',$configuration.runtimeEnvironment),@('CLC_PROBE_CONFIGURATION_PATH',$configuration.operationalConfigPath),@('CLC_PROBE_DATA_PROTECTION_ROOT',$configuration.dataProtectionRoot))) {
        $element=$pool.GetCollection('environmentVariables').CreateElement(); $element['name']=$pair[0]; $element['value']=$pair[1]; $pool.GetCollection('environmentVariables').Add($element)
    }
    $site=$manager.Sites.Add($configuration.siteName,'https',('127.0.0.1:'+$uri.Port+':'+$uri.DnsSafeHost),$configuration.applicationRoot)
    $site.Applications['/'].ApplicationPoolName=$configuration.poolName; $site.Bindings[0].SslFlags='Sni'
    $manager.CommitChanges()
    $site.Bindings[0].AddSslCertificate([Convert]::FromHexString($configuration.certificateThumbprint),'My')
    $manager.Dispose(); $manager=[Microsoft.Web.Administration.ServerManager]::new()
    $marker.iisOwnership=Get-QIisOwnershipSnapshot $manager $configuration
    $markerTemporary=Join-Path $root ('.owner-'+[guid]::NewGuid().ToString('N')+'.tmp')
    Write-QJson $markerTemporary $marker; [IO.File]::Move($markerTemporary,(Join-Path $root '.clc-t4-owner.json'),$true)
    [pscustomobject]@{provisioned=$true;campaignId=$configuration.campaignId;securityModel='ElevatedV1';applicationApprovalsCreated=$false;deploymentIisRightsDelegated=$false;nextAction='Independently approve exact probe bytes; verify elevated deployment and separate nonadministrator runtime tokens; run preflight. No group membership was changed.'}
} finally { $manager.Dispose() }

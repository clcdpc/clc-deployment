# Synthetic enrollment fixtures only. No host/IIS/account/certificate operations.
. "$PSScriptRoot/T2Support.ps1"
. "$PSScriptRoot/../tools/Distribution.Common.ps1"
$script:HBootstrapWorkspace=New-TestWorkspace
$script:HBootstrapRoot=Join-Path $script:HBootstrapWorkspace 'bootstrap'
$null=[IO.Directory]::CreateDirectory($script:HBootstrapRoot)
Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'src/CLC.Deployment') -Destination $script:HBootstrapRoot -Recurse
foreach ($name in Get-DistInfrastructureNames) {
    $destination=Join-Path $script:HBootstrapRoot $name.Replace('/','\');$null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
    [IO.File]::Copy((Join-Path $script:RepositoryRoot $name),$destination)
}
[IO.File]::WriteAllText((Join-Path $script:HBootstrapRoot 'source.commit'),('a'*40))
. (Join-Path $script:HBootstrapRoot 'tools/host/HostEnrollment.Common.ps1')
function New-HTestFixture {
    $workspace=New-TestWorkspace; $enrollment=Join-Path $workspace 'h'; $authority=Join-Path $workspace 'auth'
    foreach ($path in @($authority,(Join-Path $authority 'evidence'),(Join-Path $workspace 'config'),(Join-Path $workspace 'app'),(Join-Path $workspace 'keys'),(Join-Path $workspace 'inbox'),(Join-Path $workspace 'bin'))) { $null=[IO.Directory]::CreateDirectory($path) }
    [IO.File]::WriteAllBytes((Join-Path $authority 'host-enrollment.lock'),[byte[]]::new(0))
    $configuration=Get-Content -LiteralPath (Join-Path $script:FixtureRoot 'target.json') -Raw | ConvertFrom-Json -AsHashtable -DateKind String
    $configuration.contractFamily='clc-host-enrollment-v1'; $configuration.recordKind='deployment-configuration'
    $configuration.enrollmentRoot=$enrollment; $configuration.runtimeAccountName='SYNTHETIC\runtime$'
    $configuration.applicationRoot=Join-Path $workspace 'app'; $configuration.operationalConfigPath=Join-Path $workspace 'config\application.json'
    $configuration.dataProtectionRoot=Join-Path $workspace 'keys'; $configuration.artifactInboxRoot=Join-Path $workspace 'inbox'
    [IO.File]::WriteAllText($configuration.operationalConfigPath,'CLC_SYNTHETIC_CONFIG_MUST_REMAIN_UNCHANGED')
    [IO.File]::WriteAllText((Join-Path $configuration.dataProtectionRoot 'key.xml'),'CLC_SYNTHETIC_KEY_MUST_REMAIN_UNCHANGED')
    $configurationPath=Join-Path $workspace 'config\deployment.json'; Write-TestJson $configurationPath $configuration
    $layout=Get-HLayout $enrollment '0.1.0-dev.1'
    $policy=Get-Content -LiteralPath (Join-Path $script:FixtureRoot 'host-policy.json') -Raw | ConvertFrom-Json -AsHashtable -DateKind String
    foreach ($name in @('targetCatalogRoot','approvalCatalogRoot','controlStateRoot','lockRoot')) { $policy[$name]=$layout[$name] }
    $policy.activeToolkit.moduleManifestPath=$layout.manifestPath
    $policy.infrastructureOwnerSids=@('S-1-5-18','S-1-5-32-544','S-1-5-19')
    $policy.deploymentSids=@('S-1-5-21-1-2-3-1001')
    foreach ($pair in @(@('dotnetPath','dotnet.exe'),@('appcmdPath','appcmd.exe'))) {
        $policy[$pair[0]]=Join-Path $workspace ('bin\'+$pair[1]); [IO.File]::WriteAllText($policy[$pair[0]],'inert fixture; never executed')
    }
    $bindings=@{}; $handles=[Collections.Generic.List[IDisposable]]::new()
    try { foreach ($name in @('applicationRoot','operationalConfigPath','dataProtectionRoot','artifactInboxRoot')) { $bindings[$name]=Get-HResourceBinding $configuration[$name] $handles -Directory:($name -cne 'operationalConfigPath') } }
    finally { foreach ($handle in $handles) { $handle.Dispose() } }
    $authorization=@{contractFamily='clc-host-enrollment-v1';schemaVersion=1;recordKind='host-enrollment-authorization';authorizationId='synthetic-enroll';enabled=$true;
        approvedUtc='2026-01-01T00:00:00Z';expiresUtc='2099-01-01T00:00:00Z';authoritySid='S-1-5-19';reference='synthetic-offline';targetId=$configuration.targetId;
        deploymentConfigurationSha256=(Get-FileHash -LiteralPath $configurationPath).Hash.ToLowerInvariant();enrollmentRoot=$enrollment;hostPolicy=$policy;
        bootstrap=@{sourceCommit=('a'*40);inventorySha256=(Get-HBootstrapInventory)};permittedOperations=@('install-toolkit','enroll-target','configure-iis','create-site','create-pool');
        iis=@{bindingAddress='127.0.0.1';certificateThumbprint=('A'*40);newPoolIdentityType='ExistingOnly';expectedSnapshotSha256=('0'*64)};resourceBindings=$bindings;cutover=$null}
    $authorizationPath=Join-Path $authority 'synthetic-enroll.json'; Write-TestJson $authorizationPath $authorization
    $uri=[uri]$configuration.readinessUri
    $snapshot=@{siteExists=$true;poolExists=$true;siteId=1L;siteState='Started';siteServerAutoStart=$true;applications=@(@{siteName=$configuration.siteName;path='/';poolName=$configuration.applicationPoolName;physicalPath=$configuration.applicationRoot});
        bindings=@(@{siteName=$configuration.siteName;protocol='https';host=$uri.DnsSafeHost;address='127.0.0.1';port=[long]$uri.Port;sslFlags=1L;certificateStore='My';certificateThumbprint=('A'*40)});
        pool=@{name=$configuration.applicationPoolName;state='Stopped';workers=@();runtimeSid=$configuration.runtimeIdentitySid;managedRuntimeVersion='';managedPipelineMode='Integrated';enable32Bit=$false;maxProcesses=1L;disallowOverlappingRotation=$true;loadUserProfile=$true;
            environment=@(@{name='ASPNETCORE_ENVIRONMENT';value=$configuration.runtimeEnvironment;scope='Pool'})}}
    $iis=@{siteName=$configuration.siteName;siteState='Started';poolName=$configuration.applicationPoolName;poolState='Stopped';applications=$snapshot.applications;runtimeSid=$configuration.runtimeIdentitySid;
        maxProcesses=1L;disallowOverlappingRotation=$true;enable32Bit=$false;workers=@();environment=$snapshot.pool.environment;ancmPath=$policy.appcmdPath;bindings=$snapshot.bindings}
    @{workspace=$workspace;configuration=$configuration;configurationPath=$configurationPath;authorization=$authorization;authorizationPath=$authorizationPath;authorityRoot=$authority;
        policy=$policy;layout=$layout;snapshot=$snapshot;iis=$iis;target=(Get-HTarget $configuration)}
}
function Save-HTestAuthorization($Fixture) { Write-TestJson $Fixture.authorizationPath $Fixture.authorization }
function Set-HTestMocks($Fixture) {
    $global:HFixture=$Fixture
    Mock Get-HAuthorityRoot { $global:HFixture.authorityRoot }
    Mock Get-HCanonicalEnrollmentRoot { [IO.Path]::GetDirectoryName($global:HFixture.layout.root) }
    Mock Get-HBootstrapSourceCommit { $global:HFixture.authorization.bootstrap.sourceCommit }
    Mock Assert-HAuthorityProtection { $null=Get-ClcPathObservation $Path $Handles -Directory:$Directory }
    Mock Get-ClcCallerSid { 'S-1-5-21-1-2-3-1001' }
    Mock Test-ClcAdministratorToken { $true }
    Mock Get-ClcMachineUuidObservation { $global:HFixture.policy.machineIdentity }
    Mock Assert-ClcRuntimeIdentity { }
    Mock Assert-ClcAccess { (Get-ClcSecurityObservation $Path).sha256 }
    Mock Assert-ClcTrustAncestors { }
    Mock Assert-HResourceAccess { }
    Mock Set-HNewResourceAcl { }
    Mock Assert-ClcHelperDependencies { }
    Mock Assert-ClcHostAccess { }
    Mock Assert-HActiveCompatibility { }
    Mock Get-HIisSnapshot { $global:HFixture.snapshot }
    Mock Assert-HCertificate { }
    Mock Get-ClcIisPoolNames { @($global:HFixture.target.applicationPoolName) }
    Mock Get-ClcIisObservation { $global:HFixture.iis }
    Mock Get-ClcPlatformObservation { @{build='20348';productType=3L;is64Bit=$true;powershellMajor=7L} }
    Mock Get-ClcRuntimeObservation { @{dotnetX64=$true;ancmX64=$true;ancmMajor=20L;frameworks=@(@{name='Microsoft.NETCore.App';version='10.0.14'},@{name='Microsoft.AspNetCore.App';version='10.0.14'})} }
}
function Close-HTestSession($Session) {
    if ($null -ne $Session) {
        if ($null -ne $Session.poolLock) {$Session.poolLock.Dispose()}
        if ($null -ne $Session.globalLock) {$Session.globalLock.Dispose()}
        Close-ClcTrustedContext $Session.context
        foreach ($handle in $Session.handles) {$handle.Dispose()}
    }
}
function New-HTestDistribution {
    $workspace=New-TestWorkspace; $repository=Join-Path $workspace 'repo'
    $null=[IO.Directory]::CreateDirectory((Join-Path $repository 'src'))
    Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'src/CLC.Deployment') -Destination (Join-Path $repository 'src') -Recurse
    foreach ($name in Get-DistInfrastructureNames) {
        $destination=Join-Path $repository $name.Replace('/','\'); $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
        [IO.File]::Copy((Join-Path $script:RepositoryRoot $name),$destination)
    }
    [IO.File]::Copy((Join-Path $script:RepositoryRoot 'VERSION'),(Join-Path $repository 'VERSION'))
    foreach ($arguments in @(@('init','--initial-branch=codex/fixture'),@('config','user.name','Synthetic Enrollment'),@('config','user.email','enrollment@example.invalid'),@('config','core.autocrlf','false'),@('add','.'),@('commit','-m','Inert enrollment distribution fixture'))) { $null=Get-DistGit $repository $arguments }
    $commit=Get-DistGit $repository @('rev-parse','HEAD'); $archive=Join-Path $workspace 'toolkit.zip'
    $identity=& "$script:RepositoryRoot/tools/New-ToolkitDistribution.ps1" -RepositoryRoot $repository -SourceCommit $commit -OutputPath $archive
    @{workspace=$workspace;repository=$repository;archive=$archive;identity=$identity;commit=$commit}
}
function Set-HTestDistribution($Fixture,$Distribution) {
    foreach ($key in @('version','sourceCommit','distributionSha256','inventorySha256')) {
        $Fixture.policy.activeToolkit[$key]=if ($key -ceq 'version') {$Distribution.identity.moduleVersion} else {$Distribution.identity.PSObject.Properties[$key].Value}
    }
    Save-HTestAuthorization $Fixture
}
function Select-HSecondTestTarget($Fixture) {
    $configuration=$Fixture.configuration | ConvertTo-Json -Depth 16 -Compress | ConvertFrom-Json -AsHashtable
    $configuration.targetId='synthetic-second';$configuration.applicationId='second-app';$configuration.siteName='SecondSite';$configuration.applicationPoolName='SecondPool'
    $configuration.runtimeIdentitySid='S-1-5-21-1-2-3-2002';$configuration.runtimeAccountName='SYNTHETIC\second$'
    foreach ($pair in @(@('applicationRoot','app2'),@('dataProtectionRoot','keys2'),@('artifactInboxRoot','inbox2'))) {
        $configuration[$pair[0]]=Join-Path $Fixture.workspace $pair[1];$null=[IO.Directory]::CreateDirectory($configuration[$pair[0]])
    }
    $directory=Join-Path $Fixture.workspace 'config2';$null=[IO.Directory]::CreateDirectory($directory)
    $configuration.operationalConfigPath=Join-Path $directory 'application.json';[IO.File]::WriteAllText($configuration.operationalConfigPath,'second synthetic config')
    $Fixture.configuration=$configuration;$Fixture.target=Get-HTarget $configuration;$Fixture.configurationPath=Join-Path $directory 'deployment.json';Write-TestJson $Fixture.configurationPath $configuration
    $Fixture.authorization.authorizationId='synthetic-second';$Fixture.authorization.targetId=$configuration.targetId
    $Fixture.authorization.deploymentConfigurationSha256=(Get-FileHash -LiteralPath $Fixture.configurationPath).Hash.ToLowerInvariant()
    $handles=[Collections.Generic.List[IDisposable]]::new()
    try {foreach ($name in @('applicationRoot','operationalConfigPath','dataProtectionRoot','artifactInboxRoot')) {$Fixture.authorization.resourceBindings[$name]=Get-HResourceBinding $configuration[$name] $handles -Directory:($name -cne 'operationalConfigPath')}}
    finally {foreach ($handle in $handles) {$handle.Dispose()}}
    $Fixture.authorizationPath=Join-Path $Fixture.authorityRoot 'synthetic-second.json';Save-HTestAuthorization $Fixture
    $Fixture.snapshot.applications=@(@{siteName=$configuration.siteName;path='/';poolName=$configuration.applicationPoolName;physicalPath=$configuration.applicationRoot})
    $Fixture.snapshot.pool.name=$configuration.applicationPoolName;$Fixture.snapshot.pool.runtimeSid=$configuration.runtimeIdentitySid;$Fixture.snapshot.bindings[0].siteName=$configuration.siteName
    $Fixture.iis.siteName=$configuration.siteName;$Fixture.iis.poolName=$configuration.applicationPoolName;$Fixture.iis.runtimeSid=$configuration.runtimeIdentitySid;$Fixture.iis.applications=$Fixture.snapshot.applications
}

# MWA is a narrow local adapter, never a shell or caller-supplied executable.
function Get-HBindingSnapshot([string] $SiteName,$Binding) {
    $secure=$Binding.Protocol -ceq 'https'
    [ordered]@{siteName=$SiteName;protocol=$Binding.Protocol;address=$Binding.EndPoint.Address.ToString();port=[long]$Binding.EndPoint.Port;host=$Binding.Host;
        sslFlags=$(if ($secure) {[long]$Binding.SslFlags} else {0L});certificateStore=$(if ($secure) {$Binding.CertificateStoreName} else {''});
        certificateThumbprint=$(if (-not $secure -or $null -eq $Binding.CertificateHash) {''} else {[Convert]::ToHexString($Binding.CertificateHash)})}
}
function Get-HIisSnapshotHash($Snapshot) {
    $pool=$null
    if ($Snapshot.poolExists) {
        $source=$Snapshot.pool
        $pool=[ordered]@{}
        foreach ($key in @('name','state','runtimeSid','managedRuntimeVersion','managedPipelineMode','enable32Bit','maxProcesses','disallowOverlappingRotation','loadUserProfile')) {$pool[$key]=$source[$key]}
        $pool.workers=@($source.workers | Sort-Object)
        $pool.environment=@($source.environment | Sort-Object scope,name -CaseSensitive -Culture '' | ForEach-Object {[ordered]@{scope=$_.scope;name=$_.name;value=$_.value}})
    }
    $projection=[ordered]@{siteExists=$Snapshot.siteExists;poolExists=$Snapshot.poolExists;siteId=$Snapshot.siteId;siteState=$Snapshot.siteState;siteServerAutoStart=$Snapshot.siteServerAutoStart;pool=$pool;
        applications=@($Snapshot.applications | Sort-Object siteName,path,poolName,physicalPath -CaseSensitive -Culture '' | ForEach-Object {[ordered]@{siteName=$_.siteName;path=$_.path;poolName=$_.poolName;physicalPath=$_.physicalPath}});
        bindings=@($Snapshot.bindings | Sort-Object siteName,protocol,host,port,address -CaseSensitive -Culture '' | ForEach-Object {
            [ordered]@{siteName=$_.siteName;protocol=$_.protocol;host=$_.host;port=$_.port;address=$_.address;sslFlags=$_.sslFlags;certificateStore=$_.certificateStore;certificateThumbprint=$_.certificateThumbprint}
        })}
    Get-ClcBytesHash ([Text.Encoding]::UTF8.GetBytes(($projection | ConvertTo-Json -Depth 16 -Compress)))
}
function Open-HIisManager($Session) {
    $context=if ($null -ne $Session.context) {$Session.context} else {New-HPreflightContext $Session}
    $platform=Get-ClcPlatformObservation
    if ($platform.build -cne '20348' -or $platform.productType -notin @(2,3) -or -not $platform.is64Bit -or $platform.powershellMajor -ne 7) { Stop-ClcError Clc.EnrollmentPrerequisiteMissing }
    if ((Resolve-ClcAccountSid $Session.configuration.runtimeAccountName) -cne $Session.target.runtimeIdentitySid) { Stop-ClcError Clc.EnrollmentIdentityMismatch }
    Assert-ClcRuntimeIdentity $context $Session.target.runtimeIdentitySid
    Assert-ClcHelperDependencies $context $Session.target.runtimeIdentitySid
    $assemblyPath=Join-Path ([IO.Path]::GetDirectoryName($Session.authorization.hostPolicy.appcmdPath)) 'Microsoft.Web.Administration.dll'
    $file=Read-ClcHeldFile $assemblyPath $context.handles 268435456 -SystemFile -NoCapture
    $observation=Get-ClcMwaAssemblyObservation
    if ($null -eq $observation) { Add-Type -LiteralPath $assemblyPath; $observation=Get-ClcMwaAssemblyObservation }
    Assert-ClcMwaAssemblyIdentity $file $observation
    New-ClcMwaServerManager $observation.type
}
function Get-HIisSnapshot($Session) {
    $manager=Open-HIisManager $Session
    try {
        if ($manager.Sites.Count -gt 4096 -or $manager.ApplicationPools.Count -gt 4096) { Stop-ClcError Clc.HostPreflightFailed }
        $target=$Session.target; $site=$manager.Sites[$target.siteName]; $pool=$manager.ApplicationPools[$target.applicationPoolName]
        $applications=@(); $allBindings=@(); $count=0;$bindingCount=0
        foreach ($otherSite in $manager.Sites) {
            foreach ($application in $otherSite.Applications) {
                $count++; if ($count -gt 4096) { Stop-ClcError Clc.HostPreflightFailed }
                if ($application.ApplicationPoolName -ieq $target.applicationPoolName -or $otherSite.Name -ieq $target.siteName) {
                    if ($application.VirtualDirectories.Count -ne 1 -or $null -eq $application.VirtualDirectories['/']) { Stop-ClcError Clc.EnrollmentIisConflict }
                    $applications += @{siteName=$otherSite.Name;path=$application.Path;poolName=$application.ApplicationPoolName;physicalPath=$application.VirtualDirectories['/'].PhysicalPath}
                }
            }
            foreach ($binding in $otherSite.Bindings) {
                $bindingCount++;if ($bindingCount -gt 4096) {Stop-ClcError Clc.HostPreflightFailed}
                if ($binding.Protocol -cnotin @('http','https')) {
                    if ($otherSite.Name -ieq $target.siteName) {Stop-ClcError Clc.EnrollmentIisConflict}
                    continue
                }
                $allBindings += Get-HBindingSnapshot $otherSite.Name $binding
            }
        }
        $modules=@($manager.GetApplicationHostConfiguration().GetSection('system.webServer/globalModules').GetCollection() | Where-Object {$_['name'] -ceq 'AspNetCoreModuleV2'})
        if ($modules.Count -ne 1) { Stop-ClcError Clc.EnrollmentPrerequisiteMissing }
        $image=[string]$modules[0]['image']
        $image=$image.Replace('%ProgramFiles%',[Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)).Replace('%windir%',[Environment]::GetFolderPath([Environment+SpecialFolder]::Windows))
        $context=if ($null -ne $Session.context) {$Session.context} else {New-HPreflightContext $Session}
        $runtime=Get-ClcRuntimeObservation $context $image $target.runtimeIdentitySid
        if (-not $runtime.dotnetX64 -or -not $runtime.ancmX64 -or $runtime.ancmMajor -ne 20) { Stop-ClcError Clc.EnrollmentPrerequisiteMissing }
        foreach ($name in @('Microsoft.NETCore.App','Microsoft.AspNetCore.App')) {
            if (@($runtime.frameworks | Where-Object {$_.name -ceq $name -and $_.version -cmatch '^10\.0\.[0-9]+$'}).Count -lt 1) { Stop-ClcError Clc.EnrollmentPrerequisiteMissing }
        }
        $poolInfo=$null
        if ($null -ne $pool) {
            if ($pool.ProcessModel.IdentityType.ToString() -cne 'SpecificUser' -or (Resolve-ClcAccountSid $pool.ProcessModel.UserName) -cne $target.runtimeIdentitySid) { Stop-ClcError Clc.EnrollmentIdentityMismatch }
            $environment=@()
            foreach ($element in $pool.GetCollection('environmentVariables')) { $environment += @{name=[string]$element['name'];value=[string]$element['value'];scope='Pool'} }
            $machine=[Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]::Machine)
            foreach ($key in $machine.Keys) { if ($key -imatch '^(DOTNET_|ASPNETCORE_|COMPlus_|CORECLR_)') { $environment += @{name=[string]$key;value=[string]$machine[$key];scope='Machine'} } }
            if ($null -ne $site) {
                foreach ($element in $manager.GetWebConfiguration($site.Name).GetSection('system.webServer/aspNetCore').GetCollection('environmentVariables')) { $environment += @{name=[string]$element['name'];value=[string]$element['value'];scope='Application'} }
            }
            $workers=@($manager.WorkerProcesses | Where-Object {$_.AppPoolName -ieq $pool.Name} | ForEach-Object {[long]$_.ProcessId})
            $poolInfo=[ordered]@{name=$pool.Name;state=$pool.State.ToString();workers=$workers;runtimeSid=$target.runtimeIdentitySid;managedRuntimeVersion=$pool.ManagedRuntimeVersion;
                managedPipelineMode=$pool.ManagedPipelineMode.ToString();enable32Bit=[bool]$pool.Enable32BitAppOnWin64;maxProcesses=[long]$pool.ProcessModel.MaxProcesses;
                disallowOverlappingRotation=[bool]$pool.Recycling.DisallowOverlappingRotation;loadUserProfile=[bool]$pool.ProcessModel.LoadUserProfile;
                environment=@($environment | Sort-Object scope,name -CaseSensitive -Culture '')}
        }
        [ordered]@{siteExists=($null -ne $site);poolExists=($null -ne $pool);
            siteId=$(if ($null -ne $site) {[long]$site.Id} else {$null});siteState=$(if ($null -ne $site) {$site.State.ToString()} else {'Absent'});siteServerAutoStart=$(if ($null -ne $site) {[bool]$site.ServerAutoStart} else {$null});
            applications=$applications;pool=$poolInfo;bindings=@($allBindings | Sort-Object siteName,protocol,host,port,address -CaseSensitive -Culture '')}
    } finally { $manager.Dispose() }
}
function Assert-HCertificate($Session) {
    $store=[Security.Cryptography.X509Certificates.X509Store]::new('My','LocalMachine'); $chain=$null
    try {
        $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
        $certificates=@($store.Certificates | Where-Object {$_.Thumbprint -ceq $Session.authorization.iis.certificateThumbprint})
        if ($certificates.Count -ne 1) { Stop-ClcError Clc.EnrollmentCertificateInvalid }
        $certificate=$certificates[0]; $now=(Get-HNow).UtcDateTime; $uri=[uri]$Session.target.readinessUri
        if (-not $certificate.HasPrivateKey -or $certificate.NotBefore.ToUniversalTime() -gt $now -or $certificate.NotAfter.ToUniversalTime() -le $now -or
            -not $certificate.MatchesHostname($uri.DnsSafeHost,$true,$false)) { Stop-ClcError Clc.EnrollmentCertificateInvalid }
        $chain=[Security.Cryptography.X509Certificates.X509Chain]::new()
        $chain.ChainPolicy.RevocationMode=[Security.Cryptography.X509Certificates.X509RevocationMode]::Online
        $chain.ChainPolicy.UrlRetrievalTimeout=[TimeSpan]::FromSeconds(10)
        $chain.ChainPolicy.ApplicationPolicy.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.1'))
        if (-not $chain.Build($certificate)) { Stop-ClcError Clc.EnrollmentCertificateInvalid }
    } finally { if ($null -ne $chain) {$chain.Dispose()}; $store.Dispose() }
}
function Assert-HBinding($Session,$Binding) {
    $uri=[uri]$Session.target.readinessUri; $expected=$Session.authorization.iis
    if ($Binding.protocol -cne 'https' -or $Binding.host -ine $uri.DnsSafeHost -or $Binding.address -cne $expected.bindingAddress -or $Binding.port -ne $uri.Port -or
        $Binding.sslFlags -ne 1 -or $Binding.certificateStore -cne 'My' -or $Binding.certificateThumbprint -cne $expected.certificateThumbprint) { Stop-ClcError Clc.EnrollmentCertificateInvalid }
}
function Get-HIisPlan($Session) {
    $snapshot=Get-HIisSnapshot $Session; $target=$Session.target; $operations=@(); $uri=[uri]$target.readinessUri
    Assert-HCertificate $Session
    foreach ($binding in $snapshot.bindings) {
        if ($binding.siteName -ine $target.siteName -and $binding.port -eq $uri.Port -and ($binding.host -ieq $uri.DnsSafeHost -or $binding.host -ceq '')) { Stop-ClcError Clc.EnrollmentIisConflict }
    }
    if ($snapshot.siteExists) {
        if ($snapshot.siteState -cne 'Started' -or -not $snapshot.siteServerAutoStart -or $snapshot.applications.Count -ne 1) { Stop-ClcError Clc.EnrollmentIisConflict }
        $app=$snapshot.applications[0]
        if ($app.siteName -ine $target.siteName -or $app.path -cne '/' -or $app.poolName -ine $target.applicationPoolName -or $app.physicalPath -cne $target.applicationRoot) { Stop-ClcError Clc.EnrollmentIisConflict }
        $bindings=@($snapshot.bindings | Where-Object {$_.siteName -ieq $target.siteName})
        if ($bindings.Count -ne 1) { Stop-ClcError Clc.EnrollmentIisConflict }
        Assert-HBinding $Session $bindings[0]
    } else {
        if ($snapshot.applications.Count) { Stop-ClcError Clc.EnrollmentIisConflict }
        $operations += 'create-site'
    }
    if ($snapshot.poolExists) {
        $pool=$snapshot.pool
        $Session.initialPoolState=$pool.state; $Session.workerCount=$pool.workers.Count
        if ($pool.state -cnotin @('Started','Stopped') -or $pool.workers.Count -gt 1 -or ($pool.state -ceq 'Stopped' -and $pool.workers.Count)) { Stop-ClcError Clc.EnrollmentIisConflict }
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $setEnvironment=$true; $environmentMismatch=$false
        foreach ($variable in $pool.environment) {
            if (-not $seen.Add($variable.scope+':'+$variable.name)) { Stop-ClcError Clc.EnrollmentIisConflict }
            if ($variable.name -iin @('ASPNETCORE_ENVIRONMENT','DOTNET_ENVIRONMENT')) {
                if ($variable.value -cne $target.runtimeEnvironment) { $environmentMismatch=$true }
                if ($variable.scope -cne 'Pool' -and $variable.value -cne $target.runtimeEnvironment) { Stop-ClcError Clc.EnrollmentIisConflict }
                if ($variable.scope -ceq 'Pool' -and $variable.name -ieq 'ASPNETCORE_ENVIRONMENT' -and $variable.value -ceq $target.runtimeEnvironment) { $setEnvironment=$false }
                elseif ($variable.value -cne $target.runtimeEnvironment -and $variable.scope -cne 'Pool') { Stop-ClcError Clc.EnrollmentIisConflict }
            } elseif ($variable.name -imatch '^(DOTNET_|ASPNETCORE_|COMPlus_|CORECLR_)') { Stop-ClcError Clc.EnrollmentIisConflict }
        }
        $change=$pool.managedRuntimeVersion -cne '' -or $pool.managedPipelineMode -cne 'Integrated' -or $pool.enable32Bit -or $pool.maxProcesses -ne 1 -or
            -not $pool.disallowOverlappingRotation -or -not $pool.loadUserProfile -or $setEnvironment -or $environmentMismatch
        if ($change) {
            if ($pool.state -cne 'Stopped' -or $pool.workers.Count) { Stop-ClcError Clc.EnrollmentMaintenanceRequired }
            $operations += 'configure-iis'
        }
        if (-not $snapshot.siteExists -and ($pool.state -cne 'Stopped' -or $pool.workers.Count)) { Stop-ClcError Clc.EnrollmentMaintenanceRequired }
    } else {
        if ($snapshot.siteExists -or $Session.authorization.iis.newPoolIdentityType -cne 'ManagedServiceAccount' -or -not (Test-HManagedServiceAccount $Session.configuration.runtimeAccountName)) { Stop-ClcError Clc.EnrollmentPrerequisiteMissing }
        $operations += 'create-pool'
    }
    $digest=Get-HIisSnapshotHash $snapshot
    if ($operations.Count -and $digest -cne $Session.authorization.iis.expectedSnapshotSha256) { Stop-ClcError Clc.EnrollmentIisSnapshotMismatch }
    @{operations=$operations;snapshot=$snapshot;snapshotSha256=$digest}
}
function Test-HManagedServiceAccount([string] $AccountName) {
    if ($null -eq ('Clc.Enrollment.Accounts' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Clc.Enrollment {
 public static class Accounts {
  [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
  [DllImport("Logoncli.dll",CharSet=CharSet.Unicode)] static extern uint NetIsServiceAccount(string server,string account,[MarshalAs(UnmanagedType.Bool)]out bool service);
  public static bool IsInstalled(string account) { bool service; return NetIsServiceAccount(null,account,out service)==0 && service; }
 }
}
'@
    }
    [Clc.Enrollment.Accounts]::IsInstalled($AccountName)
}
function Invoke-HIisApply($Session,$Plan) {
    if (-not $Plan.operations.Count) { return }
    $fresh=Get-HIisPlan $Session
    if ($fresh.snapshotSha256 -cne $Plan.snapshotSha256) { Stop-ClcError Clc.EnrollmentIisSnapshotMismatch }
    foreach ($operation in $Plan.operations) { Assert-HOperation $Session $operation }
    $manager=Open-HIisManager $Session
    try {
        $target=$Session.target; $pool=$manager.ApplicationPools[$target.applicationPoolName]
        if ($Plan.operations -ccontains 'create-pool') {
            if ($null -ne $pool -or -not (Test-HManagedServiceAccount $Session.configuration.runtimeAccountName)) { Stop-ClcError Clc.EnrollmentIisConflict }
            $pool=$manager.ApplicationPools.Add($target.applicationPoolName); $pool.AutoStart=$false
            $pool.ProcessModel.IdentityType='SpecificUser'; $pool.ProcessModel.UserName=$Session.configuration.runtimeAccountName
            $pool.ProcessModel.Password='' # Existing local managed account; no credential acquisition/provisioning.
        }
        if ($Plan.operations -ccontains 'configure-iis' -or $Plan.operations -ccontains 'create-pool') {
            $pool.ManagedRuntimeVersion=''; $pool.ManagedPipelineMode='Integrated'; $pool.Enable32BitAppOnWin64=$false
            $pool.ProcessModel.MaxProcesses=1; $pool.Recycling.DisallowOverlappingRotation=$true; $pool.ProcessModel.LoadUserProfile=$true
            $variables=$pool.GetCollection('environmentVariables')
            foreach ($name in @('ASPNETCORE_ENVIRONMENT','DOTNET_ENVIRONMENT')) {
                $existing=@($variables | Where-Object {$_['name'] -ieq $name})
                if ($existing.Count) { $existing[0]['value']=$target.runtimeEnvironment }
                elseif ($name -ceq 'ASPNETCORE_ENVIRONMENT') { $variable=$variables.CreateElement(); $variable['name']=$name; $variable['value']=$target.runtimeEnvironment; $variables.Add($variable) }
            }
        }
        if ($Plan.operations -ccontains 'create-site') {
            if ($null -ne $manager.Sites[$target.siteName]) { Stop-ClcError Clc.EnrollmentIisConflict }
            $uri=[uri]$target.readinessUri
            $address=$Session.authorization.iis.bindingAddress
            if ($address.Contains(':')) {$address='['+$address+']'}
            $site=$manager.Sites.Add($target.siteName,'https',($address+':'+$uri.Port+':'+$uri.DnsSafeHost),$target.applicationRoot)
            $site.Applications['/'].ApplicationPoolName=$target.applicationPoolName
            $site.ServerAutoStart=$true; $site.Bindings[0].SslFlags='Sni'
            $site.Bindings[0].CertificateStoreName='My'; $site.Bindings[0].CertificateHash=[Convert]::FromHexString($Session.authorization.iis.certificateThumbprint)
        }
        Assert-HSessionUnchanged $Session -Mutation
        $beforeCommit=Get-HIisSnapshot $Session
        $beforeCommitHash=Get-HIisSnapshotHash $beforeCommit
        if ($beforeCommitHash -cne $Plan.snapshotSha256) { Stop-ClcError Clc.EnrollmentIisSnapshotMismatch }
        $manager.CommitChanges()
        # Only a newly created site is registered/started. Never start a pool or
        # change the state of an existing application during enrollment.
        if ($Plan.operations -ccontains 'create-site') { $null=$manager.Sites[$target.siteName].Start() }
    } finally { $manager.Dispose() }
    Assert-HIisReady $Session
}
function Assert-HIisReady($Session) {
    $plan=Get-HIisPlan $Session
    if ($plan.operations.Count -or -not $plan.snapshot.siteExists -or -not $plan.snapshot.poolExists) { Stop-ClcError Clc.EnrollmentConfigurationDrift }
}
function Assert-HCutoverStopped($Session) {
    $snapshot=Get-HIisSnapshot $Session
    if (-not $snapshot.siteExists -or -not $snapshot.poolExists -or $snapshot.pool.state -cne 'Stopped' -or $snapshot.pool.workers.Count -ne 0 -or $snapshot.applications.Count -ne 1) { Stop-ClcError Clc.EnrollmentMaintenanceRequired }
    $app=$snapshot.applications[0]
    if ($app.physicalPath -cne $Session.target.applicationRoot -or $app.poolName -ine $Session.target.applicationPoolName -or $app.siteName -ine $Session.target.siteName -or $app.path -cne '/') { Stop-ClcError Clc.EnrollmentIisConflict }
}

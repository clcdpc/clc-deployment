function Invoke-ClcIisReadQuery {
    param($Context, [ValidateSet('PoolNames','PoolState')][string] $Query, [string] $PoolName)
    Assert-ClcHelperProtection $Context
    if ($Query -ceq 'PoolState') { Assert-ClcText $PoolName 64 '^[A-Za-z0-9_.-]{1,64}$' }
    try {
        $bytes=[Clc.Host.Native]::Query($Context.policyFile.record.appcmdPath,$Query,$PoolName)
        return [Text.UTF8Encoding]::new($false,$true).GetString($bytes)
    } catch { Stop-ClcError Clc.HostPreflightFailed }
}

function Get-ClcIisPoolNames {
    param($Context)
    $type=Get-ClcAdmittedMwaType $Context
    $manager=$null
    try {
        $manager=New-ClcMwaServerManager $type
        if ($manager.ApplicationPools.Count -gt 4096) { Stop-ClcError Clc.HostPreflightFailed }
        return @($manager.ApplicationPools | ForEach-Object { [string]$_.Name })
    } catch { Stop-ClcError Clc.HostPreflightFailed }
    finally { if ($null -ne $manager) { $manager.Dispose() } }
}

function Resolve-ClcAccountSid {
    param([string] $Name)
    try { return [Security.Principal.NTAccount]::new($Name).Translate([Security.Principal.SecurityIdentifier]).Value }
    catch { Stop-ClcError Clc.HostPreflightFailed }
}

function Get-ClcMwaAssemblyObservation {
    $type='Microsoft.Web.Administration.ServerManager' -as [type]
    if ($null -eq $type) { return $null }
    return @{type=$type;path=$type.Assembly.Location;dynamic=$type.Assembly.IsDynamic;moduleVersionId=$type.Module.ModuleVersionId.ToString('D')}
}



function New-ClcMwaServerManager {
    param([type] $ServerManagerType)
    if ($ServerManagerType.FullName -cne 'Microsoft.Web.Administration.ServerManager') { Stop-ClcError Clc.HostPreflightFailed }
    return [Activator]::CreateInstance($ServerManagerType)
}

function Get-ClcAdmittedMwaType {
    param($Context)
    if ($Context.ContainsKey('mwaType')) { return $Context.mwaType }
    Assert-ClcHelperProtection $Context
    $path=Join-Path ([IO.Path]::GetDirectoryName($Context.policyFile.record.appcmdPath)) 'Microsoft.Web.Administration.dll'
    $assembly=Get-ClcMwaAssemblyObservation
    if ($null -eq $assembly) { Add-Type -LiteralPath $path -ErrorAction Stop; $assembly=Get-ClcMwaAssemblyObservation }
    if ($null -eq $assembly -or $assembly.dynamic -or -not $assembly.path.Equals($path,[StringComparison]::OrdinalIgnoreCase)) { Stop-ClcError Clc.HostPreflightFailed }
    $Context.mwaType=$assembly.type
    return $assembly.type
}

function Get-ClcIisObservation {
    param($Context, $Target)
    Assert-ClcHelperDependencies $Context $Target.runtimeIdentitySid
    $type=Get-ClcAdmittedMwaType $Context
    # MWA reads selected configuration properties only. Never read ProcessModel.Password,
    # dump a configuration section, or import WebAdministration into PowerShell 7.
    $manager=$null
    try {
        $manager=New-ClcMwaServerManager $type
        if ($manager.Sites.Count -gt 4096 -or $manager.ApplicationPools.Count -gt 4096) { Stop-ClcError Clc.HostPreflightFailed }
        $sites=@($manager.Sites | Where-Object { [string]::Equals($_.Name,$Target.siteName,[StringComparison]::OrdinalIgnoreCase) })
        $pools=@($manager.ApplicationPools | Where-Object { [string]::Equals($_.Name,$Target.applicationPoolName,[StringComparison]::OrdinalIgnoreCase) })
        if ($sites.Count -ne 1 -or $pools.Count -ne 1) { Stop-ClcError Clc.HostPreflightFailed }
        $site=$sites[0]; $pool=$pools[0]; $apps=[Collections.Generic.List[object]]::new(); $count=0
        if ($site.Applications.Count -ne 1) { Stop-ClcError Clc.HostPreflightFailed }
        foreach ($otherSite in $manager.Sites) {
            foreach ($app in $otherSite.Applications) {
                $count++; if ($count -gt 4096) { Stop-ClcError Clc.HostPreflightFailed }
                if ([string]::Equals($app.ApplicationPoolName,$pool.Name,[StringComparison]::OrdinalIgnoreCase)) {
                    $roots=@($app.VirtualDirectories | Where-Object { $_.Path -ceq '/' })
                    if ($roots.Count -ne 1 -or $app.VirtualDirectories.Count -ne 1) { Stop-ClcError Clc.HostPreflightFailed }
                    $apps.Add(@{ siteName=$otherSite.Name; path=$app.Path; poolName=$app.ApplicationPoolName; physicalPath=$roots[0].PhysicalPath })
                }
            }
        }
        $account=switch ($pool.ProcessModel.IdentityType.ToString()) {
            SpecificUser { $pool.ProcessModel.UserName }
            ApplicationPoolIdentity { 'IIS APPPOOL\'+$pool.Name }
            LocalSystem { 'NT AUTHORITY\SYSTEM' }
            LocalService { 'NT AUTHORITY\LOCAL SERVICE' }
            NetworkService { 'NT AUTHORITY\NETWORK SERVICE' }
            default { Stop-ClcError Clc.HostPreflightFailed }
        }
        $environment=[Collections.Generic.List[object]]::new()
        $machine=[Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]::Machine)
        foreach ($key in $machine.Keys) { if ($key -imatch '^(DOTNET_|ASPNETCORE_|COMPlus_|CORECLR_)') { $environment.Add(@{name=[string]$key;value=[string]$machine[$key];scope='Machine'}) } }
        foreach ($element in $pool.GetCollection('environmentVariables')) { $environment.Add(@{name=[string]$element['name'];value=[string]$element['value'];scope='Pool'}) }
        $config=$manager.GetWebConfiguration($site.Name)
        $ancm=$config.GetSection('system.webServer/aspNetCore')
        foreach ($element in $ancm.GetCollection('environmentVariables')) { $environment.Add(@{name=[string]$element['name'];value=[string]$element['value'];scope='Application'}) }
        $modules=@($manager.GetApplicationHostConfiguration().GetSection('system.webServer/globalModules').GetCollection() | Where-Object { $_['name'] -ceq 'AspNetCoreModuleV2' })
        if ($modules.Count -ne 1) { Stop-ClcError Clc.HostPreflightFailed }
        $image=[string]$modules[0]['image']
        $image=$image.Replace('%ProgramFiles%', [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)).Replace('%windir%', [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows))
        $workers=@($manager.WorkerProcesses | Where-Object { [string]::Equals($_.AppPoolName,$pool.Name,[StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { [long]$_.ProcessId })
        return @{ siteName=$site.Name; siteState=$site.State.ToString(); poolName=$pool.Name;
            poolState=$pool.State.ToString(); applications=$apps.ToArray();
            runtimeSid=(Resolve-ClcAccountSid $account); maxProcesses=[long]$pool.ProcessModel.MaxProcesses;
            disallowOverlappingRotation=[bool]$pool.Recycling.DisallowOverlappingRotation; enable32Bit=[bool]$pool.Enable32BitAppOnWin64;
            workers=$workers; environment=$environment.ToArray(); ancmPath=$image;
            bindings=@($site.Bindings | ForEach-Object { @{protocol=$_.Protocol;host=$_.Host;port=[long]$_.EndPoint.Port;address=$_.EndPoint.Address.ToString()} }) }
    } catch { Stop-ClcError Clc.HostPreflightFailed }
    finally { if ($null -ne $manager) { $manager.Dispose() } }
}

function Assert-ClcIisTargetBinding {
    param($Target, $Iis, [string] $NormalizedPool)
    if (-not [string]::Equals($Iis.siteName,$Target.siteName,[StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals($Iis.poolName,$NormalizedPool,[StringComparison]::OrdinalIgnoreCase) -or $Iis.applications.Count -ne 1) { Stop-ClcError Clc.HostPreflightFailed }
    $app=$Iis.applications[0]
    if (-not [string]::Equals($app.siteName,$Target.siteName,[StringComparison]::OrdinalIgnoreCase) -or $app.path -cne '/' -or
        -not [string]::Equals($app.poolName,$NormalizedPool,[StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals($app.physicalPath,$Target.applicationRoot,[StringComparison]::OrdinalIgnoreCase)) { Stop-ClcError Clc.HostPreflightFailed }
}

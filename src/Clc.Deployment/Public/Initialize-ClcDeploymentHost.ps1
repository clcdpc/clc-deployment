
function Initialize-ClcDeploymentHost {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Preview','Initialize')][string] $Operation,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $ApplicationId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $TargetId,
        [ValidateNotNullOrEmpty()][string] $SiteName = $ApplicationId,
        [ValidateNotNullOrEmpty()][string] $ApplicationPoolName = $ApplicationId
    )
    Assert-ClcId $TargetId
    Assert-ClcSiteName $SiteName
    Assert-ClcCode $ApplicationPoolName 64
    Assert-ClcId $ApplicationId
    $manager=$null; $mutex=$null; $held=$false
    $result=[ordered]@{status='Preview';applicationId=$ApplicationId;targetId=$TargetId;root=$null;site=$SiteName;applicationPool=$ApplicationPoolName;
        planned=@();created=@();present=@();findings=@();administratorActions=@(
            'Configure the service account, credentials and dedicated HTTPS bindings in IIS Manager.',
            'Provision the TLS certificate, external application configuration, persistent keys, logs, runtime ACLs and application dependencies.',
            'Keep both IIS automatic-start flags disabled and run Test-ClcDeploymentHost before the first release.'
        )}
    try {
        Assert-ClcPlatform
        $layout=Get-ClcHostLayout $ApplicationId
        $result.root=$layout.root
        $target=[ordered]@{schemaVersion=2;recordKind='host';applicationId=$ApplicationId;targetId=$TargetId;
            siteName=$SiteName;applicationPoolName=$ApplicationPoolName;applicationRoot=$layout.application;siteId=0}
        if ($Operation -eq 'Initialize') {
            $mutex=[Threading.Mutex]::new($false,'Global\Clc.Deployment.Initialize')
            try { $held=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held=$true }
            if (-not $held) { Stop-ClcError Clc.DeploymentLocked 'Another initialization is running on this server.' }
        }
        Assert-ClcInitializationAccess $layout
        $manager=Open-ClcIis
        $null=Get-ClcHostingRuntime $manager
        $rootExists=Test-ClcStorageEntry $layout.root
        if ($rootExists) {
            $result.present+=@($layout.root)
            Assert-ClcStoragePath $layout.root -Directory
            foreach ($name in $script:ClcHostDirectories) {
                $path=Join-Path $layout.root $name
                if (Test-ClcStorageEntry $path) { $result.present+=@($path) }
            }
        }
        $existing=$null
        if ($rootExists -and (Test-ClcStorageEntry $layout.hostRecord)) {
            $existing=Read-ClcLocalRecord $layout.hostRecord host
            if (-not $PSBoundParameters.ContainsKey('SiteName')) { $target.siteName=$existing.siteName }
            if (-not $PSBoundParameters.ContainsKey('ApplicationPoolName')) { $target.applicationPoolName=$existing.applicationPoolName }
            $result.site=$target.siteName
            $result.applicationPool=$target.applicationPoolName
        }
        $resources=Get-ClcIisResources $manager $target
        if ($null -ne $resources.site) { $result.present+=@('IIS site '+$target.siteName) }
        if ($null -ne $resources.pool) { $result.present+=@('IIS pool '+$target.applicationPoolName) }
        if ($null -ne $existing) {
            foreach ($key in @('applicationId','targetId','siteName','applicationPoolName','applicationRoot')) {
                if ($target[$key] -cne $existing[$key]) { Stop-ClcError Clc.TargetMismatch 'Initialization parameters differ from the recorded host. Inspect the existing host configuration.' }
            }
            Assert-ClcIisOwnership $manager $existing $resources
            Assert-ClcIisPhysicalIsolation $manager $existing
            if ($resources.site.Id -ne $existing.siteId) { Stop-ClcError Clc.IisConflict 'The existing IIS site ID differs from the recorded initialization.' }
            foreach ($name in $script:ClcHostDirectories) { Assert-ClcStoragePath (Join-Path $layout.root $name) -Directory }
            $state=Read-ClcLocalRecord $layout.state state
            if ($state.applicationId -cne $ApplicationId -or $state.targetId -cne $TargetId) { Stop-ClcError Clc.InvalidState }
            $result.status='AlreadyInitialized'
            $result.present+=@($layout.hostRecord,$layout.state)
            $result.administratorActions=@('Run Test-ClcDeploymentHost to inspect the current configuration and deployment state.')
            return [pscustomobject]$result
        }
        if ($rootExists -or $null -ne $resources.site -or $null -ne $resources.pool) {
            Stop-ClcError Clc.ExistingResources 'The listed resources already exist without a matching completed initialization. Inspect them manually before choosing an unused target.'
        }
        # Preview exercises the same IIS configuration construction, in memory.
        Add-ClcIisResources $manager $target
        $result.planned=@($layout.root)+@($script:ClcHostDirectories | ForEach-Object { Join-Path $layout.root $_ })+
            @($layout.state,$layout.hostRecord,('IIS site '+$SiteName),('IIS pool '+$ApplicationPoolName))
        $result.iis=[ordered]@{siteState='Stopped';siteAutoStart=$false;bindings=@();physicalPath=$layout.application;
            poolState='Stopped';poolAutoStart=$false;managedRuntime='';pipeline='Integrated';enable32Bit=$false;
            maxWorkers=1;loadUserProfile=$true;overlappingRecycling=$false;initialIdentity='ApplicationPoolIdentity'}
        if ($Operation -eq 'Preview') { return [pscustomobject]$result }

        New-ClcHostDirectory $layout.root
        foreach ($name in $script:ClcHostDirectories) { New-ClcHostDirectory (Join-Path $layout.root $name) }
        try { $manager.CommitChanges() }
        catch { Stop-ClcError Clc.IisInitializationFailed 'IIS refused the stopped, unbound configuration. Inspect local IIS diagnostics and preserve the partial scaffold.' }
        $manager.Dispose(); $manager=$null
        $manager=Open-ClcIis
        $resources=Get-ClcIisResources $manager $target
        Assert-ClcIisOwnership $manager $target $resources
        $iis=Get-ClcIisState $manager $resources
        if ($resources.site.Bindings.Count -ne 0 -or $iis.siteState -cne 'Stopped' -or $iis.poolState -cne 'Stopped' -or
            $iis.siteAutoStart -or $iis.poolAutoStart -or $iis.workerCount -ne 0 -or
            -not (Test-ClcIisPoolSettings $resources.pool) -or $resources.pool.ProcessModel.IdentityType.ToString() -cne 'ApplicationPoolIdentity') {
            Stop-ClcError Clc.IisInitializationFailed 'Could not verify the intended stopped, unbound IIS resources. Inspect the partial scaffold in IIS Manager.'
        }
        $target.siteId=[long]$resources.site.Id
        $state=[ordered]@{schemaVersion=1;recordKind='state';applicationId=$ApplicationId;targetId=$TargetId;current=$null;highWater=$null;pending=$null}
        Write-ClcLocalRecord $layout.state $state
        Write-ClcLocalRecord $layout.hostRecord $target
        $result.status='InitializedNeedsConfiguration'
        $result.created=$result.planned
        $result.planned=@()
        return [pscustomobject]$result
    } catch {
        $finding=Get-ClcSafeFinding $_
        if ($Operation -eq 'Preview') {
            $result.status='Blocked'
            $result.findings=@($finding)
            return [pscustomobject]$result
        }
        Stop-ClcError $finding.code $finding.message
    } finally {
        if ($null -ne $manager) { $manager.Dispose() }
        if ($held) { $mutex.ReleaseMutex() }
        if ($null -ne $mutex) { $mutex.Dispose() }
    }
}

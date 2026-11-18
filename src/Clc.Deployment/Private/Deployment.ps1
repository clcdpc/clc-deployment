function Get-ClcSafeFinding {
    param($ErrorRecord)
    $code=$ErrorRecord.FullyQualifiedErrorId.Split(',')[0]
    if ($code -cmatch '^Clc\.[A-Za-z]+$') {
        return @{code=$code;message=$ErrorRecord.Exception.Message}
    }
    return @{code='Clc.OperationFailed';message='A Windows, IIS or filesystem operation failed. Inspect the local host and retained deployment evidence.'}
}

function Assert-ClcRunnableContext {
    param($Context)
    if ($Context.findings.Count -gt 0) {
        Stop-ClcError Clc.HostNotReady (($Context.findings | ForEach-Object {$_.message}) -join ' ')
    }
    $null=Assert-ClcAccess $Context.layout.hostRecord $script:ClcAdministrators $script:ClcAdministrators @() @($Context.runtimeSid)
    $null=Assert-ClcAccess $Context.layout.state $script:ClcAdministrators $script:ClcAdministrators @() @($Context.runtimeSid)
}

function Assert-ClcEffectContext {
    param($Context)
    $manager=Open-ClcIis
    try {
        $target=$Context.target
        $resources=Get-ClcIisResources $manager $target
        Assert-ClcIisOwnership $manager $target $resources
        Assert-ClcIisPhysicalIsolation $manager $target
        if ($resources.site.Id -ne $Context.siteId -or -not (Test-ClcIisPoolSettings $resources.pool) -or
            $resources.pool.ProcessModel.IdentityType.ToString() -cne 'SpecificUser' -or
            (Resolve-ClcRuntimeSid $resources.pool.ProcessModel.UserName) -cne $Context.runtimeSid -or
            -not (Test-ClcIisHttpsBinding $manager $resources.site ([uri]$target.readinessUri)) -or
            -not (Test-ClcIisEnvironment $manager $resources $Context.environment -SkipApplicationConfiguration:$Context.ignoreLiveWebConfig)) {
            Stop-ClcError Clc.IisSettings 'The site, pool, runtime account or HTTPS binding changed during deployment.'
        }
    } finally { $manager.Dispose() }
    foreach ($name in $script:ClcHostDirectories) {
        Assert-ClcStoragePath (Join-Path $Context.layout.root $name) -Directory
    }
    Assert-ClcApplicationAcl $Context.layout.application $Context.runtimeSid
    foreach ($path in @($Context.layout.root,$Context.layout.deployment)) {
        Assert-ClcRuntimeAccess $path $Context.runtimeSid Protected
    }
    Assert-ClcSafeDescendants $Context.layout.keys
    $file=$Context.configurationFile
    Assert-ClcRuntimeAccess $Context.layout.config $Context.runtimeSid Read
    Assert-ClcRuntimeAccess $Context.layout.keys $Context.runtimeSid Write
    Assert-ClcRuntimeAccess $Context.layout.logs $Context.runtimeSid Write
    $file.stream.Position=0
    try {
        $current=Read-ClcStream $file.stream 4194304 ([Diagnostics.Stopwatch]::StartNew()) -Seconds 30
        if ($current.sha256 -cne $file.sha256) { Stop-ClcError Clc.ConfigurationInvalid 'External application configuration changed during the attempt.' }
    } finally { $file.stream.Position=0 }
}

function Assert-ClcQuiescent {
    param($Context)
    $iis=Get-ClcLiveIisState $Context
    if ($iis.siteState -cne 'Stopped' -or $iis.poolState -cne 'Stopped' -or $iis.workerCount -ne 0 -or
        $iis.siteAutoStart -or $iis.poolAutoStart) {
        Stop-ClcError Clc.IisStateUnknown 'Replacement requires a stopped site, stopped pool, zero workers and disabled automatic startup.'
    }
}
function Assert-ClcReplacementSafe {
    param($Context)
    Assert-ClcEffectContext $Context
    Assert-ClcQuiescent $Context
}

function Stop-ClcApplication {
    param($Context)
    Invoke-ClcIisChange $Context DisableStartup
    Invoke-ClcIisChange $Context StopSite
    Invoke-ClcIisChange $Context StopPool
    $null=Wait-ClcIisState $Context Stopped
    Assert-ClcQuiescent $Context
}

function Start-ClcApplication {
    param($Context,$Manifest,$Configuration)
    $Context.ignoreLiveWebConfig=$false
    Assert-ClcReplacementSafe $Context
    Invoke-ClcIisChange $Context StartPool
    Invoke-ClcIisChange $Context StartSite
    $null=Wait-ClcIisState $Context Started
    $null=Wait-ClcApplicationReady $Context $Manifest $Configuration
    Assert-ClcEffectContext $Context
    $null=Get-ClcTreeInventory $Context.layout.application $Manifest.files -RuntimeSid $Context.runtimeSid
    Invoke-ClcIisChange $Context EnableStartup
    $iis=Wait-ClcApplicationReady $Context $Manifest $Configuration
    if (-not $iis.siteAutoStart -or -not $iis.poolAutoStart -or $iis.siteState -cne 'Started' -or
        $iis.poolState -cne 'Started' -or $iis.workerCount -ne 1) {
        Stop-ClcError Clc.IisStateUnknown 'Could not confirm the commissioned IIS site, pool, worker and automatic-start flags.'
    }
    return $iis
}

function Assert-ClcOrdering {
    param($State,$Tag,[string] $ArchiveSha256,$Previous,[string] $Repository)
    if ($null -ne $Previous -and $Previous.source.repository -cne $Repository) {
        Stop-ClcError Clc.ReleaseMismatch 'The candidate source repository differs from the current deployment.'
    }
    if ($null -eq $State.highWater) { return }
    $previousTag=Get-ClcDeploymentTag $State.highWater.tag
    if ($previousTag.channel -cne $Tag.channel -or $Tag.releaseSequence -lt $previousTag.releaseSequence) {
        Stop-ClcError Clc.SupersededRelease 'The target has already selected a higher release or a different deployment channel.'
    }
    if ($Tag.releaseSequence -eq $previousTag.releaseSequence -and
        ($Tag.tag -cne $previousTag.tag -or $ArchiveSha256 -cne $State.highWater.archiveSha256)) {
        Stop-ClcError Clc.ReleaseMismatch 'This release tag was already recorded with different artifact bytes.'
    }
}
function New-ClcCurrent {
    param($Reference,$Configuration)
    return @{release=$Reference;configurationRevision=$Configuration.revision;keyStoreCompatibilityId=$Configuration.keyStoreCompatibilityId;
        environment=$Configuration.runtimeEnvironment;readyUtc=(Get-ClcUtc)}
}
function New-ClcDeploymentResult {
    param([string] $Status,$Context,$Reference,$Paths,$Iis,[string] $ReleaseId)
    return [pscustomobject][ordered]@{status=$Status;applicationId=$Context.target.applicationId;targetId=$Context.target.targetId;
        releaseId=$ReleaseId;attemptId=$Reference.attemptId;retainedPath=$Paths.root;siteState=$Iis.siteState;poolState=$Iis.poolState;
        workerCount=$Iis.workerCount;siteAutoStart=$Iis.siteAutoStart;poolAutoStart=$Iis.poolAutoStart}
}
function Stop-ClcFailedAttempt {
    param($ErrorRecord,$Context,$Attempt,$Paths,[bool] $IisEffects)
    $finding=Get-ClcSafeFinding $ErrorRecord
    $Attempt.errorCode=$finding.code
    try { Write-ClcLocalRecord $Paths.journal $Attempt -Replace } catch { }
    if ($IisEffects) {
        # Each operation independently rechecks the dedicated IIS association.
        # Try both stops even if disabling startup or one stop failed.
        foreach ($operation in @('DisableStartup','StopSite','StopPool')) {
            try { Invoke-ClcIisChange $Context $operation } catch { }
        }
        try { $null=Wait-ClcIisState $Context Stopped } catch { }
    }
    $iis=@{siteState='Unknown';poolState='Unknown';workerCount='Unknown';siteAutoStart='Unknown';poolAutoStart='Unknown'}
    try { $iis=Get-ClcLiveIisState $Context } catch { }
    $message=$finding.message+' Attempt '+$Attempt.release.attemptId+' retained at '+$Paths.root+
        '. Site '+$iis.siteState+', pool '+$iis.poolState+', workers '+$iis.workerCount+
        ', site auto-start '+$iis.siteAutoStart+', pool auto-start '+$iis.poolAutoStart+
        '. Inspect the attempt and reconcile uncertain IIS state before explicit recovery.'
    Stop-ClcError $finding.code $message
}

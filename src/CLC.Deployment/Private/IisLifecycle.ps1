function Invoke-ClcNativeIis {
    param([string] $AppcmdPath,[ValidateSet('Stop','Start')][string] $Operation,[string] $ApplicationPoolName)
    return [Clc.Lifecycle.Native]::Iis($AppcmdPath,$Operation,$ApplicationPoolName)
}
function Start-ClcIisHelper {
    param($Lock,[ValidateSet('Stop','Start')][string] $Operation,[Diagnostics.Stopwatch] $Clock=$null)
    Assert-ClcHelperProtection $Lock.context
    if ($null -ne $Clock -and $Clock.Elapsed.TotalSeconds -ge 30) { Stop-ClcError Clc.HelperQuiescenceUnknown }
    return Invoke-ClcNativeIis $Lock.context.policyFile.record.appcmdPath $Operation $Lock.identity.snapshot.applicationPoolName
}
function Get-ClcPoolObservation {
    param($Lock)
    $manager=$null
    try {
        $manager=New-ClcMwaServerManager (Get-ClcAdmittedMwaType $Lock.context)
        $pool=$manager.ApplicationPools[$Lock.identity.snapshot.applicationPoolName]
        if ($null -eq $pool) { Stop-ClcError Clc.HostPreflightFailed }
        return @{poolState=$pool.State.ToString();workerCount=[long]@($manager.WorkerProcesses | Where-Object AppPoolName -IEQ $pool.Name).Count}
    } catch { Stop-ClcError Clc.HostPreflightFailed }
    finally { if ($null -ne $manager) { $manager.Dispose() } }
}
function Get-ClcLivePool {
    param($Lock)
    Assert-ClcLockOwned $Lock
    return Get-ClcPoolObservation $Lock
}
function Assert-ClcIisQuiescent {
    param($Lock)
    $pool=Get-ClcLivePool $Lock
    if ($pool.poolState -cne 'Stopped' -or $pool.workerCount -ne 0) { Stop-ClcError Clc.ShutdownTimeout }
}
function Invoke-ClcIisLifecycle {
    param($Session,[ValidateSet('Stop','Start')][string] $Operation,[switch] $Safety)
    $lock=$Session.lock; $clock=[Diagnostics.Stopwatch]::StartNew()
    if ($Safety) { $null=Assert-ClcLockedTarget $lock }
    else { $null=Assert-ClcEffectAuthority $Session -Stopped:($Operation -ceq 'Start') }
    $expected=if ($Operation -ceq 'Start') {'Started'} else {'Stopped'}
    $pool=Get-ClcLivePool $lock
    if ($pool.poolState -cne $expected -or ($expected -ceq 'Stopped' -and $pool.workerCount -ne 0)) {
        $null=Invoke-ClcTrackedHelper $Session $Operation
    } else {
        $null=Write-ClcJournalIntent $lock $Operation
    }
    do {
        $pool=Get-ClcLivePool $lock
        Assert-ClcIisDeadline $clock $Operation
        if ($pool.poolState -ceq $expected -and $pool.workerCount -le 1 -and ($expected -ceq 'Started' -or $pool.workerCount -eq 0)) { return $pool }
        Start-Sleep -Milliseconds 250
    } while ((Get-ClcIisElapsed $clock) -lt 60)
    Assert-ClcIisDeadline $clock $Operation
}
function Get-ClcIisElapsed { param([Diagnostics.Stopwatch] $Clock) return $Clock.Elapsed.TotalSeconds }
function Assert-ClcIisDeadline {
    param([Diagnostics.Stopwatch] $Clock,[string] $Operation)
    if ((Get-ClcIisElapsed $Clock) -ge 60) {
        if ($Operation -ceq 'Start') { Stop-ClcError Clc.StartupFailed }
        Stop-ClcError Clc.ShutdownTimeout
    }
}

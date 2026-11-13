BeforeAll {
    . "$PSScriptRoot/Support.ps1"; . "$PSScriptRoot/T2Support.ps1"
    function New-TestMwaSnapshot {
        $global:ClcMwaCreated++
        $target=$global:ClcMwaTarget
        $app=[pscustomobject]@{Path='/';ApplicationPoolName=$target.applicationPoolName;VirtualDirectories=@([pscustomobject]@{Path='/';PhysicalPath=$global:ClcMwaRoot})}
        $site=[pscustomobject]@{Name=$target.siteName;State='Started';Applications=@($app);Bindings=@([pscustomobject]@{
            Protocol='https';Host='synthetic.invalid';EndPoint=[Net.IPEndPoint]::new([Net.IPAddress]::Loopback,443)})}
        $pool=[pscustomobject]@{Name=$target.applicationPoolName;State=$global:ClcMwaState;ProcessModel=[pscustomobject]@{
            IdentityType='SpecificUser';UserName='synthetic-account';MaxProcesses=1L};Recycling=[pscustomobject]@{DisallowOverlappingRotation=$true};Enable32BitAppOnWin64=$false}
        $pool | Add-Member ScriptMethod GetCollection { param($Name) return @() }
        $manager=[pscustomobject]@{Sites=@($site);ApplicationPools=@($pool);WorkerProcesses=@($global:ClcMwaWorkers | ForEach-Object {
            [pscustomobject]@{AppPoolName=$target.applicationPoolName;ProcessId=$_}
        })}
        $manager | Add-Member ScriptMethod GetWebConfiguration { param($Name) return $global:ClcMwaWebConfig }
        $manager | Add-Member ScriptMethod GetApplicationHostConfiguration { return $global:ClcMwaHostConfig }
        $manager | Add-Member ScriptMethod Dispose { $global:ClcMwaDisposed++ }
        return $manager
    }
}
Describe 'Fresh MWA configuration, state and worker observations without read subprocesses' {
    BeforeEach {
        $workspace=New-TestWorkspace
        $target=@{siteName='Synthetic';applicationPoolName='Dedicated';runtimeIdentitySid='S-1-5-20';applicationRoot=$workspace}
        $global:ClcMwaTarget=$target; $global:ClcMwaRoot=$workspace; $global:ClcMwaState='Stopped'; $global:ClcMwaWorkers=@()
        $global:ClcMwaCreated=0; $global:ClcMwaDisposed=0
        $global:ClcMwaWebSection=[pscustomobject]@{}
        $global:ClcMwaWebSection | Add-Member ScriptMethod GetCollection { param($Name) return @() }
        $global:ClcMwaWebConfig=[pscustomobject]@{}
        $global:ClcMwaWebConfig | Add-Member ScriptMethod GetSection { param($Name) return $global:ClcMwaWebSection }
        $global:ClcMwaHostSection=[pscustomobject]@{}
        $global:ClcMwaHostSection | Add-Member ScriptMethod GetCollection { return @(@{name='AspNetCoreModuleV2';image='C:\synthetic\aspnetcorev2.dll'}) }
        $global:ClcMwaHostConfig=[pscustomobject]@{}
        $global:ClcMwaHostConfig | Add-Member ScriptMethod GetSection { param($Name) return $global:ClcMwaHostSection }
        Mock -ModuleName CLC.Deployment Assert-ClcHelperDependencies { }
        Mock -ModuleName CLC.Deployment Get-ClcAdmittedMwaType { return [Management.Automation.PSObject] }
        Mock -ModuleName CLC.Deployment New-ClcMwaServerManager { return New-TestMwaSnapshot }
        Mock -ModuleName CLC.Deployment Resolve-ClcAccountSid { return 'S-1-5-20' }
        Mock -ModuleName CLC.Deployment Invoke-ClcIisReadQuery { throw 'Read subprocess is forbidden.' }
    }
    AfterEach { Remove-TestWorkspace $workspace }
    It 'creates and disposes a fresh manager and observes a restart with its new workers' {
        $first=Invoke-T2Private Get-ClcIisObservation @(@{},$target)
        $first.poolState | Should -Be Stopped; $first.workers.Count | Should -Be 0
        $global:ClcMwaState='Started'; $global:ClcMwaWorkers=@(1234L)
        $second=Invoke-T2Private Get-ClcIisObservation @(@{},$target)
        $second.poolState | Should -Be Started; $second.workers[0] | Should -Be 1234
        $global:ClcMwaCreated | Should -Be 2; $global:ClcMwaDisposed | Should -Be 2
        Should -Invoke -ModuleName CLC.Deployment Invoke-ClcIisReadQuery -Times 0 -Exactly
    }
    It 'observes and rejects <Case> before a stable effect' -ForEach @(@{Case='transitional-state'},@{Case='extra-worker'},@{Case='binding-drift'}) {
        if ($Case -ceq 'transitional-state') { $global:ClcMwaState='Starting' }
        elseif ($Case -ceq 'extra-worker') { $global:ClcMwaState='Started'; $global:ClcMwaWorkers=@(1234L,1235L) }
        else { $global:ClcMwaRoot=Join-Path $workspace 'different' }
        $facts=Invoke-T2Private Get-ClcIisObservation @(@{},$target)
        Test-TestRejection { Invoke-T2Private Assert-ClcStableIisObservation @($target,$facts,'Dedicated') } 'Clc.HostPreflightFailed*'
        $global:ClcMwaDisposed | Should -Be 1
    }
    It 'reads the current canonical pool names through a disposed manager without appcmd' {
        @(Invoke-T2Private Get-ClcIisPoolNames @(@{})) | Should -Be @('Dedicated')
        $global:ClcMwaCreated | Should -Be 1; $global:ClcMwaDisposed | Should -Be 1
        Should -Invoke -ModuleName CLC.Deployment Invoke-ClcIisReadQuery -Times 0 -Exactly
    }
}

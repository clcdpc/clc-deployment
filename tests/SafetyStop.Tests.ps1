BeforeAll {
    . "$PSScriptRoot/Support.ps1"; . "$PSScriptRoot/T2Support.ps1"; . "$PSScriptRoot/T3Support.ps1"
    $global:ClcSafetyActualIis=& (Get-Module Clc.Deployment) {(Get-Command Get-ClcIisObservation).ScriptBlock}
    function New-SafetyStopMwaManager {
        $fixture=$global:ClcTestFixture;$target=$fixture.target
        $app=[pscustomobject]@{Path='/';ApplicationPoolName=$target.applicationPoolName;VirtualDirectories=@([pscustomobject]@{Path='/';PhysicalPath=$global:ClcSafetySelectedRoot})}
        $site=[pscustomobject]@{Name=$target.siteName;State='Started';Applications=@($app);Bindings=@([pscustomobject]@{
            Protocol='https';Host='synthetic.invalid';EndPoint=[Net.IPEndPoint]::new([Net.IPAddress]::Loopback,443)})}
        $foreignApp=[pscustomobject]@{Path='/';ApplicationPoolName=$global:ClcSafetyForeign.poolName;VirtualDirectories=@([pscustomobject]@{Path='/';PhysicalPath=$global:ClcSafetyForeign.physicalRoot})}
        $foreignSite=[pscustomobject]@{Name='OtherSite';State='Started';Applications=@($foreignApp)}
        $pool=[pscustomobject]@{Name=$target.applicationPoolName;State=$fixture.iis.poolState;ProcessModel=[pscustomobject]@{
            IdentityType='SpecificUser';UserName='synthetic-account';MaxProcesses=1L};Recycling=[pscustomobject]@{DisallowOverlappingRotation=$true};Enable32BitAppOnWin64=$false}
        $pool | Add-Member ScriptMethod GetCollection {param($Name) return @(@{name='ASPNETCORE_ENVIRONMENT';value='Production'})}
        $manager=[pscustomobject]@{Sites=@($site,$foreignSite);ApplicationPools=@($pool,[pscustomobject]@{Name='OtherPool';State=$global:ClcSafetyForeign.poolState});WorkerProcesses=@(
            @($fixture.iis.workers | ForEach-Object {[pscustomobject]@{AppPoolName=$target.applicationPoolName;ProcessId=$_}})
            @($global:ClcSafetyForeign.workers | ForEach-Object {[pscustomobject]@{AppPoolName='OtherPool';ProcessId=$_}})
        )}
        $manager | Add-Member ScriptMethod GetWebConfiguration {param($Name) return $global:ClcSafetyWebConfig}
        $manager | Add-Member ScriptMethod GetApplicationHostConfiguration {return $global:ClcSafetyHostConfig}
        $manager | Add-Member ScriptMethod Dispose { }
        return $manager
    }
}
Describe 'Bounded safety stop after a late foreign IIS root conflict' {
    BeforeEach {
        $fixture=New-T2Fixture;Set-T2FixtureInModule $fixture;Set-T3Mocks
        $otherWorkspace=New-TestWorkspace
        $global:ClcSafetySelectedRoot=$fixture.target.applicationRoot
        $global:ClcSafetyRuntimeSid=$fixture.target.runtimeIdentitySid
        $global:ClcSafetyForeign=@{poolName='OtherPool';poolState='Started';workers=@(9876L);physicalRoot=$otherWorkspace}
        $global:ClcSafetyWebSection=[pscustomobject]@{}
        $global:ClcSafetyWebSection | Add-Member ScriptMethod GetCollection {param($Name) return @()}
        $global:ClcSafetyWebConfig=[pscustomobject]@{}
        $global:ClcSafetyWebConfig | Add-Member ScriptMethod GetSection {param($Name) return $global:ClcSafetyWebSection}
        $global:ClcSafetyHostSection=[pscustomobject]@{}
        $global:ClcSafetyHostSection | Add-Member ScriptMethod GetCollection {return @(@{name='AspNetCoreModuleV2';image=$global:ClcTestFixture.policy.appcmdPath})}
        $global:ClcSafetyHostConfig=[pscustomobject]@{}
        $global:ClcSafetyHostConfig | Add-Member ScriptMethod GetSection {param($Name) return $global:ClcSafetyHostSection}
        Mock -ModuleName Clc.Deployment Assert-ClcHelperDependencies { }
        Mock -ModuleName Clc.Deployment Get-ClcAdmittedMwaType {return [Management.Automation.PSObject]}
        Mock -ModuleName Clc.Deployment New-ClcMwaServerManager {return New-SafetyStopMwaManager}
        Mock -ModuleName Clc.Deployment Resolve-ClcAccountSid {return $global:ClcSafetyRuntimeSid}
        # Preserve the real bounded MWA adapter and native physical-root checks.
        Mock -ModuleName Clc.Deployment Get-ClcIisObservation {
            param($Context,$Target,[switch] $SafetyStop)
            $iis=& $global:ClcSafetyActualIis $Context $Target -SafetyStop:$SafetyStop
            # Platform/runtime and host settings are synthetic. Hosted runners
            # have machine DOTNET_* tooling flags that correctly fail production
            # admission; they are not this fixture's managed application settings.
            $iis.environment=$global:ClcTestFixture.iis.environment
            return $iis
        }
        $context=$null;$lock=$null
    }
    AfterEach {
        Invoke-T2Private Exit-ClcDeploymentLock @($lock);Invoke-T2Private Close-ClcTrustedContext @($context)
        Remove-TestWorkspace $fixture.workspace;Remove-TestWorkspace $otherWorkspace
    }
    It 'stops only its selected started candidate and retains recovery evidence when another pool gains its root after Start' {
        $approval=New-T3Approval $fixture
        $global:ClcSafetyConflictInjected=$false
        Mock -ModuleName Clc.Deployment Invoke-ClcReadinessRequest {
            $result=Get-T3SyntheticReadiness
            $global:ClcTestFixture.iis.poolState | Should -BeExactly Started
            $global:ClcSafetyForeign.physicalRoot=$global:ClcTestFixture.target.applicationRoot
            $global:ClcSafetyForeignAtConflict=$global:ClcSafetyForeign | ConvertTo-Json -Compress
            $global:ClcSafetyConflictInjected=$true
            return $result
        }
        Test-TestRejection {Invoke-ClcIisDeployment example $approval.record.approvalId} 'Clc.HostPreflightFailed*'
        $global:ClcSafetyConflictInjected | Should -BeTrue -Because ('the synthetic candidate must reach readiness; observed lifecycle operations: '+($global:ClcLifecycle.operations -join ', '))
        Should -Invoke -ModuleName Clc.Deployment Start-ClcIisHelper -Times 1 -Exactly -ParameterFilter {$Operation -ceq 'Stop' -and $Lock.identity.snapshot.applicationPoolName -ceq $global:ClcTestFixture.target.applicationPoolName.ToUpperInvariant()}
        Should -Invoke -ModuleName Clc.Deployment Start-ClcIisHelper -Times 0 -Exactly -ParameterFilter {$Lock.identity.snapshot.applicationPoolName -ieq 'OtherPool'}
        $fixture.iis.poolState | Should -BeExactly Stopped;$fixture.iis.workers.Count | Should -Be 0
        $global:ClcSafetyForeign.poolState | Should -BeExactly Started;$global:ClcSafetyForeign.workers | Should -Be @(9876L)
        $journalPath=Join-Path $fixture.controlRoot 'journal.json'
        $journal=Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
        $journal.phase | Should -BeExactly RecoveryRequired;$journal.liveMutationIntent | Should -BeTrue;$journal.outcome | Should -BeNullOrEmpty
        $journal.failure.observedPoolState | Should -BeExactly Stopped;$journal.failure.workerCount | Should -Be 0
        $journal.nativeCall.operation | Should -BeExactly Stop;$journal.nativeCall.launchState | Should -BeExactly Exited
        $journal.backup.verified | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $fixture.controlRoot 'current.json') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $fixture.controlRoot ('staging\'+$journal.attemptId)) | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $fixture.controlRoot ('backups\'+$journal.attemptId+'\index.json')) | Should -BeTrue
        Get-TestTreeHashes $fixture.target.applicationRoot | Should -BeExactly (Get-TestTreeHashes $approval.publish)
        $before=Get-T2TreeHashes $fixture
        Test-TestRejection {Invoke-ClcIisDeployment example $approval.record.approvalId} 'Clc.HostPreflightFailed*'
        Test-TestRejection {Restore-ClcIisDeployment example $journal.attemptId AcceptCandidate incident} 'Clc.HostPreflightFailed*'
        Get-T2TreeHashes $fixture | Should -BeExactly $before
        $global:ClcSafetyForeign | ConvertTo-Json -Compress | Should -BeExactly $global:ClcSafetyForeignAtConflict
        Should -Invoke -ModuleName Clc.Deployment Get-ClcIisObservation -Times 1 -Exactly -ParameterFilter {$SafetyStop}
    }
    It 'retains selected <Drift> authority checks during a safety stop' -ForEach @(@{Drift='root'},@{Drift='pool-user'},@{Drift='runtime-identity'}) {
        $context=Invoke-T2Private Open-ClcTrustedContext
        $lock=Invoke-T2Private Enter-ClcDeploymentLock @($context,'example')
        $global:ClcSafetyForeign.physicalRoot=$fixture.target.applicationRoot
        $fixture.iis.poolState='Started';$fixture.iis.workers=@(4711L)
        switch ($Drift) {
            root {$global:ClcSafetySelectedRoot=$fixture.target.dataProtectionRoot}
            pool-user {$global:ClcSafetyForeign.poolName=$fixture.target.applicationPoolName}
            runtime-identity {$global:ClcSafetyRuntimeSid='S-1-5-18'}
        }
        Test-TestRejection {& (Get-Module Clc.Deployment) {param($Session) Invoke-ClcIisLifecycle $Session Stop -Safety} @{lock=$lock}} 'Clc.HostPreflightFailed*'
        Should -Invoke -ModuleName Clc.Deployment Start-ClcIisHelper -Times 0 -Exactly
    }
    It 'rejects a safety Start before target observation or helper launch' {
        Test-TestRejection {& (Get-Module Clc.Deployment) {Invoke-ClcIisLifecycle @{lock=$null} Start -Safety}} 'Clc.HostPreflightFailed*'
        Should -Invoke -ModuleName Clc.Deployment Get-ClcIisObservation -Times 0 -Exactly
        Should -Invoke -ModuleName Clc.Deployment Start-ClcIisHelper -Times 0 -Exactly
    }
}

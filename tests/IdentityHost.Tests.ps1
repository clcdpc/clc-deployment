BeforeAll { . "$PSScriptRoot/Support.ps1"; . "$PSScriptRoot/T2Support.ps1" }
Describe 'Canonical observed machine and actual pool identity' {
    BeforeEach { $fixture=New-T2Fixture; Set-T2FixtureInModule $fixture; Set-T2Mocks; $context=$null; $lock=$null }
    AfterEach { if ($lock) { Invoke-T2Private Exit-ClcDeploymentLock @($lock) }; if ($context) { Invoke-T2Private Close-ClcTrustedContext @($context) }; Remove-TestWorkspace $fixture.workspace }
    It 'matches an independently calculated UTF-8 NUL-delimited SHA-256 vector' {
        $literal=[byte[]](49,49,49,49,49,49,49,49,45,49,49,49,49,45,49,49,49,49,45,49,49,49,49,45,49,49,49,49,49,49,49,49,49,49,49,49,0,69,88,65,77,80,76,69,45,80,79,79,76)
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($literal)).ToLowerInvariant() | Should -Be $fixture.targetKey
        foreach ($name in @('example-pool','EXAMPLE-POOL','Example-Pool')) {
            $pool=Invoke-T2Private Get-ClcCanonicalPoolName @($name,@('Example-Pool'))
            (Invoke-T2Private Get-ClcTargetKey @($fixture.policy.machineIdentity,$pool)) | Should -Be $fixture.targetKey
        }
        (Invoke-T2Private Get-ClcTargetKey @($fixture.policy.machineIdentity,'EXAMPLE-POOL-2')) | Should -Not -Be $fixture.targetKey
    }
    It 'rejects missing, ambiguous, invalid, changed and sentinel UUIDs' -ForEach @(
        @{Values=@()},@{Values=@('bad')},@{Values=@('00000000-0000-0000-0000-000000000000')},
        @{Values=@('ffffffff-ffff-ffff-ffff-ffffffffffff')},@{Values=@('22222222-2222-2222-2222-222222222222')},
        @{Values=@('11111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111')}
    ) {
        $global:ClcTestUuid=$Values
        Mock -ModuleName CLC.Deployment Get-ClcMachineUuidObservation { return $global:ClcTestUuid }
        Test-TestRejection { Invoke-T2Private Get-ClcMachineIdentity @($fixture.policy.machineIdentity) } 'Clc.HostPreflightFailed*'
    }
    It 'rejects ambiguous, unsupported or missing actual pools' -ForEach @(
        @{Name='example-pool';Actual=@()},@{Name='example-pool';Actual=@('example-pool','EXAMPLE-POOL')},
        @{Name='bad name';Actual=@('bad name')},@{Name='éxample';Actual=@('éxample')},@{Name=('a'*65);Actual=@(('a'*65))}
    ) { Test-TestRejection { Invoke-T2Private Get-ClcCanonicalPoolName @($Name,$Actual) } }
    It 'maps alternate TargetIds to the same canonical lock and state paths' {
        $second=$fixture.target.Clone(); $second.targetId='alternate'; $second.applicationPoolName='EXAMPLE-POOL'
        Write-TestJson (Join-Path $fixture.layout.targetCatalogRoot 'alternate.json') $second
        $context=Invoke-T2Private Open-ClcTrustedContext
        $a=Invoke-T2Private Read-ClcProtectedTarget @($context,'example'); $b=Invoke-T2Private Read-ClcProtectedTarget @($context,'alternate')
        $ia=Invoke-T2Private Get-ClcTargetIdentity @($context,$a); $ib=Invoke-T2Private Get-ClcTargetIdentity @($context,$b)
        $ia.lockPath | Should -Be $ib.lockPath; $ia.controlRoot | Should -Be $ib.controlRoot
        (Invoke-T2Private Test-ClcValueEqual @($ia.snapshot,$ib.snapshot)) | Should -BeTrue
    }
    It 'refuses target root/site reassignment and missing enrollment without creating state' -ForEach @(@{Change='root'},@{Change='site'},@{Change='control'}) {
        if ($Change -ceq 'root') { $fixture.iis.applications[0].physicalPath=$fixture.target.artifactInboxRoot }
        elseif ($Change -ceq 'site') { $fixture.iis.applications[0].siteName='other-site' }
        else { Remove-Item -LiteralPath $fixture.controlRoot }
        $context=Invoke-T2Private Open-ClcTrustedContext
        Test-TestRejection { Invoke-T2Private Enter-ClcDeploymentLock @($context,'example') }
        @([IO.Directory]::EnumerateFileSystemEntries($fixture.policy.lockRoot)).Count | Should -Be 0
    }
    It 'rejects real lock-root or control-root junction substitution' -ForEach @(@{Root='lockRoot'},@{Root='controlStateRoot'}) {
        $path=$fixture.policy[$Root]
        if ($Root -ceq 'controlStateRoot') { Remove-Item -LiteralPath $fixture.controlRoot }
        Remove-Item -LiteralPath $path; $null=New-Item -ItemType Junction -Path $path -Target $fixture.target.artifactInboxRoot
        Test-TestRejection { Invoke-T2Private Open-ClcTrustedContext } 'Clc.UnsafePath*'
        Remove-Item -LiteralPath $path
    }
}
Describe 'Read-only host preflight with deterministic IIS observations' {
    BeforeEach {
        $fixture=New-T2Fixture; Set-T2FixtureInModule $fixture; Set-T2Mocks
        Mock -ModuleName CLC.Deployment Get-ClcPlatformObservation { return @{build='20348';productType=3L;is64Bit=$true;powershellMajor=7L} }
        Mock -ModuleName CLC.Deployment Get-ClcRuntimeObservation { return @{frameworks=@(@{name='Microsoft.NETCore.App';version='10.0.12'},@{name='Microsoft.AspNetCore.App';version='10.0.12'});ancmMajor=20L;ancmX64=$true;dotnetX64=$true} }
        Mock -ModuleName CLC.Deployment Assert-ClcHostAccess { }
        $context=Invoke-T2Private Open-ClcTrustedContext; $lock=Invoke-T2Private Enter-ClcDeploymentLock @($context,'example')
    }
    AfterEach { Invoke-T2Private Exit-ClcDeploymentLock @($lock); Invoke-T2Private Close-ClcTrustedContext @($context); Remove-TestWorkspace $fixture.workspace }
    It 'observes a stable stopped dedicated x64 Production pool without journal or application writes' {
        $before=Get-T2TreeHashes $fixture
        $result=Invoke-T2Private Get-ClcHostPreflight @($context,$lock.targetFile,$lock.identity,'net10.0')
        $result.poolState | Should -Be 'Stopped'; $result.workerCount | Should -Be 0; $result.qualified | Should -BeFalse
        (Get-T2TreeHashes $fixture) | Should -Be $before
    }
    It 'accepts <PoolState> with <Workers> workers without establishing readiness' -ForEach @(
        @{PoolState='Started';Workers=@()},@{PoolState='Started';Workers=@(42L)},@{PoolState='Stopped';Workers=@()}
    ) {
        $fixture.iis.poolState=$PoolState; $fixture.iis.workers=$Workers; $before=Get-T2TreeHashes $fixture
        $result=Invoke-T2Private Get-ClcHostPreflight @($context,$lock.targetFile,$lock.identity,'net10.0')
        $result.poolState | Should -Be $PoolState; $result.workerCount | Should -Be $Workers.Count
        $result.qualified | Should -BeFalse
        (Get-T2TreeHashes $fixture) | Should -Be $before
    }
    It 'keeps the configuration digest stable across idle, demand and pool-state transitions' {
        $digests=@(foreach ($observation in @(
            @{State='Started';Workers=@(42L)},@{State='Started';Workers=@()},
            @{State='Started';Workers=@(43L)},@{State='Stopped';Workers=@()}
        )) {
            $fixture.iis.poolState=$observation.State; $fixture.iis.workers=$observation.Workers
            (Invoke-T2Private Get-ClcHostPreflight @($context,$lock.targetFile,$lock.identity,'net10.0')).hostObservationSha256
        })
        @($digests | Select-Object -Unique).Count | Should -Be 1
    }
    It 'detects admitted changes to actual <Field> configuration in the digest' -ForEach @(
        @{Field='bindings'},@{Field='environment'},@{Field='runtime'}
    ) {
        $before=(Invoke-T2Private Get-ClcHostPreflight @($context,$lock.targetFile,$lock.identity,'net10.0')).hostObservationSha256
        if ($Field -ceq 'bindings') { $fixture.iis.bindings += @{protocol='http';host='synthetic.invalid';port=80L;address='127.0.0.1'} }
        elseif ($Field -ceq 'environment') { $fixture.iis.environment += @{name='SYNTHETIC_SETTING';value='changed';scope='Pool'} }
        else { Mock -ModuleName CLC.Deployment Get-ClcRuntimeObservation { return @{frameworks=@(@{name='Microsoft.NETCore.App';version='10.0.13'},@{name='Microsoft.AspNetCore.App';version='10.0.13'});ancmMajor=20L;ancmX64=$true;dotnetX64=$true} } }
        (Invoke-T2Private Get-ClcHostPreflight @($context,$lock.targetFile,$lock.identity,'net10.0')).hostObservationSha256 | Should -Not -Be $before
    }
    It 'ignores enumeration and object-property order in unchanged host configuration' {
        $fixture.iis.bindings += @{protocol='http';host='synthetic.invalid';port=80L;address='127.0.0.1'}
        $fixture.iis.environment += @{name='SYNTHETIC_SETTING';value='same';scope='Pool'}
        $before=(Invoke-T2Private Get-ClcHostPreflight @($context,$lock.targetFile,$lock.identity,'net10.0')).hostObservationSha256
        $fixture.iis.bindings=@($fixture.iis.bindings[1],$fixture.iis.bindings[0])
        $fixture.iis.environment=@($fixture.iis.environment[1],$fixture.iis.environment[0])
        (Invoke-T2Private Get-ClcHostPreflight @($context,$lock.targetFile,$lock.identity,'net10.0')).hostObservationSha256 | Should -Be $before
    }
    It 'rejects unsafe IIS <Field> observations' -ForEach @(
        @{Field='siteState';Value='Stopped'},@{Field='poolState';Value='Starting'},@{Field='poolState';Value='Stopping'},@{Field='poolState';Value='Unknown'},
        @{Field='maxProcesses';Value=2L},@{Field='disallowOverlappingRotation';Value=$false},@{Field='enable32Bit';Value=$true},
        @{Field='runtimeSid';Value='S-1-5-18'},@{Field='workers';Value=@(123L)},
        @{Field='applications';Value=@()},@{Field='bindings';Value=@()},
        @{Field='environment';Value=@(@{name='ASPNETCORE_ENVIRONMENT';value='Development';scope='Pool'})},
        @{Field='environment';Value=@(@{name='DOTNET_ENVIRONMENT';value='Testing';scope='Pool'})},
        @{Field='environment';Value=@(@{name='DOTNET_ENVIRONMENT';value='Staging';scope='Machine'},@{name='ASPNETCORE_ENVIRONMENT';value='Production';scope='Pool'})},
        @{Field='environment';Value=@(@{name='DOTNET_STARTUP_HOOKS';value='C:\untrusted.dll';scope='Pool'})}
    ) {
        $fixture.iis[$Field]=$Value; $before=Get-T2TreeHashes $fixture
        Test-TestRejection { Invoke-T2Private Get-ClcHostPreflight @($context,$lock.targetFile,$lock.identity,'net10.0') } 'Clc.HostPreflightFailed*'
        (Get-T2TreeHashes $fixture) | Should -Be $before
    }
    It 'rejects a shared pool and multiple workers while accepting an idle started dedicated pool' {
        $fixture.iis.applications += $fixture.iis.applications[0].Clone()
        Test-TestRejection { Invoke-T2Private Get-ClcHostPreflight @($context,$lock.targetFile,$lock.identity,'net10.0') } 'Clc.HostPreflightFailed*'
        $fixture.iis.applications=@($fixture.iis.applications[0]); $fixture.iis.poolState='Started'; $fixture.iis.workers=@()
        (Invoke-T2Private Get-ClcHostPreflight @($context,$lock.targetFile,$lock.identity,'net10.0')).workerCount | Should -Be 0
        $fixture.iis.workers=@(1L,2L)
        Test-TestRejection { Invoke-T2Private Get-ClcHostPreflight @($context,$lock.targetFile,$lock.identity,'net10.0') } 'Clc.HostPreflightFailed*'
    }
    It 'rejects unqualified runtime, x86 ANCM/dotnet and missing/unprovable access' -ForEach @(@{Case='runtime'},@{Case='x86'},@{Case='dotnet-x86'},@{Case='rights'}) {
        if ($Case -ceq 'rights') { Mock -ModuleName CLC.Deployment Assert-ClcHostAccess { throw 'Synthetic access observation unavailable' } }
        elseif ($Case -ceq 'runtime') { Mock -ModuleName CLC.Deployment Get-ClcRuntimeObservation { return @{frameworks=@();ancmMajor=19L;ancmX64=$true;dotnetX64=$true} } }
        elseif ($Case -ceq 'dotnet-x86') { Mock -ModuleName CLC.Deployment Get-ClcRuntimeObservation { return @{frameworks=@();ancmMajor=20L;ancmX64=$true;dotnetX64=$false} } }
        else { Mock -ModuleName CLC.Deployment Get-ClcRuntimeObservation { return @{frameworks=@();ancmMajor=20L;ancmX64=$false;dotnetX64=$true} } }
        Test-TestRejection { Invoke-T2Private Get-ClcHostPreflight @($context,$lock.targetFile,$lock.identity,'net10.0') } 'Clc.HostPreflightFailed*'
    }
}
Describe 'Protected ANCM dependency tree and native x64 header inspection' {
    BeforeEach {
        $fixture=New-T2Fixture; Set-T2FixtureInModule $fixture; Set-T2Mocks; $context=$null
        $ancmRoot=Join-Path $fixture.workspace 'binaries\ancm'; [void][IO.Directory]::CreateDirectory($ancmRoot)
        $ancmPath=Join-Path $ancmRoot 'aspnetcorev2.dll'; [IO.File]::WriteAllText($ancmPath,'synthetic; never loaded')
        Mock -ModuleName CLC.Deployment Invoke-ClcRuntimeReadQuery { throw 'Forbidden synthetic runtime query.' }
    }
    AfterEach { if ($context) { Invoke-T2Private Close-ClcTrustedContext @($context) }; Remove-TestWorkspace $fixture.workspace }
    It 'refuses runtime-writable ANCM directory or DLL before querying dotnet' -ForEach @(@{Leaf='directory'},@{Leaf='dll'}) {
        $global:ClcTestUnsafeAncm=if ($Leaf -ceq 'directory') { $ancmRoot } else { $ancmPath }
        Mock -ModuleName CLC.Deployment Assert-ClcAccess {
            if ($Path -ceq $global:ClcTestUnsafeAncm -and $DeniedWriters -ccontains $global:ClcTestFixture.target.runtimeIdentitySid) { Invoke-T2Private Stop-ClcError @('Clc.HostPreflightFailed') }
            return (Invoke-T2Private Get-ClcSecurityObservation @($Path)).sha256
        }
        $context=Invoke-T2Private Open-ClcTrustedContext
        $null=Invoke-T2Private Read-ClcProtectedTarget @($context,'example'); $before=Get-TestTreeHashes $fixture.workspace
        Test-TestRejection { Invoke-T2Private Get-ClcRuntimeObservation @($context,$ancmPath,$fixture.target.runtimeIdentitySid) } 'Clc.HostPreflightFailed*'
        Should -Invoke -ModuleName CLC.Deployment Invoke-ClcRuntimeReadQuery -Times 0 -Exactly
        (Get-TestTreeHashes $fixture.workspace) | Should -Be $before
    }
    It 'reads an actual held PE header and refuses x86 dotnet before a runtime query' {
        $pe=[byte[]]::new(128); $pe[0]=0x4d; $pe[1]=0x5a; $pe[60]=64; $pe[64]=0x50; $pe[65]=0x45; $pe[68]=0x4c; $pe[69]=1
        [IO.File]::WriteAllBytes($fixture.policy.dotnetPath,$pe)
        $pe[68]=0x64; $pe[69]=0x86; [IO.File]::WriteAllBytes($ancmPath,$pe)
        $context=Invoke-T2Private Open-ClcTrustedContext
        $null=Invoke-T2Private Read-ClcProtectedTarget @($context,'example')
        (Invoke-T2Private Get-ClcFileX64 @($context,$fixture.policy.dotnetPath)) | Should -BeFalse
        (Invoke-T2Private Get-ClcFileX64 @($context,$ancmPath)) | Should -BeTrue
        Test-TestRejection { Invoke-T2Private Get-ClcRuntimeObservation @($context,$ancmPath,$fixture.target.runtimeIdentitySid) } 'Clc.HostPreflightFailed*'
        Should -Invoke -ModuleName CLC.Deployment Invoke-ClcRuntimeReadQuery -Times 0 -Exactly
    }
}
Describe 'Actual NTFS ownership and current-token effective access observations' {
    BeforeEach { $workspace=New-TestWorkspace }
    AfterEach { Remove-TestWorkspace $workspace }
    It 'reads the actual owner, ACL and Authz current-token access without changing them' {
        $sid=Invoke-T2Private Get-ClcCallerSid; $before=(Get-Acl -LiteralPath $workspace).Sddl
        $observation=Invoke-T2Private Get-ClcSecurityObservation @($workspace)
        $observation.ownerSid | Should -Not -BeNullOrEmpty
        ((Invoke-T2Private Get-ClcEffectiveAccess @($observation.bytes,$sid)) -band 0x120089) | Should -Be 0x120089
        (Get-Acl -LiteralPath $workspace).Sddl | Should -Be $before
    }
    It 'rejects wrong ownership, unauthorized writable trustees and an unprovable token' {
        $observation=Invoke-T2Private Get-ClcSecurityObservation @($workspace)
        Test-TestRejection { Invoke-T2Private Assert-ClcAccess @($workspace,@('S-1-5-19'),@('S-1-5-19'),@()) } 'Clc.HostPreflightFailed*'
        Test-TestRejection { Invoke-T2Private Assert-ClcAccess @($workspace,@($observation.ownerSid),@(),@()) } 'Clc.HostPreflightFailed*'
        Mock -ModuleName CLC.Deployment Get-ClcEffectiveAccess { throw 'Synthetic inaccessible identity' }
        Test-TestRejection { Invoke-T2Private Assert-ClcAccess @($workspace,@($observation.ownerSid),@($observation.ownerSid,'S-1-5-18','S-1-5-32-544'),@('S-1-5-19')) }
    }
    It 'queries one actual Windows SMBIOS UUID without using hostname or a generated identity' {
        $values=@(Invoke-T2Private Get-ClcMachineUuidObservation)
        $values.Count | Should -Be 1
        $expected=[guid]::ParseExact($values[0],'D').ToString('D').ToLowerInvariant()
        (Invoke-T2Private Get-ClcMachineIdentity @($expected)) | Should -Be $expected
    }
    It 'rejects effective ancestor replacement/control rights even through an otherwise trusted group' -ForEach @(
        @{Mask=0x10000L;Identity='runtime'},@{Mask=0x40L;Identity='runtime'},@{Mask=0x40000L;Identity='runtime'},@{Mask=0x80000L;Identity='runtime'},
        @{Mask=0x10000L;Identity='other-deployment'},@{Mask=0x40L;Identity='other-deployment'},@{Mask=0x40000L;Identity='other-deployment'},@{Mask=0x80000L;Identity='other-deployment'}
    ) {
        $global:ClcTestAncestorMask=$Mask
        $global:ClcTestAncestorSid=if ($Identity -ceq 'runtime') { 'S-1-5-20' } else { 'S-1-5-21-1-2-3-1002' }
        Mock -ModuleName CLC.Deployment Get-ClcCallerSid { return 'S-1-5-19' }
        Mock -ModuleName CLC.Deployment Test-ClcAdministratorToken { return $true }
        Mock -ModuleName CLC.Deployment Get-ClcSecurityObservation {
            $raw=[Security.AccessControl.RawSecurityDescriptor]::new('O:SYG:SYD:(A;;FA;;;SY)(A;;FA;;;BA)')
            return @{ownerSid='S-1-5-18';dacl=$raw.DiscretionaryAcl;bytes=[byte[]]@(1);sha256=('a'*64)}
        }
        Mock -ModuleName CLC.Deployment Get-ClcEffectiveAccess { if ($Sid -ceq $global:ClcTestAncestorSid) { return $global:ClcTestAncestorMask }; return 0L }
        $context=@{layout=@{root=(Join-Path $workspace 'toolkit')};policyFile=@{record=@{infrastructureOwnerSids=@('S-1-5-18','S-1-5-32-544');deploymentSids=@('S-1-5-19','S-1-5-21-1-2-3-1002')}};ancestorPins=@{}}
        $before=(Get-Acl -LiteralPath $workspace).Sddl
        Test-TestRejection { Invoke-T2Private Assert-ClcTrustAncestors @($context,$context.layout.root,'S-1-5-20') } 'Clc.HostPreflightFailed*'
        (Get-Acl -LiteralPath $workspace).Sddl | Should -Be $before
    }
}

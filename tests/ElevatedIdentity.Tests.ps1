BeforeAll {
    . "$PSScriptRoot/Support.ps1"
    . "$PSScriptRoot/T2Support.ps1"
    function New-IdentityDescriptor([string] $Sddl) {
        $raw=[Security.AccessControl.RawSecurityDescriptor]::new($Sddl)
        $bytes=[byte[]]::new($raw.BinaryLength); $raw.GetBinaryForm($bytes,0)
        @{ownerSid=$raw.Owner.Value;dacl=$raw.DiscretionaryAcl;bytes=$bytes;sha256=(Invoke-T2Private Get-ClcBytesHash @(,$bytes))}
    }
}
Describe 'Elevated V1 deployment admission before effects' {
    BeforeEach { $fixture=New-T2Fixture; Set-T2FixtureInModule $fixture; Set-T2Mocks; $context=$null }
    AfterEach { if ($context) { Invoke-T2Private Close-ClcTrustedContext @($context) }; Remove-TestWorkspace $fixture.workspace }
    It 'admits an authorized SID with an enabled administrator role' {
        $context=Invoke-T2Private Open-ClcTrustedContext
        $context.executingToolkit.sourceCommit | Should -BeExactly ('a'*40)
        Should -Invoke -ModuleName CLC.Deployment Test-ClcAdministratorToken -Times 1 -Scope It
    }
    It 'refuses <Case> before any native query or control write' -ForEach @(
        @{Case='UAC-filtered administrator';Enabled=$false;Sid='S-1-5-19'},
        @{Case='nonadministrator';Enabled=$false;Sid='S-1-5-19'},
        @{Case='wrong elevated SID';Enabled=$true;Sid='S-1-5-20'}
    ) {
        $global:IdentityEnabled=$Enabled; $global:IdentitySid=$Sid
        Mock -ModuleName CLC.Deployment Test-ClcAdministratorToken { return $global:IdentityEnabled }
        Mock -ModuleName CLC.Deployment Get-ClcCallerSid { return $global:IdentitySid }
        $before=Get-T2TreeHashes $fixture
        Test-TestRejection { Invoke-T2Private Open-ClcTrustedContext } 'Clc.HostPreflightFailed*'
        Should -Invoke -ModuleName CLC.Deployment Get-ClcIisPoolNames -Times 0 -Exactly
        (Get-T2TreeHashes $fixture) | Should -BeExactly $before
        @([IO.Directory]::EnumerateFileSystemEntries($fixture.policy.lockRoot)).Count | Should -Be 0
    }
    It 'rechecks the enabled role at a later authority boundary' {
        $context=Invoke-T2Private Open-ClcTrustedContext
        Mock -ModuleName CLC.Deployment Test-ClcAdministratorToken { return $false }
        Test-TestRejection { Invoke-T2Private Assert-ClcTrustedContextUnchanged @($context) } 'Clc.HostPreflightFailed*'
    }
    It 'uses the actual current Windows enabled role without changing token or membership' {
        # Isolated runspace is unaffected by synthetic Pester role observations.
        $ps=[PowerShell]::Create()
        try {
            $null=$ps.AddScript({ param($manifest)
                Import-Module $manifest -Force
                $id=[Security.Principal.WindowsIdentity]::GetCurrent()
                try { $expected=[Security.Principal.WindowsPrincipal]::new($id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } finally { $id.Dispose() }
                @{expected=$expected;actual=(& (Get-Module CLC.Deployment) { Test-ClcAdministratorToken })}
            }.ToString()).AddArgument($script:ModulePath)
            $result=$ps.Invoke(); $ps.HadErrors | Should -BeFalse
            $result[0].actual | Should -Be $result[0].expected
        } finally { $ps.Dispose() }
    }
}
Describe 'Protected structure versus elevated effective authority' {
    BeforeEach {
        $global:IdentitySecurity=New-IdentityDescriptor 'O:SYG:SYD:(A;;FA;;;SY)(A;;FA;;;BA)(A;;FR;;;LS)'
        $global:RuntimeMutation=0L
        $context=@{policyFile=@{record=@{infrastructureOwnerSids=@('S-1-5-18','S-1-5-32-544');deploymentSids=@('S-1-5-19')}};layout=@{root='C:\owned\toolkit'};ancestorPins=@{}}
        Mock -ModuleName CLC.Deployment Get-ClcCallerSid { return 'S-1-5-19' }
        Mock -ModuleName CLC.Deployment Test-ClcAdministratorToken { return $true }
        Mock -ModuleName CLC.Deployment Get-ClcSecurityObservation { return $global:IdentitySecurity }
        Mock -ModuleName CLC.Deployment Get-ClcEffectiveAccess { if ($Sid -ceq 'S-1-5-19') { return 0x1f01ffL }; return (0x1200a9L -bor $global:RuntimeMutation) }
    }
    It 'accepts inherited Administrators authority while retaining runtime in denied writers' {
        $denied=Invoke-T2Private Get-ClcProtectedDeniedWriters @($context,'S-1-5-20')
        $denied | Should -Contain 'S-1-5-20'; $denied | Should -Not -Contain 'S-1-5-19'
        Invoke-T2Private Assert-ClcAccess @('C:\owned',$context.policyFile.record.infrastructureOwnerSids,$context.policyFile.record.infrastructureOwnerSids,@('S-1-5-19'),$denied) | Should -BeExactly $global:IdentitySecurity.sha256
        { Invoke-T2Private Assert-ClcTrustAncestors @($context,$context.layout.root,'S-1-5-20') } | Should -Not -Throw
    }
    It 'does not globally bypass DeniedWriters for an administrator' {
        Test-TestRejection { Invoke-T2Private Assert-ClcAccess @('C:\owned',@('S-1-5-18'),@('S-1-5-18','S-1-5-32-544'),@(),@('S-1-5-19')) } 'Clc.HostPreflightFailed*'
    }
    It 'accepts inherit-only creator-owner rights on an ancestor without treating them as parent replacement access' {
        $global:IdentitySecurity=New-IdentityDescriptor 'O:SYG:SYD:(A;;FA;;;SY)(A;;FA;;;BA)(A;OICIIO;GA;;;CO)'
        { Invoke-T2Private Assert-ClcTrustAncestors @($context,$context.layout.root,'S-1-5-20') } | Should -Not -Throw
    }
    It 'rejects an unexpected direct writable <Trustee> on installed resources' -ForEach @(
        @{Trustee='deployment';Sid='S-1-5-19'},@{Trustee='runtime';Sid='S-1-5-20'},@{Trustee='unrelated nonadministrator';Sid='S-1-5-21-1-2-3-9999'}
    ) {
        $global:IdentitySecurity=New-IdentityDescriptor ('O:SYG:SYD:(A;;FA;;;SY)(A;;FA;;;BA)(A;;FA;;;'+$Sid+')')
        Test-TestRejection { Invoke-T2Private Assert-ClcAccess @('C:\owned',@('S-1-5-18'),@('S-1-5-18','S-1-5-32-544'),@(),@('S-1-5-20')) } 'Clc.HostPreflightFailed*'
        Test-TestRejection { Invoke-T2Private Assert-ClcTrustAncestors @($context,$context.layout.root,'S-1-5-20') } 'Clc.HostPreflightFailed*'
    }
    It 'rejects protected ownership by <Owner>' -ForEach @(@{Owner='S-1-5-19'},@{Owner='S-1-5-20'},@{Owner='S-1-5-21-1-2-3-9999'}) {
        $global:IdentitySecurity=New-IdentityDescriptor ('O:'+$Owner+'G:SYD:(A;;FA;;;SY)(A;;FA;;;BA)')
        Test-TestRejection { Invoke-T2Private Assert-ClcAccess @('C:\owned',@('S-1-5-18'),@('S-1-5-18','S-1-5-32-544'),@(),@('S-1-5-20')) } 'Clc.HostPreflightFailed*'
        Test-TestRejection { Invoke-T2Private Assert-ClcTrustAncestors @($context,$context.layout.root,'S-1-5-20') } 'Clc.HostPreflightFailed*'
    }
    It 'rejects runtime effective <Mask> through an otherwise trusted group' -ForEach @(
        @{Mask=2L},@{Mask=4L},@{Mask=16L},@{Mask=256L},@{Mask=64L},@{Mask=65536L},@{Mask=262144L},@{Mask=524288L}
    ) {
        $global:RuntimeMutation=$Mask
        $denied=Invoke-T2Private Get-ClcProtectedDeniedWriters @($context,'S-1-5-20')
        Test-TestRejection { Invoke-T2Private Assert-ClcAccess @('C:\owned',@('S-1-5-18'),@('S-1-5-18','S-1-5-32-544'),@('S-1-5-19'),$denied) } 'Clc.HostPreflightFailed*'
    }
}
Describe 'Runtime access across actual host resource roles' {
    BeforeEach {
        $global:IdentityUnsafePath=''; $global:IdentityUnsafeMask=0L; $global:IdentityUnsafeOwner=$false
        $context=@{layout=@{root='C:\enrolled\toolkit';policyRoot='C:\enrolled\toolkit\policy';policyPath='C:\enrolled\toolkit\policy\host-policy.json'};
            policyFile=@{record=@{infrastructureOwnerSids=@('S-1-5-18','S-1-5-32-544');deploymentSids=@('S-1-5-19');
                targetCatalogRoot='C:\enrolled\toolkit\policy\targets';approvalCatalogRoot='C:\enrolled\toolkit\policy\approvals';lockRoot='C:\enrolled\locks';controlStateRoot='C:\enrolled\control'}}}
        $target=@{applicationRoot='C:\enrolled\app';artifactInboxRoot='C:\enrolled\inbox';operationalConfigPath='C:\enrolled\config\app.json';dataProtectionRoot='C:\enrolled\keys';runtimeIdentitySid='S-1-5-20'}
        $identity=@{controlRoot='C:\enrolled\control\target'}
        Mock -ModuleName CLC.Deployment Assert-ClcRuntimeIdentity { }
        Mock -ModuleName CLC.Deployment Get-ClcCallerSid { return 'S-1-5-19' }
        Mock -ModuleName CLC.Deployment Get-ClcSecurityObservation {
            $runtimeRights=if ($Path -ceq $global:IdentityUnsafePath) { '0x'+$global:IdentityUnsafeMask.ToString('x') } elseif ($Path -ceq 'C:\enrolled\keys') { '0x1301bf' } else { 'FRFX' }
            $owner=if ($Path -ceq $global:IdentityUnsafePath -and $global:IdentityUnsafeOwner) { 'S-1-5-20' } else { 'SY' }
            return New-IdentityDescriptor ('O:'+$owner+'G:SYD:(A;;FA;;;SY)(A;;FA;;;BA)(A;;'+$runtimeRights+';;;NS)')
        }
        Mock -ModuleName CLC.Deployment Get-ClcEffectiveAccess {
            if ($Sid -ceq 'S-1-5-19') { return 0x1f01ffL }
            $raw=[Security.AccessControl.RawSecurityDescriptor]::new($Descriptor,0)
            $ace=@($raw.DiscretionaryAcl | Where-Object { $_.SecurityIdentifier.Value -ceq 'S-1-5-20' })[0]
            return [long]$ace.AccessMask
        }
    }
    It 'permits intended runtime key Modify while denying protected writes' {
        { Invoke-T2Private Assert-ClcHostAccess @($context,$target,$identity) } | Should -Not -Throw
    }
    It 'rejects runtime <Right> on <Resource>' -ForEach @(
        @{Resource='binaries';Path='C:\enrolled\app';Mask=2L;Right='write'},
        @{Resource='control';Path='C:\enrolled\control';Mask=2L;Right='write'},
        @{Resource='locks';Path='C:\enrolled\locks';Mask=2L;Right='write'},
        @{Resource='approvals';Path='C:\enrolled\toolkit\policy\approvals';Mask=2L;Right='write'},
        @{Resource='toolkit';Path='C:\enrolled\toolkit';Mask=2L;Right='write'},
        @{Resource='configuration';Path='C:\enrolled\config\app.json';Mask=2L;Right='write'},
        @{Resource='parent';Path='C:\enrolled';Mask=64L;Right='DELETE_CHILD'},
        @{Resource='parent';Path='C:\enrolled';Mask=262144L;Right='WRITE_DAC'},
        @{Resource='parent';Path='C:\enrolled';Mask=524288L;Right='WRITE_OWNER'},
        @{Resource='policy';Path='C:\enrolled\toolkit\policy';Mask=262144L;Right='WRITE_DAC'},
        @{Resource='binaries';Path='C:\enrolled\app';Mask=524288L;Right='WRITE_OWNER'}
    ) {
        $global:IdentityUnsafePath=$Path; $global:IdentityUnsafeMask=$Mask
        Test-TestRejection { Invoke-T2Private Assert-ClcHostAccess @($context,$target,$identity) } 'Clc.HostPreflightFailed*'
    }
    It 'rejects unexpected runtime ownership of protected resources' {
        $global:IdentityUnsafePath=$target.operationalConfigPath; $global:IdentityUnsafeOwner=$true
        Test-TestRejection { Invoke-T2Private Assert-ClcHostAccess @($context,$target,$identity) } 'Clc.HostPreflightFailed*'
    }
    It 'rejects runtime key-root <Control> while preserving ordinary key Modify' -ForEach @(
        @{Control='WRITE_DAC';Mask=0x1701bfL;Owned=$false},@{Control='WRITE_OWNER';Mask=0x1b01bfL;Owned=$false},
        @{Control='ownership';Mask=0x1301bfL;Owned=$true}
    ) {
        $global:IdentityUnsafePath=$target.dataProtectionRoot; $global:IdentityUnsafeMask=$Mask; $global:IdentityUnsafeOwner=$Owned
        Test-TestRejection { Invoke-T2Private Assert-ClcHostAccess @($context,$target,$identity) } 'Clc.HostPreflightFailed*'
    }
}
Describe 'Runtime identity membership admission' {
    BeforeEach {
        $context=@{policyFile=@{record=@{infrastructureOwnerSids=@('S-1-5-18','S-1-5-32-544','S-1-5-21-1-2-3-1001');deploymentSids=@('S-1-5-21-1-2-3-1002')}}}
        Mock -ModuleName CLC.Deployment Get-ClcEffectiveAccess { return 0L }
    }
    It 'accepts the distinct nonadministrator runtime' { { Invoke-T2Private Assert-ClcRuntimeIdentity @($context,'S-1-5-21-1-2-3-1003') } | Should -Not -Throw }
    It 'rejects direct runtime overlap with <Sid>' -ForEach @(@{Sid='S-1-5-32-544'},@{Sid='S-1-5-18'},@{Sid='S-1-5-21-1-2-3-1001'},@{Sid='S-1-5-21-1-2-3-1002'}) {
        Test-TestRejection { Invoke-T2Private Assert-ClcRuntimeIdentity @($context,$Sid) } 'Clc.HostPreflightFailed*'
    }
    It 'rejects indirect runtime membership in <Role> using group-aware effective access' -ForEach @(
        @{Role='Administrators';Trustee='S-1-5-32-544'},@{Role='infrastructure';Trustee='S-1-5-21-1-2-3-1001'},@{Role='deployment';Trustee='S-1-5-21-1-2-3-1002'}
    ) {
        $global:IdentityPrivilegedTrustee=$Trustee
        Mock -ModuleName CLC.Deployment Get-ClcEffectiveAccess {
            $raw=[Security.AccessControl.RawSecurityDescriptor]::new($Descriptor,0)
            if (@($raw.DiscretionaryAcl | Where-Object { $_.SecurityIdentifier.Value -ceq $global:IdentityPrivilegedTrustee }).Count) { return 1L }
            return 0L
        }
        Test-TestRejection { Invoke-T2Private Assert-ClcRuntimeIdentity @($context,'S-1-5-21-1-2-3-1003') } 'Clc.HostPreflightFailed*'
    }
    It 'refuses unavailable runtime group evidence' {
        Mock -ModuleName CLC.Deployment Get-ClcEffectiveAccess { Invoke-T2Private Stop-ClcError @('Clc.HostPreflightFailed') }
        Test-TestRejection { Invoke-T2Private Assert-ClcRuntimeIdentity @($context,'S-1-5-21-1-2-3-1003') } 'Clc.HostPreflightFailed*'
    }
}

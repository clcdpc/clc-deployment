BeforeAll { . "$PSScriptRoot/Support.ps1"; . "$PSScriptRoot/T2Support.ps1" }
Describe 'Installed toolkit and independently protected selection' {
    BeforeEach { $fixture=New-T2Fixture; Set-T2FixtureInModule $fixture; Set-T2Mocks; $context=$null }
    AfterEach { if ($context) { Invoke-T2Private Close-ClcTrustedContext @($context) }; Remove-TestWorkspace $fixture.workspace }
    It 'verifies exact installed source, distribution, inventory and active policy bytes' {
        $context=Invoke-T2Private Open-ClcTrustedContext
        $context.executingToolkit.sourceCommit | Should -Be ('a'*40)
        $context.executingToolkit.inventorySha256 | Should -Be $fixture.policy.activeToolkit.inventorySha256
        Test-TestRejection { [IO.File]::WriteAllText($fixture.layout.policyPath,'tamper') } '*'
        Test-TestRejection { Invoke-T2Private Open-ClcTrustedContext @('C:\caller-policy') } '*'
    }
    It 'binds the loaded manifest and protected identities from a <RootKind> module location' -ForEach @(@{RootKind='canonical'},@{RootKind='legacy'}) {
        $installation=if ($RootKind -ceq 'legacy') { New-T2Fixture -LegacyTargetRoot } else { $fixture }
        $before=Get-T2TreeHashes $installation
        $powerShell=[PowerShell]::Create(); $pending=$null
        try {
            # This isolated runspace has no Pester mocks. Exercise the actual
            # resolver independently of the synthetic parent/child host layout.
            $null=$powerShell.AddScript({
                param($SourceManifest,$InstalledManifest,$ProgramData)
                $ErrorActionPreference='Stop'
                Import-Module $SourceManifest -Force
                try {
                    $null=& (Get-Module Clc.Deployment) { param($Root) function Get-ClcProgramDataRoot { $Root }; Get-ClcInstalledLayout example } $ProgramData
                    throw 'The source checkout unexpectedly resolved an installation.'
                } catch {
                    if ($_.FullyQualifiedErrorId -notlike 'Clc.ToolkitNotActive*') { throw }
                    $sourceRefusal=$_.FullyQualifiedErrorId
                }
                Remove-Module Clc.Deployment -Force
                Import-Module $InstalledManifest -Force
                $observation=& (Get-Module Clc.Deployment) {
                    param($Root)
                    function Get-ClcProgramDataRoot { $Root }
                    function Get-ClcCallerSid { 'S-1-5-19' }
                    function Test-ClcAdministratorToken { $true }
                    function Assert-ClcAccess { param($Path) (Get-ClcSecurityObservation $Path).sha256 }
                    function Assert-ClcTrustAncestors { }
                    function Assert-ClcRuntimeIdentity { }
                    function Assert-ClcHelperDependencies { }
                    $context=Open-ClcTrustedContext example
                    try {
                        $result=@{layout=$context.layout;applicationRefusal=$null;target=$null;wrongTargetRefusal=$null}
                        try { $result.target=(Read-ClcProtectedTarget $context example).record }
                        catch { if ($_.FullyQualifiedErrorId -notlike 'Clc.HostPreflightFailed*') { throw }; $result.applicationRefusal=$_.FullyQualifiedErrorId }
                    } finally { Close-ClcTrustedContext $context }
                    try { $null=Invoke-ClcIisDeployment -TargetId other -ReleaseApprovalId example-001 }
                    catch { $result.wrongTargetRefusal=$_.FullyQualifiedErrorId }
                    return $result
                } $ProgramData
                $observation.sourceRefusal=$sourceRefusal
                return $observation
            }.ToString()).AddArgument($script:ModulePath).AddArgument($installation.layout.manifestPath).AddArgument($installation.workspace)
            $pending=$powerShell.BeginInvoke()
            if (-not $pending.AsyncWaitHandle.WaitOne(30000)) { $powerShell.Stop(); throw 'Installed-layout observation exceeded its deadline.' }
            $observations=$powerShell.EndInvoke($pending)
            $powerShell.Streams.Error.Count | Should -Be 0
            $observations.Count | Should -Be 1
            $observations[0].sourceRefusal | Should -BeLike 'Clc.ToolkitNotActive*'
            $layout=$observations[0].layout
            $layout.targetId | Should -BeExactly 'example'
            if ($RootKind -ceq 'legacy') {
                $layout.applicationId | Should -BeExactly 'example'
                $observations[0].applicationRefusal | Should -BeLike 'Clc.HostPreflightFailed*'
                $observations[0].target | Should -BeNullOrEmpty
            } else {
                $layout.applicationId | Should -BeExactly 'probe'
                $observations[0].target.applicationId | Should -BeExactly 'probe'
                $observations[0].target.targetId | Should -BeExactly 'example'
            }
            $observations[0].wrongTargetRefusal | Should -BeLike 'Clc.HostPreflightFailed*'
            $layout.manifestPath | Should -BeExactly $installation.layout.manifestPath
            $layout.policyPath | Should -BeExactly $installation.layout.policyPath
            $layout.controlStateRoot | Should -BeExactly $installation.layout.controlStateRoot
            $layout.lockRoot | Should -BeExactly $installation.layout.lockRoot
            (Get-T2TreeHashes $installation) | Should -BeExactly $before
        } finally {
            if ($pending) { $pending.AsyncWaitHandle.Dispose() }
            $powerShell.Dispose()
            if ($RootKind -ceq 'legacy') { Remove-TestWorkspace $installation.workspace }
        }
    }
    It 'rejects a protected target record with a conflicting <Field> before deployment locking' -ForEach @(
        @{Field='applicationId'},@{Field='targetId'}
    ) {
        $targetPath=Join-Path $fixture.layout.targetCatalogRoot 'example.json'
        $fixture.target[$Field]='other'
        Write-TestJson $targetPath $fixture.target
        $before=Get-T2TreeHashes $fixture
        Test-TestRejection {Invoke-ClcIisDeployment -TargetId example -ReleaseApprovalId example-001} 'Clc.HostPreflightFailed*'
        Should -Invoke -ModuleName Clc.Deployment Get-ClcIisPoolNames -Times 0 -Exactly
        @([IO.Directory]::EnumerateFileSystemEntries($fixture.layout.lockRoot)).Count | Should -Be 0
        Get-T2TreeHashes $fixture | Should -BeExactly $before
    }
    It 'rejects reading another target through an already opened target context' {
        $context=Invoke-T2Private Open-ClcTrustedContext
        $before=Get-T2TreeHashes $fixture
        Test-TestRejection {Invoke-T2Private Read-ClcProtectedTarget @($context,'other')} 'Clc.HostPreflightFailed*'
        Get-T2TreeHashes $fixture | Should -BeExactly $before
    }
    It 'rejects a second target record on direct deployment entry before locking or mutation' {
        $other=$fixture.target | ConvertTo-Json -Depth 16 | ConvertFrom-Json -AsHashtable;$other.targetId='other'
        Write-TestJson (Join-Path $fixture.layout.targetCatalogRoot 'other.json') $other
        Test-TestRejection {Invoke-ClcIisDeployment -TargetId example -ReleaseApprovalId example-001} 'Clc.HostPreflightFailed*'
        @([IO.Directory]::EnumerateFileSystemEntries($fixture.layout.lockRoot)).Count | Should -Be 0
    }
    It 'rejects active <Field> drift' -ForEach @(
        @{Field='version';Value='0.2.0-dev'},@{Field='sourceCommit';Value=('b'*40)},
        @{Field='distributionSha256';Value=('b'*64)},@{Field='inventorySha256';Value=('b'*64)},
        @{Field='moduleManifestPath';Value='C:\caller\Clc.Deployment.psd1'}
    ) {
        $fixture.policy.activeToolkit[$Field]=$Value; Write-TestJson $fixture.layout.policyPath $fixture.policy
        Test-TestRejection { Invoke-T2Private Open-ClcTrustedContext } 'Clc.ToolkitNotActive*'
    }
    It 'rejects altered, additional and missing installed module bytes' -ForEach @(@{Mode='altered'},@{Mode='additional'},@{Mode='missing'}) {
        $path=Join-Path $fixture.layout.moduleRoot 'Clc.Deployment.psm1'
        switch ($Mode) { altered {[IO.File]::AppendAllText($path,'tamper')}; additional {[IO.File]::WriteAllText((Join-Path $fixture.layout.moduleRoot 'extra.ps1'),'tamper')}; missing {Remove-Item -LiteralPath $path} }
        Test-TestRejection { Invoke-T2Private Open-ClcTrustedContext } 'Clc.ToolkitNotActive*'
    }
    It 'rejects missing protected metadata and unsupported policy' -ForEach @(@{Mode='missing'},@{Mode='unsupported'}) {
        if ($Mode -ceq 'missing') { Remove-Item -LiteralPath $fixture.layout.policyPath }
        else { $fixture.policy.schemaVersion=2; Write-TestJson $fixture.layout.policyPath $fixture.policy }
        Test-TestRejection { Invoke-T2Private Open-ClcTrustedContext }
    }
    It 'rejects catalog path replacement and a real junction alias' {
        $fixture.policy.approvalCatalogRoot=$fixture.target.artifactInboxRoot; Write-TestJson $fixture.layout.policyPath $fixture.policy
        Test-TestRejection { Invoke-T2Private Open-ClcTrustedContext } 'Clc.ToolkitNotActive*'
        $fixture.policy.approvalCatalogRoot=$fixture.layout.approvalCatalogRoot; Write-TestJson $fixture.layout.policyPath $fixture.policy
        Remove-Item -LiteralPath $fixture.layout.approvalCatalogRoot
        $null=New-Item -ItemType Junction -Path $fixture.layout.approvalCatalogRoot -Target $fixture.target.artifactInboxRoot
        Test-TestRejection { Invoke-T2Private Open-ClcTrustedContext } 'Clc.UnsafePath*'
        Remove-Item -LiteralPath $fixture.layout.approvalCatalogRoot
    }
    It 'detects policy or ACL observations changing during validation' -ForEach @(@{Changed='policy'},@{Changed='acl'}) {
        $context=Invoke-T2Private Open-ClcTrustedContext
        if ($Changed -ceq 'policy') { $context.policyFile.sha256='b'*64 }
        else { $context.pathPins[$fixture.layout.policyPath].aclSha256='b'*64 }
        Test-TestRejection { Invoke-T2Private Assert-ClcTrustedContextUnchanged @($context) } 'Clc.ToolkitNotActive*'
    }
    It 'checks protected approval and complete actual archive without authorizing deployment' {
        $approval=New-T2Approval $fixture; $before=Get-TestTreeHashes $fixture.workspace
        $context=Invoke-T2Private Open-ClcTrustedContext
        $release=Invoke-T2Private Read-ClcApprovedRelease @($context,$fixture.target.targetId,$approval.record.approvalId)
        $release.approvalVerified | Should -BeTrue; $release.authorizedForDeployment | Should -BeFalse
        $release.inspection.authorizedForDeployment | Should -BeFalse
        (Get-TestTreeHashes $fixture.workspace) | Should -Be $before
        Test-TestRejection { [IO.File]::AppendAllText($approval.path,'tamper') } '*'
        Test-TestRejection { [IO.File]::AppendAllText($release.archive.path,'tamper') } '*'
    }
    It 'rejects approval <Field> mismatch before any state or target write' -ForEach @(
        @{Field='enabled';Value=$false;Code='Clc.ApprovalDisabled*'},@{Field='targetId';Value='other';Code='Clc.ApprovalMismatch*'},
        @{Field='applicationId';Value='other';Code='Clc.ApprovalMismatch*'},@{Field='sourceRepository';Value='synthetic/other';Code='Clc.ApprovalMismatch*'},
        @{Field='sourceCommit';Value=('b'*40);Code='Clc.ApprovalMismatch*'},@{Field='releaseZipSha256';Value=('b'*64);Code='Clc.ApprovalMismatch*'},
        @{Field='manifestSha256';Value=('b'*64);Code='Clc.ApprovalMismatch*'},@{Field='lineageId';Value='../other';Code='Clc.InvalidContract*'}
    ) {
        $approval=New-T2Approval $fixture; $approval.record[$Field]=$Value; Write-TestJson $approval.path $approval.record
        $before=Get-TestTreeHashes $fixture.workspace; $context=Invoke-T2Private Open-ClcTrustedContext
        Test-TestRejection { Invoke-T2Private Read-ClcApprovedRelease @($context,$fixture.target.targetId,$approval.record.approvalId) } $Code
        (Get-TestTreeHashes $fixture.workspace) | Should -Be $before
    }
    It 'does not accept forged adjacent approval JSON or an altered retained archive' -ForEach @(@{Mode='adjacent'},@{Mode='tampered'}) {
        $approval=New-T2Approval $fixture
        if ($Mode -ceq 'adjacent') {
            Copy-Item -LiteralPath $approval.path -Destination (Join-Path $fixture.target.artifactInboxRoot 'example-001.json')
            Remove-Item -LiteralPath $approval.path
        } else { [IO.File]::AppendAllText((Join-Path $fixture.target.artifactInboxRoot ($approval.record.approvalId+'.zip')),'tamper') }
        $context=Invoke-T2Private Open-ClcTrustedContext
        Test-TestRejection { Invoke-T2Private Read-ClcApprovedRelease @($context,$fixture.target.targetId,$approval.record.approvalId) }
        @([IO.Directory]::EnumerateFileSystemEntries($fixture.controlRoot)).Count | Should -Be 0
    }
    It 'rejects malformed provenance and changed approval snapshot' {
        $approval=New-T2Approval $fixture; $approval.record.provenance.runAttempt=99; Write-TestJson $approval.path $approval.record
        $context=Invoke-T2Private Open-ClcTrustedContext
        Test-TestRejection { Invoke-T2Private Read-ClcApprovedRelease @($context,$fixture.target.targetId,$approval.record.approvalId) } 'Clc.ApprovalMismatch*'
    }
    It 'rejects policy namespace relocation even when the alternate root already exists' -ForEach @(@{Field='lockRoot'},@{Field='controlStateRoot'}) {
        $fixture.policy[$Field]=$fixture.target.artifactInboxRoot; Write-TestJson $fixture.layout.policyPath $fixture.policy
        Test-TestRejection { Invoke-T2Private Open-ClcTrustedContext } 'Clc.ToolkitNotActive*'
    }
    It 'rechecks an approval pin at the next boundary instead of consuming old inspection output' {
        $approval=New-T2Approval $fixture; $context=Invoke-T2Private Open-ClcTrustedContext
        $release=Invoke-T2Private Read-ClcApprovedRelease @($context,$fixture.target.targetId,$approval.record.approvalId)
        $release.approvalFile.sha256='b'*64
        Test-TestRejection { Invoke-T2Private Assert-ClcApprovedReleaseUnchanged @($context,$release) } 'Clc.ApprovalMismatch*'
    }
    It 'refuses writable helper dependencies before the first IIS query or assembly load' -ForEach @(

        @{Relative='iis';Identity='runtime'},@{Relative='iis\Microsoft.Web.Administration.dll';Identity='runtime'}
    ) {
        $global:ClcTestUnsafeHelperPath=Join-Path $fixture.workspace ('binaries\'+$Relative)
        $global:ClcTestUnsafeHelperSid=if ($Identity -ceq 'runtime') { $fixture.target.runtimeIdentitySid } else { $fixture.policy.deploymentSids[0] }
        Mock -ModuleName Clc.Deployment Assert-ClcAccess {
            if ($Path -ceq $global:ClcTestUnsafeHelperPath -and $DeniedWriters -ccontains $global:ClcTestUnsafeHelperSid) { throw 'Synthetic helper dependency write access.' }
            return (Invoke-T2Private Get-ClcSecurityObservation @($Path)).sha256
        }
        $context=Invoke-T2Private Open-ClcTrustedContext; $before=Get-TestTreeHashes $fixture.workspace
        Test-TestRejection { Invoke-T2Private Enter-ClcDeploymentLock @($context,'example') }
        Should -Invoke -ModuleName Clc.Deployment Get-ClcIisPoolNames -Times 0 -Exactly
        Should -Invoke -ModuleName Clc.Deployment Get-ClcIisObservation -Times 0 -Exactly
        @([IO.Directory]::EnumerateFileSystemEntries($fixture.policy.lockRoot)).Count | Should -Be 0
        (Get-TestTreeHashes $fixture.workspace) | Should -Be $before
    }
    It 'refuses a native query before any protected target has established helper access' {
        $context=Invoke-T2Private Open-ClcTrustedContext
        Test-TestRejection { Invoke-T2Private Invoke-ClcIisReadQuery @($context,'PoolNames') } 'Clc.HostPreflightFailed*'
    }
    It 'rejects case variants of the fixed state and lock roots' -ForEach @(@{Field='lockRoot';Leaf='Locks'},@{Field='controlStateRoot';Leaf='Control'}) {
        $fixture.policy[$Field]=Join-Path $fixture.workspace $Leaf; Write-TestJson $fixture.layout.policyPath $fixture.policy
        Test-TestRejection { Invoke-T2Private Open-ClcTrustedContext } 'Clc.ToolkitNotActive*'
    }
    It 'rejects case-sensitive or unprovable directory mode before state or native operations' -ForEach @(@{Case='sensitive'},@{Case='unknown'}) {
        if ($Case -ceq 'sensitive') { Mock -ModuleName Clc.Deployment Get-ClcDirectoryCaseFlags { return 1L } }
        else { Mock -ModuleName Clc.Deployment Get-ClcDirectoryCaseFlags { throw 'Synthetic unavailable directory flags' } }
        $before=Get-TestTreeHashes $fixture.workspace
        Test-TestRejection { Invoke-T2Private Open-ClcTrustedContext }
        @([IO.Directory]::EnumerateFileSystemEntries($fixture.policy.lockRoot)).Count | Should -Be 0
        (Get-TestTreeHashes $fixture.workspace) | Should -Be $before
    }
}

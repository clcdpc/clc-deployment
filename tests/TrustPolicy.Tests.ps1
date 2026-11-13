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
    It 'derives installation solely from the loaded manifest location' {
        $before=Get-T2TreeHashes $fixture
        $powerShell=[PowerShell]::Create(); $pending=$null
        try {
            # This isolated runspace has no Pester mocks. Exercise the actual
            # resolver independently of the synthetic parent/child host layout.
            $null=$powerShell.AddScript({
                param($SourceManifest,$InstalledManifest)
                $ErrorActionPreference='Stop'
                Import-Module $SourceManifest -Force
                try {
                    $null=& (Get-Module CLC.Deployment) { Get-ClcInstalledLayout }
                    throw 'The source checkout unexpectedly resolved an installation.'
                } catch {
                    if ($_.FullyQualifiedErrorId -notlike 'Clc.ToolkitNotActive*') { throw }
                    $sourceRefusal=$_.FullyQualifiedErrorId
                }
                Remove-Module CLC.Deployment -Force
                Import-Module $InstalledManifest -Force
                $layout=& (Get-Module CLC.Deployment) { Get-ClcInstalledLayout }
                return @{sourceRefusal=$sourceRefusal;layout=$layout}
            }.ToString()).AddArgument($script:ModulePath).AddArgument($fixture.layout.manifestPath)
            $pending=$powerShell.BeginInvoke()
            if (-not $pending.AsyncWaitHandle.WaitOne(30000)) { $powerShell.Stop(); throw 'Installed-layout observation exceeded its deadline.' }
            $observations=$powerShell.EndInvoke($pending)
            @($powerShell.Streams.Error | Where-Object { $_.FullyQualifiedErrorId -notlike 'Clc.ToolkitNotActive*' }).Count | Should -Be 0
            $observations.Count | Should -Be 1
            $observations[0].sourceRefusal | Should -BeLike 'Clc.ToolkitNotActive*'
            $layout=$observations[0].layout
            $layout.manifestPath | Should -BeExactly $fixture.layout.manifestPath
            $layout.policyPath | Should -BeExactly $fixture.layout.policyPath
            $layout.controlStateRoot | Should -BeExactly (Join-Path $fixture.workspace 'control')
            $layout.lockRoot | Should -BeExactly $fixture.layout.lockRoot
            (Get-T2TreeHashes $fixture) | Should -BeExactly $before
        } finally {
            if ($pending) { $pending.AsyncWaitHandle.Dispose() }
            $powerShell.Dispose()
        }
    }
    It 'rejects active <Field> drift' -ForEach @(
        @{Field='version';Value='0.2.0-dev'},@{Field='sourceCommit';Value=('b'*40)},
        @{Field='distributionSha256';Value=('b'*64)},@{Field='inventorySha256';Value=('b'*64)},
        @{Field='moduleManifestPath';Value='C:\caller\CLC.Deployment.psd1'}
    ) {
        $fixture.policy.activeToolkit[$Field]=$Value; Write-TestJson $fixture.layout.policyPath $fixture.policy
        Test-TestRejection { Invoke-T2Private Open-ClcTrustedContext } 'Clc.ToolkitNotActive*'
    }
    It 'rejects altered, additional and missing installed module bytes' -ForEach @(@{Mode='altered'},@{Mode='additional'},@{Mode='missing'}) {
        $path=Join-Path $fixture.layout.moduleRoot 'CLC.Deployment.psm1'
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
        Mock -ModuleName CLC.Deployment Assert-ClcAccess {
            if ($Path -ceq $global:ClcTestUnsafeHelperPath -and $DeniedWriters -ccontains $global:ClcTestUnsafeHelperSid) { throw 'Synthetic helper dependency write access.' }
            return (Invoke-T2Private Get-ClcSecurityObservation @($Path)).sha256
        }
        $context=Invoke-T2Private Open-ClcTrustedContext; $before=Get-TestTreeHashes $fixture.workspace
        Test-TestRejection { Invoke-T2Private Enter-ClcDeploymentLock @($context,'example') }
        Should -Invoke -ModuleName CLC.Deployment Get-ClcIisPoolNames -Times 0 -Exactly
        Should -Invoke -ModuleName CLC.Deployment Get-ClcIisObservation -Times 0 -Exactly
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
        if ($Case -ceq 'sensitive') { Mock -ModuleName CLC.Deployment Get-ClcDirectoryCaseFlags { return 1L } }
        else { Mock -ModuleName CLC.Deployment Get-ClcDirectoryCaseFlags { throw 'Synthetic unavailable directory flags' } }
        $before=Get-TestTreeHashes $fixture.workspace
        Test-TestRejection { Invoke-T2Private Open-ClcTrustedContext }
        @([IO.Directory]::EnumerateFileSystemEntries($fixture.policy.lockRoot)).Count | Should -Be 0
        (Get-TestTreeHashes $fixture.workspace) | Should -Be $before
    }
}

BeforeAll {
    . "$PSScriptRoot/Support.ps1"
    . "$PSScriptRoot/HostEnrollment.Support.ps1"
    function New-HSecurity([string] $Sddl) {
        $raw=[Security.AccessControl.RawSecurityDescriptor]::new($Sddl);$bytes=[byte[]]::new($raw.BinaryLength);$raw.GetBinaryForm($bytes,0)
        @{ownerSid=$raw.Owner.Value;dacl=$raw.DiscretionaryAcl;bytes=$bytes;sha256=(Get-ClcBytesHash $bytes)}
    }
}
AfterAll {Remove-TestWorkspace $script:HBootstrapWorkspace}
Describe 'Enrollment schemas, output and fixed installation boundary' {
    BeforeEach {$fixture=New-HTestFixture;Set-HTestMocks $fixture;$session=$null}
    AfterEach {Close-HTestSession $session;Remove-TestWorkspace $fixture.workspace}
    It 'validates configuration, authorization and read-only result against standalone schemas' {
        Test-Json -Json (Get-Content -LiteralPath $fixture.configurationPath -Raw) -SchemaFile (Join-Path $script:RepositoryRoot 'schemas/deployment-configuration.schema.json') -ErrorAction Stop | Should -BeTrue
        Test-Json -Json (Get-Content -LiteralPath $fixture.authorizationPath -Raw) -SchemaFile (Join-Path $script:RepositoryRoot 'schemas/host-enrollment-authorization.schema.json') -ErrorAction Stop | Should -BeTrue
        $result=Invoke-HEnrollment $fixture.configurationPath synthetic-enroll Plan
        Test-Json -Json ($result | ConvertTo-Json -Depth 16) -SchemaFile (Join-Path $script:RepositoryRoot 'schemas/host-enrollment-result.schema.json') -ErrorAction Stop | Should -BeTrue
        $result.PlannedOperations | Should -Contain install-toolkit
        $result.PlannedOperations | Should -Contain enroll-target
        $result.PSObject.Properties.Name | Should -Not -Contain IisPreStateSha256
    }
    It 'keeps secret-derived IIS pre-state fingerprints out of public workflow results' {
        $fixture.snapshot.pool.environment += @{scope='Pool';name='EXAMPLE_PRIVATE_SETTING';value='SYNTHETIC_LOW_ENTROPY_SECRET'}
        $privateDigest=Get-HIisSnapshotHash $fixture.snapshot
        $result=Invoke-HEnrollment $fixture.configurationPath synthetic-enroll Plan
        $json=$result | ConvertTo-Json -Depth 16 -Compress
        $json | Should -Not -Match SYNTHETIC_LOW_ENTROPY_SECRET
        $json | Should -Not -Match ([regex]::Escape($privateDigest))
        $result.PSObject.Properties.Name | Should -Not -Contain IisPreStateSha256
    }
    It 'refuses a second installation root even with a matching independently-shaped config and policy' {
        $different=Join-Path $fixture.workspace 'other';$newLayout=Get-HLayout $different '0.1.0-dev.1'
        $fixture.configuration.enrollmentRoot=$different;$fixture.authorization.enrollmentRoot=$different
        foreach ($name in @('targetCatalogRoot','approvalCatalogRoot','controlStateRoot','lockRoot')) {$fixture.policy[$name]=$newLayout[$name]}
        $fixture.policy.activeToolkit.moduleManifestPath=$newLayout.manifestPath
        Write-TestJson $fixture.configurationPath $fixture.configuration
        $fixture.authorization.deploymentConfigurationSha256=(Get-FileHash -LiteralPath $fixture.configurationPath).Hash.ToLowerInvariant();Save-HTestAuthorization $fixture
        {Invoke-HEnrollment $fixture.configurationPath synthetic-enroll Apply} | Should -Throw
        Test-Path -LiteralPath $different | Should -BeFalse
    }
    It 'rejects a prospective physical alias before initialization intent or filesystem effects' {
        $global:HProspectiveApp=$fixture.target.applicationRoot
        $global:HProspectiveConfiguration=[IO.Path]::GetDirectoryName($fixture.target.operationalConfigPath)
        Mock Get-HProspectivePhysicalPath {
            if ($Path -ceq $global:HProspectiveApp) {return ($global:HProspectiveConfiguration+'\nested')}
            return $Path
        }
        $before=Get-TestTreeHashes $fixture.workspace
        {Invoke-HEnrollment $fixture.configurationPath synthetic-enroll Apply} | Should -Throw
        Get-TestTreeHashes $fixture.workspace | Should -BeExactly $before
        @([IO.Directory]::EnumerateFiles((Join-Path $fixture.authorityRoot 'evidence'))).Count | Should -Be 0
    }
    It 'computes a missing descendant physical path from its held native existing parent without creating it' {
        $parent=[IO.Path]::GetDirectoryName($fixture.target.operationalConfigPath);$path=Join-Path $parent 'missing\leaf'
        $handles=[Collections.Generic.List[IDisposable]]::new()
        try {
            $facts=Get-ClcPathObservation $parent $handles -Directory
            Get-HProspectivePhysicalPath $path $handles | Should -BeExactly (Join-Path $facts.PhysicalPath 'missing\leaf')
            Test-Path -LiteralPath $path | Should -BeFalse
        } finally {foreach ($handle in $handles) {$handle.Dispose()}}
    }
    It 'refuses unknown operation and attempted release approval authority in the setup record' {
        $fixture.authorization.permittedOperations += 'approve-release';Save-HTestAuthorization $fixture
        {Open-HSession $fixture.configurationPath synthetic-enroll} | Should -Throw
    }
    It 'keeps deployment.json and infrastructure executables out of application ZIPs' -ForEach @(@{Name='deployment.json'},@{Name='Initialize-ClcHostEnrollment.ps1'}) {
        $publish=New-TestPublish $fixture.workspace
        [IO.File]::WriteAllText((Join-Path $publish.PublishRoot $Name),'inert fixture')
        {New-ClcRelease @publish} | Should -Throw
        Test-Path -LiteralPath $publish.OutputPath | Should -BeFalse
    }
    It 'admits only dedicated ProgramData namespaces without modifying ProgramData' {
        $programData=[Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
        foreach ($suffix in @('CLC\Deployment\host-authorizations','clc-example-app\Config\application.json')) {
            {Assert-ClcProtectedPath (Join-Path $programData $suffix)} | Should -Not -Throw
        }
        foreach ($path in @($programData,(Join-Path $programData 'Microsoft\config'),(Join-Path $programData 'CLCOther\config'),(Join-Path $programData 'clc-\config'))) {
            {Assert-ClcProtectedPath $path} | Should -Throw
        }
    }
    It 'rejects runtime administrative/group authority before resource effects' {
        # Exercise the original group-aware production validator, not the fixture mock.
        $ps=[PowerShell]::Create()
        try {
            $null=$ps.AddScript({param($manifest)
                Import-Module $manifest -Force
                & (Get-Module CLC.Deployment) {
                    function Get-ClcEffectiveAccess {param($Descriptor,$Sid) 1L}
                    Assert-ClcRuntimeIdentity @{policyFile=@{record=@{infrastructureOwnerSids=@('S-1-5-18','S-1-5-32-544');deploymentSids=@('S-1-5-19')}}} 'S-1-5-20'
                }
            }).AddArgument($script:ModulePath)
            {$null=$ps.Invoke()} | Should -Throw
            $ps.HadErrors | Should -BeTrue
        } finally {$ps.Dispose()}
    }
}
Describe 'New-resource ACL templates and protected independent authority' {
    BeforeEach {
        $fixture=New-HTestFixture
        $session=@{authorization=$fixture.authorization;target=$fixture.target}
        $global:HCapturedAcl=$null
        Mock Set-Acl {$global:HCapturedAcl=$AclObject}
    }
    AfterEach {Remove-TestWorkspace $fixture.workspace}
    It 'never grants individual deployment write ACEs on <Role> infrastructure' -ForEach @(@{Role='Protected'},@{Role='Control'},@{Role='Authority'}) {
        Set-HNewResourceAcl $session (Join-Path $fixture.workspace 'new') $Role
        $raw=[Security.AccessControl.RawSecurityDescriptor]::new($global:HCapturedAcl.GetSecurityDescriptorBinaryForm(),0)
        $raw.Owner.Value | Should -BeExactly 'S-1-5-32-544'
        @($raw.DiscretionaryAcl | Where-Object {$_.SecurityIdentifier.Value -ceq $fixture.policy.deploymentSids[0]}).Count | Should -Be 0
        @($raw.DiscretionaryAcl | Where-Object {$_.SecurityIdentifier.Value -ceq $fixture.target.runtimeIdentitySid}).Count | Should -Be 0
    }
    It 'keeps independently stored intent ACLs within the static authority reader allowlist' {
        Set-HNewResourceAcl $session (Join-Path $fixture.authorityRoot 'evidence\intent.json') Authority -File
        $raw=[Security.AccessControl.RawSecurityDescriptor]::new($global:HCapturedAcl.GetSecurityDescriptorBinaryForm(),0)
        @($raw.DiscretionaryAcl | Where-Object {$_.SecurityIdentifier.Value -cnotin @('S-1-5-18','S-1-5-32-544')}).Count | Should -Be 0
        # The configured independent infrastructure user remains an owner/writer
        # of ordinary toolkit policy; it inherits admin access to this handoff.
        @($raw.DiscretionaryAcl | Where-Object {$_.SecurityIdentifier.Value -ceq $fixture.authorization.authoritySid}).Count | Should -Be 0
    }
    It 'grants runtime only the intended key Modify or app ReadAndExecute' -ForEach @(@{Role='Keys';Mask=0x1301bfL},@{Role='Application';Mask=0x1200a9L}) {
        Set-HNewResourceAcl $session (Join-Path $fixture.workspace 'new') $Role
        $raw=[Security.AccessControl.RawSecurityDescriptor]::new($global:HCapturedAcl.GetSecurityDescriptorBinaryForm(),0)
        $runtime=@($raw.DiscretionaryAcl | Where-Object {$_.SecurityIdentifier.Value -ceq $fixture.target.runtimeIdentitySid})
        $runtime.Count | Should -Be 1
        ([long]$runtime[0].AccessMask -band 0x000C0000L) | Should -Be 0
        ([long]$runtime[0].AccessMask -band $Mask) | Should -Be $Mask
    }
    It 'rejects <Case> before reading approval bytes' -ForEach @(
        @{Case='owner'},@{Case='writer'},@{Case='parent-delete-child'},@{Case='parent-write-dac'},@{Case='parent-write-owner'}
    ) {
        $global:HBadCase=$Case;$global:HAuthorityLeaf=$fixture.authorityRoot
        Mock Get-ClcSecurityObservation {
            $owner=if ($global:HBadCase -ceq 'owner') {'NS'} else {'SY'}
            $extra=switch ($global:HBadCase) {writer {'(A;;FW;;;WD)'};parent-delete-child {if ($Path -cne $global:HAuthorityLeaf) {'(A;;0x40;;;WD)'}};parent-write-dac {if ($Path -cne $global:HAuthorityLeaf) {'(A;;WD;;;WD)'}};parent-write-owner {if ($Path -cne $global:HAuthorityLeaf) {'(A;;WO;;;WD)'}}}
            New-HSecurity ('O:'+$owner+'G:SYD:(A;;FA;;;SY)(A;;FA;;;BA)'+$extra)
        }
        $handles=[Collections.Generic.List[IDisposable]]::new()
        try {{Assert-HAuthorityProtection $fixture.authorityRoot $handles -Directory} | Should -Throw}
        finally {foreach ($handle in $handles) {$handle.Dispose()}}
    }
}

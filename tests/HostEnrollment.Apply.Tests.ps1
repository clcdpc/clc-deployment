BeforeAll {
    . "$PSScriptRoot/Support.ps1"
    . "$PSScriptRoot/HostEnrollment.Support.ps1"
    $script:distribution=New-HTestDistribution
}
AfterAll { Remove-TestWorkspace $script:distribution.workspace;Remove-TestWorkspace $script:HBootstrapWorkspace }
Describe 'Authorized initialization with real NTFS, distribution and protected-record readers' {
    BeforeEach {
        $session=$null; $fixture=New-HTestFixture; Set-HTestMocks $fixture; Set-HTestDistribution $fixture $script:distribution
    }
    AfterEach { Close-HTestSession $session; Remove-TestWorkspace $fixture.workspace }
    It 'installs exact approved bytes, enrolls last, and repeats without any mutation' {
        $configBefore=[IO.File]::ReadAllBytes($fixture.target.operationalConfigPath)
        $keyBefore=[IO.File]::ReadAllBytes((Join-Path $fixture.target.dataProtectionRoot 'key.xml'))
        $result=Invoke-HEnrollment $fixture.configurationPath synthetic-enroll Apply $distribution.archive
        $result.HostState | Should -BeExactly Ready
        $result.InitializationPerformed | Should -BeTrue
        $result.ApplicationReleaseApproved | Should -BeFalse
        $result.ApplicationReadinessVerified | Should -BeFalse
        $result.ActiveToolkitSourceCommit | Should -BeExactly $distribution.commit
        $targetPath=Join-Path $fixture.layout.targetCatalogRoot ($fixture.target.targetId+'.json')
        Test-Path -LiteralPath $targetPath | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $fixture.layout.versionRoot 'tools\host\Initialize-ClcHostEnrollment.ps1') | Should -BeTrue
        @([IO.Directory]::EnumerateFileSystemEntries($fixture.layout.approvalCatalogRoot)).Count | Should -Be 0
        $before=Get-TestTreeHashes $fixture.workspace
        $again=Invoke-HEnrollment $fixture.configurationPath synthetic-enroll Apply
        $again.ReadyForDeployment | Should -BeTrue
        $again.InitializationPerformed | Should -BeFalse
        Get-TestTreeHashes $fixture.workspace | Should -BeExactly $before
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.target.operationalConfigPath)) | Should -BeExactly ([Convert]::ToBase64String($configBefore))
        [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $fixture.target.dataProtectionRoot 'key.xml'))) | Should -BeExactly ([Convert]::ToBase64String($keyBefore))
        Should -Invoke Set-HNewResourceAcl -Times 0 -Exactly -ParameterFilter {$Path -ceq $fixture.target.dataProtectionRoot -or $Path -ceq $fixture.target.operationalConfigPath}
    }
    It 'refuses wrong approved distribution <Field> before toolkit provisioning' -ForEach @(@{Field='sourceCommit'},@{Field='distributionSha256'},@{Field='inventorySha256'}) {
        $fixture.policy.activeToolkit[$Field]=if ($Field -ceq 'sourceCommit') {'b'*40} else {'0'*64}; Save-HTestAuthorization $fixture
        {Invoke-HEnrollment $fixture.configurationPath synthetic-enroll Apply $distribution.archive} | Should -Throw
        Test-Path -LiteralPath $fixture.layout.root | Should -BeFalse
    }
    It 'creates missing application, inbox and key directories without installing configuration or key material' {
        [IO.File]::Delete((Join-Path $fixture.target.dataProtectionRoot 'key.xml'))
        foreach ($name in @('applicationRoot','artifactInboxRoot','dataProtectionRoot')) {
            [IO.Directory]::Delete($fixture.target[$name]);$fixture.authorization.resourceBindings[$name]=$null
        }
        Save-HTestAuthorization $fixture
        $result=Invoke-HEnrollment $fixture.configurationPath synthetic-enroll Apply $distribution.archive
        $result.ReadyForDeployment | Should -BeTrue
        foreach ($name in @('applicationRoot','artifactInboxRoot','dataProtectionRoot')) {
            [IO.Directory]::Exists($fixture.target[$name]) | Should -BeTrue
            @([IO.Directory]::EnumerateFileSystemEntries($fixture.target[$name])).Count | Should -Be 0
        }
    }
    It 'refuses absent operation authorization before installation' {
        $fixture.authorization.permittedOperations=@('enroll-target'); Save-HTestAuthorization $fixture
        {Invoke-HEnrollment $fixture.configurationPath synthetic-enroll Apply $distribution.archive} | Should -Throw
        Test-Path -LiteralPath $fixture.layout.root | Should -BeFalse
    }
    It 'retains interrupted initialization and refuses a retry using consumed authority' {
        Mock Invoke-HIisApply {throw 'synthetic before-publication failure'}
        {Invoke-HEnrollment $fixture.configurationPath synthetic-enroll Apply $distribution.archive} | Should -Throw
        Test-Path -LiteralPath $fixture.layout.policyPath | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $fixture.layout.targetCatalogRoot ($fixture.target.targetId+'.json')) | Should -BeFalse
        $before=Get-TestTreeHashes $fixture.workspace
        {Invoke-HEnrollment $fixture.configurationPath synthetic-enroll Apply $distribution.archive} | Should -Throw
        Get-TestTreeHashes $fixture.workspace | Should -BeExactly $before
    }
    It 'refuses missing target with historical canonical state, even when empty' {
        $null=Invoke-HEnrollment $fixture.configurationPath synthetic-enroll Apply $distribution.archive
        [IO.File]::Delete((Join-Path $fixture.layout.targetCatalogRoot ($fixture.target.targetId+'.json')))
        $result=Invoke-HEnrollment $fixture.configurationPath synthetic-enroll Inspect
        $result.HostState | Should -BeExactly RecoveryRequired
        {Invoke-HEnrollment $fixture.configurationPath synthetic-enroll Apply} | Should -Throw
    }
    It 'detects target mismatch, inactive pin and unknown policy content without repair' -ForEach @(@{Change='target'},@{Change='pin'},@{Change='policy'}) {
        $null=Invoke-HEnrollment $fixture.configurationPath synthetic-enroll Apply $distribution.archive
        switch ($Change) {
            target {$target=$fixture.target | ConvertTo-Json -Compress | ConvertFrom-Json -AsHashtable;$target.runtimeIdentitySid='S-1-5-19';Write-TestJson (Join-Path $fixture.layout.targetCatalogRoot ($target.targetId+'.json')) $target}
            pin {$fixture.policy.activeToolkit.sourceCommit='b'*40;Write-TestJson $fixture.layout.policyPath $fixture.policy}
            policy {[IO.File]::WriteAllText((Join-Path $fixture.layout.policyRoot 'foreign.json'),'{}')}
        }
        $before=Get-TestTreeHashes $fixture.workspace
        (Invoke-HEnrollment $fixture.configurationPath synthetic-enroll Inspect).ReadyForDeployment | Should -BeFalse
        {Invoke-HEnrollment $fixture.configurationPath synthetic-enroll Apply} | Should -Throw
        Get-TestTreeHashes $fixture.workspace | Should -BeExactly $before
    }
    It 'never overwrites historical deployment evidence or enables approvals' {
        $null=Invoke-HEnrollment $fixture.configurationPath synthetic-enroll Apply $distribution.archive
        $approval=Get-Content -LiteralPath (Join-Path $script:FixtureRoot 'release-approval.json') -Raw | ConvertFrom-Json -AsHashtable
        $approval.targetId=$fixture.target.targetId; $approval.enabled=$false
        $approvalPath=Join-Path $fixture.layout.approvalCatalogRoot ($approval.approvalId+'.json'); Write-TestJson $approvalPath $approval
        $key=Get-ClcTargetKey $fixture.policy.machineIdentity $fixture.target.applicationPoolName.ToUpperInvariant()
        $journal=Join-Path $fixture.layout.controlStateRoot ($key+'\journal.json'); [IO.File]::WriteAllText($journal,'unresolved retained evidence')
        $before=Get-TestTreeHashes $fixture.workspace
        (Invoke-HEnrollment $fixture.configurationPath synthetic-enroll Inspect).ReadyForDeployment | Should -BeFalse
        {Invoke-HEnrollment $fixture.configurationPath synthetic-enroll Apply} | Should -Throw
        Get-TestTreeHashes $fixture.workspace | Should -BeExactly $before
        (Get-Content -LiteralPath $approvalPath -Raw | ConvertFrom-Json).enabled | Should -BeFalse
    }
    It 'inspects a current release from its approval-pinned manifest without a historical ZIP' {
        $null=Invoke-HEnrollment $fixture.configurationPath synthetic-enroll Apply $distribution.archive
        $global:HManifestSelection=@{approvalFile=@{record=@{approvalId='manifest-only';releaseZipSha256=('0'*64);manifestSha256=('1'*64)}};
            manifest=@{applicationId='probe';releaseId='manifest-only';source=@{commit=('0'*40)};inventorySha256=(Get-ClcInventoryHash @());files=@()}}
        Mock Get-ClcReconciliationDecision {
            $Lock.state.current=@{record=@{release=(Get-ClcReleaseIdentity $global:HManifestSelection)}}
            return @{classification='Clean'}
        }
        Mock Read-ClcApprovedManifest { return $global:HManifestSelection }
        Mock Read-ClcApprovedRelease { throw 'Historical ZIPs are not part of enrollment inspection.' }
        $before=Get-TestTreeHashes $fixture.workspace
        (Invoke-HEnrollment $fixture.configurationPath synthetic-enroll Inspect).ReadyForDeployment | Should -BeTrue
        Should -Invoke Read-ClcApprovedManifest -Times 1 -Exactly
        Should -Invoke Read-ClcApprovedRelease -Times 0 -Exactly
        Get-TestTreeHashes $fixture.workspace | Should -BeExactly $before
    }
    It 'serializes against the actual canonical pool lock' {
        $null=Invoke-HEnrollment $fixture.configurationPath synthetic-enroll Apply $distribution.archive
        $key=Get-ClcTargetKey $fixture.policy.machineIdentity $fixture.target.applicationPoolName.ToUpperInvariant()
        $held=[Clc.Host.Native]::OpenLock((Join-Path $fixture.layout.lockRoot ($key+'.lock')))
        try {(Invoke-HEnrollment $fixture.configurationPath synthetic-enroll Inspect).ReadyForDeployment | Should -BeFalse}
        finally {$held.Dispose()}
    }
    It 'enrolls a second application without reinstalling or changing the first target, keys, approvals or state' {
        $null=Invoke-HEnrollment $fixture.configurationPath synthetic-enroll Apply $distribution.archive
        $firstTarget=Join-Path $fixture.layout.targetCatalogRoot ($fixture.target.targetId+'.json');$firstHash=(Get-FileHash -LiteralPath $firstTarget).Hash
        $toolkitBefore=Get-TestTreeHashes $fixture.layout.versionRoot
        $firstKeys=Get-TestTreeHashes $fixture.target.dataProtectionRoot
        $firstKeyRoot=$fixture.target.dataProtectionRoot
        Select-HSecondTestTarget $fixture
        $plan=Invoke-HEnrollment $fixture.configurationPath synthetic-second Plan
        $plan.HostState | Should -BeExactly TargetNotEnrolled
        $plan.PlannedOperations | Should -Not -Contain install-toolkit
        $result=Invoke-HEnrollment $fixture.configurationPath synthetic-second Apply
        $result.ReadyForDeployment | Should -BeTrue
        Get-TestTreeHashes $fixture.layout.versionRoot | Should -BeExactly $toolkitBefore
        (Get-FileHash -LiteralPath $firstTarget).Hash | Should -BeExactly $firstHash
        Get-TestTreeHashes $firstKeyRoot | Should -BeExactly $firstKeys
        @([IO.Directory]::EnumerateFiles($fixture.layout.targetCatalogRoot)).Count | Should -Be 2
    }
    It 'refuses cross-application <Collision> before selected target effects' -ForEach @(@{Collision='pool'},@{Collision='runtime'},@{Collision='keys'}) {
        $null=Invoke-HEnrollment $fixture.configurationPath synthetic-enroll Apply $distribution.archive
        $first=$fixture.target
        Select-HSecondTestTarget $fixture
        switch ($Collision) {
            pool {$fixture.configuration.applicationPoolName=$first.applicationPoolName}
            runtime {$fixture.configuration.runtimeIdentitySid=$first.runtimeIdentitySid}
            keys {$fixture.configuration.dataProtectionRoot=$first.dataProtectionRoot}
        }
        Write-TestJson $fixture.configurationPath $fixture.configuration
        $fixture.authorization.deploymentConfigurationSha256=(Get-FileHash -LiteralPath $fixture.configurationPath).Hash.ToLowerInvariant();Save-HTestAuthorization $fixture
        $before=Get-TestTreeHashes $fixture.workspace
        {Invoke-HEnrollment $fixture.configurationPath synthetic-second Apply} | Should -Throw
        Get-TestTreeHashes $fixture.workspace | Should -BeExactly $before
    }
    It 'refuses an orphan canonical lock even when the selected control root and target are absent' {
        $null=Invoke-HEnrollment $fixture.configurationPath synthetic-enroll Apply $distribution.archive
        [IO.File]::Delete((Join-Path $fixture.layout.targetCatalogRoot ($fixture.target.targetId+'.json')))
        $key=Get-ClcTargetKey $fixture.policy.machineIdentity $fixture.target.applicationPoolName.ToUpperInvariant()
        [IO.Directory]::Delete((Join-Path $fixture.layout.controlStateRoot $key))
        (Invoke-HEnrollment $fixture.configurationPath synthetic-enroll Inspect).HostState | Should -BeExactly RecoveryRequired
    }
    It 'does not let a new authorization bypass a consumed incomplete enrollment' {
        Mock Invoke-HIisApply {throw 'injected interruption'}
        {Invoke-HEnrollment $fixture.configurationPath synthetic-enroll Apply $distribution.archive} | Should -Throw
        $fixture.authorization.authorizationId='new-approval';$fixture.authorizationPath=Join-Path $fixture.authorityRoot 'new-approval.json';Save-HTestAuthorization $fixture
        $before=Get-TestTreeHashes $fixture.workspace
        {Invoke-HEnrollment $fixture.configurationPath new-approval Apply} | Should -Throw
        Get-TestTreeHashes $fixture.workspace | Should -BeExactly $before
    }
    It 'does not let another target bypass an unresolved first shared-toolkit installation intent' {
        Mock Install-HToolkit {throw 'injected before-install failure'}
        {Invoke-HEnrollment $fixture.configurationPath synthetic-enroll Apply $distribution.archive} | Should -Throw
        Test-Path -LiteralPath $fixture.layout.root | Should -BeFalse
        Select-HSecondTestTarget $fixture
        $before=Get-TestTreeHashes $fixture.workspace
        {Invoke-HEnrollment $fixture.configurationPath synthetic-second Apply $distribution.archive} | Should -Throw
        Get-TestTreeHashes $fixture.workspace | Should -BeExactly $before
    }
    It 'requires new target authority to bind the complete active host-policy generation' {
        $null=Invoke-HEnrollment $fixture.configurationPath synthetic-enroll Apply $distribution.archive
        $nextPolicy=$fixture.policy | ConvertTo-Json -Depth 16 -Compress | ConvertFrom-Json -AsHashtable;$nextPolicy.generation=2;Write-TestJson $fixture.layout.policyPath $nextPolicy
        (Invoke-HEnrollment $fixture.configurationPath synthetic-enroll Inspect).ReadyForDeployment | Should -BeTrue
        Select-HSecondTestTarget $fixture
        $before=Get-TestTreeHashes $fixture.workspace
        {Invoke-HEnrollment $fixture.configurationPath synthetic-second Apply} | Should -Throw
        Get-TestTreeHashes $fixture.workspace | Should -BeExactly $before
    }
}
Describe 'Stopped first cutover preserves exact unapproved legacy installation' {
    BeforeEach {
        $fixture=New-HTestFixture; Set-HTestMocks $fixture; Set-HTestDistribution $fixture $script:distribution; $session=$null
        $null=[IO.Directory]::CreateDirectory((Join-Path $fixture.target.applicationRoot 'nested'))
        [IO.File]::WriteAllText((Join-Path $fixture.target.applicationRoot 'old.dll'),'inert legacy application')
        [IO.File]::WriteAllText((Join-Path $fixture.target.applicationRoot 'nested\asset.txt'),'legacy asset')
        $inventory=Get-HLegacyInventory $fixture.target.applicationRoot
        $fixture.authorization.permittedOperations += 'first-cutover'
        $fixture.authorization.cutover=@{applicationRootIdentity=$inventory.rootIdentity;files=$inventory.files;inventorySha256=(Get-DistInventoryHash $inventory.files);backupRoot=(Join-Path $fixture.workspace 'legacy-backup')}
        Save-HTestAuthorization $fixture
    }
    AfterEach {Close-HTestSession $session;Remove-TestWorkspace $fixture.workspace}
    It 'verifies a retained backup before removing only authorized original files and never starts the pool' {

        $result=Invoke-HEnrollment $fixture.configurationPath synthetic-enroll Apply $distribution.archive
        $result.ReadyForDeployment | Should -BeTrue
        $result.ObservedPoolState | Should -BeExactly Stopped
        @([IO.Directory]::EnumerateFileSystemEntries($fixture.target.applicationRoot)).Count | Should -Be 0
        $backup=Join-Path $fixture.authorization.cutover.backupRoot 'original'
        (Get-HLegacyInventory $backup).files | ConvertTo-Json -Compress | Should -BeExactly ($inventory.files | ConvertTo-Json -Compress)
        (Get-Content -LiteralPath (Join-Path $fixture.authorization.cutover.backupRoot 'backup-index.json') -Raw | ConvertFrom-Json).toolkitApprovedRelease | Should -BeFalse
        [IO.File]::ReadAllText($fixture.target.operationalConfigPath) | Should -BeExactly CLC_SYNTHETIC_CONFIG_MUST_REMAIN_UNCHANGED
        [IO.File]::ReadAllText((Join-Path $fixture.target.dataProtectionRoot 'key.xml')) | Should -BeExactly CLC_SYNTHETIC_KEY_MUST_REMAIN_UNCHANGED
    }
    It 'refuses an extra file, empty directory, changed inventory or running pool before original removal' -ForEach @(@{Change='extra'},@{Change='empty'},@{Change='bytes'},@{Change='running'}) {
        switch ($Change) {
            extra {[IO.File]::WriteAllText((Join-Path $fixture.target.applicationRoot 'unknown.txt'),'unknown')}
            empty {$null=[IO.Directory]::CreateDirectory((Join-Path $fixture.target.applicationRoot 'unknown-empty'))}
            bytes {[IO.File]::WriteAllText((Join-Path $fixture.target.applicationRoot 'old.dll'),'changed')}
            running {$fixture.snapshot.pool.state='Started'}
        }
        $before=Get-TestTreeHashes $fixture.target.applicationRoot
        {Invoke-HEnrollment $fixture.configurationPath synthetic-enroll Apply $distribution.archive} | Should -Throw
        Get-TestTreeHashes $fixture.target.applicationRoot | Should -BeExactly $before
    }
}

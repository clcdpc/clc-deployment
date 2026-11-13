BeforeAll {
    . "$PSScriptRoot/Support.ps1"
    . "$PSScriptRoot/HostEnrollment.Support.ps1"
}
AfterAll { Remove-TestWorkspace $script:HBootstrapWorkspace }
Describe 'Host-local configuration and independent enrollment authorization' {
    BeforeEach { $fixture=New-HTestFixture; Set-HTestMocks $fixture; $session=$null }
    AfterEach { Close-HTestSession $session; Remove-TestWorkspace $fixture.workspace }
    It 'reads a strict configuration and produces an entirely read-only plan' {
        $before=Get-TestTreeHashes $fixture.workspace
        $result=Invoke-HEnrollment $fixture.configurationPath synthetic-enroll Plan
        $result.HostState | Should -BeExactly ToolkitNotInitialized
        $result.ReadyForDeployment | Should -BeFalse
        $result.InitializationPerformed | Should -BeFalse
        Get-TestTreeHashes $fixture.workspace | Should -BeExactly $before
        Test-Path -LiteralPath $fixture.configuration.enrollmentRoot | Should -BeFalse
    }
    It 'rejects <Case> before any provisioning' -ForEach @(
        @{Case='different host';Field='host'},@{Case='different target';Field='target'},@{Case='different config bytes';Field='configuration'},
        @{Case='different bootstrap';Field='bootstrap'},@{Case='wrong elevated caller';Field='caller'},@{Case='unelevated token';Field='token'},
        @{Case='self-declared authority';Field='authority'},@{Case='wrong canonical policy root';Field='policy'}
    ) {
        switch ($Field) {
            host { Mock Get-ClcMachineUuidObservation { 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' } }
            target { $fixture.authorization.targetId='different'; Save-HTestAuthorization $fixture }
            configuration { [IO.File]::AppendAllText($fixture.configurationPath,' ') }
            bootstrap { $fixture.authorization.bootstrap.inventorySha256='0'*64; Save-HTestAuthorization $fixture }
            caller { Mock Get-ClcCallerSid { 'S-1-5-20' } }
            token { Mock Test-ClcAdministratorToken { $false } }
            authority { $fixture.authorization.authoritySid=$fixture.policy.deploymentSids[0]; Save-HTestAuthorization $fixture }
            policy { $fixture.policy.controlStateRoot=Join-Path $fixture.workspace 'alternate'; Save-HTestAuthorization $fixture }
        }
        $before=Get-TestTreeHashes $fixture.workspace
        { Invoke-HEnrollment $fixture.configurationPath synthetic-enroll Apply } | Should -Throw
        Get-TestTreeHashes $fixture.workspace | Should -BeExactly $before
        Test-Path -LiteralPath $fixture.configuration.enrollmentRoot | Should -BeFalse
        Should -Invoke Set-HNewResourceAcl -Times 0 -Exactly
    }
    It 'requires a protected preexisting authorization rather than release metadata or caller hashes' {
        [IO.File]::Delete($fixture.authorizationPath)
        Write-TestJson (Join-Path $fixture.authorityRoot 'release.json') (Get-TestMetadata)
        { Open-HSession $fixture.configurationPath synthetic-enroll } | Should -Throw
        { Open-HSession $fixture.configurationPath release } | Should -Throw
        Test-Path -LiteralPath $fixture.configuration.enrollmentRoot | Should -BeFalse
    }
    It 'rejects expired, revoked and future authorizations at the mutation gate' -ForEach @(
        @{Case='expired'},@{Case='revoked'},@{Case='future'}
    ) {
        switch ($Case) {
            expired {$fixture.authorization.expiresUtc='2026-01-02T00:00:00Z'}
            revoked {$fixture.authorization.enabled=$false}
            future {$fixture.authorization.approvedUtc='2090-01-01T00:00:00Z'}
        }
        Save-HTestAuthorization $fixture
        $session=Open-HSession $fixture.configurationPath synthetic-enroll
        { Assert-HOperation $session enroll-target } | Should -Throw
        (Get-HEnrollmentState $session).HostState | Should -BeExactly ToolkitNotInitialized
        Should -Invoke Set-HNewResourceAcl -Times 0 -Exactly
    }
    It 'rejects <Field> in deployment.json without echoing its value' -ForEach @(
        @{Field='password'},@{Field='connectionString'},@{Field='releaseApprovalId'},@{Field='certificatePrivateKey'},@{Field='unknown'}
    ) {
        $fixture.configuration[$Field]='SYNTHETIC_DO_NOT_LOG'
        Write-TestJson $fixture.configurationPath $fixture.configuration
        $fixture.authorization.deploymentConfigurationSha256=(Get-FileHash -LiteralPath $fixture.configurationPath).Hash.ToLowerInvariant(); Save-HTestAuthorization $fixture
        try { Open-HSession $fixture.configurationPath synthetic-enroll; throw 'Expected refusal' }
        catch { $_.Exception.Message | Should -Not -Match SYNTHETIC_DO_NOT_LOG }
        Test-Path -LiteralPath $fixture.configuration.enrollmentRoot | Should -BeFalse
    }
    It 'rejects duplicate properties, legacy formats and scalar coercions' {
        foreach ($json in @('{"targetId":"a","TargetId":"b"}','{"contractFamily":"clc-host-enrollment-v1","schemaVersion":"1","recordKind":"deployment-configuration"}','{"schemaVersion":1}')) {
            { $value=Read-HJson ([Text.Encoding]::UTF8.GetBytes($json)); Assert-HConfiguration $value } | Should -Throw
        }
    }
    It 'refuses missing policy with partial <Resource>' -ForEach @(@{Resource='toolkit'},@{Resource='control'},@{Resource='locks'}) {
        $null=[IO.Directory]::CreateDirectory((Join-Path $fixture.configuration.enrollmentRoot $Resource))
        $result=Invoke-HEnrollment $fixture.configurationPath synthetic-enroll Inspect
        $result.HostState | Should -BeExactly Incomplete
        { Invoke-HEnrollment $fixture.configurationPath synthetic-enroll Apply } | Should -Throw
        Should -Invoke Set-HNewResourceAcl -Times 0 -Exactly
    }
    It 'refuses previous content without exact independent cutover approval' {
        [IO.File]::WriteAllText((Join-Path $fixture.target.applicationRoot 'unknown.dll'),'legacy application; never executed')
        $result=Invoke-HEnrollment $fixture.configurationPath synthetic-enroll Inspect
        $result.ReadyForDeployment | Should -BeFalse
        { Invoke-HEnrollment $fixture.configurationPath synthetic-enroll Apply } | Should -Throw
        Test-Path -LiteralPath (Join-Path $fixture.target.applicationRoot 'unknown.dll') | Should -BeTrue
    }
    It 'rejects wrong physical resource identity or ACL observation' -ForEach @(@{Field='fileId'},@{Field='securityDescriptorSha256'}) {
        $fixture.authorization.resourceBindings.applicationRoot[$Field]=if ($Field -ceq 'fileId') {'0'*16} else {'0'*64}
        Save-HTestAuthorization $fixture
        $result=Invoke-HEnrollment $fixture.configurationPath synthetic-enroll Inspect
        $result.HostState | Should -BeExactly DriftDetected
        { Invoke-HEnrollment $fixture.configurationPath synthetic-enroll Apply } | Should -Throw
    }
    It 'rejects overlapping application, keys, inbox and protected paths before effects' -ForEach @(@{Field='dataProtectionRoot'},@{Field='artifactInboxRoot'},@{Field='enrollmentRoot'}) {
        $fixture.configuration[$Field]=Join-Path $fixture.target.applicationRoot 'nested'
        Write-TestJson $fixture.configurationPath $fixture.configuration
        $fixture.authorization.deploymentConfigurationSha256=(Get-FileHash -LiteralPath $fixture.configurationPath).Hash.ToLowerInvariant(); Save-HTestAuthorization $fixture
        { Invoke-HEnrollment $fixture.configurationPath synthetic-enroll Apply } | Should -Throw
        Should -Invoke Set-HNewResourceAcl -Times 0 -Exactly
    }
}
Describe 'Exact IIS enrollment and stopped-only changes' {
    BeforeEach { $fixture=New-HTestFixture; Set-HTestMocks $fixture; $session=Open-HSession $fixture.configurationPath synthetic-enroll }
    AfterEach { Close-HTestSession $session; Remove-TestWorkspace $fixture.workspace }
    It 'reuses valid site and pool without a change' { (Get-HIisPlan $session).operations.Count | Should -Be 0 }
    It 'observes an unrelated HTTP binding without reading HTTPS-only certificate properties' {
        $binding=[pscustomobject]@{Protocol='http';Host='other.invalid';EndPoint=[Net.IPEndPoint]::new([Net.IPAddress]::Loopback,80)}
        $binding | Add-Member -MemberType ScriptProperty -Name CertificateHash -Value {throw 'HTTPS-only property was read'}
        $binding | Add-Member -MemberType ScriptProperty -Name CertificateStoreName -Value {throw 'HTTPS-only property was read'}
        $result=Get-HBindingSnapshot OtherSite $binding
        $result.certificateThumbprint | Should -BeExactly ''
        $result.protocol | Should -BeExactly http
    }
    It 'pins identical IIS pre-state despite nested property reordering' {
        $before=Get-HIisSnapshotHash $fixture.snapshot
        $reordered=$fixture.snapshot | ConvertTo-Json -Depth 16 -Compress | ConvertFrom-Json -AsHashtable
        $projection=[ordered]@{};foreach ($name in @($reordered.Keys | Sort-Object -Descending)) {$projection[$name]=$reordered[$name]}
        Get-HIisSnapshotHash $projection | Should -BeExactly $before
        $projection.pool.maxProcesses=2L
        Get-HIisSnapshotHash $projection | Should -Not -BeExactly $before
    }
    It 'refuses <Case> before mutation' -ForEach @(
        @{Case='wrong site root';Change='root'},@{Case='shared pool';Change='shared'},@{Case='invalid binding certificate';Change='certificate'},
        @{Case='conflicting HTTPS binding';Change='conflict'},@{Case='stopped pool with worker';Change='worker'},@{Case='missing runtime/ANCM';Change='prerequisite'},
        @{Case='untrusted certificate';Change='trust'},@{Case='running pool requiring settings';Change='running'},@{Case='machine environment override';Change='environment'},@{Case='disabled site autostart';Change='autostart'}
    ) {
        switch ($Change) {
            root {$fixture.snapshot.applications[0].physicalPath=Join-Path $fixture.workspace 'other'}
            shared {$fixture.snapshot.applications += @{siteName='other';path='/';poolName=$fixture.target.applicationPoolName;physicalPath='C:\other'}}
            certificate {$fixture.snapshot.bindings[0].certificateThumbprint='B'*40}
            conflict {$other=$fixture.snapshot.bindings[0].Clone();$other.siteName='other';$fixture.snapshot.bindings += $other}
            worker {$fixture.snapshot.pool.workers=@(123L)}
            prerequisite {Mock Get-HIisSnapshot { Stop-ClcError Clc.EnrollmentPrerequisiteMissing }}
            trust {Mock Assert-HCertificate { Stop-ClcError Clc.EnrollmentCertificateInvalid }}
            running {$fixture.snapshot.pool.state='Started';$fixture.snapshot.pool.maxProcesses=2L}
            environment {$fixture.snapshot.pool.environment += @{name='DOTNET_ENVIRONMENT';value='Development';scope='Machine'}}
            autostart {$fixture.snapshot.siteServerAutoStart=$false}
        }
        { Get-HIisPlan $session } | Should -Throw
        Should -Invoke Set-HNewResourceAcl -Times 0 -Exactly
    }
    It 'plans only explicitly authorized setting changes on a stopped pool for <Setting>' -ForEach @(
        @{Setting='maxProcesses';Value=2L},@{Setting='disallowOverlappingRotation';Value=$false},@{Setting='loadUserProfile';Value=$false},
        @{Setting='enable32Bit';Value=$true},@{Setting='managedRuntimeVersion';Value='v4.0'},@{Setting='managedPipelineMode';Value='Classic'}
    ) {
        $fixture.snapshot.pool[$Setting]=$Value
        $fixture.authorization.iis.expectedSnapshotSha256=Get-HIisSnapshotHash $fixture.snapshot
        Close-HTestSession $session; Save-HTestAuthorization $fixture; $session=Open-HSession $fixture.configurationPath synthetic-enroll
        $plan=Get-HIisPlan $session
        $plan.operations | Should -Contain configure-iis
        $fixture.snapshot.pool.workers=@(123L)
        { Invoke-HIisApply $session $plan } | Should -Throw
    }
    It 'rejects unapproved pre-state even when requested settings would be safe' {
        $fixture.snapshot.pool.maxProcesses=2L
        { Get-HIisPlan $session } | Should -Throw
    }
    It 'requires a locally installed managed service account for a new pool' {
        $fixture.snapshot.poolExists=$false; $fixture.snapshot.siteExists=$false; $fixture.snapshot.applications=@(); $fixture.snapshot.bindings=@(); $fixture.snapshot.pool=$null
        Mock Test-HManagedServiceAccount {$false}
        { Get-HIisPlan $session } | Should -Throw
    }
    It 'plans a missing dedicated site/pool only for an approved locally installed managed service account' {
        $fixture.snapshot.poolExists=$false;$fixture.snapshot.siteExists=$false;$fixture.snapshot.applications=@();$fixture.snapshot.bindings=@();$fixture.snapshot.pool=$null
        $fixture.authorization.iis.newPoolIdentityType='ManagedServiceAccount'
        $fixture.authorization.iis.expectedSnapshotSha256=Get-HIisSnapshotHash $fixture.snapshot
        Close-HTestSession $session;Save-HTestAuthorization $fixture;$session=Open-HSession $fixture.configurationPath synthetic-enroll
        Mock Test-HManagedServiceAccount {$true}
        $plan=Get-HIisPlan $session
        $plan.operations | Should -Contain create-site
        $plan.operations | Should -Contain create-pool
    }
    It 'applies only approved settings to the stopped selected pool through the narrow IIS adapter' {
        $fixture.snapshot.pool.maxProcesses=2L
        $fixture.authorization.iis.expectedSnapshotSha256=Get-HIisSnapshotHash $fixture.snapshot
        Close-HTestSession $session;Save-HTestAuthorization $fixture;$session=Open-HSession $fixture.configurationPath synthetic-enroll
        $pool=[pscustomobject]@{ManagedRuntimeVersion='v4.0';ManagedPipelineMode='Classic';Enable32BitAppOnWin64=$true;
            ProcessModel=[pscustomobject]@{MaxProcesses=2;LoadUserProfile=$false};Recycling=[pscustomobject]@{DisallowOverlappingRotation=$false};Variables=@(@{name='ASPNETCORE_ENVIRONMENT';value=$fixture.target.runtimeEnvironment})}
        $pool | Add-Member -MemberType ScriptMethod -Name GetCollection -Value {param($name) return ,$this.Variables}
        $global:HOtherPool=[pscustomobject]@{sentinel='unchanged'}
        $global:HManager=[pscustomobject]@{ApplicationPools=@{$fixture.target.applicationPoolName=$pool;OtherPool=$global:HOtherPool};Sites=@{};Selected=$pool}
        $global:HManager | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
        $global:HManager | Add-Member -MemberType ScriptMethod -Name CommitChanges -Value {
            $global:HFixture.snapshot.pool.maxProcesses=[long]$this.Selected.ProcessModel.MaxProcesses
        }
        Mock Open-HIisManager {$global:HManager}
        $plan=Get-HIisPlan $session
        Invoke-HIisApply $session $plan
        $pool.ProcessModel.MaxProcesses | Should -Be 1
        $pool.ProcessModel.LoadUserProfile | Should -BeTrue
        $pool.ManagedRuntimeVersion | Should -BeExactly ''
        $pool.ManagedPipelineMode | Should -BeExactly Integrated
        $pool.Recycling.DisallowOverlappingRotation | Should -BeTrue
        $global:HOtherPool.sentinel | Should -BeExactly unchanged
    }
    It 'never treats Started with zero workers as cutover quiescence' {
        $fixture.snapshot.pool.state='Started'; $fixture.snapshot.pool.workers=@()
        { Assert-HCutoverStopped $session } | Should -Throw
    }
}
Describe 'Native enrollment path and preservation boundaries' {
    BeforeEach {$fixture=New-HTestFixture;Set-HTestMocks $fixture;$session=Open-HSession $fixture.configurationPath synthetic-enroll}
    AfterEach {Close-HTestSession $session;Remove-TestWorkspace $fixture.workspace}
    It 'rejects native hard links and named directory streams before provisioning' {
        $path=Join-Path $fixture.target.applicationRoot 'foreign.dll';[IO.File]::WriteAllText($path,'retain me')
        $link=Join-Path $fixture.workspace 'hardlink';$null=New-Item -ItemType HardLink -Path $link -Target $path
        {Get-HLegacyInventory $fixture.target.applicationRoot} | Should -Throw
        [IO.File]::Delete($link)
        [IO.File]::WriteAllText(($fixture.target.applicationRoot+':foreign'),'retain stream')
        try {{Get-HLegacyInventory $fixture.target.applicationRoot} | Should -Throw} finally {[IO.File]::Delete(($fixture.target.applicationRoot+':foreign'))}
        [IO.File]::ReadAllText($path) | Should -BeExactly 'retain me'
    }
    It 'rejects a junction and dot/short/ADS spelling aliases' {
        $junction=Join-Path $fixture.workspace 'junction';$null=New-Item -ItemType Junction -Path $junction -Target $fixture.target.applicationRoot
        {Get-HLegacyInventory $junction} | Should -Throw
        Remove-Item -LiteralPath $junction
        foreach ($path in @(($fixture.target.applicationRoot+'\..\app'),($fixture.target.applicationRoot+':foreign'),($fixture.target.applicationRoot+'\CON.txt'))) {{Assert-ClcPathSpelling $path} | Should -Throw}
    }
    It 'publishes create-new records atomically and never overwrites an existing record' {
        $path=Join-Path $fixture.authorityRoot 'evidence\owned.json'
        $first=Write-HNewRecord $session $path @{value='original'}
        $first.ContainsKey('record') | Should -BeFalse # Raw evidence, not a deployment journal.
        Should -Invoke Set-HNewResourceAcl -Times 1 -Exactly -ParameterFilter {$Role -ceq 'Authority'}
        $global:HExpectedPublishedPath=$path
        Should -Invoke Assert-HAuthorityProtection -Times 1 -Exactly -ParameterFilter {$Path -ceq $global:HExpectedPublishedPath}
        {Write-HNewRecord $session $path @{value='replacement'}} | Should -Throw
        [IO.File]::ReadAllText($path) | Should -Match original
    }
    It 'refuses existing directories rather than resetting ACLs or removing contents' {
        {New-HDirectory $session $fixture.target.dataProtectionRoot Keys} | Should -Throw
        Should -Invoke Set-HNewResourceAcl -Times 0 -Exactly
        [IO.File]::ReadAllText((Join-Path $fixture.target.dataProtectionRoot 'key.xml')) | Should -BeExactly CLC_SYNTHETIC_KEY_MUST_REMAIN_UNCHANGED
    }
    It 'releases the read-only pool handle when a leaf ACL check rejects inspection' {
        $global:HRejectedReadLockPath=Join-Path $fixture.authorityRoot 'host-enrollment.lock'
        Mock Assert-HResourceAccess {Stop-ClcError Clc.HostPreflightFailed} -ParameterFilter {$Path -ceq $global:HRejectedReadLockPath}
        {Open-HReadLock $session @{record=$fixture.target} @{lockPath=$global:HRejectedReadLockPath}} | Should -Throw
        $again=[IO.FileStream]::new($global:HRejectedReadLockPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try {$again.SafeFileHandle.IsInvalid | Should -BeFalse} finally {$again.Dispose()}
    }
}

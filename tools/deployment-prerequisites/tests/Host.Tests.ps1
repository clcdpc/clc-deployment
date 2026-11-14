BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '../Validation.psm1') -Force
    $root=Join-Path $PSScriptRoot '../../..'
    Import-Module (Join-Path $root 'src/CLC.Deployment/CLC.Deployment.psd1') -Force
    $m=Get-Module CLC.Deployment
    . $m { param($Path) . $Path } (Join-Path $root 'tools/deployment-prerequisites/Host.ps1')
}

Describe 'Host diagnostic channel binding' {
    It 'rejects the unsupported Test channel before toolkit import or host observations' {
        { & "$PSScriptRoot/../Test-DeploymentHost.ps1" -ApplicationId app -TargetId app-dev -EnvironmentName app-test -DeploymentChannel Test -Repository example/app -ReleaseWorkflow .github/workflows/build.yml -BuildJob build -ToolkitManifestPath C:\unused\CLC.Deployment.psd1 } | Should -Throw -ErrorId 'ParameterArgumentValidationError*'
    }
}

Describe 'Read-only commissioning host inspection with isolated native boundaries' {
    InModuleScope CLC.Deployment {
        BeforeEach {
            $config=@{TargetId='app-dev';ApplicationId='app';EnvironmentName='app-dev';DeploymentChannel='DEV';Repository='example/app';ReleaseWorkflow='.github/workflows/release.yml';BuildJob='package';StandingAuthorizationId=''}
            $fixtureTarget=@{targetId='app-dev';applicationId='app';environmentName='app-dev';applicationRoot='C:\synthetic\app';operationalConfigPath='C:\synthetic\config\app.json';dataProtectionRoot='C:\synthetic\keys';artifactInboxRoot='C:\synthetic\inbox';runtimeIdentitySid='S-1-5-21-1-2-3-2001';applicationPoolName='APP'}
            $fixtureRoot=New-Item -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))) -ItemType Directory
            $null=New-Item -Path (Join-Path $fixtureRoot.FullName 'releases') -ItemType Directory
            Set-Content -LiteralPath (Join-Path $fixtureRoot.FullName 'baseline.json') 'synthetic approval'
            Set-Content -LiteralPath (Join-Path $fixtureRoot.FullName 'releases/baseline.json') 'synthetic manifest'
            $fixtureContext=@{executingToolkit=@{version='0.1.0';sourceCommit=('a'*40);distributionSha256=('b'*64);inventorySha256=('c'*64)};policyFile=@{record=@{deploymentSids=@('synthetic-deployment');machineIdentity='11111111-1111-1111-1111-111111111111'}};layout=@{targetCatalogRoot=$fixtureRoot.FullName;approvalCatalogRoot=$fixtureRoot.FullName}}
            $fixtureStanding=@{record=@{channel='DEV';sourceRepository='example/app';buildWorkflowPath='.github/workflows/release.yml';buildJob='package';lineageId='lineage'}}
            $fixtureCurrent=@{approvalSnapshot=@{approvalId='baseline';lineageId='lineage'};release=@{}}
            $fixtureJournal=@{record=@{backup=$null}}
            $fixtureStream=[IO.MemoryStream]::new()
            $fixtureIdentity=@{controlRoot=$fixtureRoot.FullName;snapshot=@{site='app'};iis=@{}}
            $fixtureLock=@{context=$fixtureContext;targetFile=@{record=$fixtureTarget};identity=$fixtureIdentity;stream=$fixtureStream;closed=$false;state=@{current=@{record=$fixtureCurrent};journal=$fixtureJournal}}
            $fixtureIis=@{ancmPath='C:\synthetic\ancm.dll';poolState='Started';workers=@(42)}
            $fixtureRuntime=@{ancmX64=$true;dotnetX64=$true;ancmMajor=20;frameworks=@(@{name='Microsoft.NETCore.App';version='10.0.14'},@{name='Microsoft.AspNetCore.App';version='10.0.14'})}
            Mock Open-ClcTrustedContext { $fixtureContext }
            Set-Content -LiteralPath (Join-Path $fixtureRoot.FullName 'app-dev.json') 'synthetic target'
            Mock Get-ClcCallerSid {'synthetic-deployment'}
            Mock Test-ClcAdministratorToken {$true}
            Mock Assert-ClcDeploymentToken {}
            Mock Get-ClcMachineUuidObservation { '11111111-1111-1111-1111-111111111111' }
            Mock Get-ClcMachineIdentity { '11111111-1111-1111-1111-111111111111' }
            Mock Read-ClcProtectedTarget { @{record=$fixtureTarget} }
            Mock Get-ClcIisObservation { $fixtureIis }
            Mock Get-ClcDeploymentPrerequisiteIisPresence { @{siteCount=1;poolCount=1;ancmCount=1} }
            Mock Get-ClcIisPoolNames { @('APP') }
            Mock Assert-ClcStableIisObservation {}
            Mock Get-ClcTargetIdentity { $fixtureIdentity }
            Mock Assert-ClcHostAccess {}
            Mock Assert-ClcSafeDescendants {}
            Mock Assert-ClcRuntimeIdentity {}
            Mock Get-ClcPlatformObservation { @{build='20348';productType=3;is64Bit=$true;powershellMajor=7} }
            Mock Get-ClcRuntimeObservation { $fixtureRuntime }
            Mock Get-ClcHostPreflight { @{poolState='Started';workerCount=1} }
            Mock Read-ClcDeploymentPrerequisiteStanding { $fixtureStanding }
            Mock Open-ClcDeploymentPrerequisiteExistingLock { $fixtureLock }
            Mock Get-ClcReconciliationDecision { @{classification='Clean'} }
            Mock Read-ClcApprovedManifest { @{approvalFile=@{record=@{schemaVersion=1}};manifest=@{files=@()}} }
            Mock Assert-ClcReleaseBinding {}
            Mock Read-ClcActiveStandingForApproval {}
            Mock Get-ClcTreeInventory {}
            Mock Assert-ClcBackup {}
            Mock Assert-ClcTrustedContextUnchanged {}
            Mock Assert-ClcHeldRecordUnchanged {}
            Mock Get-ClcIisConfigurationHash { 'same' }
            Mock Close-ClcTrustedContext {}
        }
        It 'passes authenticated synthetic infrastructure without requiring a standing policy' {
            $r=Invoke-ClcDeploymentPrerequisiteHostInspection $config
            @($r | Where-Object {$_.required -and $_.status -cnotin @('PASS','NOT_APPLICABLE')}).Count | Should -Be 0 -Because ($r | ConvertTo-Json -Depth 6)
            ($r | Where-Object id -EQ host.standing.policy).status | Should -Be NOT_APPLICABLE
            $fixtureStream.CanRead | Should -BeFalse
            Should -Invoke Get-ClcHostPreflight -Times 1 -Exactly
            Should -Invoke Close-ClcTrustedContext -Times 1 -Exactly
        }
        It 'accepts a genuinely empty enrolled target under the engine empty-inventory rules' {
            $fixtureLock.state.current=$null;$fixtureLock.state.journal=$null
            $r=Invoke-ClcDeploymentPrerequisiteHostInspection $config
            ($r | Where-Object id -EQ host.state.consistency).status | Should -Be PASS
            foreach ($id in @('host.state.current-release','host.state.inventory')) {
                ($r | Where-Object id -EQ $id).status | Should -Be NOT_APPLICABLE
                ($r | Where-Object id -EQ $id).reason | Should -Be empty-target
            }
            Should -Invoke Read-ClcApprovedManifest -Times 0 -Exactly
            Should -Invoke Get-ClcTreeInventory -Times 1 -Exactly -ParameterFilter {$ExpectedFiles.Count -eq 0}
        }
        It 'rejects contradictory files on an apparently empty target without inventing a baseline' {
            $fixtureLock.state.current=$null;$fixtureLock.state.journal=$null
            Mock Get-ClcTreeInventory {throw 'Private unexpected files'}
            $r=Invoke-ClcDeploymentPrerequisiteHostInspection $config
            ($r | Where-Object id -EQ host.state.consistency).status | Should -Be UNVERIFIED
            ($r | Where-Object id -EQ host.state.current-release).status | Should -Be SKIPPED
            Should -Invoke Read-ClcApprovedManifest -Times 0 -Exactly
        }
        It 'fails a machine mismatch and skips downstream IIS checks' {
            Mock Get-ClcMachineUuidObservation {'22222222-2222-2222-2222-222222222222'}
            $r=Invoke-ClcDeploymentPrerequisiteHostInspection $config
            ($r | Where-Object id -EQ host.machine.binding).status | Should -Be FAIL
            ($r | Where-Object id -EQ host.iis.configuration).status | Should -Be SKIPPED
            Should -Invoke Get-ClcIisObservation -Times 0 -Exactly
            Should -Invoke Read-ClcProtectedTarget -Times 0 -Exactly
        }
        It 'fails an unadmitted or unelevated identity and never reads IIS' {
            Mock Test-ClcAdministratorToken {$false}
            $r=Invoke-ClcDeploymentPrerequisiteHostInspection $config
            ($r | Where-Object id -EQ host.identity.permissions).status | Should -Be FAIL
            ($r | Where-Object id -EQ host.machine.binding).status | Should -Be SKIPPED
            Should -Invoke Get-ClcIisObservation -Times 0 -Exactly
        }
        It 'records unavailable actual machine evidence as UNVERIFIED and dependent work SKIPPED' {
            Mock Get-ClcMachineUuidObservation {throw 'PRIVATE observation detail'}
            $r=Invoke-ClcDeploymentPrerequisiteHostInspection $config
            ($r | Where-Object id -EQ host.machine.binding).status | Should -Be UNVERIFIED
            ($r | ConvertTo-Json) | Should -Not -Match PRIVATE
            Should -Invoke Get-ClcIisObservation -Times 0 -Exactly
        }
        It 'fails a confirmed missing target before IIS inspection' {
            Remove-Item -LiteralPath (Join-Path $fixtureRoot.FullName 'app-dev.json')
            $r=Invoke-ClcDeploymentPrerequisiteHostInspection $config
            ($r | Where-Object id -EQ host.target.enrollment).status | Should -Be FAIL
            Should -Invoke Get-ClcIisObservation -Times 0 -Exactly
        }
        It 'reports missing IIS resources and skips dependent configuration observations' {
            Mock Get-ClcDeploymentPrerequisiteIisPresence {@{siteCount=0;poolCount=1;ancmCount=1}}
            $r=Invoke-ClcDeploymentPrerequisiteHostInspection $config
            ($r | Where-Object id -EQ host.iis.presence).status | Should -Be FAIL
            ($r | Where-Object id -EQ host.iis.configuration).status | Should -Be SKIPPED
            Should -Invoke Get-ClcIisObservation -Times 0 -Exactly
        }
        It 'reports a confirmed incompatible platform as FAIL' {
            Mock Get-ClcPlatformObservation {@{build='wrong';productType=3;is64Bit=$true;powershellMajor=7}}
            $r=Invoke-ClcDeploymentPrerequisiteHostInspection $config
            ($r | Where-Object id -EQ host.runtime.compatibility).status | Should -Be FAIL
            ($r | Where-Object id -EQ host.iis.environment).status | Should -Be SKIPPED
        }
        It 'retains effective ACL uncertainty without claiming a violation' {
            Mock Assert-ClcHostAccess {throw 'PRIVATE ACL access denied'}
            $r=Invoke-ClcDeploymentPrerequisiteHostInspection $config
            ($r | Where-Object id -EQ host.filesystem.permissions).status | Should -Be UNVERIFIED
            ($r | Where-Object id -EQ host.state.lock).status | Should -Be SKIPPED
            Should -Invoke Open-ClcDeploymentPrerequisiteExistingLock -Times 0 -Exactly
        }
        It 'fails an observed pending admission without clearing it' {
            $pending=Join-Path $fixtureRoot.FullName 'standing/app-dev.pending'
            $null=New-Item -ItemType Directory -Path (Split-Path $pending)
            [IO.File]::WriteAllText($pending,'retain')
            $r=Invoke-ClcDeploymentPrerequisiteHostInspection $config
            ($r | Where-Object id -EQ host.state.pending-admission).status | Should -Be FAIL
            [IO.File]::ReadAllText($pending) | Should -Be retain
        }
        It 'fails unresolved recovery and skips inventory inspection' {
            Mock Get-ClcReconciliationDecision {@{classification='RecoveryRequired'}}
            $r=Invoke-ClcDeploymentPrerequisiteHostInspection $config
            ($r | Where-Object id -EQ host.state.consistency).status | Should -Be FAIL
            ($r | Where-Object id -EQ host.state.inventory).status | Should -Be SKIPPED
            Should -Invoke Read-ClcApprovedManifest -Times 0 -Exactly
        }
        It 'uses the existing restored-empty eligibility reader when applicable' {
            $fixtureLock.state.current=$null;$fixtureJournal.record.candidate=@{approvalId='baseline'}
            Mock Get-ClcReconciliationDecision {@{classification='EmptyRecoveryNeedsVerification'}}
            Mock Get-ClcEmptyBaselineEligibility {@{eligible=$true}}
            $r=Invoke-ClcDeploymentPrerequisiteHostInspection $config
            ($r | Where-Object id -EQ host.state.consistency).status | Should -Be PASS
            Should -Invoke Get-ClcEmptyBaselineEligibility -Times 1 -Exactly
        }
        It 'skips state readers after an unavailable canonical lock' {
            Mock Open-ClcDeploymentPrerequisiteExistingLock {throw 'PRIVATE busy lock'}
            $r=Invoke-ClcDeploymentPrerequisiteHostInspection $config
            ($r | Where-Object id -EQ host.state.lock).status | Should -Be UNVERIFIED
            ($r | Where-Object id -EQ host.state.consistency).status | Should -Be SKIPPED
            Should -Invoke Get-ClcReconciliationDecision -Times 0 -Exactly
        }
        It 'checks standing revocation for generated current schema <Schema>' -ForEach @(@{Schema=2},@{Schema=3}) {
            Mock Read-ClcApprovedManifest {@{approvalFile=@{record=@{schemaVersion=$Schema}};manifest=@{files=@()}}}
            $r=Invoke-ClcDeploymentPrerequisiteHostInspection $config
            ($r | Where-Object id -EQ host.state.current-release).status | Should -Be PASS
            Should -Invoke Read-ClcActiveStandingForApproval -Times 1 -Exactly
        }
        It 'blocks revoked generated current approvals even without selecting an optional standing policy' {
            Mock Read-ClcApprovedManifest {@{approvalFile=@{record=@{schemaVersion=3}};manifest=@{files=@()}}}
            Mock Read-ClcActiveStandingForApproval {throw 'PRIVATE revoked policy'}
            $r=Invoke-ClcDeploymentPrerequisiteHostInspection $config
            ($r | Where-Object id -EQ host.state.current-release).status | Should -Be UNVERIFIED
            ($r | Where-Object id -EQ host.state.inventory).status | Should -Be SKIPPED
        }
        It 'does not demand standing for a manually approved current release' {
            $null=Invoke-ClcDeploymentPrerequisiteHostInspection $config
            Should -Invoke Read-ClcActiveStandingForApproval -Times 0 -Exactly
            Should -Invoke Read-ClcDeploymentPrerequisiteStanding -Times 0 -Exactly
        }
        It 'reports optional standing mismatches without blocking independently approved commissioning' {
            $config.StandingAuthorizationId='routine-dev';$fixtureStanding.record.channel='Production'
            $r=Invoke-ClcDeploymentPrerequisiteHostInspection $config
            ($r | Where-Object id -EQ host.standing.scope).status | Should -Be FAIL
            ($r | Where-Object id -EQ host.standing.scope).required | Should -BeFalse
        }
        It 'retains earlier confirmed failures when final independent observation is unavailable' {
            Mock Get-ClcPlatformObservation {@{build='wrong';productType=3;is64Bit=$true;powershellMajor=7}}
            Mock Assert-ClcTrustedContextUnchanged {throw 'PRIVATE late observation'}
            $r=Invoke-ClcDeploymentPrerequisiteHostInspection $config
            ($r | Where-Object id -EQ host.runtime.compatibility).status | Should -Be FAIL
            ($r | Where-Object id -EQ host.state.stability).status | Should -Be UNVERIFIED
        }
        It 'never invokes application or infrastructure mutation commands' {
            foreach ($name in @('Invoke-ClcIisDeployment','Restore-ClcIisDeployment','Invoke-ClcApplicationValidation')) {
                Mock $name {throw 'MUST NOT EXECUTE'}
            }
            $null=Invoke-ClcDeploymentPrerequisiteHostInspection $config
            foreach ($name in @('Invoke-ClcIisDeployment','Restore-ClcIisDeployment','Invoke-ClcApplicationValidation')) {Should -Invoke $name -Times 0 -Exactly}
        }
    }
}

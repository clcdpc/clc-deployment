BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '../Validation.psm1') -Force
    $root=Join-Path $PSScriptRoot '../../..'
    Import-Module (Join-Path $root 'src/CLC.Deployment/CLC.Deployment.psd1') -Force
    $m=Get-Module CLC.Deployment
    . $m { param($Path) . $Path } (Join-Path $root 'tools/deployment-prerequisites/Host.ps1')
}

Describe 'Category reporting and stage aggregation' {
    InModuleScope Validation {
        BeforeAll { . (Join-Path $PSScriptRoot 'Fixtures.ps1') }
        BeforeEach {
            $config=New-ValidationConfig
            $config.ApplicationId='app'; $config.TargetId='app-dev'
            $g=[Collections.Generic.List[object]]::new(); $h=[Collections.Generic.List[object]]::new()
            Add-DpResult $g 'Repository configuration' 'Branch' PASS 'Verified'
            Add-DpResult $g 'Host and toolkit' 'Standing authorization' UNVERIFIED 'Hosted placeholder' 'Run host stage'
            Add-DpResult $h 'Host qualification' 'Standing authorization' PASS 'Verified'
        }
        It 'requires both categories and replaces only hosted host placeholders' {
            $r=Merge-DpReports (Complete-DpReport $config $g) (Complete-DpReport $config $h) -HostJobResult success
            $r.github_status | Should -BeExactly PASS
            $r.host_status | Should -BeExactly PASS
            $r.ready | Should -BeTrue
            $r.overall_ready | Should -BeTrue
            $r.passed_count | Should -Be 2
            $r.unverified_count | Should -Be 0
            $r.results.Count | Should -Be 2
            $r.application | Should -Be app
        }
        It 'applies FAIL precedence across every category combination: <GithubState> / <HostState>' -ForEach @(
            @{GithubState='PASS';HostState='FAIL';ExpectedG='PASS';ExpectedH='FAIL'},
            @{GithubState='FAIL';HostState='PASS';ExpectedG='FAIL';ExpectedH='PASS'},
            @{GithubState='PASS';HostState='UNVERIFIED';ExpectedG='PASS';ExpectedH='UNVERIFIED'},
            @{GithubState='FAIL';HostState='FAIL';ExpectedG='FAIL';ExpectedH='FAIL'},
            @{GithubState='UNVERIFIED';HostState='FAIL';ExpectedG='UNVERIFIED';ExpectedH='FAIL'}
        ) {
            Add-DpResult $g 'Repository configuration' 'Other GitHub requirement' $GithubState 'Observed' 'Correct configuration'
            Add-DpResult $h 'Host qualification' 'Other host requirement' $HostState 'Observed' 'Qualify separately'
            $r=Merge-DpReports (Complete-DpReport $config $g) (Complete-DpReport $config $h) -HostJobResult success -Strict
            $r.github_status | Should -BeExactly $ExpectedG
            $r.host_status | Should -BeExactly $ExpectedH
            $r.ready | Should -BeFalse
            $r.exit_code | Should -Be 1
            $r.results.Count | Should -Be 4
            ($r.passed_count+$r.failed_count+$r.unverified_count) | Should -Be 4
            (Format-DpSummary $r) | Should -Match 'Other GitHub requirement'
            (Format-DpSummary $r) | Should -Match 'Other host requirement'
        }
        It 'retains confirmed failures when a stage is <_>' -ForEach @('failure','cancelled','skipped') {
            Add-DpResult $h 'Host qualification' 'Revoked standing' FAIL 'Disabled' 'Independent authorization required'
            $r=Merge-DpReports (Complete-DpReport $config $g) (Complete-DpReport $config $h) -HostJobResult $_
            $r.host_status | Should -BeExactly FAIL
            $r.failed_count | Should -Be 1
            $r.unverified_count | Should -Be 1
            $r.ready | Should -BeFalse
        }
        It 'never promotes a passing host report from an unsuccessful or skipped job' -ForEach @('failure','cancelled','skipped') {
            $r=Merge-DpReports (Complete-DpReport $config $g) (Complete-DpReport $config $h) -HostJobResult $_
            $r.host_status | Should -BeExactly UNVERIFIED
            $r.ready | Should -BeFalse
        }
        It 'handles unavailable, malformed and unsupported reports under strict mode' -ForEach @(@{Evidence=$null},@{Evidence=@{}},@{Evidence=@{contract_version=1}},@{Evidence=@{contract_version=2;results=@()}}) {
            $r=Merge-DpReports -GitHubReport $Evidence -HostReport $Evidence -GitHubJobResult failure -HostJobResult failure
            $r.github_status | Should -BeExactly UNVERIFIED
            $r.host_status | Should -BeExactly UNVERIFIED
            $r.unverified_count | Should -Be 2
            $r.ready | Should -BeFalse
        }
        It 'rejects a cross-target report even when every row passes' -ForEach @('Repository','ApplicationId','TargetId','EnvironmentName','DeploymentChannel') {
            $github=Complete-DpReport $config $g
            $field=$_
            $config[$field]=switch ($field) {Repository {'different/app'}; DeploymentChannel {'Production'}; default {'different'}}
            $r=Merge-DpReports $github (Complete-DpReport $config $h) -HostJobResult success
            $r.host_status | Should -BeExactly FAIL
            ($r.results | Where-Object name -EQ 'Report target binding').status | Should -Be FAIL
        }
        It 'publishes all outputs before returning a strict failure and preserves detailed actions' {
            $oldOutput=$env:GITHUB_OUTPUT; $oldSummary=$env:GITHUB_STEP_SUMMARY
            try {
                $env:GITHUB_OUTPUT=Join-Path $TestDrive 'outputs'; $env:GITHUB_STEP_SUMMARY=Join-Path $TestDrive 'summary'
                $r=Merge-DpReports (Complete-DpReport $config $g) $null -Strict
                Publish-DpReport $r
                $r.exit_code | Should -Be 1
                $text=Get-Content -LiteralPath $env:GITHUB_OUTPUT -Raw
                foreach ($line in @('github_status=PASS','host_status=UNVERIFIED','overall_ready=false','ready=false','passed_count=1','failed_count=0','unverified_count=2')) { $text | Should -Match ([regex]::Escape($line)) }
                (Get-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Raw) | Should -Match 'Validation stage evidence.*UNVERIFIED|UNVERIFIED.*Validation stage evidence'
            } finally { $env:GITHUB_OUTPUT=$oldOutput; $env:GITHUB_STEP_SUMMARY=$oldSummary }
        }
    }
}

Describe 'Optional administrative authentication and exact workflow admission' {
    InModuleScope Validation {
        BeforeAll { . (Join-Path $PSScriptRoot 'Fixtures.ps1') }
        BeforeEach {
            $script:standard=$env:GH_TOKEN; $script:admin=$env:CLC_GITHUB_INSPECTION_TOKEN
            $env:GH_TOKEN='synthetic-standard'; $env:CLC_GITHUB_INSPECTION_TOKEN='synthetic-read-only-app'
            $client=[Net.Http.HttpClient]::new()
            $config=New-ValidationConfig; $fixture=New-ValidationFixture
            Mock Get-DpApi {
                param($Path)
                $key=$Path -replace '[?&]per_page=(30|100)&page=\d+$',''
                $fixture[$key]
            }
        }
        AfterEach { $client.Dispose(); $env:GH_TOKEN=$script:standard; $env:CLC_GITHUB_INSPECTION_TOKEN=$script:admin }
        It 'selects only GITHUB_TOKEN in standard mode even if an administrative token exists' {
            Set-DpAuthentication $client Standard
            $client.DefaultRequestHeaders.Authorization.Parameter | Should -BeExactly 'synthetic-standard'
        }
        It 'requires explicit administrative mode and never falls back to the standard token' {
            Set-DpAuthentication $client Administrative
            $client.DefaultRequestHeaders.Authorization.Parameter | Should -BeExactly 'synthetic-read-only-app'
            $env:CLC_GITHUB_INSPECTION_TOKEN=''
            { Set-DpAuthentication $client Administrative } | Should -Throw
        }
        It 'supports standard mode without an extra credential' {
            $env:CLC_GITHUB_INSPECTION_TOKEN=''
            $report=Invoke-DpValidation $config $env:CLC_PREREQUISITES_YAML
            $report.results.Count | Should -BeGreaterThan 25
        }
        It 'retains UNVERIFIED on administrative permission denial' {
            $fixture['/orgs/example/actions/runner-groups']=New-ApiFailure 403
            $report=Invoke-DpValidation $config $env:CLC_PREREQUISITES_YAML -AuthenticationMode Administrative
            ($report.results | Where-Object name -EQ 'Restricted runner group').status | Should -Be UNVERIFIED
            ($report | ConvertTo-Json -Depth 12) | Should -Not -Match 'synthetic-read-only-app|synthetic-standard'
        }
        It 'observes administrator enforcement without inferring the effective bypass model' -ForEach @($true,$false) {
            $fixture['/repos/example/app/branches/master/protection'].data.enforce_admins=@{enabled=$_}
            $report=Invoke-DpValidation $config $env:CLC_PREREQUISITES_YAML
            $expected=if ($_){'PASS'}else{'UNVERIFIED'}
            ($report.results | Where-Object name -EQ 'Classic administrator enforcement').status | Should -Be $expected
        }
        It 'observes complete empty tag bypass lists but preserves semantic review' {
            $fixture['/repos/example/app/rulesets/12?includes_parents=true'].data.bypass_actors=@()
            $report=Invoke-DpValidation $config $env:CLC_PREREQUISITES_YAML
            ($report.results | Where-Object name -EQ 'Observed tag ruleset bypass actors').status | Should -Be PASS
            ($report.results | Where-Object name -EQ 'Tag bypass authority').status | Should -Be UNVERIFIED
        }
        It 'allows only the two explicitly reviewed directly defining workflows' {
            $config.DiagnosticWorkflow='.github/workflows/diagnose-deployment.yml'
            $fixture['/orgs/example/actions/runner-groups/7'].data.selected_workflows+= 'example/app/.github/workflows/diagnose-deployment.yml@refs/heads/master'
            $report=Invoke-DpValidation $config $env:CLC_PREREQUISITES_YAML
            ($report.results | Where-Object name -EQ 'Runner selected-workflow access').status | Should -Be PASS
            $fixture['/orgs/example/actions/runner-groups/7'].data.selected_workflows+= 'example/app/.github/workflows/untrusted.yml@refs/heads/master'
            $report=Invoke-DpValidation $config $env:CLC_PREREQUISITES_YAML
            ($report.results | Where-Object name -EQ 'Runner selected-workflow access').status | Should -Be FAIL
        }
    }
}

Describe 'Read-only actual host qualification with isolated native boundaries' {
    InModuleScope CLC.Deployment {
        BeforeEach {
            $config=@{TargetId='app-dev';ApplicationId='app';EnvironmentName='app-dev';DeploymentChannel='DEV';Repository='example/app';ReleaseWorkflow='.github/workflows/release.yml';BuildJob='package';StandingAuthorizationId='routine-dev'}
            $fixtureTarget=@{targetId='app-dev';applicationId='app';environmentName='app-dev';applicationRoot='C:\synthetic\app';operationalConfigPath='C:\synthetic\config\app.json';dataProtectionRoot='C:\synthetic\keys';artifactInboxRoot='C:\synthetic\inbox';runtimeIdentitySid='S-1-5-21-1-2-3-2001';applicationPoolName='APP'}
            $fixtureRoot=New-Item -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))) -ItemType Directory
            $null=New-Item -Path (Join-Path $fixtureRoot.FullName 'releases') -ItemType Directory
            Set-Content -LiteralPath (Join-Path $fixtureRoot.FullName 'baseline.json') 'synthetic approval'
            Set-Content -LiteralPath (Join-Path $fixtureRoot.FullName 'releases/baseline.json') 'synthetic manifest'
            $fixtureContext=@{executingToolkit=@{version='0.1.0';sourceCommit=('a'*40);distributionSha256=('b'*64);inventorySha256=('c'*64)};policyFile=@{record=@{machineIdentity='11111111-1111-1111-1111-111111111111'}};layout=@{approvalCatalogRoot=$fixtureRoot.FullName}}
            $fixtureStanding=@{record=@{channel='DEV';sourceRepository='example/app';buildWorkflowPath='.github/workflows/release.yml';buildJob='package';lineageId='lineage'}}
            $fixtureCurrent=@{approvalSnapshot=@{approvalId='baseline';lineageId='lineage'};release=@{}}
            $fixtureJournal=@{record=@{backup=$null}}
            $fixtureStream=[IO.MemoryStream]::new()
            $fixtureIdentity=@{controlRoot=$fixtureRoot.FullName;snapshot=@{site='app'};iis=@{}}
            $fixtureLock=@{context=$fixtureContext;targetFile=@{record=$fixtureTarget};identity=$fixtureIdentity;stream=$fixtureStream;closed=$false;state=@{current=@{record=$fixtureCurrent};journal=$fixtureJournal}}
            $fixtureIis=@{ancmPath='C:\synthetic\ancm.dll';poolState='Started';workers=@(42)}
            $fixtureRuntime=@{ancmX64=$true;dotnetX64=$true;ancmMajor=20;frameworks=@(@{name='Microsoft.NETCore.App';version='10.0.14'},@{name='Microsoft.AspNetCore.App';version='10.0.14'})}
            Mock Open-ClcTrustedContext { $fixtureContext }
            Mock Assert-ClcDeploymentToken {}
            Mock Get-ClcMachineUuidObservation { '11111111-1111-1111-1111-111111111111' }
            Mock Get-ClcMachineIdentity { '11111111-1111-1111-1111-111111111111' }
            Mock Read-ClcProtectedTarget { @{record=$fixtureTarget} }
            Mock Get-ClcIisObservation { $fixtureIis }
            Mock Get-DhIisPresence { @{siteCount=1;poolCount=1;ancmCount=1} }
            Mock Get-ClcIisPoolNames { @('APP') }
            Mock Assert-ClcStableIisObservation {}
            Mock Get-ClcTargetIdentity { $fixtureIdentity }
            Mock Assert-ClcHostAccess {}
            Mock Assert-ClcSafeDescendants {}
            Mock Assert-ClcRuntimeIdentity {}
            Mock Get-ClcPlatformObservation { @{build='20348';productType=3;is64Bit=$true;powershellMajor=7} }
            Mock Get-ClcRuntimeObservation { $fixtureRuntime }
            Mock Get-ClcHostPreflight { @{poolState='Started';workerCount=1} }
            Mock Read-DhStanding { $fixtureStanding }
            Mock Open-DhExistingLock { $fixtureLock }
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
        It 'passes a fully qualified synthetic host without application execution or mutation' {
            $r=Invoke-DhQualification $config
            @($r | Where-Object status -NE PASS).Count | Should -Be 0
            $r.Count | Should -Be 21
            $fixtureStream.CanRead | Should -BeFalse
            Should -Invoke Get-ClcHostPreflight -Times 1 -Exactly
            Should -Invoke Close-ClcTrustedContext -Times 1 -Exactly
        }
        It 'rejects the wrong inspected machine before any IIS or target inspection' {
            Mock Get-ClcMachineUuidObservation { '22222222-2222-2222-2222-222222222222' }
            $r=Invoke-DhQualification $config
            ($r | Where-Object name -EQ 'Inspected machine binding').status | Should -Be FAIL
            Should -Invoke Get-ClcIisObservation -Times 0 -Exactly
            Should -Invoke Read-ClcProtectedTarget -Times 0 -Exactly
        }
        It 'reports unavailable actual machine evidence without inspecting runner IIS' {
            Mock Get-ClcMachineUuidObservation { throw 'PRIVATE native observation' }
            $r=Invoke-DhQualification $config
            ($r | Where-Object name -EQ 'Inspected machine binding').status | Should -Be UNVERIFIED
            ($r | ConvertTo-Json) | Should -Not -Match PRIVATE
            Should -Invoke Get-ClcIisObservation -Times 0 -Exactly
        }
        It 'reports incompatible or invalid toolkit before host access' {
            Mock Open-ClcTrustedContext { throw 'Dp.HostRequirementFailed' }
            $r=Invoke-DhQualification $config
            ($r | Where-Object name -EQ 'Compatible toolkit installation').status | Should -Be FAIL
            @($r | Where-Object status -EQ UNVERIFIED).Count | Should -Be 20
            Should -Invoke Get-ClcMachineUuidObservation -Times 0 -Exactly
        }
        It 'leaves empty, malformed or sentinel machine UUID evidence UNVERIFIED' -ForEach @(
            @{Observed=@()}, @{Observed=@('invalid')}, @{Observed=@('00000000-0000-0000-0000-000000000000')},
            @{Observed=@('ffffffff-ffff-ffff-ffff-ffffffffffff')}, @{Observed=@('11111111-1111-1111-1111-111111111111','22222222-2222-2222-2222-222222222222')}
        ) {
            $script:uuidEvidence=$Observed
            Mock Get-ClcMachineUuidObservation { $script:uuidEvidence }
            $r=Invoke-DhQualification $config
            ($r | Where-Object name -EQ 'Inspected machine binding').status | Should -Be UNVERIFIED
            Should -Invoke Get-ClcIisObservation -Times 0 -Exactly
            Should -Invoke Read-ClcProtectedTarget -Times 0 -Exactly
        }
        It 'rejects mismatched enrolled application or environment' -ForEach @('applicationId','environmentName') {
            $fixtureTarget[$_]='other'
            $r=Invoke-DhQualification $config
            ($r | Where-Object name -EQ 'IIS target enrollment').status | Should -Be FAIL
            Should -Invoke Get-ClcIisObservation -Times 0 -Exactly
        }
        It 'rejects observed missing or incorrect <Name>' -ForEach @(
            @{Name='IIS site and pool configuration';Command='Get-ClcIisObservation'},
            @{Name='Runtime identity and host permissions';Command='Assert-ClcRuntimeIdentity'},
            @{Name='Application configuration and Data Protection';Command='Assert-ClcHostAccess'},
            @{Name='Standing authorization';Command='Read-DhStanding'},
            @{Name='Current installed release bytes';Command='Get-ClcTreeInventory'}
        ) {
            Mock $Command { throw 'Dp.HostRequirementFailed' }
            $r=Invoke-DhQualification $config
            ($r | Where-Object name -EQ $Name).status | Should -Be FAIL
            @($r | Where-Object { $_.status -ne 'PASS' -and (-not $_.detail -or -not $_.action) }).Count | Should -Be 0
        }
        It 'fails directly observed missing site or pool presence' -ForEach @('siteCount','poolCount') {
            $script:presence=@{siteCount=1;poolCount=1;ancmCount=1}; $script:presence[$_]=0
            Mock Get-DhIisPresence { $script:presence }
            $r=Invoke-DhQualification $config
            ($r | Where-Object name -EQ 'IIS site and pool presence').status | Should -Be FAIL
        }
        It 'leaves unsupported effective access safely UNVERIFIED' {
            Mock Assert-ClcHostAccess { throw 'Unavailable Authz group expansion' }
            $r=Invoke-DhQualification $config
            ($r | Where-Object name -EQ 'Application configuration and Data Protection').status | Should -Be UNVERIFIED
            ($r | Where-Object name -EQ 'Runtime identity and host permissions').status | Should -Be UNVERIFIED
        }
        It 'rejects missing hosting components or runtime versions' -ForEach @('ancmX64','dotnetX64','frameworks','ancmMajor') {
            $component=$_
            $fixtureRuntime[$component]=switch ($component) { frameworks {@()}; ancmMajor {19}; default {$false} }
            $r=Invoke-DhQualification $config
            ($r | Where-Object name -EQ 'Hosting components and runtime').status | Should -Be FAIL
        }
        It 'fails a directly observed missing ANCM module even if broader IIS inspection is unavailable' {
            Mock Get-DhIisPresence { @{siteCount=1;poolCount=1;ancmCount=0} }
            Mock Get-ClcIisObservation { throw 'Unavailable ANCM configuration' }
            $r=Invoke-DhQualification $config
            ($r | Where-Object name -EQ 'Hosting components and runtime').status | Should -Be FAIL
        }
        It 'rejects mismatched standing scope: <_>' -ForEach @('channel','sourceRepository','buildWorkflowPath','buildJob') {
            $fixtureStanding.record[$_]='other'
            $r=Invoke-DhQualification $config
            ($r | Where-Object name -EQ 'Standing repository workflow and channel scope').status | Should -Be FAIL
        }
        It 'rejects a missing baseline' {
            $fixtureLock.state.current=$null
            $r=Invoke-DhQualification $config
            ($r | Where-Object name -EQ 'Initial successful deployment baseline').status | Should -Be FAIL
        }
        It 'rejects pending admission without deleting or clearing it' {
            $directory=New-Item -Path (Join-Path $fixtureContext.layout.approvalCatalogRoot 'standing') -ItemType Directory -Force
            $pending=Join-Path $directory.FullName 'app-dev.pending'
            Set-Content -LiteralPath $pending 'synthetic intent'
            $r=Invoke-DhQualification $config
            ($r | Where-Object name -EQ 'Pending admission').status | Should -Be FAIL
            (Get-Content -LiteralPath $pending -Raw).Trim() | Should -Be 'synthetic intent'
        }
        It 'rejects unresolved deployment or recovery state' -ForEach @('RecoveryRequired','EmptyRecoveryNeedsVerification') {
            $script:decision=$_
            Mock Get-ClcReconciliationDecision { @{classification=$script:decision} }
            $r=Invoke-DhQualification $config
            ($r | Where-Object name -EQ 'Host readiness and recovery qualification').status | Should -Be FAIL
            ($r | Where-Object name -EQ 'Initial successful deployment baseline').status | Should -Be UNVERIFIED
        }
        It 'rejects incompatible lineage' {
            $fixtureStanding.record.lineageId='other'
            $r=Invoke-DhQualification $config
            ($r | Where-Object name -EQ 'Standing lineage compatibility').status | Should -Be FAIL
        }
        It 'rechecks revocation on a current generated approval' {
            Mock Read-ClcApprovedManifest { @{approvalFile=@{record=@{schemaVersion=2}};manifest=@{files=@()}} }
            Mock Read-ClcActiveStandingForApproval { throw 'Dp.HostRequirementFailed' }
            $r=Invoke-DhQualification $config
            ($r | Where-Object name -EQ 'Current release and retained approval').status | Should -Be FAIL
        }
        It 'fails missing current approval and manifest records before reading their contents' {
            $fixtureCurrent.approvalSnapshot.approvalId='missing'
            $r=Invoke-DhQualification $config
            ($r | Where-Object name -EQ 'Current release and retained approval').status | Should -Be FAIL
            Should -Invoke Read-ClcApprovedManifest -Times 0 -Exactly
        }
        It 'checks retained backup material only when selected by the latest journal' {
            $fixtureJournal.record.backup=@{verified=$true}
            $r=Invoke-DhQualification $config
            ($r | Where-Object name -EQ 'Retained recovery material').status | Should -Be PASS
            Should -Invoke Assert-ClcBackup -Times 1 -Exactly
        }
        It 'leaves missing or busy existing lock UNVERIFIED without reading state' {
            Mock Open-DhExistingLock { throw 'Existing lock unavailable' }
            $r=Invoke-DhQualification $config
            ($r | Where-Object name -EQ 'Canonical deployment state access').status | Should -Be UNVERIFIED
            Should -Invoke Get-ClcReconciliationDecision -Times 0 -Exactly
        }
        It 'never calls mutation, application validation, readiness network or installation helpers' {
            foreach ($command in @('Enter-ClcDeploymentLock','Invoke-ClcDeploymentCore','Invoke-ClcRecoveryCore','Invoke-ClcIisLifecycle','Invoke-ClcApplicationValidation','Wait-ClcApplicationReady','Write-ClcStateRecord','New-ClcAutomatedApproval','New-ClcOwnedDirectory','Publish-ClcAutomatedApproval')) { Mock $command { throw 'MUTATION FORBIDDEN' } }
            $r=Invoke-DhQualification $config
            @($r | Where-Object status -NE PASS).Count | Should -Be 0
            foreach ($command in @('Enter-ClcDeploymentLock','Invoke-ClcDeploymentCore','Invoke-ClcRecoveryCore','Invoke-ClcIisLifecycle','Invoke-ClcApplicationValidation','Wait-ClcApplicationReady','Write-ClcStateRecord','New-ClcAutomatedApproval','New-ClcOwnedDirectory','Publish-ClcAutomatedApproval')) { Should -Invoke $command -Times 0 -Exactly }
        }
    }
}

Describe 'Protected standing diagnostics distinguish rejection from unavailable access' {
    InModuleScope CLC.Deployment {
        BeforeEach {
            $fixturePath=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $null=New-Item -Path (Join-Path $fixturePath 'standing') -ItemType Directory -Force
            $script:standingRecord=Read-ClcJson ([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot '../../../tests/Fixtures/standing-authorization.json'))) standing-authorization
            $standingId=$script:standingRecord.standingAuthorizationId
            Set-Content -LiteralPath (Join-Path $fixturePath ('standing/'+$standingId+'.json')) 'synthetic protected record'
            $fixtureTarget=@{targetId=$script:standingRecord.targetId;applicationId=$script:standingRecord.applicationId;environmentName=$script:standingRecord.environmentName;runtimeIdentitySid='synthetic-runtime'}
            $fixtureContext=@{handles=[Collections.Generic.List[IDisposable]]::new();layout=@{approvalCatalogRoot=$fixturePath};policyFile=@{record=@{infrastructureOwnerSids=@($script:standingRecord.authorization.authoritySid);deploymentSids=@('synthetic-deployment')}}}
            Mock Add-ClcProtectedPathPin {}
            Mock Read-ClcHeldRecord { Assert-ClcRecord $script:standingRecord standing-authorization; @{record=$script:standingRecord} }
            Mock Read-ClcStandingAuthorization { @{record=$script:standingRecord} }
            $rows=[Collections.Generic.List[object]]::new()
            $rows.Add([pscustomobject]@{name='Standing authorization';status='UNVERIFIED';detail='';action='Independently inspect standing authority'})
        }
        It 'uses the existing protected standing contract and reader' {
            $null=Invoke-DhCheck $rows 'Standing authorization' { Read-DhStanding $fixtureContext $fixtureTarget $standingId } 'Verified'
            $rows[0].status | Should -Be PASS
            Should -Invoke Read-ClcStandingAuthorization -Times 1 -Exactly
        }
        It 'fails disabled or scope-mismatched protected standing records' -ForEach @('enabled','standingAuthorizationId','targetId','applicationId','environmentName') {
            if ($_ -ceq 'enabled') { $script:standingRecord[$_]=$false } else { $script:standingRecord[$_]='different' }
            $null=Invoke-DhCheck $rows 'Standing authorization' { Read-DhStanding $fixtureContext $fixtureTarget $standingId } 'Verified'
            $rows[0].status | Should -Be FAIL
        }
        It 'fails missing standing records without creating a file' {
            $null=Invoke-DhCheck $rows 'Standing authorization' { Read-DhStanding $fixtureContext $fixtureTarget 'missing' } 'Verified'
            $rows[0].status | Should -Be FAIL
            Test-Path -LiteralPath (Join-Path $fixturePath 'standing/missing.json') | Should -BeFalse
        }
        It 'rejects malformed protected standing structure' {
            $script:standingRecord.enabled='yes'
            $null=Invoke-DhCheck $rows 'Standing authorization' { Read-DhStanding $fixtureContext $fixtureTarget $standingId } 'Verified'
            $rows[0].status | Should -Be FAIL
        }
        It 'leaves inaccessible effective ACL evidence UNVERIFIED' {
            Mock Add-ClcProtectedPathPin { Stop-ClcError Clc.HostPreflightFailed }
            $null=Invoke-DhCheck $rows 'Standing authorization' { Read-DhStanding $fixtureContext $fixtureTarget $standingId } 'Verified'
            $rows[0].status | Should -Be UNVERIFIED
            Should -Invoke Read-ClcStandingAuthorization -Times 0 -Exactly
        }
        It 'does not infer revocation from the engine generic standing rejection' {
            Mock Read-ClcStandingAuthorization { Stop-ClcError Clc.StandingAuthorizationRejected }
            $null=Invoke-DhCheck $rows 'Standing authorization' { Read-DhStanding $fixtureContext $fixtureTarget $standingId } 'Verified'
            $rows[0].status | Should -Be UNVERIFIED
        }
    }
}

Describe 'Existing canonical lock observation without mutation' {
    InModuleScope CLC.Deployment {
        BeforeEach {
            Mock Assert-ClcLockOwned {}
            Mock Assert-ClcNoNamedStreams {}
            Mock Assert-ClcPathAccess {}
        }
        It 'opens an existing lock read-only and never writes bytes' {
            $path=Join-Path $TestDrive 'existing.lock'
            [IO.File]::WriteAllText($path,'synthetic lock')
            $lock=Open-DhExistingLock @{} @{record=@{runtimeIdentitySid='synthetic'}} @{lockPath=$path}
            try {
                $lock.stream.CanRead | Should -BeTrue
                $lock.stream.CanWrite | Should -BeFalse
                { [IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) } | Should -Throw
            } finally {$lock.stream.Dispose()}
            [IO.File]::ReadAllText($path) | Should -BeExactly 'synthetic lock'
        }
        It 'never creates a missing lock' {
            $path=Join-Path $TestDrive 'missing.lock'
            { Open-DhExistingLock @{} @{record=@{runtimeIdentitySid='synthetic'}} @{lockPath=$path} } | Should -Throw
            Test-Path -LiteralPath $path | Should -BeFalse
        }
        It 'leaves a busy lock untouched' {
            $path=Join-Path $TestDrive 'busy.lock'
            [IO.File]::WriteAllText($path,'synthetic lock')
            $busy=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
            try { { Open-DhExistingLock @{} @{record=@{runtimeIdentitySid='synthetic'}} @{lockPath=$path} } | Should -Throw }
            finally {$busy.Dispose()}
            [IO.File]::ReadAllText($path) | Should -BeExactly 'synthetic lock'
        }
    }
}

Describe 'Protected workflow boundaries and host entry point' {
    BeforeAll {
        $root=Join-Path $PSScriptRoot '../../..'
        $workflow=Get-Content -LiteralPath (Join-Path $root '.github/workflows/validate-deployment.yml') -Raw
        $example=Get-Content -LiteralPath (Join-Path $root 'docs/examples/deployment-readiness.yml') -Raw
    }
    It 'keeps administrative tokens in the protected hosted dispatch job only' {
        $workflow | Should -Match 'environment: deployment-configuration-inspection'
        $workflow | Should -Match "inputs.administrative && github.event_name == 'workflow_dispatch'.*github.ref_protected"
        $workflow | Should -Match 'CLC_GITHUB_INSPECTION_TOKEN: \$\{\{ secrets.inspection_token \}\}'
        $workflow | Should -Not -Match 'secrets: inherit|runs-on: self-hosted|id-token: write'
        $standard=$workflow.Substring($workflow.IndexOf("`n  validate:"),$workflow.IndexOf("`n  administrative:")-$workflow.IndexOf("`n  validate:"))
        $standard | Should -Not -Match 'CLC_GITHUB_INSPECTION_TOKEN|secrets.inspection_token'
    }
    It 'keeps host access in a protected directly defined consumer job with an always aggregator' {
        $example | Should -Match 'github.workflow_ref.*diagnose-deployment.yml@refs/heads/master'
        $example | Should -Match 'github.event_name.*workflow_dispatch.*github.ref_protected'
        $example | Should -Match 'if: always\(\)'
        $example | Should -Match 'needs.host.result'
        $hostJob=$example.Substring($example.IndexOf('  host:'),$example.IndexOf('  report:')-$example.IndexOf('  host:'))
        $hostJob | Should -Not -Match 'inspection_token|secrets\.|Invoke-ClcIisDeployment|Restore-ClcIisDeployment|Initialize-ClcHostEnrollment|refs/pull/'
        $hostJob | Should -Match 'ref: ''0{40}'''
    }
    It 'reports a missing synthetic installed manifest without importing repository toolkit code' {
        $r=& (Join-Path $root 'tools/deployment-prerequisites/Test-DeploymentHost.ps1') -ApplicationId app -TargetId app-dev -EnvironmentName app-dev -DeploymentChannel DEV -Repository example/app -ReleaseWorkflow .github/workflows/release.yml -BuildJob package -StandingAuthorizationId routine-dev -ToolkitManifestPath (Join-Path $TestDrive 'CLC.Deployment.psd1')
        $r.host_status | Should -BeExactly FAIL
        $r.ready | Should -BeFalse
        $r.results.Count | Should -Be 1
    }
}

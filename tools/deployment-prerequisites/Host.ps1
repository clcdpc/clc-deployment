# Loaded only inside the independently authenticated installed CLC.Deployment module.
# No public deployment commands, application validators or IIS lifecycle helpers are called.
function Assert-DhRequirement {
    param([bool] $Condition)
    if (-not $Condition) { throw 'Dp.HostRequirementFailed' }
}

function Invoke-DhCheck {
    param($Rows, [string] $Name, [scriptblock] $Read, [string] $Success)
    $row=$Rows | Where-Object name -CEQ $Name
    try {
        $value=& $Read
        $row.status='PASS'; $row.detail=$Success; $row.action=''
        return $value
    } catch {
        # Access failures and unsupported effective-access observations are insufficient evidence.
        # Never log exception text: native errors can contain configuration or identity values.
        $row.status=if ($_.Exception.Message -ceq 'Dp.HostRequirementFailed' -or $_.FullyQualifiedErrorId -match '^Clc\.(InvalidContract|UnsupportedContract|ApprovalDisabled|ApprovalMismatch|ContentDrift|BackupInvalid)\b') {'FAIL'} else {'UNVERIFIED'}
        $row.detail=if ($row.status -ceq 'FAIL') {'The observed resource is missing, invalid, disabled or inconsistent with the selected protected contract.'} else {'The read-only observation could not establish this requirement; access, unavailable dependencies or concurrent state may prevent inspection.'}
        if ($row.status -ceq 'FAIL') {
            switch -CaseSensitive ($Name) {
                'Initial successful deployment baseline' { $row.detail='Initial baseline missing: clean observed state has no successful current record; standing deployment cannot initialize it.' }
                'Host readiness and recovery qualification' { $row.detail='Recovery required: the existing state/terminal/helper reader rejected routine clean-state admission.' }
                'Pending admission' { $row.detail='An unresolved target admission intent exists; ordinary standing admission is blocked.' }
                'Inspected machine binding' { $row.detail='The actual inspected local machine UUID does not match protected host enrollment.' }
            }
        }
        return $null
    }
}

function Open-DhExistingLock {
    param($Context, $TargetFile, $Identity)
    # FileMode.Open is essential: diagnostics must never create the mutation lock.
    $stream=$null
    try {
        $stream=[IO.File]::Open($Identity.lockPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
        $facts=[Clc.Foundation.NativePaths]::Observe($stream.SafeFileHandle)
        $lock=@{context=$Context;targetFile=$TargetFile;identity=$Identity;stream=$stream;lockFacts=$facts;ownerProcessId=$PID;closed=$false;state=$null}
        Assert-ClcLockOwned $lock
        Assert-ClcNoNamedStreams $Identity.lockPath
        Assert-ClcPathAccess $Context $Identity.lockPath $TargetFile.record.runtimeIdentitySid Mutable
        return $lock
    } catch { if ($null -ne $stream) {$stream.Dispose()}; throw }
}

function Get-DhIisPresence {
    param($Context, $Target)
    $manager=$null
    try {
        $manager=New-ClcMwaServerManager (Get-ClcAdmittedMwaType $Context)
        if ($manager.Sites.Count -gt 4096 -or $manager.ApplicationPools.Count -gt 4096) { throw 'Unavailable bounded IIS collection' }
        $modules=$manager.GetApplicationHostConfiguration().GetSection('system.webServer/globalModules').GetCollection()
        if ($modules.Count -gt 4096) { throw 'Unavailable bounded IIS module collection' }
        return @{
            siteCount=@($manager.Sites | Where-Object { $_.Name -ieq $Target.siteName }).Count
            poolCount=@($manager.ApplicationPools | Where-Object { $_.Name -ieq $Target.applicationPoolName }).Count
            ancmCount=@($modules | Where-Object { $_['name'] -ceq 'AspNetCoreModuleV2' }).Count
        }
    } finally { if ($null -ne $manager) {$manager.Dispose()} }
}

function Read-DhStanding {
    param($Context, $Target, [string] $Id)
    $root=Join-Path $Context.layout.approvalCatalogRoot 'standing'
    $path=Join-Path $root ($Id+'.json')
    Assert-DhRequirement (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction Stop)
    foreach ($item in @($root,$path)) { $null=Add-ClcProtectedPathPin $Context $item -Directory:($item -ceq $root) -RuntimeSid $Target.runtimeIdentitySid }
    $file=Read-ClcHeldRecord $path standing-authorization $Context.handles
    $s=$file.record; $p=$Context.policyFile.record
    # The engine intentionally collapses access/parse/revocation errors into one
    # rejection. Establish observable failures before its final read so denied
    # effective-access evidence is never misreported as a proven revocation.
    Assert-DhRequirement ($s.enabled -and $s.standingAuthorizationId -ceq $Id -and $s.targetId -ceq $Target.targetId -and
        $s.applicationId -ceq $Target.applicationId -and $s.environmentName -ceq $Target.environmentName -and
        $p.infrastructureOwnerSids -ccontains $s.authorization.authoritySid -and $p.deploymentSids -cnotcontains $s.authorization.authoritySid)
    Read-ClcStandingAuthorization $Context $Target $Id
}

function Invoke-DhQualification {
    param([hashtable] $Config)
    $rows=[Collections.Generic.List[object]]::new()
    $checks=[ordered]@{
        'Compatible toolkit installation'='Infrastructure: authenticate first import, install the reviewed contract-compatible toolkit and verify its active source/distribution/inventory pin. Do not upgrade through diagnostics.'
        'Authorized inspection identity'='Run under the exact policy-admitted deployment SID with its enabled elevated administrator token; never self-elevate.'
        'Inspected machine binding'='Run locally on the enrolled IIS machine. If the runner is elsewhere, use a separately authorized existing read-only inspection channel; no remoting is provided here.'
        'IIS target enrollment'='Infrastructure: independently enroll this exact application/environment/target; inspect the protected target and host policy without rewriting them.'
        'IIS site and pool configuration'='Infrastructure: inspect the dedicated sole root application, physical path, pool identity and one-worker settings against the enrolled target.'
        'IIS site and pool presence'='Infrastructure: independently provision the exact enrolled dedicated IIS site and pool; diagnostics never create them.'
        'Runtime identity and host permissions'='Infrastructure: establish separate nonadministrator runtime identity and effective protected-resource write isolation, including group and ancestor authority.'
        'Hosting components and runtime'='Infrastructure: independently install supported Windows Server 2022, x64 PowerShell 7, IIS/ANCM and .NET/ASP.NET Core 10 runtimes.'
        'Enrolled readiness and runtime environment'='Infrastructure: inspect the enrolled HTTPS readiness host/binding and runtime environment; application owners must separately qualify functional readiness.'
        'Application configuration and Data Protection'='Infrastructure/application owners: verify the enrolled external configuration, key directory, paths and effective ACLs without exposing contents; qualify semantics separately.'
        'Standing authorization'='Infrastructure: independently provision or review the exact enabled protected standing policy; diagnostics cannot create, enable or renew it.'
        'Standing repository workflow and channel scope'='Review the standing application/environment/channel/repository/build-workflow/build-job scope against this trusted selection; keep DEV and production separate.'
        'Canonical deployment state access'='Fence concurrent deployment, inspect the existing canonical machine/pool lock and state permissions, then rerun; never delete or create a lock to make this check pass.'
        'Pending admission'='Infrastructure: inspect retained admission intent and complete separately authorized reconciliation; never clear pending records through diagnostics.'
        'Host readiness and recovery qualification'='Operator: preserve journal/current/terminal/helper evidence and follow separately authorized recovery when required; no automatic reconciliation is performed.'
        'Initial successful deployment baseline'='Complete a separately authorized initial consumer baseline and retain its successful current/terminal/approval records before routine standing deployment.'
        'Standing lineage compatibility'='Infrastructure: verify standing lineage against the successful current baseline; authorize lineage changes independently.'
        'Current release and retained approval'='Operator: retain valid enabled exact approval and approval-pinned manifest with matching current release identity; restore missing evidence only under independent authority.'
        'Current installed release bytes'='Operator: inspect file drift against the approval-pinned retained inventory; preserve unexpected files and use separately authorized recovery.'
        'Retained recovery material'='Operator: retain and verify the latest journal-selected backup/index when present. Diagnostics never create, restore or remove recovery material.'
        'Stable final observation'='Freeze competing trusted writers and rerun the diagnostic after investigating target, policy, IIS or state drift.'
    }
    foreach ($entry in $checks.GetEnumerator()) {
        $rows.Add([pscustomobject]@{category='host';section='Host qualification';name=$entry.Key;status='UNVERIFIED';detail='A prerequisite observation was unavailable; this check was not established.';action=$entry.Value})
    }
    $context=$null; $lock=$null
    try {
        $context=Invoke-DhCheck $rows 'Compatible toolkit installation' {
            foreach ($command in @('Open-ClcTrustedContext','Read-ClcStandingAuthorization','Read-ClcApprovedManifest','Get-ClcReconciliationDecision','Get-ClcHostPreflight')) {
                Assert-DhRequirement ($null -ne (Get-Command $command -ErrorAction SilentlyContinue))
            }
            Open-ClcTrustedContext
        } 'The installed version supports the current standing/state/preflight readers; active toolkit version, source, distribution, inventory, protected policy and dependencies were validated.'
        if ($null -eq $context) { return ,$rows }
        $pin=$context.executingToolkit
        ($rows | Where-Object name -CEQ 'Compatible toolkit installation').detail += " Executing toolkit: $($pin.version); source: $($pin.sourceCommit); distribution SHA-256: $($pin.distributionSha256); inventory SHA-256: $($pin.inventorySha256)."
        $null=Invoke-DhCheck $rows 'Authorized inspection identity' { Assert-ClcDeploymentToken $context.policyFile.record } 'The exact admitted deployment SID has an enabled elevated administrator token. Approval independence remains procedural.'
        $machine=Invoke-DhCheck $rows 'Inspected machine binding' {
            $observed=@(Get-ClcMachineUuidObservation)
            $uuid=[guid]::Empty
            if ($observed.Count -ne 1 -or $observed[0] -isnot [string] -or
                -not [guid]::TryParseExact($observed[0],'D',[ref]$uuid) -or $uuid -eq [guid]::Empty -or
                $uuid.ToString('D') -ceq 'ffffffff-ffff-ffff-ffff-ffffffffffff') { throw 'Unavailable canonical local machine identity' }
            Assert-DhRequirement ($uuid.ToString('D') -ceq $context.policyFile.record.machineIdentity)
            Get-ClcMachineIdentity $context.policyFile.record.machineIdentity
        } 'The actual local SMBIOS machine UUID matches protected IIS host enrollment; runner location was not inferred from labels.'
        if ($null -eq $machine) { return ,$rows }
        $targetFile=Invoke-DhCheck $rows 'IIS target enrollment' {
            $file=Read-ClcProtectedTarget $context $Config.TargetId
            Assert-DhRequirement ($file.record.applicationId -ceq $Config.ApplicationId -and $file.record.environmentName -ceq $Config.EnvironmentName)
            $file
        } 'The protected target is valid and matches the explicit application, environment and target selection.'
        if ($null -eq $targetFile) { return ,$rows }
        $target=$targetFile.record
        $presence=Invoke-DhCheck $rows 'IIS site and pool presence' {
            $value=Get-DhIisPresence $context $target
            Assert-DhRequirement ($value.siteCount -eq 1 -and $value.poolCount -eq 1)
            $value
        } 'A bounded read-only IIS enumeration found exactly the enrolled site and application pool.'
        $iis=Invoke-DhCheck $rows 'IIS site and pool configuration' {
            $value=Get-ClcIisObservation $context $target
            $pool=Get-ClcCanonicalPoolName $target.applicationPoolName (Get-ClcIisPoolNames $context)
            # This assertion compares already returned facts only; a rejection is
            # a demonstrated mismatch, unlike an unavailable native observation.
            try { Assert-ClcStableIisObservation $target $value $pool }
            catch { if ($_.FullyQualifiedErrorId -like 'Clc.HostPreflightFailed*') { throw 'Dp.HostRequirementFailed' }; throw }
            $value
        } 'Dedicated site/root application/pool, physical root, runtime SID, one-worker/x64/overlap settings and current pool/worker state match the target.'
        if ($null -ne $iis) {
            ($rows | Where-Object name -CEQ 'IIS site and pool configuration').detail += " Observed pool state: $($iis.poolState); workers: $($iis.workers.Count)."
        }
        $identity=Invoke-DhCheck $rows 'Application configuration and Data Protection' {
            $value=Get-ClcTargetIdentity $context $targetFile
            Assert-ClcHostAccess $context $target $value
            foreach ($role in @(@{path=$target.applicationRoot;role='Mutable'},@{path=$target.artifactInboxRoot;role='Mutable'},@{path=[IO.Path]::GetDirectoryName($target.operationalConfigPath);role='Configuration'},@{path=$target.dataProtectionRoot;role='Keys'})) {
                Assert-ClcSafeDescendants $role.path $context $target.runtimeIdentitySid $role.role
            }
            $value
        } 'Enrolled disjoint physical directories/configuration file and effective application/configuration/key ACLs were verified without reading secret values or writing probe files. Application semantics require separate acceptance.'
        $null=Invoke-DhCheck $rows 'Runtime identity and host permissions' {
            Assert-ClcRuntimeIdentity $context $target.runtimeIdentitySid
            if ($null -eq $identity) { throw 'Unavailable path/access observation' }
            Assert-ClcHostAccess $context $target $identity
        } 'Existing Authz-backed checks establish runtime separation, structural infrastructure ACLs and effective protected-resource write isolation, including group/ancestor authority.'
        $null=Invoke-DhCheck $rows 'Hosting components and runtime' {
            if ($null -eq $presence) { throw 'Unavailable IIS module observation' }
            Assert-DhRequirement ($presence.ancmCount -eq 1)
            $platform=Get-ClcPlatformObservation
            Assert-DhRequirement ($platform.build -ceq '20348' -and $platform.productType -in @(2,3) -and $platform.is64Bit -and $platform.powershellMajor -eq 7)
            if ($null -eq $iis) { throw 'Unavailable IIS observation' }
            $runtime=Get-ClcRuntimeObservation $context $iis.ancmPath $target.runtimeIdentitySid
            Assert-DhRequirement ($runtime.ancmX64 -and $runtime.dotnetX64 -and $runtime.ancmMajor -eq 20)
            foreach ($name in @('Microsoft.NETCore.App','Microsoft.AspNetCore.App')) {
                Assert-DhRequirement (@($runtime.frameworks | Where-Object { $_.name -ceq $name -and $_.version -cmatch '^10\.0\.[0-9]+$' }).Count -gt 0)
            }
        } 'Server 2022, x64 PowerShell 7, protected IIS/ANCM and both required .NET 10 shared frameworks were directly observed using the bounded runtime read query.'
        $null=Invoke-DhCheck $rows 'Enrolled readiness and runtime environment' {
            if ($null -eq $identity) { throw 'Unavailable target identity' }
            $facts=Get-ClcHostPreflight $context $targetFile $identity 'net10.0'
            Assert-DhRequirement ($facts.poolState -cin @('Started','Stopped') -and $facts.workerCount -in @(0,1))
        } 'Existing read-only preflight verifies the enrolled readiness HTTPS binding, runtime environment and relevant current IIS state. No endpoint request or application code was executed.'
        $standing=Invoke-DhCheck $rows 'Standing authorization' { Read-DhStanding $context $target $Config.StandingAuthorizationId } 'The exact enabled standing policy has valid structure, protected paths/ACLs, independent infrastructure authority and matching target/application/environment.'
        $null=Invoke-DhCheck $rows 'Standing repository workflow and channel scope' {
            if ($null -eq $standing) { throw 'Unavailable standing policy' }
            $s=$standing.record
            Assert-DhRequirement ($s.channel -ceq $Config.DeploymentChannel -and $s.sourceRepository -ceq $Config.Repository -and $s.buildWorkflowPath -ceq $Config.ReleaseWorkflow -and $s.buildJob -ceq $Config.BuildJob)
        } 'Standing channel/repository/build workflow/build job exactly match the trusted selection; runtime environment is not used to infer DEV or production.'
        $null=Invoke-DhCheck $rows 'Pending admission' {
            $pending=Join-Path $context.layout.approvalCatalogRoot ('standing\'+$target.targetId+'.pending')
            Assert-DhRequirement (-not (Test-Path -LiteralPath $pending -ErrorAction Stop))
        } 'No unresolved target admission intent is present.'
        if ($null -eq $identity) { return ,$rows }
        $lock=Invoke-DhCheck $rows 'Canonical deployment state access' { Open-DhExistingLock $context $targetFile $identity } 'The existing actual machine/pool lock is held exclusively with read-only access; canonical state can be inspected without creating or clearing locks.'
        if ($null -eq $lock) { return ,$rows }
        $decision=Invoke-DhCheck $rows 'Host readiness and recovery qualification' {
            $value=Get-ClcReconciliationDecision $lock
            Assert-DhRequirement ($value.classification -ceq 'Clean')
            $value
        } 'Journal/current/terminal consistency and exact helper-process exit checks show no unresolved deployment/recovery state. This does not constitute a deployment/recovery pilot.'
        $current=Invoke-DhCheck $rows 'Initial successful deployment baseline' {
            if ($null -eq $decision) { throw 'Unverified deployment state' }
            Assert-DhRequirement ($null -ne $lock.state.current)
            $lock.state.current.record
        } 'A successful durable current baseline and matching terminal state exist; routine standing deployment has an independently approved starting point.'
        if ($null -eq $current) { return ,$rows }
        $null=Invoke-DhCheck $rows 'Standing lineage compatibility' {
            if ($null -eq $standing) { throw 'Unavailable standing policy' }
            Assert-DhRequirement ($current.approvalSnapshot.lineageId -ceq $standing.record.lineageId)
        } 'Current baseline and standing policy have the same lineage.'
        $release=Invoke-DhCheck $rows 'Current release and retained approval' {
            foreach ($path in @((Join-Path $context.layout.approvalCatalogRoot ($current.approvalSnapshot.approvalId+'.json')),
                (Join-Path $lock.identity.controlRoot ('releases\'+$current.approvalSnapshot.approvalId+'.json')))) {
                Assert-DhRequirement (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction Stop)
            }
            $value=Read-ClcApprovedManifest $lock $current.approvalSnapshot.approvalId
            Assert-ClcReleaseBinding $value $current.release $current.approvalSnapshot
            if ($value.approvalFile.record.schemaVersion -eq 2) { $null=Read-ClcActiveStandingForApproval $context $target $value.approvalFile }
            $value
        } 'Current enabled exact approval, retained manifest, source/build/release identity and lineage match; generated approvals also recheck standing revocation and retained admission/tag evidence. Historical ZIP retention is not required by this contract.'
        $null=Invoke-DhCheck $rows 'Current installed release bytes' {
            if ($null -eq $release) { throw 'Unavailable retained release' }
            $null=Get-ClcTreeInventory $target.applicationRoot $release.manifest.files
        } 'Installed managed files match the complete exact approval-pinned retained inventory; unexpected files are rejected and preserved.'
        $null=Invoke-DhCheck $rows 'Retained recovery material' {
            if ($null -ne $lock.state.journal.record.backup) { $null=Assert-ClcBackup @{lock=$lock} $lock.state.journal.record }
        } 'The latest journal-selected backup/index is verified when present; no backup is required for an attempt that never created one. Historical ZIPs are not required by the current recovery contract.'
        $null=Invoke-DhCheck $rows 'Stable final observation' {
            Assert-ClcTrustedContextUnchanged $context
            Assert-ClcHeldRecordUnchanged $context $targetFile 'Clc.HostPreflightFailed'
            if ($null -ne $standing) { Assert-ClcHeldRecordUnchanged $context $standing 'Clc.StandingAuthorizationRejected' }
            $actual=Get-ClcTargetIdentity $context $targetFile
            Assert-DhRequirement (Test-ClcValueEqual $actual.snapshot $identity.snapshot)
            if ($null -eq $iis) { throw 'Unavailable initial IIS observation' }
            Assert-DhRequirement ((Get-ClcIisConfigurationHash $actual.iis) -ceq (Get-ClcIisConfigurationHash $iis))
        } 'Protected toolkit/policy/target/standing bytes and physical/IIS identities remained consistent across this bounded observation. No fresh application validation or readiness request was executed.'
        return ,$rows
    } finally {
        if ($null -ne $lock) { $lock.stream.Dispose(); $lock.closed=$true }
        Close-ClcTrustedContext $context
    }
}

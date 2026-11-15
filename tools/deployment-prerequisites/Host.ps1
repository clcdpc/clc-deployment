# Loaded only inside the independently authenticated installed module.
. "$PSScriptRoot/Reporting.ps1"

function Open-ClcDeploymentPrerequisiteExistingLock {
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
    } catch [IO.FileNotFoundException] {
        if ($null -ne $stream) {$stream.Dispose()}
        Stop-ClcDeploymentPrerequisiteObservation 'FAIL' 'The enrolled canonical lock file is missing; diagnostics never create it.'
    } catch [IO.DirectoryNotFoundException] {
        if ($null -ne $stream) {$stream.Dispose()}
        Stop-ClcDeploymentPrerequisiteObservation 'FAIL' 'The enrolled canonical lock directory is missing.'
    } catch { if ($null -ne $stream) {$stream.Dispose()}; throw }
}

function Get-ClcDeploymentPrerequisiteIisPresence {
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

function Read-ClcDeploymentPrerequisiteStanding {
    param($Context, $Target, [string] $Id)
    $root=Join-Path $Context.layout.approvalCatalogRoot 'standing'
    $path=Join-Path $root ($Id+'.json')
    Confirm-ClcDeploymentPrerequisiteRequirement (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction Stop)
    foreach ($item in @($root,$path)) { $null=Add-ClcProtectedPathPin $Context $item -Directory:($item -ceq $root) -RuntimeSid $Target.runtimeIdentitySid }
    $file=Read-ClcHeldRecord $path standing-authorization $Context.handles
    $s=$file.record; $p=$Context.policyFile.record
    # The engine intentionally collapses access/parse/revocation errors into one
    # rejection. Establish observable failures before its final read so denied
    # effective-access evidence is never misreported as a proven revocation.
    Confirm-ClcDeploymentPrerequisiteRequirement ($s.enabled -and $s.standingAuthorizationId -ceq $Id -and $s.targetId -ceq $Target.targetId -and
        $s.applicationId -ceq $Target.applicationId -and $s.environmentName -ceq $Target.environmentName -and
        $p.infrastructureOwnerSids -ccontains $s.authorization.authoritySid -and $p.deploymentSids -cnotcontains $s.authorization.authoritySid)
    Read-ClcStandingAuthorization $Context $Target $Id
}

function Confirm-ClcDeploymentPrerequisiteRequirement {
    param([bool] $Condition,[string] $Detail='The observed prerequisite is missing or inconsistent with the enrolled configuration.')
    if (-not $Condition) {Stop-ClcDeploymentPrerequisiteObservation FAIL $Detail}
}

function Get-ClcDeploymentPrerequisiteHostObservation {
    param([string] $Id,[scriptblock] $Read,[string] $Success,[string] $Action,[bool] $CanInspect=$true,[string] $Prerequisite='')
    if (-not $CanInspect) {
        return @{established=$false;value=$null;check=(New-ClcDeploymentPrerequisiteCheck $Id SKIPPED "The prerequisite $Prerequisite was not established; this check did not execute." $Action -Reason $Prerequisite)}
    }
    try {
        $value=& $Read
        @{established=$true;value=$value;check=(New-ClcDeploymentPrerequisiteCheck $Id PASS $Success)}
    } catch {
        $status='UNVERIFIED';$detail='The read-only observation was attempted but could not establish this requirement; permissions, unavailable native evidence or concurrent changes may prevent inspection.'
        if ($_.Exception.Data.Contains('prerequisite_status')) {
            $status=$_.Exception.Data['prerequisite_status'];$detail=$_.Exception.Data['prerequisite_detail']
        }
        @{established=$false;value=$null;check=(New-ClcDeploymentPrerequisiteCheck $Id $status $detail $Action)}
    }
}

function Get-ClcDeploymentPrerequisiteSkippedHostChecks {
    param([string[]] $Ids,[string] $Prerequisite)
    foreach ($id in $Ids) {
        New-ClcDeploymentPrerequisiteCheck $id SKIPPED "The prerequisite $Prerequisite was not established; this check did not execute." 'Correct the prerequisite and rerun the read-only host inspection.' -Reason $Prerequisite
    }
}

function Invoke-ClcDeploymentPrerequisiteHostInspection {
    param([hashtable] $Config)
    $rows=[Collections.Generic.List[object]]::new();$context=$null;$lock=$null
    try {
        $toolkit=Get-ClcDeploymentPrerequisiteHostObservation 'host.toolkit.authentication' {
            foreach ($command in @('Open-ClcTrustedContext','Read-ClcStandingAuthorization','Read-ClcApprovedManifest','Get-ClcReconciliationDecision','Get-ClcHostPreflight','Get-ClcEmptyBaselineEligibility')) {
                Confirm-ClcDeploymentPrerequisiteRequirement ($null -ne (Get-Command $command -ErrorAction SilentlyContinue)) 'The authenticated installed toolkit lacks a required compatible host/state reader.'
            }
            Open-ClcTrustedContext
        } 'Independent bootstrap authentication preceded import; installed policy/source/distribution/inventory and compatible readers were revalidated.' 'Install and independently authenticate a compatible exact toolkit distribution under infrastructure authority.'
        $rows.Add($toolkit.check);$context=$toolkit.value
        if ($toolkit.established) {$toolkit.check.detail+=" Executing toolkit: $($context.executingToolkit.version); source: $($context.executingToolkit.sourceCommit)."}
        if (-not $toolkit.established) {
            foreach ($row in @(Get-ClcDeploymentPrerequisiteSkippedHostChecks @('host.identity.permissions','host.machine.binding','host.target.enrollment','host.iis.configuration','host.state.lock') 'host.toolkit.authentication')) {$rows.Add($row)}
            return $rows.ToArray()
        }
        $token=Get-ClcDeploymentPrerequisiteHostObservation 'host.identity.permissions' {
            $p=$context.policyFile.record;$caller=Get-ClcCallerSid
            Confirm-ClcDeploymentPrerequisiteRequirement ($p.deploymentSids -ccontains $caller -and (Test-ClcAdministratorToken)) 'Inspection requires the exact admitted deployment SID and an enabled elevated administrator token.'
            Assert-ClcDeploymentToken $p
        } 'The inspection identity is admitted and elevated. Infrastructure approval independence remains procedural against this administrator.' 'Run under the policy-admitted deployment identity with its enabled elevated token; diagnostics never self-elevate.'
        $rows.Add($token.check)
        $machine=Get-ClcDeploymentPrerequisiteHostObservation 'host.machine.binding' {
            $observed=@(Get-ClcMachineUuidObservation);$uuid=[guid]::Empty
            if ($observed.Count -ne 1 -or $observed[0] -isnot [string] -or -not [guid]::TryParseExact($observed[0],'D',[ref]$uuid) -or $uuid -eq [guid]::Empty -or $uuid.ToString('D') -ceq 'ffffffff-ffff-ffff-ffff-ffffffffffff') {
                Stop-ClcDeploymentPrerequisiteObservation UNVERIFIED 'A canonical actual local SMBIOS machine identity could not be observed.'
            }
            Confirm-ClcDeploymentPrerequisiteRequirement ($uuid.ToString('D') -ceq $context.policyFile.record.machineIdentity) 'The actual inspected machine UUID differs from protected enrollment.'
            Get-ClcMachineIdentity $context.policyFile.record.machineIdentity
        } 'Actual local machine identity matches protected enrollment; runner labels were not used as host evidence.' 'Run on the enrolled machine and reconcile any incorrect machine binding through infrastructure.' $token.established 'host.identity.permissions'
        $rows.Add($machine.check)
        if (-not $machine.established) {
            foreach ($row in @(Get-ClcDeploymentPrerequisiteSkippedHostChecks @('host.target.enrollment','host.iis.configuration','host.runtime.compatibility','host.state.lock') 'host.machine.binding')) {$rows.Add($row)}
            return $rows.ToArray()
        }
        $enrollment=Get-ClcDeploymentPrerequisiteHostObservation 'host.target.enrollment' {
            $path=Join-Path $context.layout.targetCatalogRoot ($Config.TargetId+'.json')
            Confirm-ClcDeploymentPrerequisiteRequirement (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction Stop) 'The exact target record is missing from the protected enrollment catalog.'
            try {$file=Read-ClcProtectedTarget $context $Config.TargetId} catch {
                # A malformed protected record is a configuration defect; unavailable access remains inconclusive.
                if ($_.FullyQualifiedErrorId -like 'Clc.InvalidContract*' -or $_.FullyQualifiedErrorId -like 'Clc.UnsupportedContract*') {Stop-ClcDeploymentPrerequisiteObservation FAIL 'The protected target record has an invalid or unsupported contract.'}
                throw
            }
            Confirm-ClcDeploymentPrerequisiteRequirement ($file.record.targetId -ceq $Config.TargetId -and $file.record.applicationId -ceq $Config.ApplicationId -and $file.record.environmentName -ceq $Config.EnvironmentName) 'Protected target application/environment/target bindings disagree with this inspection.'
            $file
        } 'The exact protected target and application/environment bindings are valid.' 'Independently enroll or reconcile this exact target; diagnostics never create or repair enrollment.'
        $rows.Add($enrollment.check)
        if (-not $enrollment.established) {
            foreach ($row in @(Get-ClcDeploymentPrerequisiteSkippedHostChecks @('host.iis.configuration','host.runtime.compatibility','host.filesystem.permissions','host.state.lock') 'host.target.enrollment')) {$rows.Add($row)}
            return $rows.ToArray()
        }
        $targetFile=$enrollment.value;$target=$targetFile.record
        $presence=Get-ClcDeploymentPrerequisiteHostObservation 'host.iis.presence' {
            $value=Get-ClcDeploymentPrerequisiteIisPresence $context $target
            Confirm-ClcDeploymentPrerequisiteRequirement ($value.siteCount -eq 1 -and $value.poolCount -eq 1) 'The enrolled dedicated IIS site or application pool is missing or ambiguous.'
            $value
        } 'Exactly the enrolled dedicated IIS site and pool exist.' 'Provision or reconcile the exact enrolled IIS site and pool through infrastructure; do not mutate them from diagnostics.'
        $rows.Add($presence.check)
        $iis=Get-ClcDeploymentPrerequisiteHostObservation 'host.iis.configuration' {
            $value=Get-ClcIisObservation $context $target
            $pool=Get-ClcCanonicalPoolName $target.applicationPoolName (Get-ClcIisPoolNames $context)
            try {Assert-ClcStableIisObservation $target $value $pool} catch {
                Stop-ClcDeploymentPrerequisiteObservation FAIL 'Returned IIS facts do not match the dedicated root application/path/runtime identity/one-worker/pool configuration.'
            }
            $value
        } 'Dedicated IIS root application/path/runtime SID, x64/one-worker/overlap settings and pool/worker state match enrollment.' 'Correct the observed IIS application/pool settings under separate infrastructure authority.' $presence.established 'host.iis.presence'
        $rows.Add($iis.check)
        $paths=Get-ClcDeploymentPrerequisiteHostObservation 'host.filesystem.permissions' {
            $value=Get-ClcTargetIdentity $context $targetFile
            Assert-ClcHostAccess $context $target $value
            foreach ($role in @(@{path=$target.applicationRoot;role='Mutable'},@{path=$target.artifactInboxRoot;role='Mutable'},@{path=[IO.Path]::GetDirectoryName($target.operationalConfigPath);role='Configuration'},@{path=$target.dataProtectionRoot;role='Keys'})) {
                Assert-ClcSafeDescendants $role.path $context $target.runtimeIdentitySid $role.role
            }
            $value
        } 'Disjoint physical directories/configuration/key paths and effective filesystem permissions were checked without exposing private configuration or writing probes.' 'Inspect enrolled directories, physical identities, protected configuration/key ACLs and effective deployment/runtime access.' $iis.established 'host.iis.configuration'
        $rows.Add($paths.check);$identity=$paths.value
        $runtimeIdentity=Get-ClcDeploymentPrerequisiteHostObservation 'host.identity.runtime' {
            Assert-ClcRuntimeIdentity $context $target.runtimeIdentitySid
            Assert-ClcHostAccess $context $target $identity
        } 'Authz-backed readers checked distinct nonadministrator runtime identity, group-derived authority and effective protected-resource write isolation.' 'Reconcile runtime group membership and effective protected-resource permissions under infrastructure authority.' $paths.established 'host.filesystem.permissions'
        $rows.Add($runtimeIdentity.check)
        $runtime=Get-ClcDeploymentPrerequisiteHostObservation 'host.runtime.compatibility' {
            Confirm-ClcDeploymentPrerequisiteRequirement ($presence.value.ancmCount -eq 1) 'Required IIS AspNetCoreModuleV2 is missing or ambiguous.'
            $platform=Get-ClcPlatformObservation
            Confirm-ClcDeploymentPrerequisiteRequirement ($platform.build -ceq '20348' -and $platform.productType -in @(2,3) -and $platform.is64Bit -and $platform.powershellMajor -eq 7) 'The observed platform is incompatible with Windows Server 2022 and x64 PowerShell 7.'
            $value=Get-ClcRuntimeObservation $context $iis.value.ancmPath $target.runtimeIdentitySid
            Confirm-ClcDeploymentPrerequisiteRequirement ($value.ancmX64 -and $value.dotnetX64 -and $value.ancmMajor -eq 20) 'The observed .NET/ANCM architecture or major version is incompatible.'
            foreach ($name in @('Microsoft.NETCore.App','Microsoft.AspNetCore.App')) {
                Confirm-ClcDeploymentPrerequisiteRequirement (@($value.frameworks | Where-Object {$_.name -ceq $name -and $_.version -cmatch '^10\.0\.[0-9]+$'}).Count -gt 0) "The required $name 10.0 runtime was not observed."
            }
        } 'Supported Windows Server, x64 PowerShell, .NET/ASP.NET Core 10 and ANCM were observed using bounded infrastructure queries.' 'Independently install the supported Windows/IIS/PowerShell/.NET/ANCM components.' $iis.established 'host.iis.configuration'
        $rows.Add($runtime.check)
        $preflight=Get-ClcDeploymentPrerequisiteHostObservation 'host.iis.environment' {
            $facts=Get-ClcHostPreflight $context $targetFile $identity 'net10.0'
            Confirm-ClcDeploymentPrerequisiteRequirement ($facts.poolState -cin @('Started','Stopped') -and $facts.workerCount -in @(0,1)) 'The observed pool/worker state is incompatible with deployment.'
        } 'Read-only host preflight verified HTTPS binding, runtime environment and infrastructure state without invoking readiness or application code.' 'Inspect the enrolled HTTPS binding, pool environment and hosting configuration under infrastructure authority.' ($paths.established -and $runtime.established) 'host.filesystem.permissions/runtime.compatibility'
        $rows.Add($preflight.check)
        $standing=$null
        if ($Config.StandingAuthorizationId) {
            $policy=Get-ClcDeploymentPrerequisiteHostObservation 'host.standing.policy' {Read-ClcDeploymentPrerequisiteStanding $context $target $Config.StandingAuthorizationId} 'The selected optional standing policy is protected, enabled and bound to this target.' 'Reconcile the selected optional standing policy before routine automation; an independently approved initial deployment does not require it.'
            $rows.Add($policy.check);$standing=$policy.value
            $scope=Get-ClcDeploymentPrerequisiteHostObservation 'host.standing.scope' {
                $s=$standing.record
                Confirm-ClcDeploymentPrerequisiteRequirement ($s.channel -ceq $Config.DeploymentChannel -and $s.sourceRepository -ceq $Config.Repository -and $s.buildWorkflowPath -ceq $Config.ReleaseWorkflow -and $s.buildJob -ceq $Config.BuildJob) 'The selected optional standing policy channel/repository/producer scope differs from this inspection.'
            } 'Optional standing policy matches the explicit channel, repository and producer.' 'Correct optional standing scope independently; DEV and Production remain separate.' $policy.established 'host.standing.policy'
            $rows.Add($scope.check)
        } else {
            foreach ($id in @('host.standing.policy','host.standing.scope')) {$rows.Add((New-ClcDeploymentPrerequisiteCheck $id NOT_APPLICABLE 'No standing policy was selected; independently approved initial deployment does not require standing authority.' -Reason 'not-selected'))}
        }
        $lockResult=Get-ClcDeploymentPrerequisiteHostObservation 'host.state.lock' {Open-ClcDeploymentPrerequisiteExistingLock $context $targetFile $identity} 'The existing canonical machine/pool lock is held exclusively for read-only state inspection; it was not created or modified.' 'Fence concurrent deployment and inspect the existing canonical lock/path/permissions; missing enrollment lock infrastructure requires independent reconciliation.' $paths.established 'host.filesystem.permissions'
        $rows.Add($lockResult.check);$lock=$lockResult.value
        $pending=Get-ClcDeploymentPrerequisiteHostObservation 'host.state.pending-admission' {
            $path=Join-Path $context.layout.approvalCatalogRoot ('standing\'+$target.targetId+'.pending')
            Confirm-ClcDeploymentPrerequisiteRequirement (-not (Test-Path -LiteralPath $path -ErrorAction Stop)) 'An unresolved target admission intent blocks deployment; retain it for independent reconciliation.'
        } 'No unresolved target pending-admission record exists.' 'Preserve pending evidence and complete separately authorized infrastructure reconciliation; diagnostics never clear it.' $lockResult.established 'host.state.lock'
        $rows.Add($pending.check)
        $state=Get-ClcDeploymentPrerequisiteHostObservation 'host.state.consistency' {
            $value=Get-ClcReconciliationDecision $lock
            Confirm-ClcDeploymentPrerequisiteRequirement ($value.classification -cin @('Clean','EmptyRecoveryNeedsVerification')) 'Canonical journal/current/terminal/helper evidence identifies unresolved recovery or contradictory deployment state.'
            if ($null -eq $lock.state.current) {
                if ($value.classification -ceq 'EmptyRecoveryNeedsVerification') {
                    $guard=Read-ClcApprovedManifest $lock $lock.state.journal.record.candidate.approvalId
                    Confirm-ClcDeploymentPrerequisiteRequirement (Get-ClcEmptyBaselineEligibility $lock $guard).eligible 'Retained RestoreEmpty evidence is incompatible with the engine initial-state rules.'
                } else {
                    try {$null=Get-ClcTreeInventory $target.applicationRoot -ExpectedFiles @()} catch {
                        if ($_.FullyQualifiedErrorId -like 'Clc.ContentDrift*') {Stop-ClcDeploymentPrerequisiteObservation FAIL 'Unexpected application files contradict the engine initial-empty-state rules; retain them for reconciliation.'}
                        throw
                    }
                }
            }
            $value
        } 'Canonical state and helper evidence permit safe commencement. An empty target was checked using the engine initial-state rules; no baseline was fabricated.' 'Preserve state and unexpected files; use separately authorized recovery or infrastructure reconciliation.' $lockResult.established 'host.state.lock'
        $rows.Add($state.check)
        $current=if ($state.established -and $null -ne $lock.state.current) {$lock.state.current.record} else {$null}
        if ($state.established -and $null -eq $current) {
            foreach ($id in @('host.state.current-release','host.state.inventory')) {$rows.Add((New-ClcDeploymentPrerequisiteCheck $id NOT_APPLICABLE 'Verified empty initial state has no deployed release, current approval or installed release inventory to inspect.' -Reason 'empty-target'))}
        } else {
            $release=Get-ClcDeploymentPrerequisiteHostObservation 'host.state.current-release' {
                foreach ($path in @((Join-Path $context.layout.approvalCatalogRoot ($current.approvalSnapshot.approvalId+'.json')),(Join-Path $lock.identity.controlRoot ('releases\'+$current.approvalSnapshot.approvalId+'.json')))) {
                    Confirm-ClcDeploymentPrerequisiteRequirement (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction Stop) 'Required current approval or retained release manifest is missing.'
                }
                try {
                    $value=Read-ClcApprovedManifest $lock $current.approvalSnapshot.approvalId
                    Assert-ClcReleaseBinding $value $current.release $current.approvalSnapshot
                } catch {
                    if ($_.FullyQualifiedErrorId -like 'Clc.ApprovalDisabled*' -or $_.FullyQualifiedErrorId -like 'Clc.ApprovalMismatch*') {
                        Stop-ClcDeploymentPrerequisiteObservation FAIL 'The current retained approval is disabled or its exact approved release/manifest binding is incorrect.'
                    }
                    throw
                }
                if ($value.approvalFile.record.schemaVersion -ge 2) {$null=Read-ClcActiveStandingForApproval $context $target $value.approvalFile}
                $value
            } 'Current exact approval, retained manifest and release bindings are valid; generated schemas 2 and 3 also recheck standing revocation.' 'Retain and reconcile current approval/manifest/binding evidence; generated approval retries require their original active standing authority.' $state.established 'host.state.consistency'
            $rows.Add($release.check)
            $inventory=Get-ClcDeploymentPrerequisiteHostObservation 'host.state.inventory' {
                try {$null=Get-ClcTreeInventory $target.applicationRoot $release.value.manifest.files} catch {
                    if ($_.FullyQualifiedErrorId -like 'Clc.ContentDrift*') {Stop-ClcDeploymentPrerequisiteObservation FAIL 'Installed files differ from the current approved inventory, or unexpected content is present; preserve the files.'}
                    throw
                }
            } 'Installed managed bytes match the current approval-pinned inventory; unexpected files were rejected and preserved.' 'Preserve drift and follow separately authorized recovery; diagnostics never clean or restore files.' $release.established 'host.state.current-release'
            $rows.Add($inventory.check)
        }
        if ($null -ne $current -and $null -ne $standing) {
            $lineage=Get-ClcDeploymentPrerequisiteHostObservation 'host.standing.lineage' {Confirm-ClcDeploymentPrerequisiteRequirement ($current.approvalSnapshot.lineageId -ceq $standing.record.lineageId) 'Optional standing lineage differs from the current baseline.'} 'Optional standing lineage agrees with the current baseline.' 'Independently reconcile optional standing lineage before routine releases.'
            $rows.Add($lineage.check)
        } else {$rows.Add((New-ClcDeploymentPrerequisiteCheck 'host.standing.lineage' NOT_APPLICABLE 'No current baseline or optional standing policy requires a lineage comparison.' -Reason 'no-baseline-or-policy'))}
        $stable=Get-ClcDeploymentPrerequisiteHostObservation 'host.state.stability' {
            Assert-ClcTrustedContextUnchanged $context;Assert-ClcHeldRecordUnchanged $context $targetFile 'Clc.HostPreflightFailed'
            if ($null -ne $standing) {Assert-ClcHeldRecordUnchanged $context $standing 'Clc.StandingAuthorizationRejected'}
            $actual=Get-ClcTargetIdentity $context $targetFile
            if (-not (Test-ClcValueEqual $actual.snapshot $identity.snapshot)) {Stop-ClcDeploymentPrerequisiteObservation UNVERIFIED 'Target physical identity changed during inspection.'}
            if ((Get-ClcIisConfigurationHash $actual.iis) -cne (Get-ClcIisConfigurationHash $iis.value)) {Stop-ClcDeploymentPrerequisiteObservation UNVERIFIED 'IIS configuration changed during inspection.'}
            $final=Get-ClcReconciliationDecision $lock
            if (-not (Test-ClcValueEqual $final $state.value)) {Stop-ClcDeploymentPrerequisiteObservation UNVERIFIED 'Canonical reconciliation state changed during inspection.'}
        } 'Protected toolkit/policy/target, physical/IIS identities and canonical reconciliation state remained stable across this observation.' 'Freeze competing trusted writers, investigate drift and rerun inspection.' ($paths.established -and $state.established) 'host.state.consistency'
        $rows.Add($stable.check)
        $rows.Add((New-ClcDeploymentPrerequisiteCheck 'host.application.acceptance' UNVERIFIED 'Application startup, configuration semantics, database access, HTTPS readiness and Data Protection compatibility were not executed. Deployment/recovery acceptance remains separate.' 'Perform separately authorized application deployment/recovery acceptance after correcting infrastructure prerequisites.'))
        $rows.ToArray()
    } catch {
        $rows.Add((New-ClcDeploymentPrerequisiteCheck 'host.stage' UNVERIFIED 'Unexpected host inspection failure interrupted remaining checks; private exception details were suppressed.' 'Correct the inspection error and rerun; retain confirmed findings.' -Reason 'inspection-error'))
        $rows.ToArray()
    } finally {
        if ($null -ne $lock) {$lock.stream.Dispose();$lock.closed=$true}
        if ($null -ne $context) {Close-ClcTrustedContext $context}
    }
}

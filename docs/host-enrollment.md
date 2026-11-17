# Host enrollment procedure

Infrastructure follows this procedure on the intended host, separately for each target. It prepares inputs for [Get-ClcHostEnrollment.ps1](../tools/host/Get-ClcHostEnrollment.ps1) and [Initialize-ClcHostEnrollment.ps1](../tools/host/Initialize-ClcHostEnrollment.ps1). Application releases remain separately approved. Behavior below is grounded in [557192e](https://github.com/clcdpc/clc-deployment/tree/557192eff5eea651d6f1a393eb3b196053a985e5).

**Ordering:** observation collection below is preauthorization preparation. The first enrollment **Inspect and Plan already require an independently installed protected authorization**. Neither command bootstraps that authority.

## 1. Inspect and prepare the host

1. **Infrastructure workstation:** obtain the reviewed source and independently authenticate the selected format-3 toolkit using [installation](installation.md#initial-bootstrap-provisioning). Set `$reviewedSource` to that authenticated source directory and retain the approved version/source/archive digest. Never use an unauthenticated archive's verifier to authenticate itself.
2. **Intended host, elevated PowerShell 7 x64:** confirm Windows Server 2022 (build 20348), installed x64 .NET 10/ANCM 20, IIS and protected native helpers. Infrastructure supplies existing deployment/runtime accounts, logon/profile rights, trusted HTTPS certificate/private key, DNS and network routing. Obtain account names and actual SIDs from the identity owner. Deployment must have an enabled elevated Administrators token on managed IIS hosts. Runtime must be distinct and nonadministrator, including indirect groups. Enrollment creates no accounts, passwords, secrets, certificates, machine trust or components.
3. Derive the canonical namespace with the reviewed native path logic:

```powershell
$targetId = 'ssrs-web-dev'
# $approvedVersion is the independently selected full toolkit version.
. "$reviewedSource\src\Clc.Deployment\Private\Contracts.ps1"
. "$reviewedSource\src\Clc.Deployment\Private\Paths.ps1"
$layout = Get-ClcTargetLayout $targetId $approvedVersion
$targetRoot = $layout.targetRoot
$bootstrapRoot = $layout.bootstrapRoot
$hostDeploymentJson = Join-Path $targetRoot 'Config\deployment.json'
```

Success: native ProgramData gives `%ProgramData%\clc-ssrs-web-dev\Deployment`; environment variables cannot redirect it. The target owns all resources below:

```text
clc-<target-id>/
  Application/; Config/application.json; Config/deployment.json; Keys/; Inbox/; Logs/ (optional)
  Deployment/
    bootstrap/                         # independently prepared executable bootstrap
    enrollment/authorizations/<authorizationId>.json
    enrollment/evidence/; enrollment/enrollment.lock
    toolkit/versions/<version>/         # Apply creates the first installation
    toolkit/policy/host-policy.json
    toolkit/policy/targets/<targetId>.json
    toolkit/policy/approvals/<approvalId>.json
    locks/<targetKey>.lock; control/<targetKey>/...
```

4. **Infrastructure provisioning procedure:** create only absent target root, `Deployment`, `Config`, and `Deployment\enrollment` with `authorizations`, `evidence`, and an empty regular `enrollment.lock` file. Provision the bootstrap using [installation](installation.md). In Windows **Properties > Security > Advanced**, set protected directory/file ownership to **BUILTIN\Administrators**, disable inheritance/remove inherited grants, and grant **SYSTEM** and **BUILTIN\Administrators** FullControl (directories: this folder, subfolders and files). Inspect every ancestor's owner and delete-child/delete/DACL/owner rights so runtime cannot replace protected children. Handoff/bootstrap accept only SYSTEM/Administrators writers; ancestor TrustedInstaller ownership/structural rights are also recognized. Never add the individual deployment SID as a protected writer. Its elevated Administrators membership provides access; independent approval against that administrator remains procedural.
5. Provision the application-owned `Config\application.json` with infrastructure ownership, infrastructure-only writes and deployment/runtime reads. If precreating Application/Inbox/Keys, preserve their required [access roles](#provisioning-and-preservation); otherwise Apply can create these three directories. Existing resources require valid ACLs before enrollment; there is no repair option. Logs and application-specific permissions remain external. Verify effective access under actual identities, including group-derived access; descriptor appearance alone is insufficient.

Success: only `bootstrap` and `enrollment` exist under fresh Deployment. Do not precreate toolkit/control/locks. Prior resources, intent, lock or state with missing records require independent reconciliation. Historical machine-wide installations are not moved/adopted automatically. Control roots must fit 71 characters, lock roots 170, and prospective state paths 240; long names/native ProgramData locations can be rejected.

## 2. Prepare Config/deployment.json

On the host, write UTF-8 JSON at `$hostDeploymentJson`, matching [the strict schema](../schemas/deployment-configuration.schema.json). Substitute actual native paths, account and readiness DNS name; this example grants no authority:

```json
{
  "contractFamily": "clc-host-enrollment-v1",
  "schemaVersion": 1,
  "recordKind": "deployment-configuration",
  "applicationId": "ssrs-web",
  "targetId": "ssrs-web-dev",
  "environmentName": "DEV",
  "runtimeEnvironment": "Production",
  "siteName": "ssrs-web-dev",
  "applicationPoolName": "ssrs-web-dev",
  "applicationRoot": "C:\\ProgramData\\clc-ssrs-web-dev\\Application",
  "operationalConfigPath": "C:\\ProgramData\\clc-ssrs-web-dev\\Config\\application.json",
  "dataProtectionRoot": "C:\\ProgramData\\clc-ssrs-web-dev\\Keys",
  "artifactInboxRoot": "C:\\ProgramData\\clc-ssrs-web-dev\\Inbox",
  "runtimeIdentitySid": "S-1-5-21-1-2-3-2001",
  "runtimeAccountName": "EXAMPLE\\svc-ssrs-web",
  "readinessUri": "https://ssrs-web-dev.example.invalid/health/ready",
  "enrollmentRoot": "C:\\ProgramData\\clc-ssrs-web-dev\\Deployment"
}
```

Use the application owner's IDs/environment/readiness contract and infrastructure's exact dedicated site/pool/account. `environmentName` labels the target; `runtimeEnvironment` is `Production` or `Staging`. Resolve the account using the command below rather than inventing its SID. Deployment configuration contains no operational configuration, credentials or authority. Unknown/duplicate fields and unsupported contracts refuse. Protect its final bytes before collecting the digest; subsequent edits require a new independently approved binding.

## 3. Collect observations and prepare the candidate

**On the host, in a fresh elevated `pwsh -NoLogo -NoProfile -NonInteractive` process running as the selected deployment account**, use only the independently authenticated packaged bootstrap under infrastructure supervision. The IIS/helper readers require the current caller's exact SID in the prospective/current `deploymentSids` and an enabled elevated Administrators token; an infrastructure approver account alone will fail. Do not add the approver as a deployment SID to bypass that check. This infrastructure-only preparation uses existing internal readers, not an additional module command or authenticated enrollment inspection. It reads local paths, identities and IIS; the read-only IIS plan also validates TLS, including bounded certificate revocation lookup. It installs nothing and changes no files/IIS settings. Keep the session and candidate local under infrastructure control: raw IIS environment values, snapshot digest and private configuration hashes must not enter transcripts, CI output or source.

Supply these independently chosen inputs before the block:

| Input | Source |
| --- | --- |
| `$bootstrapRoot`, `$hostDeploymentJson`, `$approvedVersion`, `$approvedSource`, `$approvedDigest` | Canonical layout and independently verified installation procedure |
| `$deploymentAccountName`, `$authorityAccountName` | Actual existing deployment and separate approving infrastructure accounts; approving SID must differ from deployment SID |
| `$bindingAddress`, `$certificateThumbprint` | Infrastructure's intended explicit local IP (for example `127.0.0.1`, never `*`) and uppercase 40-hex thumbprint from `Get-ChildItem -LiteralPath Cert:\LocalMachine\My`; select the installed valid server-auth certificate for the readiness hostname |
| `$newPoolIdentityType` | `ExistingOnly` for an existing conventional service-account pool; `ManagedServiceAccount` only for a missing pool whose managed account is already locally installed |
| `$authorizationId`, `$changeReference` | New lowercase safe authorization ID and nonsecret approved change reference, at most 64/128 characters respectively |
| `$proposedApprovedUtc`, `$proposedExpiresUtc` | Proposed UTC window from the infrastructure maintenance request, e.g. `2026-11-18T15:00:00Z` / `2026-11-18T17:00:00Z`; expiry must be later. Approver sets the actual reviewed window |

Run the whole block with those values. The initial policy uses generation 1; an existing installation instead retains its independently authenticated **complete current policy**, never resets its generation or active pin.

```powershell
# setup-example: enrollment-candidate
. "$bootstrapRoot\tools\host\HostEnrollment.Common.ps1"
$handles = [Collections.Generic.List[IDisposable]]::new()
try {
    $configurationFile = Read-ClcHeldFile $hostDeploymentJson $handles
    $configuration = Read-HJson $configurationFile.bytes
    Assert-HConfiguration $configuration
    $target = Get-HTarget $configuration
    $layout = Get-HLayout $target.targetId $approvedVersion
    Assert-ClcTargetPaths $target $layout
    if ($configuration.enrollmentRoot -cne $layout.deploymentRoot -or
        $hostDeploymentJson -cne (Join-Path $layout.targetRoot 'Config\deployment.json')) {
        throw 'Configuration must use the canonical target-local paths.'
    }
    Assert-HBootstrapProtection $layout $handles
    $verified = & "$bootstrapRoot\tools\Test-ToolkitDistribution.ps1" `
        -ArchivePath "$bootstrapRoot\distribution.zip" -ExpectedSha256 $approvedDigest `
        -ExpectedSourceCommit $approvedSource -ExpectedVersion $approvedVersion `
        -InstalledModuleRoot "$bootstrapRoot\Clc.Deployment" -RequireInfrastructureTools
    $deploymentSid = Resolve-ClcAccountSid $deploymentAccountName
    $authoritySid = Resolve-ClcAccountSid $authorityAccountName
    $trustedInstallerSid = Resolve-ClcAccountSid 'NT SERVICE\TrustedInstaller'
    if ((Resolve-ClcAccountSid $configuration.runtimeAccountName) -cne $target.runtimeIdentitySid) {
        throw 'Runtime account SID differs from deployment configuration.'
    }
    $uuids = @(Get-ClcMachineUuidObservation)
    if ($uuids.Count -ne 1) { throw 'Expected exactly one SMBIOS UUID.' }
    $observedUuid = ([guid]::ParseExact($uuids[0], 'D')).ToString('D').ToLowerInvariant()
    $machineIdentity = Get-ClcMachineIdentity $observedUuid
    $policy = [ordered]@{
        contractFamily='clc-file-iis-v1'; schemaVersion=1L; recordKind='host-policy'
        generation=1L; machineIdentity=$machineIdentity
        activeToolkit=@{version=$verified.moduleVersion; sourceCommit=$verified.sourceCommit
            distributionSha256=$verified.distributionSha256; inventorySha256=$verified.inventorySha256
            moduleManifestPath=$layout.manifestPath}
        targetCatalogRoot=$layout.targetCatalogRoot; approvalCatalogRoot=$layout.approvalCatalogRoot
        controlStateRoot=$layout.controlStateRoot; lockRoot=$layout.lockRoot
        dotnetPath=(Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'dotnet\dotnet.exe')
        appcmdPath=(Join-Path ([Environment]::GetFolderPath('System')) 'inetsrv\appcmd.exe')
        infrastructureOwnerSids=@('S-1-5-18','S-1-5-32-544',$trustedInstallerSid,$authoritySid)
        deploymentSids=@($deploymentSid)
    }
    if (Test-HExists $layout.policyPath) {
        $policy = (Read-ClcHeldRecord $layout.policyPath host-policy $handles).record
        # Independently authenticate this existing policy before accepting it.
    }
    Assert-ClcRecord $policy host-policy
    Assert-ClcStatePathBudget $policy
    $bindings = @{}
    foreach ($name in @('applicationRoot','operationalConfigPath','dataProtectionRoot','artifactInboxRoot')) {
        $bindings[$name] = if (Test-HExists $target[$name]) {
            Get-HResourceBinding $target[$name] $handles -Directory:($name -cne 'operationalConfigPath')
        } else { $null }
    }
    $candidate = [ordered]@{
        contractFamily='clc-host-enrollment-v1'; schemaVersion=1L
        recordKind='host-enrollment-authorization'; authorizationId=$authorizationId; enabled=$false
        approvedUtc=$proposedApprovedUtc; expiresUtc=$proposedExpiresUtc
        authoritySid=$authoritySid; reference=$changeReference; targetId=$target.targetId
        deploymentConfigurationSha256=$configurationFile.sha256; enrollmentRoot=$layout.deploymentRoot
        hostPolicy=$policy
        bootstrap=@{sourceCommit=(Get-HBootstrapSourceCommit); inventorySha256=(Get-HBootstrapInventory)}
        permittedOperations=@(); iis=@{bindingAddress=$bindingAddress
            certificateThumbprint=$certificateThumbprint; newPoolIdentityType=$newPoolIdentityType
            expectedSnapshotSha256=('0'*64)}
        resourceBindings=$bindings; cutover=$null
    }
    $session = @{handles=$handles; context=$null; configuration=$configuration; target=$target
        authorization=$candidate; initialPoolState='Unknown'; workerCount=$null}
    $snapshot = Get-HIisSnapshot $session
    $candidate.iis.expectedSnapshotSha256 = Get-HIisSnapshotHash $snapshot
    $iisPlan = Get-HIisPlan $session
    $candidate.permittedOperations = @(
        if (-not (Test-HExists $layout.policyPath)) { 'install-toolkit' }
        'enroll-target'
        $iisPlan.operations
    )
    Assert-HAuthorization $candidate $authorizationId
    # Retain $candidate privately for independent review; do not print it or $snapshot.
} finally {
    foreach ($handle in $handles) { $handle.Dispose() }
}
```

Success: the candidate passes strict validation; all required [authorization fields](../schemas/host-enrollment-authorization.schema.json) have an explicit source. `Get-HResourceBinding` supplies native volume/file/canonical-path identity and the actual security-descriptor digest. Null means genuinely absent, never “unknown”; `application.json` must already exist. `Get-HBootstrapInventory` hashes module paths prefixed `Clc.Deployment/` plus all eight infrastructure files, using the [ordinal inventory algorithm](contracts.md#package-and-trusted-ci-digest). `Get-HIisSnapshotHash` uses its explicit sorted JSON projection; do not substitute a hash of raw appcmd output or arbitrary JSON. The snapshot reader also checks account resolution, runtime/helpers and physical-root isolation; it never reads pool passwords.

Review `$iisPlan.operations` privately. `install-toolkit` permits first installation; `enroll-target` publishes the target; `configure-iis` permits approved stopped-pool settings; `create-site`/`create-pool` permit missing dedicated IIS resources. Remove permissions not needed. Recollect and independently reapprove if the pre-state/configuration changes. Observation success alone neither authorizes effects nor proves all effective access requirements; authenticated Inspect/Plan repeat full checks.

**Legacy content:** the ordinary candidate intentionally has `cutover=null`. For a separately authorized first cutover, infrastructure fences competing writers and independently establishes the selected pool **Stopped/zero workers before Apply**. In the same trusted preparation scope:

```powershell
# setup-example: enrollment-cutover
$legacy = Get-HLegacyInventory $target.applicationRoot
$targetKey = Get-ClcTargetKey $policy.machineIdentity $target.applicationPoolName.ToUpperInvariant()
$candidate.cutover = @{applicationRootIdentity=$legacy.rootIdentity; files=$legacy.files
    inventorySha256=(Get-DistInventoryHash $legacy.files)
    backupRoot=(Join-Path (Join-Path $policy.controlStateRoot $targetKey) ('legacy-cutover-'+$authorizationId))}
$candidate.permittedOperations += 'first-cutover'
Assert-HAuthorization $candidate $authorizationId
```

Obtain independent exact approval of this complete record. Do not approve empty/unrelated directories or invent an inventory. Apply creates/verifies the retained original backup **before** deleting inventoried legacy files; it never stops/starts/restores the pool or establishes an application baseline. See preservation below.

## 4. Independently approve and install the handoff

**Independent infrastructure approval process:** review the complete candidate, final deployment.json bytes, acquisition evidence, host/account/path/ACL/IIS observations and permitted operations. Confirm machine UUID, actual SID membership, selected toolkit identity, helper paths, TLS and maintenance scope against independent sources. `dotnetPath`/`appcmdPath` above are conventional installed paths; confirm those exact existing protected x64 files rather than resolving executables from PATH. Use `Get-Acl -LiteralPath <actual-path>` on helpers, their ancestors and protected resources to compare actual owners/writable trustees with the approved infrastructure list; resolve names using `Resolve-ClcAccountSid`. The candidate includes SYSTEM, Administrators, the resolved TrustedInstaller service SID for protected Windows components, and the actual approving account. Do not admit arbitrary observed writers to make checks pass. Approving `authoritySid` must be admitted in `infrastructureOwnerSids` and absent from `deploymentSids`; keep the list distinct and duplicate-free. Handoff/bootstrap protection still permits only SYSTEM/Administrators writers.

The reviewer supplies the actual approval/reference/window and enables only the approved record. Use strict UTF-8 JSON with the schema's exact fields. To save the **untrusted draft** without printing private facts, select an absent `$privateDraftPath` in an infrastructure-protected preparation directory **outside the target's entire Deployment tree**, as with installation staging. Extra draft files under Deployment or bootstrap would block enrollment:

```powershell
$draftBytes = [Text.UTF8Encoding]::new($false).GetBytes(($candidate | ConvertTo-Json -Depth 24))
$draftStream = [IO.File]::Open($privateDraftPath, [IO.FileMode]::CreateNew,
    [IO.FileAccess]::Write, [IO.FileShare]::None)
try { $draftStream.Write($draftBytes); $draftStream.Flush($true) }
finally { $draftStream.Dispose() }
```

This neither signs nor installs an approval. Review final bytes with `Read-HJson`/`Assert-HAuthorization` before provisioning. The toolkit has no approval-writing command.

The independently authorized infrastructure process installs the final record, with the handoff protection from step 1, at exactly:

```text
%ProgramData%\clc-<target-id>\Deployment\enrollment\authorizations\<authorizationId>.json
```

Success: protected ownership/ancestors, exact reviewed bytes and a currently enabled unexpired mutation window. Fence replacement/revocation against active execution and retain independent evidence. Inspection of an already valid target can use a durable handoff with `permittedOperations=[]`; disabled/expired mutation authority cannot Apply. Release approvals are separate and never inferred here.

## 5. Inspect, Plan, Apply and verify

**On the intended host, as the admitted deployment account with its enabled elevated Administrators token**, run the authenticated packaged bootstrap in a fresh approved PowerShell process. Set `$infrastructureAuthorizationId` to the installed record's ID, `$hostDeploymentJson` to canonical Config/deployment.json and `$independentlyApprovedToolkitZip` to the exact approved local archive.

```powershell
$state = & "$bootstrapRoot\tools\host\Get-ClcHostEnrollment.ps1" `
    -DeploymentConfigurationPath $hostDeploymentJson -AuthorizationId $infrastructureAuthorizationId
$plan = & "$bootstrapRoot\tools\host\Initialize-ClcHostEnrollment.ps1" `
    -DeploymentConfigurationPath $hostDeploymentJson -AuthorizationId $infrastructureAuthorizationId -Operation Plan
$plan | Select-Object HostState,PlannedOperations,ResourceKindsToCreate,NextAction
```

Get accepts only the two required parameters above. Initialize additionally accepts `-Operation Plan|Apply` (default Plan) and optional `-DistributionPath`; supply the archive for a first toolkit installation. Inspect/Plan are read-only. Review planned operations/resources against independent authority before proceeding; no-change Ready is not a repair request.

```powershell
# Run only after reviewing an authorized ToolkitNotInitialized/TargetNotEnrolled plan.
$result = & "$bootstrapRoot\tools\host\Initialize-ClcHostEnrollment.ps1" `
    -DeploymentConfigurationPath $hostDeploymentJson -AuthorizationId $infrastructureAuthorizationId `
    -Operation Apply -DistributionPath $independentlyApprovedToolkitZip
$verified = & "$bootstrapRoot\tools\host\Get-ClcHostEnrollment.ps1" `
    -DeploymentConfigurationPath $hostDeploymentJson -AuthorizationId $infrastructureAuthorizationId
if (-not $verified.ReadyForDeployment) { throw 'Independent reconciliation is required.' }
$verified | ConvertTo-Json -Depth 8
```

Success: `HostState=Ready`, `ReadyForDeployment=true`, target/toolkit initialized, actual pool/workers and expected active version/source. `ApplicationReleaseApproved` and `ApplicationReadinessVerified` remain **false**. See [result schema](../schemas/host-enrollment-result.schema.json). Apply failures attach safe `ErrorRecord.TargetObject` state, performed flag, pool/workers or Unknown and retained-material/operator action; input failures use stable `Clc.*` errors. Never dump configuration/raw exceptions to shared logs.

| HostState | Action |
| --- | --- |
| ToolkitNotInitialized / TargetNotEnrolled | Review and Apply only the independently authorized missing resources |
| Ready | Continue with [first separately approved application deployment](deployment.md#first-application-deployment) |
| Incomplete / DriftDetected | Preserve resources/evidence; independent reconciliation, no automatic repair |
| RecoveryRequired | Preserve state; admissible explicit deployment recovery or independent maintenance |

## Provisioning and preservation

Apply holds the target-local enrollment handle, repeats checks, persists create-new authorization intent before effects, installs exact bytes/initial policy and acquires a create-new canonical pool lock. It rechecks resources before directory effects, IIS commit and cutover; target publication is last. Failed versions, intent, locks and control entries are retained. Missing records with any prior evidence refuse even if a new configuration names another pool/machine. Valid Ready repeats do not reinitialize. There is no global registry/lock or automatic migration.

Existing sites must be Started/ServerAutoStart=true with exactly one root application/virtual directory, matching physical root and runtime SID. Pools require Integrated/No Managed Code, x64, one worker, disabled overlapping rotation, profile loading and exact runtime environment. Only an already Stopped/zero-worker pool may receive setting changes. Existing identity/root/binding replacements refuse. New pools require a preinstalled managed service account verified by NetIsServiceAccount; conventional account pools/credentials must already exist. New pools have AutoStart=false; enrollment never stops, starts or recycles a pool or invokes an application validator. Only a new empty site is registered/started; existing stopped sites require reconciliation.

HTTPS must match explicit address/readiness host/port, My-store thumbprint and SNI flag 1, with valid hostname/server-auth chain/revocation. Other binding/pool users and physical root overlaps across **all** applications/virtual directories refuse, including aliases/network/uncertain paths. Extended observations repeat at effect gates; cutover retains narrow stopped-pool checks per file. No cross-application lock or atomic coordination is claimed.

New Application/Inbox grant deployment Modify; Application gives runtime ReadAndExecute only. Keys retain infrastructure ownership and runtime Modify without WRITE_DAC/WRITE_OWNER. Protected ancestors prevent sibling replacement. Existing configuration/keys/directories are verified without ACL repair; key contents and application configuration are never created/copied/rewritten by enrollment. The application supplies its configuration loader, key policy and pool bootstrap variable; configuration/profile/key compatibility remains application-owned.

Cutover binds the complete original inventory/root and canonical control-root backup. It copies originals beneath `legacy-cutover-<authorizationId>\original` and verifies the backup/index before removing only approved identity-bound originals and known empty ancestor directories. The backup records `toolkitApprovedRelease=false`; the original root, configuration and keys remain. Unknown/changed files or unrelated empty directories refuse. Interruption preserves backup/index, intent, partial installation and actual pool state; no automatic restore or prior-version restart exists. Restoring legacy files is a separate operator-directed maintenance change using that exact backup, never RestorePrevious against a fabricated release. A later failed first deployment instead uses ordinary approved empty-baseline recovery. Never delete intent/lock/journal to retry. Unexpected reboot during later physical replacement can require manual recovery; there is no startup activation fence. File recovery never establishes database rollback safety.

## Trusted workflow integration

The normal trusted consumer workflow may invoke separately authorized enrollment and separately approved deployment; no separate initialization workflow or additional module export is needed. Workflow identity must be established by reviewed protected code before privileged use. Keep host credentials/code outside ordinary contributor PR CI. Shared routine tag orchestration does not itself provision this handoff or install/activate a toolkit. See [verified workflow integration](verified-workflow-integration.md) and [standing authorization](automated-deployments.md).

**Actual Windows Server 2022/IIS and independent-identity qualification remain NOT RUN.** Follow [IIS verification](iis-verification.md) under separate host/consumer authorization.

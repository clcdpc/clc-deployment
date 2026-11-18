# Host enrollment procedure

Infrastructure enrolls each target using [Get-ClcHostEnrollment.ps1](../tools/host/Get-ClcHostEnrollment.ps1) and [Initialize-ClcHostEnrollment.ps1](../tools/host/Initialize-ClcHostEnrollment.ps1). Release approval remains separate.

Enter from [bootstrap preparation](installation.md#initial-bootstrap-provisioning); section 1 supplies its host prerequisites. Complete sections 1–5 in order. Apply installs/activates the initial runtime toolkit from independently approved bytes; no prior runtime installation is required. **Next:** [installed-toolkit verification](installation.md#verification-and-activation), then first application deployment.

**Ordering:** collect observations first. **Inspect and Plan require independently installed protected authorization**; neither bootstraps authority.

## 1. Inspect and prepare the host

1. **Infrastructure workstation:** retain the [authenticated format-3 toolkit/source](installation.md#initial-bootstrap-provisioning), version/source/archive digest and `$reviewedSource` from bootstrap preparation. If entering here from installation step 2, continue below; do not restart acquisition. The archive cannot authenticate its verifier.
2. **Intended host, elevated PowerShell 7 x64:** confirm these externally provisioned prerequisites:

   | Prerequisite | Required state |
   | --- | --- |
   | Platform | Windows Server 2022 build 20348, x64 .NET 10/ANCM 20, IIS, protected native helpers |
   | Deployment account | Existing account with an enabled elevated Administrators token on managed IIS hosts |
   | Runtime account | Distinct nonadministrator, including indirect groups |
   | Infrastructure | Account names/SIDs, logon/profile rights, trusted HTTPS certificate/private key, DNS and routing |

   Enrollment provisions none of these prerequisites, credentials or machine trust.
3. Derive the canonical namespace with the reviewed native path logic:

```powershell
$applicationId = 'example-app'
$targetId = 'example-app-dev'
# $approvedVersion is the independently selected full toolkit version.
. "$reviewedSource\src\Clc.Deployment\Private\Contracts.ps1"
. "$reviewedSource\src\Clc.Deployment\Private\Paths.ps1"
$layout = Get-ClcTargetLayout $applicationId $targetId $approvedVersion
$targetRoot = $layout.targetRoot
$bootstrapRoot = $layout.bootstrapRoot
$hostDeploymentJson = $layout.deploymentConfigurationPath
```

Native ProgramData and the application ID fix these paths. The target ID binds the protected records within the application directory.

```text
clc-<application-id>/
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

4. Create only absent target root, `Deployment`, `Config`, and `Deployment\enrollment` with `authorizations`, `evidence` and an empty regular `enrollment.lock`. If bootstrap is not yet prepared, complete [bootstrap steps 3–6](installation.md#initial-bootstrap-provisioning), then continue below.

### Protect the handoff and configuration

- In **Properties > Security > Advanced**, set ownership to **BUILTIN\Administrators**, disable inheritance/remove inherited grants, and grant only **SYSTEM** and **BUILTIN\Administrators** FullControl. Directories apply grants to this folder, subfolders and files.
- Check every ancestor's owner and delete-child/delete/DACL/owner rights. Runtime must not replace protected children; TrustedInstaller ancestor ownership/structural rights are recognized.
- Never grant the individual deployment SID protected writes. Elevated Administrators membership provides access; independent approval against that administrator remains procedural.

Provision `Config\application.json`: infrastructure owns/writes; deployment/runtime read. Apply can create Application/Inbox/Keys; existing resources must meet [access roles](#provisioning-and-preservation). Verify actual identities' effective access, including groups. No ACL repair; logs/application-specific permissions remain external.

Before continuing, check:

- Fresh `Deployment` contains only bootstrap and enrollment; do not precreate toolkit/control/locks.
- Missing records with prior resources, intent, locks or state require independent reconciliation. Historical machine-wide and target-derived roots require separately authorized maintenance. A different target already registered in the application's catalog is a collision.
- Control roots fit 71 characters, lock roots 170, and prospective state paths 240.

## 2. Prepare Config/deployment.json

Write UTF-8 JSON at `$hostDeploymentJson` using [the strict schema](../schemas/deployment-configuration.schema.json). Replace the illustrative IDs, site/pool names, runtime account/SID and readiness hostname with independently selected values and actual host observations. Derive the paths from native ProgramData and the application ID.

```json
{
  "contractFamily": "clc-host-enrollment-v1",
  "schemaVersion": 1,
  "recordKind": "deployment-configuration",
  "applicationId": "example-app",
  "targetId": "example-app-dev",
  "environmentName": "DEV",
  "runtimeEnvironment": "Production",
  "siteName": "example-app-dev",
  "applicationPoolName": "example-app-dev",
  "applicationRoot": "C:\\ProgramData\\clc-example-app\\Application",
  "operationalConfigPath": "C:\\ProgramData\\clc-example-app\\Config\\application.json",
  "dataProtectionRoot": "C:\\ProgramData\\clc-example-app\\Keys",
  "artifactInboxRoot": "C:\\ProgramData\\clc-example-app\\Inbox",
  "runtimeIdentitySid": "S-1-5-21-1-2-3-2001",
  "runtimeAccountName": "EXAMPLE\\svc-example-app",
  "readinessUri": "https://example-app-dev.example.invalid/health/ready",
  "enrollmentRoot": "C:\\ProgramData\\clc-example-app\\Deployment"
}
```

Use application-owned IDs/readiness and infrastructure's site/pool/account. `environmentName` labels the target; runtime uses `Production` or `Staging`. Resolve the actual SID below.

Exclude operational configuration and credentials. Unknown/duplicate fields and unsupported contracts refuse. Protect final bytes before hashing; edits require a new independently approved binding.

## 3. Collect observations and prepare the candidate

1. Under infrastructure supervision, open fresh elevated `pwsh -NoLogo -NoProfile -NonInteractive` as the **selected deployment account**, using authenticated bootstrap. Readers require that caller's exact SID in prospective/current `deploymentSids`; never add the approver to bypass checks.
2. Keep observations/candidate local under infrastructure control. Exclude raw IIS environment values, snapshot digest and private configuration hashes from transcripts, CI and source.

Internal readers inspect paths/identities/IIS/TLS, including bounded certificate revocation lookup. They install/change nothing; authenticated enrollment inspection follows later.

Supply independently chosen inputs:

| Input | Source |
| --- | --- |
| `$bootstrapRoot`, `$hostDeploymentJson`, `$approvedVersion`, `$approvedSource`, `$approvedDigest` | Canonical layout and independently verified installation procedure |
| `$deploymentAccountName`, `$authorityAccountName` | Actual existing deployment and separate approving infrastructure accounts; approving SID must differ from deployment SID |
| `$bindingAddress`, `$certificateThumbprint` | Infrastructure's intended explicit local IP (for example `127.0.0.1`, never `*`) and uppercase 40-hex thumbprint from `Get-ChildItem -LiteralPath Cert:\LocalMachine\My`; select the installed valid server-auth certificate for the readiness hostname |
| `$newPoolIdentityType` | `ExistingOnly` for an existing conventional service-account pool; `ManagedServiceAccount` only for a missing pool whose managed account is already locally installed |
| `$authorizationId`, `$changeReference` | New lowercase safe authorization ID and nonsecret approved change reference, at most 64/128 characters respectively |
| `$proposedApprovedUtc`, `$proposedExpiresUtc` | Proposed UTC window from the infrastructure maintenance request, e.g. `2026-11-18T15:00:00Z` / `2026-11-18T17:00:00Z`; expiry must be later. Approver sets the actual reviewed window |

3. Run the whole block. Initial generation is 1; existing installations retain independently authenticated **complete current policy**, generation and active pin.

```powershell
# setup-example: enrollment-candidate
. "$bootstrapRoot\tools\host\HostEnrollment.Common.ps1"
$handles = [Collections.Generic.List[IDisposable]]::new()
try {
    $configurationFile = Read-ClcHeldFile $hostDeploymentJson $handles
    $configuration = Read-HJson $configurationFile.bytes
    Assert-HConfiguration $configuration
    $target = Get-HTarget $configuration
    $layout = Get-ClcTargetLayout $target.applicationId $target.targetId $approvedVersion
    Assert-ClcTargetPaths $target $layout
    if ($configuration.enrollmentRoot -cne $layout.deploymentRoot -or
        $hostDeploymentJson -cne $layout.deploymentConfigurationPath) {
        throw 'Configuration must use the canonical application paths.'
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

Check the candidate against [the authorization schema](../schemas/host-enrollment-authorization.schema.json):

| Observation | Interpretation |
| --- | --- |
| Resource binding | Native volume/file/path identity and security-descriptor digest. Null means absent, never unknown; `application.json` must exist |
| Bootstrap inventory | `Clc.Deployment/`-prefixed module entries plus all eight infrastructure files; [ordinal digest](contracts.md#package-and-trusted-ci-digest) |
| IIS snapshot digest | Reader's sorted JSON projection; never hash raw appcmd output/arbitrary JSON. Reader checks account/runtime/helpers/root isolation without pool passwords |

4. Review `$iisPlan.operations` privately; remove unneeded permissions:
   - `install-toolkit`: first installation; `enroll-target`: target publication.
   - `configure-iis`: stopped-pool settings; `create-site`/`create-pool`: missing dedicated resources.

Changed pre-state/configuration requires fresh observations/approval. Inspect/Plan repeat full checks, including effective access; preparation grants no authority.

### Optional legacy cutover

Leave `cutover=null` for ordinary enrollment. For separately authorized cutover, infrastructure fences competing writers and establishes **Stopped/zero workers before Apply**. In the same trusted preparation scope, collect the complete original inventory:

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

Independently approve the complete record; never invent inventory or include empty/unrelated directories. [Cutover](#provisioning-and-preservation) verifies backup before deletion, without pool control or baseline establishment.

## 4. Independently approve and install the handoff

1. **Independent infrastructure reviewer:** compare the complete candidate and final configuration bytes against independent evidence:

   | Check | Required evidence |
   | --- | --- |
   | Scope | Machine UUID, account/group SIDs, toolkit acquisition/identity, paths, ACLs, IIS/TLS, operations and maintenance window |
   | Helpers | Exact protected x64 `dotnetPath`/`appcmdPath`; do not resolve from PATH |
   | Ownership/access | `Get-Acl -LiteralPath <actual-path>` for helpers, ancestors and protected resources; resolve trustees with `Resolve-ClcAccountSid`. Never admit arbitrary observed writers |
   | Approver | `authoritySid` admitted in `infrastructureOwnerSids`, absent from `deploymentSids`; duplicate-free lists. Candidate includes SYSTEM, Administrators, TrustedInstaller and actual approver |
   | Handoff/bootstrap | Only SYSTEM/Administrators writers |

2. Save any **untrusted draft** at an absent `$privateDraftPath` in protected preparation storage **outside the entire Deployment tree**. Extra files under Deployment/bootstrap block enrollment:

```powershell
$draftBytes = [Text.UTF8Encoding]::new($false).GetBytes(($candidate | ConvertTo-Json -Depth 24))
$draftStream = [IO.File]::Open($privateDraftPath, [IO.FileMode]::CreateNew,
    [IO.FileAccess]::Write, [IO.FileShare]::None)
try { $draftStream.Write($draftBytes); $draftStream.Flush($true) }
finally { $draftStream.Dispose() }
```

3. Reviewer supplies reference/window, enables approved authority and validates final strict UTF-8 bytes with `Read-HJson`/`Assert-HAuthorization`. Serialization grants no authority; no toolkit approval-writing command exists.
4. The independently authorized infrastructure process installs those exact bytes with [protected ownership/ancestors](#protect-the-handoff-and-configuration) at:

```text
%ProgramData%\clc-<application-id>\Deployment\enrollment\authorizations\<authorizationId>.json
```

5. Verify ownership/ancestors, bytes and enabled unexpired mutation window. Fence replacement/revocation against execution; retain evidence. Valid-target inspection can use durable `permittedOperations=[]`; disabled/expired authority cannot Apply.

## 5. Inspect, Plan, Apply and verify

1. **Host, fresh elevated admitted deployment process:** set `$infrastructureAuthorizationId` to the installed ID and `$independentlyApprovedToolkitZip` to the approved local archive. Inspect and Plan using the authenticated bootstrap:

```powershell
$state = & "$bootstrapRoot\tools\host\Get-ClcHostEnrollment.ps1" `
    -DeploymentConfigurationPath $hostDeploymentJson -AuthorizationId $infrastructureAuthorizationId
$plan = & "$bootstrapRoot\tools\host\Initialize-ClcHostEnrollment.ps1" `
    -DeploymentConfigurationPath $hostDeploymentJson -AuthorizationId $infrastructureAuthorizationId -Operation Plan
$plan | Select-Object HostState,PlannedOperations,ResourceKindsToCreate,NextAction
```

Get accepts only those two required parameters. Initialize adds `-Operation Plan|Apply` (default Plan) and optional `-DistributionPath`. Inspect/Plan are read-only.

2. Review operations/resources against independent authority. Apply only an authorized missing-resource plan, supplying the archive for first installation; no-change Ready needs no repair. Then inspect again:

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

3. Verify `HostState=Ready`, `ReadyForDeployment=true`, active version/source and actual pool/workers. `ApplicationReleaseApproved` and `ApplicationReadinessVerified` remain **false**; see [result schema](../schemas/host-enrollment-result.schema.json).

On failure, inspect safe `ErrorRecord.TargetObject` state/actions, performed flag, pool/workers or Unknown and retained material. Input failures use stable `Clc.*` errors. Never publish configuration/raw exceptions.

| HostState | Action |
| --- | --- |
| ToolkitNotInitialized / TargetNotEnrolled | Review and Apply only the independently authorized missing resources |
| Ready | Next: [verify installed toolkit](installation.md#verification-and-activation), then first separately approved application deployment |
| Incomplete / DriftDetected | Preserve resources/evidence; independent reconciliation, no automatic repair |
| RecoveryRequired | Preserve state; admissible explicit deployment recovery or independent maintenance |

## Provisioning and preservation

Apply's guarantees:

- Target-local enrollment handle and canonical pool lock; create-new intent before effects; repeated checks before directory/IIS/cutover effects; target publication last.
- Failed versions, intent, locks and control entries remain. Missing records with prior evidence refuse, including changed pool/machine configurations. Ready repeats never reinitialize. No global registry/lock or automatic migration.

| Resource | Required behavior |
| --- | --- |
| Existing site | Started, ServerAutoStart=true, exactly one root application/virtual directory, matching physical root/runtime SID. Stopped sites need reconciliation |
| Pool | Integrated/No Managed Code, x64, one worker, no overlapping rotation, profile loading, exact runtime environment. Settings change only while Stopped/zero workers; identity/root/binding replacements refuse |
| New pool | Preinstalled managed service account verified by NetIsServiceAccount; AutoStart=false. Conventional-account pools/credentials must already exist |
| IIS effects | No pool stop/start/recycle or application validation. Only new empty sites are registered/started |
| HTTPS/isolation | Explicit address/host/port, My-store certificate, SNI=1, valid hostname/server-auth chain/revocation. Reject other binding/pool users and overlapping roots across all applications/virtual directories, including alias/network/uncertain paths |
| Application/Inbox | Deployment Modify; Application runtime ReadAndExecute only |
| Keys | Infrastructure ownership, runtime Modify without WRITE_DAC/WRITE_OWNER; protected ancestors prevent sibling replacement |

Existing configuration/keys/directories are verified without repair. Enrollment never creates/copies/rewrites configuration or key contents. Application owners supply the configuration loader, key policy and pool bootstrap variable and qualify configuration/profile/key compatibility. Effect-gate observations and per-file cutover stopped checks provide no cross-application atomic coordination.

For cutover:

1. Copy exact identity-bound originals to the canonical control-root `legacy-cutover-<authorizationId>\original`; verify backup/index before deletion.
2. Remove only approved originals and known empty ancestors. Preserve root/configuration/keys; reject changed/unknown files and unrelated empty directories. Backup records `toolkitApprovedRelease=false`.
3. On interruption, preserve backup/index, intent, partial installation and pool observations. Never delete intent/lock/journal to retry; no automatic restore/restart occurs.
4. Restore legacy files only through separately authorized maintenance using that backup, never a fabricated `RestorePrevious` release. Later failed first deployment uses approved empty-baseline recovery.

Unexpected reboot during later replacement may require manual recovery; no startup activation fence exists. File recovery never proves database rollback safety.

## Trusted workflow integration

Trusted workflows may invoke independently authorized enrollment/deployment after protected code establishes identity. Keep privileged credentials/code outside contributor PR CI. Shared tag orchestration does not provision handoff/toolkits; see [workflow integration](verified-workflow-integration.md) and [standing authorization](automated-deployments.md).

**Actual Windows Server 2022/IIS and independent-identity qualification remain NOT RUN.** Follow [IIS verification](iis-verification.md) under separate host/consumer authorization.

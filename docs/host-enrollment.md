# Authorized host enrollment and trusted workflow integration

Start with the [Deployment Setup Guide](setup-guide.md) for end-to-end target configuration. This runbook defines the exact enrollment trust, authorization and provisioning procedures.

The optional [GitHub setup checker](github-setup-check.md) inspects GitHub settings only. Use this document's Get/Plan procedures for separately scoped host observations; GitHub configuration results establish no enrollment state or application acceptance.

This is infrastructure tooling for elevated V1 deployment. Offline tests do not qualify a real IIS host or consumer deployment. The four public deployment commands, release approvals, deployment journal, explicit recovery and deadlines remain in force. The normal trusted consumer workflow may perform missing authorized setup; there is no separate initialization workflow.

## Trust and prerequisites

Infrastructure independently authenticates the reviewed source, producer and exact toolkit distribution before **any bootstrap code executes**. Obtain the verifier/bootstrap through an already trusted channel; verify the whole format-3 inventory, extract to an infrastructure-owned protected bootstrap directory and pin its exact source/inventory in the authorization. The bootstrap includes `Clc.Deployment/`, `tools/`, `source.commit` and retained `distribution.zip`. Never execute an arbitrary checkout or obtain a verifier from an unauthenticated archive to authenticate itself. Source-checkout layout is refused. The already trusted bootstrap pins executable/source/archive read streams against write/delete and checks the independently approved inventory/source before further use. These drift checks cannot authenticate their own first execution.

The intended Server 2022 x64 IIS host must already have PowerShell 7, x64 .NET 10/ANCM 20, protected installed IIS/.NET helpers, existing runtime accounts, required logon/profile rights, operational application configuration, a valid trusted HTTPS certificate/private key and DNS/network routing. Accounts, passwords, components, certificates, machine trust and application-specific bootstrap variables are infrastructure prerequisites, never deployment inputs or enrollment side effects. Existing pool credentials are neither read nor changed.

The authorized deployment account must have its exact admitted SID and an enabled elevated Administrators token. New infrastructure resources are owned by BUILTIN\Administrators and grant FullControl only to approved infrastructure SIDs (including SYSTEM/Administrators). No individual deployment SID gets protected-resource write ACEs. Administrative inheritance provides the required elevated access. Independent approval remains procedural against that administrator; NTFS and hashes cannot contain it. Runtime remains distinct, nonadministrator including indirect groups, and effectively unable to write/replace protected resources.

Infrastructure provisions each target's independent approval handoff, with SYSTEM/Administrators ownership/writers and protected ancestors:

```text
%ProgramData%\clc-<target-id>\Deployment\enrollment\authorizations\<authorizationId>.json
%ProgramData%\clc-<target-id>\Deployment\enrollment\enrollment.lock
%ProgramData%\clc-<target-id>\Deployment\enrollment\evidence\
```

The empty lock file and evidence directory belong to this approval handoff, not a target initialization workflow. The scripts cannot redirect that handoff. Authorizations are written/revoked by the independent infrastructure procedure; the tooling provides no approval-writing command. Revocation/replacement is fenced against active execution and retained in infrastructure evidence. An administrator can bypass the procedure; no stronger boundary is claimed.

Every authenticated target has its own fixed installation:

```text
%ProgramData%\clc-<target-id>\Deployment\toolkit\versions\<version>\...
%ProgramData%\clc-<target-id>\Deployment\toolkit\policy\host-policy.json
%ProgramData%\clc-<target-id>\Deployment\toolkit\policy\targets\<targetId>.json
%ProgramData%\clc-<target-id>\Deployment\toolkit\policy\approvals\<approvalId>.json
%ProgramData%\clc-<target-id>\Deployment\locks\<machine-pool-key>.lock
%ProgramData%\clc-<target-id>\Deployment\control\<machine-pool-key>\...
```

`enrollmentRoot` retains its v1 field shape and must exactly equal the target's derived `Deployment` directory. The initial held configuration parse supplies only a validated target selector. Native Windows known-folder resolution derives ProgramData, then protected local approval binds the exact held configuration bytes, target, bootstrap and policy before mutation. Environment variables, JSON paths, the executing module location and workflow inputs cannot choose another namespace.

`Application`, `Config/application.json`, `Config/deployment.json`, `Keys`, `Inbox` and optional application-owned `Logs` are siblings of protected `Deployment` beneath `%ProgramData%\clc-<target-id>`. Application/configuration/key/inbox paths and the supplied DeploymentConfigurationPath must match these exact canonical locations. Infrastructure must protect the target root against runtime modification, deletion, renaming and replacement. Parents of new resources already exist with safe protection.

The local catalog contains only its selected target. Actual IIS configuration supplies site/pool/binding conflicts; enrollment never scans other targets' ProgramData directories. The bootstrap must execute from that target's exact `Deployment/bootstrap`, containing only `Clc.Deployment`, `tools`, `source.commit` and `distribution.zip` with independently approved executable inventory. Preprovisioned bootstrap and enrollment handoff are expected fresh contents; toolkit, control, locks, prior intent or unknown entries still require reconciliation.

Old machine-wide installations are never adopted, moved or deleted automatically. Independently authorize re-enrollment or migration and retain all relevant release/recovery evidence. There is no fallback to the old policy.

## Host-local deployment.json

Use [the strict schema](../schemas/deployment-configuration.schema.json). This is nonsecret host-local workflow input, outside release packages. The application owns operational configuration semantics. The protected target remains authoritative after enrollment; discrepancies fail and do not rewrite it.

The example uses synthetic placeholders and grants no authority:

```json
{
  "contractFamily": "clc-host-enrollment-v1",
  "schemaVersion": 1,
  "recordKind": "deployment-configuration",
  "applicationId": "example-app",
  "targetId": "example-app-dev",
  "environmentName": "DEV",
  "runtimeEnvironment": "Production",
  "siteName": "ExampleApplication",
  "applicationPoolName": "ExampleApplication",
  "applicationRoot": "C:\\ProgramData\\clc-example-app-dev\\Application",
  "operationalConfigPath": "C:\\ProgramData\\clc-example-app-dev\\Config\\application.json",
  "dataProtectionRoot": "C:\\ProgramData\\clc-example-app-dev\\Keys",
  "artifactInboxRoot": "C:\\ProgramData\\clc-example-app-dev\\Inbox",
  "runtimeIdentitySid": "S-1-5-21-1-2-3-2001",
  "runtimeAccountName": "EXAMPLE\\svc-example-app",
  "readinessUri": "https://example-app.example.invalid/health/ready",
  "enrollmentRoot": "C:\\ProgramData\\clc-example-app-dev\\Deployment"
}
```

The application owns the meaning and layout of its operational configuration; this host-local record binds only the path consumed by the approved application validator. Runtime account name is resolved to the independently expected SID and checked against the actual pool. Machine UUID, native physical identities and installed helper/runtime facts are discovered. `environmentName` is an operator label; `runtimeEnvironment` is restricted to `Production` or `Staging`. Reject unknown fields, credentials, connection strings, key material, approval authority, duplicate keys and unsupported contracts. Configuration values/bytes/private hashes and raw native exceptions are never returned.

## Independent initialization authorization

Supply only `-AuthorizationId`; it resolves the exact protected `<id>.json`. The [strict authorization schema](../schemas/host-enrollment-authorization.schema.json) defines:

| Field | Independent binding |
| --- | --- |
| Common family/version/kind | `clc-host-enrollment-v1` / `1` / `host-enrollment-authorization` |
| authorizationId, targetId | Exact safe selectors |
| enabled, approvedUtc, expiresUtc | Enabled finite UTC approval window; no auto-enable or refresh |
| authoritySid, reference | Separate admitted infrastructure SID and nonsecret change reference; audit data is not authentication by itself |
| deploymentConfigurationSha256, enrollmentRoot | Exact reviewed deployment.json bytes and fixed installation |
| hostPolicy | Complete existing v1 host-policy, including actual machine UUID, full active toolkit identity, generation, fixed paths/helpers and infrastructure/deployment SID allowlists |
| bootstrap | Exact `sourceCommit` and `inventorySha256` of the independently authenticated executable bootstrap |
| permittedOperations | Explicit subset of install-toolkit, enroll-target, configure-iis, create-site, create-pool, first-cutover |
| iis | Exact bindingAddress, certificateThumbprint (uppercase SHA-1 store selector), newPoolIdentityType, expectedSnapshotSha256 |
| resourceBindings | applicationRoot, operationalConfigPath, dataProtectionRoot and artifactInboxRoot: null only if genuinely absent; otherwise exact native volumeId/fileId/canonicalPath/securityDescriptorSha256 |
| cutover | null, or exact applicationRootIdentity, complete ordinal files array, inventorySha256 and new canonical control-root legacy backup |

Bootstrap inventory uses the distribution's module files with `Clc.Deployment/` prefixes plus all eight `tools/` files, sorted ordinally using the existing path/NUL/length/NUL/SHA-256/LF digest. `source.commit` must match bootstrap.sourceCommit. The external acquisition procedure proves which source produced those bytes. Use trusted `Get-HBootstrapInventory`, `Get-HResourceBinding` and `Get-HIisSnapshot` helpers for read-only observations on the operator's reviewed bootstrap when assembling the handoff; observations grant no authority. Infrastructure independently reviews and publishes the resulting exact authorization. Use `Get-HIisSnapshotHash (Get-HIisSnapshot $session)` for the approved pre-state; it hashes an explicit ordered projection and sorted arrays as UTF-8 SHA-256, independently of hashtable property order. Its stable selected projection includes site/root/pool association, pool settings/state/workers, relevant environment and bindings; it never reads a pool password. Do not log that projection, environment values or the private snapshot digest; an unkeyed digest can reveal guesses about low-entropy values.

For existing resources, approval binds their physical/ACL pre-state. Existing invalid owners/permissions are refused; there is no recursive repair option. The initial host-policy's toolkit version/source/archive/module-inventory identity is independently approved, never copied from adjacent artifact metadata as authority. Apply on an initialized target must match its complete current policy, including generation and active pin. New target-local enrollment requires format 3. Historical format-1/2 archives remain inspectable with their original CLC.Deployment names and inventories; they do not initialize the new architecture. An available different distribution does not authorize an upgrade.

Get/Plan also require a durable infrastructure inspection handoff. An existing installation can receive one with an empty permittedOperations array. Setup expiry/revocation prevents mutation, while inspection of an already valid target remains useful. Subsequent release approvals are entirely separate and are never written, enabled or inferred here.

## Inspection, planning and apply

Run the independently authenticated packaged bootstrap in a fresh approved `pwsh -NoLogo -NoProfile -NonInteractive` process:

```powershell
$state = & "$trustedBootstrap\tools\host\Get-ClcHostEnrollment.ps1" `
    -DeploymentConfigurationPath $hostDeploymentJson -AuthorizationId $infrastructureAuthorizationId
$plan = & "$trustedBootstrap\tools\host\Initialize-ClcHostEnrollment.ps1" `
    -DeploymentConfigurationPath $hostDeploymentJson -AuthorizationId $infrastructureAuthorizationId -Operation Plan
if ($state.HostState -in @('ToolkitNotInitialized','TargetNotEnrolled')) {
    $result = & "$trustedBootstrap\tools\host\Initialize-ClcHostEnrollment.ps1" `
        -DeploymentConfigurationPath $hostDeploymentJson -AuthorizationId $infrastructureAuthorizationId `
        -Operation Apply -DistributionPath $independentlyApprovedToolkitZip
}
$verified = & "$trustedBootstrap\tools\host\Get-ClcHostEnrollment.ps1" `
    -DeploymentConfigurationPath $hostDeploymentJson -AuthorizationId $infrastructureAuthorizationId
if (-not $verified.ReadyForDeployment) { throw 'Enrollment requires independent operator reconciliation.' }
$verified | ConvertTo-Json -Depth 8 -Compress
```

Inspect/Plan perform reads only. Apply may provision only the exact approved missing resources. It takes the target-local enrollment handle, repeats inspection, verifies exact distribution inventory before extraction, persists a create-new immutable authorization intent, installs/protects one immutable version, creates/protects catalog/control/lock roots and activates the exact host policy. It then acquires a **create-new canonical per-pool deployment lock**, repeats collision/resource checks, creates missing external directories, applies approved IIS operations, performs approved cutover if needed, verifies the complete target with existing v1 contract/host helpers and publishes the target record create-new **last**. Failed extraction/initialization is retained, never overwritten or automatically repaired.

The intent is protected infrastructure audit/recovery evidence that consumes one authorization before effects. It is not a second deployment journal, completion marker or readiness authority. When the target is absent, any retained local intent, lock or control entry requires reconciliation, including evidence naming a previous pool or machine. Changing the exact configuration or authorization cannot make that namespace fresh. Missing policy with partial resources also blocks initialization. Reconciliation is an independent fenced maintenance change preserving evidence. A fully valid target is established exclusively by its protected policy/target and complete live verification; historical intent does not cause needless repeat setup.

| HostState | Meaning and next permitted action |
| --- | --- |
| ToolkitNotInitialized | No toolkit/control/lock/prior-operation evidence; approved initial resources verified. Plan independent first installation/enrollment |
| TargetNotEnrolled | Valid active target-local installation; no selected target or prior pool evidence. Plan independently authorized target enrollment |
| Ready | Protected records, exact installed bytes/pin, target/config, actual IIS/filesystem/security and existing deployment-state reconciliation verify. Continue with separately approved release |
| Incomplete | Missing policy with partial installation/unexpected enrollment contents. Retain and reconcile |
| DriftDetected | Invalid contract, mismatched config/SID/path/ACL/IIS/certificate or conflicting target. Refuse repair; reconcile |
| RecoveryRequired | Missing target with prior lock/control/intent or unresolved existing deployment state. Use existing explicit recovery where admissible; otherwise independent maintenance |

Input/authorization failures terminate with stable `Clc.*` codes. Apply errors attach safe structured `ErrorRecord.TargetObject` fields (authorization/target ID, performed flag, ReadyForDeployment=false, observed pool/workers or Unknown, and retention/reconciliation action); no exception or configuration dump is returned. Successful reads return structured [results](../schemas/host-enrollment-result.schema.json): state/code/action, toolkit/target/performed booleans, active version/source, target ID, ReadyForDeployment, RequiresOperatorIntervention, actual pool/workers, PlannedOperations and ResourceKindsToCreate. `ApplicationReleaseApproved=false` and `ApplicationReadinessVerified=false` always: enrollment readiness is not application readiness.

## Provisioning and preservation

Reuse a valid existing dedicated site/pool. It must be Started with ServerAutoStart=true and have exactly one root application/virtual directory, matching physical root and runtime SID, Integrated/No Managed Code, x64, one worker, disabled overlap, profile loading and the exact runtime environment. The readiness hostname must be a DNS name. TLS must match the approved hostname/address/port, My-store thumbprint and SNI flag; certificate validity, SAN hostname, server-auth chain and revocation checks must pass. Conflicting bindings, other pool users or missing runtime/ANCM refuse. Every workflow inspection also checks bounded actual-IIS physical roots of all applications and virtual directories, including other sites/pools. Exact, ancestor, descendant or physical-identity overlap with the selected Application tree refuses, without modifying or retaining handles to other applications. Unknown/network/unsafe alias paths fail closed; supported path tokens use native Windows/known-folder facts. Full observations repeat before directory effects, IIS commit and cutover phases; per-file cutover checks remain selected-pool Stopped/zero-worker observations. Every workflow inspection repeats these extended checks; the unchanged public target contract does not itself add a certificate pin.

Only an already stopped/zero-worker pool may receive approved setting changes, bound to the exact observed IIS pre-state. Existing root/identity/binding replacements are refused. A missing site can be created against a stopped dedicated pool. A missing pool requires `newPoolIdentityType=ManagedServiceAccount` and a preexisting locally installed managed account verified through [NetIsServiceAccount](https://learn.microsoft.com/en-us/windows/win32/api/lmaccess/nf-lmaccess-netisserviceaccount), SID and group/access checks. Conventional service-account pools must already have their credentials configured by infrastructure. Newly created pools have AutoStart=false; enrollment never starts/recycles/stops an application pool or executes an application validator. Existing stopped sites require infrastructure reconciliation; only a new empty site is registered/started.

New app/inbox roots allow deployment Modify; app runtime receives ReadAndExecute and no writes. New key roots retain infrastructure ownership and runtime Modify without WRITE_DAC/WRITE_OWNER; protected ancestors must prevent replacement. New toolkit/policy/catalog/control/lock roots have infrastructure administrative ACLs. Existing directories/configuration/keys are inspected without ACL changes. Keys are never created, deleted, exported, encrypted or rewritten. Existing configuration bytes and key/profile/account compatibility are retained. The app must supply its own configuration loader/key policy and pool bootstrap variable.

Local approvals retain the existing standing, hooks and recovery subdirectories, strictly parsed and bound to the selected target. Every target installs and pins its own toolkit, policy, approvals and state. DEV and Production can pin different versions on the same server. Actual IIS site/pool/binding conflicts fail host observations. There is no shared registry, directory scan or cross-target lock. Existing versions, approvals, releases, keys and journals remain retained; no automatic cleanup is provided.

## First cutover and failure handling

Legacy content requires a distinct `first-cutover` operation and exact approved physical root plus complete legacy path/length/SHA-256 inventory. Its `backupRoot` must equal `Deployment/control/<targetKey>/legacy-cutover-<authorizationId>`; this retained enrollment backup is separate from approved application-release backups. Unknown files, empty unrelated directories, hard links, streams, reparses or unsafe ownership fail. Operators fence conflicting IIS/config/writer changes and independently stop the selected pool, establishing zero workers **before** Apply. An ordinary repeat-deployment approval cannot authorize cutover.

Under both locks and held root identities, enrollment copies the exact original inventory into the new protected `control/<targetKey>/legacy-cutover-<authorizationId>/original`, verifies every retained byte and publishes a backup index binding the approval and original root. Only after the complete backup verifies does it remove exact identity-bound approved originals and known empty ancestor directories. It preserves the original root, external configuration and keys, checks stopped/zero workers before every deletion and verifies an empty managed root before final target publication. The backup explicitly records `toolkitApprovedRelease=false`.

Failure retains backup/index, authorization intent, partial installation and actual stopped state; it never restores/deletes the prior backup or restarts code. If first deployment later fails, use ordinary recovery for its approved empty baseline. Restoring original legacy files is a separate operator-directed maintenance change using the retained exact backup, not RestorePrevious to a fabricated approved release. Unknown/partial evidence requires operator intervention; deleting an intent/lock/journal is never a retry procedure.

## Consumer workflow and remaining gates

Optional [standing release admission](automated-deployments.md) is a separate infrastructure policy installed after a successful independently approved baseline. Enrollment never creates that policy or release approvals. Standing authority cannot authorize first cutover, empty-target deployment, setup or toolkit upgrades.

Any consumer workflow must use independently authenticated enrollment tooling and the installed toolkit, recheck its target and approvals, and retain application-specific prerequisites in its own repository. `ReadyForDeployment` alone does not establish an enabled application release; `Invoke-ClcIisDeployment` resolves and rechecks its independent approval before execution. The optional automation contract defines shared tag/verified-package admission, while application-specific workflow controls and readiness requirements remain consumer-owned and unqualified here.

Do not run privileged code from arbitrary PR checkouts, use pull_request_target to execute contributors, attach deployment credentials to ordinary CI, deploy on clc-linux, treat a triggering artifact as release authority or add a privileged deployment job to this repository's verification workflow. Build/release production remains separate from the privileged host path. Automatic release admission requires trusted workflow verification and an independently installed standing policy as described above.

Toolkit upgrades require an explicit independent version-install/activation/compatibility procedure preserving old versions and all recovery evidence. The initializer never changes an active pin. Follow the [rollout order and real-IIS procedure](iis-verification.md#rollout-order) for separately authorized adoption and qualification. Real-IIS evidence remains NOT RUN; stable version support and offline tests do not establish production qualification.

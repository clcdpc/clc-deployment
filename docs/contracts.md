# Public and persistent contracts

The [schemas](../schemas) and `Private/Contracts.ps1` define exact fields/types/bounds. The current phase journal replaces the former per-file ownership/retirement protocol. No operational state is automatically migrated.

## Four commands

```powershell
New-ClcRelease -PublishRoot <publish-directory> -MetadataPath <release-metadata.json> -OutputPath <new-release.zip>
Test-ClcRelease -ArchivePath <release.zip>
Invoke-ClcIisDeployment -TargetId <safe-id> -ReleaseApprovalId <safe-id> [-AllowDowngrade -Reason <change-id>]
Restore-ClcIisDeployment -TargetId <safe-id> -AttemptId <latest-guid> -Mode RestorePrevious|AcceptCandidate|RestoreEmpty -Reason <change-id>
```

These are the only exports. Paths use literal semantics; IDs match lowercase `[a-z0-9][a-z0-9-]{0,63}`. Reason is a nonsecret lowercase safe ID of at most 128 characters, required with AllowDowngrade and rejected otherwise. Restore requires a nonempty GUID. No credentials, callbacks, policy overrides, caller journal paths, approval objects or trust-bypass flags are accepted.

| Command | Result/effects |
| --- | --- |
| New | Published files/metadata -> deterministic inventoried ZIP. Returns contractFamily/packageContractVersion/releaseId/archivePath/archiveSha256/manifestSha256/inventorySha256/fileCount/totalBytes/builderVersion. No build/approval/payload execution |
| Test | Full ZIP/manifest/file verification without extraction. Returns integrityVerified=true, authorizedForDeployment=false and application/release/source/hash/count/builder identity. Invalid input throws; inspection never authorizes Invoke |
| Invoke | Protected authority, canonical lock, preflight, installed validation/fresh readiness for NoOp; otherwise stage/validation/stop/backup/copy/start/readiness/current. Returns Deployed/NoOp, attemptId/targetId/releaseId/sourceCommit/executingToolkit/currentGeneration/observedPoolState/workerCount |
| Restore | Same trust/lock and latest attempt. Returns RestoredPrevious/AcceptedCandidate/RestoredEmpty, attemptId/recoverySequence/releaseId/executingToolkit/currentGeneration/observedPoolState/workerCount. Empty remains stopped with no ready current |

Errors terminate with stable `Clc.*` IDs and safe attempt/pool/worker/retained-path/operator-action information. No secret/private configuration hash/raw native output is returned. Partial work or failed persistence cannot return success.

## Format and bounds

UTF-8 JSON rejects duplicate/case-ambiguous keys, unknown/missing fields, coercion, comments, nonintegral numbers, unsupported versions and trailing data. Required fields are nonnull except explicit nullable fields. IDs/hashes/GUIDs/source commits/timestamps are canonical. Shapes do not confer authority.

Package/metadata/policy/target/approval/current/backup retain `contractFamily=clc-file-iis-v1`, schemaVersion 1 and their exact recordKind. The simplified `journal` uses schemaVersion **2**; v1 journals and per-file ownership records are unsupported. Application validation/readiness retain their own integer contractVersion fields. Infrastructure enrollment retains its separate `clc-host-enrollment-v1`/1 contracts.

Records/manifest/metadata: 4 MiB; ZIP compressed/expanded: 1 GiB; entries: 20,000; individual file: 256 MiB; expansion: 100:1; relative/full paths: 240 characters. Enforce actual streamed lengths. Lock fails fast. Helpers: 30 seconds; stop/start: 60 each; readiness: 120 overall/5 per request/2-second poll; archive/stage/backup/replace: 300 each. Synchronous OS calls can return late, after which further effects/success refuse.

## Package and trusted CI digest

The ZIP contains only `manifest.json` and the complete `application/` tree, including safe web.config. Metadata identifies applicationId/releaseId, source repository/full commit, build workflow/run/attempt/job/sdk/dependency lock, builder module/version/source/distribution, runtime framework/rid/architecture/hostingModel/workerLimit, changeKind=files-only, fixed validation entryPoint/contractVersion and readinessContractVersion=1. Manifest adds ordinal-sorted `{path,length,sha256}` files and inventorySha256.

Inventory SHA-256 covers UTF-8 `path + NUL + invariant-length + NUL + lowercase-hash + LF`, sorted ordinally, without BOM. Manifest digest covers exact UTF-8 bytes; final ZIP digest covers the entire archive. New returns the final SHA-256 for CI to publish with build provenance. The protected approval supplies deployment's trusted expected digest. Calculate/compare the downloaded ZIP once per invocation, never in file-copy loops.

Reject traversal/absolute/UNC/device/drive/ADS paths, backslashes, reserved DOS names, trailing dots/spaces, ambiguous Unicode/case, collisions, symlinks/reparse/special attributes, encryption, unsupported compression and bound violations. Inspect raw ZIP structure and full inventory before create-new safe extraction. Reject unexpected files/unrelated empty directories and verify staged hashes. Runtime cannot write staging.

web.config is in-process ANCM `dotnet` with only the declared relative DLL, stdout disabled, no credentials/environment overrides/arbitrary arguments. Exclude scripts/toolkit, operational configuration, development/test settings and keys/certificates. Application builds additionally own secret/content semantics.

## Existing protected authority and preflight

Host policy keeps generation/machineIdentity/activeToolkit/targetCatalogRoot/approvalCatalogRoot/controlStateRoot/lockRoot/dotnetPath/appcmdPath/infrastructureOwnerSids/deploymentSids. Active toolkit pins exact version/source/distribution/module inventory/installed manifest. Infrastructure authenticates first import and installed Windows/.NET/IIS; no runtime-loader authentication framework is introduced.

Target keeps targetId/applicationId/environmentName/runtimeEnvironment/siteName/applicationPoolName/applicationRoot/operationalConfigPath/dataProtectionRoot/artifactInboxRoot/runtimeIdentitySid/readinessUri. Roots are disjoint existing canonical local NTFS objects; mutable OS directories, aliases/reparse/hard links/named streams refuse. Configuration is an external protected regular file. Runtime is a distinct nonadministrator with effective protected-resource write isolation. Deployment requires its authorized SID and enabled elevated administrator token. Independent approval against that administrator is procedural.

Release approval keeps approvalId/targetId/enabled/applicationId/releaseId/sourceRepository/sourceCommit/lineageId/releaseSequence/releaseZipSha256/manifestSha256/provenance/authorization. Provenance binds workflowPath/runId/runAttempt/buildJob/artifactId/transportSha256; authorization binds authoritySid/reference/approvedUtc. Select only exact `<approvalId>.zip` from the target inbox and match approved ZIP/manifest/source/build facts. Downgrade/incomparable lineage requires AllowDowngrade/reason; same sequence with different artifact identity rejects.

Comprehensive preflight checks dedicated sole IIS root application/site/pool, physical root/runtime SID, max one worker, disabled overlap, x64 .NET/ANCM, environment, actual HTTPS binding and required path/access observations. Started with zero/one workers permits idle preflight. Backup/replacement requires Stopped/zero workers; ready success requires Started/exactly one worker. Inner copy operations check affected paths and current stopped state, without full host scans.

## Application-owned validation/configuration/readiness

The fixed approved DLL receives `--validate-deployment --configuration-path <file> --data-protection-root <keys> --environment Production|Staging` through installed dotnet, with cleared environment and bounded output/time. Approved validation executes elevated without sandboxing. Strict response fields: validationContractVersion=1, valid, applicationId, releaseId, sourceCommit, runtimeEnvironment, configurationRevision, keyStoreCompatibilityId, errorCodes. `configurationRevision` uses the version-1 safe-code grammar with a 64-character maximum; `keyStoreCompatibilityId` uses that same grammar with the existing 128-character maximum.

Hold/hash configuration privately for the attempt; never copy/log it. Changed bytes under the same successful revision reject. A new revision requires restart even for identical release bytes. Candidate/previous validators must agree on current configuration/key compatibility. Mid-attempt drift aborts; key contents may evolve outside replacement.

An exact current release with unchanged configuration and host observations validates the approved installed inventory and application, then performs fresh readiness before recording NoOp. NoOp creates no staging directory, backup or application-file changes and preserves current.json bytes/generation while saving its completed journal/attempt snapshot. Changed release/configuration or failed NoOp readiness proceeds through normal staging and validation.

Readiness is anonymous HTTPS GET `/health/ready`, normal TLS, no redirect/cookie/auth forwarding, JSON <=4 KiB, Cache-Control:no-store. Exact fields: readinessContractVersion=1, status=ready, applicationId, releaseId, sourceCommit, runtimeEnvironment, configurationRevision. Match every expected field; generic 200, stale/wrong identity, TLS failures and malformed/extra/private fields fail.

## Canonical lock and phase state

Canonical machine identity is the local nonzero/non-all-ones SMBIOS UUID matching enrollment. Match one actual ASCII IIS pool and uppercase its name. targetKey is SHA-256 of UTF-8 `machineIdentity + NUL + uppercase-pool`. Lock/state derive from it independent of TargetId/release. One noninheritable FileShare.None handle stays with the mutator. Released handles after crashes never imply completion.

```text
controlStateRoot/<targetKey>/
  journal.json; current.json
  attempts/<attempt>/deployment.json
  attempts/<attempt>/before-recovery-<sequence>.json
  attempts/<attempt>/recovery-<sequence>.json
  staging/<attempt>/application/...
  backups/<attempt>/index.json; application/...
  releases/<approvalId>.json       # exact approval-pinned manifest
```

Journal records attempt/target/root snapshots, executing toolkit/policy, candidate/previous release/configuration, initial pool/empty baseline, phase/outcome, sticky live intent, coarse intent/observation, nativeCall, verified backup, optional recovery choice/sequence/reason, prospective published generation, timestamps and safe failure. Intent operations: Stage/Validate/Stop/Backup/Replace/Start/CheckReady/PublishCurrent/Complete. Phases: Prepared/Mutating/RecoveryRequired/Completed. No per-file path/ownership log. Any unresolved phase blocks ordinary Invoke.

Native launch records retain callId/operation/Intent|Started|Exited/processId/exact creationUtc/exitCode. Prove the exact helper exited before recovery. Unknown launch identity refuses, with no reboot inference/quiescence override.

Current retains generation/target/root/attempt/recoverySequence, approval/release, executingToolkit, private validated configuration, stable host digest, readiness and completedUtc. It records last readiness, never present health. NoOp freshly verifies full live inventory, unchanged config/host and expected-release readiness without rewriting application/current.

Backup index retains attemptId/targetKey/priorEmpty/priorApprovalId/priorManifestSha256/files/inventorySha256. Verify backup bytes before recording verified and before recovery. Empty means no files. Ordinary upgrades/recovery consume the approval-pinned retained manifest and selected backup, without historical ZIP verification or unrelated history scans.

State writes create a same-directory temporary, flush, rename and reopen/verify. Leftover unknown temporary files block admission. Success order: readiness/final hashes -> prospective generation intent -> current -> matching Completed journal/create-new terminal snapshot -> final authority observation. Failures retain evidence. Recovery retains a before-recovery snapshot. RestoreEmpty preserves matching uncommitted current before removal; interrupted retirement can require manual maintenance.

**An unexpected OS reboot during physical replacement may require manual recovery.** Pending state does not prevent WAS activation. No startup interception or filesystem transaction engine is implemented. [Deployment and recovery](deployment.md) defines failure behavior.

Infrastructure Get/Plan stay read-only; Apply retains existing fixed enrollment and exact independent machine/config/bootstrap/toolkit/operation authority. Only dedicated directories/ACLs/stopped IIS settings may be provisioned. Accounts/secrets/certificates/trust/components stay external. Cutover requires Stopped/zero workers and verified independently approved original backup. Missing records with prior resources/locks/state require reconciliation. See [enrollment](host-enrollment.md).

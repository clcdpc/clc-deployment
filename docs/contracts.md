# Public and persistent contracts

The [schemas](../schemas) and `Private/Contracts.ps1` define exact fields/types/bounds. The current phase journal replaces the former per-file ownership/retirement protocol. No operational state is automatically migrated.

Compatibility evidence is version-specific. Published MIT `v0.1.0-beta.3` points to [a3a94cd](https://github.com/clcdpc/clc-deployment/tree/a3a94cd26daa583d392f73e99e56872876a88467), with four exact-approval/file-only commands and journal2. The base for this change is [master at 7f814ef](https://github.com/clcdpc/clc-deployment/tree/7f814ef838abcfd12ade494c429918657598c35d), which additionally implements tag/standing admission. The formats below distinguish retained V1 behavior from newly introduced contracts. Offline regression fixtures test these supported shapes and paths; no published artifact, real host or consumer adoption is operationally qualified by those tests. Prerequisite-validator PR #3 remains separate, unmerged work.

## Four commands

```powershell
New-ClcRelease -PublishRoot <publish-directory> -MetadataPath <release-metadata.json> -OutputPath <new-release.zip> [-HookRoot <separate-hooks-directory>]
Test-ClcRelease -ArchivePath <release.zip>
Test-ClcRelease -ReleaseTag <vMAJOR.MINOR.PATCH[-dev.N|-beta.N|-rc.N]>
Invoke-ClcIisDeployment -TargetId <safe-id> -ReleaseApprovalId <safe-id> [-AllowDowngrade -Reason <change-id>] [-Operation Deploy|ValidateOnly]
Invoke-ClcIisDeployment -TargetId <safe-id> -StandingAuthorizationId <safe-id> -ReleaseTag <tag> -ArchivePath <inbox.zip> -VerifiedReleasePath <inbox.json>
Restore-ClcIisDeployment -TargetId <safe-id> -AttemptId <latest-guid> -Mode RestorePrevious|AcceptCandidate|RestoreEmpty -Reason <change-id> [-RecoveryApprovalId <safe-id>] [-PersistentStateApprovalId <safe-id>]
```

These are the only exports. Paths use literal semantics; IDs match lowercase `[a-z0-9][a-z0-9-]{0,63}`. Reason is a nonsecret lowercase safe ID of at most 128 characters, required with AllowDowngrade and rejected otherwise. Restore requires a nonempty GUID. No credentials, inline commands, arbitrary hook-entry-point inputs, policy overrides, caller journal paths, approval objects or trust-bypass flags are accepted. Automated selection also accepts `-Operation`; `-ReleaseReference` aliases `-ReleaseTag` for protected branch references. Deploy is the default operation. ValidateOnly invokes only separately declared planning code, returns Planned, and does not publish current/readiness or mutate IIS.

Test's tag-only set returns tag/releaseId/channel/releaseSequence/authorizedForDeployment=false without file or host access. Invoke's Automated set cannot combine with exact selection/downgrade flags. Restore's optional RecoveryApprovalId selects an independently authored schema-1 exact approval when the selected recovery release was automatically admitted. See the [automation contract](automated-deployments.md).

| Command | Result/effects |
| --- | --- |
| New | Published files/metadata -> deterministic inventoried ZIP. Returns contractFamily/packageContractVersion/releaseId/archivePath/archiveSha256/manifestSha256/inventorySha256/fileCount/totalBytes/builderVersion. No build/approval/payload execution |
| Test | Full ZIP/manifest/file verification without extraction. Returns integrityVerified=true, authorizedForDeployment=false and application/release/source/hash/count/builder identity. Invalid input throws; inspection never authorizes Invoke |
| Invoke | Protected authority, canonical lock, preflight and the versioned deployment lifecycle; V1 may return NoOp, V2 reruns the full cycle. ValidateOnly uses separate planning and returns Planned without publishing current/readiness. Same safe identity/toolkit/generation/pool/worker result fields |
| Restore | Same trust/lock and latest attempt. Returns RestoredPrevious/AcceptedCandidate/RestoredEmpty, attemptId/recoverySequence/releaseId/executingToolkit/currentGeneration/observedPoolState/workerCount. Empty remains stopped with no ready current |

Errors terminate with stable `Clc.*` IDs and safe attempt/pool/worker/retained-path/operator-action information. No secret/private configuration hash/raw native output is returned. Partial work or failed persistence cannot return success.

## Format and bounds

UTF-8 JSON rejects duplicate/case-ambiguous keys, unknown/missing fields, coercion, comments, nonintegral numbers, unsupported versions and trailing data. Required fields are nonnull except explicit nullable fields. IDs/hashes/GUIDs/source commits/timestamps are canonical. Shapes do not confer authority.

All host/package records retain `contractFamily=clc-file-iis-v1` and exact recordKind. Supported versions: metadata/manifest **1,2**; manual release approval **1**; generated approval **2,3**; standing-authorization and verified-release **1,2**; simplified journal **2,3**. Policy/target/current/backup/tag-binding remain **1**. V2 packages use `changeKind=application-deployment` and full-cycle repeats; optional hooks use hook contract 1 and a separate integrity inventory. V3 journals add hook intent/results and exact persistent-state recovery authority. Hook-policy and persistent-state-approval use schema 1; hook-result and source identity use contractVersion 1. V1 journals/per-file ownership records remain unsupported. Application validation/readiness and separate `clc-host-enrollment-v1`/1 are unchanged. No state is automatically migrated.

Records/manifest/metadata: 4 MiB; ZIP compressed/expanded: 1 GiB; entries: 20,000; individual file: 256 MiB; expansion: 100:1; relative/full paths: 240 characters. Enforce actual streamed lengths. Lock fails fast. Helpers: 30 seconds; stop/start: 60 each; readiness: 120 overall/5 per request/2-second poll; archive/stage/backup/replace: 300 each. Synchronous OS calls can return late, after which further effects/success refuse.

Hook/context results are bounded to 8 KiB; hook execution has an independently protected 1–300 second bound and bounded helper termination. Raw hook diagnostics remain local and are not published by shared workflows.

## Package and trusted CI digest

V1 ZIPs contain only `manifest.json` and the complete `application/` tree, including safe web.config. Metadata identifies applicationId/releaseId, source repository/full commit, build workflow/run/attempt/job/sdk/dependency lock, builder module/version/source/distribution, runtime framework/rid/architecture/hostingModel/workerLimit, changeKind=files-only, fixed validation entryPoint/contractVersion and readinessContractVersion=1. Manifest adds ordinal-sorted `{path,length,sha256}` files and inventorySha256. V2 changes schema/changeKind and optionally adds verified `hooks/` assets; `manifest.files` and inventorySha256 remain application-only. `manifest.hooks.files`/inventorySha256 cover all hook/support files; archive, entry and aggregate bounds cover both trees. See [hook contracts](application-hooks.md).

V1 retains its mandatory `build.dependencyLockSha256` digest. In the new V2 metadata/manifest contract, that field remains required but may be explicit JSON `null` for independently qualified builds without a NuGet lock. Otherwise it is the lowercase SHA-256 of the actual project-adjacent (or source-root when no project is configured) `packages.lock.json` bytes. No placeholder, omitted field or alternative evidence is a lock digest. The conventional shared builder still requires the lock and uses `--locked-mode`. Prequalified CI owns build qualification: recording a lock's bytes does not claim that its restore used locked mode. Successful exact producer/source/artifact verification, package hashes and builder identity remain required in either case. This refines unpublished package V2; no V1 format, approval, readiness or journal version changes.

Shared orchestration requires package `builder.sourceCommit` to equal the protected consumer configuration's `orchestration.sharedRevision`. Both conventional and prequalified shared package creation reject a different `SharedSourceCommit` before build/package work; publication and admission independently verify the package builder pin after byte/inventory and source/producer checks. This adds no package field/version or signing requirement, and preserves existing builder-distribution verification and independently installed host-toolkit pins.

Inventory SHA-256 covers UTF-8 `path + NUL + invariant-length + NUL + lowercase-hash + LF`, sorted ordinally, without BOM. Manifest digest covers exact UTF-8 bytes; final ZIP digest covers the entire archive. New returns the final SHA-256 for CI to publish with build provenance. The protected approval supplies deployment's trusted expected digest. Calculate/compare the downloaded ZIP once per invocation, never in file-copy loops.

Reject traversal/absolute/UNC/device/drive/ADS paths, backslashes, reserved DOS names, trailing dots/spaces, ambiguous Unicode/case, collisions, symlinks/reparse/special attributes, encryption, unsupported compression and bound violations. Inspect raw ZIP structure and full inventory before create-new safe extraction. Reject unexpected files/unrelated empty directories and verify staged hashes. Runtime cannot write staging.

The exact `application/web.config` must exist, match the verified inventory and contain well-formed XML within the 4 MiB bound; DTD processing and external entity resolution are disabled. Applications own its IIS semantics, including handlers/modules, ANCM arguments, environment variables and logging, and should validate their expected configuration in CI. The toolkit never rewrites it. An authorized application release can introduce application-level IIS configuration changes. Source eligibility, release review, infrastructure host configuration and independent exact release authorization manage that trust; shared XML allowlists do not. Dedicated site/pool, host identity/configuration, canonical paths, runtime access restrictions, package/validator identity and exact-release readiness remain independently enforced. Exclude scripts/toolkit, operational configuration, development/test settings and keys/certificates. Application builds additionally own secret/content semantics.

## Existing protected authority and preflight

Host policy keeps generation/machineIdentity/activeToolkit/targetCatalogRoot/approvalCatalogRoot/controlStateRoot/lockRoot/dotnetPath/appcmdPath/infrastructureOwnerSids/deploymentSids. Active toolkit pins exact version/source/distribution/module inventory/installed manifest. Infrastructure authenticates first import and installed Windows/.NET/IIS; no runtime-loader authentication framework is introduced.

Target keeps targetId/applicationId/environmentName/runtimeEnvironment/siteName/applicationPoolName/applicationRoot/operationalConfigPath/dataProtectionRoot/artifactInboxRoot/runtimeIdentitySid/readinessUri. Roots are disjoint existing canonical local NTFS objects; mutable OS directories, aliases/reparse/hard links/named streams refuse. Configuration is an external protected regular file. Runtime is a distinct nonadministrator with effective protected-resource write isolation. Deployment requires its authorized SID and enabled elevated administrator token. Independent approval against that administrator is procedural.

Release approval keeps approvalId/targetId/enabled/applicationId/releaseId/sourceRepository/sourceCommit/lineageId/releaseSequence/releaseZipSha256/manifestSha256/provenance/authorization. Provenance binds workflowPath/runId/runAttempt/buildJob/artifactId/transportSha256; authorization binds authoritySid/reference/approvedUtc. Select only exact `<approvalId>.zip` from the target inbox and match approved ZIP/manifest/source/build facts. Downgrade/incomparable lineage requires AllowDowngrade/reason; same sequence with different artifact identity rejects except a later automatically admitted build of the same tag/source.

Schema-2 approval adds admission.standingAuthorizationId/standingAuthorizationSha256/tag/verifiedReleaseSha256. Schema 3 adds sourceIdentity, binding the independently verified source class/integration branch/order. Routine execution requires the original exact enabled standing policy and cannot use AllowDowngrade. Only trusted installed admission code creates these records after checking policy scope, trusted workflow-supplied identity, exact package bytes, immutable tag/source binding and explicit ordering. Source/order kinds cannot be silently mixed. Snapshots do not bind a mutable branch name permanently to one commit. The [verified workflow contract](verified-workflow-integration.md) defines the separate GitHub trust boundary. Existing approvals, snapshots and backups remain readable. Standing authority alone cannot authorize exceptional recovery or executable hooks.

Comprehensive preflight checks dedicated sole IIS root application/site/pool, physical root/runtime SID, max one worker, disabled overlap, x64 .NET/ANCM, environment, actual HTTPS binding and required path/access observations. Started with zero/one workers permits idle preflight. Backup/replacement requires Stopped/zero workers; ready success requires Started/exactly one worker. Inner copy operations check affected paths and current stopped state, without full host scans.

## Application-owned validation/configuration/readiness

The fixed approved DLL receives `--validate-deployment --configuration-path <file> --data-protection-root <keys> --environment Production|Staging` through installed dotnet, with cleared environment and bounded output/time. Approved validation executes elevated without sandboxing. Strict response fields: validationContractVersion=1, valid, applicationId, releaseId, sourceCommit, runtimeEnvironment, configurationRevision, keyStoreCompatibilityId, errorCodes. `configurationRevision` uses the version-1 safe-code grammar with a 64-character maximum; `keyStoreCompatibilityId` uses that same grammar with the existing 128-character maximum.

Hold/hash configuration privately for the attempt; never copy/log it. Changed bytes under the same successful revision reject. A new revision requires restart even for identical release bytes. Candidate/previous validators must agree on current configuration/key compatibility. Mid-attempt drift aborts; key contents may evolve outside replacement.

For V1 only, an exact current release with unchanged configuration and host observations validates the approved installed inventory and application, then performs fresh readiness before recording NoOp. NoOp creates no staging directory, backup or application-file changes and preserves current.json bytes/generation while saving its completed journal/attempt snapshot. V2 always uses the full deployment cycle and reruns declared hooks. ValidateOnly preserves current bytes/generation and performs no readiness check; a successful trusted plan is recorded separately as Planned.

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

Journal records attempt/target/root snapshots, executing toolkit/policy, candidate/previous release/configuration, initial pool/empty baseline, phase/outcome, sticky live intent, coarse intent/observation, nativeCall, verified backup, optional recovery choice/sequence/reason, prospective published generation, timestamps and safe failure. Intent operations: Stage/Validate/Stop/Backup/Replace/Start/CheckReady/PublishCurrent/Complete; V3 also supports Hook. Phases: Prepared/Mutating/RecoveryRequired/Completed. V3 records possible external mutation before hook launch, per-stage intent/safe result, separate planning and persistent-state recovery approval ID/hash. A hook's false mutation result never clears uncertainty after failure. Any unresolved phase blocks ordinary Invoke. No per-file path/ownership log.

Native launch records retain callId/operation/Intent|Started|Exited/processId/exact creationUtc/exitCode. Prove the exact helper exited before recovery. Unknown launch identity refuses, with no reboot inference/quiescence override.

Current retains generation/target/root/attempt/recoverySequence, approval/release, executingToolkit, private validated configuration, stable host digest, readiness and completedUtc. It records last readiness, never present health. NoOp freshly verifies full live inventory, unchanged config/host and expected-release readiness without rewriting application/current.

Backup index retains attemptId/targetKey/priorEmpty/priorApprovalId/priorManifestSha256/files/inventorySha256. Verify backup bytes before recording verified and before recovery. Empty means no files. Ordinary upgrades/recovery consume the approval-pinned retained manifest and selected backup, without historical ZIP verification or unrelated history scans.

State writes create a same-directory temporary, flush, rename and reopen/verify. Leftover unknown temporary files block admission. Success order: readiness/final hashes -> prospective generation intent -> current -> matching Completed journal/create-new terminal snapshot -> final authority observation. Failures retain evidence. Recovery retains a before-recovery snapshot. RestoreEmpty preserves matching uncommitted current before removal; interrupted retirement can require manual maintenance.

**An unexpected OS reboot during physical replacement may require manual recovery.** Pending state does not prevent WAS activation. No startup interception or filesystem transaction engine is implemented. [Deployment and recovery](deployment.md) defines failure behavior.

Infrastructure Get/Plan stay read-only; Apply retains existing fixed enrollment and exact independent machine/config/bootstrap/toolkit/operation authority. Only dedicated directories/ACLs/stopped IIS settings may be provisioned. Accounts/secrets/certificates/trust/components stay external. Cutover requires Stopped/zero workers and verified independently approved original backup. Missing records with prior resources/locks/state require reconciliation. See [enrollment](host-enrollment.md).

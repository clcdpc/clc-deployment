# IIS verification

**Actual Windows Server 2022/IIS qualification remains NOT RUN.** This procedure covers ordinary deployment and recovery. Offline NTFS/process/loopback/DPAPI tests and synthetic IIS/identity observations do not establish live-host acceptance. Reboot, power/storage loss and other disruptive checks need separate scope and evidence.

## Rollout order

1. Complete application-owned compatibility and release integration, including immutable source and distribution pins required by the consumer.
2. Have infrastructure inspect the actual target with read-only `Get-ClcHostEnrollment` and `Initialize-ClcHostEnrollment -Operation Plan`. Apply missing setup only under exact protected authorization; reconcile incomplete or drifted state before proceeding.
3. Conduct a separately authorized consumer deployment/recovery pilot using the seven checks below and the application's prerequisites. A consumer may use its dedicated approved target; a disposable probe application is not a prerequisite.
4. Scope disruptive/destructive checks, including reboot and storage faults, separately from ordinary deployment/recovery verification.

## Prerequisites

For the optional [standing-policy path](automated-deployments.md), first complete the independent exact baseline and infrastructure policy/verifier setup. Under separately scoped host authorization, repeat upgrade/NoOp/failure/recovery checks with authenticated receipts; verify revocation before effects and require an independent exact RecoveryApprovalId for a generated selected release. Offline provenance tests do not qualify the GitHub signing/privileged-runner/actual IIS integration. Those real-host gates remain NOT RUN.

Infrastructure must explicitly authorize the host, consumer application scope, maintenance window and failure/recovery exercise. The optional harness below accepts only its explicitly designated isolated Server 2022 target and must not be repointed at a consumer or existing application.

Before starting, infrastructure supplies:

- Windows Server 2022, PowerShell 7 x64, installed .NET 10/ANCM and one dedicated IIS site/root application/pool with one worker and overlapping rotation disabled.
- The independently verified installed toolkit and protected exact version/source/distribution pin, enrolled target, canonical machine/pool lock/state and protected approval catalogs. Unsupported legacy journals or unresolved state require reconciliation before this exercise.
- The authorized deployment account with an enabled elevated administrator token, a distinct nonadministrator runtime, protected structural ACLs and effective runtime write isolation. Approval remains independently infrastructure-owned and procedural against the deployment administrator. Approved validation runs elevated.
- Working trusted HTTPS `/health/ready`, compatible protected external configuration and persistent Data Protection keys, retention capacity and a way to observe actual pool state/worker count. Accounts, secrets, certificates, machine trust and components are provisioned externally.
- Two separately approved healthy releases A and B with distinct release/source identities and increasing sequence, plus an independently approved test-only release C that validates successfully but fails readiness (for example immutable `FailureApp` `NotReady503`). Configuration revisions 1 and 2 must be application-approved and compatible with the releases selected for recovery. Keep ZIPs in the approved inbox; manifests and hashes alone never authorize execution.

Before invoking deployment or recovery, use the independently authenticated bootstrap's `Get-ClcHostEnrollment.ps1` and `Initialize-ClcHostEnrollment.ps1 -Operation Plan` to inspect the fixed enrollment. Both are read-only and establish generic enrollment state only; they do not attest application-specific IIS inheritance, runtime access, operational configuration, key usability, logging ACLs, release approval or application readiness. Continue only on fresh `Ready` and an understood no-change plan. `ToolkitNotInitialized` or `TargetNotEnrolled` needs a separate exact infrastructure Apply authorization. `Incomplete`, `DriftDetected` or `RecoveryRequired` stops the sequence for reconciliation; never use Apply to repair drift or clear unresolved deployment state. Complete any consumer-owned prerequisites before direct toolkit commands; a consumer workflow may run additional checks but must not silently provision infrastructure.

Freeze competing deployment, configuration and IIS changes. Use a fresh trusted PowerShell process for each invocation and import the exact installed manifest. Record the source/distribution, actual host/runtime identities, initial/final pool and worker observations, safe result/error, attempt ID, expected readiness identity, file inventories and retained paths. Keep original state locally protected; share only safe projections, never operational configuration, private configuration digests, credentials or raw native output.

## Seven checks

Use operator-selected IDs below; the snippets are placeholders, not host authorization. Inspect existing state and material before each transition. Stop the sequence on an unexpected result and retain evidence.

| Check | Action | Required observation |
| --- | --- | --- |
| Initial deployment | On an authorized empty target, invoke approved A. Record whether the pool starts Started or Stopped. | `Deployed`; exact A inventory and readiness; Started/one worker; verified empty backup; current generation 1 and matching Completed journal/terminal snapshot. |
| Upgrade | Invoke approved B. | `Deployed`; exact B readiness and final inventory; next current generation; complete verified A backup/index retained; external configuration and keys preserved. |
| Healthy NoOp | Invoke B again without changing configuration. | `NoOp`; fresh B readiness; unchanged application/current bytes, write times and generation; no new stage/backup or stop/copy/start; a new Completed attempt snapshot. |
| Configuration restart | Infrastructure changes only approved external configuration to revision 2, then invoke B. | `Deployed`; restart despite identical release bytes; B readiness reports revision 2; next generation and verified backup. Same-revision changed bytes must refuse in a separately scoped negative check. |
| Failed readiness | Invoke approved test-only C as an upgrade. | Bounded `Clc.ReadinessFailed` after actual replacement/start; a preflight/validation/startup failure does not complete this check. No success/current publication for C; retained stage, manifest, backup and RecoveryRequired journal. After replacement, bounded stop should prove Stopped/zero workers; report uncertainty if it cannot. No automatic restore or prior-version restart. Ordinary retry must refuse unresolved state. |
| Backup preservation | Before recovery, compare every previously recorded backup/index inventory and inspect the failed attempt's verified B backup. | Previous backups remain byte-identical; failed attempt backup/index matches approved B, including manifest/inventory digest. Configuration/keys remain outside these backups. Do not delete or edit failure material. |
| Explicit recovery | Select the latest failed attempt and explicitly restore B with `RestorePrevious` and a nonsecret reason. | Enabled approvals, exact retained manifest/verified backup, compatible revision-2 configuration and exited helpers before effects; `RestoredPrevious`, exact B readiness/inventory, Started/one worker, next generation, before-recovery snapshot and matching numbered terminal record. Original backup/stage/failure evidence remains retained. |

```powershell
Import-Module $independentlyInstalledManifest
Invoke-ClcIisDeployment -TargetId $targetId -ReleaseApprovalId $approvedA
Invoke-ClcIisDeployment -TargetId $targetId -ReleaseApprovalId $approvedB
Invoke-ClcIisDeployment -TargetId $targetId -ReleaseApprovalId $approvedB # healthy NoOp
# Infrastructure applies application-approved configuration revision 2.
Invoke-ClcIisDeployment -TargetId $targetId -ReleaseApprovalId $approvedB
# Test-only failure, within the explicitly authorized maintenance window:
Invoke-ClcIisDeployment -TargetId $targetId -ReleaseApprovalId $approvedC
# Preserve and inspect the failed attempt and all backups before recovery.
Restore-ClcIisDeployment -TargetId $targetId -AttemptId $latestFailedAttemptId -Mode RestorePrevious -Reason $incidentReference
```

Run commands individually; the expected failure must be inspected before continuing. Never reset a journal or delete a lock to bypass refusal. `RestorePrevious` uses the protected approval-pinned retained manifest and verified backup; it does not require a cached historical ZIP. A failed first install may separately exercise `RestoreEmpty` (verified empty backup/stage, approved web.config guard, Stopped/zero workers, no ready current). `AcceptCandidate` separately requires complete exact installed candidate bytes, compatible configuration and successful explicit restart/readiness; it cannot accept mixed files. Neither file recovery nor readiness establishes database rollback safety. See [failure/recovery rules](deployment.md).

Complete the seven checks only when actual observations support every result. Record missing checks as NOT RUN or BLOCKED. This evidence establishes the exercised host/application path, not reboot, power-loss, storage-fault, independent-identity or production acceptance. Further disruptive checks require separate scope. Unexpected OS reboot during replacement may require manual recovery; there is no activation fence or startup hook.

## Retained disposable harness

`tests/Qualification/Scripts/Invoke-IisQualification.ps1` defaults to read-only preflight. `-Operation Plan` writes the retained scenario catalog as NOT RUN without a host. It is a catalog for separately selected investigations, not a required replacement qualification campaign. The `mandatory*` aggregate fields describe catalog report completeness; they do not define the DEV pilot or release acceptance checklist. Reports always leave `realHostQualified=false` and independent acceptance Required.

The healthy/negative probe builders, independently verified distribution/installation, protected authorization and ownership checks, actual token/access observations, lifecycle/drift/recovery/idle/DPAPI scenarios, privacy scanner and protected evidence collection/aggregation remain available. Worker observations use fixed command names and external phase-journal polling, with no exact source lines or crash injection. Timings include instrumentation; short journal intervals can be missed and remain unobserved, never zero. Performance profiles retain provenance/count checks and production deadlines; synthetic padding does not establish consumer representativeness.

For a separately authorized disposable campaign, use the existing [configuration schema/template](../tests/Qualification/Configuration), protected exact-config/machine/time/action authorization, independently installed toolkit and ownership marker. `New-IisQualificationEnvironment.ps1` defaults to Plan and retirement defaults to Inspect. Provisioning, approval, activation and cleanup retain their separate infrastructure procedures; no repository template grants authority. Keep credentials/configuration/evidence outside source and evidence outside the removable owned root. [Distribution installation](installation.md) remains authoritative for exact-byte installation.

The existing infrastructure-owned authorization record uses `formatVersion=1`, exact `configurationSha256`, `reference`, `machineIdentity`, `computerName`, `campaignId`, distinct `grantedBySid`, `expiresUtc` within seven days, explicit `permissions`, `isolationConfirmed=true` and `cleanupRetainsEvidence=true`. Execution needs `execute`, `change-owned-iis`, `change-owned-fixtures` and `terminate-owned-process` (bounded worker cleanup); enrollment, approval, activation, observation and cleanup retain their separate permissions. Each fresh worker rechecks authorization. Self-authored adjacent JSON never supplies independent authority.

```powershell
& .\tests\Qualification\Scripts\Invoke-IisQualification.ps1 -Operation Plan -OutputRoot $newPlanDirectory
& .\tests\Qualification\Scripts\Invoke-IisQualification.ps1 -ConfigurationPath $localConfiguration -OutputRoot $newPreflightDirectory
& .\tests\Qualification\Scripts\Invoke-IisQualification.ps1 -ConfigurationPath $localConfiguration -Operation Execute -AuthorizationPath $protectedAuthorization -ScenarioId deploy-initial-stopped -OutputRoot $newEvidenceDirectory
```

Select one established scenario at a time. NoOp/configuration/idle checks select the exact current campaign release; controlled drift requires the initial release. Failed readiness and infrastructure-controlled identity/TLS/storage cases remain operator-observed: the runner reports BLOCKED rather than manufacturing a pass. Retained recovery cases require an actually established failed attempt; destructive fixture reset is never automatic. Capture safe before/after/worker/terminal evidence, run `Test-QualificationEvidencePrivacy.ps1`, and preserve material for the infrastructure owner. Protected evidence receipts and report merging preserve provenance; they do not execute missing checks or automatically qualify a host.

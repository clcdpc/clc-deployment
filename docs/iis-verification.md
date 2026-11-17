# IIS verification

The optional [GitHub setup check](github-setup-check.md) reads settings only; routine deployments do not require it. Host/consumer acceptance and independent-identity qualification need separately scoped enrollment, preflight and deployment/recovery observations.

**Actual Windows Server 2022/IIS qualification remains NOT RUN.** This procedure covers ordinary deployment and recovery. Offline NTFS/process/loopback/DPAPI tests and synthetic IIS/identity observations do not establish live-host acceptance. Reboot, power/storage loss and other disruptive checks need separate scope and evidence.

The harness/NoOp check use V1 packages. For an authorized V2 pilot, expect full repeat deployment: hooks rerun, stop/start, successful readiness and next generation. Separately authorize database/hooks/persistent-state reconciliation under [hook contracts](application-hooks.md).

V2 live-host, database and independent-identity acceptance remain NOT RUN.

## Rollout order

1. Complete application-owned compatibility and release integration, including immutable source and distribution pins required by the consumer.
2. Have infrastructure complete [preauthorization observation collection and the independent protected handoff](host-enrollment.md#3-collect-observations-and-prepare-the-candidate) before the first read-only `Get-ClcHostEnrollment` and `Initialize-ClcHostEnrollment -Operation Plan`. Apply only exact authorized missing setup; reconcile incomplete/drifted state first.
3. Conduct a separately authorized consumer deployment/recovery pilot using the seven checks below and the application's prerequisites. A consumer may use its dedicated approved target; a disposable probe application is not a prerequisite.
4. Scope disruptive/destructive checks, including reboot and storage faults, separately from ordinary deployment/recovery verification.

## Prerequisites

For the optional [standing-policy path](automated-deployments.md):

1. Establish independently approved baseline and standing policy.
2. Separately authorize upgrade/repeat/failure/recovery checks using workflow-verified exact releases.
3. Verify revocation before effects; require independent exact RecoveryApprovalId for a generated selected recovery release.

Offline admission tests do not qualify privileged runners or IIS. These real-host gates remain NOT RUN.

Infrastructure must explicitly authorize the host, consumer application scope, maintenance window and failure/recovery exercise. The optional harness below accepts only its explicitly designated isolated Server 2022 target and must not be repointed at a consumer or existing application.

Before starting, infrastructure supplies:

- Windows Server 2022, PowerShell 7 x64, installed .NET 10/ANCM and one dedicated IIS site/root application/pool with one worker and overlapping rotation disabled.
- The independently verified installed toolkit and protected exact version/source/distribution pin, enrolled target, canonical machine/pool lock/state and protected approval catalogs. Unsupported legacy journals or unresolved state require reconciliation before this exercise.
- The authorized deployment account with an enabled elevated administrator token, a distinct nonadministrator runtime, protected structural ACLs and effective runtime write isolation. Approval remains independently infrastructure-owned and procedural against the deployment administrator. Approved validation runs elevated.
- Working trusted HTTPS `/health/ready`, compatible protected external configuration and persistent Data Protection keys, retention capacity and a way to observe actual pool state/worker count. Accounts, secrets, certificates, machine trust and components are provisioned externally.
- Two separately approved healthy releases A and B with distinct release/source identities and increasing sequence, plus an independently approved test-only release C that validates successfully but fails readiness (for example immutable `FailureApp` `NotReady503`). Configuration revisions 1 and 2 must be application-approved and compatible with the releases selected for recovery. Keep ZIPs in the approved inbox; manifests and hashes alone never authorize execution.

Before deployment/recovery:

1. Run authenticated bootstrap `Get-ClcHostEnrollment.ps1` and `Initialize-ClcHostEnrollment.ps1 -Operation Plan`. Continue only with fresh Ready and an understood no-change plan.
2. For ToolkitNotInitialized/TargetNotEnrolled, obtain separate exact infrastructure Apply authority. Stop for reconciliation on Incomplete/DriftDetected/RecoveryRequired; Apply cannot repair drift or clear pending deployment.
3. Complete consumer prerequisites: application-specific IIS inheritance/runtime access, configuration, key usability, logging ACLs, release approval and readiness. Read-only enrollment inspection attests none of these; consumer checks must not silently provision infrastructure.

Freeze competing deployment/configuration/IIS writers. Use fresh trusted PowerShell with the exact installed manifest for each invocation. Record:

- Source/distribution and actual host/runtime identities.
- Initial/final pool/workers, safe result/error and attempt ID.
- Expected readiness, file inventories and retained paths.

Protect original local state; share safe projections only. Exclude configuration, private configuration digests, credentials and raw native output.

## Seven checks

Use operator-selected IDs below; the snippets are placeholders, not host authorization. Inspect existing state and material before each transition. Stop the sequence on an unexpected result and retain evidence.

### 1. Initial deployment

Invoke approved A on the authorized empty target; record initial Started/Stopped pool state. Require:

- Deployed, exact A inventory/readiness, Started/one worker.
- Verified empty backup, current generation 1 and matching Completed journal/terminal snapshot.

### 2. Upgrade

Invoke approved B. Require Deployed, exact B readiness/final inventory and next generation. Retain complete verified A backup/index; preserve external configuration/keys.

### 3. Healthy NoOp

Invoke B unchanged. Require:

- NoOp with fresh B readiness and new Completed attempt snapshot.
- Unchanged application/current bytes, write times and generation; no stage/backup or stop/copy/start.

### 4. Configuration restart

Infrastructure approves/applies only external configuration revision 2; invoke B. Require Deployed with restart despite identical release bytes, revision-2 readiness, next generation and verified backup. Separately scope a negative check proving same-revision changed bytes refuse.

### 5. Failed readiness

Invoke test-only approved C as an upgrade. Require:

- Bounded `Clc.ReadinessFailed` **after replacement/start**. Preflight/validation/startup failure does not satisfy this check.
- No C success/current publication; retained stage/manifest/backup and RecoveryRequired journal.
- Bounded stop proving Stopped/zero workers, or explicit uncertainty. No automatic restore/prior-version restart.
- Ordinary retry refuses unresolved state.

### 6. Backup preservation

Before recovery, compare every recorded backup/index inventory and the failed attempt's B backup. Require byte-identical prior backups and exact approved B manifest/inventory digests. Configuration/keys stay outside backups. Preserve all failure material unchanged.

### 7. Explicit recovery

Select latest failed attempt, RestorePrevious and nonsecret reason. Require:

- Before effects: enabled approvals, exact retained manifest/verified backup, compatible revision-2 configuration and exited helpers.
- RestoredPrevious, exact B readiness/inventory, Started/one worker, next generation, before-recovery snapshot and matching numbered terminal record.
- Original backup/stage/failure evidence retained.

### Command examples

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

Run commands individually; inspect expected failure before continuing. Never reset journals/delete locks to bypass refusal. RestorePrevious uses the retained approval-pinned manifest/verified backup, without cached historical ZIP.

Separately scoped alternatives:

| Mode | Required observation |
| --- | --- |
| RestoreEmpty | Failed first install; verified empty backup/stage, approved web.config guard, Stopped/zero workers, no ready current |
| AcceptCandidate | Complete exact candidate, compatible configuration, explicit restart/readiness; mixed files refuse |

File recovery/readiness proves no database rollback safety. See [recovery rules](deployment.md).

Complete the seven checks only when actual observations support every result. Record missing checks as NOT RUN or BLOCKED. This evidence establishes the exercised host/application path, not reboot, power-loss, storage-fault, independent-identity or production acceptance. Further disruptive checks require separate scope. Unexpected OS reboot during replacement may require manual recovery; there is no activation fence or startup hook.

## Retained disposable harness

`tests/Qualification/Scripts/Invoke-IisQualification.ps1` defaults to read-only preflight. `-Operation Plan` writes the retained scenario catalog as NOT RUN without a host. It is a catalog for separately selected investigations, not a required replacement qualification campaign. The `mandatory*` aggregate fields describe catalog report completeness; they do not define the DEV pilot or release acceptance checklist. Reports always leave `realHostQualified=false` and independent acceptance Required.

Available tools include probe builders, verified distributions/installation, protected authorization/ownership and token/access checks, lifecycle/drift/recovery/idle/DPAPI scenarios, privacy scanning and protected evidence collection/aggregation.

Observation limits:

- Workers use fixed command names and external phase-journal polling, without source-line/crash injection.
- Timings include instrumentation. Missed short intervals remain unobserved, never zero.
- Performance profiles retain provenance/count checks and production deadlines; synthetic padding cannot establish consumer representativeness.

For a separately authorized disposable campaign, use the existing [configuration schema/template](../tests/Qualification/Configuration), protected exact-config/machine/time/action authorization, independently installed toolkit and ownership marker. `New-IisQualificationEnvironment.ps1` defaults to Plan and retirement defaults to Inspect. Provisioning, approval, activation and cleanup retain their separate infrastructure procedures; no repository template grants authority. Keep credentials/configuration/evidence outside source and evidence outside the removable owned root. [Distribution installation](installation.md) remains authoritative for exact-byte installation.

| Infrastructure-owned authorization | Required value |
| --- | --- |
| Identity | `formatVersion=1`, exact configurationSha256/reference/machineIdentity/computerName/campaignId, distinct grantedBySid |
| Window/isolation | expiresUtc within seven days; isolationConfirmed=true; cleanupRetainsEvidence=true |
| Execution permissions | execute, change-owned-iis, change-owned-fixtures, terminate-owned-process (bounded cleanup) |
| Other permissions | Enrollment/approval/activation/observation/cleanup separately authorized |

Each fresh worker rechecks authority; self-authored adjacent JSON grants none.

```powershell
& .\tests\Qualification\Scripts\Invoke-IisQualification.ps1 -Operation Plan -OutputRoot $newPlanDirectory
& .\tests\Qualification\Scripts\Invoke-IisQualification.ps1 -ConfigurationPath $localConfiguration -OutputRoot $newPreflightDirectory
& .\tests\Qualification\Scripts\Invoke-IisQualification.ps1 -ConfigurationPath $localConfiguration -Operation Execute -AuthorizationPath $protectedAuthorization -ScenarioId deploy-initial-stopped -OutputRoot $newEvidenceDirectory
```

Select one established scenario at a time:

- NoOp/configuration/idle: exact current campaign release. Controlled drift: initial release.
- Failed readiness/identity/TLS/storage: operator-observed; runner reports BLOCKED rather than manufacturing passes.
- Recovery: actual established failed attempt; no automatic destructive fixture reset.

Capture safe before/after/worker/terminal evidence, run `Test-QualificationEvidencePrivacy.ps1` and preserve material for infrastructure. Receipts/report merging preserve provenance; they execute no missing checks and cannot automatically qualify a host.

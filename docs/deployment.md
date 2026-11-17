# IIS deployment and explicit recovery

Follow the [public contracts](contracts.md) for command, approval, package and state formats, and [application hooks](application-hooks.md) for V2 policy, planning and persistent-state recovery.

## First application deployment

Perform this once per successfully [enrolled target](host-enrollment.md#5-inspect-plan-apply-and-verify), before standing authorization. The application owner must first qualify configuration/readiness and any separately authorized [hooks](application-hooks.md). The deployment operator uses the admitted enabled elevated administrator token. This procedure uses the existing shared package mechanism; an application-owned producer must supply equivalent authenticated identity/provenance.

### Obtain the exact release ZIP

1. **Application repository:** an authorized developer pushes a valid DEV tag, or a stable Production tag contained in master history, using the existing [release workflow](setup-guide.md#7-configure-the-release-workflow). The successful producer uploads `clc-package-<fullSourceCommit>-<runId>-<attempt>`, containing only `release.zip`; publication exposes that same ZIP as the canonical immutable GitHub Release asset.
2. Before baseline/standing setup, the automatic deployment stage is expected to refuse: an enrolled empty target reaches `Clc.AutomationRequiresBaseline`; missing toolkit/target can fail earlier. No baseline, exact approval or standing policy is inferred. Keep successful package/publication evidence even if the overall workflow becomes Failed. A publication failure skips deployment and requires separate reconciliation.
3. **Trusted infrastructure workstation, fresh PowerShell:** independently authenticate the application repository, exact tag/source, `.clc/release.json` at that source, workflow/job, run/attempt and artifact. Obtain run ID/attempt from the Actions run; obtain the artifact ID and service transport digest from its authenticated API record. Use reviewed shared source pinned by the tagged configuration (`$sharedSource`), not arbitrary release payload code. Provision read-only GitHub access through the existing secure workstation process (`GH_TOKEN` for these readers); never print/store credentials in examples/evidence. Import the independently reviewed packaging module, then load its read-only preparation readers:

```powershell
# setup-example: baseline-acquisition
Import-Module "$sharedSource\src\Clc.Deployment\Clc.Deployment.psd1"
. "$sharedSource\tools\release\Workflow.Common.ps1"
# $repository is the independently selected owner/repository, e.g. EXAMPLE-OWNER/ssrs-web.
$api = { param($method,$path,$body,[switch]$Bytes)
    Invoke-ClcReleaseApi -Repository $repository -Method $method -Path $path -Body $body -Bytes:$Bytes
}
# $tag, $sourceCommit, $runId and $runAttempt identify the selected producer.
$configResponse = & $api GET ("/repos/$repository/contents/.clc/release.json?ref=$sourceCommit") $null
if ($configResponse.encoding -cne 'base64') { throw 'Expected exact tagged configuration bytes.' }
$c = Read-ClcConsumerConfiguration -Bytes ([Convert]::FromBase64String($configResponse.content))
if ($c.repository -cne $repository) { throw 'Configuration repository differs.' }
$source = Get-ClcVerifiedSource $c $tag $sourceCommit $runId $api
$artifactId = Get-ClcQualifiedArtifactId $c $sourceCommit $runId $runAttempt $api
$run = & $api GET ("/repos/$repository/actions/runs/$runId/attempts/$runAttempt") $null
$jobs = Get-ClcGitHubCollection $api ("/repos/$repository/actions/runs/$runId/attempts/$runAttempt/jobs") jobs
$artifact = & $api GET ("/repos/$repository/actions/artifacts/$artifactId") $null
$published = & $api GET ("/repos/$repository/releases/tags/$tag") $null
```

Before proceeding, the **independent reviewer** verifies these facts against the selected tagged workflow and authenticated GitHub responses:

| Observation | Required match |
| --- | --- |
| Run | Exact repository/head_repository, run ID/attempt, full head SHA, configured workflow path, event `push`, head_branch equal to selected tag |
| Producer job | Exactly one configured REST job name (`producer.jobName`, otherwise `producer.job`), Completed/Success, same run/source; all required application qualification precedes packaging |
| Artifact | Exact ID, not expired, positive bounded size, name `clc-package-<source>-<run>-<attempt>`, same workflow_run ID/head SHA; `digest` matches `sha256:<64 lowercase hex>` |
| Timing | Artifact created between that producer job's started/completed times; job started no earlier than this attempt's run_started_at |
| Publication | Same tag/source, correct prerelease classification, canonical `release.zip` bytes, published API `immutable=true` |
| Failed overall run | Failure is the expected downstream host-authorization refusal, not failed producer/qualification/publication; retain the exact successful producer evidence |

`Get-ClcVerifiedProducer` can verify an in-progress or successfully completed overall run; it deliberately rejects a completed failed run. Do not change that verifier or fabricate a successful run. The manual independent approval procedure above reviews the successful producer separately when only downstream deployment refused.

After that review, form provenance from those authenticated observations, download the Actions transport and verify the package. `$newDownloadDirectory` is an absent protected local preparation directory; `$runId`/`$runAttempt`/`$artifactId` are actual positive integers:

```powershell
# setup-example: baseline-package
$producer = @{workflowPath=$c.producer.workflowPath; runId=[long]$runId
    runAttempt=[long]$runAttempt; buildJob=$c.producer.job; artifactId=[long]$artifactId
    transportSha256=$artifact.digest.Substring(7)}
$releaseZip = Save-ClcVerifiedArtifact $repository $producer $newDownloadDirectory $api
$inspection = Get-ClcVerifiedPackage $c $source $producer $releaseZip
$publishedAssets = @($published.assets | Where-Object { $_.name -ceq 'release.zip' })
if ($published.draft -isnot [bool] -or $published.draft -or
    $published.immutable -isnot [bool] -or -not $published.immutable -or
    $published.tag_name -cne $tag -or $publishedAssets.Count -ne 1) {
    throw 'Expected one canonical immutable published release ZIP.'
}
$publishedZip = & $api GET ("/repos/$repository/releases/assets/"+$publishedAssets[0].id) $null -Bytes
if ((Get-ClcBytesHash $publishedZip) -cne $inspection.archiveSha256) {
    throw 'Published ZIP differs from the qualified producer ZIP.'
}
# Recheck tag/source after download; any difference requires fresh review.
$sourceAgain = Get-ClcVerifiedSource $c $tag $sourceCommit $runId $api
if (($source.identity | ConvertTo-Json -Compress) -cne
    ($sourceAgain.identity | ConvertTo-Json -Compress)) { throw 'Source changed.' }
```

`Save-ClcVerifiedArtifact` checks the actual outer transport digest and safely extracts its sole bounded ZIP. `Get-ClcVerifiedPackage` checks all package/inventory hashes, source/producer/builder pin and compiled application identity without executing it. Success is integrity evidence, still not approval. If downloading canonical `release.zip` instead, independently compare it byte-for-byte with this producer-verified inner ZIP; a Release name alone is insufficient. An expired/unavailable original artifact requires a new qualified tag/build and independent review, not invented provenance or repackaging.

### Prepare and independently install the exact approval

**Infrastructure workstation:** choose a new safe `$approvalId` (for example `ssrs-web-dev-baseline`) and a stable `$lineageId` (for example `ssrs-web-dev`) that later standing policy will retain. Use the authenticated values above:

```powershell
# setup-example: baseline-approval
$releaseCandidate = [ordered]@{
    contractFamily='clc-file-iis-v1'; schemaVersion=1L; recordKind='release-approval'
    approvalId=$approvalId; targetId=$targetId; enabled=$false
    applicationId=$inspection.applicationId; releaseId=$inspection.releaseId
    sourceRepository=$source.identity.repository; sourceCommit=$inspection.sourceCommit
    lineageId=$lineageId; releaseSequence=$source.identity.sequence
    releaseZipSha256=$inspection.archiveSha256; manifestSha256=$inspection.manifestSha256
    provenance=$producer
    authorization=@{authoritySid=$authoritySid; reference=$changeReference; approvedUtc=$approvedUtc}
}
Assert-ClcRecord $releaseCandidate release-approval
```

`$authoritySid` is the actual independent approving infrastructure SID admitted by host policy and distinct from deployment; reference/time come from its approval process. Validate against [release-approval schema](../schemas/release-approval.schema.json). Independently review final bytes, package/source/producer evidence, target, lineage/sequence, configuration compatibility and maintenance scope, then enable/protect the approved record. Inspection/self-declared hashes never authenticate approval.

**On the enrolled host**, the authorized infrastructure process installs the final schema-1 approval at:

```text
%ProgramData%\clc-<target-id>\Deployment\toolkit\policy\approvals\<approvalId>.json
```

Use infrastructure ownership and structural protection from [enrollment](host-enrollment.md#1-inspect-and-prepare-the-host); never grant the individual deployment SID protected writes. Place the exact reviewed application ZIP at `%ProgramData%\clc-<target-id>\Inbox\<approvalId>.zip` and recompare its SHA-256 with the approval. Do not change/rebuild its bytes during transfer.

### Deploy and verify the baseline

**Intended host, fresh elevated admitted deployment process:** import the exact independently active manifest (from protected host-policy, verified through [installation](installation.md#verification-and-activation)), then invoke:

```powershell
Import-Module $independentlyInstalledManifest
$result = Invoke-ClcIisDeployment -TargetId $targetId -ReleaseApprovalId $approvalId
$result | ConvertTo-Json -Depth 8
```

Accept the baseline only on `status=Deployed`, expected release/toolkit identity, `observedPoolState=Started`, `workerCount=1` and `currentGeneration=1` for the first empty deployment. The engine verifies expected-release HTTPS readiness and final complete installed inventory before success. Infrastructure also reviews protected `control/<targetKey>/current.json`, `journal.json` and `attempts/<attemptId>/deployment.json`: same attempt/release/generation, Completed journal/terminal snapshot and verified empty backup/index. Derive `targetKey` with `Get-ClcTargetKey $policy.machineIdentity $target.applicationPoolName.ToUpperInvariant()` in the trusted preparation scope. Retain local evidence without publishing private configuration hashes. Follow [seven real-IIS checks](iis-verification.md#seven-checks) for observed acceptance.

Only after this successful real baseline does infrastructure establish [standing authorization](automated-deployments.md#configure-standing-authorization). For failure, preserve all retained material and use the recovery procedure below; never fabricate current state or an empty-baseline exception.

## Manual operations after baseline

Use the same exact-manifest import and protected approval/inbox locations above. Downgrades additionally require independent exact authority and a nonsecret reason:

```powershell
Invoke-ClcIisDeployment -TargetId $targetId -ReleaseApprovalId $approvedPriorRelease -AllowDowngrade -Reason $incidentReference
Restore-ClcIisDeployment -TargetId $targetId -AttemptId $latestFailedAttemptId -Mode RestorePrevious -Reason $incidentReference
```

For routine standing selection, see [automated deployments](automated-deployments.md). Revoked/changed standing bytes also block direct retries of generated exact approvals. No command provisions credentials or operational configuration.

## Deployment sequence and safeguards

1. Resolve the protected target/release approval using the target-local installed toolkit context bound to TargetId, verify the toolkit and acquire one fail-fast exclusive OS file handle for the actual machine/pool. Read that pool's state and reject unresolved attempts. Never delete a lock file or infer completion from its age or released handle.
2. Verify approved ZIP SHA-256 once, exact manifest bytes/source/build identity and safe archive contents. Preflight dedicated IIS configuration, physical paths, platform/runtime, external configuration, separate identities and effective protected-resource access. Reject reparse points, hard links, unsafe aliases/streams, overlapping roots and unknown files.
3. For a **V1** exact current release with matching host observations, verify its installed approved inventory before running its fixed application validator against current configuration. If configuration matches, check fresh expected-release readiness and record NoOp without extraction, staging, backup or stop/copy/start; preserve current state and save the completed attempt. **V2 always performs the full cycle**, even on identical repeats.
4. Otherwise extract safely to protected staging, verify inventory before application validation, run the approved fixed validator and check previous configuration compatibility. Changed configuration revisions require restart; failed NoOp readiness follows this staged deployment path.
5. Persist stop and backup intent, stop, confirm Stopped/zero workers and copy the exact approved old inventory. Verify the complete backup/index before replacement. Track bounded helper launches and exact process creation identity; unknown helper lifetime blocks recovery.
6. Persist replacement intent, replace only the approved managed union using ordinary literal .NET file operations and affected-path checks, and verify the destination inventory. Confirm Stopped/zero workers at each file effect. External configuration, keys, logs and data stay outside the replaceable tree; unexpected files are never cleanup candidates. Recovery never restores external configuration or Data Protection keys with application files.
7. Persist startup intent, start and poll exact release/source/environment/configuration readiness. Verify final hashes and exactly one worker before publishing current and a matching terminal record, with durable intent before current publication. Persistence failures cannot return success.

V2 hook packages retain a verified online backup of exact prior managed bytes before any hook. Preflight and BeforeStop run before the first IIS stop; AfterStop runs only after Stopped/zero workers; AfterStart follows exact-release readiness. This reuses the same stop/replacement/start engine. No-hook V2 keeps the stopped backup sequence. Every started hook is possible persistent mutation regardless of its result flag. SQL/DACPAC/Hangfire semantics remain application-owned.

Comprehensive host/access checks are lifecycle gates, not operations repeated for every file. At preflight and effect gates, a bounded actual-IIS observation checks every application's virtual-directory root against the selected Application tree. Exact, ancestor, descendant and physical-identity overlap refuse even when the other application uses another site/pool or the selected pool is stopped. Native local-path observations reject uncertain aliases, network paths and unknown environment expansion. IIS `%SystemDrive%`, `%SystemRoot%` and `%windir%` use native Windows facts; `%ProgramData%` uses the trusted known-folder resolver. These temporary observations release other applications' directory handles before returning. Replacement repeats the full gate after inventory and between deletion, copy and directory-retirement phases; individual file effects retain the narrow Stopped/zero-worker check. The independently trusted toolkit/Windows/.NET installation and restricted runtime access are the operational trust assumptions; approved validation executes elevated without a sandbox.

The toolkit verifies `web.config` integrity and bounded XML structure; applications validate its IIS semantics in CI. An authorized release may change application-level IIS settings, managed through source/release review and independent infrastructure host configuration and authorization. The retained approved `web.config` in RestoreEmpty is recovery material, not an activation barrier; that outcome requires Stopped/zero workers and must remain stopped pending separately authorized deployment.

Freeze competing trusted configuration, filesystem and IIS changes throughout deployment and recovery. Fresh IIS root checks do not provide atomic coordination with other applications, acquire their locks or stop/adopt their pools; conflicts require operator reconciliation. A held default-stream handle does not prevent another trusted writer from adding a named stream; fresh checks do not make stream absence atomic. These checks do not contain a compromised administrator or trusted application process.

If a foreign different-pool root conflict appears after live effects, bounded failure handling can still stop the selected pool. That private safety-stop path re-proves the held target, native machine/root identities, selected site/root/pool association, sole selected-pool application and runtime SID; it omits only the foreign-root admission scan. It cannot start a pool, stop another pool, authorize replacement or publish success. Changed selected authority still requires operator intervention. Ordinary retries, Start and explicit recovery retain full physical isolation checks and refuse an unresolved conflict; failure evidence and approved files/backups remain retained.

## Failure behavior

| Failure boundary | Behavior |
| --- | --- |
| Approval, archive, host, staging or validation failure before IIS changes | Preserve application and original pool state; retain available failure/staging information |
| Any hook failure or later failure after a hook began | Retain possible external mutation and RecoveryRequired. BeforeStop failure leaves the original pool when IIS effects have not begun. Never automatically restart previous code or retry SQL; after live effects use bounded stop |
| Stop or backup failure before replacement begins | When helper exit, unchanged prior files, configuration and target authority are proven, restore the prior running pool if appropriate. An initially stopped pool stays stopped |
| Replacement has begun, startup/readiness fails, or current/terminal publication fails | Attempt bounded stop and zero-worker observation; retain backup, stage, journal and current evidence. Do not automatically restore or start previous files |
| Stop cannot be proven or helper lifetime is unknown | Report actual Started/Stopped/Unknown facts and require operator intervention; never claim a stopped target without observation |
| Process termination or unexpected OS reboot during file copy | No cleanup guarantee. Files may be mixed, and IIS may activate them. Routine retry refuses the pending journal; manual recovery may be required |

An OS reboot during physical replacement is an explicitly accepted operational limitation. There is no Closed/Candidate/Released fence, startup hook, named-pipe activation broker, job-object admission service or per-file transaction protocol.

## Explicit recovery

`Restore-ClcIisDeployment` requires the exact latest attempt, an explicit mode and a nonsecret incident/change reason. It takes the same lock, rechecks protected approvals, target identity, unchanged compatible external configuration and helper quiescence. It retains a before-recovery snapshot and never guesses an arbitrary backup path.

After possible hook mutation, also provide `-PersistentStateApprovalId` selecting independent protected authority for the exact latest journal, selected manifest and recovery mode. Infrastructure must confirm external-state compatibility and helper quiescence. Recovery records that exact approval, executes no hooks and does not claim database rollback. Existing generated releases still need their separate RecoveryApprovalId. A schema-1 release approval or a hook's `externalStateMayHaveChanged=false` alone cannot authorize this reconciliation. See [the exact record and operator obligations](application-hooks.md#failure-and-explicit-recovery).

When the selected recovery release has an automatically generated approval, also supply `-RecoveryApprovalId` selecting an independent normal schema-1 approval with matching exact release/target/source/lineage/provenance/hashes. Standing authority does not authorize recovery. Preserve the generated approval and journal bytes; a revoked standing policy does not prevent this separately approved recovery. Existing manually approved recovery is unchanged.

| Mode | Required material and outcome |
| --- | --- |
| RestorePrevious | Enabled prior approval, approval-pinned retained manifest, exact verified backup/index and compatible configuration. Stop/observe, replace only the managed union from backup, verify, start, check previous release readiness and publish a new generation |
| AcceptCandidate | Enabled candidate approval and a complete exact installed candidate inventory. Validate, explicitly stop/start, check readiness and publish success. It cannot complete a partial copy |
| RestoreEmpty | Failed first installation, verified empty backup and complete verified stage. Stop, remove only known candidate file paths, retain the approved web.config guard, preserve any matching uncommitted current as evidence and leave no ready current |

Partial managed files can be overwritten by an explicitly selected verified backup; unexpected paths, unsafe filesystem objects, corrupt backup/source material or incompatible configuration refuse. Recovery failure after its live boundary attempts stop only and retains all evidence. No recovery recursively invokes another recovery.

## Operator procedure

1. Preserve the application tree, `journal.json`, `current.json`, attempt snapshots, staging, retained manifests and backup/index. Read the safe error's attempt, pool/worker observations and retained control path.
2. Freeze concurrent configuration/deployment/IIS changes. Fence application exposure/activation if necessary. Confirm exact machine/pool/root identities and helper exit. Unknown launch identity, corrupt state or unsupported legacy journals require infrastructure maintenance; ordinary commands never reset or adopt them.
3. Independently confirm enabled approval, exact backup/stage bytes and selected application/configuration/key compatibility. File restoration says nothing about database compatibility.
4. Select the exact latest attempt and recovery mode with a nonsecret reason. Run the independently installed toolkit in a fresh trusted PowerShell process.
5. Accept success only after exact readiness, final hashes and durable current/terminal state. Retain all recovery material until infrastructure authorizes retention cleanup.

A defective toolkit requires independent installation/activation of a reviewed compatible replacement. Lost approvals, unverifiable files, unknown helpers or unsupported state require a separately authorized manual maintenance plan. Do not edit a journal to Completed, delete evidence, adopt mixed content or assume a reboot made recovery safe. The shared elevated administrator is privileged; independent approval remains procedural against that account. Actual IIS/runtime-token/profile/TLS/storage behavior still needs real-host evidence.

## Plan-only diagnostics

Use the same approved invocation with `-Operation ValidateOnly`. Only the separately declared and policy-authorized planning entry point runs. It may retain reviewed SQL plan/report diagnostics locally, returns Planned on success and leaves IIS/current unchanged. It does not execute lifecycle hooks. Read-only behavior depends on independently reviewed code; it is not enforced by a sandbox. Failure or reported mutation requires reconciliation, and planning may have no file backup suitable for ordinary recovery. The separate optional [GitHub setup check](github-setup-check.md) reads GitHub settings and executes no application code.

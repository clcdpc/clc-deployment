# IIS deployment and explicit recovery

Prerequisite for baseline: [enrollment Apply](host-enrollment.md#5-inspect-plan-apply-and-verify) and [installed-toolkit verification](installation.md#verification-and-activation). **Next:** standing authorization only after baseline succeeds, then return to [setup verification](setup-guide.md#9-verify-the-setup). Later failures use [explicit recovery](#operator-procedure); [contracts](contracts.md) and [hooks](application-hooks.md) supply technical details.

## First application deployment

Establish one exact approved baseline per [enrolled target](host-enrollment.md#5-inspect-plan-apply-and-verify), **before standing authorization**. Application owners first qualify configuration/readiness and separately authorized hooks. Deployment requires the admitted elevated administrator token.

**Acquisition/provenance examples below apply to compatible shared-workflow consumers:** `.clc/release.json`, `clc-package-*` artifacts and shared release conventions. SSRS Web uses `.github/workflows/release.yml`, `ssrs-web-release-<run>-<attempt>` and application-owned verification with schema-1 verified release/standing authorization ([fixed adapter](https://github.com/clcdpc/ssrs-web/blob/dddb72c1bafc58db1c8f1ade301a600a269a46bd/scripts/release/AutomaticDeployment.Adapter.ps1)). Use its [application deployment guide](https://github.com/clcdpc/ssrs-web/blob/master/docs/clc-deployment.md) for release acquisition and baseline/approval/deployment.

### 1. Select and acquire the release

1. **Application repository:** push an authorized DEV tag or stable Production tag in master history through the [release workflow](setup-guide.md#7-configure-the-release-workflow). Retain successful producer/publication evidence: `clc-package-<fullSourceCommit>-<runId>-<attempt>` contains only `release.zip`, also published as the canonical immutable Release asset.
2. Expect automatic deployment to refuse before baseline/standing setup (`Clc.AutomationRequiresBaseline` on an enrolled empty target; missing setup may fail earlier). Preserve successful upstream evidence even if the overall run fails. Failed publication requires reconciliation and blocks deployment.
3. **Trusted infrastructure workstation, fresh PowerShell:** authenticate the inputs below. Application-owned producers need equivalent identity/provenance. Use reviewed `$sharedSource` pinned by tagged configuration and securely provision read-only `GH_TOKEN`; never record credentials.

   | Input | Authenticated source |
   | --- | --- |
   | Repository, tag, full commit, configuration | Application repository and exact tagged `.clc/release.json` |
   | Workflow/job, run ID/attempt | Selected Actions producer run |
   | Artifact ID, transport digest | Artifact API record |

4. Import the reviewed packaging module and load its read-only readers:

```powershell
# setup-example: baseline-acquisition
Import-Module "$sharedSource\src\Clc.Deployment\Clc.Deployment.psd1"
. "$sharedSource\tools\release\Workflow.Common.ps1"
# $repository is the independently selected compatible shared-workflow repository.
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

### 2. Verify provenance and exact bytes

1. **Independent reviewer:** compare the tagged workflow with authenticated GitHub responses:

| Observation | Required match |
| --- | --- |
| Run | Exact repository/head_repository, run ID/attempt, full head SHA, configured workflow path, event `push`, head_branch equal to selected tag |
| Producer job | Exactly one configured REST job name (`producer.jobName`, otherwise `producer.job`), Completed/Success, same run/source; all required application qualification precedes packaging |
| Artifact | Exact ID, not expired, positive bounded size, name `clc-package-<source>-<run>-<attempt>`, same workflow_run ID/head SHA; `digest` matches `sha256:<64 lowercase hex>` |
| Timing | Artifact created between that producer job's started/completed times; job started no earlier than this attempt's run_started_at |
| Publication | Same tag/source, correct prerelease classification, canonical `release.zip` bytes, published API `immutable=true` |
| Failed overall run | Failure is the expected downstream host-authorization refusal, not failed producer/qualification/publication; retain the exact successful producer evidence |

`Get-ClcVerifiedProducer` rejects completed failed runs. When only downstream deployment refused, independently review the successful producer using this table; never fabricate success or bypass the verifier.

2. Form provenance, download and verify. Use an absent protected `$newDownloadDirectory` and actual positive integer run/attempt/artifact IDs:

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

The readers verify transport/package/inventory hashes, source/producer/builder pin and compiled application identity without execution. This is integrity evidence, not approval.

3. If acquiring canonical `release.zip` separately, compare it byte-for-byte with the producer-verified inner ZIP. Expired/unavailable originals require a new qualified tag/build and review; never invent provenance or repackage.

### 3. Independently approve and install

1. **Infrastructure workstation:** choose a new safe `$approvalId` (e.g. `example-app-dev-baseline`) and stable `$lineageId` (e.g. `example-app-dev`) for later standing policy. Build the disabled candidate from verified observations:

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

2. **Independent infrastructure reviewer:** validate the [schema](../schemas/release-approval.schema.json), final bytes, package/source/producer evidence, target, lineage/sequence, configuration compatibility and maintenance scope. `$authoritySid` must be admitted by host policy and distinct from deployment; reference/time come from the approval process. Enable only the approved record.

3. **Enrolled host, authorized infrastructure process:** install the final schema-1 approval at:

```text
%ProgramData%\clc-<target-id>\Deployment\toolkit\policy\approvals\<approvalId>.json
```

4. Apply [enrollment's ownership/ancestor protection](host-enrollment.md#protect-the-handoff-and-configuration), without individual deployment-SID writes. Transfer unchanged reviewed bytes to the target's `Inbox\<approvalId>.zip`; recompare SHA-256 with approval. Inspection/self-declared hashes grant no authority.

### Deploy and verify the baseline

1. **Host, fresh elevated admitted deployment process:** [verify the exact active manifest](installation.md#verification-and-activation), import it and deploy:

```powershell
Import-Module $independentlyInstalledManifest
$result = Invoke-ClcIisDeployment -TargetId $targetId -ReleaseApprovalId $approvalId
$result | ConvertTo-Json -Depth 8
```

2. Verify the first empty deployment:

   | Evidence | Required result |
   | --- | --- |
   | Returned result | `status=Deployed`, expected release/toolkit, `observedPoolState=Started`, `workerCount=1`, `currentGeneration=1` |
   | Application | Expected-release HTTPS readiness and final complete installed inventory |
   | Protected state under `control/<targetKey>` | `current.json`, `journal.json` and `attempts/<attemptId>/deployment.json` agree on attempt/release/generation; Completed journal/terminal snapshot; verified empty backup/index |

   Derive `targetKey` with `Get-ClcTargetKey $policy.machineIdentity $target.applicationPoolName.ToUpperInvariant()` in trusted preparation. Keep private configuration hashes local. Retain the [initial-deployment observations](iis-verification.md#1-initial-deployment); remaining acceptance follows standing setup at [stage 8](setup-guide.md#9-verify-the-setup).

3. **Next:** only after successful real baseline, install [standing authorization](automated-deployments.md#configure-standing-authorization); if operating manually, return to [setup verification](setup-guide.md#9-verify-the-setup). On failure, preserve material and follow recovery below; never fabricate current state or baseline exceptions.

## Manual operations after baseline

Use the same manifest/approval/inbox procedure. Downgrades need independent exact authority and a nonsecret reason:

```powershell
Invoke-ClcIisDeployment -TargetId $targetId -ReleaseApprovalId $approvedPriorRelease -AllowDowngrade -Reason $incidentReference
Restore-ClcIisDeployment -TargetId $targetId -AttemptId $latestFailedAttemptId -Mode RestorePrevious -Reason $incidentReference
```

Use [standing selection](automated-deployments.md) for routine tags; revoked/changed standing bytes also block direct generated-approval retries. Deployment provisions no credentials or operational configuration.

## Deployment sequence and safeguards

| Phase | Engine behavior |
| --- | --- |
| Admit | Verify protected target/approval/toolkit; acquire exclusive machine/pool handle; reject unresolved attempts |
| Preflight | Verify ZIP once, manifest/source/build, safe archive, IIS/platform, paths, configuration, identities and effective access; reject unsafe objects, overlaps and unknown files |
| Stage/validate | Safely extract/verify, run fixed validator and check prior configuration compatibility. New configuration revision requires restart; failed NoOp readiness follows this path |
| Stop/backup | Persist intent, prove Stopped/zero workers, copy approved prior inventory and verify backup/index before replacement |
| Replace | Persist intent; replace only approved managed union using literal operations; check paths and Stopped/zero workers at every effect; verify destination |
| Start/publish | Persist intent, start, verify exact release/source/environment/configuration readiness, final hashes and one worker; durably publish current and matching terminal state |

**V1 healthy repeat:** unchanged configuration/host, verified live inventory, fixed validation and fresh readiness permit NoOp. Application/current remain unchanged; only the completed attempt is saved. No extraction, stage, backup or stop/copy/start occurs. **V2 repeats always run the full cycle.**

V2 hook order is Preflight → BeforeStop → stop → AfterStop → replacement/start/readiness → AfterStart. Verify an online backup before any hook; no-hook V2 uses stopped backup. Started hooks always imply possible persistent mutation. SQL/DACPAC/Hangfire compatibility remains application-owned.

Operator safeguards:

- Freeze competing configuration/filesystem/IIS writers. Checks provide no atomic cross-application coordination or containment of trusted administrators/application processes; even a held file cannot prevent another trusted writer adding a named stream.
- Keep configuration, keys, logs and data outside replacement. Unexpected files are never cleanup candidates; recovery never restores configuration/keys with application files.
- Trust the independently installed toolkit/Windows/.NET and enforce runtime access isolation. Approved validators/hooks execute elevated without sandboxing.
- Let application CI qualify `web.config` semantics. The toolkit verifies bytes/bounded XML and never rewrites it; application-level IIS changes need source/release review and independent host configuration/approval.

[Preflight contracts](contracts.md#iis-and-path-gates) define all-application physical-root checks and their repetition between replacement phases. After live effects, a foreign different-pool conflict may permit only bounded stop of the still-bound selected pool. Selected identity/authority checks remain; retries, Start and recovery refuse unresolved conflicts. Preserve evidence and reconcile independently.

## Failure behavior

| Failure boundary | Behavior |
| --- | --- |
| Approval, archive, host, staging or validation failure before IIS changes | Preserve application and original pool state; retain available failure/staging information |
| Any hook failure or later failure after a hook began | Retain possible external mutation and RecoveryRequired. BeforeStop failure leaves the original pool when IIS effects have not begun. Never automatically restart previous code or retry SQL; after live effects use bounded stop |
| Stop or backup failure before replacement begins | When helper exit, unchanged prior files, configuration and target authority are proven, restore the prior running pool if appropriate. An initially stopped pool stays stopped |
| Replacement has begun, startup/readiness fails, or current/terminal publication fails | Attempt bounded stop and zero-worker observation; retain backup, stage, journal and current evidence. Do not automatically restore or start previous files |
| Stop cannot be proven or helper lifetime is unknown | Report actual Started/Stopped/Unknown facts and require operator intervention; never claim a stopped target without observation |
| Process termination or unexpected OS reboot during file copy | No cleanup guarantee. Files may be mixed, and IIS may activate them. Routine retry refuses the pending journal; manual recovery may be required |

Pending state does not prevent IIS activation after reboot; no startup activation fence or per-file transaction protocol exists.

## Explicit recovery

Recovery selects the **latest attempt**, explicit mode and nonsecret reason. It uses the same lock, rechecks target/approvals, unchanged compatible configuration and helper quiescence, and retains a before-recovery snapshot. It never guesses backup paths or executes hooks.

| Additional authority | Required when |
| --- | --- |
| `-RecoveryApprovalId` | Selected release was automatically admitted: independent schema-1 approval matching exact release/target/source/lineage/provenance/hashes. Standing authority cannot authorize recovery; revocation does not block separately approved recovery |
| `-PersistentStateApprovalId` | Any possible hook mutation: independent exact latest-journal/manifest/mode approval of external-state compatibility and helper quiescence. Release approval or `externalStateMayHaveChanged=false` alone is insufficient |

Both can be required. Preserve generated approval/journal bytes; follow [persistent-state obligations](application-hooks.md#failure-and-explicit-recovery). File recovery never proves database rollback safety.

| Mode | Required material and outcome |
| --- | --- |
| RestorePrevious | Enabled prior approval, approval-pinned retained manifest, exact verified backup/index and compatible configuration. Stop/observe, replace only the managed union from backup, verify, start, check previous release readiness and publish a new generation |
| AcceptCandidate | Enabled candidate approval and a complete exact installed candidate inventory. Validate, explicitly stop/start, check readiness and publish success. It cannot complete a partial copy |
| RestoreEmpty | Failed first installation, verified empty backup and complete verified stage. Stop, remove only known candidate file paths, retain the approved web.config guard, preserve any matching uncommitted current as evidence and leave no ready current |

`RestoreEmpty` must remain Stopped/zero workers pending separately authorized deployment; retained `web.config` is recovery material, not an activation barrier.

Verified backup may overwrite partial managed files. Unknown/unsafe paths, corrupt sources/backups or incompatible configuration refuse. Recovery failure after live effects attempts stop only, retains evidence and never invokes another recovery.

## Operator procedure

1. Read safe error facts: attempt, actual pool/workers, retained control path and operator action. Preserve application, journal/current, attempt snapshots, staging, manifests and backup/index. Never delete locks or infer completion from age/released handles.
2. Freeze competing writers; fence exposure/activation as needed. Confirm exact machine/pool/root and helper exit, including exact recorded creation identity. Unknown helper lifetime/identity requires maintenance; reboot proves no quiescence.
3. Independently verify enabled approvals, backup/stage bytes and application/configuration/key compatibility. Add the authorities above when required. Database safety requires application-owned evidence.
4. Import the exact approved installed manifest in a fresh trusted process. Select the latest attempt/mode/reason, for example:

   ```powershell
   Restore-ClcIisDeployment -TargetId $targetId -AttemptId $latestFailedAttemptId `
       -Mode RestorePrevious -Reason $incidentReference
   # Add -RecoveryApprovalId and/or -PersistentStateApprovalId when required above.
   ```

5. Verify the selected mode's pool/readiness, final hashes and durable current/terminal outcome. RestoreEmpty remains stopped with no ready current. Retain recovery material until infrastructure authorizes cleanup.

Lost authority, unverifiable bytes, corrupt/unsupported state or unknown helpers need separately authorized maintenance. A defective toolkit needs independently installed/activated compatible replacement. Never edit journals to Completed, delete evidence, adopt mixed content or infer reboot safety. Independent approval against the elevated administrator remains procedural.

## Plan-only diagnostics

Add `-Operation ValidateOnly` to the approved invocation. Only separately declared, policy-authorized planning code runs; success returns Planned with IIS/current unchanged and no lifecycle hooks. Reviewed SQL diagnostics stay local.

Read-only behavior depends on code review, without sandboxing. Failure/reported mutation needs reconciliation; planning may have no recoverable file backup. The [GitHub setup check](github-setup-check.md) separately reads settings without application execution.

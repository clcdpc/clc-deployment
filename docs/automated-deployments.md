# Standing authorization and routine deployment

Complete [host enrollment](host-enrollment.md) and the [first independently approved application baseline](deployment.md#first-application-deployment) before configuring standing authority. It admits routine exact releases for one established target; it cannot authorize enrollment, initial baseline/cutover, toolkit changes, downgrades or exceptional recovery. Build-time shared pins and the target's independently active host-toolkit pin remain separate.

## Configure standing authorization

1. **Infrastructure workstation:** obtain the protected target/host policy and the successful baseline approval. Record the exact application, target, `environmentName`, repository and baseline `lineageId`. Read the producer workflow path/job from the authenticated application's `.clc/release.json` and workflow. `buildJob` is the logical configured producer job, not its optional REST display name. Use `integrationBranch=master`.
2. Prepare a schema-**2** candidate using the [strict schema](../schemas/standing-authorization.schema.json). Current shared tag behavior supplies schema-2 verified evidence; DEV requires `allowUnmergedDevTags=true`. Use `allowSnapshots=false` for both shared routine targets. The example is shape-valid synthetic data: replace repository, approving SID/reference/time and any different actual target/producer/lineage values before review. Keep `enabled=false` until independent approval:

```json
{
  "contractFamily": "clc-file-iis-v1",
  "schemaVersion": 2,
  "recordKind": "standing-authorization",
  "standingAuthorizationId": "ssrs-web-dev",
  "enabled": false,
  "targetId": "ssrs-web-dev",
  "applicationId": "ssrs-web",
  "environmentName": "DEV",
  "channel": "DEV",
  "sourceRepository": "EXAMPLE-OWNER/ssrs-web",
  "buildWorkflowPath": ".github/workflows/build.yml",
  "buildJob": "package",
  "lineageId": "ssrs-web-dev",
  "authorization": {
    "authoritySid": "S-1-5-21-1-2-3-1002",
    "reference": "replace-with-approved-change",
    "approvedUtc": "2026-11-18T15:00:00Z"
  },
  "sourcePolicy": {
    "integrationBranch": "master",
    "allowUnmergedDevTags": true,
    "allowSnapshots": false
  }
}
```

3. **Independent infrastructure reviewer:** verify the complete candidate against baseline/target/producer evidence and host policy. `authorization.authoritySid` must be an actual admitted infrastructure SID distinct from deployment; reference/time come from its approval process. Approve final bytes and set `enabled=true`. Hooks require a separate [hook policy](application-hooks.md), including `UnmergedDevTag` scope for unmerged DEV hooks; standing policy alone never enables executable hooks.
4. **On the intended host, infrastructure process:** create/protect the `standing` subdirectory if absent and install the exact approved record at:

```text
%ProgramData%\clc-<target-id>\Deployment\toolkit\policy\approvals\standing\<standingAuthorizationId>.json
```

Use the [protected ownership/ancestor procedure](host-enrollment.md#1-inspect-and-prepare-the-host), effective runtime isolation and no direct deployment-SID protected write ACE. The toolkit never creates/enables standing policy. NTFS does not contain the elevated deployment administrator; independent approval remains procedural.

5. **Verify locally:** validate final JSON with `Test-Json -Json (Get-Content -LiteralPath $standingPath -Raw) -SchemaFile $standingSchema`, where `$standingSchema` is the reviewed schema above. Then, in a fresh elevated admitted deployment process importing the exact active manifest, use this infrastructure-only read of the installed protected record:

```powershell
# setup-example: standing-verification
& (Get-Module Clc.Deployment) {
    param($TargetId, $StandingId)
    $context = $null
    try {
        $context = Open-ClcTrustedContext -TargetId $TargetId
        $target = (Read-ClcProtectedTarget $context $TargetId).record
        $record = (Read-ClcStandingAuthorization $context $target $StandingId).record
        $record | Select-Object standingAuthorizationId,targetId,enabled,channel,
            sourceRepository,buildWorkflowPath,buildJob,lineageId,sourcePolicy
    } finally { Close-ClcTrustedContext $context }
} $targetId $standingAuthorizationId
```

Success: strict protected-record verification returns the intended enabled scope. Compare it with the baseline and tagged producer configuration; this reader does not verify GitHub or authorize deployment. Under separately authorized consumer scope, the next eligible tag verifies the complete workflow/host path. Repeat setup independently for Production using its target/standing ID, exact target `environmentName`, `channel=Production`, baseline lineage and `allowUnmergedDevTags=false`.

## Routine operation and revocation

An authorized developer pushes an eligible tag using [setup section 10](setup-guide.md#10-routine-operation). The existing application workflow qualifies its producer, publishes immutable bytes, then invokes installed admission. Its authenticated channel determines target/environment/runner labels before host lookup. Native ProgramData and protected target-local host policy select/verify the exact active toolkit; beta/RC return before any host lookup.

The current explicit engine invocation is:

```powershell
Invoke-ClcIisDeployment -TargetId $targetId -StandingAuthorizationId $standingAuthorizationId `
    -ReleaseTag $tag -ArchivePath $inboxZip -VerifiedReleasePath $verifiedIdentity
```

The trusted workflow supplies the exact inbox ZIP and independently verified release identity; hand-written identity JSON is not authentication. No additional human approval is required for each routine tag. Verify actual result, expected readiness, installed inventory and completed state as in [deployment](deployment.md#deploy-and-verify-the-baseline). V2 repeats perform the full cycle and rerun applicable hooks; V1 retains healthy NoOp behavior.

**Revoke through infrastructure:** fence active deployment/policy writers, preserve the old exact policy/evidence, then disable, remove or byte-change that protected standing record under independently authorized change control. This revokes its generated approvals, including direct `-ReleaseApprovalId` retries. Recheck the disabled/missing record and, in a separately authorized negative exercise, verify refusal before mutation. Never delete attempts, pending intents or release evidence to retry. Generated-release recovery needs an independent matching schema-1 `RecoveryApprovalId`, plus compatible files/configuration and proven helper exit; possible hook mutation additionally needs independent persistent-state approval.

## Source, ordering and interruption reference

| Reference | Eligibility |
| --- | --- |
| `vMAJOR.MINOR.PATCH-dev.N` | DEV: `IntegrationTag` in protected master history or explicitly enabled `UnmergedDevTag` outside it |
| `vMAJOR.MINOR.PATCH` | Production: protected integration ancestry and separate Production standing authority |
| `-beta.N`, `-rc.N` | ArtifactOnly: package/publication, no privileged host handoff |
| `-test.N` | Unsupported |
| `refs/heads/<integrationBranch>` | Retained installed DEV snapshot support only when explicitly enabled; shared routine entry point accepts tags only |

Unmerged DEV needs no PR metadata, approval, current PR-head equality or master-file equality. PR branches may be draft/closed/advanced/deleted/unprotected. The authorized tag creator can select executable workflow/script/configuration/shared-pin changes. GitHub native actor/tag controls and protected master remain required; verification repeats exact source/producer/artifact eligibility after queueing/download. See [workflow contract](verified-workflow-integration.md).

SemVer uses bounded numeric sequence from `Test-ClcRelease -ReleaseTag`. Snapshots use authenticated producer runId and `dev-<runId>-<first12SourceCommit>`. Ordering kinds cannot mix within an automated lineage; switching requires a separate manual baseline. Protect integration history: run order is not a rollback detector. Only DEV/Production are deployment channels; host/environment names containing “test” do not create another channel.

Later runs/attempts may admit rebuilt same-tag/source bytes; changed bytes in one run/attempt, moved tags and older builds refuse. An UnmergedDevTag becoming integrated can be admitted in the same run only with identical reference/source/release/provenance/ZIP/manifest. This does not permit replacement of immutable canonical GitHub assets: conflicting rebuilt publication fails; choose a new tag.

Schema-2 policy/evidence yields generated approval 3 with source identity. Historical schema-1 policy/evidence yields generated approval 2; schema versions must match. Generated records bind exact standing bytes and target/source/build/artifact/package identity. Equivalent evidence formatting preserves first-admitted evidence. Tag/source bindings are immutable per target/lineage; snapshots never permanently bind a mutable branch name. No historical policy registry exists.

Admission holds the canonical machine/pool lock and requires clean current baseline state. A durable `standing/<targetId>.pending` intent precedes catalog/inbox/approval effects; interruption blocks ordinary deployment for independent reconciliation. Thereafter the normal lifecycle journal blocks unresolved attempts. Policy revocation does not prevent independently exact-approved recovery; retain original generated approvals/journals. File recovery never establishes database rollback safety.

**Actual Windows Server 2022/IIS, runner admission and independent-identity qualification remain NOT RUN.** Follow [IIS verification](iis-verification.md).

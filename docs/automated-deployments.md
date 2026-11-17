# Standing authorization and routine deployment

Prerequisite: [verified installed toolkit](installation.md#verification-and-activation) and [successful independently approved baseline](deployment.md#deploy-and-verify-the-baseline). Standing authority excludes enrollment, baseline/cutover, toolkit changes, downgrades and exceptional recovery. Build-time shared pins remain separate from the active host-toolkit pin. **Next:** return to [setup section 9](setup-guide.md#9-verify-the-setup) for separately authorized IIS acceptance, then routine operation.

**The schema-2 example below is for compatible shared-workflow consumers** using `.clc/release.json` and `clc-package-*`. SSRS Web retains `.github/workflows/release.yml`, `ssrs-web-release-<run>-<attempt>` and application-owned verification: schema-1 verified release requires matching schema-1 standing authorization ([fixed adapter](https://github.com/clcdpc/ssrs-web/blob/dddb72c1bafc58db1c8f1ade301a600a269a46bd/scripts/release/AutomaticDeployment.Adapter.ps1)). Follow its [authorization/deployment guide](https://github.com/clcdpc/ssrs-web/blob/master/docs/clc-deployment.md#github-and-host-configuration-prerequisites); no schema-2 migration is required.

## Configure standing authorization

1. **Infrastructure workstation:** collect inputs from protected target/host policy, successful baseline approval and authenticated application `.clc/release.json`/workflow:

   | Input | Value |
   | --- | --- |
   | Scope | Exact application/target/environment/repository; baseline `lineageId` |
   | Producer | Exact workflow path and logical `buildJob`, not optional REST display name |
   | Source policy | `integrationBranch=master`; DEV `allowUnmergedDevTags=true`; shared routine targets `allowSnapshots=false` |

2. Prepare a [schema-2 candidate](../schemas/standing-authorization.schema.json), matching current shared evidence. Replace synthetic repository/SID/reference/time and any differing target/producer/lineage values below. Keep disabled pending independent approval:

```json
{
  "contractFamily": "clc-file-iis-v1",
  "schemaVersion": 2,
  "recordKind": "standing-authorization",
  "standingAuthorizationId": "example-app-dev",
  "enabled": false,
  "targetId": "example-app-dev",
  "applicationId": "example-app",
  "environmentName": "DEV",
  "channel": "DEV",
  "sourceRepository": "EXAMPLE-OWNER/example-app",
  "buildWorkflowPath": ".github/workflows/build.yml",
  "buildJob": "package",
  "lineageId": "example-app-dev",
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

3. **Independent reviewer:** compare candidate with baseline/target/producer/host-policy evidence. Use an admitted infrastructure SID distinct from deployment and the actual approval reference/time. Approve final bytes and enable. Hooks separately require [hook policy](application-hooks.md), including UnmergedDevTag scope for unmerged DEV.
4. **On the intended host, infrastructure process:** create/protect the `standing` subdirectory if absent and install the exact approved record at:

```text
%ProgramData%\clc-<target-id>\Deployment\toolkit\policy\approvals\standing\<standingAuthorizationId>.json
```

Apply [ownership/ancestor protection](host-enrollment.md#protect-the-handoff-and-configuration), effective runtime isolation and no direct deployment-SID write ACE. The toolkit never creates/enables standing policy; approval against the elevated administrator remains procedural.

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

Compare returned enabled scope with baseline/tagged producer configuration. This read does not verify GitHub or authorize a deployment; exercise the next eligible tag only under separately authorized consumer scope.

Repeat independently for Production: its target/standing ID, exact `environmentName`, `channel=Production`, baseline lineage and `allowUnmergedDevTags=false`. **Next:** [setup verification](setup-guide.md#9-verify-the-setup).

## Routine operation and revocation

An authorized developer [pushes an eligible tag](setup-guide.md#10-routine-operation). The workflow qualifies its producer, publishes immutable bytes, then invokes installed admission. Authenticated channel selects target/environment/runner labels; native ProgramData/protected policy select the active toolkit. Beta/RC return before host lookup.

The current explicit engine invocation is:

```powershell
Invoke-ClcIisDeployment -TargetId $targetId -StandingAuthorizationId $standingAuthorizationId `
    -ReleaseTag $tag -ArchivePath $inboxZip -VerifiedReleasePath $verifiedIdentity
```

The trusted workflow supplies exact ZIP and authenticated release identity; hand-written JSON grants no authority. Routine tags need no further human approval. Verify [result/readiness/inventory/completed state](deployment.md#deploy-and-verify-the-baseline). V2 repeats rerun full cycle/hooks; V1 retains healthy NoOp.

To revoke, infrastructure:

1. Fences deployment/policy writers and preserves exact old policy/evidence.
2. Independently authorizes and disables, removes or byte-changes the protected record. Generated approvals, including direct `-ReleaseApprovalId` retries, are revoked.
3. Rechecks disabled/missing/changed bytes; separately authorizes a negative exercise proving refusal before mutation.

Preserve attempts/intents/release evidence. Generated-release recovery needs independent matching schema-1 RecoveryApprovalId, compatible files/configuration and exited helpers. Possible hook mutation also needs persistent-state approval; follow [recovery](deployment.md#explicit-recovery).

## Source, ordering and interruption reference

| Reference | Eligibility |
| --- | --- |
| `vMAJOR.MINOR.PATCH-dev.N` | DEV: `IntegrationTag` in protected master history or explicitly enabled `UnmergedDevTag` outside it |
| `vMAJOR.MINOR.PATCH` | Production: protected integration ancestry and separate Production standing authority |
| `-beta.N`, `-rc.N` | ArtifactOnly: package/publication, no privileged host handoff |
| `-test.N` | Unsupported |
| `refs/heads/<integrationBranch>` | Retained installed DEV snapshot support only when explicitly enabled; shared routine entry point accepts tags only |

Unmerged DEV needs no PR metadata/approval, PR-head or master-file equality; branch status/protection is irrelevant. Authorized tag creators select executable workflow/script/configuration/shared pins. Native actor/tag controls and protected master remain required; exact source/producer/artifact checks repeat after queueing/download. See [workflow trust](verified-workflow-integration.md).

| Ordering | Rule |
| --- | --- |
| Tags | Bounded numeric sequence from `Test-ClcRelease -ReleaseTag` |
| Snapshots | Authenticated runId; `dev-<runId>-<first12SourceCommit>` |
| Switching kinds | Separate manual baseline; never mix within automated lineage |
| History/channels | Protect integration history; run order cannot detect rollback. Only DEV/Production deploy; “test” names add no channel |

Later runs/attempts may admit rebuilt same-tag/source bytes; same-attempt changed bytes, moved tags and older builds refuse. Same-run UnmergedDevTag → integrated admission requires identical reference/source/release/provenance/ZIP/manifest. Immutable canonical assets cannot be replaced: conflicting publication requires a new tag.

| Matching policy/evidence | Generated approval |
| --- | --- |
| Schema 2 | Schema 3, including source identity |
| Schema 1 (including SSRS Web) | Schema 2 |

Both bind exact standing bytes and target/source/build/artifact/package. Equivalent evidence formatting preserves first-admitted evidence. Tag/source bindings are immutable per target/lineage; snapshots do not permanently bind branch names. No historical policy registry exists.

Admission requires clean baseline under the machine/pool lock. Durable `standing/<targetId>.pending` intent precedes catalog/inbox/approval effects; interruption requires independent reconciliation. The lifecycle journal then blocks unresolved attempts. Retain generated approvals/journals for independent recovery; file recovery proves no database rollback safety.

**Actual Windows Server 2022/IIS, runner admission and independent-identity qualification remain NOT RUN.** Follow [IIS verification](iis-verification.md).

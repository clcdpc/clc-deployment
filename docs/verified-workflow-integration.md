# Verified workflow integration contract

The shared [workflow integration guide](shared-release-orchestration.md) describes consumer configuration and examples. This document defines the handoff into the independently installed host toolkit. It extends the implementation on `master` at [`7f814ef`](https://github.com/clcdpc/clc-deployment/commit/7f814ef838abcfd12ade494c429918657598c35d); existing release artifacts must be evaluated at their own exact source/distribution pins. The new formats below are introduced by this change and require independent toolkit installation/adoption. No operational state is migrated.

## Host API and versions

```powershell
Invoke-ClcIisDeployment -TargetId $targetId -StandingAuthorizationId $standingId `
    -ReleaseReference $reference -ArchivePath $inboxZip -VerifiedReleasePath $inboxIdentity
# Separate, explicitly authorized diagnostics; never runs ordinary lifecycle hooks:
Invoke-ClcIisDeployment -TargetId $targetId -StandingAuthorizationId $standingId `
    -ReleaseReference $reference -ArchivePath $inboxZip -VerifiedReleasePath $inboxIdentity -Operation ValidateOnly
```

`ReleaseReference` aliases the existing `ReleaseTag` parameter. The reference is an exact supported tag or `refs/heads/<protectedIntegrationBranch>`. The Automated parameter set cannot combine with exact approval/downgrade selection. Both paths are absolute literal paths to regular files directly inside the protected target inbox; use unique input filenames. The toolkit holds and verifies them during admission. No caller-selected target/state paths, inline commands, credentials or approval objects are accepted.

| Contract | Existing supported format | New format |
| --- | --- | --- |
| Exact manual approval | Schema 1 | Unchanged |
| Standing policy | Schema 1, tagged DEV/production | Schema 2 adds explicit integration branch/PR/snapshot/test source policy |
| Verified release | Schema 1, tagged identity | Schema 2 adds versioned source identity |
| Generated exact approval | Schema 2 | Schema 3 retains exact source identity in `admission` |
| Application package | Schema 1, file-only/healthy NoOp | Schema 2, full deployment cycle and optional separate hook assets |

Both standing/evidence versions must correspond. Legacy manual approvals and retained recovery evidence remain readable; this does not claim every published toolkit can read the new records. See [public contracts](contracts.md) for package/journal versions and [installation](installation.md) before changing an active pin.

## Trusted verified-release JSON

The trusted workflow supplies strict UTF-8 JSON only after independent platform verification. Unknown/duplicate fields, noncanonical commits/hashes, malformed types and unsupported versions refuse. JSON is evidence, not independent execution authority.

```json
{
  "contractFamily": "clc-file-iis-v1",
  "schemaVersion": 2,
  "recordKind": "verified-release",
  "targetId": "example-dev",
  "applicationId": "example",
  "releaseId": "v1-0-0-dev-2",
  "tag": "v1.0.0-dev.2",
  "sourceRepository": "owner/application",
  "sourceCommit": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "releaseZipSha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "manifestSha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
  "provenance": {
    "workflowPath": ".github/workflows/build.yml",
    "runId": 123,
    "runAttempt": 1,
    "buildJob": "build",
    "artifactId": 456,
    "transportSha256": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
  },
  "sourceIdentity": {
    "contractVersion": 1,
    "kind": "tag",
    "sourceClass": "ReviewedPr",
    "repository": "owner/application",
    "sourceCommit": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "reference": "v1.0.0-dev.2",
    "releaseId": "v1-0-0-dev-2",
    "channel": "DEV",
    "orderingKind": "SemVer",
    "sequence": 1000000000002,
    "tag": "v1.0.0-dev.2",
    "integrationBranch": "master",
    "integrationCommit": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
  }
}
```

For integrated tagged source use `sourceClass=IntegrationTag`. For snapshots use `kind=snapshot`, `sourceClass=ProtectedBranch`, `reference=refs/heads/<branch>`, `tag=null`, `channel=DEV`, `orderingKind=Snapshot`, `sequence=provenance.runId`, and `releaseId=dev-<runId>-<first12Commit>`. `integrationCommit` is the authenticated GitHub comparison's merge-base witness; it is the source itself when that source is already in integration history. It remains stable when unrelated protected commits advance the branch. `integrationBranch` must exactly match standing policy for every source class.

The [verified-release schema](../schemas/verified-release.schema.json), [source identity schema](../schemas/source-identity.schema.json) and installed validators define exact shapes and semantic matching. The tag-derived release ID is required by the new source contract; legacy schema-1 evidence retains application-chosen safe IDs. Package application/release/source and producer workflow/run/attempt/job must exactly match evidence. New shared workflows additionally require package contract 2.

## Platform verification and privilege boundary

The reusable workflow obtains GitHub job OIDC identity directly from the platform endpoint, checks its immutable `job_workflow_ref`/`job_workflow_sha`, and checks out only that shared revision. It verifies the caller repository, protected caller workflow/configuration bytes, approved shared pin, source eligibility, exact successful producer run/job/attempt and artifact identity. The hosted admission job verifies bytes before routing; the privileged job repeats checks after queueing and download and rejects changed routing configuration.

The Actions artifact name is `clc-package-<fullSourceCommit>-<runId>-<attempt>`. It contains only `release.zip`. The verifier checks the service transport SHA-256 before extracting that package, then verifies its complete manifest/inventories and provenance. The qualified artifact may come from the shared conventional build or an application's existing CI; qualification remains defined by that protected producer. Optional `producer.jobName` binds the exact REST job display name for reusable jobs, while package `build.job` retains its safe identifier.

The privileged runner checks the independently installed distribution before importing the exact active module. It supplies a unique inbox package/evidence pair and the configured standing-policy selector. The installed module performs no GitHub API calls. It checks its elevated identity and protected authority under the canonical lock; it cannot distinguish trusted and malicious code running as that same administrator. The direct platform handoff and external [runner/environment restrictions](github-setup.md) are necessary trust assumptions.

Application artifacts cannot select privileged executable orchestration. Only declared hooks and a distinct planning entry point may execute, and only under separately protected hook policy and verified source/channel eligibility. They run elevated without sandboxing. `ValidateOnly` requires an explicitly admitted planning entry point and read-only planning authorization; the label cannot prove arbitrary PowerShell is side-effect-free. Planning does not stop/start IIS, replace managed files, run ordinary deployment hooks or publish current deployment state. See [deployment/recovery](deployment.md).

## Protected authority and retained evidence

Admission creates a generated exact approval only after clean state, successful baseline, protected policy scope, exact bytes and ordering verify. Schema 3 `admission` retains `standingAuthorizationId`, exact policy SHA-256, reference in `tag`, exact verified-evidence SHA-256, and `sourceIdentity`. Semantic tags also retain an immutable target/lineage/tag/source binding. Snapshot approvals bind each exact source/build without freezing the mutable branch name.

Original evidence bytes remain at `approvals/standing/<approvalId>.verified.json`, exact package bytes at `inbox/<approvalId>.zip`, and the exact approval at `approvals/<approvalId>.json`. No record is overwritten. Equivalent identity JSON formatting reuses the original evidence. Interrupted `standing/<targetId>.pending` admission and unresolved lifecycle journals refuse ordinary retry. Preserve all material for independent reconciliation.

Deployment returns `Deployed` (or legacy `NoOp`) with attempt, target/release/source, actual toolkit identity, current generation and pool/worker observations. Planning returns `Planned` and leaves current generation unchanged. Stable `Clc.*` failures retain concrete operator instructions. Success requires the applicable durable terminal evidence; inspection or HTTP 200 alone does not establish deployment readiness.

Revocation remains effective on direct generated-approval retries. Exceptional recovery additionally needs a matching independent schema-1 `RecoveryApprovalId`; standing policy never authorizes it. External-state uncertainty must be reconciled explicitly, and file recovery does not imply database compatibility or rollback. No live consumer or Windows Server 2022/IIS qualification is established by these contracts or offline tests.

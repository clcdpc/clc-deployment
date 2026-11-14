# Standing authorization for shared releases

Infrastructure may enable routine releases for one established target under a protected standing policy. The shared [GitHub workflows](shared-release-orchestration.md) independently verify source eligibility, producer run/job/attempt, artifact ownership and downloaded bytes. The installed toolkit then creates an exact approval under the canonical machine/pool lock and uses the existing IIS engine. Release publication never authorizes deployment.

The four exports remain unchanged. Existing exact manual approvals need no standing policy. GitHub API access stays outside the installed module; no signing service, privileged consumer checkout or application-bundled engine is introduced. See the [host integration contract](verified-workflow-integration.md), [GitHub prerequisites](github-setup.md) and [deployment/recovery rules](deployment.md).

## Independent infrastructure setup

Install and pin an independently authenticated compatible toolkit, enroll the dedicated target, and complete a successful independently approved baseline. Infrastructure separately writes `approvalCatalogRoot/standing/<standingAuthorizationId>.json`, preserving protected ownership, structural ACLs and effective runtime isolation. Deployment never creates or enables that policy. The elevated deployment administrator remains procedurally trusted; NTFS and hashes do not contain that account.

Use distinct DEV, Test and production targets, environments and policies. Standing authority cannot enroll a host, establish the first baseline/cutover, change the toolkit, authorize downgrades or authorize exceptional recovery. See the [standing schema](../schemas/standing-authorization.schema.json). Schema 1 retains its existing tagged DEV/production scope. New schema 2 adds the exact `sourcePolicy` object:

```json
"sourcePolicy": {
  "integrationBranch": "main",
  "allowUnmergedDevTags": true,
  "allowSnapshots": true,
  "allowTestTags": false
}
```

The policy still binds application, target, environment, channel, repository, producer workflow/job, lineage and independent infrastructure authority. A schema-2 policy requires schema-2 verified evidence; legacy evidence cannot omit the new source checks. Executable hooks require their own separately protected authorization described in [contracts](contracts.md); neither these source flags nor a valid ZIP hash enables hooks.

## Supported source and ordering rules

| Source | Classification and admission |
| --- | --- |
| `vMAJOR.MINOR.PATCH-dev.N` | DEV; `IntegrationTag` in protected master history, or explicitly enabled `UnmergedDevTag` outside it |
| `vMAJOR.MINOR.PATCH-beta.N`, `-rc.N` | ArtifactOnly; package/publication without automatic IIS admission |
| `vMAJOR.MINOR.PATCH` | Production; separately enabled production target and standing authority |
| `vMAJOR.MINOR.PATCH-test.N` | Test; requires explicit test-tag policy and Test target/channel |
| `refs/heads/<integrationBranch>` | DEV snapshot; explicit snapshot policy, verified protected-branch source and authenticated producer-run ordering |

Creating and pushing a valid DEV version tag authorizes that exact release through GitHub repository permissions and tag creation controls. With `allowUnmergedDevTags=true` in both protected consumer configuration and host standing policy, an exact same-repository commit outside master needs no associated PR or formal GitHub review. A PR may be draft, closed or advanced beyond the tagged commit, and its branch may be unprotected or deleted. Master (the actual configured `integrationBranch`, such as `main`) must remain protected. The source must retain identical trusted workflows, configuration and declared supporting files. The shared verifier checks the current tag object and full source commit, exact successful producer and artifact/package identity, then repeats eligibility after privileged queueing and download. A qualifying tag push can proceed unattended; no additional manual release approval gate is needed. Independent host and hook authorization still apply.

SemVer ordering uses the existing bounded numeric tag sequence; `Test-ClcRelease -ReleaseTag` exposes classification without authority. Snapshots use authenticated producer `runId`, with release ID `dev-<runId>-<first12SourceCommit>`. Their sequence is separate from SemVer: switching ordering kind within an automated lineage refuses. A separately approved manual baseline is required to establish another ordering scheme. Protect integration history against force pushes/deletion; run ordering is not a Git history rollback detector.

Automatic snapshots that have been superseded by the current integration head are skipped. Explicit redeployment uses protected `workflow_dispatch` and independently checked repository write authority; it still must pass source eligibility, monotonic host ordering and every approval check. A rerun retains its original run ID; it does not make an older snapshot newer.

A later run, or later attempt of the same run, can rebuild the same immutable tag/source with new package bytes. Changed bytes for the same run/attempt, moved tags and older builds refuse. A fresh observation that an `UnmergedDevTag` source is now integrated into master can be admitted for the same run only when the exact source/reference/release ID, full provenance, ZIP and manifest bytes match. Current trusted configuration and workflow files must still match; after deliberate policy, producer or shared-pin changes, a historical tag may need separately reviewed repinning or new exact authority. No historical policy registry is maintained.

## Admission, interruption and revocation

Schema-2 evidence produces a schema-3 exact approval containing the verified source identity. Existing schema-1 evidence/policy still produces the legacy schema-2 approval. All generated approvals bind exact standing-policy bytes, target/source/build/artifact/package identity and retained evidence. Equivalent JSON formatting preserves the first admitted evidence. Tag/source bindings are immutable per target/lineage; snapshots do not bind a mutable branch name to one commit.

A durable `standing/<targetId>.pending` intent precedes approval/catalog/inbox effects. Interrupted admission retains that intent and blocks ordinary deployment until independent reconciliation. After admission, the existing lifecycle journal blocks unresolved attempts. Never delete an intent, lock or journal to retry.

Package contract 2 uses the full deployment cycle on every routine deployment, including identical releases: applicable hooks rerun and IIS stops/starts. Legacy package contract 1 retains its tested healthy NoOp behavior in the same engine. Shared reusable workflows require package contract 2. Hooks own their idempotency; external mutation uncertainty remains sticky and requires explicit reconciliation or recovery.

Disabling, removing or byte-changing standing policy revokes its generated approvals, including direct `-ReleaseApprovalId` retries. Fence policy changes against active processes holding protected handles. Retain prior approvals, packages, manifests and attempts; policy replacement does not rewrite history.

Generated approvals never authorize exceptional recovery. Recovery of a selected generated release requires a matching independent schema-1 `RecoveryApprovalId`, even after standing revocation. It also requires compatible configuration, approved retained bytes and proven helper quiescence. File recovery never establishes database rollback safety. Actual Windows Server 2022/IIS, independent-identity enforcement, runner admission and consumer adoption remain **NOT RUN**.

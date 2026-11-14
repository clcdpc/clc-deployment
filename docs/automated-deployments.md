# Tag-authorized routine deployment

Infrastructure can authorize successive releases for one enrolled target without writing a manual approval for each version. The installed toolkit authenticates a signed release receipt against that protected standing policy, publishes a create-new exact-byte approval, and calls the existing deployment engine. Inspection, a tag, a ZIP hash, CI success and an unsigned receipt still grant no execution authority.

This extends the exact-approval path at baseline [a3a94cd26daa583d392f73e99e56872876a88467](https://github.com/clcdpc/clc-deployment/tree/a3a94cd26daa583d392f73e99e56872876a88467). It adds no deployment service, enrollment operation, release downloader, application build engine or automatic recovery. Actual Server 2022/IIS and independent-identity qualification remain **NOT RUN**.

## Tag contract shared with ssrs-web

Use the independently pinned toolkit on the isolated build/admission runner:

```powershell
$tag = Test-ClcRelease -ReleaseTag $githubTag
# tag, releaseId, channel, releaseSequence, authorizedForDeployment=false
```

| Tag | channel | Intended action |
| --- | --- | --- |
| `vMAJOR.MINOR.PATCH-dev.N` | `DEV` | Produce release; request the independently enabled DEVWEB target |
| `vMAJOR.MINOR.PATCH` | `Production` | Produce release; request the independently enabled production target |
| `vMAJOR.MINOR.PATCH-beta.N` | `ArtifactOnly` | Produce artifact only |
| `vMAJOR.MINOR.PATCH-rc.N` | `ArtifactOnly` | Produce artifact only |

CLC owns classification and eligibility. Consumers use this result to route jobs through an explicit infrastructure-reviewed channel-to-target map; do not implement a second tag parser. DEVWEB is a consumer environment name, not a hardcoded hostname. The protected policy binds the exact target and its actual environment label, independently of `runtimeEnvironment` (which can be Production on DEV).

Tags are case sensitive, have no leading numeric zeroes or build metadata, and bound major/minor/patch to 0..9999 and N to 1..9998. `releaseId` is the tag with dots replaced by hyphens, including the initial `v`. Sequence is `(((major*10000 + minor)*10000 + patch)*10000 + ordinal)`, where ordinal is N for prereleases and 9999 for stable. Use the returned sequence and an infrastructure-selected lineage in the initial exact baseline approval. DEV and production have separate policies/targets and may have separate lineages. Routine admission never switches lineage or authorizes a downgrade. A stable version sorts after its dev iterations; a higher patch/minor/major sorts numerically.

## Infrastructure setup and revocation

Confirm that the consumer can generate GitHub artifact attestations before selecting this integration. As checked November 13, 2026, current GitHub Free, Pro and Team plans support attestations only for public repositories; private/internal repositories require eligible GitHub Enterprise Cloud access. Legacy Bronze/Silver/Gold plans do not support them. The API reports **ssrs-web public** and **polaris-oidc private**. polaris-oidc therefore needs public visibility, eligible Enterprise Cloud access, or a separately approved alternative before using this path. This task changes no visibility, plan or signing system. Until that prerequisite is satisfied, leave standing deployment disabled and retain independent exact approvals; unsigned receipts grant no authority. See [GitHub's availability requirements](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations).

First separately install/activate a compatible reviewed toolkit, enroll the target, complete any first cutover and deploy an independently approved baseline successfully. Standing authorization cannot initialize an empty or unresolved target. Preserve all existing state and approvals.

Provision an infrastructure-owned `standing` directory below the existing protected `approvalCatalogRoot`. Publish `<standingAuthorizationId>.json` using the strict [schema](../schemas/standing-authorization.schema.json). The [synthetic fixture](../tests/Fixtures/standing-authorization.json) illustrates shape only and authorizes nothing. No command creates, updates or enables standing policies.

| Policy field | Binding |
| --- | --- |
| family/version/kind | `clc-file-iis-v1` / 1 / `standing-authorization` |
| standingAuthorizationId, enabled | Safe selector and explicit enable/revoke switch |
| targetId, applicationId, environmentName, channel | One existing target/application/environment and DEV or Production eligibility |
| sourceRepository, sourceRepositoryId, sourceOwnerId | Exact GitHub.com owner/repository and immutable numeric repository/owner identities (decimal strings) |
| producer.repository, workflowPath, sourceCommit | Reviewed reusable signing workflow at an exact full commit, called using that commit |
| producer.buildWorkflowPath, buildJob | Consumer caller workflow and build job recorded in the release manifest |
| lineageId | Existing baseline lineage; no automatic lineage reset |
| verifier | Independently installed GitHub CLI **2.97.0** executable path/SHA-256 and custom Sigstore trusted-root path/SHA-256 |
| authorization | Distinct admitted infrastructure authoritySid, nonsecret reference and approvedUtc |

Authenticate the CLI and trusted roots independently before enabling policy. The [reviewed Windows x64 CLI pins](../tools/automation-verifier.lock.json) record the official release archive, source commit and extracted executable hashes; use those authenticated bytes when assembling the protected policy. The toolkit never downloads or upgrades them. Both files and their ancestors must satisfy protected-resource owner/ACL/path checks; neither runtime nor an individual deployment SID gets protected write ACEs. Obtain roots through the independently trusted CLI's `gh attestation trusted-root`, review their accepted signing identities and validity coverage, and pin the exact resulting JSONL bytes. A custom trusted root prevents caller-selected roots or mutable trust-cache contents from becoming authority. Retain roots with evidence and rotate them through an independently authorized policy update. An expired/unusable root or verifier failure rejects admission. Existing manual deployments do not need these new files or directory.

The shared elevated deployment administrator can physically override host controls. Independent approval remains procedural against that account; these checks do not claim administrator containment. Ordinary CI and runtime processes must lack protected catalog, verifier, toolkit and ancestor replacement rights. Infrastructure must audit this under actual identities before activation.

Disable the standing record (`enabled=false`), remove it while retaining infrastructure evidence, or replace its bytes under a fenced infrastructure change to stop routine use. Generated approvals pin its exact bytes and recheck it on every ordinary deployment, including `-ReleaseApprovalId` retries. Re-enabling identical bytes restores that authority; policy replacement does not silently reauthorize old receipts. Previously deployed generated releases remain usable as historical backup/compatibility material. Independently authorized explicit recovery does not require an enabled standing policy. Exact approval revocation retains its existing effect.

## Trusted producer and signed receipt

Use the implemented [reusable producer](../.github/workflows/clc-receipt-producer.yml), pinned to a reviewed full commit in both the caller and protected policy. It runs on GitHub-hosted Windows runners without deployment credentials and accepts **no workflow inputs or secrets**. The workflow controls checkout of the authenticated tag commit, a fixed application-owned build entry point, successful build dependency, immutable upload selection, packaging inspection and receipt construction. The build job has contents-read permission without OIDC/attestation permission. A fresh signing job runs no application code, constructs the predicate itself and signs only after build success. It cannot sign caller-supplied predicates, artifact paths/digests, source identities or arbitrary command inputs. Application code and build outputs must never execute on the privileged runner during admission.

### Fixed application build boundary

The exact tagged source supplies `.clc/build.ps1` and `.clc/receipt.json`. The script is the application's release build and required validation gates, under the same protected-source/tag review policy as its existing build system. It must throw/exit nonzero on any failed gate. Do not merely copy an artifact from an earlier caller job. The producer invokes this fixed file after checkout; there is no configurable script path, callback input or build framework. It provides:

| Environment | Required use |
| --- | --- |
| `CLC_TOOLKIT_MANIFEST` | Exact producer-pinned packaging/tag module; application dependency/toolchain provisioning remains application-owned |
| `CLC_RELEASE_ID` | CLC-classified tag releaseId; embed this in the application and package |
| `CLC_RELEASE_WORKFLOW`, `CLC_RELEASE_JOB` | Authenticated caller workflow path and fixed `build` job for manifest.build |
| `GITHUB_REPOSITORY`, `GITHUB_SHA`, `GITHUB_RUN_ID`, `GITHUB_RUN_ATTEMPT` | Actual source/build facts, never dispatch parameters |
| `CLC_RELEASE_DIRECTORY` | Produce exactly `release.zip` here using New-ClcRelease; keep publish/metadata inputs in disjoint directories |

The map contains exactly `applicationId` and `targets`, with safe target IDs for `DEV`, `Production`, `ArtifactOnly`. Example: `{"applicationId":"ssrs-web","targets":{"DEV":"ssrs-web-dev","Production":"ssrs-web-production","ArtifactOnly":"ssrs-web-artifact-only"}}`. Artifact-only signatures do not make beta/RC tags deployable; the toolkit still refuses admission. The signing job reads this fixed file as data at the authenticated source SHA, inspects the complete package, rejects mismatched application/release/source/workflow/job/run/attempt, obtains the numeric artifact ID and service transport SHA-256 from GitHub for this exact run/attempt, and constructs the strict predicate. No application-generated provenance file is accepted.

Source review remains essential: a trusted producer authenticates the exact build source and cannot prove that application code or its declared gates are safe. Infrastructure must protect version tags and approve the consumer's source eligibility, `.clc` files and build gates. Changing the producer or its packaging pin requires independent review and a new exact policy pin. The repository's own `.clc` files are explicitly restricted to synthetic qualification tags and cannot build a consumer or toolkit release.

### ssrs-web integration example

The following caller replaces the hosted job boundary only after the compatible toolkit and consumer changes are separately approved. Pin the same exact producer revision in standing policy; do not use a branch or version alias:

```yaml
on:
  push:
    tags: ['v*']
permissions:
  contents: read
jobs:
  release:
    uses: clcdpc/clc-deployment/.github/workflows/clc-receipt-producer.yml@c61588a40c357d478f240d534f1a09c9eb8c0a9e
    permissions:
      contents: read
      actions: read
      id-token: write
      attestations: write
```

Practical inspection of [ssrs-web PR #1 at cdba54d0a0dff2f8d0bef4c0c7adb81055cd4ac7](https://github.com/clcdpc/ssrs-web/tree/cdba54d0a0dff2f8d0bef4c0c7adb81055cd4ac7) found a compatible separation between hosted release production and protected-master deployment admission. Its existing locked builds, source-eligibility checks, packaging tests and application tests can be invoked by `.clc/build.ps1`; retain those gates. This is **not drop-in compatibility**: its Build-PortalRelease context currently requires job `release`, derives run-based release IDs and uses the published beta.3 pin. The consumer task must adopt `build` manifest identity and tag-derived compiled/package releaseId, update its independently verified toolkit pin, retain source eligibility/tag-movement checks, acquire the separate receipt, and replace the existing fail-closed `Invoke-SsrsToolkitAutomaticDeployment` adapter with the documented Invoke call. Retain separately administered setup tooling outside the package. No ssrs-web files were modified or tests claimed here.

The immutable outputs are `clc-package-<runId>-<attempt>` containing `release.zip`, and `clc-receipt-<runId>-<attempt>` containing `<releaseId>.sigstore.json` plus the non-authorizing audit copy `predicate.json`. Verify acquisition/service digests on the trusted consumer, rename the inner ZIP to `<releaseId>.zip`, and place only that ZIP and bundle in the existing target inbox. There is no consumer approval writer or additional authorization mechanism. The protected policy's buildWorkflowPath is `.github/workflows/release.yml` and buildJob is `build` for this example.

The producer:

1. Builds the exact tagged source and packages it using `New-ClcRelease`. Set metadata.releaseId from `Test-ClcRelease -ReleaseTag`; keep the existing ASP.NET Core validator/readiness/package contracts. Set source/build facts from the authenticated GitHub context, not dispatch strings or application output.
2. Uploads the exact release ZIP as an immutable Actions artifact. Retains its upload-produced numeric artifact ID and transport SHA-256. Upload the receipt bundle separately to avoid a self-referential transport hash.
3. Constructs exactly the [automated-provenance predicate](../schemas/automated-provenance.schema.json): family/version/kind; targetId/applicationId/releaseId/tag; sourceRepository/sourceCommit; releaseZipSha256/manifestSha256; existing provenance.workflowPath/runId/runAttempt/buildJob/artifactId/transportSha256. The target comes from the reviewed channel-to-target mapping. All hashes come from the actual package/upload; all run facts come from the current producer context.
4. Uses an independently reviewed, full-SHA-pinned `actions/attest` custom predicate with `subject-path` selecting the exact release ZIP, `predicate-type` **`https://clcdpc.github.io/clc-deployment/attestations/release/v1`**, and `predicate-path` selecting those UTF-8 JSON bytes. The signing job needs the minimum `id-token: write` / `attestations: write` permissions; publishing is isolated from privileged deployment. Retain its Sigstore bundle and exact source/run/attempt/artifact observations.

The toolkit invokes only the protected CLI, with a cleared environment, local bundle, explicit github.com repository, exact reusable signer workflow/commit, exact source tag/commit, GitHub OIDC issuer, denial of self-hosted signers, custom protected root and exact predicate type. It bounds output to 4 MiB and execution to 30 seconds, requires successful exit and proves verifier exit before admission. Raw verifier output/errors are not logged.

It then checks GitHub certificate extensions, independently of the signed predicate: exact repository/owner numeric IDs, repository URL/source commit/tag ref, signing workflow URL at the pinned commit/digest, push event, github-hosted runner, caller workflow at the tag ref and run/attempt URL. The strict signed predicate must match that run, package source/build facts, target, tag, ZIP and exact manifest bytes. Missing/ambiguous/extra predicate fields, failed signatures, fabricated certificate facts and mismatches refuse before publishing authority or executing application code.

The custom predicate is deliberately small. Standard provenance alone does not bind the toolkit manifest, intended target and upload identity; accepting unsigned JSON after checking an artifact hash would not authenticate a producer. See the [GitHub custom-attestation guide](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations) and the reviewed [CLI verifier source](https://github.com/cli/cli/blob/55dbb4dc6b7edb10b48e3d7fc5bccd32318d1b55/pkg/cmd/attestation/verify/verify.go). Signed predicate contents remain assertions by the pinned trusted producer, which must construct them itself. An attacker controlling that producer's signing context can authorize malicious output within policy scope.

## Deployment integration contract

After trusted hosted admission, the independently admitted privileged workflow downloads the selected immutable artifact/bundle as data, checks the service transport digest during acquisition and places these two files in the existing protected target inbox:

```text
<releaseId>.zip
<releaseId>.sigstore.json
```

No caller archive, policy, executable, journal or approval path is accepted. The signature authenticates the exact inner ZIP. Artifact ID/transport digest are signed producer audit facts, not alternative caller-supplied authorizers. Retain the original service transport/archive provenance with workflow evidence; do not claim that the inner ZIP hash is the transport hash.

Import the independently installed toolkit in a fresh trusted process:

```powershell
Invoke-ClcIisDeployment -TargetId $infrastructureTargetId `
    -StandingAuthorizationId $infrastructureStandingId -ReleaseTag $tag
```

There are still four exports. Invoke's `Automated` parameter set has only TargetId, StandingAuthorizationId and ReleaseTag; it cannot combine with ReleaseApprovalId, AllowDowngrade or Reason. Results remain the existing Deployed/NoOp result, including exact release/source/toolkit identity and actual pool/worker observations.

Admission takes the existing machine/pool lock and rejects unresolved lifecycle state before receipt processing. It requires a completed current baseline and the same lineage, and rejects lower sequences. The approval ID is deterministic: `auto-` plus the first 59 lowercase SHA-256 hex characters of UTF-8 `targetId + NUL + releaseId`. The complete record identity is compared on retry; a collision or changed source, bytes, receipt, artifact, policy or release facts never overwrites an existing approval. Identical retry reuses the record and the engine still verifies installed bytes/configuration/readiness before NoOp. A later release cannot be replaced by an older retry.

A durable create-new `standing/<targetId>.pending` record precedes copying verified ZIP bytes to `<approvalId>.zip` in the inbox and atomically publishing `<approvalId>.json` in the protected approval catalog. No application/IIS effects occur during admission. Interrupted publication retains intent/material and blocks routine automated authority for that target, including different releases; infrastructure must reconcile under a fenced maintenance change. Unknown destination files are never overwritten or deleted. Failure after admission follows the existing phase journal, backup, stop, readiness and explicit recovery rules. Admission alone never reports deployment success.

## Compatibility and exceptional recovery

Manual schema-1 exact approvals and their command syntax are unchanged. Host policy, targets, package/ASP.NET Core contracts, journal v2, current state and backups retain their formats. No existing record is migrated. Automatically generated release approvals use schema **2**, with the schema-1 fields plus `admission` (standingAuthorizationId/standingAuthorizationSha256/tag/bundleSha256). Older toolkits reject that new format; keep an independently installed compatible toolkit for any state referencing it. Toolkit rollback is a separately reviewed infrastructure action.

Standing authority permits routine deployment only. First enrollment/installation/cutover, empty baseline deployment, toolkit upgrades and exceptional recovery retain separate authorization. Generated approvals cannot use AllowDowngrade, including through their saved exact selector. To recover a selected automatically admitted release, infrastructure independently creates a normal schema-1 exact approval under a **new** ID, matching target/application/release/source/lineage/sequence/hashes/provenance of that generated approval. Preserve the original approval bytes and journal snapshots. No historical ZIP is required for recovery.

```powershell
Restore-ClcIisDeployment -TargetId $targetId -AttemptId $latestAttempt `
    -Mode RestorePrevious -Reason $incidentReference -RecoveryApprovalId $independentExactApprovalId
```

RecoveryApprovalId is optional for existing manual releases and required when the selected recovery release has a generated approval. It is checked before recovery evidence or application effects and held/rechecked throughout effects. RestorePrevious checks the previous release; AcceptCandidate/RestoreEmpty check the candidate. The original generated approval must still be enabled, but its standing policy may be revoked. This grants no automatic recovery and changes none of the helper-quiescence, backup, configuration, readiness or failure requirements. File recovery never implies database rollback safety.

## Privileged runner admission and rollout

Keep the privileged workflow on an infrastructure-reviewed protected branch (or pinned infrastructure reusable workflow), never on a tag/PR checkout. A hosted `workflow_run` admission job can select a completed producer and then invoke that trusted deployment path. It may pass only release selectors, never scripts or executable paths. Runner-group selected-workflow restrictions and environment/branch controls must prevent contributor workflows from acquiring the privileged runner. Use independent DEV and production activation/scope controls and `cancel-in-progress: false`; the host lock remains authoritative.

Protect version-tag creation, update and deletion with infrastructure-reviewed release permissions/rules. The pinned producer must enforce the application's approved source/branch policy before signing; a tag is a release selector, not proof of source review. It must refuse PR/reusable-workflow caller inputs that could change checkout or substitute artifacts. The host authenticates the certificate's exact tagged commit and trusted signer, while source review and permitted tag creation remain infrastructure/consumer responsibilities.

Standing policy replaces per-version host approval for the authorized scope. Environment reviewer gates can remain, or infrastructure can separately approve unattended operation with available externally enforced runner/workflow controls. Do not silently remove existing gates or treat repository variables/YAML conditions as authority. See [GitHub setup](github-setup.md), [installation](installation.md), [enrollment](host-enrollment.md), and the [separately authorized real-host pilot](iis-verification.md). No live GitHub/runner/environment/host settings are changed by this implementation. ssrs-web implementation starts only after this change is merged and a compatible toolkit release is independently published and approved; this task does not modify that repository.

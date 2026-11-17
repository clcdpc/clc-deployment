# CLC Deployment Setup Guide

This is the authoritative setup sequence for applications using the shared tag workflow. Set up each deployment target independently. After setup, an authorized developer selects a commit, creates its version tag and pushes it. GitHub builds, tests, packages, publishes and then deploys automatically. DEV can release an unmerged commit containing application, workflow, script, configuration or shared-pin changes. Production must be in protected integration-branch history. Use `ssrs-web` below as an example and substitute your application's identity, repository and project paths. GitHub administration, independently authorized host setup and live acceptance are separate activities; this guide grants no host authority.

## 1. Establish naming conventions

Choose one stable lowercase `applicationId` of at most 53 characters (letters, digits and hyphens, starting with a letter or digit), for example `ssrs-web`. Derive these identifiers; keep DEV and Production separately scoped:

| Resource | DEV | Production |
| --- | --- | --- |
| GitHub environment | `ssrs-web-dev` | `ssrs-web-production` |
| Dedicated deployment runner label | `ssrs-web-dev` | `ssrs-web-production` |
| Host enrollment authorization ID | `ssrs-web-dev` | `ssrs-web-production` |
| Deployment target ID | `ssrs-web-dev` | `ssrs-web-production` |
| Standing authorization ID | `ssrs-web-dev` | `ssrs-web-production` |

These are distinct protected resources with the same derived identifier. GitHub names do not confer host authority. Consumer configuration version 2 derives routing from `applicationId`; no deployment-routing variables or redundant runner configuration are required.

Each target owns `%ProgramData%\clc-<target-id>\`: `Application`, `Config` (`application.json` and `deployment.json`), `Keys`, `Inbox`, optional `Logs`, and protected `Deployment`. DEV uses `clc-ssrs-web-dev`; Production uses `clc-ssrs-web-production`. Their bootstrap, immutable toolkit versions, active policy, approvals, enrollment evidence and locks/state all live inside their own `Deployment`. The target root is infrastructure owned so runtime writes in Keys/Logs cannot replace protected siblings. There is no shared installation, target registry or enrollment lock.

## 2. Restrict GitHub Actions

Open **Repository Settings > Actions > Policies > New policy > Restrict actors**, at `https://github.com/<owner>/<repository>/settings/actions/policies`. Name the native policy, set enforcement to **Active**, target **All workflows** in this repository and select authorized release developers. Include automation only when intentionally authorized to release. Leave **Restrict events** unconfigured: no event restrictions are required. Review effective inherited organization/enterprise controls. See [GitHub workflow execution policies](https://docs.github.com/en/actions/how-tos/administer/control-workflow-execution).

Tag creation is the deliberate release decision. The tagged commit can change executable workflows and shared pins, so release developers are trusted to authorize that code. Restrict actors controls workflow execution; it does not grant permission to create protected tags. CLC adds no actor allowlist, signature requirement, custom release approval or authorization service. If the policy is not exposed by read-only APIs, inspect it in GitHub; the optional checker reports CHECK MANUALLY.

## 3. Protect release tags

Open **Repository Settings > Rules > Rulesets > New ruleset > New tag ruleset** (`https://github.com/<owner>/<repository>/settings/rules`). Create two Active tag rulesets targeting `v*`:

- **Release tag creation:** enable **Restrict creations** and grant appropriately scoped **Always allow** bypass to the authorized release developers through native team/actor selection. An empty bypass list blocks all matching tag creation, including authorized releases; pull-request-only bypass cannot authorize tag creation.
- **Immutability:** separately enable **Restrict updates** and **Restrict deletions**, without routine release-actor bypass. Do not combine all three restrictions under the same creator bypass: that bypass would also allow moving or deleting existing tags.

Review inherited organization rulesets, include/exclude patterns and effective bypass permissions together. A creator must be permitted by every applicable creation restriction; bypass of one ruleset cannot override another. Confirm the designated creators' identities, team/role membership and repository permissions in GitHub. The optional checker reports CHECK MANUALLY where it cannot establish that effective arrangement, and NEEDS CONFIGURATION for proven blockers. See [GitHub's rule semantics](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets) and [rule layering](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets#about-rule-layering).

Separately, under **Repository Settings > General > Releases > Release immutability**, enable immutable releases (or verify owner-enforced immutability). **Both tag rulesets and Release immutability are required.** Rulesets govern creation and tag movement/deletion before publication; Release immutability protects canonical published assets. See [GitHub immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases).

Application publication creates a draft, uploads and verifies assets, publishes, then re-reads the final Release. Existing published Releases and race winners must also have matching source/tag/prerelease classification, exact assets and actual API Boolean `immutable=true`. False, missing, null or malformed evidence fails publication. A mutable published Release remains retained for operator inspection: the publisher never automatically deletes, replaces or repairs it. Enabling the repository setting alone does not prove an existing Release immutable. Publication failure blocks dependent deployment.

## 4. Protect master

In **Repository Settings > Rules > Rulesets** (or **Branches > Branch protection rules**), protect `master`: block force pushes, restrict deletion and retain the application's required CI status checks. Preserve existing application-specific PR review requirements. Use the repository's actual integration branch in configuration if it differs, and account for effective bypass.

Production requires a commit contained in this branch's history, including a historical commit rather than only HEAD. DEV requires neither integration nor PR metadata, PR approval, current PR-head equality, an open PR, or workflow/configuration equality with master. Individual PR branches need no extra protection for deployment.

## 5. Create deployment environments

Open **Repository Settings > Environments > New environment** (`https://github.com/<owner>/<repository>/settings/environments`). Create `ssrs-web-dev` and `ssrs-web-production`. For each, set **Deployment branches and tags > No restriction**, with no required reviewers, wait timers or additional deployment approval rules. Native actor/tag policies establish release authority; host standing authorization remains independent.

## 6. Register deployment runners

Open **Repository Settings > Actions > Runners > New self-hosted runner** (`https://github.com/<owner>/<repository>/settings/actions/runners`). Register each dedicated Windows x64 deployment runner with `self-hosted`, `Windows`, `X64` and its derived target label (`ssrs-web-dev` or `ssrs-web-production`). Repository-scoped runners are preferred and need no group. An organization-scoped runner works with those labels when its group grants the application repository access under **Organization Settings > Actions > Runner groups > Repository access**.

Shared deployment uses labels only. No exact protected-master workflow allowlist, routine per-PR runner change or GitHub variable is required. Keep ordinary PR/build/test/package/publication jobs on GitHub-hosted runners without deployment credentials. Reserve privileged runner access for authorized release code; do not run arbitrary contributor checkouts there. Deployment, validation and hooks execute elevated without sandboxing. See [GitHub setup boundaries](github-setup.md).

## 7. Configure the release workflow

Copy the [conventional example](examples/shared-conventional-build.yml) to `.github/workflows/build.yml`, or retain existing CI using the [prequalified example](examples/shared-prequalified-build.yml). Keep all required application qualification before packaging in the producer job. The [publication/deployment example](examples/shared-application-deploy.yml) shows the same single-workflow chain. It runs automatically from the tagged consumer commit:

```yaml
on:
  push:
    tags:
      - 'v*'
```

Copy [`.clc/release.json`](examples/shared-release.json), keeping **contractVersion 2**. Set `applicationId=ssrs-web`, the actual repository/integration branch, producer workflow path/job (and exact REST display name when needed), `requiredToolkitContractVersion=2`, and optional project/test-project paths. Replace every synthetic SHA in the workflow and `orchestration.sharedRevision` with the same reviewed immutable shared revision. The tagged commit may deliberately select a new shared revision before merging.

Keep `package -> publication -> deployment`: publication has `needs: package`; deployment has `needs: publication`. Failed/incomplete producer jobs cannot qualify, and failed publication skips deployment. Keep normal success-dependent behavior without `always()` or failure bypasses. Use `GITHUB_TOKEN` where sufficient; limit `contents: write` to publication jobs. No manual release dispatch or protected-master `workflow_run` consumer is used.

Do not restore removed `targets`, `trustedFiles`, consumer `sourcePolicy`, runner groups/labels, activation flags or `orchestration.deploymentWorkflowPath`. Host standing-policy source restrictions remain independently protected. Optional [application hooks](application-hooks.md) remain supported under separate host authorization.

| Tag | Source eligibility | Automatic result |
| --- | --- | --- |
| `v1.2.3-dev.1` | Any valid selected repository commit, including unmerged workflow/configuration/shared-pin changes | Build, package, publish, deploy DEV |
| `v1.2.3` | Contained in protected integration history | Build, package, publish, deploy Production |
| `v1.2.3-beta.1`, `v1.2.3-rc.1` | Integrated or unmerged repository commit | Build, package, publish only |

Unsupported tags fail validation. Verification binds tag/object/source, platform workflow identity, exact producer run/attempt and completed successful job, artifact ownership/identity, transport/package/manifest hashes, compiled `Clc.*` identity and approved builder/shared revision. The producer job may qualify while the overall workflow remains in progress. Source eligibility and identities are rechecked after queueing/download. Beta/RC uses workflow-only `ArtifactOnlyTag` evidence and cannot create a host verified-release handoff. See [orchestration](shared-release-orchestration.md) and [workflow integration](verified-workflow-integration.md).

## 8. Prepare deployment hosts

Infrastructure completes this ordered sequence under its own exact authorizations:

1. Provision Windows Server 2022, PowerShell 7, IIS/.NET/ANCM, TLS and required deployment/runtime identities, keeping one dedicated site/root application/pool and one worker.
2. Independently authenticate and provision the format-3 `Clc.Deployment` bootstrap in the target's `Deployment/bootstrap`, plus its protected enrollment authorization handoff. Use [installation](installation.md) for exact source/distribution/inventory verification before any import. Application artifacts cannot install or select host code. A real published renamed distribution is required before updating consumer release pins; historical `0.1.0-beta.3` has the old layout and cannot supply that pin. This implementation does not publish a replacement.
3. Provision protected external configuration, persistent keys and dedicated directories. Accounts, secrets, certificates, trust and components remain external to deployment.
4. Create target and host authorization records with derived identifiers and exact machine/config/bootstrap/toolkit/operation bindings.
5. Complete [host enrollment](host-enrollment.md): read-only Get/Plan, then separately authorized Apply for approved missing resources. Enrollment publishes the protected target after verification and changes only approved directories/ACLs and stopped IIS settings. Missing records with prior resources/state require reconciliation.
6. Complete a separately authorized successful initial deployment/baseline. Legacy cutover needs its own exact authority, an already Stopped/zero-worker pool and retained verified backup.
7. Establish protected target-scoped standing authorization after the successful baseline, as described below.
8. Verify routine application readiness and deployment behavior under separately authorized consumer/host scope using step 9 and the [IIS procedure](iis-verification.md).

After a successful independently approved baseline, infrastructure installs the protected target-scoped [standing authorization](automated-deployments.md) under the derived identifier. Bind the exact repository, producer workflow/job, channel, target and lineage. For DEV, schema-2 policy enables `allowUnmergedDevTags`; routine tag orchestration does not use snapshots. Configure separately protected hook scope if the application declares hooks.

Standing policy is established once and stays valid until revoked or changed. Each qualifying release receives an exact byte-bound approval through the installed toolkit. No human approval is needed for each routine tag. Host enrollment, initial baseline/cutover, toolkit changes, downgrades and exceptional recovery retain their existing independent authority. Recovery of generated releases needs an independent exact recovery approval; file recovery never establishes database rollback safety.

Host source/target validation, protected configuration/installed toolkit checks, monotonic release ordering, same-tag/downgrade safeguards, approval revocation, canonical locks, durable attempts, backups, readiness and validation remain enforced. Hook uncertainty additionally needs independent persistent-state compatibility/quiescence authority for recovery. Follow [deployment and recovery](deployment.md).

Every target independently pins its runtime `activeToolkit` in `Deployment/toolkit/policy/host-policy.json`. DEV can use version A while Production uses B. A separately authorized upgrade installs a new immutable version and explicitly activates only that target's next policy generation, retaining previous versions/history and recovery evidence. Build-time `orchestration.sharedRevision` remains independently pinned. Native known-folder resolution and authenticated derived target IDs select host paths; no path input or environment variable routes a deployment. Existing machine-wide installations need independently approved re-enrollment or migration; nothing automatically moves operational configuration, keys, logs or retained evidence.

## 9. Verify the setup

Under separately authorized consumer/host scope, verify DEV from an unmerged commit that changes workflow/configuration, then Production from protected master history. Retain exact source/run/attempt/job/artifact/package and readiness evidence. Complete the [IIS deployment/recovery procedure](iis-verification.md) before claiming host acceptance. The optional [GitHub setup checker](github-setup-check.md) is a read-only diagnostic and never a deployment gate.

| Exercise | Required observation |
| --- | --- |
| Integrated/unmerged beta/RC | Immutable canonical publication; no privileged deployment |
| Invalid tags or unauthorized native release-policy conditions | Rejection with no privileged effects |
| Failed/incomplete producer or wrong run/attempt/artifact/compiled identity | Rejection before publication/host handoff |
| Failed publication or mutable GitHub Release | No canonical publication success; dependent deployment skipped |
| Missing/revoked standing policy or incorrect target | Installed-host refusal before mutation; direct generated-approval retries respect revocation |
| Same-tag/order/downgrade conflicts | Existing host safeguards refuse incompatible identities/build order |
| Queued source/tag/configuration change | Fresh verification refuses changed identity or eligibility |
| Deployment failure and explicit recovery | Retained backups/attempts, actual pool/workers and independently approved compatible recovery |

Use [offline negative tests](testing.md) before live operation; their synthetic GitHub/IIS boundaries do not complete live acceptance. Scope disruptive/destructive checks separately. The checker retains three reporting states, seven default categories and four outputs; confirm unavailable actor/bypass facts manually.

## 10. Routine operation

The routine procedure is only creating and pushing the appropriate tag:

```powershell
git tag v1.2.3-dev.1 <exact-commit>
git push origin v1.2.3-dev.1
# For a commit contained in protected master history:
git tag v1.2.3 <exact-integrated-commit>
git push origin v1.2.3
```

`vN.N.N-dev.N` deploys DEV; `vN.N.N` deploys Production; `-beta.N` and `-rc.N` build/archive and publish without deployment. Existing numeric bounds remain enforced. Do not move/reuse a published tag. Failed build/test/package blocks publication; failed publication blocks deployment. The completed producer job qualifies while the overall workflow is running. Host ordering, standing revocation, locking, recovery and exact readiness remain required.

No manual dispatch, temporary policy change, per-PR exception, deployment reviewer or routing variable is required. Inspect retained publication evidence after a failure; conflicting canonical assets cannot be overwritten to repair it. For host failures retain all material and follow [explicit recovery](deployment.md#operator-procedure).

**Actual Windows Server 2022/IIS and independent-identity qualification remain NOT RUN.** Offline tests do not establish consumer or infrastructure acceptance.

# Deployment Setup Guide

Set up each application once. After setup, an authorized developer releases an exact commit by creating and pushing its version tag. GitHub builds, tests, packages, publishes and then deploys automatically. DEV can release an unmerged commit containing application, workflow, script, configuration or shared-pin changes. Production must be in protected integration-branch history.

## 1. Establish application ID

Choose one stable lowercase `applicationId` of at most 53 characters (letters, digits and hyphens), for example `example-app`. DEV uses `example-app-dev`; Production uses `example-app-production`. Each identifier names its deployment target, GitHub environment, dedicated runner label, host enrollment authorization and standing authorization. These are separate resources with the same identifier.

Install one tagged consumer workflow using the [conventional example](examples/shared-conventional-build.yml), or retain existing CI using the [prequalified example](examples/shared-prequalified-build.yml). Set the application/repository, project/test paths, integration branch and exact shared revision in [`.clc/release.json`](examples/shared-release.json). Replace every synthetic SHA with the same reviewed immutable shared revision. The three jobs belong in one workflow: `package`, `publication` with `needs: package`, and `deployment` with `needs: publication`. No deployment-routing variables, runner group or per-PR edits are required.

## 2. Configure Restrict actors

In **Repository Settings > Actions > Policies > New policy > Restrict actors**, create an Active native policy covering all workflows in the repository and select the developers and automation allowed to release. See [GitHub workflow execution policies](https://docs.github.com/en/actions/how-tos/administer/control-workflow-execution). Review effective organization/enterprise controls where applicable. Open `https://github.com/<owner>/<repository>/settings/actions/policies`.

Tag creation is the deliberate release decision. The tagged commit can change executable workflows and shared pins, so release developers are trusted to authorize that code. Restrict actors controls workflow execution; it does not grant permission to create protected tags. CLC adds no actor allowlist, signature requirement, custom release approval or authorization service. If the policy is not exposed by read-only APIs, inspect it in GitHub; the optional checker reports CHECK MANUALLY.

## 3. Protect release tags

Open **Repository Settings > Rules > Rulesets > New ruleset > New tag ruleset** (`https://github.com/<owner>/<repository>/settings/rules`). Create two Active tag rulesets targeting `v*`:

- **Creation:** enable **Restrict creations** and grant appropriately scoped native bypass to the designated release team/actors or trusted GitHub App, in a mode that permits tag creation. An empty bypass list blocks all matching tag creation, including authorized releases; pull-request-only bypass cannot authorize tag creation.
- **Immutability:** separately enable **Restrict updates** and **Restrict deletions**, without routine release-actor bypass. Do not combine all three restrictions under the same creator bypass: that bypass would also allow moving or deleting existing tags.

Review inherited organization rulesets, include/exclude patterns and effective bypass permissions together. A creator must be permitted by every applicable creation restriction; bypass of one ruleset cannot override another. Confirm the designated creators' identities, team/role membership and repository permissions in GitHub. The optional checker reports CHECK MANUALLY where it cannot establish that effective arrangement, and NEEDS CONFIGURATION for proven blockers. See [GitHub's rule semantics](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets) and [rule layering](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets#about-rule-layering).

Under **Repository Settings > General > Releases > Release immutability**, enable immutable releases (or verify owner-enforced immutability). The publisher preserves identical published assets and rejects conflicting bytes. See [GitHub tag rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/creating-rulesets-for-a-repository).

## 4. Protect master

In **Repository Settings > Rules > Rulesets** (or **Branches > Branch protection rules**), protect `master`, including required build checks and prevention of force pushes/deletion. Use the repository's actual integration branch in configuration if it differs.

Production requires ancestry in this branch, not equality with its latest files. DEV requires neither integration nor PR metadata, PR approval, current PR-head equality, an open PR, or workflow/configuration equality with master.

## 5. Create environments

Open **Repository Settings > Environments > New environment** (`https://github.com/<owner>/<repository>/settings/environments`). Create the derived DEV and Production environments. For each, set **Deployment branches and tags > No restriction**. Remove required reviewers and wait timers so the authorized tag runs automatically. Native actor/tag policies establish release authority; an environment's existence does not authorize a host.

## 6. Register deployment runners

Open **Repository Settings > Actions > Runners > New self-hosted runner** (`https://github.com/<owner>/<repository>/settings/actions/runners`). Register the dedicated Windows x64 deployment runner with `self-hosted`, `Windows`, `X64` and the derived target label. A repository-scoped runner needs no group. An organization-scoped runner works with those labels when its group grants the application repository access under **Organization Settings > Actions > Runner groups > Repository access**.

Shared deployment uses labels only. No exact runner-group workflow allowlist or GitHub variable is required. Keep ordinary PR/build/test jobs on GitHub-hosted runners without deployment credentials. Reserve privileged runner access for authorized release code; do not run arbitrary contributor checkouts there. See [GitHub setup boundaries](github-setup.md).

## 7. Prepare and enroll IIS hosts

Infrastructure prepares Windows Server 2022, PowerShell 7, .NET/ANCM, dedicated IIS site/root application/pool, deployment/runtime identities, TLS, protected external configuration and persistent keys. Install and verify the exact toolkit independently using [installation](installation.md); an application package never chooses or replaces it.

Follow [host enrollment](host-enrollment.md): read-only Get/Plan first, then Apply under exact independent machine/config/bootstrap/toolkit/operation authority using the derived identifier. Enrollment can provision only approved directories/ACLs and stopped IIS settings. Accounts, secrets, certificates, trust and components remain external. Initial baseline/cutover needs its existing independent authorization. This guide does not authorize real host operations.

## 8. Establish standing authorization

After a successful independently approved baseline, infrastructure installs the protected target-scoped [standing authorization](automated-deployments.md) under the derived identifier. Bind the exact repository, producer workflow/job, channel, target and lineage. For DEV, schema-2 policy enables `allowUnmergedDevTags`; routine tag orchestration does not use snapshots. Configure separately protected hook scope if the application declares hooks.

Standing policy is established once and stays valid until revoked or changed. Each qualifying release receives an exact byte-bound approval through the installed toolkit. No human approval is needed for each routine tag. Host enrollment, initial baseline/cutover, toolkit changes, downgrades and exceptional recovery retain their existing independent authority. Recovery of generated releases needs an independent exact recovery approval; file recovery never establishes database rollback safety.

## 9. Verify tag deployments

Under separately authorized consumer/host scope, verify DEV from an unmerged commit that changes workflow/configuration, then Production from protected master history. Retain exact source/run/attempt/job/artifact/package and readiness evidence. Complete the [IIS deployment/recovery procedure](iis-verification.md) before claiming host acceptance. The optional [GitHub setup checker](github-setup-check.md) is a read-only diagnostic and never a deployment gate.

The routine procedure is only creating and pushing the appropriate tag:

```powershell
git tag v1.2.3-dev.1 <exact-commit>
git push origin v1.2.3-dev.1
# For a commit contained in protected master history:
git tag v1.2.3 <exact-commit>
git push origin v1.2.3
```

`vN.N.N-dev.N` deploys DEV; `vN.N.N` deploys Production; `-beta.N` and `-rc.N` build/archive and publish without deployment. Existing numeric bounds remain enforced. Do not move/reuse a published tag. Failed build/test/package blocks publication; failed publication blocks deployment. The completed producer job qualifies while the overall workflow is running. Host ordering, standing revocation, locking, recovery and exact readiness remain required.

**Actual Windows Server 2022/IIS and independent-identity qualification remain NOT RUN.** Offline tests do not establish consumer or infrastructure acceptance.

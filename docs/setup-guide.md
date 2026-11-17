# CLC Deployment Setup Guide

Use this checklist for each application and target. GitHub administrators complete sections 1–7; infrastructure completes section 8 under independent host authorization. Application owners participate in verification. Examples use `ssrs-web`; substitute your repository and application values. Detailed procedures live in the linked runbooks.

## 1. Establish naming conventions

Choose a stable lowercase `applicationId`, at most 53 letters, digits or hyphens, beginning with a letter or digit. Derive the two identifiers once:

```text
DEV:        ssrs-web-dev
Production: ssrs-web-production
```

Use the corresponding identifier for the target, GitHub environment, runner label, enrollment authorization ID and standing authorization ID. These remain distinct resources. Consumer configuration version 2 derives routing from `applicationId`.

Each host target owns `%ProgramData%\clc-<target-id>\`, including `Application`, `Config`, `Keys`, `Inbox` and protected `Deployment`. DEV and Production have separate installations and approvals, even on one server.

## 2. Restrict GitHub Actions

In the application repository:

1. Open **Settings > Actions > Policies**, create a policy and select **Restrict actors**.
2. Set enforcement to **Active**, scope to **All workflows**, and allow the authorized release developers. Include automation identities only when deliberately authorized.
3. Leave **Restrict events** unconfigured for this setup. Review inherited organization/enterprise policies.

Success: the effective repository-wide policy admits the intended release actors. Tag creation is their release decision, including executable code at an unmerged DEV commit. See [GitHub policy details](github-setup.md#effective-policies).

## 3. Protect release tags

Under **Settings > Rules > Rulesets**, create two **Active** tag rulesets targeting `v*`:

1. **Creation:** enable **Restrict creations**; grant authorized release developers **Always allow** bypass through native actor/team selection.
2. **Immutability:** enable **Restrict updates** and **Restrict deletions**, without routine developer bypass.
3. Under **Settings > General > Releases**, enable **Release immutability**, or verify owner-enforced immutability.

Success: designated developers can create tags, cannot routinely move/delete them, and new published Releases report Boolean `immutable=true`. Check inherited rules and bypasses using [GitHub setup](github-setup.md); tag protection and Release immutability are separate requirements.

## 4. Protect master

Under **Settings > Rules > Rulesets** or **Branches**, protect `master`: require the application's actual CI checks, block force pushes and restrict deletion. Retain existing PR review requirements.

Success: required checks gate integration and Production sources belong to protected master history. DEV tags may select unmerged commits without PR approval or workflow/configuration equality with master. Individual PR branches need no additional deployment protection.

## 5. Create deployment environments

Under **Settings > Environments**, create both derived identifiers. For each, choose **Deployment branches and tags > No restriction**, with no required reviewers, wait timer or additional deployment approval rules.

Success: tagged deployment jobs can select their target environment without another GitHub approval. Host authorizations are configured separately in section 8.

## 6. Register deployment runners

Under **Settings > Actions > Runners > New self-hosted runner**, register dedicated Windows x64 deployment runners. Give each `self-hosted`, `Windows`, `X64` and its target-specific label. Repository runners need no runner group; organization runner groups must grant this repository access.

Success: each label selects its intended runner. Keep ordinary PR/build/test/package/publication jobs on GitHub-hosted runners without deployment credentials. Privileged deployment, application validation and hooks execute elevated without sandboxing. See [runner boundaries](github-setup.md#privileged-runners).

## 7. Configure the release workflow

In the application repository:

1. Keep a working application-owned release workflow. For new integration, adapt the [conventional example](examples/shared-conventional-build.yml), or add the [prequalified packaging tail](examples/shared-prequalified-build.yml) after existing application qualification.
2. Configure `push.tags: ['v*']` and preserve `package -> publication -> deployment` through success-dependent `needs`.
3. Set [`.clc/release.json`](examples/shared-release.json) to contract version **2**: actual application/repository, `integrationBranch=master`, producer workflow path/job and optional exact REST job display name. Keep `requiredToolkitContractVersion=2` and application project paths where applicable.
4. Replace synthetic shared SHAs in workflow calls, packaging and `orchestration.sharedRevision` with the same reviewed full immutable revision. Allow `contents: read`, `actions: read`, `id-token: write`; grant `contents: write` to publication only. Preserve application-specific build permissions.

Success: eligible tags produce a qualified `release.zip`, publish it immutably, then attempt deployment. Failed publication blocks deployment. Generic examples describe integration; they are not replacement instructions for an existing application workflow. See [orchestration reference](shared-release-orchestration.md).

## 8. Prepare deployment hosts

On each intended Windows Server 2022 host, infrastructure:

1. Provisions PowerShell 7, IIS/.NET 10/ANCM, identities, TLS and application-owned configuration/keys.
2. Follows [installation](installation.md) to authenticate the selected format-3 distribution and provision the protected bootstrap. Published [beta.4](https://github.com/clcdpc/clc-deployment/releases/tag/v0.1.0-beta.4) supplies `Clc.Deployment`; installation still needs independent approval.
3. Follows [host enrollment](host-enrollment.md) to prepare configuration, collect observations, independently approve/install the exact authorization, then Inspect, Plan and Apply.
4. Completes the [first exact approved deployment](deployment.md#first-application-deployment), verifies its baseline, then installs [standing authorization](automated-deployments.md#configure-standing-authorization).

Success: enrollment reports `ReadyForDeployment=true`, the baseline has exact readiness and completed state, and standing scope matches the target. Enrollment readiness alone does not establish application readiness.

## 9. Verify the setup

Optionally run the [read-only GitHub diagnostic](github-setup-check.md) from an administrative workstation or GitHub-hosted runner; resolve NEEDS CONFIGURATION and inspect CHECK MANUALLY items.

Under separately authorized consumer/host scope, follow [IIS verification](iis-verification.md). Retain DEV unmerged-source and Production integrated-source evidence, release identity, readiness, inventory and recovery results. Scope disruptive checks separately. **Actual Windows Server 2022/IIS and independent-identity qualification remain NOT RUN** until observed acceptance is recorded.

## 10. Routine operation

From the application checkout, an authorized release developer sets `$devCommit` / `$productionCommit` to the selected full commit and pushes its tag:

```powershell
git tag v1.2.3-dev.1 $devCommit
git push origin v1.2.3-dev.1
# Production: select a commit contained in protected master history.
git tag v1.2.3 $productionCommit
git push origin v1.2.3
```

DEV tags deploy DEV; stable tags deploy Production; `-beta.N`/`-rc.N` publish only. Success requires the deployment result and expected-release readiness. Preserve failed-attempt material and follow [explicit recovery](deployment.md#operator-procedure). Create a new tag for changed release bytes; published assets cannot be overwritten.

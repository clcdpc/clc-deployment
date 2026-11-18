# CLC Deployment Setup Guide

This guide controls generic setup for each application and target. **SSRS Web administrators start with the [application deployment guide](https://github.com/clcdpc/ssrs-web/blob/master/docs/clc-deployment.md)** and use toolkit procedures where it directs them. Shared-workflow examples below use `example-app`; substitute compatible consumer values.

## Setup roadmap

Follow this order. Complete each linked procedure, then use its **Next** link to continue; return here for verification and routine operation.

| Stage | Procedure |
| --- | --- |
| 1. Configure GitHub | [Sections 1–7](#1-establish-naming-conventions); [GitHub setup](github-setup.md) is supplementary reference |
| 2. Prepare the host | [Section 8](#8-prepare-deployment-hosts): OS, IIS, accounts, TLS and application configuration |
| 3. Prepare trusted bootstrap | [Installation: initial bootstrap provisioning](installation.md#initial-bootstrap-provisioning) |
| 4. Enroll the host | [Enrollment](host-enrollment.md#1-inspect-and-prepare-the-host): deployment.json, observations, independent authorization, Inspect/Plan/Apply, readiness |
| 5. Verify installed toolkit | [Installation: verification and activation](installation.md#verification-and-activation), after Apply installs/activates it |
| 6. Deploy first application | [First deployment](deployment.md#first-application-deployment): acquire, independently approve, deploy and verify baseline |
| 7. Enable routine deployment | [Standing authorization](automated-deployments.md#configure-standing-authorization), only after baseline succeeds |
| 8. Verify deployment | [Section 9](#9-verify-the-setup) → [separately authorized IIS acceptance](iis-verification.md#rollout-order) |
| 9. Operate normally | [Section 10: routine tag-driven operation](#10-routine-operation) |

GitHub administrators begin with naming in [section 1](#1-establish-naming-conventions), then GitHub Settings in [sections 2–7](#2-restrict-github-actions). Infrastructure administrators begin at [section 8](#8-prepare-deployment-hosts), then prepare trusted bootstrap. Application owners prepare external configuration and application-specific release/readiness requirements before baseline.

Paths below are relative to `%ProgramData%\clc-<application-id>\`:

| File | Preparation point and owner |
| --- | --- |
| `Config/application.json` | Application owner supplies content; infrastructure [provisions/protects it](host-enrollment.md#protect-the-handoff-and-configuration) |
| `Config/deployment.json` | Infrastructure writes target configuration in [enrollment section 2](host-enrollment.md#2-prepare-configdeploymentjson) |
| `Deployment/enrollment/authorizations/<authorizationId>.json` | Independent infrastructure reviewer approves; authorized process installs [enrollment handoff](host-enrollment.md#4-independently-approve-and-install-the-handoff) |
| `Deployment/toolkit/policy/host-policy.json` | [Enrollment Apply](host-enrollment.md#5-inspect-plan-apply-and-verify) installs the independently approved initial policy |
| `Deployment/toolkit/policy/approvals/standing/<standingAuthorizationId>.json` | Infrastructure independently approves/provisions [standing authorization](automated-deployments.md#configure-standing-authorization) after baseline |

## 1. Establish naming conventions

Choose a stable lowercase `applicationId`, at most 53 letters, digits or hyphens, beginning with a letter or digit. Use the same application ID in every environment. For `example-app`, the canonical root on both servers is `C:\ProgramData\clc-example-app` when native ProgramData is `C:\ProgramData`.

```text
DEV:        example-app-dev
Production: example-app-production
```

Use the corresponding deployment target ID for routing, the GitHub environment, runner label, enrollment authorization ID and standing authorization ID. Consumer configuration version 2 derives routing from `applicationId`.

DEV and Production use separate servers with independent installations and approvals. The protected `Deployment` directory on each server serves exactly one target.

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

**Compatible shared-workflow consumers only:** `.clc/release.json`, `clc-package-*` artifacts and schema-2 verified release/standing authorization apply to this integration. SSRS Web retains `.github/workflows/release.yml`, `ssrs-web-release-<run>-<attempt>` artifacts and application-owned release/verification scripts with schema-1 verified release/standing authorization ([fixed source](https://github.com/clcdpc/ssrs-web/tree/dddb72c1bafc58db1c8f1ade301a600a269a46bd/scripts/release)). Follow its [application guide](https://github.com/clcdpc/ssrs-web/blob/master/docs/clc-deployment.md); no schema migration is required.

In a compatible application repository:

1. Keep a working application-owned release workflow. For new integration, adapt the [conventional example](examples/shared-conventional-build.yml), or add the [prequalified packaging tail](examples/shared-prequalified-build.yml) after existing application qualification.
2. Configure `push.tags: ['v*']` and preserve `package -> publication -> deployment` through success-dependent `needs`.
3. Set [`.clc/release.json`](examples/shared-release.json) to contract version **2**: actual application/repository, `integrationBranch=master`, producer workflow path/job and optional exact REST job display name. Keep `requiredToolkitContractVersion=2` and application project paths where applicable.
4. Replace synthetic shared SHAs in workflow calls, packaging and `orchestration.sharedRevision` with the same reviewed full immutable revision. Allow `contents: read`, `actions: read`, `id-token: write`; grant `contents: write` to publication only. Preserve application-specific build permissions.

Success: eligible tags produce a qualified `release.zip`, publish it immutably, then attempt deployment. Failed publication blocks deployment. Next: [prepare the host](#8-prepare-deployment-hosts). See [orchestration reference](shared-release-orchestration.md) for details.

## 8. Prepare deployment hosts

After GitHub configuration, infrastructure provisions each intended Windows Server 2022 host: PowerShell 7, IIS/.NET 10/ANCM, accounts, TLS and application-owned configuration/keys. Application owners supply configuration content and qualify release/readiness requirements; the toolkit does not generate application configuration.

Next: [prepare trusted bootstrap](installation.md#initial-bootstrap-provisioning), then follow roadmap stages 4–7 through the linked procedures. Enrollment Apply installs/activates the initial runtime toolkit; it must not already be installed. Return to [section 9](#9-verify-the-setup) after successful baseline and standing setup.

## 9. Verify the setup

Prerequisite: successful baseline and, when enabling automation, standing authorization.

Optionally run the [read-only GitHub diagnostic](github-setup-check.md) from an administrative workstation or GitHub-hosted runner; resolve NEEDS CONFIGURATION and inspect CHECK MANUALLY items.

Under separately authorized consumer/host scope, follow [IIS verification](iis-verification.md). Retain DEV unmerged-source and Production integrated-source evidence, release identity, readiness, inventory and recovery results. Scope disruptive checks separately. **Actual Windows Server 2022/IIS and independent-identity qualification remain NOT RUN** until observed acceptance is recorded.

Next: [routine operation](#10-routine-operation) after the applicable acceptance checks.

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

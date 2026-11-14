# Shared deployment prerequisites diagnostic (contract 1)

Applications call [validate-deployment.yml](../.github/workflows/validate-deployment.yml) to inspect their own GitHub configuration. The PowerShell 7 implementation is [Validate-DeploymentPrerequisites.ps1](../tools/Validate-DeploymentPrerequisites.ps1), backed by the isolated [validation module](../tools/deployment-prerequisites/Validation.psm1). It uses GitHub-hosted Windows runners, the **calling repository's** `GITHUB_TOKEN`, `GITHUB_REPOSITORY` and Actions variable context. It never contacts an IIS host, registers a runner, changes GitHub settings, creates approvals/standing authority, installs the deployment toolkit, publishes releases or triggers deployment. Its only writes are ephemeral hosted-runner dependencies and job summary/output files.

This diagnostic preserves the standing-authorization, deployment-engine and host qualification boundaries merged in PR #2 at [master 7f814ef838abcfd12ade494c429918657598c35d](https://github.com/clcdpc/clc-deployment/commit/7f814ef838abcfd12ade494c429918657598c35d). See the [contracts](https://github.com/clcdpc/clc-deployment/blob/7f814ef838abcfd12ade494c429918657598c35d/docs/contracts.md), [trusted workflow integration](https://github.com/clcdpc/clc-deployment/blob/7f814ef838abcfd12ade494c429918657598c35d/docs/verified-workflow-integration.md) and [IIS verification](https://github.com/clcdpc/clc-deployment/blob/7f814ef838abcfd12ade494c429918657598c35d/docs/iis-verification.md) at that revision. GitHub observations cannot verify protected host approvals or installed toolkit bytes. No engine, public command, approval schema or IIS lifecycle changes are included.

## Minimal caller

Replace `<reviewed-40-character-commit>` with the reviewed immutable commit containing the reusable workflow. The example describes a future ssrs-web integration; this task does not modify that repository or polaris-oidc.

```yaml
name: Deployment prerequisites
on:
  pull_request:
    paths:
      - '.github/workflows/**'
      - '.clc/**'
permissions:
  contents: read
  actions: read
jobs:
  validate-deployment:
    uses: clcdpc/clc-deployment/.github/workflows/validate-deployment.yml@<reviewed-40-character-commit>
    with:
      environment_name: ssrs-web-dev
      integration_branch: master
      release_workflow: .github/workflows/release.yml
      deployment_workflow: .github/workflows/deploy-release.yml
      runner_group: ssrs-web-dev-deployment
      runner_labels: self-hosted,Windows,X64,ssrs-web-dev
      activation_variable: APP_DEV_DEPLOYMENT_ENABLED
      deployment_channel: DEV
```

Run it on deployment-related PRs and release/deployment configuration changes, or as hosted release validation before privileged deployment. Optional periodic checks can be added later by the consumer. This adds no manual deployment dispatch. **PR invocation inspects committed integration-branch configuration, not proposed PR files**; review proposed changes separately. The integration branch is resolved once to a commit and both workflows are read at that commit. Mutable administrative settings are observations during the run, not an atomic snapshot or durable authorization.

GitHub.com `job.workflow_repository` / `job.workflow_sha` identify the reusable definition. The workflow validates that identity and checks out **only clcdpc/clc-deployment at that exact SHA**, with persisted Git credentials disabled. It does not use the caller's `github.sha`, PR checkout, helpers or artifacts as executable validation code. Platforms without this identity fail before checkout; there is no fallback to a caller-controlled revision. See [GitHub job workflow identity](https://docs.github.com/en/actions/reference/workflows-and-actions/contexts#job-context). For a private shared repository, GitHub must permit the caller to read its exact source using its normal token; source acquisition errors fail the run and do not justify adding a privileged credential.

## Inputs and outputs

Only `environment_name` and `runner_group` are required. Names and paths are data, never shell text. Workflows must be single files under `.github/workflows/`; URLs, traversal, expression-valued inputs, executable paths and API endpoints are rejected. Contract 1 supports GitHub.com and organization-owned dedicated privileged runner groups.

| Input | Default / meaning |
| --- | --- |
| `environment_name` | Required exact environment name; 1–100 ASCII letters/digits/spaces/`_.-`, starting with a letter/digit |
| `integration_branch` | `master`; expected protected trusted source branch, up to 128 safe characters |
| `release_workflow` | `.github/workflows/release.yml` |
| `deployment_workflow` | `.github/workflows/deploy-release.yml`; workflow that directly defines the privileged job |
| `runner_group` | Required exact dedicated organization runner group; same name grammar as environment |
| `runner_labels` | `self-hosted,Windows,X64`; 1–10 comma-separated labels, no spaces, each up to 64 letters/digits/`_.-` |
| `activation_variable` | `CLC_DEPLOYMENT_ENABLED`; uppercase Actions variable identifier, up to 64 characters; reserved prefixes rejected |
| `deployment_channel` | `DEV`; exact `DEV` or `Production` |
| `environment_protection` | `runner-workflow` for independently enforced unattended admission; alternatively `required-reviewers` |
| `strict` | Boolean `false`; fail after reporting if any requirement is FAIL or UNVERIFIED |

| Output | Meaning |
| --- | --- |
| `ready` | String `true` only if every requirement is verified PASS; otherwise `false` |
| `passed_count` | Number of PASS rows |
| `failed_count` | Number of FAIL rows |
| `unverified_count` | Number of UNVERIFIED rows |

**Contract 1 always leaves host qualification and semantic trust review Unverified, so overall `ready` is currently always `false`, including a fully configured GitHub fixture. Strict mode therefore currently always fails.** This conservative result is intentional: there is no evidence upload or self-assertion input that can grant readiness. Strict mode is useful as an adoption stop gate; it cannot yet become a green deployment admission gate. A future reviewed contract can accept independently trustworthy qualification evidence; it must preserve the engine's separate authorization. The default diagnostic run succeeds after writing its NOT READY report so early setup checks remain usable.

Outputs are written before the strict-mode nonzero exit. GitHub's normal failure/skip propagation still applies to downstream jobs; consumers reading failed-job outputs must use the appropriate `always()` condition. Invalid inputs, unavailable trusted source/dependencies, and internal execution errors are tooling errors and fail even without strict mode. They must never produce a green readiness result.

## Evidence and classification

PASS means that the **specific row's** limited claim was established, not that the whole deployment is safe. FAIL means a required setting was verifiably absent/incorrect/disabled. UNVERIFIED means insufficient permission, ambiguous/incomplete API data, unsupported analysis or missing independent evidence. Each non-PASS row includes an explanation and a concrete next action. No raw workflow content, API response, exception, token, variable value, operational configuration or host identity is logged in the summary.

| Area | Implemented observation | Limits / administrator action |
| --- | --- | --- |
| Integration branch | Combine classic protection with active applicable repository/organization/enterprise branch rules: required PRs, review count, force-push/deletion restrictions, code-owner review | Rule existence does not prove reviewer independence, bypass authority or effective CODEOWNERS coverage. Infrastructure must review those for both workflows, helpers and toolkit pins. A protected branch name alone never passes these checks. |
| Release tags | Enumerate parent-inclusive rulesets and inspect active tag rules for `creation`, `update`, `deletion`, covering all `v*` tags | Names and matching conditions alone do not pass. Only simple `~ALL`, `refs/tags/*`, `refs/tags/v*` full-coverage patterns without exclusions are proven. Narrower prefixes fail missing coverage; unsupported patterns/exclusions or inaccessible inherited details are Unverified. Review bypass actors and authorized release creators independently. |
| Workflows | Files at the fixed integration SHA; parse YAML as bounded data; explicit `push.tags: ['v*']`; optional release `workflow_dispatch`; deployment has no manual dispatch; `workflow_run` names release workflow and `completed` | Release success, artifact qualification, trusted checkout/helper execution and expression semantics remain Unverified. Same-workflow `needs` / reusable handoffs require review. The parser does not evaluate scripts or implement a complete GitHub policy engine. |
| Environment | Complete exact-name list; deployment policy; exact integration-branch-only selected policy with no tags | Unrestricted refs fail. Protected-branches-only remains Unverified because it does not prove exact source admission. Plan/visibility/permission failures are Unverified. |
| Environment review model | `required-reviewers` checks reviewers, `prevent_self_review`, and exposed `can_admins_bypass=false` | Hidden fields are Unverified. `runner-workflow` does **not** require manual reviewers: infrastructure must instead independently qualify enforced runner/workflow admission and review bypass settings. |
| Runner group | Verify caller visibility from its repository API identity; require selected caller-only repository access, `allows_public_repositories=false` for private callers or `true` for public callers, `restricted_to_workflows=true`, only the expected workflow at `refs/heads/<integration_branch>`; all expected labels on one group runner | Missing or inconsistent visibility is UNVERIFIED. Public access alone never grants readiness; public self-hosted runner risk and independent administrative review remain explicitly UNVERIFIED. Organization **Self-hosted runners: read** is normally unavailable to `GITHUB_TOKEN`. Inspect organization Settings → Actions → Runner groups → Repository access / Selected workflows / runners. No PAT or extra credential is requested. Reusable privileged definitions, broader approved group-sharing models and inherited settings need separate review. Labels do not establish availability, online status, installation or host safety. |
| Activation | Calling repository/organization Actions variable classified as enabled, intentionally disabled, missing/empty, or invalid; check for environment-scoped overrides | GitHub expression string comparison is case-insensitive (`true` / `false`). Only the classification is passed to the process; raw values are never printed. A variable unavailable/empty in this run fails the usable-configuration requirement. Environment overrides conflict with this repository/organization-only pre-job admission contract. Inaccessible override inspection is Unverified. Activation never authorizes a host or release. |
| Privileged job binding | A statically named expected runner group and exact environment occur on the **same** job | Dynamic routing/labels and reusable definitions need review. This does not prove that every privileged path is safe. |
| Production | Explicit production gate is a separate Unverified requirement | Infrastructure reviews production opt-in and its chosen independently enforced protection. A true variable cannot satisfy the gate. Nothing enables production. |
| Toolkit integration | Direct `uses: clcdpc/clc-deployment/...@<40-hex-SHA>` references where observable | PASS proves only a pinned reference. Installed-toolkit/helper integrations, actual shared-engine use, protected standing authority and exact distribution authentication remain Unverified; review against [trusted workflow integration](verified-workflow-integration.md). No signed attestation, signing producer or Sigstore requirement is introduced. |
| Host and toolkit | Separate Unverified rows for compatible installed toolkit, IIS enrollment, initial successful baseline, standing authorization, actual runtime/access, configuration/Data Protection and readiness/recovery | No host requests or caller-supplied attestations. Infrastructure and application owners retain their responsibilities in [installation](installation.md), [host enrollment](host-enrollment.md) and [IIS verification](iis-verification.md). Actual Server 2022/IIS and independent-identity qualification remain NOT RUN. |

The caller's public/private visibility comes only from an identity-matched `GET /repos/{owner}/{repo}` response, using its explicit `visibility` or, when absent, a Boolean `private` field. If both are present, they must agree. Missing, malformed, conflicting or unsupported visibility (including `internal`) stays UNVERIFIED; the validator never infers it from runner-group settings or caller assertions. The integration branch need not be readable to establish repository visibility.

For a **private** caller, keep public access disabled. For a **public** caller, public access must be enabled for its jobs to be eligible, while the selected-repository list must still contain exactly that caller and selected-workflow access must still contain exactly its protected deployment workflow. Disabled public access fails for a public caller; enabled public access fails for a private caller. Broader repository/workflow access fails for either. An inaccessible selected-repository list remains UNVERIFIED. None of these settings proves safe execution. [GitHub warns about untrusted PR/fork code on public self-hosted runners](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/manage-access); the diagnostic includes an explicit UNVERIFIED public-runner risk row requiring independent infrastructure review, even if observable access checks pass or organization settings are inaccessible. Administrators must review every privileged code path and never execute untrusted PR/fork code on the deployment host.

The [repository API](https://docs.github.com/en/rest/repos/repos#get-a-repository), [GitHub rules API](https://docs.github.com/en/rest/repos/rules), [runner-group API](https://docs.github.com/en/rest/actions/self-hosted-runner-groups), and [environment API](https://docs.github.com/en/rest/deployments/environments) define the observed fields and required permissions. Use only `contents: read` and `actions: read` in the caller. `GITHUB_TOKEN` cannot be elevated to organization administration by this workflow. A 401/403/404 for an administrative resource never proves it is missing; a missing environment/group is FAIL only after a complete accessible list establishes absence. Transport failures, 429/5xx, malformed/incomplete responses, inconsistent total counts, pagination limits and inaccessible settings yield Unverified. API calls are GET-only, fixed to `api.github.com`, with redirects disabled, 20-second request timeouts, 4 MiB response buffering, a 150-request/240-second budget and at most 20 pages / 2,000 items per collection. Environment variables use their [documented 30-item page limit](https://docs.github.com/en/rest/actions/variables#list-environment-variables), so that collection is bounded to 600 items.

## Verification and maintenance

The separate [test workflow](../.github/workflows/test-deployment-prerequisites.yml) runs alongside the existing build/release workflow. It runs pinned PowerShell/Pester, offline API fixtures, PowerShell/YAML syntax validation and pinned actionlint across all workflows, plus an actual hosted reusable-workflow smoke call and output assertions. YAML uses YamlDotNet representation nodes only, with byte/depth/node bounds and no application-object deserialization. Anchors, tags and merges are unsupported; their analysis is Unverified. Package/assembly hashes and upstream authentication evidence are in [diagnostic dependencies](../tools/deployment-prerequisites/dependencies.lock.json); existing PowerShell/Pester pins stay in [the foundation lock](../tools/dependencies.lock.json). Parser/actionlint provisioning installs no host toolkit.

```powershell
$deps = & ./tools/deployment-prerequisites/Initialize-Dependencies.ps1 -Destination $newTemporaryDirectory -IncludeActionlint
& ./tools/Test-DeploymentPrerequisites.ps1 -PesterManifestPath $verifiedPesterManifest -YamlAssemblyPath $deps.YamlAssemblyPath -ActionlintPath $deps.ActionlintPath
```

Fixtures cover public/private callers with enabled/disabled public access, exact selected-repository/workflow restrictions, missing/conflicting visibility evidence, public-runner risk review, configured and missing settings, inherited/ineffective rules, administrative denial, API failure, disabled/conflicting activation, malformed inputs/YAML, strict mode/readiness/counters, and the no-consumer-execution/no-external-mutation boundary. These are hosted/offline diagnostics, not administrative-policy or real-host qualification.

For consumer adoption, review `Get-DpToolkitResults` against the merged [trusted workflow/installed-toolkit contract](verified-workflow-integration.md), and review the consumer's actual workflow names, variable names, runner routing, automatic qualification handoff and production gate. Keep unknown semantics Unverified until a reviewed check can prove its precise claim. Consumer changes and real-host deployment/recovery qualification require their own explicit scope; this diagnostic grants neither.

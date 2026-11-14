# Shared deployment prerequisites diagnostic (report contract 2)

Applications call [validate-deployment.yml](../.github/workflows/validate-deployment.yml) to inspect their own GitHub configuration, run [Test-DeploymentHost.ps1](../tools/deployment-prerequisites/Test-DeploymentHost.ps1) under explicit host inspection authority, and combine both observations with [Merge-DeploymentReadiness.ps1](../tools/deployment-prerequisites/Merge-DeploymentReadiness.ps1). The [validation module](../tools/deployment-prerequisites/Validation.psm1) maintains detailed actionable PASS/FAIL/UNVERIFIED reporting. The hosted workflow uses the calling repository's identity/Actions variable context and standard token or an optional protected read-only installation token. Only the separate authorized host stage inspects IIS. Neither stage changes GitHub settings, provisions resources, creates approvals/standing authority, installs the toolkit, enables or triggers deployment.

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

Only `environment_name` and `runner_group` are required for the hosted workflow. Names and paths are data, never shell text. Workflows must be single files under `.github/workflows/`; URLs, traversal, expression-valued inputs, executable paths and API endpoints are rejected. Report contract 2 supports GitHub.com and organization-owned dedicated privileged runner groups, preserving existing hosted inputs and outputs.

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
| `application_id` / `target_id` | Optional safe IDs for hosted reporting; both required and exact in a combined consumer run |
| `diagnostic_workflow` | Optional exact consumer workflow path directly defining the host diagnostic job; runner allowlist must contain exactly deployment plus diagnostic definitions |
| `administrative` | Boolean false; opt in to the protected hosted administrative job |
| `strict` | Boolean `false`; fail after reporting if any requirement is FAIL or UNVERIFIED |

| Output | Meaning |
| --- | --- |
| `github_status` / `host_status` | Category PASS / FAIL / UNVERIFIED; FAIL takes precedence |
| `overall_ready` | Boolean string true only when both categories PASS |
| `report_json` | Sanitized contract-2 detailed stage report for same-run aggregation; no deployment authority |
| `ready` | String `true` only if every requirement is verified PASS; otherwise `false` |
| `passed_count` | Number of PASS rows |
| `failed_count` | Number of FAIL rows |
| `unverified_count` | Number of UNVERIFIED rows |

**Report contract 2 separates GitHub configuration from host qualification.** The hosted stage leaves host checks UNVERIFIED. A separately authorized host stage replaces those hosted placeholders with actual local observations; it cannot replace GitHub semantic-review rows. GitHub configuration remains UNVERIFIED wherever workflow semantics, reviewer/bypass authority, public-runner safety, unattended protection or DEV/production separation cannot be independently established. Administrative API access does not prove these semantics, so the present hosted implementation deliberately cannot return category PASS on its own. There is no self-assertion input to override those checks. Synthetic all-PASS aggregation tests verify classification only; they do not establish operational readiness.

The host category can PASS only when all implemented read-only host prerequisites were observed. Neither category PASS nor combined READY authorizes deployment or establishes application acceptance, database compatibility, a deployment/recovery pilot, or independent-identity qualification. Actual Windows Server 2022/IIS qualification remains **NOT RUN**.

Outputs are written before the strict-mode nonzero exit. GitHub's normal failure/skip propagation still applies to downstream jobs; consumers reading failed-job outputs must use the appropriate `always()` condition. Invalid inputs, unavailable trusted source/dependencies, and internal execution errors are tooling errors and fail even without strict mode. They must never produce a green readiness result.

## Evidence and classification

PASS means that the **specific row's** limited claim was established, not that the whole deployment is safe. FAIL means a required setting was verifiably absent/incorrect/disabled. UNVERIFIED means insufficient permission, ambiguous/incomplete API data, unsupported analysis or missing independent evidence. Each non-PASS row includes an explanation and a concrete next action. No raw workflow content, API response, exception, token, variable value, operational configuration, SID or machine UUID is logged in the summary.

| Area | Implemented observation | Limits / administrator action |
| --- | --- | --- |
| Integration branch | Combine classic protection with active applicable repository/organization/enterprise branch rules: required PRs, review count, force-push/deletion restrictions, code-owner review | Rule existence does not prove reviewer independence, bypass authority or effective CODEOWNERS coverage. Infrastructure must review those for both workflows, helpers and toolkit pins. A protected branch name alone never passes these checks. |
| Release tags | Enumerate parent-inclusive rulesets and inspect active tag rules for `creation`, `update`, `deletion`, covering all `v*` tags | Names and matching conditions alone do not pass. Only simple `~ALL`, `refs/tags/*`, `refs/tags/v*` full-coverage patterns without exclusions are proven. Narrower prefixes fail missing coverage; unsupported patterns/exclusions or inaccessible inherited details are Unverified. Review bypass actors and authorized release creators independently. |
| Workflows | Files at the fixed integration SHA; parse YAML as bounded data; explicit `push.tags: ['v*']`; optional release `workflow_dispatch`; deployment has no manual dispatch; `workflow_run` names release workflow and `completed` | Release success, artifact qualification, trusted checkout/helper execution and expression semantics remain Unverified. Same-workflow `needs` / reusable handoffs require review. The parser does not evaluate scripts or implement a complete GitHub policy engine. |
| Environment | Complete exact-name list; deployment policy; exact integration-branch-only selected policy with no tags | Unrestricted refs fail. Protected-branches-only remains Unverified because it does not prove exact source admission. Plan/visibility/permission failures are Unverified. |
| Environment review model | `required-reviewers` checks reviewers, `prevent_self_review`, and exposed `can_admins_bypass=false` | Hidden fields are Unverified. `runner-workflow` does **not** require manual reviewers: infrastructure must instead independently qualify enforced runner/workflow admission and review bypass settings. |
| Runner group | Verify caller visibility from its repository API identity; require selected caller-only repository access, `allows_public_repositories=false` for private callers or `true` for public callers, `restricted_to_workflows=true`, only the expected workflow at `refs/heads/<integration_branch>`; all expected labels on one group runner | Missing or inconsistent visibility is UNVERIFIED. Public access alone never grants readiness; public self-hosted runner risk and independent administrative review remain explicitly UNVERIFIED. Organization **Self-hosted runners: read** is normally unavailable to `GITHUB_TOKEN`. Inspect organization Settings → Actions → Runner groups → Repository access / Selected workflows / runners. Standard mode requires no extra credential; optional administrative mode is described below. Reusable privileged definitions, broader approved group-sharing models and inherited settings need separate review. Labels do not establish availability, online status, installation or host safety. |
| Activation | Calling repository/organization Actions variable classified as enabled, intentionally disabled, missing/empty, or invalid; check for environment-scoped overrides | GitHub expression string comparison is case-insensitive (`true` / `false`). Only the classification is passed to the process; raw values are never printed. A variable unavailable/empty in this run fails the usable-configuration requirement. Environment overrides conflict with this repository/organization-only pre-job admission contract. Inaccessible override inspection is Unverified. Activation never authorizes a host or release. |
| Privileged job binding | A statically named expected runner group and exact environment occur on the **same** job | Dynamic routing/labels and reusable definitions need review. This does not prove that every privileged path is safe. |
| Production | Explicit production gate is a separate Unverified requirement | Infrastructure reviews production opt-in and its chosen independently enforced protection. A true variable cannot satisfy the gate. Nothing enables production. |
| Toolkit integration | Direct `uses: clcdpc/clc-deployment/...@<40-hex-SHA>` references where observable | PASS proves only a pinned reference. Installed-toolkit/helper integrations, actual shared-engine use, protected standing authority and exact distribution authentication remain Unverified; review against [trusted workflow integration](verified-workflow-integration.md). No signed attestation, signing producer or Sigstore requirement is introduced. |
| Host and toolkit | Separate Unverified rows for compatible installed toolkit, IIS enrollment, initial successful baseline, standing authorization, actual runtime/access, configuration/Data Protection and readiness/recovery | The hosted stage makes no host requests and accepts no attestations. The separately authorized host stage below inspects actual enrolled resources. Infrastructure and application owners retain their responsibilities in [installation](installation.md), [host enrollment](host-enrollment.md) and [IIS verification](iis-verification.md). Actual Server 2022/IIS and independent-identity qualification remain NOT RUN. |

The caller's public/private visibility comes only from an identity-matched `GET /repos/{owner}/{repo}` response, using its explicit `visibility` or, when absent, a Boolean `private` field. If both are present, they must agree. Missing, malformed, conflicting or unsupported visibility (including `internal`) stays UNVERIFIED; the validator never infers it from runner-group settings or caller assertions. The integration branch need not be readable to establish repository visibility.

For a **private** caller, keep public access disabled. For a **public** caller, public access must be enabled for its jobs to be eligible, while the selected-repository list must still contain exactly that caller and selected-workflow access must still contain exactly its protected deployment workflow. Disabled public access fails for a public caller; enabled public access fails for a private caller. Broader repository/workflow access fails for either. An inaccessible selected-repository list remains UNVERIFIED. None of these settings proves safe execution. [GitHub warns about untrusted PR/fork code on public self-hosted runners](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/manage-access); the diagnostic includes an explicit UNVERIFIED public-runner risk row requiring independent infrastructure review, even if observable access checks pass or organization settings are inaccessible. Administrators must review every privileged code path and never execute untrusted PR/fork code on the deployment host.

The [repository API](https://docs.github.com/en/rest/repos/repos#get-a-repository), [GitHub rules API](https://docs.github.com/en/rest/repos/rules), [runner-group API](https://docs.github.com/en/rest/actions/self-hosted-runner-groups), and [environment API](https://docs.github.com/en/rest/deployments/environments) define the observed fields and required permissions. Use only `contents: read` and `actions: read` in the caller. `GITHUB_TOKEN` cannot be elevated to organization administration by this workflow. A 401/403/404 for an administrative resource never proves it is missing; a missing environment/group is FAIL only after a complete accessible list establishes absence. Transport failures, 429/5xx, malformed/incomplete responses, inconsistent total counts, pagination limits and inaccessible settings yield Unverified. API calls are GET-only, fixed to `api.github.com`, with redirects disabled, 20-second request timeouts, 4 MiB response buffering, a 150-request/240-second budget and at most 20 pages / 2,000 items per collection. Environment variables use their [documented 30-item page limit](https://docs.github.com/en/rest/actions/variables#list-environment-variables), so that collection is bounded to 600 items.

## Verification and maintenance

### Standard and administrative GitHub inspection

Standard mode uses only `GITHUB_TOKEN` (`contents: read`, `actions: read`), does every accessible GET and leaves inaccessible administrative resources UNVERIFIED. It is independently usable in ordinary PR CI and never schedules a host runner. The optional `inspection_token` secret is ignored in standard mode.

Administrative mode accepts an explicitly supplied short-lived GitHub App installation token through `inspection_token`; it does not mint tokens, read App private keys or support PAT provisioning. The reusable workflow schedules its administrative job only for `workflow_dispatch` on the selected protected integration ref. It uses the fixed **deployment-configuration-inspection** Environment in the calling repository. Infrastructure must protect that environment with the exact integration branch, appropriate independent reviewers/no self-review and bypass controls before supplying credentials. Token delivery occurs only in the inspection step on a GitHub-hosted runner, after exact shared-source checkout. A missing token fails; denied endpoints still report UNVERIFIED. No token is passed to host jobs, report outputs or consumer code. Use a protected consumer dispatcher; never use `secrets: inherit` or make this credential available to PR jobs. The CLI's `-AuthenticationMode Administrative` is an operator entry point; its protected workflow boundary is enforced by the wrapper, not inferred by the CLI.

Install the App on only the selected consumer repositories. All requested permissions are **read-only**:

| Scope | Permission | Inspected endpoints |
| --- | --- | --- |
| Repository | Metadata (implicit), Contents: read | Repository identity/visibility, integration branch, workflow files at its observed commit, effective branch rules/rulesets |
| Repository | Administration: read | Classic branch protection and administrator enforcement; administrative rule detail where exposed |
| Repository | Actions: read | Environment enumeration, environment policy observations and deployment-branch policies |
| Repository | Environments: read | Environment variable override inspection |
| Organization | Self-hosted runners: read | Dedicated runner group, selected repositories/workflows, registered runner labels |

These are the union needed by this validator, not broad organization administration. No Secrets, Deployments write, Workflows write, Members, Variables organization read, signing or attestation permission is needed. Activation is classified from the calling Actions variables context; the validator does not fetch organization variable values. The [environment API](https://docs.github.com/en/rest/deployments/environments), [environment variables API](https://docs.github.com/en/rest/actions/variables#list-environment-variables), [branch protection API](https://docs.github.com/en/rest/branches/branch-protection) and [runner-group API](https://docs.github.com/en/rest/actions/self-hosted-runner-groups) describe endpoint permissions. GitHub plan, inherited policy and installation restrictions can still conceal evidence.

The existing branch/tag/review/workflow/environment/activation/runner checks remain individual rows. New rows observe classic `enforce_admins` and exposed active-tag bypass lists. Empty complete bypass lists establish only that narrow observation; configured bypass actors require semantic review. DEV/production separation always receives its own review action. The optional `diagnostic_workflow` extends the exact selected-workflow set to two entries; additional workflows or refs fail. Public/private access rules remain unchanged: public callers need public access enabled, private callers need it disabled, and both require caller-only selected repository access. Public runner safety remains UNVERIFIED pending independent review.

### Independently authorized host inspection

Run [Test-DeploymentHost.ps1](../tools/deployment-prerequisites/Test-DeploymentHost.ps1) only under a separately authorized read-only inspection scope, using the exact independently authenticated installed manifest in a fresh trusted PowerShell process. Infrastructure must authenticate the installation **before first import**; code cannot authenticate itself. Neither the script nor this PR grants host execution authority. Select application ID, environment, channel, target ID, repository, release workflow/build job and standing authorization ID explicitly. `ToolkitManifestPath` is a reviewed operator/workflow literal, never a dispatch input, artifact field or executable selector exposed to contributors. No account, credential or remoting setup is performed.

The script loads a small read-only adapter inside the installed module and uses its existing private contract/physical-path/ACL/Authz/IIS/preflight/state readers; the four-command public deployment API is unchanged. The existing enabled elevated deployment token is required because those trusted readers enforce that policy. The shared deployment administrator remains privileged; independent approval is procedural. Inspection does not execute application code with that token. Effective access failures, unavailable group expansion and inaccessible evidence remain UNVERIFIED; no write probe substitutes for Authz.

| Host area | Direct observation and limits |
| --- | --- |
| Toolkit | Active policy/version/source/distribution/inventory/installed-manifest identity and protected dependencies through `Open-ClcTrustedContext`; required current standing, preflight and journal readers must exist. Missing manifest fails. Unavailable first import or ambiguous trust/access failure is UNVERIFIED. No install/upgrade/activation. |
| Actual machine | Local SMBIOS UUID must match protected policy **before any IIS/target inspection**. A different machine fails. Unavailable machine evidence leaves host qualification UNVERIFIED. Runner labels never establish host identity. |
| Enrollment | Protected host-policy and exact target contracts, matching application/environment/target; existing enrolled canonical directories and runtime SID. No enrollment, policy repair or resource creation. |
| IIS | Bounded site/pool presence, dedicated site/sole root application/pool/path/SID, one worker, overlap/x64 settings; existing preflight checks runtime environment and enrolled HTTPS readiness binding. Actual observed pool state/worker count is reported. No pool lifecycle or IIS configuration writes. |
| Hosting | Server 2022 build 20348, 64-bit PowerShell 7; protected IIS/.NET dependencies, x64 ANCM major 20 and both .NET/ASP.NET Core 10.0 shared frameworks, using the existing bounded `--list-runtimes` query. Infrastructure still owns component patch qualification. |
| Identity/ACLs | Exact elevated admitted deployment SID; distinct nonadministrator runtime including groups; structural infrastructure ownership, protected authorization/catalog/toolkit access and ancestor replacement isolation through existing Authz-backed checks. |
| Application paths | Disjoint physical app/inbox/configuration/key/control roots, bounded descendant/alias/hard-link/reparse/stream checks, configuration and Data Protection permissions. Configuration/key contents are not retrieved; semantic compatibility remains application-owned. |
| Standing | Existing enabled protected policy, independent infrastructure authority, exact application/target/environment/channel/repository/build workflow/job and current baseline lineage. Current generated approvals recheck live standing revocation, retained admission evidence and immutable tag binding. No create/enable/renew. |
| State | Exclusively open the **existing** canonical machine/pool lock using `FileMode.Open`, `FileAccess.Read`, `FileShare.None`; never create it. Missing/busy/unreadable locks leave state UNVERIFIED. Reuse existing clean-state/terminal/helper-exit readers under that handle. Missing baseline fails; unresolved deployment/recovery fails and later dependent checks remain UNVERIFIED. |
| Retention | Current exact enabled approval, approval-pinned retained manifest/release identity, complete installed inventory and latest journal-selected backup/index when present. Recovery consumes retained manifests/backups, so a historical ZIP is not required. Unknown files are preserved and rejected. No restore, cleanup, state publication or reconciliation. |
| Final stability | Recheck protected context/target/standing bytes and physical/IIS identity before releasing all handles. This is a point-in-time observation; freeze competing trusted writers. The lock serializes toolkit mutation, not independent administrative IIS/configuration changes. |

If the runner is not on the IIS host, this implementation does **not** introduce remote execution. Use an existing independently authorized read-only inspection channel to run the same diagnostic on the actual enrolled machine and return only its sanitized report. If that channel is unavailable, skip host inspection and report UNVERIFIED. Never inspect the runner's IIS installation as a substitute. Local-machine mismatch is FAIL, not a qualified host.

The diagnostic makes no readiness HTTP request and never executes the elevated application validator. Existing current/readiness records are historical observations, not fresh health. A configured endpoint, valid paths and matching files do not establish current functional acceptance, configuration semantics, Data Protection/profile usability, TLS trust/revocation from the application path, database safety or successful deployment/recovery. Follow [IIS verification](iis-verification.md) and consumer acceptance under separate scope. A disposable probe is not a prerequisite for a consumer pilot.

### Protected consumer workflow and combined reporting

The complete [consumer template](examples/deployment-readiness.yml) shows all three stages: reusable hosted inspection, an explicitly dispatched directly defined host job, and an `always()` hosted aggregator. Replace every zero SHA with **one reviewed immutable clc-deployment commit containing these files**, and replace the synthetic repository, environment, group, installed version and selectors through consumer review. Do not copy it into an active workflow until separately authorized. Add reviewed application/environment/target choices with fixed literal mappings; never accept commands, scripts, machine names, executable paths or privilege escalation inputs.

For `example/app`, configure the dedicated group exactly as follows:

```text
Repository access: Selected repositories -> example/app only
Allow public repositories: enabled for a public caller; disabled for a private caller
Workflow access: Selected workflows (restricted_to_workflows=true)
  example/app/.github/workflows/deploy-release.yml@refs/heads/master
  example/app/.github/workflows/diagnose-deployment.yml@refs/heads/master
```

The host job must be directly defined in `diagnose-deployment.yml`, with the restricted group and protected deployment Environment on the same job. Restrict that Environment to protected master and the independently chosen protection/bypass model. The job checks repository, dispatch event, exact protected ref, exact `workflow_ref` and `workflow_sha == github.sha` before invoking pinned shared diagnostic code. It checks out no consumer PR/tag/application source or release artifact. It receives no administrative inspection token and performs no deployment. Keep diagnostic dispatch independent of the activation variable, so setup can be inspected while deployment stays disabled; the activation row will correctly FAIL.

[GitHub selected-workflow admission applies to jobs directly defined in the selected workflow](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/manage-access). Allowlisting only a caller does not admit host jobs defined in a reusable callee. This template deliberately defines the privileged job in the consumer; the shared reusable workflow remains GitHub-hosted. Do not broaden the allowlist to arbitrary PR refs or all workflows to resolve routing failures. Enforce these controls outside repository code before allowing runner access, especially for public repositories.

Reports retain every observed row with check name, evidence/explanation and corrective/verification action. Each hosted host-placeholder row is replaced only by its matching actual host observation; unavailable prerequisites and their original actions remain visible. Aggregation validates report contract 2 and matching repository/application/environment/channel/target, recomputes statuses/counts from rows and ignores claimed aggregate readiness. Reports are bounded to 1 MiB/500 rows. They are diagnostic data from the same trusted run, never authorization or a persistent evidence service.

`github_status` and `host_status` use **FAIL before UNVERIFIED before PASS**. Empty categories are UNVERIFIED. `overall_ready` and legacy `ready` are true only if both categories PASS. Counts remain separate PASS/FAIL/UNVERIFIED totals. Missing, malformed, skipped, cancelled or unsuccessful stage evidence adds an actionable UNVERIFIED row while preserving available individual FAIL rows. A confirmed failure remains FAIL even if the stage also failed or lost other evidence. The aggregator runs with `always()` and passes actual `needs.<job>.result`; never infer success from an empty output. Strict mode writes summaries/outputs first and then exits nonzero for NOT READY. Default mode reports NOT READY successfully; tooling/source/dependency errors still fail.

The template transports sanitized reports through job outputs for same-run aggregation, using environment variables rather than shell interpolation. If GitHub suppresses an output, the missing report stays UNVERIFIED. Reporting may write GitHub command files or runner-temporary report files; host inspection itself returns an object and writes no host files. Deployment, software installation, GitHub settings writes, approval/standing writes, app/config/key mutation, lock deletion, recovery and activation remain outside both diagnostics.

The reviewed existing-behavior baseline is clc-deployment master [`7f814ef838abcfd12ade494c429918657598c35d`](https://github.com/clcdpc/clc-deployment/commit/7f814ef838abcfd12ade494c429918657598c35d), including standing/schema-2 admission. The inspected ssrs-web master [`c9fee1f1c2f2e0d1c1f613e601858286b0d50647`](https://github.com/clcdpc/ssrs-web/blob/c9fee1f1c2f2e0d1c1f613e601858286b0d50647/.github/workflows/deploy-dev.yml) currently uses a protected-master direct privileged job, separately authenticated bootstrap/enrollment and exact manual release approval with dispatch. It has not yet adopted the automatic standing consumer architecture expected by these GitHub checks; diagnostics must report that difference honestly. No ssrs-web or polaris-oidc changes are included. Their rollout, tokens, runner allowlists, host authority and acceptance remain separate work.

The separate [test workflow](../.github/workflows/test-deployment-prerequisites.yml) runs alongside the existing build/release workflow. It runs pinned PowerShell/Pester, offline API fixtures, PowerShell/YAML syntax validation and pinned actionlint across all workflows, plus an actual hosted reusable-workflow smoke call and output assertions. YAML uses YamlDotNet representation nodes only, with byte/depth/node bounds and no application-object deserialization. Anchors, tags and merges are unsupported; their analysis is Unverified. Package/assembly hashes and upstream authentication evidence are in [diagnostic dependencies](../tools/deployment-prerequisites/dependencies.lock.json); existing PowerShell/Pester pins stay in [the foundation lock](../tools/dependencies.lock.json). Parser/actionlint provisioning installs no host toolkit.

```powershell
$deps = & ./tools/deployment-prerequisites/Initialize-Dependencies.ps1 -Destination $newTemporaryDirectory -IncludeActionlint
& ./tools/Test-DeploymentPrerequisites.ps1 -PesterManifestPath $verifiedPesterManifest -YamlAssemblyPath $deps.YamlAssemblyPath -ActionlintPath $deps.ActionlintPath
```

Fixtures cover public/private callers with enabled/disabled public access, exact selected-repository/workflow restrictions, missing/conflicting visibility evidence, public-runner risk review, configured and missing settings, inherited/ineffective rules, administrative denial, API failure, disabled/conflicting activation, malformed inputs/YAML, strict mode/readiness/counters, and the no-consumer-execution/no-external-mutation boundary. These are hosted/offline diagnostics, not administrative-policy or real-host qualification.

For consumer adoption, review `Get-DpToolkitResults` against the merged [trusted workflow/installed-toolkit contract](verified-workflow-integration.md), and review the consumer's actual workflow names, variable names, runner routing, automatic qualification handoff and production gate. Keep unknown semantics Unverified until a reviewed check can prove its precise claim. Consumer changes and real-host deployment/recovery qualification require their own explicit scope; this diagnostic grants neither.

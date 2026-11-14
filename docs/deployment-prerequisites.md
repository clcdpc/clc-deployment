# Read-only deployment prerequisite checker (report contract 3)

Use this checker after configuring GitHub and enrolling a host, when onboarding or migrating a target, after meaningful infrastructure changes, or when troubleshooting. It answers whether the required infrastructure is configured sufficiently to attempt a separately authorized initial deployment. Routine deployments do not require a checker report.

1. Configure protected GitHub source, release tags, workflows, environment and runner admission. Independently install/authenticate the toolkit and enroll the intended host.
2. Run the manually invoked [consumer diagnostic workflow](examples/deployment-readiness.yml), with exact reviewed source pins and explicit application/environment/target/channel selectors.
3. Correct blocking findings using the indicated resource and setting. The checker performs no corrections.
4. Rerun if necessary.
5. Proceed with the separately authorized initial deployment. An empty, correctly enrolled target can be READY without a deployed application, current-release approval, historical journals/backups or standing authorization.
6. Complete application-specific deployment and recovery acceptance under its own scope. Actual Windows Server 2022/IIS and independent-identity qualification remain **NOT RUN**.

The checker never approves deployment, installs or upgrades the toolkit, enrolls a target, changes GitHub/IIS/ACLs, creates approvals, clears state, or executes application validators, hooks, planning code, readiness requests or migrations. Deployment retains its independent approval, locking, preflight and recovery checks. The merged architecture is [master c552e724bd0508798312f579f208dc438ed39c51](https://github.com/clcdpc/clc-deployment/tree/c552e724bd0508798312f579f208dc438ed39c51); its [contracts](https://github.com/clcdpc/clc-deployment/blob/c552e724bd0508798312f579f208dc438ed39c51/docs/contracts.md) distinguish protected source/caller/shared-job identities from installed toolkit identity.

## Run and interpret

The [template](examples/deployment-readiness.yml) defines a manual consumer workflow with three jobs: hosted GitHub inspection, directly defined and independently admitted actual-host inspection, then hosted aggregation with `if: always()`. It is a template, not an installed workflow or authority. Replace all diagnostic zero SHA pins with one reviewed immutable diagnostic revision; separately pin the shared orchestration SHA matching protected `.clc/release.json`. Independently allowlist the exact job-defining shared deployment workflow and the consumer diagnostic workflow. Keep privileged runners and infrastructure credentials outside ordinary PR CI.

Hosted inspection is also available independently:

```powershell
# GH_TOKEN supplies ordinary read access. Administrative settings may need the
# explicit protected read-only installation token described below.
& ./tools/Validate-DeploymentPrerequisites.ps1 `
    -ApplicationId example-app -TargetId example-app-dev -EnvironmentName example-app-dev `
    -IntegrationBranch master -ReleaseWorkflow .github/workflows/build.yml `
    -DeploymentWorkflow .github/workflows/deploy.yml -DeploymentChannel DEV `
    -RunnerGroup example-app-dev -RunnerLabels self-hosted,Windows,X64 `
    -SharedRevision $reviewedOrchestrationSha -DiagnosticWorkflow .github/workflows/diagnose-deployment.yml `
    -YamlAssemblyPath $verifiedYamlAssembly -ReportPath $localReport
```

On the independently admitted enrolled host, use trusted diagnostic source and the exact independently approved installed manifest:

```powershell
$hostReport = & ./tools/deployment-prerequisites/Test-DeploymentHost.ps1 `
    -ApplicationId example-app -TargetId example-app-dev -EnvironmentName example-app-dev `
    -Repository example-org/example-app -IntegrationBranch master -DeploymentChannel DEV `
    -ReleaseWorkflow .github/workflows/build.yml -BuildJob build `
    -ToolkitManifestPath $independentlyApprovedInstalledManifest
# Optional -StandingAuthorizationId selects an existing policy for advisory inspection.
# It is not required for commissioning and never authorizes initial deployment.
```

Both inspectors emit structured findings for normal prerequisite failures. Successful diagnostic execution can exit zero with NOT READY findings. Invalid inputs, unauthenticated executable dependencies or inability to produce a valid report are command errors. The final `Merge-DeploymentReadiness.ps1` publishes available findings, exits zero only for READY and nonzero for NOT READY or report-generation failure. There is no Strict switch or configurable failure policy.

READY means both GitHub and actual-host categories PASS: all required applicable prerequisites have sufficient practical evidence. It may contain visible advisory warnings. NOT READY means a required prerequisite failed, remained inconclusive or was skipped. A GitHub-only or host-only report cannot establish overall READY. The summary prioritizes blocking problems and corrective actions, then nonblocking warnings and compact successful checks.

| Check status | Meaning |
| --- | --- |
| PASS | Executed and obtained sufficient evidence |
| FAIL | Confirmed missing, incorrect, disabled or incompatible prerequisite |
| UNVERIFIED | Attempted but inconclusive: denied access, incomplete API/native evidence, unsupported configuration or concurrent change |
| SKIPPED | Did not execute; reason identifies the missing dependency or inspection stage |
| NOT_APPLICABLE | A source-defined applicability condition was established, such as a verified empty target with no current release |

Each check has an explicit source-owned Required or Advisory classification. Required FAIL blocks; required UNVERIFIED/SKIPPED prevents PASS. Legitimate NOT_APPLICABLE does not block. Advisory findings retain their actual status and corrective action without independently blocking readiness. Categories use FAIL precedence, otherwise UNVERIFIED for incomplete required inspection, otherwise PASS. Human titles have no role in aggregation.

## What is inspected

| Area | Required observations and practical limits |
| --- | --- |
| Repository/source | Exact consumer identity and configured integration branch (`master` or `main`), required CI checks, force-push/deletion and observable bypass restrictions. Mandatory PR reviews, reviewer counts, CODEOWNERS and extra PR-branch protection are not universal requirements. |
| Release tags | Active applicable creation/update/deletion rules and observable bypass restrictions for the selected channel. Names/patterns alone and evaluate-only rules are insufficient. Simple full or channel-specific coverage is supported; complex exclusions remain inconclusive. Only explicitly enabled Test tags use Test authority; DEV snapshots rely on the protected integration source and explicit source policy. |
| Workflows/routing | Expected producer/caller source at one observed integration commit, bounded valid YAML, trigger handoff, exact immutable shared deployment/publication references, the existing strict shared consumer configuration contract (including trusted files and required toolkit contract), protected application/channel/target/environment/group/labels and actual shared job routing. Disabled activation indicators are pending activation warnings, never host authority. Legacy direct routing can be inspected, but absent protected channel configuration remains inconclusive. |
| Environment | Exact environment and exact configured integration-branch-only policy with no unexpected branch/tag admission. Reviewers are optional compatibility information, not a new pipeline approval requirement. |
| Runner admission | Exact selected repository access with correct public/private admission; selected-workflow enforcement and no additional workflows; actual job-defining shared workflow rather than consumer caller; an online group runner with expected labels. Wrong or overbroad allowlists FAIL; inaccessible required settings remain UNVERIFIED. Cross-organization shared use requires observed inherited enterprise ownership. Correct observable restrictions can PASS with an advisory enterprise-enforcement limitation. |
| Toolkit trust | Trusted diagnostic bootstrap authenticates the fixed protected installation policy before candidate import, checks active version/source/distribution/inventory and required dependencies, and holds authenticated files/physical identities across import and inspection. Candidate code cannot authenticate itself. The initial authority anchor accepts SYSTEM/Administrators writers; other infrastructure writer patterns remain inconclusive without importing candidate code. |
| Host/IIS/filesystem | Actual machine and admitted elevated deployment identity; exact protected enrollment; dedicated IIS site/root application/pool/path/runtime SID/one-worker settings; Server 2022/x64 PowerShell/.NET/ANCM; external configuration/key directories and existing physical-path/ACL/Authz observations. Runtime remains distinct and nonadministrator with effective protected-resource write isolation. No probe writes or application execution. |
| Canonical state | Existing lock opened read-only/exclusive without creation or modification, pending admission, journal/current/terminal/helper reconciliation, and engine initial-empty-state rules. Populated targets retain current approved manifest/inventory and generated schema-2/3 standing-revocation checks. No historical ZIP or unrelated recovery-backup campaign is required. Unresolved/corrupt/unsafe evidence blocks readiness; diagnostics never reconcile it. |
| Optional automation | Missing standing policy or baseline does not block initial commissioning. A selected existing policy is checked for scope/protection; warnings do not certify routine unattended release eligibility. |

Static inspection cannot prove every future workflow expression, administrator/bypass action or enterprise enforcement behavior. Those limitations remain visible advisories when observable critical configuration is sufficient. Missing security-critical settings or unavailable required observations remain blocking. Application startup, database access, HTTPS readiness, operational configuration semantics, Data Protection compatibility and deployment/recovery acceptance require separately authorized application evidence. There is no certificate, expiration timer, report database, signoff or ongoing health monitor.

## Authentication, limits and reports

GitHub observation uses fixed-origin GET-only APIs, no redirects, bounded pagination (20 pages/2,000 items), 150 requests/240 seconds, 20-second requests and 4 MiB API responses. Workflow/config files are bounded to 256 KiB, with bounded safe JSON/YAML parsing. YAML aliases are rejected for consumer observations; the independently pinned shared definition permits bounded data-only alias interpretation. The YAML assembly and test tools retain [reviewed dependency pins](../tools/deployment-prerequisites/dependencies.lock.json).

Standard hosted inspection uses the caller's GitHub token. Administrative mode is explicit: a short-lived read-only GitHub App installation token in `inspection_token`, available only to the hosted `deployment-configuration-inspection` environment on protected-branch manual dispatch. Required organization runner/protection APIs may be unavailable to ordinary `GITHUB_TOKEN`; that produces UNVERIFIED, never a bypass. No administrative token enters the actual-host job. Shared diagnostic checkout requires GitHub.com's independently observed job workflow repository/path/SHA and fails before checkout if unavailable; it never falls back to caller source. The existing hosted smoke exercises this platform dependency.

Report version **3** intentionally rejects version 2. The report contains `contract_version`, `subject` (repository, integration_branch, application, target, environment, channel, observed_commit), `checked_at_utc`, `github_status`, `host_status`, Boolean `ready`, status `counts` and `checks`. Every check contains stable `id`, explicit `category`, human `name`, `status`, Boolean `required`, safe `detail`, corrective `action` and stable `reason` (empty when unused). JSON values have consistent types.

Aggregation rejects unsupported/malformed/oversized reports, unknown or duplicate check IDs, wrong category/classification, missing fields, contradictory summaries/counts and mixed subjects. Omitted known required checks cannot grant PASS. It preserves valid findings and corrective actions, including confirmed failures from unsuccessful stages. A missing stage adds one SKIPPED inspection finding, not invented host observations. Ordering is deterministic by ID. Reports are bounded to 1 MiB, 500 checks and 4,096 characters per text field. Only sanitized authored diagnostics are published; no private exception text, API response, token, operational configuration or credentials are emitted.

Reusable outputs are `report_json`, `github_status`, `host_status`, `ready`, and `passed_count`, `failed_count`, `unverified_count`, `skipped_count`, `not_applicable_count`. The JSON contract uses nested `counts`; Actions count/readiness outputs are strings. Final reporting uses `always()` to publish available results after failed or skipped inspection jobs. These outputs are troubleshooting observations and have no deployment-admission role.

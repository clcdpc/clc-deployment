# GitHub prerequisites for shared application workflows

The [shared integration guide](shared-release-orchestration.md) supplies conventional and prequalified-artifact examples. Infrastructure must independently establish the controls below before enabling their protected target routes. These instructions create no settings, runners, secrets, environments or host authority. Actual runner admission and consumer deployment qualification remain **NOT RUN**.

## Protect source and executable workflow code

Protect the integration branch with required independent review/checks, restricted bypass, and no force pushes/deletion. Protect release tags against update/deletion and restrict their creation. Enforce infrastructure review of workflows, `.clc/release.json`, security-sensitive supporting scripts and immutable dependency/shared-toolkit pins. The protected consumer configuration must list those files in `trustedFiles`; reviewed unmerged DEV application source cannot substitute their bytes.

Keep the deployment/publication caller on the protected integration branch. Pin all shared `uses: clcdpc/clc-deployment/.github/workflows/application-*.yml@<40-character-reviewed-SHA>` references and set `orchestration.sharedRevision` to that exact SHA. Producer and deployment workflow paths are explicit configuration. GitHub job OIDC binds the executing reusable revision and caller context; a producer artifact cannot supply replacement orchestration. See [protected branches](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches).

Ordinary PR CI runs on isolated hosted/build runners without host credentials or privileged runner access. The shared conventional build also uses a hosted runner. Existing complex CI retains its specialized tests, qualifies one successful producer job/run/attempt and uploads the fixed artifact contract. A `workflow_run` completion is a selector for independent verification, not authorization. Its caller workflow must exist on the default branch; see [GitHub's completion-event semantics](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_run).

## Restrict the privileged runner externally

Have the organization runner administrator configure a dedicated restricted runner group before registering the Windows host:

1. Select only authorized consumer repositories. Do not enable general public-repository or repository-wide workflow access to a privileged host.
2. Enable enforceable **Selected workflows** access and admit the exact shared reusable `clcdpc/clc-deployment/.github/workflows/application-deploy.yml@<reviewed-SHA>` whose `deploy` job requests the runner. Access applies to jobs directly defined by the selected workflow; allowing only a caller does not automatically authorize its callee. Verify effective organization/enterprise policy against [GitHub's runner-group controls](https://docs.github.com/en/enterprise-cloud@latest/actions/how-tos/manage-runners/self-hosted-runners/manage-access).
3. Ensure no alternate group, repository runner registration or workflow path exposes that host more broadly. Register it directly into the restricted group.
4. Match the configured group and explicit `self-hosted`, `Windows`, `X64` and target labels. Keep DEV, Test and production admission scopes separate.

Labels, YAML conditions, an environment name and `runnerAdmissionReady=true` do not enforce runner isolation. Check the organization plan and actual effective controls; if the required restriction is unavailable, keep deployment disabled until infrastructure approves an equivalent external boundary. The shared workflow verifies caller/configuration again on the runner, but that cannot make admitting arbitrary privileged jobs safe.

The shared workflow obtains and checks out its own immutable revision before privileged operations. The application package is verified data until its declared, separately authorized hooks execute. Hooks and application validation run under the elevated deployment identity and are not sandboxed. The runner service, workspace, pinned Actions runtime and installed tooling are privileged infrastructure dependencies.

## Configure separate environments and protected routing

Create each exact configured environment before use. Apply the infrastructure-approved automatic-deployment review/bypass policy and allow the protected caller's integration-branch execution ref. A `workflow_run` consumer executes protected branch code; the application tag/PR source is verified separately and should not broaden environment admission. Verify actual branch protection and rules rather than trusting **Protected branches only** or the environment's existence. See [environment configuration](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments).

Routes live in reviewed `.clc/release.json`, containing channel, target ID, environment, runner group/labels, standing-policy ID, `enabled` and `runnerAdmissionReady`. They contain no host paths, credentials or authority records. Leave activation flags false until independent host/baseline/policy and external runner/environment prerequisites are accepted. The hosted admission job loads protected routing; the queued privileged job rejects changed configuration and repeats source/build/artifact checks. Beta/RC remain artifact-only. Production is disabled unless its own route and independent authority are enabled.

For explicit redeployment use the protected caller's `workflow_dispatch` with `automatic: false`. The shared route requires the actual actor's repository write, maintain or admin authority. It does not bypass source eligibility, standing scope, ordering or unresolved state. Automatic branch deployments use `automatic: true` and skip superseded source. Normal mutating deployment and `operation: ValidateOnly` are distinct requests; planning still requires normal admission and separately authorized read-only planning code.

## Permissions, acquisition and evidence

Use minimum token permissions from the reusable workflow: read source, Actions and PR metadata; obtain job OIDC for immutable workflow identity; grant contents-write only to the publication workflow. Verify that the credential can read current reviewer/collaborator authority in the intended repository; an inaccessible permission check fails closed. No host credentials belong in ordinary CI. A private shared-source checkout may require separately provisioned read access; a repository token does not automatically read another private repository.

The exact successful producer attempt must expose `clc-package-<fullSourceCommit>-<runId>-<attempt>` containing only `release.zip`. The verifier authenticates artifact ownership, run/job/attempt, timestamps and service digest, then checks inner package contract/provenance. Retain qualified artifacts long enough for queueing and operator retries. GitHub Release publication preserves completed releases and rejects conflicting identity/assets; it does not approve a host operation. GitHub artifact downloads require approved outbound HTTPS/API/blob access; redirected storage requests never receive the GitHub bearer token. See [artifact API](https://docs.github.com/en/rest/actions/artifacts) and [runner network requirements](https://docs.github.com/en/actions/reference/runners/self-hosted-runners).

The shared deploy job uses a target concurrency group with `cancel-in-progress: false`. Concurrency does not guarantee pending-run order or preserve every pending run; revalidation after queueing and the installed machine/pool OS lock remain authoritative. Preserve the safe workflow summary and protected attempt/backup/hook evidence. Never upload operational configuration, private configuration digests, credentials or raw helper output.

## Independent host prerequisites and acceptance

Infrastructure separately installs/verifies the active toolkit and elevated deployment identity, distinct nonadministrator runtime, dedicated IIS target, TLS, external configuration/keys, protected catalogs and canonical state. Follow [installation](installation.md), [enrollment](host-enrollment.md), [standing authorization](automated-deployments.md) and [hook/recovery contracts](contracts.md). The workflow verifies the installed distribution before import; it never changes the active pin or provisions accounts, secrets or certificates.

A successful exact baseline precedes standing authority. Initial setup/cutover, downgrades, toolkit changes and exceptional recovery retain independent approvals. Generated release recovery requires a matching independent schema-1 `RecoveryApprovalId`; activation flags and a GitHub environment approval cannot create that authority. Revocation must remain effective on direct approval retries.

Before activation, record the reviewed consumer/shared revisions and inspect effective runner/environment settings, successful producer/negative admission tests, exact baseline, standing/hook policies and application-owned prerequisites. The separate prerequisite-validator PR #3 can report these observations without authorizing execution; integration should consume its read-only results alongside, rather than duplicate or bypass, installed approval/preflight checks. Complete the separately authorized [real-IIS deployment/recovery procedure](iis-verification.md) before claiming acceptance. This repository change performs no consumer integration or live qualification.

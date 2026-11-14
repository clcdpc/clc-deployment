# GitHub setup for a consumer deployment workflow

Use this checklist when an application repository adopts the toolkit. Infrastructure owns the GitHub controls and privileged runner; the application owns its workflow, release packaging and application checks. This guide describes the required setup, not verified live settings. It creates no runner, environment, approval or deployment.

All names below are examples: `example-org/example-app`, protected branch `master`, workflow `.github/workflows/deploy-dev.yml`, environment `example-app-dev` and runner group `example-app-dev-deployment`. Substitute the consumer's reviewed names consistently. This repository supplies neither that workflow nor a universal variable schema; keep the application's implementation and runbook in its own repository.

The branch-only manual path below remains supported. For separately enabled unattended routine deployment, use the [standing-policy and verified-workflow contract](automated-deployments.md). It replaces per-version host approval within one infrastructure-approved scope, while preserving privileged runner restrictions, independently pinned deployment code and separate DEV/production scopes. A tag-producing build never gains privileged-runner access.

## 1. Confirm ownership and available controls

Have an organization runner administrator configure runner access and a repository administrator configure branch/environment protection. Record who reviews workflow changes, authorizes host setup, approves exact release bytes and approves a deployment run. GitHub approval permits a job to run; it does not create the toolkit's protected host or release approval.

Check the organization's plan, repository visibility and inherited enterprise policies before promising these controls:

- Confirm **Selected workflows** is available and enforceable for the intended runner group. Repository access alone does not restrict which workflows in that repository can use it.
- On GitHub.com, private/internal environments and deployment branch rules require an eligible paid plan. Required environment reviewers on Free, Pro and Team are available only for public repositories; a private Team repository does not gain reviewers merely by creating an environment. See [GitHub's environment availability](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments).
- If a required admission or independent-review control is unavailable, leave privileged deployment disabled and the runner unavailable to repository jobs until infrastructure reviews an equivalent externally enforced control or the plan changes. Do not substitute labels, a variable, a YAML condition or public repository visibility for the missing protection.

## 2. Protect workflow and release source

In repository **Settings → Rules → Rulesets** or **Settings → Branches**, protect the deployment/release branch. Require pull requests, independent reviews and the consumer's required verification checks. Prevent force pushes/deletion and restrict bypass. Require infrastructure review of `.github/workflows/`, release/approval selection code and dependency/toolkit pins, using enforced code-owner review where supported.

Keep the deployment workflow manual-only (`workflow_dispatch`) on the approved protected branch. Its admission checks should reject the wrong repository, event, ref, unprotected ref and mismatched workflow/source commit. Protecting a branch name does not pin its bytes forever: record and review the full workflow SHA for each run. Do not admit PR refs, arbitrary branches or tags through this branch-only path.

For the optional automated path, a hosted completion/admission job may trigger trusted deployment code on that protected branch using release selectors only. Keep the tag's checkout/code on the isolated producer runner. Trusted deployment code independently verifies GitHub repository/tag/source/build/artifact provenance, repeats eligibility after queueing, and passes the exact package and verified identity to the installed standing-policy admission path. A completion event or job output alone grants no authority. Infrastructure separately approves any change to environment review gates for unattended deployment. If external runner controls cannot enforce the intended boundary, leave automation disabled.

Release packaging runs separately on an isolated build runner without IIS access or deployment credentials. Require the reviewed full source SHA, verify that the workflow definition and checkout resolve to the intended revision, and retain workflow/run/attempt/job and artifact provenance. Pin third-party actions and toolkit/dependency inputs to reviewed immutable identities. Ordinary PR CI must never select the privileged runner or execute contributor code with deployment authority. See [protected branches](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches).

## 3. Restrict the privileged runner before registration

In organization **Settings → Actions → Runner groups**, create the dedicated group before adding the privileged runner:

1. Under **Repository access**, select only the intended consumer repository. Keep access for public repositories disabled.
2. Under **Workflow access**, choose **Selected workflows** and allow exactly the reviewed workflow, for example:

   ```text
   example-org/example-app/.github/workflows/deploy-dev.yml@refs/heads/master
   ```

3. Save and inspect the effective policy, including inherited enterprise restrictions. Do not leave another group or repository-level registration that gives the same privileged host a broader route.
4. After the independent host prerequisites are complete, register the runner directly in this restricted group. Do not temporarily place it in a broadly accessible default group.

GitHub requires a branch pin for a non-reusable workflow. Reusable workflows can use a branch, tag or full SHA, but access applies only to jobs directly defined in the selected workflow. A selected caller does not automatically admit a job defined in another reusable workflow. See [runner-group access controls](https://docs.github.com/en/enterprise-cloud@latest/actions/how-tos/manage-runners/self-hosted-runners/manage-access).

The consumer job must select both the group and the intended Windows/x64/target labels. Labels route work; they do not authorize it. Neither an `if` guard nor an environment prevents another permitted workflow from requesting that host. Keep ordinary CI runners separate.

Host prerequisites still include the elevated deployment identity, distinct nonadministrator runtime identity, trusted PowerShell and dependencies, authenticated bootstrap/installed toolkit, protected paths, configuration, IIS/TLS and independent approvals. The runner service and script workspace are privileged infrastructure. Use [distribution installation](installation.md) and [host enrollment](host-enrollment.md); GitHub settings do not install or qualify any of them.

## 4. Create and protect the deployment environment

In repository **Settings → Environments**, create the exact environment named by the privileged job, for example `example-app-dev`, before enabling it:

1. Add independent **Required reviewers** and enable **Prevent self-review**. GitHub needs only one of the listed reviewers to approve, not every listed person.
2. Disable **Allow administrators to bypass configured protection rules** where supported. Restrict who can change the environment and document any unavoidable administrative trust.
3. Under deployment branches/tags, choose **Selected branches and tags**, add a **Branch** rule for the exact protected branch `master`, and add no tag or PR-ref rules for this branch-only workflow.
4. Confirm the privileged job explicitly names this environment. An environment elsewhere in the workflow does not protect an unrelated job.

Do not rely on **Protected branches only** without inspecting real branch protection: GitHub permits all branches under that option when no branch protection rules exist. A misspelled/new environment referenced by YAML can also be created without protection. Verify the exact environment and rules rather than its mere existence. See [environment configuration](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments) and [deployment protection semantics](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments).

## 5. Set the consumer's repository variables

Use repository **Settings → Secrets and variables → Actions → Variables**. Read the consumer workflow for its actual names and required values. These illustrative names describe the common pattern; adding them alone does not make a workflow consume them:

| Example variable | Value and meaning |
| --- | --- |
| `APP_DEV_DEPLOYMENT_ENABLED` | Leave absent or `false` until infrastructure explicitly authorizes activation; then exact string `true` |
| `APP_DEV_RUNNER_ADMISSION_READY` | Exact string `true` only after effective external runner access has been independently verified |
| `APP_DEV_RUNNER_GROUP` | Exact restricted group name, for example `example-app-dev-deployment` |
| `APP_DEV_RUNNER_LABELS` | Nonempty JSON array of the installed runner's labels, for example `["self-hosted","Windows","X64","example-app-dev"]` |

Use repository-scoped variables for admission that runs before the environment job, and for runner selection. Environment-scoped variables cannot supply values to a separate admission job that does not reference that environment. Check for conflicting organization/environment values and validate missing or malformed inputs before routing a privileged job. A small hosted admission job can do this without privileged host access.

These variables are nonsecret assertions, not evidence or authority. Users with repository write access can manage repository variables, so `true` must never replace runner restrictions, independent environment review or protected host approvals. Keep credentials and operational application configuration out of variables, source and artifacts. See [configuration variables](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-variables).

## 6. Keep permissions and release approval separate

- Set explicit minimum `GITHUB_TOKEN` permissions. A workflow reading its repository and Actions artifacts commonly needs `contents: read` and `actions: read`; grant writes only to a separate job that actually requires them. A repository token does not automatically read another private repository. If private toolkit acquisition needs a separate credential, use an independently provisioned read-only secret scoped to that source, never a privileged host credential. See [token permissions](https://docs.github.com/en/actions/tutorials/authenticate-with-github_token).
- The privileged job consumes authorized bytes through authenticated installed tooling. It must not build from a checkout, execute downloaded application scripts, author policies or hand-build approvals, install credentials or silently recover a failed attempt. Only the independently installed standing-policy admission path may derive a generated exact approval from a release independently verified by trusted workflow code under protected standing authority. Host enrollment and release approval remain distinct authorities.
- Identify the exact producer workflow/source/run/attempt/job/artifact. Verify both the downloaded transport archive and inner release ZIP as applicable; they are different hashes. Retain approved bytes and provenance independently before Actions artifacts expire. Build success, provenance and `Test-ClcRelease` establish evidence, not approval. The protected [release approval](contracts.md#existing-protected-authority-and-preflight) binds the target and exact bytes before execution.
- Use a stable concurrency group per deployment target with `cancel-in-progress: false` so a newer run does not cancel an active mutation. This does not preserve every pending dispatch or guarantee dispatch order. The toolkit's machine/pool OS lock remains authoritative across repositories and operator invocations. See [GitHub concurrency](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency).

## 7. Review before activation

Record the consumer commit and effective settings, then check:

- The approved repository/workflow/ref is the only route to the privileged group; ordinary CI and PR jobs have no such access.
- The protected branch requires review, the exact environment has independent review/no self-review and the intended branch restriction, and bypass permissions are understood.
- Runner group/labels match the host; activation is still disabled until the host/runtime/bootstrap/toolkit and protected authorizations have been independently verified.
- Release selection matches exact approved provenance and bytes; no application-specific configuration, keys, database setup or service behavior has been moved into this toolkit.

If negative admission testing is needed, use a separately authorized disposable runner without deployment authority, not the live IIS host. Record what was actually tested and what remains unverified. Enable the consumer activation flag only after infrastructure approves the completed prerequisites and the intended live operation. Then follow the consumer's application runbook and [IIS deployment/recovery procedure](deployment.md). A documentation review or green hosted CI run does not establish live runner admission, host qualification or permission to deploy.

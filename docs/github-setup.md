# GitHub setup for a consumer deployment workflow

Use this checklist when an application repository adopts the toolkit. Infrastructure owns the GitHub controls and privileged runner; the application owns its workflow, release packaging and application checks. This guide describes the required setup, not verified live settings. It creates no runner, environment, approval or deployment.

All names below are examples: `example-org/example-app`, protected branch `master`, workflow `.github/workflows/deploy-dev.yml`, environment `example-app-dev` and runner group `example-app-dev-deployment`. Substitute the consumer's reviewed names consistently. This repository supplies neither that workflow nor a universal variable schema; keep the application's implementation and runbook in its own repository.

The recommended integration is automatic, tag-driven release production followed by trusted automatic deployment consumers under [standing authorization](automated-deployments.md). Follow the [verified workflow integration contract](verified-workflow-integration.md) for the exact host API and trust boundary. Routine IIS deployment does not use `workflow_dispatch`. Standing authority replaces per-build manual host approval only within an independently approved scope after a successful independently approved baseline. Initial setup, exact manual approvals, exceptional recovery and toolkit upgrades retain their separate procedures below.

## Recommended release and deployment flow

1. An eligible release tag starts the consumer's release workflow on an isolated build runner without IIS access or deployment credentials. That workflow builds and retains the exact package and provenance.
2. Successful release-workflow completion starts trusted automatic deployment code from the protected branch, for example through `workflow_run` with `types: [completed]`. A hosted admission job verifies the producer and release eligibility before routing a privileged job. The completion event alone grants no authority.
3. The privileged consumer repeats tag/source/eligibility checks after queueing, verifies exact build/artifact identity and bytes, and supplies the inbox ZIP and verified-release JSON to the independently installed toolkit. Protected standing policy admits a schema-2 exact approval under the machine/pool lock before the existing deployment lifecycle runs.

Use `Test-ClcRelease -ReleaseTag` for centralized classification: `v1.0.0-dev.1` is DEV, `v1.0.0` is Production, and beta/RC are artifact-only. Keep DEV and production targets, environments and policies separate. Neither the tag's checkout nor its build workflow gains privileged-runner access.

The consumer's **release workflow** may also permit `workflow_dispatch` to request a fresh build against an existing immutable tag/commit. This is a build request, not a manual deployment trigger or approval. Its successful completion goes through the same automatic consumer and all provenance, eligibility, ordering and standing-policy checks. A fresh run or later run attempt for the same tag/commit may qualify; moving a tag, selecting an arbitrary branch or directly dispatching routine IIS deployment is not this path. This describes consumer integration, not an additional trigger in this repository's toolkit publication workflow.

For `workflow_run`, the consumer workflow must exist on the default branch; its workflow ref/SHA identify protected deployment code, while the triggering run identifies the separate tagged application source. Check successful conclusion explicitly. See [GitHub's completion-event semantics](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_run).

## 1. Confirm ownership and available controls

Have an organization runner administrator configure runner access and a repository administrator configure branch/environment protection. Record who reviews workflow changes, authorizes host setup and the exact baseline, installs/revokes standing policy, and approves environment gates and activation. Any GitHub per-run approval permits a job to run; it does not create the toolkit's protected host or release approval.

Check the organization's plan, repository visibility and inherited enterprise policies before promising these controls:

- Confirm **Selected workflows** is available and enforceable for the intended runner group. Repository access alone does not restrict which workflows in that repository can use it.
- Check environment and branch/tag rule availability for the plan and repository visibility. Required reviewers, if the approved policy calls for them, have additional plan limits; a private Team repository does not gain reviewers merely by creating an environment. Routine unattended deployment does not require a human approval for each run. See [GitHub's environment availability](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments).
- If a control required by the approved admission or environment policy is unavailable, leave privileged deployment disabled and the runner unavailable to repository jobs until infrastructure reviews an equivalent externally enforced control or the plan changes. Do not substitute labels, a variable, a YAML condition or public repository visibility for the missing protection.

## 2. Protect workflow and release source

In repository **Settings → Rules → Rulesets** or **Settings → Branches**, protect the branch supplying trusted deployment code and eligible release source. Require pull requests, independent reviews and the consumer's required verification checks. Prevent force pushes/deletion and restrict bypass. Require infrastructure review of `.github/workflows/`, admission/support code, release/approval selection code and dependency/toolkit pins, using enforced code-owner review where supported. Separately protect release tags: restrict creation to authorized producers/operators and prohibit updates/deletion. Tag protection does not replace source eligibility checks.

Keep the automatic deployment consumer and its executable support code on the approved protected branch. Reject the wrong repository, completion/producer event, workflow/ref or unprotected deployment code, PR builds, ineligible tags/source and mismatched build/artifact identity. Protecting a branch name does not pin its bytes forever: record and verify the full reviewed deployment workflow/support-code revision independently of the tagged application's commit.

Use completion data only as selectors for independent GitHub verification, never as executable privileged code or authority. Trusted deployment code establishes repository identity, immutable tag/object and commit, source eligibility, reviewed producer files, successful exact build run/attempt/job, artifact ownership, transport digest and inner package identity. Repeat tag/source/eligibility checks after queueing. Do not check out or execute tag/PR code on the privileged runner. If external runner controls cannot enforce this boundary, leave automation disabled.

Release packaging runs separately on an isolated build runner without IIS access or deployment credentials. Require the reviewed full source SHA, verify that the workflow definition and checkout resolve to the intended revision, and retain workflow/run/attempt/job and artifact provenance. Pin third-party actions and toolkit/dependency inputs to reviewed immutable identities. Ordinary PR CI must never select the privileged runner or execute contributor code with deployment authority. See [protected branches](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches).

## 3. Restrict the privileged runner before registration

In organization **Settings → Actions → Runner groups**, create the dedicated group before adding the privileged runner:

1. Under **Repository access**, select only the intended consumer repository. Keep access for public repositories disabled.
2. Under **Workflow access**, choose **Selected workflows** and allow exactly the trusted automatic deployment consumer at its protected code ref, for example:

   ```text
   example-org/example-app/.github/workflows/deploy-dev.yml@refs/heads/master
   ```

3. Save and inspect the effective policy, including inherited enterprise restrictions. Do not leave another group or repository-level registration that gives the same privileged host a broader route.
4. After the independent host prerequisites are complete, register the runner directly in this restricted group. Do not temporarily place it in a broadly accessible default group.

GitHub requires a branch pin for a non-reusable workflow. Reusable workflows can use a branch, tag or full SHA, but access applies only to jobs directly defined in the selected workflow. A selected caller does not automatically admit a job defined in another reusable workflow. See [runner-group access controls](https://docs.github.com/en/enterprise-cloud@latest/actions/how-tos/manage-runners/self-hosted-runners/manage-access).

The privileged consumer job must select both the group and the intended Windows/x64/target labels. Admit the protected deployment consumer, not the tagged release producer, ordinary CI or a PR workflow. Labels route work; they do not authorize it. Neither an `if` guard nor an environment prevents another permitted workflow from requesting that host. Keep ordinary CI runners separate, and apply separate DEV/production runner admission scopes.

Host prerequisites still include the elevated deployment identity, distinct nonadministrator runtime identity, trusted PowerShell and dependencies, authenticated bootstrap/installed toolkit, protected paths, configuration, IIS/TLS and independent approvals. The runner service and script workspace are privileged infrastructure. Use [distribution installation](installation.md) and [host enrollment](host-enrollment.md); GitHub settings do not install or qualify any of them.

## 4. Create and protect the deployment environment

In repository **Settings → Environments**, create the exact environment named by the privileged job, for example `example-app-dev`, before enabling it:

1. Have infrastructure approve the environment policy for automatic deployment under standing authority. Unattended routine deployment must not wait for a human reviewer on each run. Changing existing review gates requires separate infrastructure authorization; this guide does not authorize removing them. If a scope retains per-run **Required reviewers**, enable **Prevent self-review** and record that it waits for approval. GitHub needs only one listed reviewer to approve.
2. Disable **Allow administrators to bypass configured protection rules** where supported. Restrict who can change the environment and document any unavoidable administrative trust.
3. Under deployment branches/tags, choose **Selected branches and tags** and allow the trusted consumer's actual execution ref. For the protected-default-branch `workflow_run` model, add a **Branch** rule for `master`; the application release tag is verified separately and is not the consumer's execution ref. Do not add broad tag or PR-ref rules to admit producer code.
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

These variables are nonsecret assertions, not evidence or authority. Users with repository write access can manage repository variables, so `true` must never replace runner restrictions, the infrastructure-approved environment policy or protected host approvals. Resolve target and standing-policy selectors from reviewed trusted configuration; do not let a producer select arbitrary authority. Keep credentials and operational application configuration out of variables, source and artifacts. See [configuration variables](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-variables).

## 6. Keep permissions and release approval separate

- Set explicit minimum `GITHUB_TOKEN` permissions. A workflow reading its repository and Actions artifacts commonly needs `contents: read` and `actions: read`; grant writes only to a separate job that actually requires them. A repository token does not automatically read another private repository. If private toolkit acquisition needs a separate credential, use an independently provisioned read-only secret scoped to that source, never a privileged host credential. See [token permissions](https://docs.github.com/en/actions/tutorials/authenticate-with-github_token).
- The privileged job consumes authorized bytes through authenticated installed tooling. It must not build from a checkout, execute downloaded application scripts, author policies or hand-build approvals, install credentials or silently recover a failed attempt. Only the independently installed standing-policy admission path may derive a generated exact approval from a release independently verified by trusted workflow code under protected standing authority. Host enrollment and release approval remain distinct authorities.
- Identify the exact producer workflow/source/run/attempt/job/artifact. Verify both the downloaded transport archive and inner release ZIP as applicable; they are different hashes. Retain approved bytes and provenance independently before Actions artifacts expire. Build success, provenance and `Test-ClcRelease` establish evidence, not approval. The protected [release approval](contracts.md#existing-protected-authority-and-preflight) binds the target and exact bytes before execution.
- Use a stable concurrency group per deployment target with `cancel-in-progress: false` so a newer run does not cancel an active mutation. This does not preserve every pending run or guarantee deployment order; repeat admission after queueing. The toolkit's machine/pool OS lock remains authoritative across repositories and operator invocations. See [GitHub concurrency](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency).

## 7. Preserve independently authorized operations

- Initial installation/enrollment and legacy cutover require exact protected machine/config/bootstrap/toolkit/operation authority under [host enrollment](host-enrollment.md). The trusted consumer may invoke missing setup only under that authority. Standing release policy cannot authorize setup or the first deployment; establish a successful independently approved baseline first.
- Schema-1 [exact manual release approvals](deployment.md#prerequisites-and-commands) remain supported without standing policy. They bind exact target/source/build/package bytes for independently authorized operations; GitHub dispatch or environment approval cannot create them. Downgrades retain their separate exact approval, explicit flag and reason.
- [Exceptional recovery](deployment.md#explicit-recovery) requires an explicit operator choice and compatible verified retained material. A generated selected release additionally requires an independent matching schema-1 `RecoveryApprovalId`, including after standing-policy revocation. An automatic consumer must not silently recover a failed attempt.
- [Toolkit installation/upgrades](installation.md) require independent authentication and exact version installation/activation with compatibility review. Preserve old versions and recovery evidence; neither enrollment retries nor a tagged application release may change the active toolkit pin.

## 8. Review before activation

Record the consumer commit and effective settings, then check:

- The approved repository/workflow/ref is the only route to the privileged group; ordinary CI and PR jobs have no such access.
- The protected branch requires independent review/checks, release tags cannot move, and the exact environment has the approved automatic-deployment policy and consumer-ref restriction. Any retained human gates and bypass permissions are understood.
- Runner group/labels match the host; activation is still disabled until the host/runtime/bootstrap/toolkit and protected authorizations have been independently verified.
- The exact baseline succeeded and the independently installed standing policy matches the intended target/application/environment/channel/repository/build workflow/job/lineage. Activation flags do not install or enable that policy, and revocation blocks direct generated-approval retries too.
- Successful tag builds and permitted fresh builds of existing tags enter the same automatic admission path. PR/branch builds, beta/RC deployment, source substitution and older builds cannot reach mutation through that path. Release selection matches verified provenance and bytes; application-specific configuration, keys, database setup and service behavior remain application-owned.

If negative admission testing is needed, use a separately authorized disposable runner without deployment authority, not the live IIS host. Record what was actually tested and what remains unverified. Enable the consumer activation flag only after infrastructure approves the completed prerequisites and intended automatic scope. Eligible release completions can then deploy without a separate manual deployment trigger. Follow the consumer's application runbook and [IIS deployment/recovery procedure](deployment.md). A documentation review or green hosted CI run does not establish live runner admission, host qualification or permission to deploy. Actual Windows Server 2022/IIS and consumer deployment/recovery qualification remain NOT RUN.

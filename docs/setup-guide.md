# Deployment Setup Guide

Follow this guide to configure a new application and deployment target. GitHub UI configuration → optional GitHub setup check → separate host preparation and deployment preflight → authorized deployment → application acceptance. GitHub settings route trusted work; independently protected host approvals authorize execution.

The deployment/toolkit procedures describe the implementation at [c09a841](https://github.com/clcdpc/clc-deployment/tree/c09a841871a1552ec131c12cdd8b4c50f930f5f9); the optional [GitHub checker](github-setup-check.md) is documented separately. Specialized documents linked below define the exact contracts. **Actual Windows Server 2022/IIS and independent-identity qualification remain NOT RUN.** Examples use synthetic values and grant no operational authority.

## 1. Before you begin

1. Agree on the following worksheet before changing settings. Use the application's reviewed values consistently; do not copy synthetic identities into production.

   | Decision | Example or expected input | Configured in |
   | --- | --- | --- |
   | Consumer repository and integration branch | `example-org/example`, `master` or `main` | Consumer configuration and repository settings |
   | Application and target | `example`, `example-dev` | Consumer configuration and protected host target |
   | Channel and deployment environment | `DEV`, `example-dev`; separately `Production`, `example-production` | Protected routing, GitHub environment and host authority |
   | Producer and deployment caller | `.github/workflows/build.yml`, `.github/workflows/deploy.yml`; producer job and exact REST display name | Workflows and consumer configuration |
   | Dedicated group and labels | `example-dev`; `self-hosted,Windows,X64,example-dev` | Organization runner controls, registration and protected routing |
   | Host/IIS and identities | Independently expected machine UUID, site/pool/root, deployment SID and distinct runtime account/SID | Infrastructure records and protected enrollment |
   | Shared orchestration | Reviewed full 40-character source SHA, where shared workflows are used | Reusable `uses` pins and `orchestration.sharedRevision` |
   | Installed toolkit | Approved version, source SHA, distribution digest, module inventory and absolute manifest path | Independent installation approval and protected host policy |

2. Assign ownership. Application developers own build qualification, validator/readiness integration, configuration/key/database compatibility and acceptance. Repository administrators enforce branch/tag/workflow/environment controls. Organization runner administrators provision and restrict groups and registrations. Windows/IIS infrastructure administrators own accounts, components, TLS, ACLs, external configuration, enrollment, toolkit pins and protected approvals. Independently authorized deployment operators execute approved releases and recovery.
3. Confirm the repository's exact `owner/name` and integration branch in GitHub; authorized read-only repository/branch API observations must describe that same consumer. Select the [shared integration pattern](shared-release-orchestration.md#two-integration-patterns), or document the intentionally different workflow architecture. Obtain separate infrastructure authorization before real host inspection or changes. This guide does not authorize consumer changes or host operations.

## 2. Configure the repository

### Protect the integration branch

1. In **Repository Settings > Rules > Rulesets**, create or inspect an active branch ruleset targeting the exact integration branch. Existing classic **Settings > Branches** protection can also supply controls. Include inherited organization rules in the review.
2. Keep the deployment caller and security-sensitive configuration on that protected branch. Establish the exact repository/branch identity and inspect its current commit before reviewing workflow files.

### Configure required status checks

1. Enable **Require status checks to pass** for the integration branch and select the application's relevant build/test checks by their actual reported names. Confirm they run and gate integration; an empty list does not establish required CI.
2. Mandatory PR reviews, reviewer counts, CODEOWNERS and extra PR-branch protection are not universal requirements. Apply additional controls only under the application's own policy.

### Restrict force pushes and deletion

1. Enable **Block force pushes** and **Restrict deletions** in the applicable ruleset. With classic protection, leave force pushes and deletions disallowed.
2. Inspect effective controls for the exact branch, including layered rules. A ruleset name or a protected-branch indicator alone does not prove each control is enforced.

### Restrict branch bypass access

1. Review ruleset bypass actors/modes and classic administrator enforcement. Prevent broad administrator, owner, repository-role or enterprise-role bypass from defeating required controls; another independently enforcing applicable rule may supply the restriction.
2. Retain infrastructure control of specifically selected actors. Do not broaden bypass to make automation work. GitHub can omit bypass actors from read-only API responses; retain that visibility limitation without assuming an empty actor list or demanding write-capable diagnostic credentials.
3. Verify effective branch rules and available classic settings through authorized read-only inspection. See [GitHub setup](github-setup.md#protect-source-and-executable-workflow-code) and [GitHub rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/creating-rulesets-for-a-repository).

### Protect trusted workflow and configuration files

1. Retain infrastructure review/control of release/deployment workflows, `.clc/release.json`, security-sensitive supporting scripts and immutable dependency pins.
2. In the shared model, list those consumer files in `trustedFiles`, including the configuration and producer/deployment workflows. Source admission compares their exact bytes with protected integration source. A tag or artifact cannot supply alternative trusted deployment code.
3. Explicitly enable `sourcePolicy.allowUnmergedDevTags` in both protected consumer configuration and host standing policy only when that source class is intended. PR approval or protection of the tagged feature branch is not a substitute for the trusted-file comparison.

## 3. Protect release tags

### Choose tag patterns and channel coverage

1. In **Repository Settings > Rules > Rulesets**, use tag rulesets covering every release tag for the intended channel. A simple `v*` target covers the supported version family. The optional checker supports this straightforward prefix convention; the API represents it as `refs/tags/v*`.
2. Preserve the release contract: `vMAJOR.MINOR.PATCH-dev.N` is **DEV**; `vMAJOR.MINOR.PATCH` is **Production**; beta/RC tags are artifact-only; `-test.N` is unsupported. Environment/host names do not define a release channel. Production coverage must include stable tags.
3. Avoid ambiguous exclusions when establishing coverage. Complex overlap or exclusions require manual inspection. See [release source rules](shared-release-orchestration.md#source-and-ordering).

### Configure release-tag creation restrictions

1. Enable **Restrict creations** for the applicable tag pattern. Independently select only the release identities that need creation authority and review their bypass scope.
2. Verify that ordinary unauthorized actors cannot create eligible release tags under effective rules. Creating/pushing an eligible DEV tag is the deliberate release authorization step in the shared model; tagger metadata does not authenticate the actor.

### Configure release-tag update restrictions

1. Enable **Restrict updates** for the applicable pattern so an existing release tag cannot be moved through ordinary repository access.
2. Inspect effective update restrictions and any bypass. A release tag must retain its exact source binding; rebuilding does not authorize moving it.

### Configure release-tag deletion restrictions

1. Enable **Restrict deletions** for the applicable pattern.
2. Verify effective deletion restrictions separately from update/creation controls. Preserve published source identity and retained release evidence.

### Restrict tag bypass access

1. Inspect bypass actors/modes on every applicable tag ruleset. Keep creation authority narrowly controlled; do not grant broad administrator or role bypass merely to simplify releases.
2. Ensure permitted creation actors do not silently defeat update/deletion restrictions. Separate layered rules can enforce those controls independently. Review observable actors and record hidden-list limitations described in [the checker's capabilities](github-setup-check.md#api-inventory-and-capabilities).

### Verify effective tag enforcement

1. Set the required rulesets to **Active**. Evaluation mode records hypothetical effects and does not enforce protection.
2. Inspect repository and inherited tag rules, their patterns, exclusions, each of the three restrictions and bypass scope. Multiple active rulesets can supply separate controls. Record the effective outcome for DEV and Production independently; do not test destructive tag operations on real releases.

## 4. Configure release and deployment workflows

### Configure the release workflow

1. Identify the producer's exact `.github/workflows/*.yml` path, workflow `name`, successful packaging job ID and, where configured, exact GitHub REST job display name.
2. Use the [conventional build example](examples/shared-conventional-build.yml), or retain qualified application CI and add the [prequalified packaging tail](examples/shared-prequalified-build.yml). Review application validator/readiness integration and application-owned `web.config` validation in CI.
3. For the supported shared automatic arrangement, retain `push.tags: ['v*']` and any explicitly intended protected-branch snapshot trigger. Produce the exact qualified artifact `clc-package-<fullSourceCommit>-<runId>-<attempt>` containing only `release.zip`.

### Configure the deployment workflow

1. Start from the [shared publication/deployment caller](examples/shared-application-deploy.yml) on the protected integration branch. Pin shared build/publication/deployment `uses` references to the reviewed full SHA; do not use a mutable branch or version tag as the executable pin.
2. Set `orchestration.sharedRevision` to that same SHA and `orchestration.deploymentWorkflowPath` to the protected caller path in [the consumer configuration](examples/shared-release.json). The package builder revision must match this pin. Installed host-toolkit identity is independently pinned and is not selected by the caller's SHA.
3. Admit only the workflow definitions that actually define privileged jobs. Keep ordinary PR/fork CI isolated from privileged runners and host credentials. Review [immutable workflow execution](shared-release-orchestration.md#immutable-workflow-execution) and [the verified handoff](verified-workflow-integration.md).

### Configure producer handoff

1. In the shared model, set `workflow_run.workflows` to the producer's exact workflow `name` and `types: [completed]`. Keep the caller on the default/protected integration branch and gate consumption on success as in the example.
2. Pass the producer source commit, run ID and attempt. Trusted shared code independently authenticates source eligibility, successful producer/job/artifact ownership, transport/package bytes and protected routing; a completion event selects evidence and grants no host authority.
3. For explicit manual redeployment, retain protected `workflow_dispatch` selection of the exact reference/source/producer attempt and pass `automatic: false` on that path. Shared code verifies the actual actor's repository write/maintain/admin authority and repeats release/host admission. Do not hard-code `automatic: true` on a dispatch-capable caller. Planning is a separately authorized `ValidateOnly` request, not a lifecycle hook or sandbox.

### Review intentional workflow differences

Review application-owned workflow behavior under the application's own policy. The GitHub setup checker does not read workflow contents or require a shared workflow, `.clc/release.json`, `workflow_run` handoff or automatic trigger. Shared/direct deployment and automatic/manual redeployment receive the same GitHub settings checks. Consumer migration, including SSRS Web, remains a separate task.

### Configure release immutability

In **Repository Settings > General > Releases > Release immutability**, enable **Enable release immutability**, or verify owner-enforced immutability. The optional checker uses the supported read-only setting API when permitted; an ambiguous 404 requires this UI inspection. Do not create a test release to infer the setting.

## 5. Configure GitHub environments

### Create deployment environments

1. In **Repository Settings > Environments > New environment**, create the exact configured deployment environment before use. Use consistent spelling/case across toolkit selectors, routing and host target records, even though GitHub environment names are case-insensitive.
2. Configure DEV and Production separately. Required reviewers, wait timers and custom protections are optional application-policy choices. Unattended deployment does not universally require a manual approval gate, including for public repositories.

### Restrict environment branches

1. Under **Deployment branches and tags**, choose **Selected branches and tags**. Add exactly one **branch** rule for the configured integration branch, with no wildcard or additional branch/tag rules.
2. Inspect the saved policy: custom branch policies enabled, protected-branches mode disabled, one branch rule matching the integration branch. **Protected branches only** does not establish this exact restriction for the checker. Application tag source is verified separately; do not admit tags merely because releases are tagged.
3. Verify the environment's exact name, effective restrictions and optional protection behavior through authorized read access. See [GitHub environment settings](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments).

## 6. Configure self-hosted runners

### Create a dedicated runner group

1. Have the organization runner administrator open **Organization Settings > Actions > Runner groups > New runner group** and create the agreed dedicated group. Check plan/enterprise controls support the required effective restrictions before registering a privileged host.
2. Keep DEV and Production groups separate. Never select a default or fallback group because the expected name is missing. A consumer variable naming a group does not provision or secure it.

### Restrict runner repository access

1. Set **Repository access > Selected repositories** to the independently authorized consumer repositories and ensure the intended caller is admitted. The diagnostic verifies this caller's membership; infrastructure reviews the complete intended list.
2. Keep public-repository eligibility disabled for a private caller. A public caller requires that eligibility enabled **within the dedicated selected-repository and selected-workflow boundary**; this is not permission for unrestricted public self-hosted execution. Retain infrastructure review of public PR/fork exposure without inventing extra application approval gates.
3. Inspect inherited enterprise restrictions and ensure there is no alternate registration/group exposing the same host more broadly. See [GitHub runner-group controls](https://docs.github.com/en/enterprise-cloud@latest/actions/how-tos/manage-runners/self-hosted-runners/manage-access) and [the CLC GitHub checklist](github-setup.md#restrict-the-privileged-runner-externally).

### Restrict runner workflow access

1. Enforce **Selected workflows** for the exact job-defining workflow. For shared deployment, select `clcdpc/clc-deployment/.github/workflows/application-deploy.yml@<reviewed-full-SHA>`, replacing the placeholder with the approved revision. Allowlisting only its consumer caller does not admit the callee's jobs.
2. An application-owned direct workflow uses its exact consumer path at `@refs/heads/<integrationBranch>`. Admit only independently approved workflow definitions. The GitHub setup check runs on hosted infrastructure and needs no runner-group admission.
3. For shared code from another organization, inspect inherited enterprise group ownership and effective cross-organization admission. If exact effective restrictions cannot be established, leave deployment disabled and resolve the external boundary with infrastructure. The checker reports inaccessible settings as CHECK MANUALLY.

### Register runners and configure labels

1. Use the organization's Windows x64 runner registration instructions and select the dedicated group explicitly (`--runnergroup` in the registration command). Infrastructure supplies the registration credential outside source/logs and configures the service account and required service-logon rights.
2. Confirm `self-hosted`, `Windows`, `X64` and the agreed target-specific label (for example `example-dev`) on the registered runner. Shared protected routing requires the explicit Windows/x64 labels; the target label identifies the agreed target convention, not machine authority.
3. Set consumer expectations to that existing group and labels. For a diagnostic caller using variables, `vars.EXPECTED_RUNNER_GROUP` and its labels input describe those settings; `.clc/release.json` supplies shared deployment routing. Diagnostic labels are 1–10 comma-separated values without whitespace, each 1–64 ASCII letters/digits/underscores/dots/hyphens starting with a letter or digit. An explicitly empty labels input fails; omission retains the diagnostic's three default labels. Shared routing accepts 3–8 explicit labels including the three Windows/x64 defaults; use that narrower bound when configuring both.
4. Inspect the group's runner list for at least one **online** runner with every expected label. Confirm registration and workflow access separately; online labels do not prove host installation or authorization. Ordinary PR/fork jobs must never reach this infrastructure.

## 7. Configure deployment routing and activation

### Configure protected deployment routing

1. For shared workflows, use the existing strict `.clc/release.json` [example](examples/shared-release.json) and [configuration contract](shared-release-orchestration.md#minimal-consumer-configuration). Set application/repository/integration identity, producer, trusted files, `requiredToolkitContractVersion: 2` and the reviewed orchestration SHA.
2. Match each `targets` entry to the independently enrolled host target. For example, application `example` / channel `DEV` routes to target `example-dev`, environment `example-dev`, group `example-dev` and labels `self-hosted,Windows,X64,example-dev`. Its `standingAuthorizationId` selects independently installed policy for later automation. Production uses distinct target/environment/group values.
3. Match host `applicationId`, `targetId` and `environmentName` to those selections. Host `runtimeEnvironment` is `Production` or `Staging`; it does not select the deployment channel. Keep host paths, credentials and approval records out of consumer routing.

### Activate only under independent authority

1. Leave `enabled` and `runnerAdmissionReady` false during setup. They assert routing activation and externally established runner admission; they do not enforce runner security or grant deployment authority.
2. After an independently approved successful baseline, approved standing policy and accepted external controls, activate only the separately authorized route. Missing current release/standing policy and disabled indicators can be legitimate during commissioning. Never enable deployment merely to obtain a passing diagnostic.

## 8. Prepare the Windows/IIS host

### Prepare Windows and IIS

Have infrastructure verify the following against [host enrollment](host-enrollment.md#trust-and-prerequisites), [the public preflight contract](contracts.md#existing-protected-authority-and-preflight) and [IIS verification prerequisites](iis-verification.md#prerequisites):

1. Windows Server 2022 x64 (build 20348), x64 PowerShell 7, x64 .NET/ASP.NET Core 10 runtimes and the hosting bundle/ANCM 20 with `AspNetCoreModuleV2`; protected installed `dotnet`/`appcmd` helpers and required IIS management components. The application targets `net10.0` / `win-x64` / in-process hosting.
2. One dedicated site, one root application/virtual directory and one dedicated pool with the enrolled physical root. Use Integrated pipeline, No Managed Code, 32-bit disabled, `maxProcesses=1`, overlapping rotation disabled and `loadUserProfile=true`. Site `ServerAutoStart=true` and site Started; the pool may be Started or Stopped under the supported state rules. Review recycling/idle behavior without assuming a second worker is permitted.
3. Trusted HTTPS readiness DNS hostname, routing, binding/address/port, certificate/private-key availability, SAN/validity/server-auth chain/revocation and SNI consistent with enrollment. The application supplies anonymous exact-release `/health/ready`; a generic HTTP 200 is insufficient.
4. Existing protected external application configuration and persistent Data Protection key location, including application-owned configuration revision/key compatibility and bootstrap environment variables. Confirm actual service profile/key usability under application acceptance; do not copy keys or configuration into packages or replacement trees.

### Configure deployment and runtime identities

1. Provision the admitted deployment account externally, with local Administrators membership only on managed IIS servers and an enabled elevated token for deployment/recovery/host inspection. Provision runner service-logon rights and runtime logon/profile rights for the selected account model through infrastructure policy; enrollment does not install accounts, passwords or rights.
2. Use a distinct runtime account/SID that is nonadministrator, including group-derived authority. Conventional service-account pools must already have credentials configured. Enrollment can create a pool only for an already locally installed managed service account; it does not install that account or retrieve secrets.
3. Verify effective runtime write isolation and actual access observations. Approved application validators/hooks run elevated under deployment authority without sandboxing. Independent approval against this administrator remains procedural.

### Protect directories and external configuration

1. Use canonical disjoint local NTFS application, inbox, operational-configuration, key, toolkit/policy/catalog/control and lock paths from the approved host configuration. Reject aliases, hard links, reparses, named streams, unsafe ancestry and unexpected files.
2. Retain infrastructure ownership/structural ACLs and protected ancestors. Application/inbox roots allow deployment Modify and runtime ReadAndExecute without writes. Keys permit the required runtime Modify without WRITE_DAC/WRITE_OWNER; configuration is protected and readable as required. Runtime must not write/replace application, toolkit, authority or control resources. Never grant the deployment account's individual SID protected-resource write ACEs; its elevated Administrators authority is not NTFS containment.
3. Accounts, secrets, certificates, trust, components, operational configuration and application bootstrap settings must already exist. Authorized enrollment can create approved dedicated directories/ACLs and missing stopped IIS settings/resources; existing directory ACLs are inspected, not automatically repaired. Review the exact [provisioning limits](host-enrollment.md#provisioning-and-preservation).

## 9. Install and configure the deployment toolkit

### Install and verify the toolkit

1. Obtain the reviewed distribution and independently authenticate source revision, producer/run/job/artifact and exact archive digest through the infrastructure procedure. Acquire reviewed verifier/bootstrap code through an already trusted channel **before first execution/import**. An unauthenticated checkout or downloaded verifier cannot authenticate itself; adjacent manifests/hashes are integrity claims.
2. From that trusted tooling, verify exact distribution/source/version/inventories using the existing command (variables are independently approved absolute paths/identities):

   ```powershell
   & "$trustedTools\Test-ToolkitDistribution.ps1" -ArchivePath $candidateZip `
       -ExpectedSha256 $approvedDigest -ExpectedSourceCommit $approvedSource -ExpectedVersion $approvedVersion
   ```

3. Follow [installation](installation.md#installation) for protected immutable version directories, installed-byte inspection and independently authorized host-policy publication. The manual extractor is `Expand-ToolkitDistribution.ps1` with `-ArchivePath`, `-ExpectedSha256`, `-ExpectedSourceCommit`, `-ExpectedVersion`, `-VersionRoot` and `-OperatorApprovalReference`; use its documented procedure. Never patch an installed version or change an active pin by supplying a different candidate to enrollment.
4. For first automated installation, use the authenticated format-2 packaged bootstrap and the fixed `%ProgramData%\CLC\Deployment\Enrollment` layout. Prepare the independently protected `host-authorizations/<authorizationId>.json`, existing handoff lock and evidence directory. Infrastructure approves exact machine/config/bootstrap/toolkit/operation/IIS/resource bindings using [the authorization schema](../schemas/host-enrollment-authorization.schema.json). No approval-writing command is provided.
5. Prepare nonsecret host-local `deployment.json` using [the exact schema](../schemas/deployment-configuration.schema.json) and [documented example](host-enrollment.md#host-local-deploymentjson). Bind existing external configuration/key paths, runtime account/SID, readiness URI and fixed enrollment root. The protected host policy independently pins active toolkit version/source/distribution/module inventory/manifest and the machine/helper/SID/catalog paths. Use [public contracts](contracts.md); consumer routing never supplies this authority.

### Enroll the target

1. Under separately authorized infrastructure scope, run the authenticated packaged bootstrap in a fresh trusted PowerShell process. Inspect and plan before any Apply:

   ```powershell
   & "$trustedBootstrap\tools\host\Get-ClcHostEnrollment.ps1" `
       -DeploymentConfigurationPath $hostDeploymentJson -AuthorizationId $infrastructureAuthorizationId
   & "$trustedBootstrap\tools\host\Initialize-ClcHostEnrollment.ps1" `
       -DeploymentConfigurationPath $hostDeploymentJson -AuthorizationId $infrastructureAuthorizationId -Operation Plan
   ```

2. Get/Plan are read-only and require the protected inspection handoff. Only genuine `ToolkitNotInitialized` or `TargetNotEnrolled` with an understood plan can proceed to separately authorized `Initialize-ClcHostEnrollment.ps1 -Operation Apply`, using the same configuration/authorization selectors and `-DistributionPath $independentlyApprovedToolkitZip` where required. Apply must have exact protected operation approval; it does not approve a release or upgrade an active pin.
3. Setting changes require an already Stopped/zero-worker pool. New pools require an installed managed account; conventional pools are reused. Enrollment never stops/starts/recycles a pool or executes application code. Legacy first cutover needs separate exact `first-cutover` authority, independent stop/zero-worker observation and verified retained backup before removal; follow [the cutover procedure](host-enrollment.md#first-cutover-and-failure-handling).
4. Reinspect installed bytes/protection and rerun Get/Plan. Expect `Ready`, `ReadyForDeployment=true` and an understood no-change plan. `ApplicationReleaseApproved` and `ApplicationReadinessVerified` remain false. `Incomplete`, `DriftDetected`, `RecoveryRequired` or prior resources/lock/intent/state with missing records requires independent reconciliation; never retry Apply as a repair.

## 10. Verify host state and optional automation

### Inspect existing deployment state

1. Inspect the existing canonical machine/pool lock and protected control root under separately authorized read-only scope. Enrollment creates the canonical lock; the diagnostic opens it exclusively without creating/modifying it. Neither an old lock file nor a released crash handle proves completion.
2. Require no pending admission and consistent supported journal/current/terminal/helper evidence. A correctly enrolled empty target has an empty managed application tree, safe canonical infrastructure and no fabricated current release, manifest, historical backup or standing policy. Retained `RestoreEmpty` state follows the engine's explicit empty-state rules.
3. For a populated target, verify the current protected approval, retained exact manifest and installed inventory. Generated approvals also recheck their original standing authority. Ensure toolkit and host state remain stable during inspection.
4. On drift, unresolved activity, contradictory records, unknown helper lifetime or unexpected files, preserve evidence and stop. Fence competing trusted writers and use [explicit recovery/maintenance](deployment.md#operator-procedure) or [enrollment reconciliation](host-enrollment.md#inspection-planning-and-apply). Never delete locks, clear journals, replace protected records or clean files to make verification pass. File recovery does not establish database rollback safety.

### Configure optional standing authorization

1. Initial commissioning and an independently exact-approved first deployment do not require standing authorization. Install it independently only after a successful approved baseline, when routine automation is intended.
2. Follow [standing policy and revocation](automated-deployments.md), matching target/channel/repository/producer, lineage and explicit source policy. Keep DEV/Production scopes separate. Standing authority cannot authorize enrollment, baseline/cutover, toolkit changes, downgrades or exceptional recovery. Recovery of a generated release requires an independent schema-1 exact approval; hook-related persistent-state reconciliation has additional exact authority under [the hook contract](application-hooks.md#failure-and-explicit-recovery).

## 11. Verify the completed setup

### Run the optional GitHub setup check

1. After GitHub UI configuration, add the [small manual caller](examples/check-github-setup.yml) at an immutable reviewed revision and run **Check GitHub deployment setup**. Pass the expected integration branch, environment, group and comma-separated labels explicitly. Run separately for DEV and Production. No host access, toolkit or deployment secret is needed.
2. Read the seven category rows and linked UI settings. `CONFIGURED` means observed settings match expectations; `NEEDS CONFIGURATION` means a confirmed discrepancy; `CHECK MANUALLY` means API evidence is insufficient and includes the exact UI path and expected setting. Follow [API capabilities and invocation details](github-setup-check.md) for the optional read-only inspection token. Default-token coverage is limited.
3. Correct confirmed discrepancies and inspect unresolved settings manually. Disabled deployment activation can remain false. The check is optional and never gates ordinary deployment.
4. Separately complete host preparation, enrollment observations and application-owned prerequisites. Actual deployment preflight remains part of the authorized toolkit operation; a GitHub configuration report supplies no host evidence.

### Authorize first deployment and acceptance

1. A GitHub configuration report does not authorize deployment. Do not fabricate a baseline or activate automation for a configured result. Routine deployment does not require running the checker.
2. Obtain independent exact first-release authority and separately scoped host/application deployment approval, then follow [deployment](deployment.md#prerequisites-and-commands) and [IIS rollout/acceptance](iis-verification.md#rollout-order). Complete application-specific configuration, keys, startup/readiness, database and deployment/recovery acceptance. GitHub setup checks do not replace those observations.
3. Only then consider independently authorized standing automation and route activation. Record actual unrun gates honestly; this setup guide establishes no real-host qualification.

## 12. Troubleshooting and safe remediation

### Troubleshoot incomplete inspection

1. `GITHUB_TOKEN` cannot read several administrative settings. Use the row's exact UI navigation and expected setting, or supply the optional read-only App inspection token on hosted infrastructure. Hidden ruleset bypass may still require manual inspection; do not grant write access for diagnostics.
2. A denied request, ambiguous 404, incomplete pagination or malformed response is CHECK MANUALLY. Confirm missing resources only from complete authoritative lists or direct UI inspection.
3. For unexpected execution failures, retain the safe job log and retry the same selection after resolving the error. Do not publish credentials, unrelated settings or raw private responses. Workflow behavior and host configuration are reviewed separately.

### Troubleshoot host trust and enrollment

1. Obtain separate authorization for real host observations and use the independently authenticated enrollment Get/Plan procedures; the GitHub checker supplies no host observations.
2. For toolkit authentication failure, do not import candidate code. For instability detected after authenticated import, stop further work. Independently verify protected policy/physical ancestry, exact installed bytes/inventory/source/distribution and compatible readers using [installation procedures](installation.md#trust-before-first-import). Freeze competing writers; replacement/activation requires separate infrastructure authority.
3. For machine/enrollment identity mismatch, confirm actual SMBIOS UUID and intended site/pool/root/runtime SID against protected records. Follow [enrollment states](host-enrollment.md#inspection-planning-and-apply); never create a second installation namespace or overwrite records to match labels.
4. For state drift or unresolved activity, preserve all material and use [authorized recovery/maintenance](deployment.md#operator-procedure). Uncertainty about helper exit, mixed files or external persistent state requires operator intervention.

### Rerun after configuration changes

Rerun the optional GitHub check with the intended environment, runner group and labels after changing GitHub settings. Keep independently scoped host observations and application acceptance evidence under their existing procedures; there is no combined diagnostic report.

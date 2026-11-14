# Shared application release and deployment

This change extends master [`7f814ef`](https://github.com/clcdpc/clc-deployment/commit/7f814ef) with reusable application workflows and package version 2. It does not publish a toolkit/package, configure GitHub, enroll a host, or establish consumer acceptance. **Actual Windows Server 2022/IIS and independent-identity qualification remain NOT RUN.**

## Responsibilities

| Component | Owns |
| --- | --- |
| [Release tools](../tools/release) | Source eligibility, exact successful producer/run/job/attempt and artifact verification, transport/package integrity, ordering inputs and GitHub Release publication |
| [Reusable workflows](../.github/workflows) | Isolated conventional builds or prequalified CI handoff, hosted admission/publication, protected environment/runner routing, postqueue revalidation and safe summaries |
| Installed four-command toolkit | Independently protected authority, canonical machine/pool lock, host/package checks, optional authorized hooks, IIS/files/readiness, durable attempts and explicit recovery |

GitHub API calls stay outside the installed deployment engine. Applications retain build/test requirements, configuration/readiness/database semantics and optional hook scripts; infrastructure retains installation, accounts, credentials, certificates, external configuration, target/standing/hook/recovery approvals and GitHub runner controls. Hooks do not introduce SQLCMD, DACPAC or Hangfire engines into this toolkit.

## Source and ordering

`vMAJOR.MINOR.PATCH-dev.N` is DEV; beta/RC is artifact-only; stable is Production. Explicitly enabled `-test.N` tags use a separate Test channel. Creating and pushing a valid DEV version tag is the deliberate release authorization step, governed by GitHub repository permissions and tag creation controls. After successful qualification, release publication and deployment can proceed unattended under the existing target, standing and applicable hook policies. No separate PR approval or manual environment/workflow approval gate is required.

A tag whose exact source is already contained in master is `IntegrationTag`. A DEV tag outside master is `UnmergedDevTag` and requires `sourcePolicy.allowUnmergedDevTags=true` in both protected consumer configuration and host standing authorization. False remains an explicit refusal; missing flags fail contract validation. The commit may be an open or draft PR head, an earlier commit after its PR advances, a closed PR commit, or a same-repository commit with no PR or formal GitHub review. PR branches need no protection and may be deleted. Master must still be reported as protected, using each repository's actual configured `integrationBranch` name (`master` or `main`).

The tag must resolve to the exact source commit, and declared trusted workflows, configuration and security-sensitive supporting files must agree byte-for-byte with protected master. Exact successful producer workflow/run/attempt/job, artifact ownership/transport, package bytes/inventories and approved builder revision/distribution checks remain required, including revalidation after queueing and download. Tag author/tagger fields are not authenticated GitHub actors. The unmerged DEV allowance does not extend to production, beta/RC, test tags or host infrastructure authority.

Explicitly enabled protected-branch snapshots use `refs/heads/<integrationBranch>`, `dev-<producerRunId>-<commit12>` identities and authenticated producer-run ordering. Automatic deployments skip source superseded by the current protected branch head; a protected explicit dispatch may request redeployment after repository-write authority is checked. Host ordering still refuses downgrades or incompatible lineages. Snapshot and semantic-tag ordering use separate standing lineages; switch only through independent exact baseline authority.

Tagged rebuilds retain the exact immutable tag/source binding. A newer successful producer run/attempt can have its own package bytes; changed bytes for the same producer identity refuse. GitHub Release publication preserves a completed release's exact canonical asset set: a conflicting rebuilt asset refuses publication and leaves the existing release untouched. Snapshots retain Actions artifacts and create no GitHub Release. Publication never authorizes deployment.

The example publication and deployment jobs are independent. A separately authorized rebuild/redeployment can consume its verified Actions artifact even when publishing different bytes under an already completed tag refuses. Inspect each job's result; a publication conflict does not replace canonical assets or grant deployment authority.

## Immutable workflow execution

Consumers pin each reusable workflow to one reviewed full commit SHA. The workflow's first inline step requests its job identity directly from GitHub's platform endpoint and checks `job_workflow_ref`/`job_workflow_sha` for that immutable shared workflow before checking out machinery. It retains only a safe identity projection; the token is not logged or accepted from an artifact. GitHub documents that the ordinary reusable-workflow `github` context identifies the caller, while the [OIDC job claims identify the called workflow](https://docs.github.com/en/actions/reference/security/oidc). See also [reusable workflow context](https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations).

The shared code authenticates caller repository, workflow path/revision, current protected configuration, exact producer attempt/job, artifact ownership/name/transport digest and complete package bytes. Hosted admission verifies the package before routing. The privileged job repeats verification after queueing, uses the same artifact ID, refuses changed protected routing configuration and rechecks mutable source eligibility immediately before host admission. It checks out only shared machinery; it never checks out application source on the IIS runner.

Before its first installed-module import, pinned shared readers authenticate the fixed host policy with SYSTEM/Administrators ownership/writers and protected physical ancestry, then verify/hold the approved installed module inventory, source and distribution bytes. These handles remain held through import and invocation. The installed module repeats its existing authority/host checks. Infrastructure's elevated administrator remains procedurally trusted; this is not containment against that administrator.

## Minimal consumer configuration

Place the strict contract-version-1 [example](examples/shared-release.json) at `.clc/release.json`. Its validator is `Read-ClcConsumerConfiguration` in [Release.Common.ps1](../tools/release/Release.Common.ps1); unknown fields and ambiguous JSON refuse. No host paths, connection strings, credentials or authorization records belong here.

- Identity: application/repository, protected integration branch and explicit source-policy switches.
- Producer: workflow path and safe `job`; optional `jobName` is the exact GitHub REST display name, such as `package / build`, Favorite Authors' `Build, test, publish, and package`, or ASAP's `Frontend, CI checks and package`. Commas are accepted within the existing 128-character bound; API comparison remains exact and case-sensitive.
- `trustedFiles`: configuration, producer/deployment workflows and every consumer security-sensitive admission/packaging helper. Files must match protected master code; ordinary application source may differ for explicitly permitted unmerged DEV tags.
- `requiredToolkitContractVersion=2`; optional conventional `project` and `testProject` paths.
- `orchestration`: exact shared revision and protected deployment workflow path. Shared package creation requires `SharedSourceCommit` to equal `sharedRevision`; publication and deployment admission independently require the verified package's `builder.sourceCommit` to equal that protected pin. Existing source/producer/artifact/hash and builder-distribution checks still apply.
- `targets`: channel, target/policy selectors, environment, runner group/explicit Windows x64 labels and disabled-by-default activation/admission assertions. These values route work; independent GitHub controls and host approvals supply authority.

Optional `hooks` uses the package declaration in [hook documentation](application-hooks.md); conventional hook/support inputs live under `.clc/hooks`. Omit it entirely for no-hook applications. External configuration, certificates, keys and operational data remain outside both the published application tree and hook inputs.

## Two integration patterns

**Conventional application:** copy [the build caller](examples/shared-conventional-build.yml), [protected publication/deployment caller](examples/shared-application-deploy.yml) and [configuration](examples/shared-release.json) into the consumer's reviewed paths. Replace all synthetic identities and `aaaaaaaa…` pins. The shared builder provisions the repository's pinned .NET 10 SDK, performs locked restore/build, optionally tests `testProject`, publishes and produces a verified version-2 package. Specialized qualification can remain in consumer jobs that gate the reusable build caller.

The application integrates the existing ASP.NET Core validator/readiness contracts and maps these build properties to immutable assembly metadata:

```xml
<AssemblyMetadata Include="Clc.ApplicationId" Value="$(ClcApplicationId)" />
<AssemblyMetadata Include="Clc.ReleaseId" Value="$(ClcReleaseId)" />
<AssemblyMetadata Include="Clc.SourceCommit" Value="$(ClcSourceCommit)" />
<AssemblyMetadata Include="Clc.IdentityKind" Value="Release" />
```

**Existing complex CI:** retain its frontend/browser/.NET/SQL checks, evidence reuse and publish operation. Add [the shared packaging tail](examples/shared-prequalified-build.yml) after those checks, then use the same protected publication/deployment caller. `-QualifiedPublishRoot` with the producer's actual `-SdkVersion` skips SDK provisioning, restore/build/test/publish and uses the same metadata/package producer. A literal project `AssemblyName` or explicit fixed `-ValidationEntryPoint Example.dll` selects the validator DLL; no scripts/inline commands are accepted. A NuGet lock file is optional on this path. If project-adjacent `packages.lock.json` exists (or source-root `packages.lock.json` without project configuration), its actual SHA-256 is recorded; otherwise V2 metadata and manifest explicitly record `build.dependencyLockSha256=null`. This records available input evidence, without claiming a particular restore convention or substituting other qualification evidence for a NuGet lock. Conventional shared builds continue to require locked restore. Update `producer.job`/`jobName` to the real qualified job. This example is a job tail, not replacement CI.

Applications also own detailed `web.config` validation in CI. Shared packaging requires the exact managed file, verified bytes and bounded well-formed XML with DTD/entity resolution disabled. It accepts application-owned handlers/modules (including ASAP's WebDAV removals), launch arguments (including Favorite Authors' `--environment=Production`), environment variables, logging and other IIS settings without normalization. An authorized application release can change application-level IIS configuration; source eligibility, release review, protected host configuration and infrastructure authorization manage that trust. Dedicated IIS target/runtime restrictions and exact package/validator/readiness identity remain independently checked.

Obtain the compiled release identity from shared `Get-ClcVerifiedSource.identity.releaseId` before the consumer's build; use its exact source commit and application identity in the existing readiness integration. The producer uploads only `release.zip` in `clc-package-<fullCommit>-<runId>-<attempt>`. The shared consumer independently locates/verifies that artifact; it does not trust a JSON file from the producer as deployment authority. Advanced producers can still call `New-ClcRelease` directly with the documented metadata contract.

## Activation and operation

Follow [GitHub setup](github-setup.md) before enabling any target. Infrastructure must provision separate DEV/Production environment and runner scopes, restrict runner access to the exact immutable reusable workflow defining the privileged job, protect caller/configuration/support code and release tags, and supply the independently installed toolkit/enrolled target plus an exact successful baseline and standing policy. A selected caller workflow does not automatically authorize jobs defined in a different reusable workflow. Keep ordinary PR CI on separate runners with no host credentials. The examples leave activation false and grant no host authority.

`application-release.yml` verifies/publishes on hosted Windows; `application-deploy.yml` performs hosted admission then protected execution. `automatic=false` is accepted only for protected dispatch by repository-write authority. `operation=ValidateOnly` selects only the separately declared trusted planning script under full release/hook authorization; it does not execute Preflight or database mutation hooks. Planning has no IIS cycle/current-generation publication and is not an arbitrary-PowerShell sandbox. Hook diagnostics remain protected on the host; only safe deployment summaries are uploaded.

New routine packages use schema 2 / `changeKind=application-deployment` and always perform the normal IIS cycle on repeats. Direct legacy schema-1 packages retain their tested NoOp behavior. Hook intent uses journal 3, with sticky external-state uncertainty; successful planning is a separate terminal outcome. Failures never imply database rollback or safe older web files. See [hooks](application-hooks.md), [deployment/recovery](deployment.md) and [versioned contracts](contracts.md). Published companion validation/readiness contracts are unchanged; installing a compatible new toolkit and independently enabling policy precede adoption.

## Reference coverage and follow-up

| Read-only reference | Required behavior represented |
| --- | --- |
| [ASAP `732dbcd`](https://github.com/clcdpc/asap-pocketbase/commit/732dbcd973cbbd6eb5cfd4186144a5de2d79cbd5) | Protected master snapshots (configured `main`), test tags, explicit redeployment, supersession, retained complex CI; one AfterStop entry point composes DACPAC/Hangfire and a distinct planning entry point produces SQL diagnostics |
| [Favorite Authors `5b15bc1`](https://github.com/clcdpc/favorite-authors/commit/5b15bc1c1a11a73faee839f2515ae538c8f65e73) | Exact CI-qualified unmerged DEV tags without GitHub PR approval, including the release pattern illustrated by v1.0.0-dev.46 and dev.47; BeforeStop DDL on repeats, failures before unnecessary IIS changes; application-owned certificate checks and SQL integration qualification |
| [SSRS master `c9fee1f`](https://github.com/clcdpc/ssrs-web/commit/c9fee1f1c2f2e0d1c1f613e601858286b0d50647), [PR #1 head `48193b4`](https://github.com/clcdpc/ssrs-web/commit/48193b41804a852fdd27f1ee662521793b02e8d5) | No-hook deployment, exact unmerged DEV tags without a separate reviewer, beta/RC artifact-only releases, stable publication and independently disabled Production activation |
| [Polaris master `9d4b1d7`](https://github.com/clcdpc/polaris-oidc/commit/9d4b1d756d7b528a9e23a7e013196a39a33ab4b3) | Conventional .NET 10, no hooks, external configuration/certificates and independently managed EF migrations; remote master has no established release workflow |

These are compatibility requirements represented by compact offline fixtures, not completed consumer integrations. SSRS PR #1 must replace its duplicated release/admission adapter with reviewed immutable shared workflow/toolkit pins, emit package 2, map producer display names/configuration and retain its application acceptance checks. No consumer repository was changed.

Prerequisite-validator [PR #3 at `b1194c0`](https://github.com/clcdpc/clc-deployment/commit/b1194c0a81af70b249365800117f9bd685198343) is separate/unmerged and remains untouched. Existing installed reader signatures are preserved; `Get-ClcReconciliationDecision` exposes unresolved hook attempts through its existing recovery classification. When that PR is incorporated, its generated-approval check must include schema 3 (`-ge 2`), and optional source/hook/persistent-state policy observations should call these installed readers. Diagnostics must never execute validators, hooks or planning. Do not duplicate its prerequisite-validation workflow here.

Offline PowerShell/native-file/harmless-process tests and workflow lint establish only the implemented boundaries. Protected runner admission, actual consumer CI/publication, service identities, database/application compatibility, live IIS/recovery and disruptive failures still require separately authorized evidence under [IIS verification](iis-verification.md).

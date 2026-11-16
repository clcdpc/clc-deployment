# Shared application release orchestration

Use the [one-time setup guide](setup-guide.md). One consumer workflow triggers on supported version-tag pushes and executes from the tagged commit. Deliberate tag creation under GitHub's native repository-wide Restrict actors policy and tag rulesets is release authorization. Build/test work stays on hosted runners; only verified DEV/Production deployment requests the derived privileged runner label.

## Consumer workflow

Copy the [conventional workflow](examples/shared-conventional-build.yml) into `.github/workflows/build.yml`. It calls immutable shared build, release and deployment workflows in order through `needs`. The [publication/deployment example](examples/shared-application-deploy.yml) shows the same chain, not a separate default-branch consumer. No `workflow_run`, manual dispatch, per-release approval or per-PR configuration is used.

Applications retaining their own frontend/browser/.NET/SQL tests can use the [prequalified workflow tail](examples/shared-prequalified-build.yml). Keep application qualification before packaging in the single producer job; a failed step must fail that job. Existing CI owns qualification and publishes the exact application/release/source identity. V2 records the actual NuGet lock hash or explicit null when absent; the conventional builder still uses required locked restore. Application-owned IIS semantics and optional hooks remain application responsibilities.

## Configuration version 2

[`.clc/release.json`](examples/shared-release.json) keeps `applicationId`, `repository`, `integrationBranch`, exact producer workflow/job (optional exact REST `jobName`), `requiredToolkitContractVersion`, optional project/test project, immutable `orchestration.sharedRevision`, and optional [hooks](application-hooks.md). All shared calls and the builder must match that revision. A tagged commit can deliberately change the pin before merging.

Version 1 consumer configuration is rejected. Remove `sourcePolicy`, `trustedFiles`, `targets` and `orchestration.deploymentWorkflowPath` when adopting version 2. There are no application routing files or required repository variables. DEV derives `<applicationId>-dev`; Production derives `<applicationId>-production`. Target, environment, dedicated runner label, host enrollment authorization and standing authorization reuse that identifier. Deployment requests exactly `self-hosted`, `Windows`, `X64` and that label, with no group input. Infrastructure retains each resource separately and controls physical host paths, installed toolkit and standing-policy bytes.

## Tag and workflow identity

`vN.N.N-dev.N` admits any exact valid repository commit, including unmerged workflow/configuration/script changes. No PR lookup, author allowlist, review, PR-head or master-file equality is required. `vN.N.N` requires the commit to be contained in protected integration history. Beta/RC are artifact-only; Test tags are unsupported. Existing tag numeric bounds remain centralized in the installed tag classifier. Branch snapshots remain an installed-host evidence format for existing integrations, but are not a shared routine release entry point.

The reusable workflow obtains platform job identity directly, checks the immutable upstream workflow path/SHA and reads consumer configuration at `workflow_sha`. It requires the configured caller path at the exact tag, and binds caller workflow SHA, selected source, run ID and attempt. It checks the current peeled tag object and protected integration branch. Configuration and workflow bytes are never compared with latest master. The privileged job repeats identity and configuration-blob checks after queueing.

## Same-run producer qualification

Publication/admission query the exact run attempt and its jobs. The overall run may be in progress. The configured build/test/package producer job must be completed and successful, at the exact source commit. The run must belong to the exact repository/tag/workflow and source revision. A completed failed workflow or incomplete/failed producer cannot qualify.

The Actions artifact is `clc-package-<fullSourceCommit>-<runId>-<attempt>`, selected uniquely by ID, repository ownership and run/source identity. Its creation must fall within that successful producer job's attempt window. Verify its service SHA-256 before extracting the sole `release.zip`, then check exact package/manifest/inventories, source, producer and builder pin. Wrong attempts, stale artifacts, substituted source and transport/package mutations refuse before publication or host admission. Packaging and publication/admission read `Clc.ApplicationId`, `Clc.ReleaseId`, `Clc.SourceCommit` and `Clc.IdentityKind=Release` from the fixed validation DLL metadata without loading or executing it. These must exactly match the tag and manifest; deployment also enforces validator/readiness identity. A DEV commit with no common ancestor uses the observed protected integration head as its branch witness.

## Publication and deployment

Publication rechecks source after download, creates a draft release, verifies assets and finishes publication. Identical canonical releases are preserved; conflicting published assets are never replaced. `deployment` has `needs: publication`, so a publication failure skips deployment. Beta/RC never route to a privileged runner.

Hosted admission verifies before labels are exposed. The queued job rechecks, opens the independently installed toolkit through the fixed protected host policy, and hands exact bytes/evidence to it. Missing/revoked standing authority, target/channel mismatch, ordering/downgrade conflicts and unresolved state still fail under the canonical machine/pool lock. No artifact selects host configuration or installed code. Baseline/enrollment/toolkit changes and exceptional recovery keep their independent authority. Hooks run elevated without sandboxing and have separate infrastructure scope.

## Evidence limits

The prior orchestration at [7f6e884](https://github.com/clcdpc/clc-deployment/commit/7f6e88417d02ab4d6ea058fb28deb1d1af86483d) required master file equality and completed producer runs. This change replaces that consumer orchestration; installed IIS lifecycle and approval formats are unchanged.

Offline tests cover exact tag/run/job/attempt/artifact binding, unmerged DEV code/configuration changes, Production ancestry, sequential job dependencies, immutable publication and host-policy refusals. No consumer repository is modified. **Actual Windows Server 2022/IIS, runner policy and independent-identity qualification remain NOT RUN.** Follow [real-host verification](iis-verification.md) under separate scope.

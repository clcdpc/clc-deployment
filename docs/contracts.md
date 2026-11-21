# PowerShell and data contracts

Import the manifest from a trusted checkout or verified distribution. The module exports six commands.

| Command | Required parameters | Result |
| --- | --- | --- |
| `Initialize-ClcDeploymentHost` | `Operation` Preview or Initialize, `ApplicationId`, `TargetId`; optional site and pool overrides (`SiteName`, `ApplicationPoolName`) | Preview, Blocked, InitializedNeedsConfiguration, or AlreadyInitialized |
| `Test-ClcDeploymentHost` | `ApplicationId`, `TargetId`, `ExpectedRuntimeAccount`, `RuntimeEnvironment` | NotInitialized, InitializedNeedsConfiguration, ReadyForFirstDeployment, ReadyForDeployment, InvalidConfiguration, or RecoveryRequired |
| `New-ClcRelease` | `PublishRoot`, `MetadataPath`, `OutputPath` | New deterministic ZIP and digests |
| `Test-ClcRelease` | `ArchivePath` or `ReleaseTag` | Archive integrity and identity, or release tag identity |
| `Invoke-ClcIisDeployment` | Host validation parameters plus `ArchivePath`, `ExpectedSha256`, `ReleaseTag`, `ExpectedSourceCommit`, `ExpectedRepository` | Deployed with release, attempt and IIS state |
| `Restore-ClcIisDeployment` | Host validation parameters plus `AttemptId`, `Reason` | RestoredPrevious or RestoredEmpty with IIS state |

Use canonical lowercase application and target IDs, up to 64 characters, and explicit DNS hostnames on the managed HTTPS bindings. The expected runtime account is the administrator-selected account name. Set `RuntimeEnvironment` to the expected ASP.NET Core runtime environment on the selected target. `Invoke-ClcIisDeployment` accepts DEV tags with `Production` or `Staging` and stable tags with `Production`. Beta and RC tags are artifact-only. Recovery takes the unresolved attempt GUID and a short nonsecret reason or incident reference. Validation is read-only. Unsafe mutation requests terminate with a `Clc.*` error and an actionable diagnostic.

## Consumer release configuration contract 3

The consumer's `.clc/release.json` requires `devRuntimeEnvironment` with the exact string `Production` or `Staging`. The shared workflow reads this value from the authenticated tagged revision for DEV deployments. Stable tags always use the `Production` runtime environment. The verified tag determines the deployment channel, target ID and GitHub environment. [Example configuration](examples/shared-release.json) · [Shared workflow routing](shared-release-orchestration.md)

## Package contract 3

The archive contains `manifest.json` and the complete `application/` file inventory. Use the [metadata](../schemas/release-metadata.schema.json) and [manifest](../schemas/release-manifest.schema.json) schemas. Stable and DEV packages carry the exact target ID. Artifact-only packages can use null. The release ID is derived from the tag by replacing periods with hyphens. Source repository and exact commit, workflow producer identity, builder identity, runtime, hashes, and fixed validator DLL are part of the manifest.

SHA-256 covers exact ZIP and manifest bytes. The inventory digest is SHA-256 over ordinal-sorted UTF-8 `path + NUL + invariant length + NUL + lowercase SHA-256 + LF`. ZIP inspection bounds compressed and expanded bytes at 1 GiB, entries at 20,000, a file at 256 MiB, and compression expansion at 100:1. JSON records are bounded and reject duplicate keys, coercion, and unsupported versions. Canonical NTFS paths are bounded to 240 characters. Reparse points, alternate streams, hard links, aliases, directory collisions, and unrelated files fail closed.

The application validator and readiness response retain contract 1. See the [companion integration](aspnetcore-integration.md).

## Local deployment records

`Deployment/host.json` identifies the completed scaffold. `Deployment/state.json` holds the current release, latest selected release, and any unresolved attempt. `Deployment/attempt-<GUID>/` holds the exact candidate manifest, attempt record, staged files, verified backup, and diagnostic remnants when available. State and attempt records use version 1 of this lifecycle. A target-local exclusive file handle serializes operations. Filesystem and IIS identity checks confirm that each mutation still addresses the recorded site, pool and application path.

New initializations write host schema 2 with the site name, pool name, numeric site ID and canonical root. Schema 1 still requires its original valid readiness URI. Both formats use current IIS bindings at runtime. Reading or deploying preserves the original host record bytes. Older toolkit pins require schema 1 and its single matching binding. Existing immutable tags keep their original toolkit pin. Use a release admitted with the new toolkit for schema 2 or multiple bindings. Package contract 3, readiness contract 1, state, attempt and backup formats are unchanged.

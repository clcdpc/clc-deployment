# CLC file deployment

CLC.Deployment is an application-independent PowerShell toolkit for file-only ASP.NET Core/IIS deployments on Windows Server 2022 with PowerShell 7. V1 requires net10.0/win-x64/in-process hosting, one dedicated site/root application/pool and one worker. It exports four commands: `New-ClcRelease`, `Test-ClcRelease`, `Invoke-ClcIisDeployment`, and `Restore-ClcIisDeployment`.

Deployment verifies the approved ZIP, validates the package and host, extracts to protected staging, stops and observes zero workers, verifies a backup, replaces managed files, starts, checks exact release readiness, and records success. A healthy exact installed release/configuration completes NoOp after installed-file validation and fresh readiness, without staging, backup or restart. One exclusive OS file handle serializes the actual machine/pool; the version-2 phase journal blocks unresolved attempts and never resumes a partial copy.

Infrastructure independently installs/pins the toolkit and Windows/.NET/IIS components and owns identities, IIS/TLS/ACL provisioning, protected exact-byte approvals, external configuration, persistent Data Protection keys, capacity and retention. Inspection and self-declared hashes never authorize execution. Deployment requires an enabled elevated administrator token; independent approval against that administrator is procedural and approved application validation is not sandboxed. Runtime remains a separate nonadministrator without effective application/control/toolkit write access.

Applications own publishing/provenance, configuration semantics and revisions, key compatibility, readiness, database compatibility and business services. The toolkit replaces only managed application files. Database deployment, DACPACs, Hangfire installation, subscription data and application features remain consumer-owned.

An unexpected OS reboot during physical replacement may leave mixed files and require manual recovery. Pending state does not prevent IIS activation after reboot or an external start; there is no startup interception or unattended activation fence. After replacement begins, failures attempt a bounded stop and retain recovery material. Recovery requires an explicit operator choice, compatible approved material and proven helper exit; file restoration never establishes database rollback safety.

The toolkit and companion package share the published [v0.1.0-beta.2 release](https://github.com/clcdpc/clc-deployment/releases/tag/v0.1.0-beta.2), built from `ace6d5a735bfdfd5f926936f07dfb03f0614f9f6`. Current source for the repository, toolkit and companion package is licensed under [MIT](LICENSE). The published v0.1.0-beta.2 artifacts remain AGPL-3.0-only. Publication does not approve installation or deployment.

**Actual Windows Server 2022/IIS qualification remains NOT RUN.** Offline/synthetic tests and published artifacts do not establish independent service-identity, runtime/profile/access, TLS/key, storage/power-loss or consumer deployment acceptance. Each consumer must approve an exact package/toolkit version and retain its source/artifact pins and application-owned acceptance evidence.

## Consumers and operators

| Guide | Purpose |
| --- | --- |
| [Installation](docs/installation.md) | Authenticate, verify and install an exact toolkit distribution |
| [Host enrollment](docs/host-enrollment.md) | Separately authorized infrastructure setup |
| [GitHub setup](docs/github-setup.md) | Consumer workflow controls and privileged runner admission |
| [ASP.NET Core integration](docs/aspnetcore-integration.md) | Application-side validator and readiness plumbing |
| [Deployment and recovery](docs/deployment.md) | Commands, safeguards, failure boundaries and explicit recovery |
| [IIS verification](docs/iis-verification.md) | Rollout prerequisites, seven practical checks and remaining unrun gates |

## Maintainers

| Guide | Purpose |
| --- | --- |
| [Contracts](docs/contracts.md) | Four commands, package/approval/configuration/state formats |
| [Testing](docs/testing.md) | Pinned verification tools and coverage limits |
| [Releasing](docs/releasing.md) | Shared versions, verified artifacts and protected tag publication |

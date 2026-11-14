# CLC release and IIS deployment

CLC.Deployment provides shared release verification, GitHub Actions orchestration and an independently installed ASP.NET Core/IIS deployment toolkit. Windows Server 2022, PowerShell 7, net10.0/win-x64/in-process hosting, one dedicated site/root application/pool and one worker remain the supported host model. It exports four commands: `New-ClcRelease`, `Test-ClcRelease`, `Invoke-ClcIisDeployment`, and `Restore-ClcIisDeployment`.

Deployment verifies the approved ZIP, validates the package and host, extracts to protected staging, stops and observes zero workers, verifies a backup, replaces managed files, starts, checks exact release readiness, and records success. New schema-2 packages perform the full cycle on repeats and can declare four separately authorized [application hooks](docs/application-hooks.md). Legacy schema-1 packages retain their tested healthy NoOp behavior. One exclusive OS file handle serializes the actual machine/pool; supported phase journals block unresolved attempts and never resume a partial copy.

Infrastructure independently installs/pins the toolkit and Windows/.NET/IIS components and owns identities, IIS/TLS/ACL provisioning, protected exact-byte approvals, external configuration, persistent Data Protection keys, capacity and retention. Inspection and self-declared hashes never authorize execution. Deployment requires an enabled elevated administrator token; independent approval against that administrator is procedural and approved application validation is not sandboxed. Runtime remains a separate nonadministrator without effective application/control/toolkit write access.

Applications own build/test qualification, configuration semantics and revisions, key compatibility, readiness, database compatibility and business services. The toolkit replaces only managed application files. Applications can implement SQL/DACPAC/Hangfire operations in verified, explicitly authorized hooks; the shared toolkit supplies lifecycle and evidence, with no database deployment or rollback engine.

Applications validate their own `web.config` IIS semantics in CI. Shared packaging checks its exact inventoried bytes and bounded well-formed XML, with DTD/entity resolution disabled; authorized releases can change application-level IIS settings under independent infrastructure authorization. Existing qualified CI can package without a NuGet lock file, recording explicit absent lock evidence in V2; conventional shared builds retain locked restore.

An optional infrastructure-owned [standing deployment policy](docs/automated-deployments.md) admits independently verified tagged releases and protected-branch snapshots into exact approvals for the same engine. DEV, Test and production remain explicitly scoped; enrollment, initial baseline, toolkit changes and exceptional recovery retain independent authorization. The [shared workflows and consumer examples](docs/shared-release-orchestration.md) support conventional .NET applications and applications retaining their own CI.

An unexpected OS reboot during physical replacement may leave mixed files and require manual recovery. Pending state does not prevent IIS activation after reboot or an external start; there is no startup interception or unattended activation fence. After replacement begins, failures attempt a bounded stop and retain recovery material. Recovery requires an explicit operator choice, compatible approved material and proven helper exit; file restoration never establishes database rollback safety.

The repository, PowerShell toolkit and ASP.NET Core companion source are licensed under [MIT](LICENSE). See [Releases](https://github.com/clcdpc/clc-deployment/releases) for releases published from this clean-history repository. The previously published `0.1.0-beta.2` artifacts came from its predecessor repository and remain AGPL-3.0-only; they are not MIT-licensed builds. Publication does not approve installation or deployment.

**Actual Windows Server 2022/IIS qualification remains NOT RUN.** Offline/synthetic tests and published artifacts do not establish independent service-identity, runtime/profile/access, TLS/key, storage/power-loss or consumer deployment acceptance. Each consumer must approve an exact package/toolkit version and retain its source/artifact pins and application-owned acceptance evidence.

## Consumers and operators

| Guide | Purpose |
| --- | --- |
| [Installation](docs/installation.md) | Authenticate, verify and install an exact toolkit distribution |
| [Host enrollment](docs/host-enrollment.md) | Separately authorized infrastructure setup |
| [GitHub setup](docs/github-setup.md) | Consumer workflow controls and privileged runner admission |
| [Automated deployments](docs/automated-deployments.md) | Standing policy, verified workflow identity and consumer integration |
| [ASP.NET Core integration](docs/aspnetcore-integration.md) | Application-side validator and readiness plumbing |
| [Deployment and recovery](docs/deployment.md) | Commands, safeguards, failure boundaries and explicit recovery |
| [IIS verification](docs/iis-verification.md) | Rollout prerequisites, seven practical checks and remaining unrun gates |

## Maintainers

| Guide | Purpose |
| --- | --- |
| [Contracts](docs/contracts.md) | Four commands, package/approval/configuration/state formats |
| [Application hooks](docs/application-hooks.md) | Fixed stages, separate policy, planning and persistent-state recovery |
| [Testing](docs/testing.md) | Pinned verification tools and coverage limits |
| [Releasing](docs/releasing.md) | Shared versions, verified artifacts and protected tag publication |

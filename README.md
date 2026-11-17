# CLC release and IIS deployment

Clc.Deployment provides shared GitHub release orchestration and an independently installed ASP.NET Core/IIS deployment toolkit. It supports Windows Server 2022, PowerShell 7, net10.0/win-x64/in-process hosting, one dedicated site/root application/pool and one worker. Its four exports are `New-ClcRelease`, `Test-ClcRelease`, `Invoke-ClcIisDeployment` and `Restore-ClcIisDeployment`.

**Generic setup starts here → [Deployment Setup Guide](docs/setup-guide.md#setup-roadmap).** Follow its ordered roadmap; it links each supporting procedure when needed.

**Configuring SSRS Web? Start with [clcdpc/ssrs-web/docs/clc-deployment.md](https://github.com/clcdpc/ssrs-web/blob/master/docs/clc-deployment.md).** That application runbook controls its setup and release workflow, referring to toolkit procedures as needed. Generic shared-workflow examples do not replace it.

Every target owns `%ProgramData%\clc-<target-id>\`, including its protected `Deployment` bootstrap/toolkit/policy/approvals/state. DEV and Production can pin different toolkit versions on one host. Infrastructure owns accounts, components, IIS/TLS/ACLs, protected configuration/keys, toolkit installation and approvals. Applications own builds, configuration/readiness semantics and database/hook compatibility. Deployment replaces managed application files only.

Exact-byte authority, physical-path/access checks, the machine/pool lock, durable journals, verified backups and expected-release readiness are mandatory. Validation/hooks run elevated without sandboxing; approval against the deployment administrator remains procedural.

After replacement begins, failure retains recovery material without automatic restore/restart. Reboot may require manual recovery; no startup fence exists. File recovery never proves database safety. See [contracts](docs/contracts.md) and [recovery rules](docs/deployment.md#failure-behavior).

Maintainers: [testing](docs/testing.md), [releasing](docs/releasing.md), [orchestration](docs/shared-release-orchestration.md), [workflow trust](docs/verified-workflow-integration.md), [ASP.NET Core integration](docs/aspnetcore-integration.md), [application hooks](docs/application-hooks.md). The optional [GitHub diagnostic](docs/github-setup-check.md) reads settings only and grants no host authority.

[Published releases](https://github.com/clcdpc/clc-deployment/releases) include format-3 [beta.4](https://github.com/clcdpc/clc-deployment/releases/tag/v0.1.0-beta.4). Publication does not approve installation/deployment. This repository and its toolkit/companion source use [MIT](LICENSE); predecessor `0.1.0-beta.2` artifacts remain AGPL-3.0-only.

**Actual Windows Server 2022/IIS and independent-identity qualification remain NOT RUN.** Offline/synthetic tests and published artifacts do not establish real-host or consumer acceptance.

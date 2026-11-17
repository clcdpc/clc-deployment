# CLC release and IIS deployment

Clc.Deployment provides shared GitHub release orchestration and an independently installed ASP.NET Core/IIS deployment toolkit. It supports Windows Server 2022, PowerShell 7, net10.0/win-x64/in-process hosting, one dedicated site/root application/pool and one worker. Its four exports are `New-ClcRelease`, `Test-ClcRelease`, `Invoke-ClcIisDeployment` and `Restore-ClcIisDeployment`.

**Start with the [Deployment Setup Guide](docs/setup-guide.md).** It is the authoritative ten-section checklist for GitHub configuration, host setup, first deployment and routine operation. Existing applications retain their qualified application-owned workflows; shared examples supply integration patterns.

| Procedure | Responsibility |
| --- | --- |
| [Host enrollment](docs/host-enrollment.md) | Prepare host-specific inputs, collect observations, obtain independent approval, Inspect/Plan/Apply |
| [Installation](docs/installation.md) | Acquire/verify the exact toolkit, provision bootstrap, install/activate, upgrade |
| [Manual deployment and recovery](docs/deployment.md) | Obtain the first application ZIP, independently approve it, establish/verify baseline, recover explicitly |
| [Automated deployments](docs/automated-deployments.md) | Configure protected standing authorization after baseline; operate/revoke routine deployment |
| [GitHub setup reference](docs/github-setup.md) | Inherited policies, tag bypasses, immutable releases and privileged runners |
| [IIS verification](docs/iis-verification.md) | Separately authorized host/consumer deployment and recovery acceptance |

Every target owns `%ProgramData%\clc-<target-id>\`, including its protected `Deployment` bootstrap/toolkit/policy/approvals/state. DEV and Production can pin different toolkit versions on one host. Infrastructure owns accounts, components, IIS/TLS/ACLs, protected configuration/keys, toolkit installation and approvals. Applications own builds, configuration/readiness semantics and database/hook compatibility. Deployment replaces managed application files only.

Exact-byte authorization, physical-path/access validation, the canonical machine/pool lock, durable journals, verified backups and expected-release readiness remain mandatory. Validation/hooks run elevated without sandboxing; independent approval against the deployment administrator is procedural. After replacement begins, failure retains recovery material without automatic restore/prior-version restart. Unexpected reboot during replacement can require manual recovery; no startup activation fence exists. File recovery never proves database rollback safety. See [contracts](docs/contracts.md) and [failure/recovery rules](docs/deployment.md#failure-behavior).

Maintainers: [testing](docs/testing.md), [releasing](docs/releasing.md), [orchestration](docs/shared-release-orchestration.md), [workflow trust](docs/verified-workflow-integration.md), [ASP.NET Core integration](docs/aspnetcore-integration.md), [application hooks](docs/application-hooks.md). The optional [GitHub diagnostic](docs/github-setup-check.md) reads settings only and grants no host authority.

[Published releases](https://github.com/clcdpc/clc-deployment/releases) include format-3 [beta.4](https://github.com/clcdpc/clc-deployment/releases/tag/v0.1.0-beta.4). Publication does not approve installation/deployment. This repository and its toolkit/companion source use [MIT](LICENSE); predecessor `0.1.0-beta.2` artifacts remain AGPL-3.0-only.

**Actual Windows Server 2022/IIS and independent-identity qualification remain NOT RUN.** Offline/synthetic tests and published artifacts do not establish real-host or consumer acceptance.

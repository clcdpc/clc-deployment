# Clc.Deployment

Clc.Deployment packages and deploys ASP.NET Core applications to dedicated IIS sites on Windows Server 2022. The lifecycle is **initialize once, configure in IIS Manager, validate, deploy from protected GitHub tags, and recover explicitly when needed**.

Initialization defaults both IIS names to the application ID. Administrators configure HTTPS bindings on the stopped site. Deployment and recovery discover the fixed readiness path from those bindings and require at least one exact release response.

GitHub controls release authorization. A GitHub-hosted runner builds, tests, and publishes the release. A dedicated Windows runner verifies the artifact against trusted GitHub metadata and deploys it. Each target has its own server and uses native ProgramData under `clc-<application-id>`. Releases replace only the `Application` tree. Configuration, Data Protection keys, and logs remain outside it.

Start with the [setup guide](docs/setup-guide.md), then use the [command reference](docs/contracts.md), [deployment and recovery runbook](docs/deployment.md), and [shared workflow integration](docs/shared-release-orchestration.md). The [ASP.NET Core companion](docs/aspnetcore-integration.md) provides compiled release identity, application validation, and readiness.

This release introduces package contract 3 and toolkit distribution format 4. Obtain an exact version from [GitHub Releases](https://github.com/clcdpc/clc-deployment/releases) or an authenticated immutable checkout. See [toolkit acquisition](docs/installation.md) and [maintainer release conventions](docs/releasing.md).

SSRS Web is the first intended consumer. Its workflow integration and actual Windows Server 2022/IIS commissioning remain **NOT RUN** in this repository.

# Shared GitHub Actions release workflows

Pin all reusable workflows to the same immutable Clc.Deployment commit. Use the [conventional](examples/shared-conventional-build.yml) or [prequalified](examples/shared-prequalified-build.yml) build example, and the [publication/deployment chain](examples/shared-application-deploy.yml). Configure the consumer's `.clc/release.json` with contract 3, the exact producer and shared revision, `master` as the protected integration branch, and the required `devRuntimeEnvironment`. [Example configuration](examples/shared-release.json)

GitHub-hosted runners build or package the prequalified output, verify compiled identity, and publish an immutable tagged release. DEV `vX.Y.Z-dev.N` tags can point to authorized commits outside master. Stable `vX.Y.Z` tags require protected master ancestry.

| Release tag | Deployment channel | Deployment target ID | GitHub environment | ASP.NET Core runtime environment |
| --- | --- | --- | --- | --- |
| `vX.Y.Z-dev.N` | DEV | `<application-id>-dev` | `<application-id>-dev` | `devRuntimeEnvironment` |
| `vX.Y.Z` | Production | `<application-id>-production` | `<application-id>-production` | `Production` |
| `vX.Y.Z-beta.N` or `vX.Y.Z-rc.N` | Artifact-only | — | — | — |

The tag selects the channel, which identifies the dedicated server target and the GitHub environment that governs its job. The runner labels are `self-hosted`, `Windows`, `X64`, and the target ID. The ASP.NET Core runtime environment controls application behavior on that server. For DEV, the workflow reads it from the authenticated `.clc/release.json` at the tagged revision. Use `Production` for the SSRS Web DEV pilot or explicitly select `Staging` for an application that expects it. Set the host's runtime environment to match.

The hosted routing job verifies the producer and GitHub Actions artifact digest, inspects the package and matches its SHA-256 to the immutable GitHub release asset. The Windows deployment job repeats these checks and invokes Clc.Deployment with the authenticated release digest. Set `CLC_RUNTIME_ACCOUNT` as a target environment variable with the expected pool account name. Keep credentials and application configuration on the host. The checkout on the self-hosted deployment runner contains pinned shared toolkit code. Application build and test execution happens on GitHub-hosted runners.

The consumer owns its initialization workflow. Use a manual dispatch from trusted workflow code, enforce the protected branch and runner access before scheduling a self-hosted job, and supply the application ID, target ID, IIS names and URI explicitly. The follow-up SSRS Web integration owns these inputs, runner routing, toolkit selection, application build/validator and environment configuration. Follow the [GitHub setup](github-setup.md).


For a retry of a published release in the same workflow run, select the original successful producer attempt. Rebuilding under a new attempt changes the package provenance and immutable ZIP bytes. An operator can also recover the target, then use the exact published archive and trusted release metadata through the direct API.

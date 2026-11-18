# Setup guide

## 1. Prepare the server and runner

Use a dedicated Windows Server 2022 x64 IIS server for each target. Install IIS, IIS Management Scripts and Tools, and the x64 .NET 10 Hosting Bundle. Use stable PowerShell 7.6.6 or later within the 7.x major version. Run host commands with an enabled elevated local administrator token. Register the dedicated GitHub Actions runner according to the [GitHub setup](github-setup.md), and select a [trusted toolkit revision](installation.md).

## 2. Preview and initialize

Choose the names and readiness hostname for the target explicitly. The following uses a fictional application.

```powershell
$target = @{
    ApplicationId = 'example-app'
    TargetId = 'example-app-dev'
    SiteName = 'Example App DEV'
    ApplicationPoolName = 'ExampleApp.Dev'
    ReadinessUri = 'https://example-app-dev.example.org/health/ready'
}
Initialize-ClcDeploymentHost -Operation Preview @target
Initialize-ClcDeploymentHost -Operation Initialize @target
```

Review Preview's planned paths and IIS settings. For a blocked Preview, inspect the reported findings and existing resources. Completed initialization returns `InitializedNeedsConfiguration`. A matching repeat returns `AlreadyInitialized`. An incomplete scaffold requires manual inspection. Preserve its evidence and account for every existing resource before deciding how to proceed.

The new site has zero bindings and the pool uses an inert ApplicationPoolIdentity. Both remain stopped and have automatic startup disabled. The initializer sets Integrated pipeline, No Managed Code, x64, one worker, Load User Profile, and disabled overlapping recycling.

## 3. Configure the stopped site and pool

In IIS Manager, configure the pool with the expected specific, distinct nonadministrator service account. Configure the site's dedicated HTTPS DNS hostname and port matching the readiness URI. Select an unexpired matching certificate with a private key from LocalMachine. Use a single HTTPS binding with a locally installed certificate. Set `ASPNETCORE_ENVIRONMENT` or `DOTNET_ENVIRONMENT` to `Production` on the Production target. On the DEV target, match `devRuntimeEnvironment` in the consumer's `.clc/release.json`. The example uses `Production`, as required for the SSRS Web DEV pilot. Applications that use `Staging` on DEV can select it explicitly. Keep the site and pool stopped, with both auto-start flags disabled, until first deployment succeeds. [Shared workflow routing](shared-release-orchestration.md)

The administrator provides the application dependencies and operational settings. The app root is always under the operating system's ProgramData known folder. Assign the following access to the service account SID. Keep Administrators and SYSTEM as the trusted owners of protected paths.

| Directory | Purpose | Runtime access |
| --- | --- | --- |
| Application | Managed release files | Inherited Read and Execute |
| Config | External `application.json` and app configuration | Read and Execute |
| Keys | Persistent Data Protection key ring | Inherited Modify |
| Logs | Persistent application logs | Inherited Modify |
| Inbox | Temporary package intake, when used | Exclude write access |
| Deployment | Local control and retained attempts | Exclude write access |

Grant the runtime account only its required access. Provision existing Data Protection material and permissions if the application requires it. Keep configuration and credentials on the server. The application owns their format and the readiness response.

## 4. Validate and deploy

```powershell
$hostInputs = @{
    ApplicationId = $target.ApplicationId
    TargetId = $target.TargetId
    ExpectedRuntimeAccount = $expectedServiceAccount
    RuntimeEnvironment = 'Production'
}
Test-ClcDeploymentHost @hostInputs
```

Resolve the reported findings until the result is `ReadyForFirstDeployment`. Push an authorized release tag and observe the build, publication, deployment, and readiness result. A successful first deployment starts the site and pool and enables automatic startup. Future releases use the same deployment command.

If a deployment fails, preserve local evidence and follow the [recovery procedure](deployment.md). Use the [IIS verification checklist](iis-verification.md) before operational acceptance.

# Clc.Deployment.AspNetCore

`Clc.Deployment.AspNetCore` contains the application-side version-1 validator and readiness protocol used by the PowerShell deployment module. It reads release identity from the assembly supplied by the consuming app, parses `--validate-deployment --configuration-path <file> --data-protection-root <keys> --environment Production|Staging`, writes the bounded version-1 JSON response, and provides an anonymous readiness middleware for `GET /health/ready`. Current repository source, toolkit and companion package metadata use `MIT`, stated in the root `LICENSE` and package metadata. Previously published `0.1.0-beta.2` artifacts remain under AGPL-3.0-only.

The consuming application still owns external configuration loading and semantics, configuration revisions, key-store compatibility and validation, database compatibility, required startup checks, and all business services. The package does not load application configuration, create or protect keys, probe remote services, or alter the PowerShell module's approval, IIS, backup, or recovery behavior.

## Application integration

Keep the four `Clc.*` assembly metadata values in the application build. Use the consuming assembly explicitly in both early validation and normal startup:

```csharp
const string applicationId = "example-app";
const string keyStoreCompatibilityId = "example-keyring-v1";

var validationOptions = new DeploymentValidationOptions(
    typeof(Program).Assembly,
    applicationId,
    keyStoreCompatibilityId,
    request => ValidateExternalConfigurationAndKeys(request));

if (ClcDeploymentValidator.TryRun(args, validationOptions, Console.Out, out var exitCode))
{
    Environment.ExitCode = exitCode;
    return;
}
```

Place this block before `WebApplication.CreateBuilder`, logging setup, and hosted-service registration. The callback receives only the three parsed values and returns the application's validated configuration revision (1–64 characters). The application-supplied `keyStoreCompatibilityId` keeps its existing version-1 grammar and 1–128-character bound. Use `DeploymentValidationException` with a version-1 error code for known safe failures; unexpected exception messages are discarded by the package.

For readiness, create a `DeploymentReadinessGate`, register `UseClcDeploymentReadiness` before HTTPS redirection and authentication, and call `MarkReady()` only after the app's required startup checks complete. ASP.NET Core host-start and host-stopping state also gate the response. The middleware emits the seven-field version-1 JSON response with `application/json`, `Cache-Control: no-store`, and status 200 or 503. It short-circuits before later authentication, redirect, and cookie middleware.

## Package availability

The package and toolkit share each release version published from this repository. Release tags determine their version; root [`VERSION`](../VERSION) is only the untagged development fallback. Package verification restores the actual nupkg from an isolated local feed and package cache, checks its exact ID/version/license/source identity and bytes, creates a throwaway lock for its content hash, then repeats the restore in locked mode. The consuming application's committed lock remains the immutable package verification boundary. Adoption requires an exact approved package version, accessible matching source revision and application-owned acceptance. See [shared releases](releasing.md) for publication policy and required external setup.

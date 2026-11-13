using System.Text.Json;
using Microsoft.AspNetCore.DataProtection;

var identity = ProbeIdentity.Embedded();
if (args.Length > 0 && args[0] == "--validate-deployment")
{
    ProbeConfiguration? configuration = null;
    var valid = false;
    var environment = "Production";
    try
    {
        var input = ProbeConfiguration.ValidatorArguments(args);
        environment = input.Environment;
        configuration = ProbeConfiguration.Load(input.Path, input.Keys, input.Environment);
        valid = true;
    }
    catch { /* Only bounded fixed error codes leave this process. */ }
    Console.Write(JsonSerializer.Serialize(new
    {
        validationContractVersion = 1, valid,
        applicationId = identity.ApplicationId, releaseId = identity.ReleaseId, sourceCommit = identity.SourceCommit,
        runtimeEnvironment = environment is "Production" or "Staging" ? environment : "Production",
        configurationRevision = configuration?.Revision ?? "invalid",
        keyStoreCompatibilityId = configuration?.CompatibilityId ?? "invalid",
        errorCodes = valid ? Array.Empty<string>() : new[] { "InvalidConfiguration" }
    }));
    return valid ? 0 : 2;
}

// The probe deliberately accepts no normal command-line configuration overrides.
// These two nonsecret paths are provisioned on its disposable IIS pool.
if (args.Length != 0) return 2;
var startupStage = "configuration";
try
{
    var environment = Environment.GetEnvironmentVariable("ASPNETCORE_ENVIRONMENT") ?? "Production";
    var dotnetEnvironment = Environment.GetEnvironmentVariable("DOTNET_ENVIRONMENT");
    if (dotnetEnvironment is not null && dotnetEnvironment != environment) return 2;
    var configuration = ProbeConfiguration.Load(
        Environment.GetEnvironmentVariable("CLC_PROBE_CONFIGURATION_PATH") ?? "",
        Environment.GetEnvironmentVariable("CLC_PROBE_DATA_PROTECTION_ROOT") ?? "", environment);
    if (!OperatingSystem.IsWindows()) return 2;
    startupStage = "host-builder";
    var builder = WebApplication.CreateBuilder(new WebApplicationOptions
    {
        Args = Array.Empty<string>(), EnvironmentName = environment, ContentRootPath = AppContext.BaseDirectory
    });
    // A loopback URL is used only by the hosted process contract tests. Under IIS,
    // the server integration supplies the binding and no extra listener is added.
    if (Environment.GetEnvironmentVariable("ASPNETCORE_PORT") is null &&
        Environment.GetEnvironmentVariable("ASPNETCORE_IIS_PHYSICAL_PATH") is null &&
        Environment.GetEnvironmentVariable("CLC_PROBE_LOOPBACK_URL") is string loopback)
    {
        var uri = new Uri(loopback);
        if (uri.Scheme != "http" || uri.Host != "127.0.0.1" || uri.AbsolutePath != "/" || uri.Port == 0) return 2;
        builder.WebHost.UseUrls(loopback);
    }
    builder.Logging.ClearProviders();
    startupStage = "key-services";
    builder.Services.AddDataProtection().SetApplicationName("CLC.DisposableQualification.Probe.v1")
        .PersistKeysToFileSystem(new DirectoryInfo(configuration.KeyRoot)).ProtectKeysWithDpapi(protectToLocalMachine: false);
    startupStage = "host-build";
    var app = builder.Build();
    var protector = app.Services.GetRequiredService<IDataProtectionProvider>().CreateProtector("disposable-continuity-v1");
    const string harmless = "CLC disposable probe continuity value";
    var ready = false;
    // A real protection round trip is required. Failure never yields a ready body.
    try { ready = protector.Unprotect(protector.Protect(harmless)) == harmless; } catch { }
    app.Lifetime.ApplicationStopping.Register(() => ready = false);
    startupStage = "endpoints";
    app.MapGet("/health/ready", (HttpContext context) =>
    {
        context.Response.Headers.CacheControl = "no-store";
        if (!ready) return Results.StatusCode(503);
        return Results.Json(new
        {
            readinessContractVersion = 1, status = "ready", applicationId = identity.ApplicationId,
            releaseId = identity.ReleaseId, sourceCommit = identity.SourceCommit,
            runtimeEnvironment = configuration.Environment, configurationRevision = configuration.Revision
        });
    }).AllowAnonymous();
    app.MapGet("/probe/value", () => Results.Json(new { releaseId = identity.ReleaseId, value = "disposable-probe" }));
    app.MapGet("/probe/protect", () => ready ? Results.Text(protector.Protect(harmless)) : Results.StatusCode(503));
    app.MapPost("/probe/unprotect", async (HttpContext context) =>
    {
        if (!ready || context.Request.ContentLength is null or > 4096) return Results.StatusCode(400);
        using var reader = new StreamReader(context.Request.Body);
        var token = await reader.ReadToEndAsync(context.RequestAborted);
        if (token.Length > 4096) return Results.StatusCode(400);
        try { return protector.Unprotect(token) == harmless ? Results.Ok() : Results.BadRequest(); }
        catch { return Results.BadRequest(); }
    });
    startupStage = "listener";
    await app.RunAsync();
    return 0;
}
catch (Exception exception) { Console.Error.Write("ProbeStartupFailed:" + startupStage + ":" + exception.GetType().Name); return 2; }

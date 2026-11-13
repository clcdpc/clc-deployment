// Deliberately broken, separately approved application fixtures. These are never
// part of the normal probe. No environment variable or deployment bypass selects
// their behavior; the immutable build input and artifact identify the fault.
using System.Reflection;
using System.Text.Json;
using Microsoft.AspNetCore.DataProtection;

var identity = ProbeIdentity.Embedded();
if (args.Length > 0 && args[0] == "--validate-deployment")
{
    ProbeConfiguration? config = null;
    var environment = "Production";
    try { var input = ProbeConfiguration.ValidatorArguments(args); environment = input.Environment; config = ProbeConfiguration.Load(input.Path, input.Keys, environment); } catch { }
    Console.Write(JsonSerializer.Serialize(new
    {
        validationContractVersion = 1, valid = config is not null, applicationId = identity.ApplicationId, releaseId = identity.ReleaseId,
        sourceCommit = identity.SourceCommit, runtimeEnvironment = environment is "Production" or "Staging" ? environment : "Production",
        configurationRevision = config?.Revision ?? "invalid", keyStoreCompatibilityId = config?.CompatibilityId ?? "invalid",
        errorCodes = config is not null ? Array.Empty<string>() : new[] { "InvalidConfiguration" }
    }));
    return config is not null ? 0 : 2;
}
try
{
    if (args.Length != 0) return 2;
    var failure = Assembly.GetExecutingAssembly().GetCustomAttributes<AssemblyMetadataAttribute>().Single(a => a.Key == "FailureKind").Value;
    if (failure == "StartupFailure") return 2;
    var environment = Environment.GetEnvironmentVariable("ASPNETCORE_ENVIRONMENT") ?? "Production";
    var config = ProbeConfiguration.Load(Environment.GetEnvironmentVariable("CLC_PROBE_CONFIGURATION_PATH") ?? "", Environment.GetEnvironmentVariable("CLC_PROBE_DATA_PROTECTION_ROOT") ?? "", environment);
    if (!OperatingSystem.IsWindows()) return 2;
    var builder = WebApplication.CreateBuilder(new WebApplicationOptions { Args = Array.Empty<string>(), EnvironmentName = environment, ContentRootPath = AppContext.BaseDirectory });
    builder.Logging.ClearProviders();
    if (Environment.GetEnvironmentVariable("CLC_PROBE_LOOPBACK_URL") is string loopback)
    {
        var uri = new Uri(loopback);
        if (uri.Scheme != "http" || uri.Host != "127.0.0.1" || uri.AbsolutePath != "/") return 2;
        builder.WebHost.UseUrls(loopback);
    }
    builder.Services.AddDataProtection().SetApplicationName("CLC.DisposableQualification.Probe.v1")
        .PersistKeysToFileSystem(new DirectoryInfo(config.KeyRoot)).ProtectKeysWithDpapi(protectToLocalMachine: false);
    var app = builder.Build();
    var protector = app.Services.GetRequiredService<IDataProtectionProvider>().CreateProtector("disposable-continuity-v1");
    if (protector.Unprotect(protector.Protect("disposable fixture startup")) != "disposable fixture startup") return 2;
    app.MapGet("/health/ready", async (HttpContext context) =>
    {
        context.Response.Headers.CacheControl = "no-store";
        if (failure == "Redirect") { context.Response.Redirect("/fixture-redirect"); return; }
        if (failure == "Authentication") { context.Response.StatusCode = 401; context.Response.Headers.WWWAuthenticate = "Basic realm=disposable-fixture"; return; }
        if (failure == "Cookie") context.Response.Headers.SetCookie = "disposable-fixture=synthetic; Secure; HttpOnly; SameSite=Strict";
        if (failure == "Unavailable") { context.Response.StatusCode = 503; return; }
        if (failure == "Timeout") await Task.Delay(TimeSpan.FromSeconds(15), context.RequestAborted);
        context.Response.ContentType = "application/json; charset=utf-8";
        await context.Response.WriteAsJsonAsync(new
        {
            readinessContractVersion = 1, status = "ready", applicationId = identity.ApplicationId,
            releaseId = failure == "WrongRelease" ? "deliberately-wrong-fixture" : identity.ReleaseId,
            sourceCommit = failure == "WrongSource" ? new string(identity.SourceCommit[0] == 'a' ? 'b' : 'a', 40) : identity.SourceCommit,
            runtimeEnvironment = config.Environment, configurationRevision = failure == "WrongRevision" ? "deliberately-wrong-fixture" : config.Revision
        });
    });
    await app.RunAsync();
    return 0;
}
catch { Console.Error.Write("NegativeFixtureStartupFailed"); return 2; }

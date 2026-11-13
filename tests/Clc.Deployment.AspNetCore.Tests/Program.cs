using System.Reflection;
using System.Text.Json;
using Clc.Deployment.AspNetCore;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

internal static class Program
{
    private const string ApplicationId = "companion-tests";
    private const string ReleaseId = "companion-tests-001";
    private const string SourceCommit = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    private const string KeyStoreCompatibilityId = "companion-key-v1";
    private static int assertions;

    private static async Task Main()
    {
        IdentityComesFromConsumerAssembly();
        ValidatorRecognizesOnlyValidationInvocations();
        ValidatorWritesExactSuccessContract();
        ValidatorPreservesV1CompatibilityAndRevisionBounds();
        ValidatorRejectsMalformedArgumentsWithoutEchoingThem();
        ValidatorMapsApplicationExceptionsToSafeErrors();
        await ReadinessGatesStartupShutdownAndAuthentication();
        await ReadinessAcceptsUnavailableAsAValidRevision();
        await ReadinessRejectsInvalidRevisionAndCallbackFailureSafely();
        Console.WriteLine($"Passed {assertions} ASP.NET Core companion assertions.");
    }

    private static void IdentityComesFromConsumerAssembly()
    {
        var identity = ClcApplicationIdentity.ReadFromAssembly(typeof(Program).Assembly, ApplicationId);
        Check(identity.IsRelease, "consumer assembly release metadata should be valid");
        Equal(ApplicationId, identity.ApplicationId, "application ID");
        Equal(ReleaseId, identity.ReleaseId, "release ID");
        Equal(SourceCommit, identity.SourceCommit, "source commit");

        var packageIdentity = ClcApplicationIdentity.ReadFromAssembly(typeof(ClcDeploymentValidator).Assembly, ApplicationId);
        Equal("Clc.Deployment.AspNetCore", typeof(ClcDeploymentValidator).Assembly.GetName().Name, "package assembly identity casing");
        Equal("Clc.Deployment.AspNetCore", typeof(ClcDeploymentValidator).Namespace, "package namespace casing");
        Check(!packageIdentity.IsRelease, "package assembly must not supply consumer identity");
        Equal("synthetic-invalid", packageIdentity.ReleaseId, "safe invalid release placeholder");
        Equal(new string('0', 40), packageIdentity.SourceCommit, "safe invalid source placeholder");
    }

    private static void ValidatorRecognizesOnlyValidationInvocations()
    {
        var called = false;
        var options = Options(_ => { called = true; return "revision-1"; });
        using var output = new StringWriter();
        Check(!ClcDeploymentValidator.TryRun(["--urls", "http://127.0.0.1:1"], options, output, out var exitCode), "normal startup must continue");
        Equal(0, exitCode, "normal startup exit code");
        Equal(string.Empty, output.ToString(), "normal startup output");
        Check(!called, "normal startup must not run deployment validation");
        Check(ClcDeploymentValidator.IsValidationInvocation(["--validate-deployment-extra"]), "malformed validator prefixes must enter safe validation");
    }

    private static void ValidatorWritesExactSuccessContract()
    {
        DeploymentValidationRequest? observed = null;
        var options = Options(request => { observed = request; return "config-r7"; });
        using var output = new StringWriter();
        var exitCode = ClcDeploymentValidator.Run(ValidArguments(), options, output);
        Equal(0, exitCode, "valid validator exit code");
        Check(observed is not null, "application validator callback should run");
        Equal("C:\\private\\application.json", observed!.ConfigurationPath, "configuration path");
        Equal("C:\\private\\keys", observed.DataProtectionRoot, "key root");
        Equal("Staging", observed.RuntimeEnvironment, "runtime environment");

        using var document = JsonDocument.Parse(output.ToString());
        var root = document.RootElement;
        Names(root, "validationContractVersion", "valid", "applicationId", "releaseId", "sourceCommit", "runtimeEnvironment",
            "configurationRevision", "keyStoreCompatibilityId", "errorCodes");
        Equal(1, root.GetProperty("validationContractVersion").GetInt32(), "validation contract version");
        Check(root.GetProperty("valid").GetBoolean(), "validator should return valid");
        Equal(ApplicationId, root.GetProperty("applicationId").GetString(), "response application ID");
        Equal(ReleaseId, root.GetProperty("releaseId").GetString(), "response release ID");
        Equal(SourceCommit, root.GetProperty("sourceCommit").GetString(), "response source commit");
        Equal("Staging", root.GetProperty("runtimeEnvironment").GetString(), "response environment");
        Equal("config-r7", root.GetProperty("configurationRevision").GetString(), "response revision");
        Equal(KeyStoreCompatibilityId, root.GetProperty("keyStoreCompatibilityId").GetString(), "response key compatibility");
        Equal(0, root.GetProperty("errorCodes").GetArrayLength(), "success error count");
        Check(System.Text.Encoding.UTF8.GetByteCount(output.ToString()) < 8192, "validator output must remain bounded");
    }

    private static void ValidatorPreservesV1CompatibilityAndRevisionBounds()
    {
        foreach (var length in new[] { 64, 65, 128 })
        {
            var compatibilityId = new string('k', length);
            var options = Options(_ => "Revision_1", compatibilityId);
            Equal(compatibilityId, options.KeyStoreCompatibilityId, $"compatibility ID length {length}");
        }
        var grammarCompatibilityId = "K1._-" + new string('z', 123);
        Equal(128, grammarCompatibilityId.Length, "version-1 compatibility grammar fixture length");
        Equal(grammarCompatibilityId, Options(_ => "Revision_1", grammarCompatibilityId).KeyStoreCompatibilityId,
            "compatibility ID preserves uppercase, lowercase, digit, dot, underscore, and hyphen grammar");

        var rejectedCompatibilityId = false;
        try { _ = Options(_ => "Revision_1", new string('k', 129)); }
        catch (ArgumentException) { rejectedCompatibilityId = true; }
        Check(rejectedCompatibilityId, "compatibility ID length 129 must be rejected");

        var invalidGrammarCompatibilityId = false;
        try { _ = Options(_ => "Revision_1", ".invalid"); }
        catch (ArgumentException) { invalidGrammarCompatibilityId = true; }
        Check(invalidGrammarCompatibilityId, "compatibility ID grammar must retain its alphanumeric first character");

        var validRevision = ClcDeploymentValidator.Validate(ValidArguments(), Options(_ => new string('r', 64)));
        Check(validRevision.Valid, "configuration revision length 64 must remain valid");
        Equal(new string('r', 64), validRevision.ConfigurationRevision, "64-character configuration revision");

        var longRevision = ClcDeploymentValidator.Validate(ValidArguments(), Options(_ => new string('r', 65)));
        Check(!longRevision.Valid, "configuration revision length 65 must be rejected");
        Equal("unavailable", longRevision.ConfigurationRevision, "invalid revision uses safe placeholder");
    }

    private static void ValidatorRejectsMalformedArgumentsWithoutEchoingThem()
    {
        var callbackCount = 0;
        var options = Options(_ => { callbackCount++; return "config-r1"; });
        using var output = new StringWriter();
        var exitCode = ClcDeploymentValidator.Run(["--validate-deployment", "SECRET_SENTINEL"], options, output);
        Equal(1, exitCode, "malformed validator exit code");
        Equal(0, callbackCount, "malformed arguments must not invoke app validation");
        Check(!output.ToString().Contains("SECRET_SENTINEL", StringComparison.Ordinal), "input values must not be reflected");
        Check(System.Text.Encoding.UTF8.GetByteCount(output.ToString()) < 8192, "error output must remain bounded");
        using var document = JsonDocument.Parse(output.ToString());
        Names(document.RootElement, "validationContractVersion", "valid", "applicationId", "releaseId", "sourceCommit", "runtimeEnvironment",
            "configurationRevision", "keyStoreCompatibilityId", "errorCodes");
        Equal("InvalidArguments", document.RootElement.GetProperty("errorCodes")[0].GetString(), "malformed argument error");
        Equal(ReleaseId, document.RootElement.GetProperty("releaseId").GetString(), "valid compiled identity remains available on argument errors");

        using var partial = new StringWriter();
        exitCode = ClcDeploymentValidator.Run(
            ["--validate-deployment", "--environment", "Development", "--environment", "Staging", "--data-protection-root", "x"],
            options, partial);
        Equal(1, exitCode, "duplicate argument with unsupported partial environment exit code");
        using var partialDocument = JsonDocument.Parse(partial.ToString());
        Equal("Production", partialDocument.RootElement.GetProperty("runtimeEnvironment").GetString(), "unsupported partial environment uses safe default");
        Equal(2, partialDocument.RootElement.GetProperty("errorCodes").GetArrayLength(), $"invalid arguments and environment both reported; response {partial}");
        Equal("InvalidArguments", partialDocument.RootElement.GetProperty("errorCodes")[0].GetString(), "argument error ordering");
        Equal("UnsupportedEnvironment", partialDocument.RootElement.GetProperty("errorCodes")[1].GetString(), "environment error ordering");

        using var unsupported = new StringWriter();
        exitCode = ClcDeploymentValidator.Run(ValidArguments(environment: "Development"), options, unsupported);
        Equal(1, exitCode, "unsupported environment exit code");
        Equal(0, callbackCount, "unsupported environment must not invoke app validation");
        Check(unsupported.ToString().Contains("UnsupportedEnvironment", StringComparison.Ordinal), "unsupported environment should use the stable error code");
        Check(!unsupported.ToString().Contains("Development", StringComparison.Ordinal), "unsupported value must not be reflected");
    }

    private static void ValidatorMapsApplicationExceptionsToSafeErrors()
    {
        var options = Options(_ => throw new InvalidOperationException("SECRET_SENTINEL"));
        using var output = new StringWriter();
        var exitCode = ClcDeploymentValidator.Run(ValidArguments(), options, output);
        Equal(1, exitCode, "application validation failure exit code");
        Check(output.ToString().Contains("ConfigurationOrKeyStoreInvalid", StringComparison.Ordinal), "application failures should use the stable generic code");
        Check(!output.ToString().Contains("SECRET_SENTINEL", StringComparison.Ordinal), "exception details must not be reflected");
    }

    private static async Task ReadinessGatesStartupShutdownAndAuthentication()
    {
        var lifetime = new TestApplicationLifetime();
        using var services = new ServiceCollection().AddSingleton<IHostApplicationLifetime>(lifetime).BuildServiceProvider();
        var gate = new DeploymentReadinessGate();
        gate.MarkReady();
        var identity = ClcApplicationIdentity.ReadFromAssembly(typeof(Program).Assembly, ApplicationId);
        var downstreamCalls = 0;
        var app = new ApplicationBuilder(services);
        app.UseClcDeploymentReadiness(identity, "Production", () => "config-r7", gate);
        app.Run(context =>
        {
            downstreamCalls++;
            context.Response.StatusCode = StatusCodes.Status307TemporaryRedirect;
            context.Response.Headers.Location = "/login";
            context.Response.Headers.Append("Set-Cookie", "auth=renewed");
            context.Response.Headers.WWWAuthenticate = "Bearer";
            return Task.CompletedTask;
        });
        var pipeline = app.Build();

        var beforeStart = await SendReadiness(pipeline, services);
        Equal(StatusCodes.Status503ServiceUnavailable, beforeStart.Status, "startup status");
        Equal("unavailable", beforeStart.Json.RootElement.GetProperty("status").GetString(), "startup response status");
        Check(!beforeStart.Json.RootElement.GetRawText().Contains("SECRET_SENTINEL", StringComparison.Ordinal), "startup response does not leak details");
        Check(!beforeStart.SetCookie && !beforeStart.Location && !beforeStart.Challenge, "startup readiness remains anonymous, cookie-free, and redirect-free");
        beforeStart.Json.Dispose();

        lifetime.MarkStarted();
        var ready = await SendReadiness(pipeline, services);
        Equal(StatusCodes.Status200OK, ready.Status, "ready status");
        Equal("application/json", ready.ContentType, "ready content type");
        Equal("no-store", ready.CacheControl, "ready cache policy");
        Check(!ready.SetCookie, "readiness must not set cookies");
        Check(!ready.Location, "readiness must not redirect");
        Check(!ready.Challenge, "readiness must not challenge authentication");
        Equal(0, downstreamCalls, "readiness must bypass later authentication/redirect middleware");
        Names(ready.Json.RootElement, "readinessContractVersion", "status", "applicationId", "releaseId", "sourceCommit",
            "runtimeEnvironment", "configurationRevision");
        Equal(1, ready.Json.RootElement.GetProperty("readinessContractVersion").GetInt32(), "readiness contract version");
        Equal("ready", ready.Json.RootElement.GetProperty("status").GetString(), "ready response status");
        Equal(ApplicationId, ready.Json.RootElement.GetProperty("applicationId").GetString(), "ready application ID");
        Equal(ReleaseId, ready.Json.RootElement.GetProperty("releaseId").GetString(), "ready release ID");
        Equal(SourceCommit, ready.Json.RootElement.GetProperty("sourceCommit").GetString(), "ready source commit");
        Equal("Production", ready.Json.RootElement.GetProperty("runtimeEnvironment").GetString(), "ready environment");
        Equal("config-r7", ready.Json.RootElement.GetProperty("configurationRevision").GetString(), "ready revision");
        Check(System.Text.Encoding.UTF8.GetByteCount(ready.Json.RootElement.GetRawText()) < 4096, "readiness response must remain bounded");
        ready.Json.Dispose();

        lifetime.StopApplication();
        var stopping = await SendReadiness(pipeline, services);
        Equal(StatusCodes.Status503ServiceUnavailable, stopping.Status, "shutdown status");
        Equal("unavailable", stopping.Json.RootElement.GetProperty("status").GetString(), "shutdown response status");
        Check(!stopping.Json.RootElement.GetRawText().Contains("SECRET_SENTINEL", StringComparison.Ordinal), "shutdown response does not leak details");
        Check(!stopping.SetCookie && !stopping.Location && !stopping.Challenge, "shutdown readiness remains anonymous, cookie-free, and redirect-free");
        stopping.Json.Dispose();
    }

    private static async Task ReadinessAcceptsUnavailableAsAValidRevision()
    {
        var lifetime = new TestApplicationLifetime();
        using var services = new ServiceCollection().AddSingleton<IHostApplicationLifetime>(lifetime).BuildServiceProvider();
        var gate = new DeploymentReadinessGate();
        gate.MarkReady();
        var pipeline = BuildReadinessPipeline(services, "Production", () => "unavailable", gate);

        lifetime.MarkStarted();
        var response = await SendReadiness(pipeline, services);
        Equal(StatusCodes.Status200OK, response.Status, "the valid revision value 'unavailable' is ready after startup");
        Equal("ready", response.Json.RootElement.GetProperty("status").GetString(), "sentinel-valued revision response status");
        Equal("unavailable", response.Json.RootElement.GetProperty("configurationRevision").GetString(), "sentinel-valued revision is preserved");
        Check(!response.SetCookie && !response.Location && !response.Challenge, "sentinel-valued readiness remains anonymous, cookie-free, and redirect-free");
        response.Json.Dispose();
    }

    private static async Task ReadinessRejectsInvalidRevisionAndCallbackFailureSafely()
    {
        var lifetime = new TestApplicationLifetime();
        using var services = new ServiceCollection().AddSingleton<IHostApplicationLifetime>(lifetime).BuildServiceProvider();
        var gate = new DeploymentReadinessGate();
        gate.MarkReady();
        lifetime.MarkStarted();

        await AssertUnavailable(() => BuildReadinessPipeline(services, "Production", () => null!, gate), services, "null revision");
        await AssertUnavailable(() => BuildReadinessPipeline(services, "Production", () => "not a revision", gate), services, "invalid revision");
        await AssertUnavailable(() => BuildReadinessPipeline(services, "Production", () => throw new InvalidOperationException("SECRET_SENTINEL"), gate), services, "callback exception");

        gate.MarkUnavailable();
        await AssertUnavailable(() => BuildReadinessPipeline(services, "Production", () => "config-r7", gate), services,
            "incomplete application startup", expectedRevision: "config-r7");
    }

    private static RequestDelegate BuildReadinessPipeline(IServiceProvider services, string environment,
        Func<string> configurationRevision, DeploymentReadinessGate gate)
    {
        var app = new ApplicationBuilder(services);
        app.UseClcDeploymentReadiness(ClcApplicationIdentity.ReadFromAssembly(typeof(Program).Assembly, ApplicationId),
            environment, configurationRevision, gate);
        return app.Build();
    }

    private static async Task AssertUnavailable(Func<RequestDelegate> build, IServiceProvider services, string reason,
        string expectedRevision = "unavailable")
    {
        var response = await SendReadiness(build(), services);
        Equal(StatusCodes.Status503ServiceUnavailable, response.Status, $"{reason} status");
        Equal("unavailable", response.Json.RootElement.GetProperty("status").GetString(), $"{reason} response status");
        Equal(expectedRevision, response.Json.RootElement.GetProperty("configurationRevision").GetString(), $"{reason} safe revision");
        Check(!response.Json.RootElement.GetRawText().Contains("SECRET_SENTINEL", StringComparison.Ordinal), $"{reason} does not leak callback details");
        Check(!response.SetCookie && !response.Location && !response.Challenge, $"{reason} remains anonymous, cookie-free, and redirect-free");
        response.Json.Dispose();
    }

    private static async Task<(int Status, string ContentType, string CacheControl, bool SetCookie, bool Location, bool Challenge, JsonDocument Json)> SendReadiness(
        RequestDelegate pipeline, IServiceProvider services)
    {
        await using var body = new MemoryStream();
        var context = new DefaultHttpContext
        {
            RequestServices = services,
            Response = { Body = body }
        };
        context.Request.Method = HttpMethods.Get;
        context.Request.Path = "/health/ready";
        context.Request.Headers.Cookie = "__Host-Portal=invalid";
        await pipeline(context);
        body.Position = 0;
        var json = await JsonDocument.ParseAsync(body);
        return (context.Response.StatusCode,
            context.Response.ContentType?.Split(';')[0] ?? string.Empty,
            context.Response.Headers.CacheControl.ToString(),
            context.Response.Headers.ContainsKey("Set-Cookie"),
            context.Response.Headers.ContainsKey("Location"),
            context.Response.Headers.ContainsKey("WWW-Authenticate"),
            json);
    }

    private static DeploymentValidationOptions Options(Func<DeploymentValidationRequest, string> validator,
        string keyStoreCompatibilityId = KeyStoreCompatibilityId) =>
        new(typeof(Program).Assembly, ApplicationId, keyStoreCompatibilityId, validator);

    private static string[] ValidArguments(string environment = "Staging") =>
    ["--validate-deployment", "--configuration-path", "C:\\private\\application.json", "--data-protection-root", "C:\\private\\keys", "--environment", environment];

    private static void Names(JsonElement element, params string[] expected)
    {
        var actual = element.EnumerateObject().Select(property => property.Name).ToArray();
        Check(expected.SequenceEqual(actual), $"JSON fields expected [{string.Join(',', expected)}], observed [{string.Join(',', actual)}]");
    }

    private static void Check(bool condition, string message)
    {
        assertions++;
        if (!condition) { throw new InvalidOperationException("Test failed: " + message); }
    }

    private static void Equal<T>(T expected, T actual, string message)
    {
        assertions++;
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
        {
            throw new InvalidOperationException($"Test failed: {message}; expected '{expected}', got '{actual}'.");
        }
    }

    private sealed class TestApplicationLifetime : IHostApplicationLifetime
    {
        private readonly CancellationTokenSource started = new();
        private readonly CancellationTokenSource stopping = new();
        private readonly CancellationTokenSource stopped = new();

        public CancellationToken ApplicationStarted => started.Token;
        public CancellationToken ApplicationStopping => stopping.Token;
        public CancellationToken ApplicationStopped => stopped.Token;
        public void StopApplication() => stopping.Cancel();
        internal void MarkStarted() => started.Cancel();

        public void Dispose()
        {
            started.Dispose();
            stopping.Dispose();
            stopped.Dispose();
        }
    }
}

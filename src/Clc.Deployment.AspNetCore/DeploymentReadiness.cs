using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

namespace Clc.Deployment.AspNetCore;

/// <summary>The application-controlled startup readiness decision.</summary>
public sealed class DeploymentReadinessGate
{
    private int ready;

    public void MarkReady() => Volatile.Write(ref ready, 1);
    public void MarkUnavailable() => Volatile.Write(ref ready, 0);

    internal bool IsReady => Volatile.Read(ref ready) == 1;
}

/// <summary>Version-1 anonymous readiness middleware. Register before HTTPS redirection and authentication.</summary>
public static class DeploymentReadinessApplicationBuilderExtensions
{
    private const string Path = "/health/ready";
    private const string UnavailableRevision = "unavailable";

    private sealed record ReadinessResponse(
        [property: JsonPropertyName("readinessContractVersion")] int ReadinessContractVersion,
        [property: JsonPropertyName("status")] string Status,
        [property: JsonPropertyName("applicationId")] string ApplicationId,
        [property: JsonPropertyName("releaseId")] string ReleaseId,
        [property: JsonPropertyName("sourceCommit")] string SourceCommit,
        [property: JsonPropertyName("runtimeEnvironment")] string RuntimeEnvironment,
        [property: JsonPropertyName("configurationRevision")] string ConfigurationRevision);

    /// <summary>
    /// Handles GET /health/ready before later middleware. The application marks its gate ready only
    /// after its own startup checks complete; host startup and shutdown are also enforced here.
    /// </summary>
    public static IApplicationBuilder UseClcDeploymentReadiness(this IApplicationBuilder app,
        ClcApplicationIdentity identity, string runtimeEnvironment, Func<string> configurationRevision,
        DeploymentReadinessGate gate)
    {
        ArgumentNullException.ThrowIfNull(app);
        ArgumentNullException.ThrowIfNull(identity);
        ArgumentNullException.ThrowIfNull(runtimeEnvironment);
        ArgumentNullException.ThrowIfNull(configurationRevision);
        ArgumentNullException.ThrowIfNull(gate);

        return app.Use(next => async context =>
        {
            if (!HttpMethods.IsGet(context.Request.Method) || context.Request.Path != Path)
            {
                await next(context);
                return;
            }

            context.Response.Headers.CacheControl = "no-store";
            context.Response.Headers.Remove("Set-Cookie");
            context.Response.Headers.Remove("Location");
            context.Response.Headers.Remove("WWW-Authenticate");

            var environmentSupported = DeploymentContract.IsSupportedEnvironment(runtimeEnvironment);
            var responseEnvironment = environmentSupported ? runtimeEnvironment : "Production";
            var revision = UnavailableRevision;
            var revisionValid = false;
            try
            {
                var observedRevision = configurationRevision();
                if (DeploymentContract.IsValidRevision(observedRevision))
                {
                    revision = observedRevision;
                    revisionValid = true;
                }
            }
            catch (Exception)
            {
                // Readiness is a safe protocol surface. A consumer callback failure means unavailable.
            }

            var lifetime = context.RequestServices.GetRequiredService<IHostApplicationLifetime>();
            var ready = gate.IsReady &&
                lifetime.ApplicationStarted.IsCancellationRequested &&
                !lifetime.ApplicationStopping.IsCancellationRequested &&
                environmentSupported && identity.IsRelease && revisionValid;
            var response = new ReadinessResponse(1, ready ? "ready" : "unavailable", identity.ApplicationId,
                identity.ReleaseId, identity.SourceCommit, responseEnvironment, revision);

            context.Response.StatusCode = ready ? StatusCodes.Status200OK : StatusCodes.Status503ServiceUnavailable;
            context.Response.ContentType = "application/json; charset=utf-8";
            await JsonSerializer.SerializeAsync(context.Response.Body, response, options: null, cancellationToken: context.RequestAborted);
        });
    }
}

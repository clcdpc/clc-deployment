using System.Reflection;
using System.Text.RegularExpressions;

namespace Clc.Deployment.AspNetCore;

/// <summary>Identity compiled into the consuming application assembly.</summary>
public sealed class ClcApplicationIdentity
{
    private const string InvalidReleaseId = "synthetic-invalid";
    private const string InvalidSourceCommit = "0000000000000000000000000000000000000000";
    private static readonly Regex ApplicationIdPattern = new(@"\A[a-z0-9][a-z0-9-]{0,63}\z", RegexOptions.CultureInvariant);
    private static readonly Regex ReleaseIdPattern = new(@"\A[a-z0-9][a-z0-9-]{0,63}\z", RegexOptions.CultureInvariant);
    private static readonly Regex SourceCommitPattern = new(@"\A[a-f0-9]{40}\z", RegexOptions.CultureInvariant);

    private readonly string releaseId;
    private readonly string sourceCommit;

    private ClcApplicationIdentity(string applicationId, string releaseId, string sourceCommit, bool isRelease)
    {
        ApplicationId = applicationId;
        this.releaseId = releaseId;
        this.sourceCommit = sourceCommit;
        IsRelease = isRelease;
    }

    /// <summary>The expected, application-owned identifier supplied by the consumer.</summary>
    public string ApplicationId { get; }

    /// <summary>True only for a valid release identity in the supplied application assembly.</summary>
    public bool IsRelease { get; }

    /// <summary>Returns a safe placeholder when the compiled identity is invalid.</summary>
    public string ReleaseId => IsRelease ? releaseId : InvalidReleaseId;

    /// <summary>Returns a safe placeholder when the compiled identity is invalid.</summary>
    public string SourceCommit => IsRelease ? sourceCommit : InvalidSourceCommit;

    /// <summary>Reads Clc.* assembly metadata from the supplied consuming application assembly.</summary>
    public static ClcApplicationIdentity ReadFromAssembly(Assembly applicationAssembly, string expectedApplicationId)
    {
        ArgumentNullException.ThrowIfNull(applicationAssembly);
        ArgumentException.ThrowIfNullOrWhiteSpace(expectedApplicationId);
        if (!ApplicationIdPattern.IsMatch(expectedApplicationId))
        {
            throw new ArgumentException("Expected application ID is not a contract identifier.", nameof(expectedApplicationId));
        }

        var metadata = ReadMetadata(applicationAssembly);
        var applicationId = metadata.GetValueOrDefault("Clc.ApplicationId");
        var releaseId = metadata.GetValueOrDefault("Clc.ReleaseId");
        var sourceCommit = metadata.GetValueOrDefault("Clc.SourceCommit");
        var kind = metadata.GetValueOrDefault("Clc.IdentityKind");
        var valid = string.Equals(applicationId, expectedApplicationId, StringComparison.Ordinal) &&
            string.Equals(kind, "Release", StringComparison.Ordinal) &&
            releaseId is not null && ReleaseIdPattern.IsMatch(releaseId) &&
            !releaseId.StartsWith("synthetic-", StringComparison.Ordinal) &&
            sourceCommit is not null && SourceCommitPattern.IsMatch(sourceCommit) &&
            !string.Equals(sourceCommit, InvalidSourceCommit, StringComparison.Ordinal);

        return new(expectedApplicationId, releaseId ?? string.Empty, sourceCommit ?? string.Empty, valid);
    }

    private static Dictionary<string, string?> ReadMetadata(Assembly assembly)
    {
        try
        {
            var values = assembly.GetCustomAttributes<AssemblyMetadataAttribute>()
                .Where(attribute => attribute.Key is "Clc.ApplicationId" or "Clc.ReleaseId" or "Clc.SourceCommit" or "Clc.IdentityKind")
                .GroupBy(attribute => attribute.Key, StringComparer.Ordinal);
            var result = new Dictionary<string, string?>(StringComparer.Ordinal);
            foreach (var group in values)
            {
                var entries = group.ToArray();
                if (entries.Length == 1) { result.Add(group.Key, entries[0].Value); }
            }
            return result;
        }
        catch (Exception)
        {
            return new Dictionary<string, string?>(StringComparer.Ordinal);
        }
    }
}

internal static class DeploymentContract
{
    private static readonly Regex ApplicationIdPattern = new(@"\A[a-z0-9][a-z0-9-]{0,63}\z", RegexOptions.CultureInvariant);
    private static readonly Regex RevisionPattern = new(@"\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z", RegexOptions.CultureInvariant);
    private static readonly Regex KeyStoreCompatibilityIdPattern = new(@"\A[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\z", RegexOptions.CultureInvariant);

    internal static bool IsValidApplicationId(string value) => value is not null && ApplicationIdPattern.IsMatch(value);
    internal static bool IsValidRevision(string value) => value is not null && RevisionPattern.IsMatch(value);
    internal static bool IsValidKeyStoreCompatibilityId(string value) => value is not null && KeyStoreCompatibilityIdPattern.IsMatch(value);
    internal static bool IsSupportedEnvironment(string value) => value is "Production" or "Staging";
}

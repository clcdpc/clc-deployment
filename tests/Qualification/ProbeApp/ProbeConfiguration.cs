using System.Reflection;
using System.Text.Json;
using System.Text.RegularExpressions;

internal sealed record ProbeIdentity(string ApplicationId, string ReleaseId, string SourceCommit)
{
    public static ProbeIdentity Embedded()
    {
        var metadata = Assembly.GetExecutingAssembly().GetCustomAttributes<AssemblyMetadataAttribute>()
            .ToDictionary(a => a.Key, a => a.Value!, StringComparer.Ordinal);
        var identity = new ProbeIdentity(metadata["ApplicationId"], metadata["ReleaseId"], metadata["SourceCommit"]);
        if (identity.ApplicationId != "clc-qualification-probe" || !Regex.IsMatch(identity.ReleaseId, "\\A[a-z0-9][a-z0-9-]{0,63}\\z") ||
            !Regex.IsMatch(identity.SourceCommit, "\\A[a-f0-9]{40}\\z") || identity.SourceCommit == new string('0', 40))
            throw new InvalidDataException("InvalidEmbeddedIdentity");
        return identity;
    }
}

internal sealed record ProbeConfiguration(string Revision, string CompatibilityId, string Environment, string KeyRoot)
{
    // No host builder, configuration provider, logger, network client or key
    // manager is constructed here. Startup and validation use this exact loader.
    public static ProbeConfiguration Load(string path, string keys, string environment)
    {
        if (environment is not ("Production" or "Staging")) throw new InvalidDataException("InvalidEnvironment");
        foreach (var value in new[] { path, keys })
        {
            if (!Path.IsPathFullyQualified(value) || value.StartsWith(@"\\", StringComparison.Ordinal) ||
                Path.GetFullPath(value) != value || value.Length > 240) throw new InvalidDataException("InvalidExternalPath");
            var current = value;
            while (!string.IsNullOrEmpty(current))
            {
                if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("InvalidExternalPath");
                current = Path.GetDirectoryName(current);
            }
        }
        var appRoot = Path.GetFullPath(AppContext.BaseDirectory).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        if (path.StartsWith(appRoot, StringComparison.OrdinalIgnoreCase) || keys.StartsWith(appRoot, StringComparison.OrdinalIgnoreCase) || !Directory.Exists(keys))
            throw new InvalidDataException("InvalidExternalPath");
        using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (file.Length is < 2 or > 16384) throw new InvalidDataException("InvalidConfiguration");
        using var json = JsonDocument.Parse(file, new JsonDocumentOptions { MaxDepth = 4 });
        if (json.RootElement.ValueKind != JsonValueKind.Object) throw new InvalidDataException("InvalidConfiguration");
        var fields = new Dictionary<string, JsonElement>(StringComparer.OrdinalIgnoreCase);
        foreach (var property in json.RootElement.EnumerateObject())
            if (!fields.TryAdd(property.Name, property.Value)) throw new InvalidDataException("InvalidConfiguration");
        if (fields.Count != 3 || !fields.Keys.Order(StringComparer.Ordinal).SequenceEqual(new[] { "configurationRevision", "keyStoreCompatibilityId", "syntheticSecret" }))
            throw new InvalidDataException("InvalidConfiguration");
        var revision = fields["configurationRevision"].GetString()!;
        var compatibility = fields["keyStoreCompatibilityId"].GetString()!;
        // A fixed application discriminator and DPAPI-current-user policy remain
        // stable across releases; changing either requires a different app contract.
        if (!Regex.IsMatch(revision, "\\A[A-Za-z0-9_.-]{1,64}\\z") || compatibility != "clc-probe-dpapi-user-v1" ||
            fields["syntheticSecret"].ValueKind != JsonValueKind.String || fields["syntheticSecret"].GetString()!.Length > 256)
            throw new InvalidDataException("InvalidConfiguration");
        return new(revision, compatibility, environment, keys);
    }

    public static (string Path, string Keys, string Environment) ValidatorArguments(string[] args)
    {
        if (args.Length != 7 || args[0] != "--validate-deployment" || args[1] != "--configuration-path" ||
            args[3] != "--data-protection-root" || args[5] != "--environment") throw new InvalidDataException("InvalidArguments");
        return (args[2], args[4], args[6]);
    }
}

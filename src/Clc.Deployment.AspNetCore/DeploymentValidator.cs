using System.Reflection;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Clc.Deployment.AspNetCore;

public enum DeploymentValidationErrorCode
{
    InvalidArguments,
    UnsupportedEnvironment,
    InvalidCompiledIdentity,
    AmbiguousConfigurationSource,
    ConfigurationPathMismatch,
    ConfigurationOrKeyStoreInvalid,
    InvalidDeploymentInput
}

/// <summary>Thrown by application validation to return one stable, nonsecret contract error.</summary>
public sealed class DeploymentValidationException : Exception
{
    public DeploymentValidationException(DeploymentValidationErrorCode errorCode) : base(errorCode.ToString()) => ErrorCode = errorCode;

    public DeploymentValidationErrorCode ErrorCode { get; }
}

/// <summary>Validated command-line inputs passed to application-owned configuration checks.</summary>
public sealed record DeploymentValidationRequest(string ConfigurationPath, string DataProtectionRoot, string RuntimeEnvironment);

/// <summary>Application-owned input and callback for the version-1 deployment validator.</summary>
public sealed class DeploymentValidationOptions
{
    public DeploymentValidationOptions(Assembly applicationAssembly, string applicationId, string keyStoreCompatibilityId,
        Func<DeploymentValidationRequest, string> validateConfiguration)
    {
        ArgumentNullException.ThrowIfNull(applicationAssembly);
        ArgumentException.ThrowIfNullOrWhiteSpace(applicationId);
        ArgumentException.ThrowIfNullOrWhiteSpace(keyStoreCompatibilityId);
        ArgumentNullException.ThrowIfNull(validateConfiguration);
        if (!DeploymentContract.IsValidApplicationId(applicationId) || !DeploymentContract.IsValidKeyStoreCompatibilityId(keyStoreCompatibilityId))
        {
            throw new ArgumentException("Deployment identifiers must match the version-1 contract.");
        }

        ApplicationAssembly = applicationAssembly;
        ApplicationId = applicationId;
        KeyStoreCompatibilityId = keyStoreCompatibilityId;
        ValidateConfiguration = validateConfiguration;
    }

    public Assembly ApplicationAssembly { get; }
    public string ApplicationId { get; }
    public string KeyStoreCompatibilityId { get; }
    public Func<DeploymentValidationRequest, string> ValidateConfiguration { get; }
}

/// <summary>The exact version-1 deployment validator response.</summary>
public sealed record DeploymentValidationResponse(
    [property: JsonPropertyName("validationContractVersion")] int ValidationContractVersion,
    [property: JsonPropertyName("valid")] bool Valid,
    [property: JsonPropertyName("applicationId")] string ApplicationId,
    [property: JsonPropertyName("releaseId")] string ReleaseId,
    [property: JsonPropertyName("sourceCommit")] string SourceCommit,
    [property: JsonPropertyName("runtimeEnvironment")] string RuntimeEnvironment,
    [property: JsonPropertyName("configurationRevision")] string ConfigurationRevision,
    [property: JsonPropertyName("keyStoreCompatibilityId")] string KeyStoreCompatibilityId,
    [property: JsonPropertyName("errorCodes")] string[] ErrorCodes);

/// <summary>Version-1 argument parsing and bounded response plumbing for application validation.</summary>
public static class ClcDeploymentValidator
{
    private const string DefaultEnvironment = "Production";
    private const string UnavailableRevision = "unavailable";
    private const string InvalidReleaseId = "synthetic-invalid";
    private const string InvalidSourceCommit = "0000000000000000000000000000000000000000";
    private const int MaximumPathLength = 4096;

    private static readonly JsonSerializerOptions SerializerOptions = new(JsonSerializerDefaults.Web)
    {
        MaxDepth = 16,
        WriteIndented = false
    };

    /// <summary>JSON options that serialize the package response with the version-1 camel-case fields.</summary>
    public static JsonSerializerOptions JsonOptions => new(SerializerOptions);

    /// <summary>Recognizes the validator switch before the application constructs its host.</summary>
    public static bool IsValidationInvocation(string[] args)
    {
        ArgumentNullException.ThrowIfNull(args);
        return args.Any(argument => argument is not null && argument.StartsWith("--validate-deployment", StringComparison.OrdinalIgnoreCase));
    }

    /// <summary>Runs validation only when a validator switch is present; call before host construction.</summary>
    public static bool TryRun(string[] args, DeploymentValidationOptions options, TextWriter output, out int exitCode)
    {
        ArgumentNullException.ThrowIfNull(args);
        ArgumentNullException.ThrowIfNull(options);
        ArgumentNullException.ThrowIfNull(output);
        if (!IsValidationInvocation(args))
        {
            exitCode = 0;
            return false;
        }

        exitCode = Run(args, options, output);
        return true;
    }

    /// <summary>Validates exact version-1 arguments and writes one bounded JSON response line.</summary>
    public static int Run(string[] args, DeploymentValidationOptions options, TextWriter output)
    {
        ArgumentNullException.ThrowIfNull(output);
        var response = Validate(args, options);
        output.WriteLine(JsonSerializer.Serialize(response, SerializerOptions));
        return response.Valid ? 0 : 1;
    }

    /// <summary>Returns the version-1 validation response without writing it.</summary>
    public static DeploymentValidationResponse Validate(string[] args, DeploymentValidationOptions options)
    {
        ArgumentNullException.ThrowIfNull(args);
        ArgumentNullException.ThrowIfNull(options);
        try
        {
            return ValidateCore(args, options);
        }
        catch (Exception)
        {
            return InvalidInput(options);
        }
    }

    public static bool IsValidConfigurationRevision(string value) => DeploymentContract.IsValidRevision(value);
    public static bool IsSupportedEnvironment(string value) => DeploymentContract.IsSupportedEnvironment(value);

    private static DeploymentValidationResponse ValidateCore(string[] args, DeploymentValidationOptions options)
    {
        var errors = new List<DeploymentValidationErrorCode>();
        var environment = DefaultEnvironment;
        var configurationRevision = UnavailableRevision;
        var request = Parse(args, errors, out var hasEnvironment, out var requestedEnvironment);
        if (hasEnvironment)
        {
            if (DeploymentContract.IsSupportedEnvironment(requestedEnvironment!))
            {
                environment = requestedEnvironment!;
            }
            else
            {
                errors.Add(DeploymentValidationErrorCode.UnsupportedEnvironment);
            }
        }

        var identity = ClcApplicationIdentity.ReadFromAssembly(options.ApplicationAssembly, options.ApplicationId);
        if (!identity.IsRelease) { errors.Add(DeploymentValidationErrorCode.InvalidCompiledIdentity); }

        if (errors.Count == 0 && request is not null)
        {
            try
            {
                var revision = options.ValidateConfiguration(request);
                if (!DeploymentContract.IsValidRevision(revision))
                {
                    errors.Add(DeploymentValidationErrorCode.ConfigurationOrKeyStoreInvalid);
                }
                else
                {
                    configurationRevision = revision;
                }
            }
            catch (DeploymentValidationException exception)
            {
                errors.Add(exception.ErrorCode);
            }
            catch (Exception)
            {
                errors.Add(DeploymentValidationErrorCode.ConfigurationOrKeyStoreInvalid);
            }
        }

        var releaseIdentityValid = identity.IsRelease;
        var codes = errors.Distinct().Select(static code => code.ToString()).ToArray();
        return new(1, codes.Length == 0, options.ApplicationId,
            releaseIdentityValid ? identity.ReleaseId : InvalidReleaseId,
            releaseIdentityValid ? identity.SourceCommit : InvalidSourceCommit,
            environment, configurationRevision, options.KeyStoreCompatibilityId, codes);
    }

    private static DeploymentValidationRequest? Parse(string[] args, List<DeploymentValidationErrorCode> errors,
        out bool hasEnvironment, out string? requestedEnvironment)
    {
        hasEnvironment = false;
        requestedEnvironment = null;
        if (args.Length != 7 || args[0] != "--validate-deployment")
        {
            errors.Add(DeploymentValidationErrorCode.InvalidArguments);
            return null;
        }

        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        for (var index = 1; index < args.Length; index += 2)
        {
            var name = args[index];
            var value = args[index + 1];
            if (name is not ("--configuration-path" or "--data-protection-root" or "--environment") ||
                !values.TryAdd(name, value!))
            {
                errors.Add(DeploymentValidationErrorCode.InvalidArguments);
                return null;
            }
            if (name == "--environment")
            {
                hasEnvironment = true;
                requestedEnvironment = value;
            }
        }

        if (values.Count != 3 ||
            values["--configuration-path"]?.Length > MaximumPathLength ||
            values["--data-protection-root"]?.Length > MaximumPathLength ||
            values["--environment"]?.Length > 32)
        {
            errors.Add(DeploymentValidationErrorCode.InvalidArguments);
            return null;
        }

        return new(values["--configuration-path"]!, values["--data-protection-root"]!, values["--environment"]!);
    }

    private static DeploymentValidationResponse InvalidInput(DeploymentValidationOptions options) =>
        new(1, false, options.ApplicationId, InvalidReleaseId, InvalidSourceCommit, DefaultEnvironment,
            UnavailableRevision, options.KeyStoreCompatibilityId, [DeploymentValidationErrorCode.InvalidDeploymentInput.ToString()]);
}

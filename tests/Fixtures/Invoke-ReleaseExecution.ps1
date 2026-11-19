param([string] $ToolkitRoot, [string] $SharedRevision, [string] $Work, [string] $PublishRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/ReleaseHttp.ps1"

if (Get-Command Assert-ClcPathComponent -ErrorAction SilentlyContinue) {
    throw 'Packaging must start without consumer-side private helpers.'
}
$env:GH_TOKEN = 'fixture-token'
$env:GITHUB_OUTPUT = Join-Path $Work 'outputs.txt'
$repo = 'example/portal'
$sourceCommit = 'a' * 40
$tag = 'v1.2.3-dev.1'
$integration = @{protected=$true; commit=@{sha=('b' * 40)}}
$config = @{
    contractVersion=3; requiredToolkitContractVersion=3; applicationId='probe'; repository=$repo
    integrationBranch='master'; devRuntimeEnvironment='Production'; orchestration=@{sharedRevision=$SharedRevision}
    producer=@{workflowPath='.github/workflows/release.yml'; job='package'}
}
$configPath = Join-Path $Work 'release.json'
$configBytes = [Text.Encoding]::UTF8.GetBytes(($config | ConvertTo-Json -Depth 6 -Compress))
[IO.File]::WriteAllBytes($configPath, $configBytes)
Add-Type -TypeDefinition @"
using System.Reflection;
[assembly: AssemblyMetadata("Clc.ApplicationId", "probe")]
[assembly: AssemblyMetadata("Clc.ReleaseId", "v1-2-3-dev-1")]
[assembly: AssemblyMetadata("Clc.SourceCommit", "$sourceCommit")]
[assembly: AssemblyMetadata("Clc.IdentityKind", "Release")]
public sealed class ReleaseProbe {}
"@ -OutputAssembly (Join-Path $PublishRoot 'Probe.dll')

function Add-JsonResponse($Body) {
    $data = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Body -Depth 10 -Compress))
    $global:ClcReleaseFixtureHttp.Enqueue(200, $null, $data)
}
function Add-SourceResponses {
    Add-JsonResponse $integration
    Add-JsonResponse @{object=@{type='commit'; sha=$sourceCommit}}
    $global:ClcReleaseFixtureHttp.Enqueue(404, $null, [byte[]]::new(0))
}
function Add-ProducerResponses([switch] $ListArtifacts) {
    Add-SourceResponses
    if ($ListArtifacts) { Add-JsonResponse @{artifacts=@($artifact)} }
    Add-JsonResponse @{
        id=123; run_attempt=1; status='in_progress'; conclusion=$null; head_sha=$sourceCommit
        repository=@{full_name=$repo}; head_repository=@{full_name=$repo}; path=$config.producer.workflowPath
        event='push'; head_branch=$tag; run_started_at='2026-11-13T00:00:00Z'
    }
    Add-JsonResponse @{jobs=@(@{
        name='package'; status='completed'; conclusion='success'; head_sha=$sourceCommit; run_id=123
        started_at='2026-11-13T00:00:01Z'; completed_at='2026-11-13T00:10:00Z'
    })}
    Add-JsonResponse $artifact
}

$global:ClcReleaseFixtureHttp = [ClcReleaseTests.RecordingHandler]::new()
try {
    Add-SourceResponses
    $package = & "$ToolkitRoot/tools/release/New-ClcApplicationPackage.ps1" -ConfigurationPath $configPath -SourceRoot $Work `
        -Reference $tag -SourceCommit $sourceCommit -SharedSourceCommit $SharedRevision -RunId 123 -RunAttempt 1 `
        -QualifiedPublishRoot $PublishRoot -SdkVersion '10.0.403' -ValidationEntryPoint 'Probe.dll' -OutputDirectory (Join-Path $Work 'package')
    if ($package.packageContractVersion -ne 3 -or $package.releaseId -cne 'v1-2-3-dev-1') { throw 'Unexpected packaged release identity.' }

    $transportPath = Join-Path $Work 'transport.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory([IO.Path]::GetDirectoryName($package.archivePath), $transportPath, [IO.Compression.CompressionLevel]::NoCompression, $false)
    $transportBytes = [IO.File]::ReadAllBytes($transportPath)
    $artifact = @{
        id=456; expired=$false; name="clc-package-$sourceCommit-123-1"; workflow_run=@{id=123; head_sha=$sourceCommit}
        digest=('sha256:' + (Get-FileHash -LiteralPath $transportPath).Hash.ToLowerInvariant())
        size_in_bytes=$transportBytes.Length; created_at='2026-11-13T00:05:00Z'
    }
    $archiveBytes = [IO.File]::ReadAllBytes($package.archivePath)
    $published = @{
        id=987; tag_name=$tag; target_commitish=$sourceCommit; draft=$false; immutable=$true; prerelease=$true
        assets=@(@{id=654; name='release.zip'; size=$archiveBytes.Length; state='uploaded'; digest=('sha256:' + $package.archiveSha256)})
    }
    $blob = 'f' * 40
    foreach ($action in @('Release', 'Route')) {
        $workflow = if ($action -ceq 'Release') { 'release' } else { 'deploy' }
        $claims = @{
            iss='https://token.actions.githubusercontent.com'; aud='clc-deployment'; repository=$repo; event_name='push'
            workflow_sha=$sourceCommit; workflow_ref="$repo/$($config.producer.workflowPath)@refs/tags/$tag"
            job_workflow_sha=$SharedRevision; job_workflow_ref="clcdpc/clc-deployment/.github/workflows/application-$workflow.yml@$SharedRevision"
            run_id='123'; run_attempt='1'
        }
        Add-JsonResponse @{type='file'; encoding='base64'; size=$configBytes.Length; content=[Convert]::ToBase64String($configBytes); sha=$blob}
        Add-JsonResponse $integration
        Add-SourceResponses
        Add-ProducerResponses -ListArtifacts
        $global:ClcReleaseFixtureHttp.Enqueue(302, 'https://fixture.blob.core.windows.net/artifact', [byte[]]::new(0))
        $global:ClcReleaseFixtureHttp.Enqueue(200, $null, $transportBytes)
        Add-ProducerResponses
        Add-JsonResponse $published
        if ($action -ceq 'Release') {
            $global:ClcReleaseFixtureHttp.Enqueue(302, 'https://release-assets.githubusercontent.com/package', [byte[]]::new(0))
            $global:ClcReleaseFixtureHttp.Enqueue(200, $null, $archiveBytes)
        }

        $directory = Join-Path $Work $action
        $claimsJson = $claims | ConvertTo-Json -Compress
        $result = & "$ToolkitRoot/tools/release/Invoke-ClcApplicationWorkflow.ps1" -Action $action -ClaimsJson $claimsJson `
            -Repository $repo -Reference $tag -SourceCommit $sourceCommit -RunId 123 -RunAttempt 1 -OutputDirectory $directory
        if ($action -ceq 'Release' -and ($result.status -cne 'Preserved' -or $result.releaseId -ne 987)) {
            throw 'The shared publisher did not preserve the exact immutable release.'
        }
        if ((Get-FileHash -LiteralPath (Join-Path $directory 'artifact/release.zip')).Hash -ine $package.archiveSha256 -or
            $global:ClcReleaseFixtureHttp.Responses.Count -ne 0) { throw 'The hosted job did not complete artifact verification.' }
    }
    $outputs = [IO.File]::ReadAllLines($env:GITHUB_OUTPUT)
    foreach ($expected in @('deploy=true', "configuration_blob=$blob", 'artifact_id=456', 'target_id=probe-dev', 'environment=probe-dev')) {
        if ($expected -cnotin $outputs) { throw "Missing routing output $expected." }
    }
    $http = $global:ClcReleaseFixtureHttp
    if (@($http.RequestMethods | Where-Object { $_ -cne 'GET' }).Count -ne 0) { throw 'The fixture attempted to mutate the release.' }
    foreach ($path in @('https://fixture.blob.core.windows.net/artifact', 'https://release-assets.githubusercontent.com/package')) {
        $index = $http.RequestUris.IndexOf($path)
        if ($index -lt 0 -or $http.AuthorizationValues[$index] -or $http.AcceptValues[$index - 1] -cne 'application/octet-stream') {
            throw 'Binary redirect handling differed from the expected credential boundary.'
        }
    }
    Write-Output 'Offline release execution verified.'
} finally {
    $global:ClcReleaseFixtureHttp.Dispose()
}

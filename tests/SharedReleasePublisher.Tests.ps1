BeforeAll {
    . "$PSScriptRoot/Support.ps1"
    . "$script:RepositoryRoot/tools/Distribution.Common.ps1"
    . "$script:RepositoryRoot/tools/SharedReleasePublisher.Common.ps1"

    if ($null -eq ('ClcReleaseTests.RecordingHandler' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

namespace ClcReleaseTests {
    public sealed class ResponseSpec {
        public int StatusCode;
        public string Location;
        public byte[] Body;
    }

    public sealed class RecordingHandler : HttpMessageHandler {
        public readonly List<string> RequestUris = new List<string>();
        public readonly List<string> AuthorizationValues = new List<string>();
        public readonly Queue<ResponseSpec> Responses = new Queue<ResponseSpec>();

        public void Enqueue(int statusCode, string location, byte[] body) {
            Responses.Enqueue(new ResponseSpec { StatusCode = statusCode, Location = location, Body = body ?? Array.Empty<byte>() });
        }

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) {
            RequestUris.Add(request.RequestUri.AbsoluteUri);
            AuthorizationValues.Add(request.Headers.Authorization == null ? null : request.Headers.Authorization.ToString());
            if (Responses.Count == 0) throw new InvalidOperationException("No response was queued for the HTTP request.");
            ResponseSpec item = Responses.Dequeue();
            HttpResponseMessage response = new HttpResponseMessage((HttpStatusCode)item.StatusCode);
            response.Content = new ByteArrayContent(item.Body);
            if (!String.IsNullOrEmpty(item.Location)) response.Headers.Location = new Uri(item.Location, UriKind.RelativeOrAbsolute);
            return Task.FromResult(response);
        }
    }
}
'@ -ErrorAction Stop
    }
}

Describe 'Shared release publisher behavior' {
BeforeEach {
    $script:workspace = New-TestWorkspace
    $script:packagePath = Join-Path $script:workspace 'Clc.Deployment.AspNetCore.0.1.0-beta.1.nupkg'
    $script:signedPackagePath = Join-Path $script:workspace 'signed.nupkg'
    $script:mismatchPackagePath = Join-Path $script:workspace 'mismatch.nupkg'
    $script:packageId = 'Clc.Deployment.AspNetCore'
    $script:sourceCommit = '0123456789abcdef0123456789abcdef01234567'
    $script:version = '0.1.0-beta.1'

    function New-ReleaseNuGetFixture {
        param([string] $Path,[string] $Version,[string] $Payload,[switch] $RepositorySignature)
        $nuspec = @"
<package xmlns="http://schemas.microsoft.com/packaging/2013/05/nuspec.xsd"><metadata><id>Clc.Deployment.AspNetCore</id><version>$Version</version><license type="expression">MIT</license><repository type="git" url="https://github.com/clcdpc/clc-deployment" commit="$script:sourceCommit" /></metadata></package>
"@
        $entries = @(
            @{ name='Clc.Deployment.AspNetCore.nuspec'; bytes=[Text.Encoding]::UTF8.GetBytes($nuspec) },
            @{ name='lib/net10.0/Clc.Deployment.AspNetCore.dll'; bytes=[Text.Encoding]::UTF8.GetBytes($Payload) }
        )
        if ($RepositorySignature) { $entries += @{ name='.signature.p7s'; bytes=[Text.Encoding]::UTF8.GetBytes('simulated NuGet repository signature') } }
        New-TestZip -Path $Path -Entries $entries
    }

    New-ReleaseNuGetFixture -Path $script:packagePath -Version $script:version -Payload 'package payload bytes'
    New-ReleaseNuGetFixture -Path $script:signedPackagePath -Version $script:version -Payload 'package payload bytes' -RepositorySignature
    New-ReleaseNuGetFixture -Path $script:mismatchPackagePath -Version $script:version -Payload 'different package payload' -RepositorySignature
}

AfterEach {
    Remove-TestWorkspace -Path $script:workspace
}

Context 'Signing-aware package verification' {
    It 'accepts an unsigned local package after NuGet adds its repository signature for a prerelease version' {
        $published = [IO.File]::ReadAllBytes($script:signedPackagePath)
        Test-SharedReleaseNuGetPackage -ExpectedPackagePath $script:packagePath -PublishedPackageBytes $published -ExpectedPackageId $script:packageId -ExpectedVersion $script:version -ExpectedSourceCommit $script:sourceCommit | Should -BeTrue
    }

    It 'accepts a stable version with the same package contents and a repository signature' {
        $stableVersion = '1.2.3'
        $stablePath = Join-Path $script:workspace 'stable.nupkg'
        $stableSignedPath = Join-Path $script:workspace 'stable-signed.nupkg'
        New-ReleaseNuGetFixture -Path $stablePath -Version $stableVersion -Payload 'stable package contents'
        New-ReleaseNuGetFixture -Path $stableSignedPath -Version $stableVersion -Payload 'stable package contents' -RepositorySignature
        $published = [IO.File]::ReadAllBytes($stableSignedPath)
        Test-SharedReleaseNuGetPackage -ExpectedPackagePath $stablePath -PublishedPackageBytes $published -ExpectedPackageId $script:packageId -ExpectedVersion $stableVersion -ExpectedSourceCommit $script:sourceCommit | Should -BeTrue
    }

    It 'rejects a real package content difference' {
        $published = [IO.File]::ReadAllBytes($script:mismatchPackagePath)
        Test-SharedReleaseNuGetPackage -ExpectedPackagePath $script:packagePath -PublishedPackageBytes $published -ExpectedPackageId $script:packageId -ExpectedVersion $script:version -ExpectedSourceCommit $script:sourceCommit | Should -BeFalse
    }

    It 'rejects a different package identity even when the payload is the same' {
        $otherIdentityPath = Join-Path $script:workspace 'other-version.nupkg'
        New-ReleaseNuGetFixture -Path $otherIdentityPath -Version '0.1.0-beta.2' -Payload 'package payload bytes' -RepositorySignature
        $published = [IO.File]::ReadAllBytes($otherIdentityPath)
        Test-SharedReleaseNuGetPackage -ExpectedPackagePath $script:packagePath -PublishedPackageBytes $published -ExpectedPackageId $script:packageId -ExpectedVersion $script:version -ExpectedSourceCommit $script:sourceCommit | Should -BeFalse
    }
}

Context 'NuGet publish and retry behavior' {
    It 'returns after an accepted submission without waiting for NuGet processing' {
        $script:pushCount = 0
        $script:publishedPackage = [IO.File]::ReadAllBytes($script:signedPackagePath)
        $handler = [ClcReleaseTests.RecordingHandler]::new()
        $handler.Enqueue(404,$null,[byte[]]::new(0))
        $client = New-SharedReleaseHttpClient -Handler $handler
        $pushPackage = { param($Path,$ApiKey,$DotnetPath) $script:pushCount++; return 0 }
        try {
            $result = Invoke-SharedReleaseNuGetPublication -PackagePath $script:packagePath -PackageId $script:packageId -Version $script:version -SourceCommit $script:sourceCommit -NuGetClient $client -PushPackage $pushPackage -ApiKey 'fixture-key' -DotnetPath 'fixture-dotnet'

            $result | Should -BeExactly 'submitted-processing'
            $script:pushCount | Should -Be 1
            $handler.RequestUris.Count | Should -Be 1
            $handler.RequestUris[0] | Should -BeExactly 'https://api.nuget.org/v3-flatcontainer/clc.deployment.aspnetcore/0.1.0-beta.1/clc.deployment.aspnetcore.0.1.0-beta.1.nupkg'
            $handler.AuthorizationValues[0] | Should -BeNullOrEmpty
        } finally { $client.Dispose(); $handler.Dispose() }
    }

    It 'treats an already-published matching version as an idempotent retry without pushing again' {
        $script:pushCount = 0
        $script:publishedPackage = [IO.File]::ReadAllBytes($script:signedPackagePath)
        $handler = [ClcReleaseTests.RecordingHandler]::new()
        $handler.Enqueue(200,$null,$script:publishedPackage)
        $client = New-SharedReleaseHttpClient -Handler $handler
        $pushPackage = { param($Path,$ApiKey,$DotnetPath) $script:pushCount++; return 0 }
        try {
            $result = Invoke-SharedReleaseNuGetPublication -PackagePath $script:packagePath -PackageId $script:packageId -Version $script:version -SourceCommit $script:sourceCommit -NuGetClient $client -PushPackage $pushPackage -ApiKey 'fixture-key' -DotnetPath 'fixture-dotnet'

            $result | Should -BeExactly 'already-published-identical'
            $script:pushCount | Should -Be 0
            $handler.RequestUris.Count | Should -Be 1
            $handler.AuthorizationValues[0] | Should -BeNullOrEmpty
        } finally { $client.Dispose(); $handler.Dispose() }
    }

    It 'rejects a conflicting already-published version without trying to overwrite it' {
        $script:pushCount = 0
        $script:publishedPackage = [IO.File]::ReadAllBytes($script:mismatchPackagePath)
        $handler = [ClcReleaseTests.RecordingHandler]::new()
        $handler.Enqueue(200,$null,$script:publishedPackage)
        $client = New-SharedReleaseHttpClient -Handler $handler
        $pushPackage = { param($Path,$ApiKey,$DotnetPath) $script:pushCount++; return 0 }
        try {
            {
                Invoke-SharedReleaseNuGetPublication -PackagePath $script:packagePath -PackageId $script:packageId -Version $script:version -SourceCommit $script:sourceCommit -NuGetClient $client -PushPackage $pushPackage -ApiKey 'fixture-key' -DotnetPath 'fixture-dotnet'
            } | Should -Throw '*different identity or package contents*'
            $script:pushCount | Should -Be 0
            $handler.RequestUris.Count | Should -Be 1
            $handler.AuthorizationValues[0] | Should -BeNullOrEmpty
        } finally { $client.Dispose(); $handler.Dispose() }
    }
    It 'does not claim success when a rejected push is still unavailable' {
        $handler = [ClcReleaseTests.RecordingHandler]::new()
        $handler.Enqueue(404,$null,[byte[]]::new(0))
        $handler.Enqueue(404,$null,[byte[]]::new(0))
        $client = New-SharedReleaseHttpClient -Handler $handler
        try {
            { Invoke-SharedReleaseNuGetPublication -PackagePath $script:packagePath -PackageId $script:packageId -Version $script:version -SourceCommit $script:sourceCommit -NuGetClient $client -PushPackage { return 1 } } | Should -Throw '*not downloadable for verification*'
            $handler.RequestUris.Count | Should -Be 2
        } finally { $client.Dispose(); $handler.Dispose() }
    }

    It 'accepts a failed push only when a concurrent publication matches' {
        $handler = [ClcReleaseTests.RecordingHandler]::new()
        $handler.Enqueue(404,$null,[byte[]]::new(0))
        $handler.Enqueue(200,$null,[IO.File]::ReadAllBytes($script:signedPackagePath))
        $client = New-SharedReleaseHttpClient -Handler $handler
        try {
            Invoke-SharedReleaseNuGetPublication -PackagePath $script:packagePath -PackageId $script:packageId -Version $script:version -SourceCommit $script:sourceCommit -NuGetClient $client -PushPackage { return 1 } | Should -BeExactly 'already-published-identical'
        } finally { $client.Dispose(); $handler.Dispose() }
    }

    It 'rejects conflicting contents discovered after a failed push' {
        $handler = [ClcReleaseTests.RecordingHandler]::new()
        $handler.Enqueue(404,$null,[byte[]]::new(0))
        $handler.Enqueue(200,$null,[IO.File]::ReadAllBytes($script:mismatchPackagePath))
        $client = New-SharedReleaseHttpClient -Handler $handler
        try {
            { Invoke-SharedReleaseNuGetPublication -PackagePath $script:packagePath -PackageId $script:packageId -Version $script:version -SourceCommit $script:sourceCommit -NuGetClient $client -PushPackage { return 1 } } | Should -Throw '*different identity or package contents*'
        } finally { $client.Dispose(); $handler.Dispose() }
    }

}

Context 'Draft GitHub release lookup and refresh' {
    It 'finds an existing draft when the tag endpoint returns no release' {
        $script:paths=[Collections.Generic.List[string]]::new()
        $getJson={
            param($Path)
            $script:paths.Add($Path)
            if ($Path.Contains('/tags/')) { return $null }
            return @(@{id=42L;tag_name='v0.1.0-beta.1';draft=$true})
        }
        $release=Get-SharedReleaseByTag -Repository 'clcdpc/clc-deployment' -Tag 'v0.1.0-beta.1' -GetJson $getJson
        $release.id | Should -Be 42
        $release.draft | Should -BeTrue
        $script:paths.Count | Should -Be 2
        $script:paths[1] | Should -BeExactly '/repos/clcdpc/clc-deployment/releases?per_page=100&page=1'
    }
    It 'refreshes a newly created draft by ID after an asset upload' {
        $getJson={
            param($Path)
            if ($Path -cne '/repos/clcdpc/clc-deployment/releases/42') { throw 'Draft must be refreshed by ID, not hidden tag endpoint.' }
            return @{id=42L;tag_name='v0.1.0-beta.1';draft=$true;assets=@(@{name='release-manifest.json'})}
        }
        $release=Get-SharedReleaseById -Repository 'clcdpc/clc-deployment' -ReleaseId 42 -GetJson $getJson
        $release.assets[0].name | Should -BeExactly 'release-manifest.json'
        $release.draft | Should -BeTrue
    }
    It 'uses the published release directly without listing drafts' {
        $getJson={
            param($Path)
            if (-not $Path.Contains('/tags/')) { throw 'Unexpected collection lookup.' }
            return @{id=42L;tag_name='v0.1.0-beta.1';draft=$false}
        }
        (Get-SharedReleaseByTag -Repository 'clcdpc/clc-deployment' -Tag 'v0.1.0-beta.1' -GetJson $getJson).draft | Should -BeFalse
    }
    It 'returns absent only after checking the draft collection' {
        $getJson={ param($Path) if ($Path.Contains('/tags/')) { return $null }; return @(@{tag_name='v9.0.0';id=9L;draft=$true}) }
        Get-SharedReleaseByTag -Repository 'clcdpc/clc-deployment' -Tag 'v0.1.0-beta.1' -GetJson $getJson | Should -BeNullOrEmpty
    }
    It 'continues collection lookup past a full unrelated page' {
        $getJson={
            param($Path)
            if ($Path.Contains('/tags/')) { return $null }
            if ($Path.EndsWith('page=1')) { return @(1..100 | ForEach-Object { @{id=$_;tag_name=('v9.0.'+$_);draft=$true} }) }
            return @(@{id=142L;tag_name='v0.1.0-beta.1';draft=$true})
        }
        (Get-SharedReleaseByTag -Repository 'clcdpc/clc-deployment' -Tag 'v0.1.0-beta.1' -GetJson $getJson).id | Should -Be 142
    }
}

Context 'HTTP credential boundaries' {
    It 'sends the GitHub token to the API request and omits it from an approved asset redirect' {
        $handler = [ClcReleaseTests.RecordingHandler]::new()
        $handler.Enqueue(302,'https://release-assets.githubusercontent.com/release/asset',[byte[]]::new(0))
        $handler.Enqueue(200,$null,[byte[]]::new(0))
        $client = New-SharedReleaseHttpClient -Handler $handler
        try {
            $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get,'https://api.github.com/repos/clcdpc/clc-deployment/releases/assets/42')
            $response = Send-SharedReleaseHttpRequest -Client $client -Request $request -GitHubToken 'github-fixture-token' -GitHubAuthorization -AllowedRedirectHosts @('api.github.com','release-assets.githubusercontent.com')
            $response.Dispose()

            $handler.RequestUris.Count | Should -Be 2
            $handler.RequestUris[0] | Should -BeExactly 'https://api.github.com/repos/clcdpc/clc-deployment/releases/assets/42'
            $handler.AuthorizationValues[0] | Should -BeExactly 'Bearer github-fixture-token'
            $handler.RequestUris[1] | Should -BeExactly 'https://release-assets.githubusercontent.com/release/asset'
            $handler.AuthorizationValues[1] | Should -BeNullOrEmpty
        } finally { $client.Dispose(); $handler.Dispose() }
    }

    It 'sends no GitHub token to NuGet or its CDN redirect' {
        $handler = [ClcReleaseTests.RecordingHandler]::new()
        $handler.Enqueue(302,'https://globalcdn.nuget.org/packages/package.nupkg',[byte[]]::new(0))
        $handler.Enqueue(200,$null,[byte[]]::new(0))
        $client = New-SharedReleaseHttpClient -Handler $handler
        try {
            $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get,'https://api.nuget.org/v3-flatcontainer/example/1.0.0/example.1.0.0.nupkg')
            $response = Send-SharedReleaseHttpRequest -Client $client -Request $request -AllowedRedirectHosts @('api.nuget.org','globalcdn.nuget.org')
            $response.Dispose()

            $handler.RequestUris.Count | Should -Be 2
            $handler.AuthorizationValues[0] | Should -BeNullOrEmpty
            $handler.RequestUris[1] | Should -BeExactly 'https://globalcdn.nuget.org/packages/package.nupkg'
            $handler.AuthorizationValues[1] | Should -BeNullOrEmpty
        } finally { $client.Dispose(); $handler.Dispose() }
    }

    It 'blocks a GitHub API redirect to NuGet before sending any redirected request' {
        $handler = [ClcReleaseTests.RecordingHandler]::new()
        $handler.Enqueue(302,'https://api.nuget.org/v3-flatcontainer/private/package.nupkg',[byte[]]::new(0))
        $client = New-SharedReleaseHttpClient -Handler $handler
        try {
            $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get,'https://api.github.com/repos/clcdpc/clc-deployment/releases/assets/42')
            { Send-SharedReleaseHttpRequest -Client $client -Request $request -GitHubToken 'github-fixture-token' -GitHubAuthorization -AllowedRedirectHosts @('api.github.com','release-assets.githubusercontent.com') } | Should -Throw '*redirect destination is not allowlisted*'
            $handler.RequestUris.Count | Should -Be 1
            $handler.AuthorizationValues[0] | Should -BeExactly 'Bearer github-fixture-token'
        } finally { $client.Dispose(); $handler.Dispose() }
    }

    It 'refuses to attach GitHub authorization to an unrelated initial host' {
        $handler = [ClcReleaseTests.RecordingHandler]::new()
        $client = New-SharedReleaseHttpClient -Handler $handler
        try {
            $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get,'https://api.nuget.org/v3/index.json')
            { Send-SharedReleaseHttpRequest -Client $client -Request $request -GitHubToken 'github-fixture-token' -GitHubAuthorization -AllowedRedirectHosts @('api.nuget.org') } | Should -Throw '*GitHub authorization is restricted*'
            $handler.RequestUris.Count | Should -Be 0
        } finally { $client.Dispose(); $handler.Dispose() }
    }
}
}

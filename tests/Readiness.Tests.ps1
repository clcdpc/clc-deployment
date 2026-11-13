BeforeAll { . "$PSScriptRoot/Support.ps1"; . "$PSScriptRoot/T2Support.ps1" }
Describe 'Strict readiness protocol and actual HTTP response processing' {
    BeforeEach {
        $ready=Get-Content -LiteralPath (Join-Path $script:FixtureRoot 'readiness.json') -Raw | ConvertFrom-Json -AsHashtable -DateKind String
        $manifest=@{applicationId=$ready.applicationId;releaseId=$ready.releaseId;source=@{commit=$ready.sourceCommit}}
        $configuration=@{runtimeEnvironment=$ready.runtimeEnvironment;revision=$ready.configurationRevision}
    }
    It 'accepts only the exact approved release, source, environment and configuration identity' {
        $bytes=[Text.Encoding]::UTF8.GetBytes(($ready | ConvertTo-Json -Compress))
        Invoke-T2Private Test-ClcReadinessIdentity @($bytes,$manifest,$configuration) | Should -BeTrue
    }
    It 'rejects incorrect <Field> in a generic HTTP 200 body' -ForEach @(
        @{Field='applicationId';Value='wrong'},@{Field='releaseId';Value='wrong'},@{Field='sourceCommit';Value=('f'*40)},
        @{Field='runtimeEnvironment';Value='Staging'},@{Field='configurationRevision';Value='wrong'},@{Field='status';Value='starting'},
        @{Field='readinessContractVersion';Value=2L}
    ) {
        $ready[$Field]=$Value
        Invoke-T2Private Test-ClcReadinessIdentity @([Text.Encoding]::UTF8.GetBytes(($ready | ConvertTo-Json -Compress)),$manifest,$configuration) | Should -BeFalse
    }
    It 'rejects <Case> JSON' -ForEach @(@{Case='missing'},@{Case='extra'},@{Case='duplicate'},@{Case='malformed'},@{Case='oversized'},@{Case='html'}) {
        $json=$ready | ConvertTo-Json -Compress
        switch ($Case) {
            missing { $ready.Remove('status'); $json=$ready | ConvertTo-Json -Compress }
            extra { $ready.private='private-response-sentinel'; $json=$ready | ConvertTo-Json -Compress }
            duplicate { $json=$json.Replace('{','{"status":"ready",') }
            malformed { $json='{' }
            oversized { $json=' '*4097 }
            html { $json='<html>OK</html>' }
        }
        Invoke-T2Private Test-ClcReadinessIdentity @([Text.Encoding]::UTF8.GetBytes($json),$manifest,$configuration) | Should -BeFalse
    }
    It 'uses a transport with certificate verification, no redirect, cookie, credentials or proxy forwarding' {
        $handler=[Clc.Lifecycle.Native]::ReadinessHandler()
        try {
            $handler.AllowAutoRedirect | Should -BeFalse; $handler.UseCookies | Should -BeFalse; $handler.UseProxy | Should -BeFalse
            $handler.UseDefaultCredentials | Should -BeFalse; $handler.PreAuthenticate | Should -BeFalse
            $handler.Credentials | Should -BeNullOrEmpty; $handler.ServerCertificateCustomValidationCallback | Should -BeNullOrEmpty
            $handler.CheckCertificateRevocationList | Should -BeTrue
        } finally { $handler.Dispose() }
    }
    It 'rejects an HTTP response with <Case> before accepting a body' -ForEach @(
        @{Case='503'},@{Case='redirect'},@{Case='challenge'},@{Case='cookie'},@{Case='html'},@{Case='charset'},@{Case='parameter'},
        @{Case='cache'},@{Case='age'},@{Case='oversized'}
    ) {
        $response=[Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::OK)
        try {
            $response.Content=[Net.Http.StringContent]::new(($ready | ConvertTo-Json -Compress),[Text.Encoding]::UTF8,'application/json')
            $response.Headers.CacheControl=[Net.Http.Headers.CacheControlHeaderValue]::new(); $response.Headers.CacheControl.NoStore=$true
            switch ($Case) {
                '503' { $response.StatusCode=[Net.HttpStatusCode]::ServiceUnavailable }
                redirect { $response.StatusCode=[Net.HttpStatusCode]::Redirect; $response.Headers.Location=[Uri]'https://synthetic.invalid/health/ready' }
                challenge { $response.Headers.WwwAuthenticate.Add([Net.Http.Headers.AuthenticationHeaderValue]::new('Negotiate')) }
                cookie { $null=$response.Headers.TryAddWithoutValidation('Set-Cookie','synthetic=secret') }
                html { $response.Content.Headers.ContentType.MediaType='text/html' }
                charset { $response.Content.Headers.ContentType.CharSet='utf-16' }
                parameter { $response.Content.Headers.ContentType.Parameters.Add([Net.Http.Headers.NameValueHeaderValue]::new('unknown','value')) }
                cache { $response.Headers.CacheControl.NoStore=$false }
                age { $response.Headers.Age=[TimeSpan]::FromSeconds(1) }
                oversized { $response.Content=[Net.Http.ByteArrayContent]::new([byte[]]::new(4097)); $response.Content.Headers.ContentType=[Net.Http.Headers.MediaTypeHeaderValue]::new('application/json') }
            }
            [Clc.Lifecycle.Native]::HealthResponse($response,[Threading.CancellationToken]::None).Accepted | Should -BeFalse
        } finally { $response.Dispose() }
    }
    It 'reads the bounded actual HTTP body and passes it to strict identity validation' {
        $response=[Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::OK)
        try {
            $response.Content=[Net.Http.StringContent]::new(($ready | ConvertTo-Json -Compress),[Text.Encoding]::UTF8,'application/json')
            $response.Headers.CacheControl=[Net.Http.Headers.CacheControlHeaderValue]::new(); $response.Headers.CacheControl.NoStore=$true
            $actual=[Clc.Lifecycle.Native]::HealthResponse($response,[Threading.CancellationToken]::None)
            $actual.Accepted | Should -BeTrue
            Invoke-T2Private Test-ClcReadinessIdentity @($actual.Bytes,$manifest,$configuration) | Should -BeTrue
        } finally { $response.Dispose() }
    }
}

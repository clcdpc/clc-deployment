BeforeAll {
    . "$PSScriptRoot/Fixtures/ReleaseHttp.ps1"
    . "$PSScriptRoot/../tools/release/Release.Common.ps1"
    $script:repository = 'example/portal'
    $script:branchPath = '/repos/example/portal/branches/master'
}

Describe 'Application release GitHub REST responses' {
    BeforeEach {
        $script:handler = [ClcReleaseTests.RecordingHandler]::new()
        $script:previousToken = $env:GH_TOKEN
        $env:GH_TOKEN = 'fixture-token'
        Mock New-SharedReleaseHttpClient { [Net.Http.HttpClient]::new($script:handler, $false) }
    }

    AfterEach {
        $env:GH_TOKEN = $script:previousToken
        $script:handler.Dispose()
    }

    It 'parses a successful JSON GET and preserves timestamp strings' {
        $body = [Text.Encoding]::UTF8.GetBytes('{"protected":true,"created_at":"2026-11-13T00:00:00Z"}')
        $script:handler.Enqueue(200, $null, $body)
        $result = Invoke-ClcReleaseApi $script:repository GET $script:branchPath
        $result.protected | Should -BeTrue
        $result.created_at | Should -BeOfType ([string])
        $result.created_at | Should -BeExactly '2026-11-13T00:00:00Z'
        $script:handler.AcceptValues[0] | Should -BeExactly 'application/vnd.github+json'
        $script:handler.AuthorizationValues[0] | Should -BeExactly 'Bearer fixture-token'
    }

    It 'returns raw bytes only for the binary request when the same response can also be parsed as JSON' {
        $path = '/repos/example/portal/releases/assets/456'
        $body = [Text.Encoding]::UTF8.GetBytes('{"value":123}')
        $script:handler.Enqueue(200, $null, $body)
        $script:handler.Enqueue(200, $null, $body)
        $binary = Invoke-ClcReleaseApi $script:repository GET $path -Bytes
        $binary.GetType() | Should -Be ([byte[]])
        [Convert]::ToHexString($binary) | Should -BeExactly ([Convert]::ToHexString($body))
        (Invoke-ClcReleaseApi $script:repository GET $path -Bytes:$false).value | Should -Be 123
        ($script:handler.AcceptValues -join ',') | Should -BeExactly 'application/octet-stream,application/vnd.github+json'
    }

    It 'returns a single byte array for the <Case> binary response' -ForEach @(
        @{Case='non-UTF-8'; Body=[byte[]]@(255,0,128)}, @{Case='empty'; Body=[byte[]]::new(0)}
    ) {
        $script:handler.Enqueue(200, $null, $Body)
        $result = Invoke-ClcReleaseApi $script:repository GET '/repos/example/portal/actions/artifacts/456/zip' -Bytes
        $result.GetType() | Should -Be ([byte[]])
        [Convert]::ToHexString($result) | Should -BeExactly ([Convert]::ToHexString($Body))
    }

    It 'rejects a declared length beyond the <Mode> limit' -ForEach @(
        @{Mode='JSON'; Binary=$false; Length=4194305L}, @{Mode='binary'; Binary=$true; Length=1073741825L}
    ) {
        $content = [Net.Http.ByteArrayContent]::new([byte[]]::new(0))
        $content.Headers.ContentLength = $Length
        $script:handler.EnqueueContent(200, $null, $content)
        { Invoke-ClcReleaseApi $script:repository GET $script:branchPath -Bytes:$Binary } | Should -Throw '*exceeds its byte bound*'
    }

    It 'enforces the JSON byte limit while reading even when the declared length is smaller' {
        $content = [Net.Http.ByteArrayContent]::new([byte[]]::new(4194305))
        $content.Headers.ContentLength = 1
        $script:handler.EnqueueContent(200, $null, $content)
        { Invoke-ClcReleaseApi $script:repository GET $script:branchPath } | Should -Throw '*exceeds its byte bound*'
    }

    It 'returns null for a missing resource' {
        $script:handler.Enqueue(404, $null, [byte[]]::new(0))
        $result = Invoke-ClcReleaseApi $script:repository GET $script:branchPath
        ($null -eq $result) | Should -BeTrue
    }

    It 'rejects HTTP <Status> without exposing the response body' -ForEach @(
        @{Status=401}, @{Status=403}, @{Status=429}, @{Status=500}
    ) {
        $script:handler.Enqueue($Status, $null, [Text.Encoding]::UTF8.GetBytes('response-body-sentinel'))
        { Invoke-ClcReleaseApi $script:repository GET $script:branchPath } | Should -Throw "GitHub request refused; status $Status."
    }

    It 'rejects malformed JSON after a successful status' {
        $script:handler.Enqueue(200, $null, [Text.Encoding]::UTF8.GetBytes('{"unclosed":'))
        { Invoke-ClcReleaseApi $script:repository GET $script:branchPath } | Should -Throw '*Conversion from JSON failed*'
    }

    It 'rejects invalid UTF-8 in a JSON response' {
        $script:handler.Enqueue(200, $null, [byte[]]@(255))
        { Invoke-ClcReleaseApi $script:repository GET $script:branchPath } | Should -Throw '*GetString*'
    }

    It 'refuses to send without a GitHub token' {
        $env:GH_TOKEN = $null
        { Invoke-ClcReleaseApi $script:repository GET $script:branchPath } | Should -Throw '*authorization token is unavailable*'
        $script:handler.RequestUris.Count | Should -Be 0
    }

    It 'refuses paths outside the selected repository before sending' {
        { Invoke-ClcReleaseApi $script:repository GET '/repos/example/elsewhere/branches/master' } | Should -Throw '*outside the selected repository*'
        $script:handler.RequestUris.Count | Should -Be 0
    }
}

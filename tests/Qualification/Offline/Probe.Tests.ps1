BeforeAll {
    . "$PSScriptRoot/../../Support.ps1"
    $script:probeWorkspace=New-TestWorkspace
    $script:probeDotnet=$env:CLC_T4_DOTNET
    if (-not $script:probeDotnet -or -not [IO.File]::Exists($script:probeDotnet)) { throw 'Provision the exact verified .NET SDK and set process-local CLC_T4_DOTNET.' }
    $script:probeSource=(& git -C $script:RepositoryRoot rev-parse HEAD).Trim()
    $script:probePublish1=Join-Path $script:probeWorkspace 'initial'; $script:probePublish2=Join-Path $script:probeWorkspace 'newer'
    $script:probeNegative=Join-Path $script:probeWorkspace 'negative'
    $script:probeConfiguration=Join-Path $script:probeWorkspace 'probe.json'; $script:probeKeys=Join-Path $script:probeWorkspace 'keys'
    $null=[IO.Directory]::CreateDirectory($script:probeKeys)
    function Write-ProbeConfiguration([string] $Revision='probe-001',[string] $Compatibility='clc-probe-dpapi-user-v1') {
        Write-TestJson $script:probeConfiguration @{configurationRevision=$Revision;keyStoreCompatibilityId=$Compatibility;syntheticSecret='CLC_SYNTHETIC_SECRET_SENTINEL_T4'}
    }
    Write-ProbeConfiguration
    $project=Join-Path $script:RepositoryRoot 'tests/Qualification/ProbeApp/ProbeApp.csproj'
    $env:DOTNET_GENERATE_ASPNET_CERTIFICATE='false'; $env:DOTNET_CLI_TELEMETRY_OPTOUT='1'; $env:DOTNET_NOLOGO='1'
    foreach ($build in @(@{root=$script:probePublish1;id='probe-contract-initial'},@{root=$script:probePublish2;id='probe-contract-newer'})) {
        & $script:probeDotnet publish $project -c Release -p:RestoreLockedMode=true --self-contained false -r win-x64 -o $build.root ('-p:ProbeReleaseId='+$build.id) ('-p:ProbeSourceCommit='+$script:probeSource) | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Actual probe build failed.' }
    }
    & $script:probeDotnet publish (Join-Path $script:RepositoryRoot 'tests/Qualification/FailureApp/FailureApp.csproj') -c Release -p:RestoreLockedMode=true -o $script:probeNegative -p:ProbeReleaseId=probe-contract-negative ('-p:ProbeSourceCommit='+$script:probeSource) -p:ProbeFailureKind=WrongRelease | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Separate negative fixture build failed.' }
    function Start-ProbeProcess([string] $PublishRoot,[string[]] $InputArguments=@(),[int] $Port=0) {
        $info=[Diagnostics.ProcessStartInfo]::new($script:probeDotnet); $info.UseShellExecute=$false; $info.CreateNoWindow=$true
        $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true; $info.Environment.Clear(); $info.Environment['SystemRoot']=[Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
        $info.ArgumentList.Add((Join-Path $PublishRoot 'ClcQualificationProbe.dll'))
        foreach ($argument in $InputArguments) { $info.ArgumentList.Add($argument) }
        if ($Port) {
            $info.Environment['ASPNETCORE_ENVIRONMENT']='Production'; $info.Environment['CLC_PROBE_CONFIGURATION_PATH']=$script:probeConfiguration
            $info.Environment['CLC_PROBE_DATA_PROTECTION_ROOT']=$script:probeKeys; $info.Environment['CLC_PROBE_LOOPBACK_URL']='http://127.0.0.1:'+$Port
        }
        $process=[Diagnostics.Process]::Start($info)
        @{process=$process;creationFiletime=$process.StartTime.ToUniversalTime().ToFileTimeUtc();output=$process.StandardOutput.ReadToEndAsync();errors=$process.StandardError.ReadToEndAsync()}
    }
    function Stop-ProbeProcess($Running) {
        if ($Running.process.StartTime.ToUniversalTime().ToFileTimeUtc() -ne $Running.creationFiletime) { throw 'Probe cleanup process identity mismatch.' }
        if (-not $Running.process.HasExited) { $Running.process.Kill(); if (-not $Running.process.WaitForExit(10000)) { throw 'Probe exit is unknown.' } }
        $Running.process.Dispose()
    }
    function Invoke-ProbeValidation([string] $PublishRoot=$script:probePublish1,[string] $Environment='Production',[string[]] $OverrideArguments=@()) {
        $arguments=@('--validate-deployment','--configuration-path',$script:probeConfiguration,'--data-protection-root',$script:probeKeys,'--environment',$Environment)
        if ($OverrideArguments.Count) { $arguments=$OverrideArguments }
        $running=Start-ProbeProcess $PublishRoot $arguments
        try {
            if (-not $running.process.WaitForExit(10000)) { throw 'Probe validator exceeded the offline bound.' }
            $text=$running.output.GetAwaiter().GetResult(); $stderr=$running.errors.GetAwaiter().GetResult()
            $text.Length | Should -BeLessThan 8193; $stderr | Should -BeExactly ''
            @{record=($text | ConvertFrom-Json -AsHashtable);text=$text;exitCode=$running.process.ExitCode}
        } finally { Stop-ProbeProcess $running }
    }
    function Start-ProbeServer([string] $PublishRoot=$script:probePublish1) {
        $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0); $listener.Start(); $port=$listener.LocalEndpoint.Port; $listener.Stop()
        $running=Start-ProbeProcess $PublishRoot @() $port
        $handler=[Net.Http.HttpClientHandler]::new(); $handler.AllowAutoRedirect=$false; $handler.UseCookies=$false; $handler.UseProxy=$false
        $client=[Net.Http.HttpClient]::new($handler); $client.Timeout=[TimeSpan]::FromSeconds(1); $base='http://127.0.0.1:'+$port
        $clock=[Diagnostics.Stopwatch]::StartNew(); $ready=$false
        while ($clock.Elapsed.TotalSeconds -lt 15 -and -not $running.process.HasExited) {
            try { $response=$client.GetAsync($base+'/health/ready').GetAwaiter().GetResult(); $ready=[int]$response.StatusCode -eq 200; $response.Dispose(); if ($ready) { break } } catch { }
            Start-Sleep -Milliseconds 100
        }
        if (-not $ready) {
            $client.Dispose(); Stop-ProbeProcess $running
            $safeCode=$running.errors.GetAwaiter().GetResult()
            if ($safeCode -cnotmatch '^ProbeStartupFailed:[a-z-]+:[A-Za-z]+Exception$') { $safeCode='NoSafeStartupCode' }
            throw ('Actual loopback probe startup/readiness failed (not IIS qualification): '+$safeCode)
        }
        @{running=$running;client=$client;base=$base}
    }
    function Stop-ProbeServer($Server) { $Server.client.Dispose(); Stop-ProbeProcess $Server.running }
}
AfterAll { if ($script:probeWorkspace) { Remove-TestWorkspace $script:probeWorkspace } }
Describe 'Real probe build and read-only validator contracts (no IIS)' {
    BeforeEach { Write-ProbeConfiguration }
    It 'uses immutable embedded release and source identities in both built releases' {
        $first=Invoke-ProbeValidation; $second=Invoke-ProbeValidation $script:probePublish2
        $first.exitCode | Should -Be 0; $second.exitCode | Should -Be 0
        $first.record.releaseId | Should -BeExactly 'probe-contract-initial'
        $second.record.releaseId | Should -BeExactly 'probe-contract-newer'
        $first.record.sourceCommit | Should -BeExactly $script:probeSource
        $first.record.applicationId | Should -BeExactly 'clc-qualification-probe'
    }
    It 'emits the exact strict toolkit validation shape under Production and Staging' {
        foreach ($environment in @('Production','Staging')) {
            $actual=Invoke-ProbeValidation -Environment $environment
            $record=& (Get-Module CLC.Deployment) { param($bytes) Read-ClcJson $bytes application-validation } ([Text.Encoding]::UTF8.GetBytes($actual.text))
            $record.valid | Should -BeTrue; $record.runtimeEnvironment | Should -BeExactly $environment; $record.errorCodes.Count | Should -Be 0
        }
    }
    It 'makes no scoped file/key changes and exposes no synthetic secret during validation' {
        $before=Get-TestTreeHashes $script:probeWorkspace
        1..3 | ForEach-Object { $actual=Invoke-ProbeValidation; $actual.text | Should -Not -Match 'CLC_SYNTHETIC_SECRET'; $actual.exitCode | Should -Be 0 }
        Get-TestTreeHashes $script:probeWorkspace | Should -BeExactly $before
    }
    It 'shares configuration semantics and recognizes a changed revision' {
        Write-ProbeConfiguration changed-revision
        (Invoke-ProbeValidation).record.configurationRevision | Should -BeExactly 'changed-revision'
        $server=Start-ProbeServer
        try { ($server.client.GetStringAsync($server.base+'/health/ready').GetAwaiter().GetResult() | ConvertFrom-Json).configurationRevision | Should -BeExactly 'changed-revision' }
        finally { Stop-ProbeServer $server }
    }
    It 'rejects unsupported environments, duplicate configuration keys, unknown fields and incompatible keys without secret output' {
        (Invoke-ProbeValidation -Environment Development).exitCode | Should -Be 2
        [IO.File]::WriteAllText($script:probeConfiguration,'{"configurationRevision":"a","ConfigurationRevision":"b","keyStoreCompatibilityId":"clc-probe-dpapi-user-v1","syntheticSecret":"CLC_SYNTHETIC_SECRET_SENTINEL_T4"}')
        $actual=Invoke-ProbeValidation; $actual.exitCode | Should -Be 2; $actual.text | Should -Not -Match 'CLC_SYNTHETIC_SECRET'
        Write-ProbeConfiguration probe-001 incompatible-key-policy
        (Invoke-ProbeValidation).exitCode | Should -Be 2
        Write-ProbeConfiguration
        $config=Get-Content -LiteralPath $script:probeConfiguration -Raw | ConvertFrom-Json -AsHashtable; $config.extra='forbidden'; Write-TestJson $script:probeConfiguration $config
        (Invoke-ProbeValidation).exitCode | Should -Be 2
    }
    It 'rejects additional validator arguments and emits a bounded fixed error' {
        $actual=Invoke-ProbeValidation -OverrideArguments @('--validate-deployment','--unsafe','arbitrary')
        $actual.exitCode | Should -Be 2; $actual.record.errorCodes | Should -Contain 'InvalidConfiguration'
    }
    It 'packages and inspects the actual framework-dependent win-x64 in-process publish tree with New/Test' {
        $metadata=Get-TestMetadata; $metadata.applicationId='clc-qualification-probe'; $metadata.releaseId='probe-contract-initial'; $metadata.source.commit=$script:probeSource
        $metadata.validation.entryPoint='ClcQualificationProbe.dll'; $metadata.build.sdkVersion='10.0.403'
        $inputRoot=Join-Path $script:probeWorkspace 'input'; $outputRoot=Join-Path $script:probeWorkspace 'output'
        $null=[IO.Directory]::CreateDirectory($inputRoot); $null=[IO.Directory]::CreateDirectory($outputRoot)
        $metadataPath=Join-Path $inputRoot 'metadata.json'; Write-TestJson $metadataPath $metadata
        $package=New-ClcRelease -PublishRoot $script:probePublish1 -MetadataPath $metadataPath -OutputPath (Join-Path $outputRoot 'probe.zip')
        $inspection=Test-ClcRelease -ArchivePath $package.archivePath
        $inspection.sourceCommit | Should -BeExactly $script:probeSource; $inspection.authorizedForDeployment | Should -BeFalse
        $entries=Get-TestZipEntries $package.archivePath
        @($entries | Where-Object { $_ -imatch 'probe\.json|key-|\.pfx|\.pem|\.cs$|packages\.lock' }).Count | Should -Be 0
        $inspection.fileCount | Should -BeGreaterThan 3
    }
    It 'keeps negative readiness behavior in a separate immutable fixture with a safe validator' {
        $actual=Invoke-ProbeValidation $script:probeNegative
        $actual.exitCode | Should -Be 0; $actual.record.releaseId | Should -BeExactly 'probe-contract-negative'
        . "$script:RepositoryRoot/tools/Probe.Metadata.ps1"
        $embedded=Get-ProbeEmbeddedMetadata (Join-Path $script:probeNegative 'ClcQualificationProbe.dll')
        $embedded['FailureKind'] | Should -BeExactly 'WrongRelease'
        $server=Start-ProbeServer $script:probeNegative
        try {
            $text=$server.client.GetStringAsync($server.base+'/health/ready').GetAwaiter().GetResult()
            $manifest=@{applicationId='clc-qualification-probe';releaseId='probe-contract-negative';source=@{commit=$script:probeSource}}
            $configuration=@{runtimeEnvironment='Production';revision='probe-001'}
            & (Get-Module CLC.Deployment) { param($bytes,$manifest,$config) Test-ClcReadinessIdentity $bytes $manifest $config } ([Text.Encoding]::UTF8.GetBytes($text)) $manifest $configuration | Should -BeFalse
        } finally { Stop-ProbeServer $server }
    }
}
Describe 'Actual loopback startup/readiness and current-user DPAPI (no IIS or service token claim)' {
    BeforeEach { Write-ProbeConfiguration }
    It 'serves an anonymous exact no-store readiness response without cookies, auth or redirects' {
        $server=Start-ProbeServer
        try {
            $response=$server.client.GetAsync($server.base+'/health/ready').GetAwaiter().GetResult()
            try {
                [int]$response.StatusCode | Should -Be 200; $response.Headers.CacheControl.NoStore | Should -BeTrue
                $response.Headers.Contains('Set-Cookie') | Should -BeFalse; $response.Headers.Contains('WWW-Authenticate') | Should -BeFalse
                $text=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                $record=& (Get-Module CLC.Deployment) { param($bytes) Read-ClcJson $bytes readiness } ([Text.Encoding]::UTF8.GetBytes($text))
                $record.releaseId | Should -BeExactly 'probe-contract-initial'; $text | Should -Not -Match 'CLC_SYNTHETIC_SECRET|C:\\'
            } finally { $response.Dispose() }
        } finally { Stop-ProbeServer $server }
    }
    It 'performs real protect/unprotect across a process restart and a newer built release under the same test user' {
        $first=Start-ProbeServer
        try { $token=$first.client.GetStringAsync($first.base+'/probe/protect').GetAwaiter().GetResult() }
        finally { Stop-ProbeServer $first }
        $second=Start-ProbeServer $script:probePublish2
        try {
            $content=[Net.Http.StringContent]::new($token)
            try { $response=$second.client.PostAsync($second.base+'/probe/unprotect',$content).GetAwaiter().GetResult(); try { [int]$response.StatusCode | Should -Be 200 } finally { $response.Dispose() } } finally { $content.Dispose() }
            $keys=@(Get-ChildItem -LiteralPath $script:probeKeys -Filter key-*.xml -File)
            $keys.Count | Should -BeGreaterThan 0
            foreach ($file in $keys) { [IO.File]::ReadAllText($file.FullName) | Should -Match 'encryptedSecret|Dpapi' }
        } finally { Stop-ProbeServer $second }
    }
}

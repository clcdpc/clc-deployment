BeforeDiscovery { . "$PSScriptRoot/Support.ps1" }
BeforeAll { . "$PSScriptRoot/Support.ps1" }
Describe 'New-ClcRelease safe packaging' {
    BeforeEach { $workspace = New-TestWorkspace; $publishArgs = New-TestPublish $workspace }
    AfterEach { Remove-TestWorkspace $workspace }
    It 'packages and inspects all files without changing inputs or extracting anything' {
        $before = Get-TestTreeHashes $publishArgs.PublishRoot
        $result = New-ClcRelease @publishArgs
        $inspection = Test-ClcRelease $result.archivePath
        $inspection.integrityVerified | Should -BeTrue
        $inspection.authorizedForDeployment | Should -BeFalse
        $inspection.fileCount | Should -Be 4
        $inspection.archiveSha256 | Should -Be ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($publishArgs.OutputPath))).ToLowerInvariant())
        $inspection.inventorySha256 | Should -Be $result.inventorySha256
        $inspection.manifestSha256 | Should -Be $result.manifestSha256
        (Get-TestTreeHashes $publishArgs.PublishRoot) | Should -Be $before
        @(Get-ChildItem -LiteralPath (Split-Path $publishArgs.OutputPath) -Force).Count | Should -Be 1
        @(Get-ChildItem -LiteralPath $workspace -Recurse -Filter 'executed.marker').Count | Should -Be 0
    }
    It 'generates identical bytes with different metadata order and source timestamps' {
        $first = New-ClcRelease @publishArgs
        $metadata = Get-TestMetadata
        $reversed = [ordered]@{}
        $keys = @($metadata.Keys); [Array]::Reverse($keys)
        foreach ($key in $keys) { $reversed[$key] = $metadata[$key] }
        Write-TestJson $publishArgs.MetadataPath $reversed
        [IO.File]::SetLastWriteTimeUtc((Join-Path $publishArgs.PublishRoot 'Probe.dll'),[DateTime]::UtcNow)
        $publishArgs.OutputPath = Join-Path (Split-Path $publishArgs.OutputPath) 'second.zip'
        $second = New-ClcRelease @publishArgs
        $second.archiveSha256 | Should -Be $first.archiveSha256
        $second.manifestSha256 | Should -Be $first.manifestSha256
        $second.inventorySha256 | Should -Be $first.inventorySha256
    }
    It 'preserves existing output and neighboring sentinels' {
        [IO.File]::WriteAllText($publishArgs.OutputPath,'existing-output-sentinel')
        $sentinel = Join-Path (Split-Path $publishArgs.OutputPath) '.clc-build-unowned.tmp'
        [IO.File]::WriteAllText($sentinel,'unowned-sentinel')
        Test-TestRejection { New-ClcRelease @publishArgs } 'Clc.OutputExists*'
        [IO.File]::ReadAllText($publishArgs.OutputPath) | Should -Be 'existing-output-sentinel'
        [IO.File]::ReadAllText($sentinel) | Should -Be 'unowned-sentinel'
    }
    It 'accepts the SDK logging basename only when stdout logging is disabled' {
        $path = Join-Path $publishArgs.PublishRoot 'web.config'
        [IO.File]::WriteAllText($path,(Get-TestWebConfig).Replace('stdoutLogEnabled="false"','stdoutLogEnabled="false" stdoutLogFile=".\logs\stdout"'))
        $null = New-ClcRelease @publishArgs
        [IO.File]::Delete($publishArgs.OutputPath)
        [IO.File]::WriteAllText($path,(Get-TestWebConfig).Replace('stdoutLogEnabled="false"','stdoutLogEnabled="false" stdoutLogFile="C:\private\log"'))
        Test-TestRejection { New-ClcRelease @publishArgs } 'Clc.UnsafeArchive*'
    }
    It 'removes only its owned temporary after a bounded build failure' {
        $sentinel = Join-Path (Split-Path $publishArgs.OutputPath) '.clc-build-unowned.tmp'
        [IO.File]::WriteAllText($sentinel,'unowned-sentinel')
        & (Get-Module CLC.Deployment) { $script:ClcLimits.Compressed = 100 }
        try { Test-TestRejection { New-ClcRelease @publishArgs } } finally { & (Get-Module CLC.Deployment) { $script:ClcLimits.Compressed = 1073741824L } }
        [IO.File]::Exists($publishArgs.OutputPath) | Should -BeFalse
        @(Get-ChildItem -LiteralPath (Split-Path $publishArgs.OutputPath) -Force).Count | Should -Be 1
        [IO.File]::ReadAllText($sentinel) | Should -Be 'unowned-sentinel'
    }
    It 'rejects a builder version inconsistent with the loaded candidate' {
        $metadata = Get-TestMetadata; $metadata.builder.version = '0.1.0'
        Write-TestJson $publishArgs.MetadataPath $metadata
        Test-TestRejection { New-ClcRelease @publishArgs } 'Clc.InvalidContract*'
        [IO.File]::Exists($publishArgs.OutputPath) | Should -BeFalse
    }
    It 'rejects unsafe ANCM XML <Label> before output' -ForEach @(
        @{ Label='DTD'; Xml='<!DOCTYPE configuration [<!ENTITY x SYSTEM "file:///C:/missing">]><configuration>&x;</configuration>' },
        @{ Label='external entity'; Xml='<!DOCTYPE configuration SYSTEM "https://synthetic.invalid/remote"><configuration />' },
        @{ Label='launch arguments'; Xml=(Get-TestWebConfig).Replace('.\Probe.dll','.\Probe.dll --execute') },
        @{ Label='credentials'; Xml=(Get-TestWebConfig).Replace('hostingModel="inprocess"','hostingModel="inprocess" password="synthetic-sentinel"') },
        @{ Label='environment'; Xml=(Get-TestWebConfig).Replace(' /></system.webServer>','><environmentVariables><environmentVariable name="ASPNETCORE_ENVIRONMENT" value="Development" /></environmentVariables></aspNetCore></system.webServer>') },
        @{ Label='out of process'; Xml=(Get-TestWebConfig).Replace('inprocess','outofprocess') },
        @{ Label='logging'; Xml=(Get-TestWebConfig).Replace('stdoutLogEnabled="false"','stdoutLogEnabled="true"') }
    ) {
        [IO.File]::WriteAllText((Join-Path $publishArgs.PublishRoot 'web.config'),$Xml)
        Test-TestRejection { New-ClcRelease @publishArgs } 'Clc.UnsafeArchive*'
        [IO.File]::Exists($publishArgs.OutputPath) | Should -BeFalse
    }
    It 'rejects prohibited publish content <Name> without executing it' -ForEach @(
        @{Name='launchSettings.json'},@{Name='appsettings.Development.json'},@{Name='appsettings.Testing.json'},
        @{Name='operational-config.json'},@{Name='certificate.pfx'},@{Name='private.key'},@{Name='private.SNK'},@{Name='adapter.ps1'},@{Name='deploy.cmd'},@{Name='.clc-owned.tmp'}
    ) {
        $path = Join-Path $publishArgs.PublishRoot $Name
        [IO.File]::WriteAllText($path,'Set-Content executed.marker secret-sentinel')
        $before = Get-TestTreeHashes $publishArgs.PublishRoot
        Test-TestRejection { New-ClcRelease @publishArgs }
        (Get-TestTreeHashes $publishArgs.PublishRoot) | Should -Be $before
        [IO.File]::Exists($publishArgs.OutputPath) | Should -BeFalse
        [IO.File]::Exists((Join-Path $workspace 'executed.marker')) | Should -BeFalse
    }
    It 'rejects missing DLL and a runtimeconfig framework mismatch' {
        [IO.File]::Delete((Join-Path $publishArgs.PublishRoot 'Probe.dll'))
        Test-TestRejection { New-ClcRelease @publishArgs }
        [IO.File]::WriteAllText((Join-Path $publishArgs.PublishRoot 'Probe.dll'),'fixture')
        [IO.File]::WriteAllText((Join-Path $publishArgs.PublishRoot 'Probe.runtimeconfig.json'),'{"runtimeOptions":{"tfm":"net9.0","framework":{"name":"Microsoft.AspNetCore.App","version":"9.0.0"}}}')
        Test-TestRejection { New-ClcRelease @publishArgs }
        [IO.File]::Exists($publishArgs.OutputPath) | Should -BeFalse
    }
    It 'rejects newly added source files at final observation and deletes its exact owned output' {
        $before = Get-TestTreeHashes $publishArgs.PublishRoot
        $script:TestInventoryCalls=0
        $script:TestOriginalInventory = & (Get-Module CLC.Deployment) { (Get-Command Get-ClcPublishInventory).ScriptBlock }
        Mock Get-ClcPublishInventory -ModuleName CLC.Deployment {
            param($Root,$Handles,$Clock)
            $script:TestInventoryCalls++
            if ($script:TestInventoryCalls -eq 3) { [IO.File]::WriteAllText((Join-Path $Root.CanonicalPath 'added.txt'),'source-race-sentinel') }
            & $script:TestOriginalInventory $Root $Handles $Clock
        }
        Test-TestRejection { New-ClcRelease @publishArgs } 'Clc.ContentDrift*'
        [IO.File]::Exists($publishArgs.OutputPath) | Should -BeFalse
        @(Get-ChildItem -LiteralPath (Split-Path $publishArgs.OutputPath) -Force).Count | Should -Be 0
        [IO.File]::ReadAllText((Join-Path $publishArgs.PublishRoot 'added.txt')) | Should -Be 'source-race-sentinel'
        [IO.File]::Delete((Join-Path $publishArgs.PublishRoot 'added.txt'))
        (Get-TestTreeHashes $publishArgs.PublishRoot) | Should -Be $before
    }
    It 'preserves a competing output created at the publication boundary' {
        $expectedOutput = $publishArgs.OutputPath
        $script:TestExpectedOutput = $expectedOutput
        $script:TestOriginalInspection = & (Get-Module CLC.Deployment) { (Get-Command Test-ClcArchiveStream).ScriptBlock }
        Mock Test-ClcArchiveStream -ModuleName CLC.Deployment {
            param($Stream,$Clock)
            $result = & $script:TestOriginalInspection $Stream $Clock
            [IO.File]::WriteAllText($script:TestExpectedOutput,'competing-output-sentinel')
            return $result
        }
        Test-TestRejection { New-ClcRelease @publishArgs } 'Clc.OutputExists*'
        [IO.File]::ReadAllText($expectedOutput) | Should -Be 'competing-output-sentinel'
        @(Get-ChildItem -LiteralPath (Split-Path $expectedOutput) -Force).Count | Should -Be 1
    }
}

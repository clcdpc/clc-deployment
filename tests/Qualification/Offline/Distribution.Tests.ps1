BeforeAll {
    . "$PSScriptRoot/../../Support.ps1"
    . "$script:RepositoryRoot/tools/Distribution.Common.ps1"
    $script:DistributionBuilder=Join-Path $script:RepositoryRoot 'tools/New-ToolkitDistribution.ps1'
    $script:DistributionVerifier=Join-Path $script:RepositoryRoot 'tools/Test-ToolkitDistribution.ps1'
    function Set-DistributionFixtureVersion([string] $ModuleRoot,[string] $Version) {
        Assert-DistVersion $Version
        $dash=$Version.IndexOf('-')
        $base=if ($dash -ge 0) {$Version.Substring(0,$dash)} else {$Version}
        $prerelease=if ($dash -ge 0) {$Version.Substring($dash+1)} else {$null}
        $manifestPath=Join-Path $ModuleRoot 'CLC.Deployment.psd1'
        $text=[IO.File]::ReadAllText($manifestPath)
        $moduleVersionPattern=[regex]::new("(?m)(^\s*ModuleVersion\s*=\s*)'[^']+'")
        if (-not $moduleVersionPattern.IsMatch($text)) { throw 'Fixture module version declaration is missing.' }
        $text=$moduleVersionPattern.Replace($text,('$1'''+$base+''''),1)
        if ($null -ne $prerelease) {
            $prereleasePattern=[regex]::new("\bPrerelease\s*=\s*'[^']*'")
            if ($prereleasePattern.IsMatch($text)) { $text=$prereleasePattern.Replace($text,("Prerelease = '$prerelease'"),1) }
            else {
                $replacement=[string]::Concat("    PrivateData = @{ PSData = @{ Prerelease = '$prerelease' } }",[Environment]::NewLine,'}')
                $text=[regex]::Replace($text,'(?m)^}\s*$',$replacement,1)
            }
        } else {
            $text=[regex]::Replace($text,'(?m)^\s*PrivateData\s*=.*(?:\r?\n|$)','')
        }
        [IO.File]::WriteAllText($manifestPath,$text,[Text.UTF8Encoding]::new($false))
    }
    function New-DistributionFixture([string] $Version) {
        if (-not $Version) { $Version=Get-DistVersionFromBytes ([IO.File]::ReadAllBytes((Join-Path $script:RepositoryRoot 'VERSION'))) }
        $workspace=New-TestWorkspace; $repository=Join-Path $workspace 'repo'; $null=[IO.Directory]::CreateDirectory((Join-Path $repository 'src'))
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'src/CLC.Deployment') -Destination (Join-Path $repository 'src') -Recurse
        Set-DistributionFixtureVersion (Join-Path $repository 'src/CLC.Deployment') $Version
        [IO.File]::WriteAllText((Join-Path $repository 'VERSION'),$Version,[Text.UTF8Encoding]::new($false))
        $null=Get-DistGit $repository @('init','--initial-branch=codex/fixture')
        $null=Get-DistGit $repository @('config','user.name','CLC Qualification Fixture')
        $null=Get-DistGit $repository @('config','user.email','qualification@example.invalid')
        $null=Get-DistGit $repository @('config','core.autocrlf','false')
        $null=Get-DistGit $repository @('add','src','VERSION'); $null=Get-DistGit $repository @('commit','-m','Synthetic immutable distribution fixture')
        $commit=Get-DistGit $repository @('rev-parse','HEAD'); $archive=Join-Path $workspace 'candidate.zip'
        $identity=& $script:DistributionBuilder -RepositoryRoot $repository -SourceCommit $commit -OutputPath $archive
        @{workspace=$workspace;repository=$repository;commit=$commit;archive=$archive;identity=$identity;version=$Version;module=(Join-Path $repository 'src/CLC.Deployment')}
    }
    function Test-DistributionFixture($Fixture,[string] $InstalledRoot='') {
        & $script:DistributionVerifier -ArchivePath $Fixture.archive -ExpectedSha256 $Fixture.identity.distributionSha256 -ExpectedSourceCommit $Fixture.commit -ExpectedVersion $Fixture.version -InstalledModuleRoot $InstalledRoot
    }
    function New-DistributionWithChangedEntry($Fixture,[string] $OutputPath,[string] $EntryName,[byte[]] $Replacement) {
        $sourceStream=[IO.FileStream]::new($Fixture.archive,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $sourceZip=$null; $targetStream=$null; $targetZip=$null; $found=$false
        try {
            $sourceZip=[IO.Compression.ZipArchive]::new($sourceStream,[IO.Compression.ZipArchiveMode]::Read,$true)
            $targetStream=[IO.FileStream]::new($OutputPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            $targetZip=[IO.Compression.ZipArchive]::new($targetStream,[IO.Compression.ZipArchiveMode]::Create,$true)
            foreach ($sourceEntry in $sourceZip.Entries) {
                $targetEntry=$targetZip.CreateEntry($sourceEntry.FullName,[IO.Compression.CompressionLevel]::NoCompression)
                $targetEntry.LastWriteTime=[DateTimeOffset]::new(1980,1,1,0,0,0,[TimeSpan]::Zero)
                $inputStream=$sourceEntry.Open(); $outputStream=$targetEntry.Open()
                try {
                    if ($sourceEntry.FullName -ceq $EntryName) { $found=$true; $outputStream.Write($Replacement) }
                    else { $inputStream.CopyTo($outputStream) }
                } finally { $inputStream.Dispose(); $outputStream.Dispose() }
            }
            $targetZip.Dispose(); $targetZip=$null; $targetStream.Flush($true)
        } finally {
            if ($null -ne $targetZip) { $targetZip.Dispose() }
            if ($null -ne $targetStream) { $targetStream.Dispose() }
            if ($null -ne $sourceZip) { $sourceZip.Dispose() }
            $sourceStream.Dispose()
        }
        if (-not $found) { throw 'Requested archive entry was not found.' }
        return (Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}
Describe 'Independent immutable distribution verification' {
    BeforeEach { $script:fixture=New-DistributionFixture }
    AfterEach { Remove-TestWorkspace $script:fixture.workspace }
    It 'builds byte-identical source-pinned distributions and verifies an exact installed tree without importing it' {
        $again=Join-Path $fixture.workspace 'again.zip'
        $second=& $script:DistributionBuilder -RepositoryRoot $fixture.repository -SourceCommit $fixture.commit -OutputPath $again
        $second.distributionSha256 | Should -BeExactly $fixture.identity.distributionSha256
        $result=Test-DistributionFixture $fixture $fixture.module
        $result.integrityVerified | Should -BeTrue
        $result.authenticatedByThisCheck | Should -BeFalse
        $result.sourceCommit | Should -BeExactly $fixture.commit
        (Get-Module CLC.Deployment).ModuleBase | Should -BeExactly (Join-Path $script:RepositoryRoot 'src/CLC.Deployment')
    }
    It 'round-trips stable and prerelease distributions through verification and inactive extraction' {
        foreach ($version in @('1.2.3','2.0.0-beta.1')) {
            $fixture=New-DistributionFixture $version
            try {
                $verified=Test-DistributionFixture $fixture
                $verified.moduleVersion | Should -BeExactly $version
                $versions=Join-Path $fixture.workspace 'versions'
                $null=[IO.Directory]::CreateDirectory($versions)
                $expanded=& (Join-Path $script:RepositoryRoot 'tools/Expand-ToolkitDistribution.ps1') -ArchivePath $fixture.archive -ExpectedSha256 $fixture.identity.distributionSha256 -ExpectedSourceCommit $fixture.commit -ExpectedVersion $version -VersionRoot (Join-Path $versions $version) -OperatorApprovalReference 'offline-integrity-test'
                $expanded.identity.moduleVersion | Should -BeExactly $version
                $expanded.activated | Should -BeFalse
                $installed=Test-DistributionFixture $fixture (Join-Path $versions ($version+'\CLC.Deployment'))
                $installed.moduleVersion | Should -BeExactly $version
                (Get-DistModuleVersion ([IO.File]::ReadAllText($expanded.moduleManifestPath))) | Should -BeExactly $version
            } finally { Remove-TestWorkspace $fixture.workspace }
        }
    }
    It 'accepts omitted prerelease metadata as a stable module version' {
        $stableManifest=[string]::Join([Environment]::NewLine,@('@{',"    ModuleVersion = '4.5.6'",'}'))
        (Get-DistModuleVersion $stableManifest) | Should -BeExactly '4.5.6'
        $emptyPrerelease=[string]::Join([Environment]::NewLine,@('@{',"    ModuleVersion = '4.5.6'","    PrivateData = @{ PSData = @{ Prerelease = '' } }",'}'))
        { Get-DistModuleVersion $emptyPrerelease } | Should -Throw '*Invalid shared release version*'
    }
    It 'rejects malformed shared versions and nonmatching tags' {
        foreach ($version in @('01.2.3','1.02.3','1.2.03','2147483648.0.0','1.2','1.2.3-','1.2.3-01','v1.2.3','1.2.3+meta','1.2.3-alpha.01')) {
            { Assert-DistVersion $version } | Should -Throw '*Invalid shared release version*'
        }
        { Assert-DistReleaseTag 'v1.2.3' '1.2.3-beta.1' } | Should -Throw '*does not match*'
        { Assert-DistReleaseTag 'v1.2.3-beta.1' '1.2.3-beta.1' } | Should -Not -Throw
    }
    It 'rejects dirty source before creating output' {
        [IO.File]::WriteAllText((Join-Path $fixture.repository 'untracked.txt'),'unreviewed')
        $output=Join-Path $fixture.workspace 'dirty.zip'
        { & $script:DistributionBuilder -RepositoryRoot $fixture.repository -SourceCommit $fixture.commit -OutputPath $output } | Should -Throw '*clean committed HEAD*'
        Test-Path -LiteralPath $output | Should -BeFalse
    }
    It 'rejects a different source pin and refuses existing outputs' {
        { & $script:DistributionBuilder -RepositoryRoot $fixture.repository -SourceCommit ('a'*40) -OutputPath (Join-Path $fixture.workspace 'wrong.zip') } | Should -Throw
        $hash=(Get-FileHash -LiteralPath $fixture.archive).Hash
        { & $script:DistributionBuilder -RepositoryRoot $fixture.repository -SourceCommit $fixture.commit -OutputPath $fixture.archive } | Should -Throw
        (Get-FileHash -LiteralPath $fixture.archive).Hash | Should -BeExactly $hash
    }
    It 'cannot authenticate a distribution with its adjacent self-declared checksum' {
        { & $script:DistributionVerifier -ArchivePath $fixture.archive -ExpectedSha256 ('0'*64) -ExpectedSourceCommit $fixture.commit -ExpectedVersion $fixture.version } | Should -Throw '*digest differs*'
    }
    It 'rejects source, version and manifest mismatches even when a modified archive digest is supplied' {
        { & $script:DistributionVerifier -ArchivePath $fixture.archive -ExpectedSha256 $fixture.identity.distributionSha256 -ExpectedSourceCommit ('a'*40) -ExpectedVersion $fixture.version } | Should -Throw '*identity differs*'
        { & $script:DistributionVerifier -ArchivePath $fixture.archive -ExpectedSha256 $fixture.identity.distributionSha256 -ExpectedSourceCommit $fixture.commit -ExpectedVersion '0.1.0' } | Should -Throw '*identity differs*'
        $sourceZip=[IO.Compression.ZipFile]::OpenRead($fixture.archive)
        try { $record=Read-DistJson (Read-DistEntry $sourceZip.GetEntry('distribution.json') 4194304) }
        finally { $sourceZip.Dispose() }
        $record.moduleVersion='9.9.9'
        $manifestBytes=[Text.Encoding]::UTF8.GetBytes(($record | ConvertTo-Json -Depth 16 -Compress))
        $rewritten=Join-Path $fixture.workspace 'wrong-manifest.zip'
        $digest=New-DistributionWithChangedEntry $fixture $rewritten 'distribution.json' $manifestBytes
        { & $script:DistributionVerifier -ArchivePath $rewritten -ExpectedSha256 $digest -ExpectedSourceCommit $fixture.commit -ExpectedVersion $fixture.version } | Should -Throw '*identity differs*'
    }
    It 'rejects module bytes changed inside an archive even when its outer digest is updated' {
        $rewritten=Join-Path $fixture.workspace 'wrong-module.zip'
        $digest=New-DistributionWithChangedEntry $fixture $rewritten 'CLC.Deployment/Private/ToolkitIdentity.ps1' ([Text.Encoding]::UTF8.GetBytes('function Get-ClcToolkitVersion { }'))
        { & $script:DistributionVerifier -ArchivePath $rewritten -ExpectedSha256 $digest -ExpectedSourceCommit $fixture.commit -ExpectedVersion $fixture.version } | Should -Throw '*Module bytes differ*'
    }
    It 'rejects modified, missing and unexpected installed files' {
        $path=Join-Path $fixture.module 'Private/ToolkitIdentity.ps1'
        [IO.File]::AppendAllText($path,'# drift')
        { Test-DistributionFixture $fixture $fixture.module } | Should -Throw '*differs*'
        [IO.File]::Delete($path)
        { Test-DistributionFixture $fixture $fixture.module } | Should -Throw '*differs*'
        [IO.File]::WriteAllText((Join-Path $fixture.module 'extra.ps1'),'throw "Never execute"')
        { Test-DistributionFixture $fixture $fixture.module } | Should -Throw
    }
    It 'rejects an unexpected empty installed directory' {
        $null=[IO.Directory]::CreateDirectory((Join-Path $fixture.module 'foreign'))
        { Test-DistributionFixture $fixture $fixture.module } | Should -Throw '*Unexpected installed directory*'
    }
    It 'rejects actual installed hard links and named directory streams' {
        $path=Join-Path $fixture.module 'Private/ToolkitIdentity.ps1'; $link=Join-Path $fixture.workspace 'hardlink.ps1'
        $null=New-Item -ItemType HardLink -Path $link -Target $path
        { Test-DistributionFixture $fixture $fixture.module } | Should -Throw
        [IO.File]::Delete($link)
        [IO.File]::WriteAllText(($fixture.module+':foreign'),'unknown')
        try { { Test-DistributionFixture $fixture $fixture.module } | Should -Throw }
        finally { [IO.File]::Delete(($fixture.module+':foreign')) }
    }
    It 'rejects duplicate and case-ambiguous JSON fields before deserialization' {
        { Read-DistJson ([Text.Encoding]::UTF8.GetBytes('{"formatVersion":1,"FormatVersion":1}')) } | Should -Throw '*Duplicate*'
    }
    It 'rejects path aliases and archive traversal without importing code' {
        foreach ($name in @('../evil','C:/evil','a//b','a/CON.txt','a./b','a\\b')) { { Assert-DistName $name } | Should -Throw }
        { Assert-DistLocalPath (Join-Path $fixture.module '..\other') } | Should -Throw
    }
}

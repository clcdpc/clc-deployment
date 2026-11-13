BeforeAll {
    . "$PSScriptRoot/Support.ps1"
    . "$script:RepositoryRoot/tools/Distribution.Common.ps1"
    function New-TaggedDistributionFixture([switch] $WithInfrastructure) {
        $root=New-TestWorkspace
        $repo=Join-Path $root 'repo'
        [void][IO.Directory]::CreateDirectory((Join-Path $repo 'src'))
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'src/CLC.Deployment') -Destination (Join-Path $repo 'src') -Recurse
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'VERSION') -Destination $repo
        if ($WithInfrastructure) {
            foreach ($name in (Get-DistInfrastructureNames)) {
                $destination=Join-Path $repo $name
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
                Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot $name) -Destination $destination
            }
        }
        $null=Get-DistGit $repo @('init','--initial-branch=codex/version-fixture')
        $null=Get-DistGit $repo @('config','user.name','CLC Version Fixture')
        $null=Get-DistGit $repo @('config','user.email','version@example.invalid')
        $null=Get-DistGit $repo @('config','core.autocrlf','false')
        $null=Get-DistGit $repo @('add','.')
        $null=Get-DistGit $repo @('commit','-m','Immutable development version')
        @{root=$root;repo=$repo;commit=(Get-DistGit $repo @('rev-parse','HEAD'))}
    }
    function Read-TaggedDistributionRecord([string] $Path) {
        $zip=[IO.Compression.ZipFile]::OpenRead($Path)
        try { Read-DistJson (Read-DistEntry $zip.GetEntry('distribution.json')) }
        finally { $zip.Dispose() }
    }
    function Rewrite-TaggedDistribution([string] $Path,[scriptblock] $Change) {
        $source=[IO.Compression.ZipFile]::OpenRead($Path)
        try {
            $record=Read-DistJson (Read-DistEntry $source.GetEntry('distribution.json'))
            $manifestBytes=Read-DistEntry $source.GetEntry('CLC.Deployment/CLC.Deployment.psd1')
        } finally { $source.Dispose() }
        $zip=[IO.Compression.ZipFile]::Open($Path,[IO.Compression.ZipArchiveMode]::Update)
        try {
            & $Change $record $zip $manifestBytes
            $zip.GetEntry('distribution.json').Delete()
            $entry=$zip.CreateEntry('distribution.json',[IO.Compression.CompressionLevel]::NoCompression)
            $entry.ExternalAttributes=0
            $stream=$entry.Open()
            try { $stream.Write([Text.Encoding]::UTF8.GetBytes(($record | ConvertTo-Json -Depth 16 -Compress))) }
            finally { $stream.Dispose() }
        } finally { $zip.Dispose() }
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}
Describe 'Tag-derived module distribution versions' {
    BeforeEach { $fixture=New-TaggedDistributionFixture }
    AfterEach { Remove-TestWorkspace $fixture.root }
    It 'generates and extracts <Version> without changing committed development metadata' -ForEach @(@{Version='7.8.9'},@{Version='7.8.9-beta.2'}) {
        $manifestPath=Join-Path $fixture.repo 'src/CLC.Deployment/CLC.Deployment.psd1'
        $original=[IO.File]::ReadAllBytes($manifestPath)
        $originalVersion=[IO.File]::ReadAllText((Join-Path $fixture.repo 'VERSION'))
        $archive=Join-Path $fixture.root 'release.zip'
        $identity=& "$script:RepositoryRoot/tools/New-ToolkitDistribution.ps1" -RepositoryRoot $fixture.repo -SourceCommit $fixture.commit -OutputPath $archive -ReleaseVersion $Version
        $identity.moduleVersion | Should -BeExactly $Version
        $verified=& "$script:RepositoryRoot/tools/Test-ToolkitDistribution.ps1" -ArchivePath $archive -ExpectedSha256 $identity.distributionSha256 -ExpectedSourceCommit $fixture.commit -ExpectedVersion $Version
        $verified.formatVersion | Should -Be 1
        $record=Read-TaggedDistributionRecord $archive
        ($record.sourceFiles | Where-Object path -CEQ 'src/CLC.Deployment/CLC.Deployment.psd1').sha256 | Should -BeExactly (Get-DistHash $original)
        (Get-DistHash ([IO.File]::ReadAllBytes($manifestPath))) | Should -BeExactly (Get-DistHash $original)
        [IO.File]::ReadAllText((Join-Path $fixture.repo 'VERSION')) | Should -BeExactly $originalVersion
        (Get-DistGit $fixture.repo @('status','--porcelain=v1','--untracked-files=normal')) | Should -BeNullOrEmpty
        $again=Join-Path $fixture.root 'again.zip'
        $second=& "$script:RepositoryRoot/tools/New-ToolkitDistribution.ps1" -RepositoryRoot $fixture.repo -SourceCommit $fixture.commit -OutputPath $again -ReleaseVersion $Version
        $second.distributionSha256 | Should -BeExactly $identity.distributionSha256
        $versions=Join-Path $fixture.root 'versions'
        [void][IO.Directory]::CreateDirectory($versions)
        $expanded=& "$script:RepositoryRoot/tools/Expand-ToolkitDistribution.ps1" -ArchivePath $archive -ExpectedSha256 $identity.distributionSha256 -ExpectedSourceCommit $fixture.commit -ExpectedVersion $Version -VersionRoot (Join-Path $versions $Version) -OperatorApprovalReference 'offline-version-test'
        (Get-DistModuleVersion ([IO.File]::ReadAllText($expanded.moduleManifestPath))) | Should -BeExactly $Version
        $expanded.activated | Should -BeFalse
    }
    It 'rejects an incorrect stamped version even when the output inventory is recomputed' {
        $archive=Join-Path $fixture.root 'tampered.zip'
        $identity=& "$script:RepositoryRoot/tools/New-ToolkitDistribution.ps1" -RepositoryRoot $fixture.repo -SourceCommit $fixture.commit -OutputPath $archive -ReleaseVersion '7.8.9'
        $digest=Rewrite-TaggedDistribution $archive {
            param($record,$zip,$manifestBytes)
            $entry=$zip.GetEntry('CLC.Deployment/CLC.Deployment.psd1')
            $changed=Get-DistVersionedManifestBytes $manifestBytes '9.9.9'
            $entry.Delete()
            $entry=$zip.CreateEntry('CLC.Deployment/CLC.Deployment.psd1',[IO.Compression.CompressionLevel]::NoCompression)
            $entry.ExternalAttributes=0
            $stream=$entry.Open();try {$stream.Write($changed)} finally {$stream.Dispose()}
            $file=$record.files | Where-Object path -CEQ 'CLC.Deployment.psd1'
            $file.length=[long]$changed.Length;$file.sha256=Get-DistHash $changed
            $record.inventorySha256=Get-DistInventoryHash $record.files
        }
        { & "$script:RepositoryRoot/tools/Test-ToolkitDistribution.ps1" -ArchivePath $archive -ExpectedSha256 $digest -ExpectedSourceCommit $fixture.commit -ExpectedVersion '7.8.9' } | Should -Throw '*manifest version differs*'
    }
    It 'preserves infrastructure inventory and supports protected extraction of format-2 bundles' {
        $withTools=New-TaggedDistributionFixture -WithInfrastructure
        try {
            $archive=Join-Path $withTools.root 'with-tools.zip'
            $identity=& "$script:RepositoryRoot/tools/New-ToolkitDistribution.ps1" -RepositoryRoot $withTools.repo -SourceCommit $withTools.commit -OutputPath $archive -ReleaseVersion '7.8.9-beta.2'
            $verified=& "$script:RepositoryRoot/tools/Test-ToolkitDistribution.ps1" -ArchivePath $archive -ExpectedSha256 $identity.distributionSha256 -ExpectedSourceCommit $withTools.commit -ExpectedVersion '7.8.9-beta.2' -RequireInfrastructureTools
            $verified.formatVersion | Should -Be 2
            $versions=Join-Path $withTools.root 'versions'
            [void][IO.Directory]::CreateDirectory($versions)
            $expanded=& "$script:RepositoryRoot/tools/Expand-ToolkitDistribution.ps1" -ArchivePath $archive -ExpectedSha256 $identity.distributionSha256 -ExpectedSourceCommit $withTools.commit -ExpectedVersion '7.8.9-beta.2' -VersionRoot (Join-Path $versions '7.8.9-beta.2') -OperatorApprovalReference 'offline-version-test'
            $expanded.activated | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $versions '7.8.9-beta.2/tools/host/Initialize-ClcHostEnrollment.ps1') | Should -BeTrue
        } finally { Remove-TestWorkspace $withTools.root }
    }
    It 'does not treat a generated distribution without infrastructure as enrollment-ready' {
        $archive=Join-Path $fixture.root 'no-tools.zip'
        $identity=& "$script:RepositoryRoot/tools/New-ToolkitDistribution.ps1" -RepositoryRoot $fixture.repo -SourceCommit $fixture.commit -OutputPath $archive -ReleaseVersion '7.8.9'
        { & "$script:RepositoryRoot/tools/Test-ToolkitDistribution.ps1" -ArchivePath $archive -ExpectedSha256 $identity.distributionSha256 -ExpectedSourceCommit $fixture.commit -ExpectedVersion '7.8.9' -RequireInfrastructureTools } | Should -Throw '*requires a format-2 distribution*'
    }
}

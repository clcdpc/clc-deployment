BeforeAll {
    . "$PSScriptRoot/Support.ps1"
    . "$script:RepositoryRoot/tools/Distribution.Common.ps1"
    $script:tagVerifier=Join-Path $script:RepositoryRoot 'tools/Test-SharedReleaseTag.ps1'
}
Describe 'Tag-authoritative release version' {
    BeforeEach {
        $script:workspace=New-TestWorkspace
        $script:repo=Join-Path $workspace 'repo'
        [void][IO.Directory]::CreateDirectory($repo)
        $null=Get-DistGit $repo @('init','--initial-branch=codex/version-fixture')
        $null=Get-DistGit $repo @('config','user.name','CLC version fixture')
        $null=Get-DistGit $repo @('config','user.email','version@example.invalid')
        [IO.File]::WriteAllText((Join-Path $repo 'VERSION'),'0.1.0-dev.1')
        $null=Get-DistGit $repo @('add','VERSION')
        $null=Get-DistGit $repo @('commit','-m','Development fixture')
        $script:commit=Get-DistGit $repo @('rev-parse','HEAD')
    }
    AfterEach { Remove-TestWorkspace $workspace }
    It 'uses <Version> without editing development metadata' -ForEach @(
        @{Version='1.2.3';Prerelease=$false}, @{Version='2.0.0-beta.1';Prerelease=$true}
    ) {
        $null=Get-DistGit $repo @('tag',('v'+$Version))
        $result=& $tagVerifier -RepositoryRoot $repo -Tag ('v'+$Version) -SourceCommit $commit
        $result.version | Should -BeExactly $Version
        $result.prerelease | Should -Be $Prerelease
        [IO.File]::ReadAllText((Join-Path $repo 'VERSION')) | Should -BeExactly '0.1.0-dev.1'
        Get-DistGit $repo @('status','--porcelain') | Should -BeNullOrEmpty
    }
    It 'rejects malformed, absent and differently targeted tags' {
        foreach ($tag in @('1.2.3','V1.2.3','v01.2.3','v1.2.3+meta','v1.2.3-01','v1.2')) {
            { & $tagVerifier -RepositoryRoot $repo -Tag $tag -SourceCommit $commit } | Should -Throw
        }
        { & $tagVerifier -RepositoryRoot $repo -Tag 'v1.2.3' -SourceCommit $commit } | Should -Throw '*absent*'
        $null=Get-DistGit $repo @('tag','v1.2.3')
        [IO.File]::WriteAllText((Join-Path $repo 'second'),'second')
        $null=Get-DistGit $repo @('add','second')
        $null=Get-DistGit $repo @('commit','-m','Different commit')
        $second=Get-DistGit $repo @('rev-parse','HEAD')
        { & $tagVerifier -RepositoryRoot $repo -Tag 'v1.2.3' -SourceCommit $second } | Should -Throw '*does not point*'
        { & $tagVerifier -RepositoryRoot $repo -Tag 'v1.2.3' -SourceCommit $commit } | Should -Throw '*HEAD differs*'
    }
    It 'rejects dirty source even when the tag targets HEAD' {
        $null=Get-DistGit $repo @('tag','v1.2.3')
        [IO.File]::WriteAllText((Join-Path $repo 'untracked'),'dirty')
        { & $tagVerifier -RepositoryRoot $repo -Tag 'v1.2.3' -SourceCommit $commit } | Should -Throw '*not clean*'
    }
}

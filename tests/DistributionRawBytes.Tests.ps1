BeforeAll {
    . "$PSScriptRoot/Support.ps1"
    . "$script:RepositoryRoot/tools/Distribution.Common.ps1"
    function New-RawDistributionRepository([string] $Root,[string] $ObjectFormat='sha1'){
        $repo=Join-Path $Root 'repo';[void][IO.Directory]::CreateDirectory($repo)
        $null=Get-DistGit $repo @('init','--initial-branch=codex/raw-fixture',('--object-format='+$ObjectFormat))
        foreach($pair in @(@('user.name','CLC Raw Distribution Fixture'),@('user.email','raw-distribution@example.invalid'),@('core.autocrlf','false'))){$null=Get-DistGit $repo @('config',$pair[0],$pair[1])}
        [IO.File]::WriteAllBytes((Join-Path $repo 'source.txt'),[Text.Encoding]::UTF8.GetBytes("first`nsecond`n"))
        [IO.File]::WriteAllBytes((Join-Path $repo 'binary.data'),[byte[]]@(0,10,13,128,255))
        return $repo
    }
    function Save-RawDistributionCommit([string]$Repository){$null=Get-DistGit $Repository @('add','.');$null=Get-DistGit $Repository @('commit','-m','Owned raw Git byte fixture');Get-DistGit $Repository @('rev-parse','HEAD')}
}
Describe 'Distribution source bytes are raw Git objects, independent of checkout EOL settings' {
    BeforeEach {$root=New-TestWorkspace}
    AfterEach {Remove-TestWorkspace $root}
    It 'keeps archive bytes equal to actual <Format> Git blob identities under local autocrlf=true/eol=crlf' -ForEach @(@{Format='sha1'},@{Format='sha256'}) {
        $repo=New-RawDistributionRepository $root $Format;$commit=Save-RawDistributionCommit $repo
        $null=Get-DistGit $repo @('config','core.autocrlf','true');$null=Get-DistGit $repo @('config','core.eol','crlf')
        $map=Get-DistGitTreeBlobMap $repo $commit;$map.Count|Should -Be 2
        $archive=Join-Path $root 'source.zip';$null=Get-DistGit $repo @('archive','--format=zip',('--output='+$archive),$commit)
        $zip=[IO.Compression.ZipFile]::OpenRead($archive)
        try{foreach($entry in $zip.Entries){$bytes=Read-DistEntry $entry;{Assert-DistGitBlobBytes $bytes $map[$entry.FullName]}|Should -Not -Throw;if($entry.FullName -ceq 'source.txt'){[Text.Encoding]::UTF8.GetString($bytes)|Should -BeExactly "first`nsecond`n"}}}finally{$zip.Dispose()}
        (Get-DistGit $repo @('config','--get','core.autocrlf'))|Should -BeExactly true
        (Get-DistGit $repo @('config','--get','core.eol'))|Should -BeExactly crlf
    }
    It 'refuses actual export-subst conversion before SDK execution or output publication' {
        $repo=New-RawDistributionRepository $root
        [IO.File]::WriteAllText((Join-Path $repo '.gitattributes'),"source.txt export-subst`n",[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $repo 'source.txt'),'$Format:%H$',[Text.UTF8Encoding]::new($false))
        $commit=Save-RawDistributionCommit $repo;$output=Join-Path $root 'rejected.zip'
        {& "$script:RepositoryRoot/tools/New-ToolkitDistribution.ps1" -RepositoryRoot $repo -SourceCommit $commit -OutputPath $output}|Should -Throw '*raw committed Git blob bytes*'
        Test-Path -LiteralPath $output|Should -BeFalse
        Test-Path -LiteralPath ($output+'.identity.json')|Should -BeFalse
    }
    It 'refuses forced attribute EOL conversion rather than relabeling converted bytes with a source commit' {
        $repo=New-RawDistributionRepository $root
        [IO.File]::WriteAllText((Join-Path $repo '.gitattributes'),"source.txt text eol=crlf`n",[Text.UTF8Encoding]::new($false))
        $commit=Save-RawDistributionCommit $repo;$output=Join-Path $root 'rejected.zip'
        {& "$script:RepositoryRoot/tools/New-ToolkitDistribution.ps1" -RepositoryRoot $repo -SourceCommit $commit -OutputPath $output}|Should -Throw '*raw committed Git blob bytes*'
        Test-Path -LiteralPath $output|Should -BeFalse
    }
}

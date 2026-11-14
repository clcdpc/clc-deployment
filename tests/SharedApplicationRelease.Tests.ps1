BeforeAll {
    . "$PSScriptRoot/../tools/release/Release.Common.ps1"
    function New-ApplicationReleaseFixture {
        $script:sourceCommit='a'*40; $script:integrationCommit='b'*40
        $script:configuration=@{contractVersion=1L;applicationId='ssrs-web';repository='clcdpc/ssrs-web';integrationBranch='master';sourcePolicy=@{allowPrDev=$true;allowSnapshots=$true;allowTestTags=$true};producer=@{workflowPath='.github/workflows/build.yml';job='build'};trustedFiles=@('.clc/release.json','.github/workflows/build.yml');requiredToolkitContractVersion=2L}
        $script:responses=@{}
        $base='/repos/clcdpc/ssrs-web'
        $script:responses[$base+'/branches/master']=@{protected=$true;commit=@{sha=$script:integrationCommit}}
        $script:responses[$base+'/git/ref/tags/v1.2.3-dev.1']=@{object=@{type='commit';sha=$script:sourceCommit}}
        $script:responses[$base+'/compare/'+$script:sourceCommit+'...'+$script:integrationCommit]=@{status='ahead';merge_base_commit=@{sha=$script:sourceCommit}}
        foreach ($path in $script:configuration.trustedFiles) {
            foreach ($commit in @($script:sourceCommit,$script:integrationCommit)) { $script:responses[$base+'/contents/'+$path+'?ref='+$commit]=@{type='file';sha='same-blob'} }
        }
        $script:api={param($method,$path,$body) if (-not $script:responses.ContainsKey($path)) { throw ('Unexpected API '+$path) }; return $script:responses[$path]}
    }
    function Set-ReviewedPrFixture {
        $base='/repos/clcdpc/ssrs-web'
        $script:responses[$base+'/compare/'+$script:sourceCommit+'...'+$script:integrationCommit]=@{status='diverged';merge_base_commit=@{sha=('c'*40)}}
        $script:responses[$base+'/commits/'+$script:sourceCommit+'/pulls?per_page=100&page=1']=,@{state='open';draft=$false;number=1;user=@{login='author'};head=@{sha=$script:sourceCommit;repo=@{full_name='clcdpc/ssrs-web'}};base=@{ref='master';repo=@{full_name='clcdpc/ssrs-web'}}}
        $script:responses[$base+'/pulls/1/reviews?per_page=100&page=1']=,@{id=1;state='APPROVED';commit_id=$script:sourceCommit;user=@{login='reviewer'}}
        $script:responses[$base+'/collaborators/reviewer/permission']=@{permission='write'}
    }
}

Describe 'Shared application source eligibility' {
    BeforeEach { New-ApplicationReleaseFixture }
    It 'classifies supported semantic releases independently from deployment authority' -ForEach @(
        @{tag='v1.2.3-dev.1';channel='DEV'},@{tag='v1.2.3-test.1';channel='Test'},@{tag='v1.2.3-beta.1';channel='ArtifactOnly'},@{tag='v1.2.3-rc.1';channel='ArtifactOnly'},@{tag='v1.2.3';channel='Production'}
    ) { (Get-ClcApplicationTag $tag).channel | Should -BeExactly $channel }
    It 'accepts the SSRS reviewed unmerged current same-repository DEV PR head' {
        Set-ReviewedPrFixture
        $result=Get-ClcVerifiedSource $script:configuration 'v1.2.3-dev.1' $script:sourceCommit 123 $script:api
        $result.identity.sourceClass | Should -BeExactly 'ReviewedPr'
    }
    It 'rejects moved tags before source execution' {
        $script:responses['/repos/clcdpc/ssrs-web/git/ref/tags/v1.2.3-dev.1'].object.sha='c'*40
        { Get-ClcVerifiedSource $script:configuration 'v1.2.3-dev.1' $script:sourceCommit 123 $script:api } | Should -Throw '*tag moved*'
    }
    It 'rejects an external PR head even with a write-authority review' {
        Set-ReviewedPrFixture
        $script:responses['/repos/clcdpc/ssrs-web/commits/'+$script:sourceCommit+'/pulls?per_page=100&page=1'][0].head.repo.full_name='external/ssrs-web'
        { Get-ClcVerifiedSource $script:configuration 'v1.2.3-dev.1' $script:sourceCommit 123 $script:api } | Should -Throw '*current-head approval*'
    }
    It 'rejects stale or withdrawn review authority' -ForEach @(@{mode='stale'},@{mode='withdrawn'},@{mode='read'}) {
        Set-ReviewedPrFixture
        $key='/repos/clcdpc/ssrs-web/pulls/1/reviews?per_page=100&page=1'
        if ($mode -ceq 'stale') {$script:responses[$key][0].commit_id='c'*40}
        if ($mode -ceq 'withdrawn') {$script:responses[$key]+=,@{id=2;state='CHANGES_REQUESTED';commit_id=$script:sourceCommit;user=@{login='reviewer'}}}
        if ($mode -ceq 'read') {$script:responses['/repos/clcdpc/ssrs-web/collaborators/reviewer/permission'].permission='read'}
        { Get-ClcVerifiedSource $script:configuration 'v1.2.3-dev.1' $script:sourceCommit 123 $script:api } | Should -Throw '*current-head approval*'
    }
    It 'rejects trusted workflow or policy changes on eligible PR source' {
        Set-ReviewedPrFixture
        $script:responses['/repos/clcdpc/ssrs-web/contents/.clc/release.json?ref='+$script:sourceCommit].sha='changed'
        { Get-ClcVerifiedSource $script:configuration 'v1.2.3-dev.1' $script:sourceCommit 123 $script:api } | Should -Throw '*trusted release*'
    }
    It 'orders ASAP branch snapshots separately and marks superseded automatic source' {
        $result=Get-ClcVerifiedSource $script:configuration 'refs/heads/master' $script:sourceCommit 123 $script:api
        $result.identity.sourceClass | Should -BeExactly 'ProtectedBranch'
        $result.identity.sequence | Should -Be 123
        $result.identity.orderingKind | Should -BeExactly 'Snapshot'
        $result.superseded | Should -BeTrue
    }
    It 'keeps immutable source identity stable when the protected branch advances without changing trusted code' {
        $first=Get-ClcVerifiedSource $script:configuration 'v1.2.3-dev.1' $script:sourceCommit 123 $script:api
        $next='d'*40; $base='/repos/clcdpc/ssrs-web'
        $script:responses[$base+'/branches/master'].commit.sha=$next
        $script:responses[$base+'/compare/'+$script:sourceCommit+'...'+$next]=@{status='ahead';merge_base_commit=@{sha=$script:sourceCommit}}
        foreach ($path in $script:configuration.trustedFiles) {$script:responses[$base+'/contents/'+$path+'?ref='+$next]=@{type='file';sha='same-blob'}}
        $second=Get-ClcVerifiedSource $script:configuration 'v1.2.3-dev.1' $script:sourceCommit 123 $script:api
        ($second.identity | ConvertTo-Json -Compress) | Should -BeExactly ($first.identity | ConvertTo-Json -Compress)
    }
    It 'rejects an unauthorized branch snapshot' {
        $script:configuration.sourcePolicy.allowSnapshots=$false
        { Get-ClcVerifiedSource $script:configuration 'refs/heads/master' $script:sourceCommit 123 $script:api } | Should -Throw '*snapshots are disabled*'
    }
    It 'requires a protected integration branch' {
        $script:responses['/repos/clcdpc/ssrs-web/branches/master'].protected=$false
        { Get-ClcVerifiedSource $script:configuration 'v1.2.3-dev.1' $script:sourceCommit 123 $script:api } | Should -Throw '*must be protected*'
    }
}

Describe 'Qualified producer and artifact admission' {
    BeforeEach {
        New-ApplicationReleaseFixture
        $script:source=Get-ClcVerifiedSource $script:configuration 'v1.2.3-dev.1' $script:sourceCommit 123 $script:api
        $base='/repos/clcdpc/ssrs-web'
        $script:responses[$base+'/actions/runs/123/attempts/2']=@{id=123;run_attempt=2;status='completed';conclusion='success';head_sha=$script:sourceCommit;repository=@{full_name='clcdpc/ssrs-web'};head_repository=@{full_name='clcdpc/ssrs-web'};path='.github/workflows/build.yml';event='push';head_branch='v1.2.3-dev.1';run_started_at='2026-11-13T00:00:00Z';updated_at='2026-11-13T00:10:00Z'}
        $script:responses[$base+'/actions/runs/123/attempts/2/jobs?per_page=100&page=1']=@{jobs=@(@{name='build';status='completed';conclusion='success';run_id=123})}
        $script:responses[$base+'/actions/artifacts/456']=@{id=456;expired=$false;name=('clc-package-'+$script:sourceCommit+'-123-2');workflow_run=@{id=123;head_sha=$script:sourceCommit};digest=('sha256:'+('d'*64));size_in_bytes=200;created_at='2026-11-13T00:05:00Z'}
    }
    It 'accepts exact qualified run job attempt and artifact identity' {
        $result=Get-ClcVerifiedProducer $script:configuration $script:source 123 2 456 $script:api
        $result.transportSha256 | Should -BeExactly ('d'*64)
    }
    It 'rejects wrong workflow, attempt artifact, failed job and stale artifact' -ForEach @(@{mode='workflow'},@{mode='attempt'},@{mode='job'},@{mode='stale'}) {
        if ($mode -ceq 'workflow') {$script:responses['/repos/clcdpc/ssrs-web/actions/runs/123/attempts/2'].path='.github/workflows/untrusted.yml'}
        if ($mode -ceq 'attempt') {$script:responses['/repos/clcdpc/ssrs-web/actions/artifacts/456'].name='old-attempt'}
        if ($mode -ceq 'job') {$script:responses['/repos/clcdpc/ssrs-web/actions/runs/123/attempts/2/jobs?per_page=100&page=1'].jobs[0].conclusion='failure'}
        if ($mode -ceq 'stale') {$script:responses['/repos/clcdpc/ssrs-web/actions/artifacts/456'].created_at='2026-11-12T00:05:00Z'}
        { Get-ClcVerifiedProducer $script:configuration $script:source 123 2 456 $script:api } | Should -Throw
    }
}

Describe 'Trusted artifact transport' {
    BeforeEach {
        $script:transportStream=[IO.MemoryStream]::new()
        $zip=[IO.Compression.ZipArchive]::new($script:transportStream,[IO.Compression.ZipArchiveMode]::Create,$true)
        $entry=$zip.CreateEntry('release.zip',[IO.Compression.CompressionLevel]::NoCompression); $entry.ExternalAttributes=0
        $output=$entry.Open(); $payload=[Text.Encoding]::UTF8.GetBytes('verified inner package')
        $output.Write($payload); $output.Dispose(); $zip.Dispose()
        $script:transport=$script:transportStream.ToArray(); $script:transportStream.Dispose()
        $script:provenance=@{artifactId=456;transportSha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($script:transport)).ToLowerInvariant()}
        $script:downloadApi={param($method,$path,$body,[switch]$Bytes) if (-not $Bytes) {throw 'Expected byte transport'}; return ,$script:transport}
        $script:downloadPath=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    }
    It 'extracts only the byte-verified qualified package' {
        $path=Save-ClcVerifiedArtifact 'clcdpc/ssrs-web' $script:provenance $script:downloadPath $script:downloadApi
        [IO.File]::ReadAllText($path) | Should -BeExactly 'verified inner package'
    }
    It 'rejects a transport mismatch before creating a destination' {
        $script:provenance.transportSha256='f'*64
        { Save-ClcVerifiedArtifact 'clcdpc/ssrs-web' $script:provenance $script:downloadPath $script:downloadApi } | Should -Throw '*digest differs*'
        Test-Path -LiteralPath $script:downloadPath | Should -BeFalse
    }
    It 'does not overwrite an existing artifact destination' {
        $null=[IO.Directory]::CreateDirectory($script:downloadPath)
        { Save-ClcVerifiedArtifact 'clcdpc/ssrs-web' $script:provenance $script:downloadPath $script:downloadApi } | Should -Throw '*must be new*'
    }
}

Describe 'Application release publication preserves completed bytes' {
    BeforeEach {
        $script:assetPath=Join-Path $TestDrive 'release.zip'; [IO.File]::WriteAllText($script:assetPath,'verified')
        $script:asset=@{name='release.zip';path=$script:assetPath;length=(Get-Item $script:assetPath).Length;sha256=(Get-FileHash $script:assetPath).Hash.ToLowerInvariant()}
        $script:identity=@{kind='tag';tag='v1.2.3-dev.1';releaseId='v1-2-3-dev-1';channel='DEV';repository='clcdpc/ssrs-web';sourceCommit=('a'*40)}
        $script:release=@{id=42;tag_name='v1.2.3-dev.1';target_commitish=('a'*40);prerelease=$true;draft=$false;assets=@(@{id=9;name='release.zip';size=$script:asset.length})}
        $script:writes=0
        $script:publishApi={param($method,$path,$body) if ($method -cne 'GET') {$script:writes++; throw 'Unexpected write'}; return $script:release}
        $script:assetHash={param($asset) return $script:asset.sha256}
        $script:upload={param($release,$asset) $script:writes++; throw 'Unexpected upload'}
    }
    It 'preserves identical completed GitHub releases without any writes' {
        $result=Invoke-ClcApplicationPublication $script:identity @($script:asset) $script:publishApi $script:assetHash $script:upload
        $result.status | Should -BeExactly 'Preserved'; $script:writes | Should -Be 0
    }
    It 'rejects conflicting completed release bytes without mutation' {
        { Invoke-ClcApplicationPublication $script:identity @($script:asset) $script:publishApi {param($a) 'f'*64} $script:upload } | Should -Throw '*assets conflict*'
        $script:writes | Should -Be 0
    }
    It 'refuses to repair a completed release missing assets' {
        $script:release.assets=@()
        { Invoke-ClcApplicationPublication $script:identity @($script:asset) $script:publishApi $script:assetHash $script:upload } | Should -Throw '*missing expected*'
        $script:writes | Should -Be 0
    }
    It 'accepts a racing draft asset upload only after exact winning-byte verification' {
        $script:release.draft=$true; $script:release.assets=@()
        $api={param($method,$path,$body) if ($method -ceq 'PATCH') {$script:release.draft=$false}; return $script:release}
        $upload={param($release,$asset) $script:release.assets=@(@{id=9;name='release.zip';size=$asset.length}); throw 'Duplicate race'}
        (Invoke-ClcApplicationPublication $script:identity @($script:asset) $api $script:assetHash $upload).status | Should -BeExactly 'Published'
    }
    It 'preserves a matching completed release that wins a creation race' {
        $script:created=$false
        $api={
            param($method,$path,$body)
            if ($method -ceq 'POST') {$script:created=$true; throw 'Creation race'}
            if ($path.Contains('/releases?')) {return @()}
            if ($script:created) {return $script:release}
            return $null
        }
        (Invoke-ClcApplicationPublication $script:identity @($script:asset) $api $script:assetHash $script:upload).status | Should -BeExactly 'Preserved'
        $script:writes | Should -Be 0
    }
    It 'stops uploading as soon as a racing publisher completes the full verified release' {
        $otherPath=Join-Path $TestDrive 'evidence.json'; [IO.File]::WriteAllText($otherPath,'verified')
        $other=@{name='evidence.json';path=$otherPath;length=$script:asset.length;sha256=$script:asset.sha256}
        $script:release.draft=$true; $script:release.assets=@(); $script:uploads=0
        $api={param($method,$path,$body) if ($method -cne 'GET') {throw 'Completed release must not be changed'}; return $script:release}
        $upload={
            param($release,$asset)
            $script:uploads++
            $script:release.assets=@(@{id=9;name='release.zip';size=$asset.length},@{id=10;name='evidence.json';size=$asset.length})
            $script:release.draft=$false
        }
        (Invoke-ClcApplicationPublication $script:identity @($script:asset,$other) $api $script:assetHash $upload).status | Should -BeExactly 'Preserved'
        $script:uploads | Should -Be 1
    }
    It 'never publishes protected-branch snapshots' {
        $script:identity.kind='snapshot'
        { Invoke-ClcApplicationPublication $script:identity @($script:asset) $script:publishApi $script:assetHash $script:upload } | Should -Throw '*do not create*'
    }
}

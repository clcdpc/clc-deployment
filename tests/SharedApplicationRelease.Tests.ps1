BeforeAll {
    . "$PSScriptRoot/../tools/release/Release.Common.ps1"
    function New-ApplicationReleaseFixture {
        $script:sourceCommit='a'*40; $script:integrationCommit='b'*40
        $script:configuration=@{contractVersion=1L;applicationId='ssrs-web';repository='clcdpc/ssrs-web';integrationBranch='master';sourcePolicy=@{allowUnmergedDevTags=$true;allowSnapshots=$true;allowTestTags=$true};producer=@{workflowPath='.github/workflows/build.yml';job='build'};trustedFiles=@('.clc/release.json','.github/workflows/build.yml');requiredToolkitContractVersion=2L}
        $script:responses=@{}
        $base='/repos/clcdpc/ssrs-web'
        $script:responses[$base+'/branches/master']=@{protected=$true;commit=@{sha=$script:integrationCommit}}
        $script:responses[$base+'/git/ref/tags/v1.2.3-dev.1']=@{object=@{type='commit';sha=$script:sourceCommit}}
        $script:responses[$base+'/compare/'+$script:sourceCommit+'...'+$script:integrationCommit]=@{status='ahead';merge_base_commit=@{sha=$script:sourceCommit}}
        foreach ($path in $script:configuration.trustedFiles) {
            foreach ($commit in @($script:sourceCommit,$script:integrationCommit)) { $script:responses[$base+'/contents/'+$path+'?ref='+$commit]=@{type='file';sha='same-blob'} }
        }
        $script:requests=[Collections.Generic.List[string]]::new()
        $script:api={param($method,$path,$body) $script:requests.Add($path); if (-not $script:responses.ContainsKey($path)) { throw ('Unexpected API '+$path) }; return $script:responses[$path]}
    }
    function Set-UnmergedDevTagFixture {
        $base='/repos/clcdpc/ssrs-web'
        $script:responses[$base+'/compare/'+$script:sourceCommit+'...'+$script:integrationCommit]=@{status='diverged';merge_base_commit=@{sha=('c'*40)}}
    }
}

Describe 'Shared application source eligibility' {
    BeforeEach { New-ApplicationReleaseFixture }
    It 'classifies supported semantic releases independently from deployment authority' -ForEach @(
        @{tag='v1.2.3-dev.1';channel='DEV'},@{tag='v1.2.3-test.1';channel='Test'},@{tag='v1.2.3-beta.1';channel='ArtifactOnly'},@{tag='v1.2.3-rc.1';channel='ArtifactOnly'},@{tag='v1.2.3';channel='Production'}
    ) { (Get-ClcApplicationTag $tag).channel | Should -BeExactly $channel }
    It 'accepts exact SSRS unmerged DEV tag source without PR, review or feature-branch evidence' {
        Set-UnmergedDevTagFixture
        $result=Get-ClcVerifiedSource $script:configuration 'v1.2.3-dev.1' $script:sourceCommit 123 $script:api
        $result.identity.sourceClass | Should -BeExactly 'UnmergedDevTag'
        $result.identity.sourceCommit | Should -BeExactly $script:sourceCommit
        @($script:requests | Where-Object {$_ -match '/pulls|/collaborators/|/branches/(?!master$)'}).Count | Should -Be 0
    }
    It 'rejects moved tags before source execution' {
        $script:responses['/repos/clcdpc/ssrs-web/git/ref/tags/v1.2.3-dev.1'].object.sha='c'*40
        { Get-ClcVerifiedSource $script:configuration 'v1.2.3-dev.1' $script:sourceCommit 123 $script:api } | Should -Throw '*tag moved*'
    }
    It 'peels bounded annotated tag objects to their exact commit' {
        $base='/repos/clcdpc/ssrs-web'
        $script:responses[$base+'/git/ref/tags/v1.2.3-dev.1']=@{object=@{type='tag';sha=('c'*40)}}
        $script:responses[$base+'/git/tags/'+('c'*40)]=@{sha=('c'*40);tag='v1.2.3-dev.1';object=@{type='tag';sha=('d'*40)}}
        $script:responses[$base+'/git/tags/'+('d'*40)]=@{sha=('d'*40);tag='inner';object=@{type='commit';sha=$script:sourceCommit}}
        (Get-ClcVerifiedSource $script:configuration 'v1.2.3-dev.1' $script:sourceCommit 123 $script:api).identity.sourceCommit | Should -BeExactly $script:sourceCommit
        $script:responses[$base+'/git/tags/'+('d'*40)].object.sha='e'*40
        { Get-ClcVerifiedSource $script:configuration 'v1.2.3-dev.1' $script:sourceCommit 123 $script:api } | Should -Throw '*tag moved*'
    }
    It 'retains exact tagged source regardless of an associated PR being <State>' -ForEach @(
        @{State='open without reviews'},@{State='advanced'},@{State='closed'},@{State='draft'},@{State='targeting another branch'},@{State='absent'}
    ) {
        Set-UnmergedDevTagFixture
        $first=Get-ClcVerifiedSource $script:configuration 'v1.2.3-dev.1' $script:sourceCommit 123 $script:api
        $pr=@{state='open';draft=$false;number=1;head=@{sha=$script:sourceCommit};base=@{ref='master'}}
        switch ($State) {
            advanced {$pr.head.sha='e'*40}
            closed {$pr.state='closed'}
            draft {$pr.draft=$true}
            'targeting another branch' {$pr.base.ref='other'}
        }
        $script:responses['/repos/clcdpc/ssrs-web/commits/'+$script:sourceCommit+'/pulls?per_page=100&page=1']=@($pr)
        if ($State -ceq 'absent') {$script:responses['/repos/clcdpc/ssrs-web/commits/'+$script:sourceCommit+'/pulls?per_page=100&page=1']=@()}
        $script:responses['/repos/clcdpc/ssrs-web/pulls/1/reviews?per_page=100&page=1']=@()
        $second=Get-ClcVerifiedSource $script:configuration 'v1.2.3-dev.1' $script:sourceCommit 123 $script:api
        ($second.identity | ConvertTo-Json -Compress) | Should -BeExactly ($first.identity | ConvertTo-Json -Compress)
        @($script:requests | Where-Object {$_ -match '/pulls|/collaborators/'}).Count | Should -Be 0
    }
    It 'cannot use a DEV tag to bypass disabled unmerged-source policy' {
        Set-UnmergedDevTagFixture
        $script:configuration.sourcePolicy.allowUnmergedDevTags=$false
        { Get-ClcVerifiedSource $script:configuration 'v1.2.3-dev.1' $script:sourceCommit 123 $script:api } | Should -Throw '*outside the protected integration history*'
    }
    It 'keeps integrated tags eligible when unmerged DEV tags are disabled' {
        $script:configuration.sourcePolicy.allowUnmergedDevTags=$false
        (Get-ClcVerifiedSource $script:configuration 'v1.2.3-dev.1' $script:sourceCommit 123 $script:api).identity.sourceClass | Should -BeExactly IntegrationTag
    }
    It 'rejects unmerged <Tag> outside the DEV allowance' -ForEach @(
        @{Tag='v1.2.3'},@{Tag='v1.2.3-beta.1'},@{Tag='v1.2.3-rc.1'},@{Tag='v1.2.3-test.1'}
    ) {
        Set-UnmergedDevTagFixture
        $script:responses['/repos/clcdpc/ssrs-web/git/ref/tags/'+$Tag]=@{object=@{type='commit';sha=$script:sourceCommit}}
        { Get-ClcVerifiedSource $script:configuration $Tag $script:sourceCommit 123 $script:api } | Should -Throw '*outside the protected integration history*'
    }
    It 'rejects invalid version tags <Tag>' -ForEach @(@{Tag='v1.2.3-dev.0'},@{Tag='v1.2.3-dev.01'},@{Tag='v1.2.3-dev.1-extra'},@{Tag='v1.2.3-DEV.1'}) {
        Set-UnmergedDevTagFixture
        { Get-ClcVerifiedSource $script:configuration $Tag $script:sourceCommit 123 $script:api } | Should -Throw
        @($script:requests | Where-Object {$_ -match '/git/ref/tags/'}).Count | Should -Be 0
    }
    It 'rejects changed trusted file <Path> on eligible unmerged DEV source' -ForEach @(
        @{Path='.clc/release.json'},@{Path='.github/workflows/build.yml'},@{Path='.clc/security-helper.ps1'}
    ) {
        Set-UnmergedDevTagFixture
        $script:configuration.trustedFiles+= '.clc/security-helper.ps1'
        foreach ($commit in @($script:sourceCommit,$script:integrationCommit)) {$script:responses['/repos/clcdpc/ssrs-web/contents/.clc/security-helper.ps1?ref='+$commit]=@{type='file';sha='same-blob'}}
        $script:responses['/repos/clcdpc/ssrs-web/contents/'+$Path+'?ref='+$script:sourceCommit].sha='changed'
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
    It 'requires the configured primary branch <Branch> to be protected for unmerged DEV tags' -ForEach @(@{Branch='master'},@{Branch='main'}) {
        Set-UnmergedDevTagFixture
        $script:configuration.integrationBranch=$Branch
        $script:responses['/repos/clcdpc/ssrs-web/branches/'+$Branch]=@{protected=$false;commit=@{sha=$script:integrationCommit}}
        { Get-ClcVerifiedSource $script:configuration 'v1.2.3-dev.1' $script:sourceCommit 123 $script:api } | Should -Throw '*must be protected*'
        $script:responses['/repos/clcdpc/ssrs-web/branches/'+$Branch].protected=$true
        (Get-ClcVerifiedSource $script:configuration 'v1.2.3-dev.1' $script:sourceCommit 123 $script:api).identity.integrationBranch | Should -BeExactly $Branch
        @($script:requests | Where-Object {$_ -match '/branches/' -and $_ -cne ('/repos/clcdpc/ssrs-web/branches/'+$Branch)}).Count | Should -Be 0
    }
}

Describe 'Qualified producer and artifact admission' {
    BeforeEach {
        New-ApplicationReleaseFixture
        Set-UnmergedDevTagFixture
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
    It 'requires the exact configured REST job display name including <Difference>' -ForEach @(
        @{Difference='commas';ActualName='Build test publish and package'},
        @{Difference='case';ActualName='build, test, publish, and package'},
        @{Difference='spaces';ActualName='Build, test, publish, and package '}
    ) {
        $script:configuration.producer.jobName='Build, test, publish, and package'
        $job=$script:responses['/repos/clcdpc/ssrs-web/actions/runs/123/attempts/2/jobs?per_page=100&page=1'].jobs[0]
        $job.name=$script:configuration.producer.jobName
        (Get-ClcVerifiedProducer $script:configuration $script:source 123 2 456 $script:api).buildJob | Should -BeExactly build
        $job.name=$ActualName
        { Get-ClcVerifiedProducer $script:configuration $script:source 123 2 456 $script:api } | Should -Throw '*Exact successful producer job is missing*'
    }
    It 'rejects incorrect unmerged DEV producer or artifact evidence <mode>' -ForEach @(
        @{mode='workflow'},@{mode='attempt'},@{mode='job'},@{mode='stale'},@{mode='run-id'},@{mode='run-attempt'},@{mode='failed-run'},
        @{mode='source'},@{mode='repository'},@{mode='fork'},@{mode='reference'},@{mode='job-run'},@{mode='artifact-id'},@{mode='artifact-run'},@{mode='artifact-source'},@{mode='expired'}
    ) {
        $run=$script:responses['/repos/clcdpc/ssrs-web/actions/runs/123/attempts/2']
        $artifact=$script:responses['/repos/clcdpc/ssrs-web/actions/artifacts/456']
        switch ($mode) {
            run-id {$run.id=124}
            run-attempt {$run.run_attempt=1}
            failed-run {$run.conclusion='failure'}
            source {$run.head_sha='e'*40}
            repository {$run.repository.full_name='external/ssrs-web'}
            fork {$run.head_repository.full_name='external/ssrs-web'}
            reference {$run.head_branch='feature'}
            job-run {$script:responses['/repos/clcdpc/ssrs-web/actions/runs/123/attempts/2/jobs?per_page=100&page=1'].jobs[0].run_id=124}
            artifact-id {$artifact.id=457}
            artifact-run {$artifact.workflow_run.id=124}
            artifact-source {$artifact.workflow_run.head_sha='e'*40}
            expired {$artifact.expired=$true}
        }
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

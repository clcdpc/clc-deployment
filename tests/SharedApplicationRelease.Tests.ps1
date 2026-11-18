BeforeAll {
    . "$PSScriptRoot/../tools/release/Workflow.Common.ps1"
    function New-ApplicationReleaseFixture {
        $script:sourceCommit='a'*40; $script:integrationCommit='b'*40
        $script:configuration=@{contractVersion=3L;applicationId='ssrs-web';repository='clcdpc/ssrs-web';integrationBranch='master';devRuntimeEnvironment='Production';producer=@{workflowPath='.github/workflows/build.yml';job='build'};requiredToolkitContractVersion=3L}
        $script:responses=@{}
        $base='/repos/clcdpc/ssrs-web'
        $script:responses[$base+'/branches/master']=@{protected=$true;commit=@{sha=$script:integrationCommit}}
        $script:responses[$base+'/git/ref/tags/v1.2.3-dev.1']=@{object=@{type='commit';sha=$script:sourceCommit}}
        $script:responses[$base+'/compare/'+$script:sourceCommit+'...'+$script:integrationCommit]=@{status='ahead';merge_base_commit=@{sha=$script:sourceCommit}}
        $script:requests=[Collections.Generic.List[string]]::new()
        $script:api={param($method,$path,$body) $script:requests.Add($path); if (-not $script:responses.ContainsKey($path)) { throw ('Unexpected API '+$path) }; return $script:responses[$path]}
    }
    function Set-UnmergedDevTagFixture {
        $base='/repos/clcdpc/ssrs-web'
        $script:responses[$base+'/compare/'+$script:sourceCommit+'...'+$script:integrationCommit]=@{status='diverged';merge_base_commit=@{sha=('c'*40)}}
    }
    function Get-TestProtectedDeploymentConfiguration([string] $Tag) {
        $repository=$script:configuration.repository
        $sharedRevision='d'*40
        $script:configuration.orchestration=@{sharedRevision=$sharedRevision}
        $contents=[Text.Encoding]::UTF8.GetBytes(($script:configuration | ConvertTo-Json -Depth 4 -Compress))
        $script:responses['/repos/'+$repository+'/contents/.clc/release.json?ref='+$script:sourceCommit]=@{
            type='file';encoding='base64';size=$contents.Length;content=[Convert]::ToBase64String($contents);sha=('f'*40)
        }
        $claims=@{iss='https://token.actions.githubusercontent.com';aud='clc-deployment';repository=$repository;event_name='push';
            workflow_sha=$script:sourceCommit;workflow_ref="$repository/.github/workflows/build.yml@refs/tags/$Tag";
            job_workflow_sha=$sharedRevision;job_workflow_ref="clcdpc/clc-deployment/.github/workflows/application-deploy.yml@$sharedRevision"}
        (Get-ClcProtectedWorkflowConfiguration $claims $repository deploy $TestDrive $script:api).configuration
    }
}

Describe 'Authenticated consumer runtime configuration and deployment routing' {
    BeforeEach { New-ApplicationReleaseFixture }

    It 'loads the documented example with the Production runtime on DEV' {
        $configuration=Read-ClcConsumerConfiguration (Join-Path $PSScriptRoot '../docs/examples/shared-release.json')
        $configuration.devRuntimeEnvironment | Should -BeExactly 'Production'
    }
    It 'routes <Tag> with configured <ConfiguredRuntime> to <Target> using <ExpectedRuntime>' -ForEach @(
        @{Tag='v1.2.3-dev.1';ConfiguredRuntime='Production';Target='ssrs-web-dev';ExpectedRuntime='Production'},
        @{Tag='v1.2.3-dev.1';ConfiguredRuntime='Staging';Target='ssrs-web-dev';ExpectedRuntime='Staging'},
        @{Tag='v1.2.3';ConfiguredRuntime='Production';Target='ssrs-web-production';ExpectedRuntime='Production'},
        @{Tag='v1.2.3';ConfiguredRuntime='Staging';Target='ssrs-web-production';ExpectedRuntime='Production'}
    ) {
        $script:configuration.devRuntimeEnvironment=$ConfiguredRuntime
        $script:responses['/repos/clcdpc/ssrs-web/git/ref/tags/'+$Tag]=@{object=@{type='commit';sha=$script:sourceCommit}}
        $configuration=Get-TestProtectedDeploymentConfiguration $Tag
        $source=Get-ClcVerifiedSource $configuration $Tag $script:sourceCommit 123 $script:api
        $route=Get-ClcDeploymentRoute $configuration $source
        $route.targetId | Should -BeExactly $Target
        $route.environment | Should -BeExactly $Target
        ($route.runnerLabels -join ',') | Should -BeExactly "self-hosted,Windows,X64,$Target"
        $route.runtimeEnvironment | Should -BeExactly $ExpectedRuntime
    }
    It 'rejects a DEV runtime of <Case> before qualifying source or artifacts' -ForEach @(
        @{Case='missing';Value=$null},@{Case='null';Value=$null},@{Case='empty';Value=''},
        @{Case='Development';Value='Development'},@{Case='wrong case';Value='production'},
        @{Case='an array';Value=@('Production')},@{Case='a number';Value=1}
    ) {
        $script:configuration.devRuntimeEnvironment=$Value
        if ($Case -ceq 'missing') { $script:configuration.Remove('devRuntimeEnvironment') }
        { Get-TestProtectedDeploymentConfiguration 'v1.2.3-dev.1' } | Should -Throw -ErrorId 'Clc.InvalidContract*'
        ($script:requests -join ',') | Should -BeExactly ('/repos/clcdpc/ssrs-web/contents/.clc/release.json?ref='+$script:sourceCommit)
    }
}

Describe 'Shared application source eligibility' {
    BeforeEach { New-ApplicationReleaseFixture }
    It 'classifies supported semantic releases independently from deployment authority' -ForEach @(
        @{tag='v1.2.3-dev.1';channel='DEV'},@{tag='v1.2.3-beta.1';channel='ArtifactOnly'},@{tag='v1.2.3-rc.1';channel='ArtifactOnly'},@{tag='v1.2.3';channel='Production'}
    ) { (Get-ClcApplicationTag $tag).channel | Should -BeExactly $channel }
    It 'rejects unsupported Test tags before source lookup or fallback with history <History>' -ForEach @(
        @{History='ahead'},@{History='diverged'},@{History='identical'}
    ) {
        $script:responses['/repos/clcdpc/ssrs-web/compare/'+$script:sourceCommit+'...'+$script:integrationCommit].status=$History
        { Get-ClcApplicationTag 'v1.2.3-test.1' } | Should -Throw -ErrorId 'Clc.InvalidContract*'
        { Get-ClcVerifiedSource $script:configuration 'v1.2.3-test.1' $script:sourceCommit 123 $script:api } | Should -Throw -ErrorId 'Clc.InvalidContract*'
        @($script:requests | Where-Object {$_ -match '/git/ref/tags/|/compare/|/contents/'}).Count | Should -Be 0
    }
    It 'accepts exact SSRS unmerged DEV tag source without PR, review or feature-branch evidence' {
        Set-UnmergedDevTagFixture
        $result=Get-ClcVerifiedSource $script:configuration 'v1.2.3-dev.1' $script:sourceCommit 123 $script:api
        $result.identity.sourceCommit | Should -BeExactly $script:sourceCommit
        $result.identity.sourceCommit | Should -BeExactly $script:sourceCommit
        @($script:requests | Where-Object {$_ -match '/pulls|/collaborators/|/branches/(?!master$)'}).Count | Should -Be 0
    }
    It 'accepts integrated DEV and Production tags anywhere in protected master history' -ForEach @(@{Tag='v1.2.3-dev.1'},@{Tag='v1.2.3'}) {
        $script:responses['/repos/clcdpc/ssrs-web/git/ref/tags/'+$Tag]=@{object=@{type='commit';sha=$script:sourceCommit}}
        (Get-ClcVerifiedSource $script:configuration $Tag $script:sourceCommit 123 $script:api).identity.sourceCommit | Should -BeExactly $script:sourceCommit
    }
    It 'accepts unmerged DEV workflow, script, configuration and shared-pin changes without reading master files' {
        Set-UnmergedDevTagFixture
        (Get-ClcVerifiedSource $script:configuration 'v1.2.3-dev.1' $script:sourceCommit 123 $script:api).identity.sourceCommit | Should -BeExactly $script:sourceCommit
        @($script:requests | Where-Object {$_ -match '/contents/|/pulls|/collaborators/'}).Count | Should -Be 0
    }
    It 'admits a valid DEV commit without a common ancestor while refusing Production' {
        $script:responses['/repos/clcdpc/ssrs-web/compare/'+$script:sourceCommit+'...'+$script:integrationCommit]=$null
        $result=Get-ClcVerifiedSource $script:configuration 'v1.2.3-dev.1' $script:sourceCommit 123 $script:api
        $result.identity.sourceCommit | Should -BeExactly $script:sourceCommit
        $script:responses['/repos/clcdpc/ssrs-web/git/ref/tags/v1.2.3']=@{object=@{type='commit';sha=$script:sourceCommit}}
        { Get-ClcVerifiedSource $script:configuration 'v1.2.3' $script:sourceCommit 123 $script:api } | Should -Throw '*outside the protected integration history*'
    }
    It 'rejects moved tags before source execution' {
        $script:responses['/repos/clcdpc/ssrs-web/git/ref/tags/v1.2.3-dev.1'].object.sha='c'*40
        { Get-ClcVerifiedSource $script:configuration 'v1.2.3-dev.1' $script:sourceCommit 123 $script:api } | Should -Throw '*tag moved*'
    }
    It 'returns complete workflow-only evidence for <Tag> with <History> history' -ForEach @(
        @{Tag='v1.2.3-beta.1';History='integrated'},@{Tag='v1.2.3-rc.1';History='integrated'},
        @{Tag='v1.2.3-beta.1';History='unmerged'},@{Tag='v1.2.3-rc.1';History='unmerged'},
        @{Tag='v1.2.3-beta.1';History='unrelated'},@{Tag='v1.2.3-rc.1';History='unrelated'}
    ) {
        $base='/repos/clcdpc/ssrs-web'
        $script:responses[$base+'/git/ref/tags/'+$Tag]=@{object=@{type='commit';sha=$script:sourceCommit}}
        if ($History -ceq 'unmerged') { Set-UnmergedDevTagFixture }
        if ($History -ceq 'unrelated') { $script:responses[$base+'/compare/'+$script:sourceCommit+'...'+$script:integrationCommit]=$null }
        $source=Get-ClcVerifiedSource $script:configuration $Tag $script:sourceCommit 123 $script:api
        $source.identity.channel | Should -BeExactly ArtifactOnly
        $source.identity.tag | Should -BeExactly $Tag
        $source.identity.releaseId | Should -BeExactly $Tag.Replace('.','-')
        foreach ($value in $source.identity.Values) { $value | Should -Not -BeNullOrEmpty }
        (Get-ClcDeploymentRoute $script:configuration $source).targetId | Should -BeNullOrEmpty
    }
    It 'rejects annotated tag chains beyond five objects without unbounded API calls' {
        $base='/repos/clcdpc/ssrs-web'; $object='c'*40
        $script:responses[$base+'/git/ref/tags/v1.2.3-dev.1']=@{object=@{type='tag';sha=$object}}
        $script:responses[$base+'/git/tags/'+$object]=@{object=@{type='tag';sha=$object}}
        { Get-ClcVerifiedSource $script:configuration 'v1.2.3-dev.1' $script:sourceCommit 123 $script:api } | Should -Throw '*tag moved*'
        @($script:requests | Where-Object {$_ -like '*/git/tags/*'}).Count | Should -Be 5
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
    It 'rejects unmerged <Tag> outside the DEV allowance' -ForEach @(
        @{Tag='v1.2.3'}
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
    It 'keeps immutable source identity stable when the protected branch advances without changing trusted code' {
        $first=Get-ClcVerifiedSource $script:configuration 'v1.2.3-dev.1' $script:sourceCommit 123 $script:api
        $next='d'*40; $base='/repos/clcdpc/ssrs-web'
        $script:responses[$base+'/branches/master'].commit.sha=$next
        $script:responses[$base+'/compare/'+$script:sourceCommit+'...'+$next]=@{status='ahead';merge_base_commit=@{sha=$script:sourceCommit}}
        $second=Get-ClcVerifiedSource $script:configuration 'v1.2.3-dev.1' $script:sourceCommit 123 $script:api
        ($second.identity | ConvertTo-Json -Compress) | Should -BeExactly ($first.identity | ConvertTo-Json -Compress)
    }
    It 'requires master to be protected for unmerged DEV tags' {
        $Branch='master'
        Set-UnmergedDevTagFixture
        $script:configuration.integrationBranch=$Branch
        $script:responses['/repos/clcdpc/ssrs-web/branches/'+$Branch]=@{protected=$false;commit=@{sha=$script:integrationCommit}}
        { Get-ClcVerifiedSource $script:configuration 'v1.2.3-dev.1' $script:sourceCommit 123 $script:api } | Should -Throw '*must be protected*'
        $script:responses['/repos/clcdpc/ssrs-web/branches/'+$Branch].protected=$true
        (Get-ClcVerifiedSource $script:configuration 'v1.2.3-dev.1' $script:sourceCommit 123 $script:api).identity.sourceCommit | Should -BeExactly $script:sourceCommit
        @($script:requests | Where-Object {$_ -match '/branches/' -and $_ -cne ('/repos/clcdpc/ssrs-web/branches/'+$Branch)}).Count | Should -Be 0
    }
}

Describe 'Qualified producer and artifact verification' {
    BeforeEach {
        New-ApplicationReleaseFixture
        Set-UnmergedDevTagFixture
        $script:source=Get-ClcVerifiedSource $script:configuration 'v1.2.3-dev.1' $script:sourceCommit 123 $script:api
        $base='/repos/clcdpc/ssrs-web'
        $script:responses[$base+'/actions/runs/123/attempts/2']=@{id=123;run_attempt=2;status='in_progress';conclusion=$null;head_sha=$script:sourceCommit;repository=@{full_name='clcdpc/ssrs-web'};head_repository=@{full_name='clcdpc/ssrs-web'};path='.github/workflows/build.yml';event='push';head_branch='v1.2.3-dev.1';run_started_at='2026-11-13T00:00:00Z';updated_at='2026-11-13T00:10:00Z'}
        $script:responses[$base+'/actions/runs/123/attempts/2/jobs?per_page=100&page=1']=@{jobs=@(@{name='build';status='completed';conclusion='success';head_sha=$script:sourceCommit;started_at='2026-11-13T00:00:01Z';completed_at='2026-11-13T00:09:00Z';run_id=123})}
        $script:responses[$base+'/actions/artifacts/456']=@{id=456;expired=$false;name=('clc-package-'+$script:sourceCommit+'-123-2');workflow_run=@{id=123;head_sha=$script:sourceCommit};digest=('sha256:'+('d'*64));size_in_bytes=200;created_at='2026-11-13T00:05:00Z'}
    }
    It 'qualifies a completed successful producer while its overall workflow is running' {
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
        @{mode='incomplete-job'},@{mode='job-source'},@{mode='late-artifact'},@{mode='source'},@{mode='repository'},@{mode='fork'},@{mode='reference'},@{mode='job-run'},@{mode='artifact-id'},@{mode='artifact-run'},@{mode='artifact-source'},@{mode='expired'}
    ) {
        $run=$script:responses['/repos/clcdpc/ssrs-web/actions/runs/123/attempts/2']
        $artifact=$script:responses['/repos/clcdpc/ssrs-web/actions/artifacts/456']
        switch ($mode) {
            run-id {$run.id=124}
            run-attempt {$run.run_attempt=1}
            failed-run {$run.conclusion='failure'}
            incomplete-job {$script:responses['/repos/clcdpc/ssrs-web/actions/runs/123/attempts/2/jobs?per_page=100&page=1'].jobs[0].status='in_progress'}
            job-source {$script:responses['/repos/clcdpc/ssrs-web/actions/runs/123/attempts/2/jobs?per_page=100&page=1'].jobs[0].head_sha='e'*40}
            late-artifact {$artifact.created_at='2026-11-13T00:09:01Z'}
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
        $script:release=@{id=42;tag_name='v1.2.3-dev.1';target_commitish=('a'*40);prerelease=$true;draft=$false;immutable=$true;assets=@(@{id=9;name='release.zip';size=$script:asset.length})}
        $script:writes=0
        $script:publishApi={param($method,$path,$body) if ($method -cne 'GET') {$script:writes++; throw 'Unexpected write'}; return $script:release}
        $script:assetHash={param($asset) return $script:asset.sha256}
        $script:upload={param($release,$asset) $script:writes++; throw 'Unexpected upload'}
    }
    It 'preserves identical completed GitHub releases without any writes' {
        $result=Invoke-ClcApplicationPublication $script:identity @($script:asset) $script:publishApi $script:assetHash $script:upload
        $result.status | Should -BeExactly 'Preserved'; $script:writes | Should -Be 0
    }
    It 'rejects a published release with <Field> immutability without any writes' -ForEach @(
        @{Field='false';Value=$false},@{Field='null';Value=$null},@{Field='missing';Value=$null},
        @{Field='string true';Value='true'},@{Field='string false';Value='false'},@{Field='number';Value=1},
        @{Field='array';Value=@($true)},@{Field='empty array';Value=@()},@{Field='object';Value=@{value=$true}}
    ) {
        if ($Field -ceq 'missing') {$script:release.Remove('immutable')} else {$script:release.immutable=$Value}
        { Invoke-ClcApplicationPublication $script:identity @($script:asset) $script:publishApi $script:assetHash $script:upload } | Should -Throw '*Boolean immutable=true*'
        $script:writes | Should -Be 0
        $script:release.assets[0].id | Should -Be 9
    }
    It 'keeps the shared toolkit publisher opt-in behavior for releases without immutability evidence' {
        $script:release.Remove('immutable')
        $shared=@{repository=$script:identity.repository;tag=$script:identity.tag;sourceCommit=$script:identity.sourceCommit;prerelease=$true}
        (Invoke-SharedReleaseGitHubPublication $shared @($script:asset) $script:publishApi $script:assetHash $script:upload).status | Should -BeExactly Preserved
        $script:writes | Should -Be 0
    }
    It 'verifies new final publication with immutable=<Immutable> and preserves the observed assets' -ForEach @(@{Immutable=$true},@{Immutable=$false}) {
        $script:release=$null; $script:finalImmutable=$Immutable
        $script:operations=[Collections.Generic.List[string]]::new()
        $api={
            param($method,$path,$body)
            $script:operations.Add($method+' '+$path)
            if ($method -ceq 'POST') {
                $body.draft | Should -BeTrue
                $script:release=@{id=42;tag_name=$body.tag_name;target_commitish=$body.target_commitish;prerelease=$body.prerelease;draft=$true;immutable=$false;assets=@()}
            }
            if ($method -ceq 'PATCH') { $script:release.draft=$false; $script:release.immutable=$script:finalImmutable }
            if ($path.Contains('/releases?')) {return @()}
            return $script:release
        }
        $upload={param($release,$asset) $release.draft | Should -BeTrue; $script:release.assets=@(@{id=9;name=$asset.name;size=$asset.length})}
        if ($Immutable) {
            (Invoke-ClcApplicationPublication $script:identity @($script:asset) $api $script:assetHash $upload).status | Should -BeExactly Published
            # A repeat of the same tag verifies and preserves the canonical bytes.
            (Invoke-ClcApplicationPublication $script:identity @($script:asset) $api $script:assetHash $script:upload).status | Should -BeExactly Preserved
        } else {
            { Invoke-ClcApplicationPublication $script:identity @($script:asset) $api $script:assetHash $upload } | Should -Throw '*Boolean immutable=true*'
        }
        $script:release.draft | Should -BeFalse
        $script:release.assets[0].id | Should -Be 9
        @($script:operations | Where-Object {$_ -like 'DELETE *'}).Count | Should -Be 0
        @($script:operations | Where-Object {$_ -like 'PATCH *'}).Count | Should -Be 1
        $script:operations | Should -Contain 'GET /repos/clcdpc/ssrs-web/releases/42'
    }
    It 'rejects conflicting completed release bytes without mutation' {
        { Invoke-ClcApplicationPublication $script:identity @($script:asset) $script:publishApi {param($a) 'f'*64} $script:upload } | Should -Throw '*assets conflict*'
        $script:writes | Should -Be 0
    }
    It 'rejects an immutable completed release with conflicting <Field> without mutation' -ForEach @(
        @{Field='tag_name';Value='v1.2.3-dev.2'},@{Field='target_commitish';Value=('b'*40)},@{Field='prerelease';Value=$false}
    ) {
        $script:release[$Field]=$Value
        { Invoke-ClcApplicationPublication $script:identity @($script:asset) $script:publishApi $script:assetHash $script:upload } | Should -Throw '*source or classification conflicts*'
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
    It 'revalidates immutable=<Immutable> on a matching completed creation-race winner' -ForEach @(@{Immutable=$true},@{Immutable=$false}) {
        $script:release.immutable=$Immutable
        $script:created=$false
        $api={
            param($method,$path,$body)
            if ($method -ceq 'POST') {$script:created=$true; throw 'Creation race'}
            if ($path.Contains('/releases?')) {return @()}
            if ($script:created) {return $script:release}
            return $null
        }
        if ($Immutable) {
            (Invoke-ClcApplicationPublication $script:identity @($script:asset) $api $script:assetHash $script:upload).status | Should -BeExactly 'Preserved'
        } else {
            { Invoke-ClcApplicationPublication $script:identity @($script:asset) $api $script:assetHash $script:upload } | Should -Throw '*Boolean immutable=true*'
        }
        $script:writes | Should -Be 0
    }
    It 'resumes a compatible complete draft and rechecks the final API object rather than the PATCH claim' {
        $script:release.draft=$true; $script:release.immutable=$false
        $api={
            param($method,$path,$body)
            if ($method -ceq 'PATCH') {
                $script:writes++; $script:release.draft=$false
                $claim=$script:release.Clone(); $claim.immutable=$true; return $claim
            }
            return $script:release
        }
        { Invoke-ClcApplicationPublication $script:identity @($script:asset) $api $script:assetHash $script:upload } | Should -Throw '*Boolean immutable=true*'
        $script:writes | Should -Be 1
        $script:release.assets[0].id | Should -Be 9
    }
    It 'publishes a resumed complete draft without uploading or replacing canonical assets' {
        $script:release.draft=$true; $script:release.immutable=$false
        $api={param($method,$path,$body) if ($method -ceq 'PATCH') {$script:writes++; $script:release.draft=$false; $script:release.immutable=$true}; return $script:release}
        (Invoke-ClcApplicationPublication $script:identity @($script:asset) $api $script:assetHash $script:upload).status | Should -BeExactly Published
        $script:writes | Should -Be 1
        $script:release.assets[0].id | Should -Be 9
    }
    It 'retains a resumed draft when final publication fails without a published race winner' {
        $script:release.draft=$true; $script:release.immutable=$false
        $api={param($method,$path,$body) if ($method -ceq 'PATCH') {throw 'Publication failed'}; return $script:release}
        { Invoke-ClcApplicationPublication $script:identity @($script:asset) $api $script:assetHash $script:upload } | Should -Throw '*publication failed; compatible draft retained*'
        $script:release.draft | Should -BeTrue
        $script:release.assets[0].id | Should -Be 9
        $script:writes | Should -Be 0
    }
    It 'revalidates immutable=<Immutable> after a competing publisher wins the final PATCH' -ForEach @(@{Immutable=$true},@{Immutable=$false}) {
        $script:release.draft=$true; $script:release.immutable=$Immutable
        $api={param($method,$path,$body) if ($method -ceq 'PATCH') {$script:release.draft=$false; throw 'Publication race'}; return $script:release}
        if ($Immutable) {
            (Invoke-ClcApplicationPublication $script:identity @($script:asset) $api $script:assetHash $script:upload).status | Should -BeExactly Published
        } else {
            { Invoke-ClcApplicationPublication $script:identity @($script:asset) $api $script:assetHash $script:upload } | Should -Throw '*Boolean immutable=true*'
        }
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
    It 'rejects a mutable completed asset-upload race winner without further writes' {
        $script:release.draft=$true; $script:release.assets=@(); $script:uploads=0
        $api={param($method,$path,$body) if ($method -cne 'GET') {throw 'Unexpected write'}; return $script:release}
        $upload={
            param($release,$asset)
            $script:uploads++; $script:release.draft=$false; $script:release.immutable=$false
            $script:release.assets=@(@{id=9;name=$asset.name;size=$asset.length})
            throw 'Upload race'
        }
        { Invoke-ClcApplicationPublication $script:identity @($script:asset) $api $script:assetHash $upload } | Should -Throw '*Boolean immutable=true*'
        $script:uploads | Should -Be 1; $script:writes | Should -Be 0
    }
}


Describe 'Immutable publication digest used by the deployment workflow' {
    BeforeEach {
        $source=@{identity=@{tag='v1.2.3-dev.1';repository='synthetic/probe';channel='DEV'}}
        $inspection=@{archiveSha256=('a'*64)}
        $response=@{tag_name=$source.identity.tag;draft=$false;immutable=$true;prerelease=$true;
            assets=@(@{name='release.zip';state='uploaded';digest=('sha256:'+$inspection.archiveSha256)})}
        $releaseApi={param($method,$url,$body) $response}
    }
    It 'uses the exact SHA-256 returned by GitHub' {
        Assert-ClcPublishedPackage $source $inspection $releaseApi | Should -BeExactly $inspection.archiveSha256
    }
    It 'rejects <Case> before passing a digest to deployment' -ForEach @(
        @{Case='mutable release'},@{Case='draft'},@{Case='wrong digest'},@{Case='duplicate assets'}
    ) {
        switch ($Case) {
            'mutable release' { $response.immutable=$false }
            draft { $response.draft=$true }
            'wrong digest' { $response.assets[0].digest='sha256:'+('b'*64) }
            'duplicate assets' { $response.assets+=@($response.assets[0]) }
        }
        { Assert-ClcPublishedPackage $source $inspection $releaseApi } | Should -Throw
    }
}

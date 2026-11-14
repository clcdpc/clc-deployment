BeforeAll {
    . "$PSScriptRoot/Support.ps1"
    . "$script:RepositoryRoot/tools/release/Workflow.Common.ps1"
    . "$script:RepositoryRoot/tools/Distribution.Common.ps1"
    # A clean committed copy permits the real package entry point to build its
    # toolkit distribution, even while this checkout has uncommitted changes.
    $script:machineryWorkspace=New-TestWorkspace
    $script:machinery=Join-Path $script:machineryWorkspace 'repo'
    $null=[IO.Directory]::CreateDirectory((Join-Path $script:machinery 'src'))
    Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'src/CLC.Deployment') -Destination (Join-Path $script:machinery 'src') -Recurse
    Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'tools') -Destination $script:machinery -Recurse
    Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'VERSION') -Destination $script:machinery
    foreach ($arguments in @(
        @('init','--initial-branch=codex/offline-fixture'),@('config','user.name','CLC Offline Fixture'),
        @('config','user.email','fixture@example.invalid'),@('config','core.autocrlf','false'),@('add','.'),@('commit','-m','Exact offline machinery')
    )) { $null=Get-DistGit $script:machinery $arguments }
    $script:sharedCommit=Get-DistGit $script:machinery @('rev-parse','HEAD')
    function New-EntrypointFixture([string] $Reference='v1.2.3-dev.1',[switch] $Superseded,
        [string] $ProducerWorkflowPath='.github/workflows/build.yml',[string] $ProducerJob='build',[string] $ProducerJobName='package / build') {
        $script:workspace=New-TestWorkspace
        $script:sourceCommit='a'*40; $script:caller='b'*40
        # Script/module mock scopes share only this explicitly named test state.
        $global:ClcWorkflowEntry=@{sourceCommit=$script:sourceCommit;release=$null;uploaded=$null}
        $script:integration=if ($Superseded) {'e'*40} else {$script:sourceCommit}
        $script:reference=$Reference; $script:configurationBlob='d'*40
        $script:configuration=@{contractVersion=1L;applicationId='probe';repository='clcdpc/example';integrationBranch='master';
            sourcePolicy=@{allowPrDev=$true;allowSnapshots=$true;allowTestTags=$true};producer=@{workflowPath=$ProducerWorkflowPath;job=$ProducerJob;jobName=$ProducerJobName};
            trustedFiles=@('.clc/release.json',$ProducerWorkflowPath,'.github/workflows/deploy.yml');requiredToolkitContractVersion=2L;
            orchestration=@{sharedRevision=$script:sharedCommit;deploymentWorkflowPath='.github/workflows/deploy.yml'};
            targets=@(@{channel='DEV';targetId='probe-dev';environment='probe-dev';runnerGroup='probe-dev';runnerLabels=@('self-hosted','Windows','X64','probe-dev');standingAuthorizationId='probe-dev';enabled=$true;runnerAdmissionReady=$true},
                @{channel='Production';targetId='probe-production';environment='probe-production';runnerGroup='probe-production';runnerLabels=@('self-hosted','Windows','X64','probe-production');standingAuthorizationId='probe-production';enabled=$false;runnerAdmissionReady=$false})}
        $script:claims=@{iss='https://token.actions.githubusercontent.com';aud='clc-deployment';repository=$script:configuration.repository;
            workflow_ref='clcdpc/example/.github/workflows/deploy.yml@refs/heads/master';workflow_sha=$script:caller;
            job_workflow_ref=('clcdpc/clc-deployment/.github/workflows/application-deploy.yml@'+$script:sharedCommit);job_workflow_sha=$script:sharedCommit;event_name='workflow_run';actor='operator';environment='probe-dev'}
        $script:responses=@{}; $base='/repos/clcdpc/example'
        $script:responses[$base+'/branches/master']=@{protected=$true;commit=@{sha=$script:integration}}
        foreach ($commit in @($script:caller,$script:sourceCommit,$script:integration)) {
            foreach ($path in $script:configuration.trustedFiles) { $script:responses[$base+'/contents/'+$path+'?ref='+$commit]=@{type='file';sha=('f'*40)} }
        }
        $content=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($script:configuration | ConvertTo-Json -Depth 12)))
        foreach ($commit in @($script:caller,$script:sourceCommit,$script:integration)) {
            $script:responses[$base+'/contents/.clc/release.json?ref='+$commit]=@{type='file';sha=$script:configurationBlob;encoding='base64';size=2000;content=$content}
        }
        $script:responses[$base+'/git/ref/tags/'+$Reference]=@{object=@{type='commit';sha=$script:sourceCommit}}
        $script:responses[$base+'/compare/'+$script:sourceCommit+'...'+$script:integration]=@{status='ahead';merge_base_commit=@{sha=$script:sourceCommit}}
        $branch=if ($Reference.StartsWith('refs/heads/')) {'master'} else {$Reference}
        $script:responses[$base+'/actions/runs/123/attempts/2']=@{id=123L;run_attempt=2L;status='completed';conclusion='success';head_sha=$script:sourceCommit;repository=@{full_name='clcdpc/example'};head_repository=@{full_name='clcdpc/example'};path=$ProducerWorkflowPath;event='push';head_branch=$branch;run_started_at='2026-11-13T00:00:00Z';updated_at='2026-11-13T00:10:00Z'}
        $script:responses[$base+'/actions/runs/123/attempts/2/jobs?per_page=100&page=1']=@{jobs=@(@{name=$ProducerJobName;status='completed';conclusion='success';run_id=123L})}
        $script:inputs=New-TestPublish $script:workspace
        $metadata=Get-TestMetadata; $metadata.schemaVersion=2L; $metadata.changeKind='application-deployment'
        $metadata.source=@{repository=$script:configuration.repository;commit=$script:sourceCommit}
        $metadata.releaseId=if ($Reference.StartsWith('refs/heads/')) {'dev-123-'+$script:sourceCommit.Substring(0,12)} else {(Get-ClcApplicationTag $Reference).releaseId}
        $metadata.build.runId=123L; $metadata.build.runAttempt=2L; $metadata.build.dependencyLockSha256=$null
        $metadata.build.workflowPath=$ProducerWorkflowPath; $metadata.build.job=$ProducerJob; $metadata.builder.sourceCommit=$script:sharedCommit
        Write-TestJson $script:inputs.MetadataPath $metadata
        $script:package=New-ClcRelease @script:inputs
        Set-EntrypointArtifact
        $script:parameters=@{Action='Admit';ClaimsJson=($script:claims | ConvertTo-Json -Compress);Repository='clcdpc/example';Reference=$Reference;
            SourceCommit=$script:sourceCommit;RunId=123L;RunAttempt=2L;OutputDirectory=(Join-Path $script:workspace 'workflow')}
        $script:oldOutput=$env:GITHUB_OUTPUT; $script:oldSummary=$env:GITHUB_STEP_SUMMARY
        $env:GITHUB_OUTPUT=Join-Path $script:workspace 'github-output.txt'; $env:GITHUB_STEP_SUMMARY=Join-Path $script:workspace 'step-summary.md'
        $script:release=$null; $script:uploaded=$null
    }
    function Set-EntrypointArtifact {
        $transport=Join-Path $script:workspace ([guid]::NewGuid().ToString('N')+'.zip')
        New-TestZip $transport @(@{name='release.zip';bytes=[IO.File]::ReadAllBytes($script:package.archivePath)})
        $script:transport=[IO.File]::ReadAllBytes($transport)
        $name='clc-package-'+$script:sourceCommit+'-123-2'; $base='/repos/clcdpc/example'
        $script:responses[$base+'/actions/runs/123/artifacts?per_page=100&page=1']=@{artifacts=@(@{id=456L;name=$name},@{id=455L;name='old-attempt'})}
        $script:responses[$base+'/actions/artifacts/456']=@{id=456L;expired=$false;name=$name;workflow_run=@{id=123L;head_sha=$script:sourceCommit};digest=('sha256:'+(Get-FileHash -LiteralPath $transport -Algorithm SHA256).Hash.ToLowerInvariant());size_in_bytes=$script:transport.Length;created_at='2026-11-13T00:05:00Z'}
        $global:ClcWorkflowEntry.responses=$script:responses; $global:ClcWorkflowEntry.transport=$script:transport; $global:ClcWorkflowEntry.package=$script:package
    }
    function Remove-EntrypointFixture {
        $env:GITHUB_OUTPUT=$script:oldOutput; $env:GITHUB_STEP_SUMMARY=$script:oldSummary
        # Package tests import the exact committed fixture module. Restore the
        # checkout module before removing that fixture and running other tests.
        Get-Module CLC.Deployment | Remove-Module -Force
        Import-Module $script:ModulePath -Force
        @(Get-Module CLC.Deployment).Count | Should -Be 1
        (Get-Module CLC.Deployment).ModuleBase | Should -BeExactly (Split-Path $script:ModulePath -Parent)
        Remove-TestWorkspace $script:workspace
        Remove-Variable -Name ClcWorkflowEntry -Scope Global
    }
}
AfterAll { Remove-TestWorkspace $script:machineryWorkspace }

Describe 'Actual shared workflow entry point with offline GitHub boundaries' {
    BeforeEach {
        New-EntrypointFixture
        Mock Send-SharedReleaseHttpRequest { throw 'Live network is forbidden in entry-point tests.' }
        Mock Invoke-ClcReleaseApi {
            param($Repository,$Method,$Path,$Body,[switch]$Bytes)
            $Repository | Should -BeExactly 'clcdpc/example'
            if ($Path -ceq '/repos/clcdpc/example/actions/artifacts/456/zip') { $Bytes | Should -BeTrue; return ,$global:ClcWorkflowEntry.transport }
            if ($Path -ceq '/repos/clcdpc/example/releases/assets/9') { $Bytes | Should -BeTrue; return ,$global:ClcWorkflowEntry.uploaded }
            if ($Path -ceq '/repos/clcdpc/example/releases/tags/v1.2.3-dev.1') { return $global:ClcWorkflowEntry.release }
            if ($Path -ceq '/repos/clcdpc/example/releases?per_page=100&page=1') { return @() }
            if ($Method -ceq 'POST' -and $Path -ceq '/repos/clcdpc/example/releases') {
                $Body.target_commitish | Should -BeExactly $global:ClcWorkflowEntry.sourceCommit; $Body.draft | Should -BeTrue
                $global:ClcWorkflowEntry.release=@{id=42L;tag_name=$Body.tag_name;target_commitish=$Body.target_commitish;prerelease=$Body.prerelease;draft=$true;assets=@()}
                return $global:ClcWorkflowEntry.release
            }
            if ($Path -ceq '/repos/clcdpc/example/releases/42') {
                if ($Method -ceq 'PATCH') { $Body.draft | Should -BeFalse; $global:ClcWorkflowEntry.release.draft=$false }
                return $global:ClcWorkflowEntry.release
            }
            if ($Method -cne 'GET' -or -not $global:ClcWorkflowEntry.responses.ContainsKey($Path)) { throw ('Unexpected offline API call: '+$Method+' '+$Path) }
            return $global:ClcWorkflowEntry.responses[$Path]
        }
        Mock Send-ClcApplicationReleaseAsset {
            param($Repository,$Release,$Asset)
            $Asset.name | Should -BeExactly 'release.zip'; $Release.draft | Should -BeTrue
            $global:ClcWorkflowEntry.uploaded=[IO.File]::ReadAllBytes($Asset.path)
            $global:ClcWorkflowEntry.release.assets=@(@{id=9L;name=$Asset.name;size=$Asset.length})
        }
        Mock Open-ClcWorkflowToolkit { throw 'Unexpected privileged toolkit access.' }
    }
    AfterEach { Remove-EntrypointFixture }
    It 'publishes a verified release through the real imports, producer checks and publication orchestration' {
        $script:parameters.Action='Release'
        $script:claims.job_workflow_ref='clcdpc/clc-deployment/.github/workflows/application-release.yml@'+$script:sharedCommit
        $script:parameters.ClaimsJson=$script:claims | ConvertTo-Json -Compress
        $result=& "$script:RepositoryRoot/tools/release/Invoke-ClcApplicationWorkflow.ps1" @script:parameters
        $result.status | Should -BeExactly Published; $global:ClcWorkflowEntry.release.draft | Should -BeFalse
        (Get-DistHash $global:ClcWorkflowEntry.uploaded) | Should -BeExactly $script:package.archiveSha256
        Should -Invoke Send-ClcApplicationReleaseAsset -Times 1 -Exactly
        Should -Invoke Open-ClcWorkflowToolkit -Times 0 -Exactly
    }
    It 'admits the exact qualified artifact and writes protected routing outputs' {
        $result=& "$script:RepositoryRoot/tools/release/Invoke-ClcApplicationWorkflow.ps1" @script:parameters
        $result.status | Should -BeExactly Admitted; $result.admitted | Should -BeTrue
        $output=[IO.File]::ReadAllText($env:GITHUB_OUTPUT)
        $output | Should -Match '(?m)^admitted=true$'
        $output | Should -Match '(?m)^artifact_id=456$'
        $output | Should -Match '(?m)^target_id=probe-dev$'
        $output | Should -Match ('(?m)^configuration_blob='+$script:configurationBlob+'$')
        $output | Should -Match '(?m)^runner_labels=\["self-hosted","Windows","X64","probe-dev"\]$'
        Should -Invoke Invoke-ClcReleaseApi -Times 2 -Exactly -ParameterFilter { $Path -ceq '/repos/clcdpc/example/actions/runs/123/attempts/2' }
        Should -Invoke Open-ClcWorkflowToolkit -Times 0 -Exactly
    }
    It 'admits the observed <Consumer> producer workflow, job ID and exact REST display name' -ForEach @(
        @{Consumer='Favorite Authors';WorkflowPath='.github/workflows/build-test.yml';JobName='Build, test, publish, and package'},
        @{Consumer='ASAP';WorkflowPath='.github/workflows/dotnet.yml';JobName='Frontend, CI checks and package'}
    ) {
        Remove-EntrypointFixture
        New-EntrypointFixture -ProducerWorkflowPath $WorkflowPath -ProducerJob build-test-package -ProducerJobName $JobName
        $result=& "$script:RepositoryRoot/tools/release/Invoke-ClcApplicationWorkflow.ps1" @script:parameters
        $result.status | Should -BeExactly Admitted; $result.admitted | Should -BeTrue
        [IO.File]::ReadAllText($env:GITHUB_OUTPUT) | Should -Match '(?m)^admitted=true$'
        Should -Invoke Open-ClcWorkflowToolkit -Times 0 -Exactly
    }
    It 'rejects an otherwise verified package with an unapproved builder revision during <Action>' -ForEach @(
        @{Action='Release'},@{Action='Admit'},@{Action='Deploy'}
    ) {
        $metadata=Get-Content -LiteralPath $script:inputs.MetadataPath -Raw | ConvertFrom-Json -AsHashtable
        $metadata.builder.sourceCommit='e'*40; Write-TestJson $script:inputs.MetadataPath $metadata
        [IO.File]::Delete($script:package.archivePath); $script:package=New-ClcRelease @script:inputs
        (Test-ClcRelease $script:package.archivePath).integrityVerified | Should -BeTrue
        Set-EntrypointArtifact
        $script:parameters.Action=$Action
        if ($Action -ceq 'Release') { $script:claims.job_workflow_ref='clcdpc/clc-deployment/.github/workflows/application-release.yml@'+$script:sharedCommit }
        $script:parameters.ClaimsJson=$script:claims | ConvertTo-Json -Compress
        $script:parameters.ExpectedConfigurationBlob=$script:configurationBlob
        $script:heldToolkit=[IO.MemoryStream]::new(); $global:ClcWorkflowEntry.heldToolkit=$script:heldToolkit
        Mock Open-ClcWorkflowToolkit { return @{policy=@{};handles=@($global:ClcWorkflowEntry.heldToolkit)} }
        if ($Action -ceq 'Deploy') {
            Mock Open-ClcTrustedContext { throw 'Unexpected host admission.' } -ModuleName CLC.Deployment
            Mock Invoke-ClcIisDeployment { throw 'Unexpected deployment.' }
        }
        try {
            { & "$script:RepositoryRoot/tools/release/Invoke-ClcApplicationWorkflow.ps1" @script:parameters } | Should -Throw '*Package builder revision differs from protected orchestration.sharedRevision*'
            [IO.File]::Exists($env:GITHUB_OUTPUT) | Should -BeFalse
            Should -Invoke Send-ClcApplicationReleaseAsset -Times 0 -Exactly
            $global:ClcWorkflowEntry.release | Should -BeNullOrEmpty
            if ($Action -ceq 'Deploy') {
                Should -Invoke Open-ClcTrustedContext -Times 0 -Exactly -ModuleName CLC.Deployment
                Should -Invoke Invoke-ClcIisDeployment -Times 0 -Exactly
                $script:heldToolkit.CanRead | Should -BeFalse
            } else { Should -Invoke Open-ClcWorkflowToolkit -Times 0 -Exactly }
        } finally { $script:heldToolkit.Dispose() }
    }
    It 'returns <Status> without downloading or invoking infrastructure' -ForEach @(
        @{Reference='v1.2.3';Status='ActivationDisabled';Superseded=$false},
        @{Reference='refs/heads/master';Status='Superseded';Superseded=$true}
    ) {
        Remove-EntrypointFixture
        New-EntrypointFixture -Reference $Reference -Superseded:$Superseded
        $result=& "$script:RepositoryRoot/tools/release/Invoke-ClcApplicationWorkflow.ps1" @script:parameters
        $result.status | Should -BeExactly $Status; $result.admitted | Should -BeFalse
        [IO.File]::ReadAllText($env:GITHUB_OUTPUT) | Should -Match '(?m)^admitted=false$'
        Should -Invoke Invoke-ClcReleaseApi -Times 0 -Exactly -ParameterFilter { $Bytes }
        Should -Invoke Open-ClcWorkflowToolkit -Times 0 -Exactly
    }
    It 'rejects <Mode> before privileged operations or publication' -ForEach @(
        @{Mode='moved source';ErrorPattern='*tag moved*'},@{Mode='failed producer';ErrorPattern='*Producer run identity*'},
        @{Mode='artifact transport';ErrorPattern='*digest differs*'},@{Mode='modified package';ErrorPattern='*Release inspection failed*'},
        @{Mode='invalid lock evidence';ErrorPattern='*Release inspection failed*'},@{Mode='package producer';ErrorPattern='*qualified source and producer*'},
        @{Mode='queued authorization';ErrorPattern='*configuration changed while queued*'},@{Mode='job environment';ErrorPattern='*environment differs*'}
    ) {
        switch ($Mode) {
            'moved source' { $script:responses['/repos/clcdpc/example/git/ref/tags/v1.2.3-dev.1'].object.sha='e'*40 }
            'failed producer' { $script:responses['/repos/clcdpc/example/actions/runs/123/attempts/2'].conclusion='failure' }
            'artifact transport' { $script:responses['/repos/clcdpc/example/actions/artifacts/456'].digest='sha256:'+('e'*64) }
            'modified package' {
                $entries=@(Get-TestZipEntries $script:package.archivePath)
                ($entries | Where-Object name -CEQ 'application/Probe.dll').bytes=[Text.Encoding]::UTF8.GetBytes('modified qualified files')
                [IO.File]::Delete($script:package.archivePath); New-TestZip $script:package.archivePath $entries
                Set-EntrypointArtifact
            }
            'package producer' {
                $metadata=Get-Content -LiteralPath $script:inputs.MetadataPath -Raw | ConvertFrom-Json -AsHashtable
                $metadata.build.job='unqualified'; Write-TestJson $script:inputs.MetadataPath $metadata
                [IO.File]::Delete($script:package.archivePath); $script:package=New-ClcRelease @script:inputs
                Set-EntrypointArtifact
            }
            'invalid lock evidence' {
                $entries=@(Get-TestZipEntries $script:package.archivePath)
                $manifest=[Text.Encoding]::UTF8.GetString($entries[0].bytes) | ConvertFrom-Json -AsHashtable
                $manifest.build.dependencyLockSha256='independent-ci-evidence'
                $entries[0].bytes=[Text.Encoding]::UTF8.GetBytes(($manifest | ConvertTo-Json -Depth 16))
                [IO.File]::Delete($script:package.archivePath); New-TestZip $script:package.archivePath $entries
                Set-EntrypointArtifact
            }
            'queued authorization' { $script:parameters.Action='Deploy'; $script:parameters.ExpectedConfigurationBlob='e'*40 }
            'job environment' {
                $script:parameters.Action='Deploy'; $script:parameters.ExpectedConfigurationBlob=$script:configurationBlob
                $script:claims.environment='probe-production'; $script:parameters.ClaimsJson=$script:claims | ConvertTo-Json -Compress
            }
        }
        { & "$script:RepositoryRoot/tools/release/Invoke-ClcApplicationWorkflow.ps1" @script:parameters } | Should -Throw $ErrorPattern
        Should -Invoke Open-ClcWorkflowToolkit -Times 0 -Exactly
        Should -Invoke Send-ClcApplicationReleaseAsset -Times 0 -Exactly
    }
    It 'hands verified bytes and ValidateOnly to the installed engine through mocked infrastructure' {
        $script:parameters.Action='Deploy'; $script:parameters.ExpectedConfigurationBlob=$script:configurationBlob; $script:parameters.Operation='ValidateOnly'
        $script:inbox=Join-Path $script:workspace 'inbox'; $null=[IO.Directory]::CreateDirectory($script:inbox)
        $script:heldToolkit=[IO.MemoryStream]::new()
        $global:ClcWorkflowEntry.inbox=$script:inbox; $global:ClcWorkflowEntry.heldToolkit=$script:heldToolkit
        Mock Open-ClcWorkflowToolkit { return @{policy=@{};handles=@($global:ClcWorkflowEntry.heldToolkit)} }
        Mock Open-ClcTrustedContext -ModuleName CLC.Deployment { return @{} }
        Mock Read-ClcProtectedTarget -ModuleName CLC.Deployment { return @{record=@{targetId='probe-dev';applicationId='probe';artifactInboxRoot=$global:ClcWorkflowEntry.inbox;runtimeIdentitySid='S-1-5-21-1-2-3-2001'}} }
        Mock Add-ClcProtectedPathPin -ModuleName CLC.Deployment {}
        Mock Close-ClcTrustedContext -ModuleName CLC.Deployment {}
        Mock Invoke-ClcIisDeployment {
            param($TargetId,$StandingAuthorizationId,$ReleaseTag,$ArchivePath,$VerifiedReleasePath,$Operation)
            $TargetId | Should -BeExactly probe-dev; $StandingAuthorizationId | Should -BeExactly probe-dev
            $ReleaseTag | Should -BeExactly v1.2.3-dev.1; $Operation | Should -BeExactly ValidateOnly
            (Test-ClcRelease $ArchivePath).archiveSha256 | Should -BeExactly $global:ClcWorkflowEntry.package.archiveSha256
            $identity=Get-Content -LiteralPath $VerifiedReleasePath -Raw | ConvertFrom-Json -AsHashtable
            $identity.sourceCommit | Should -BeExactly $global:ClcWorkflowEntry.sourceCommit; $identity.provenance.artifactId | Should -Be 456
            return @{status='Planned';releaseId=$identity.releaseId}
        }
        $result=& "$script:RepositoryRoot/tools/release/Invoke-ClcApplicationWorkflow.ps1" @script:parameters
        $result.status | Should -BeExactly Planned
        (Get-Content -LiteralPath (Join-Path $script:parameters.OutputDirectory 'deployment-summary.json') -Raw | ConvertFrom-Json).status | Should -BeExactly Planned
        [IO.File]::ReadAllText($env:GITHUB_STEP_SUMMARY) | Should -Match 'Planned'
        $script:heldToolkit.CanRead | Should -BeFalse
        Should -Invoke Invoke-ClcIisDeployment -Times 1 -Exactly
    }
}

Describe 'Actual package entry point with independently qualified publish files' {
    BeforeEach {
        New-EntrypointFixture
        Write-TestJson (Join-Path $script:workspace 'release.json') $script:configuration
        $script:packageParameters=@{ConfigurationPath=(Join-Path $script:workspace 'release.json');SourceRoot=$script:workspace;Reference=$script:reference;
            SourceCommit=$script:sourceCommit;SharedSourceCommit=$script:sharedCommit;RunId=123L;RunAttempt=2L;
            QualifiedPublishRoot=$script:inputs.PublishRoot;SdkVersion='10.0.403';ValidationEntryPoint='Probe.dll';OutputDirectory=(Join-Path $script:workspace 'package-output')}
        Mock Send-SharedReleaseHttpRequest { throw 'Live network is forbidden in package tests.' }
        Mock Invoke-ClcReleaseApi {
            param($Repository,$Method,$Path,$Body,[switch]$Bytes)
            if ($Method -cne 'GET' -or -not $global:ClcWorkflowEntry.responses.ContainsKey($Path)) { throw ('Unexpected offline API call: '+$Method+' '+$Path) }
            return $global:ClcWorkflowEntry.responses[$Path]
        }
    }
    AfterEach { Remove-EntrypointFixture }
    It 'produces exact metadata, real toolkit identity and a verified ZIP with lock present=<WithLock>' -ForEach @(@{WithLock=$true},@{WithLock=$false}) {
        $lock=Join-Path $script:workspace 'packages.lock.json'
        if ($WithLock) { [IO.File]::WriteAllText($lock,'{"version":1,"dependencies":{}}') }
        $before=Get-TestTreeHashes $script:inputs.PublishRoot
        $entry=Join-Path $script:machinery 'tools/release/New-ClcApplicationPackage.ps1'
        (Get-FileHash -LiteralPath $entry).Hash | Should -BeExactly (Get-FileHash -LiteralPath (Join-Path $script:RepositoryRoot 'tools/release/New-ClcApplicationPackage.ps1')).Hash
        $result=& $entry @script:packageParameters
        $inspection=Test-ClcRelease $result.archivePath
        $inspection.integrityVerified | Should -BeTrue; $inspection.packageContractVersion | Should -Be 2
        $metadata=Get-Content -LiteralPath (Join-Path $script:packageParameters.OutputDirectory 'metadata.json') -Raw | ConvertFrom-Json -AsHashtable
        $manifest=[Text.Encoding]::UTF8.GetString(@(Get-TestZipEntries $result.archivePath | Where-Object name -CEQ 'manifest.json')[0].bytes) | ConvertFrom-Json -AsHashtable
        $expected=if ($WithLock) {(Get-FileHash -LiteralPath $lock -Algorithm SHA256).Hash.ToLowerInvariant()} else {$null}
        foreach ($record in @($metadata,$manifest)) {
            $record.build.dependencyLockSha256 | Should -Be $expected
            $record.source.repository | Should -BeExactly 'clcdpc/example'; $record.source.commit | Should -BeExactly $script:sourceCommit
            $record.build.workflowPath | Should -BeExactly '.github/workflows/build.yml'; $record.build.job | Should -BeExactly build
            $record.build.runId | Should -Be 123; $record.build.runAttempt | Should -Be 2; $record.build.sdkVersion | Should -BeExactly '10.0.403'
            $record.validation.entryPoint | Should -BeExactly Probe.dll; $record.builder.sourceCommit | Should -BeExactly $script:configuration.orchestration.sharedRevision
            $record.builder.distributionSha256 | Should -BeExactly (Get-FileHash -LiteralPath (Join-Path $script:packageParameters.OutputDirectory 'toolkit.zip') -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        (Get-TestTreeHashes $script:inputs.PublishRoot) | Should -BeExactly $before
        $output=[IO.File]::ReadAllText($env:GITHUB_OUTPUT)
        $output | Should -Match ('(?m)^artifact_name=clc-package-'+$script:sourceCommit+'-123-2$')
        $output | Should -Match ('(?m)^artifact_path='+[regex]::Escape((Join-Path $script:packageParameters.OutputDirectory 'qualified'))+'$')
        # No SDK provisioning or build outputs are created on this path.
        [IO.Directory]::Exists((Join-Path $script:packageParameters.OutputDirectory 'sdk')) | Should -BeFalse
    }
    It 'rejects an unapproved shared builder revision before <Mode> package work' -ForEach @(@{Mode='Prequalified'},@{Mode='Build'}) {
        $script:configuration.orchestration.sharedRevision='e'*40
        if ($Mode -ceq 'Build') {
            $script:configuration.project='Probe.csproj'
            foreach ($name in @('QualifiedPublishRoot','SdkVersion','ValidationEntryPoint')) { $script:packageParameters.Remove($name) }
        }
        Write-TestJson $script:packageParameters.ConfigurationPath $script:configuration
        { & "$script:machinery/tools/release/New-ClcApplicationPackage.ps1" @script:packageParameters } | Should -Throw '*Shared builder revision must match consumer orchestration.sharedRevision*'
        [IO.Directory]::Exists($script:packageParameters.OutputDirectory) | Should -BeFalse
        [IO.File]::Exists($env:GITHUB_OUTPUT) | Should -BeFalse
        Should -Invoke Invoke-ClcReleaseApi -Times 0 -Exactly
    }
    It 'rejects <Mode> without producing or advertising a release ZIP' -ForEach @(
        @{Mode='invalid SDK'},@{Mode='invalid validator'},@{Mode='missing web.config'},@{Mode='missing producer identity'},@{Mode='missing source identity'},@{Mode='missing shared pin'}
    ) {
        switch ($Mode) {
            'invalid SDK' {$script:packageParameters.SdkVersion='latest'}
            'invalid validator' {$script:packageParameters.ValidationEntryPoint='../Probe.dll'}
            'missing web.config' {[IO.File]::Delete((Join-Path $script:inputs.PublishRoot 'web.config'))}
            'missing producer identity' {$script:configuration.producer.Remove('job'); Write-TestJson $script:packageParameters.ConfigurationPath $script:configuration}
            'missing source identity' {$script:packageParameters.SourceCommit=''}
            'missing shared pin' {$script:configuration.Remove('orchestration'); Write-TestJson $script:packageParameters.ConfigurationPath $script:configuration}
        }
        { & "$script:machinery/tools/release/New-ClcApplicationPackage.ps1" @script:packageParameters } | Should -Throw
        [IO.File]::Exists((Join-Path $script:packageParameters.OutputDirectory 'qualified/release.zip')) | Should -BeFalse
        [IO.File]::Exists($env:GITHUB_OUTPUT) | Should -BeFalse
    }
}

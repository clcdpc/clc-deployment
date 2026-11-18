BeforeAll {
    . "$PSScriptRoot/../tools/release/Workflow.Common.ps1"
    function New-WorkflowFixture {
        $script:shared='c'*40; $script:caller='a'*40; $script:integration='b'*40
        $script:claims=@{iss='https://token.actions.githubusercontent.com';aud='clc-deployment';repository='clcdpc/example';workflow_ref='clcdpc/example/.github/workflows/build.yml@refs/tags/v1.2.3-dev.1';workflow_sha=$script:caller;job_workflow_ref=('clcdpc/clc-deployment/.github/workflows/application-deploy.yml@'+$script:shared);job_workflow_sha=$script:shared;event_name='push';run_id='123';run_attempt='2'}
        $script:configuration=@{contractVersion=2L;applicationId='example';repository='clcdpc/example';integrationBranch='master';producer=@{workflowPath='.github/workflows/build.yml';job='build';jobName='package / build'};requiredToolkitContractVersion=2L;orchestration=@{sharedRevision=$script:shared}}
        $base='/repos/clcdpc/example'; $script:responses=@{}
        $script:responses[$base+'/branches/master']=@{protected=$true;commit=@{sha=$script:integration}}
        $script:responses[$base+'/git/ref/tags/v1.2.3-dev.1']=@{object=@{type='commit';sha=$script:caller}}
        $script:responses[$base+'/compare/'+$script:caller+'...'+$script:integration]=@{status='diverged';merge_base_commit=@{sha=('d'*40)}}
        Set-WorkflowConfigurationResponse
        $script:api={param($method,$path,$body,[switch]$Bytes) if (-not $script:responses.ContainsKey($path)) { throw ('Unexpected API '+$path) }; return $script:responses[$path]}
        $script:source=@{identity=@{channel='DEV';sourceClass='UnmergedDevTag'}}
    }
    function Set-WorkflowConfigurationResponse {
        $content=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($script:configuration | ConvertTo-Json -Depth 12 -Compress)))
        $script:responses['/repos/clcdpc/example/contents/.clc/release.json?ref='+$script:caller]=@{type='file';sha=('d'*40);encoding='base64';size=100;content=$content}
    }
}
Describe 'Tagged application workflow identity and conventional routing' {
    BeforeEach { New-WorkflowFixture }
    It 'accepts unmerged DEV caller configuration and an immutable shared pin selected by that tag' {
        $result=Get-ClcProtectedWorkflowConfiguration $script:claims 'clcdpc/example' deploy $TestDrive $script:api
        $result.configuration.applicationId | Should -BeExactly example
        Assert-ClcWorkflowSource $script:claims $result.configuration 'v1.2.3-dev.1' $script:caller 123 2
    }
    It 'rejects mutable reusable refs, changed shared revisions and caller repositories' -ForEach @(@{Kind='ref'},@{Kind='revision'},@{Kind='repository'}) {
        switch ($Kind) {
            ref {$script:claims.job_workflow_ref='clcdpc/clc-deployment/.github/workflows/application-deploy.yml@master'}
            revision {$script:claims.job_workflow_sha='e'*40}
            repository {$script:claims.repository='external/example'}
        }
        { Get-ClcProtectedWorkflowConfiguration $script:claims 'clcdpc/example' deploy $TestDrive $script:api } | Should -Throw '*identity refused*'
    }
    It 'rejects non-tag caller references and manual or workflow_run release events' -ForEach @(@{Kind='branch'},@{Kind='PR'},@{Kind='manual'},@{Kind='workflow_run'}) {
        switch ($Kind) {
            branch {$script:claims.workflow_ref='clcdpc/example/.github/workflows/build.yml@refs/heads/master'}
            PR {$script:claims.workflow_ref='clcdpc/example/.github/workflows/build.yml@refs/pull/1/merge'}
            manual {$script:claims.event_name='workflow_dispatch'}
            workflow_run {$script:claims.event_name='workflow_run'}
        }
        { Get-ClcProtectedWorkflowConfiguration $script:claims 'clcdpc/example' deploy $TestDrive $script:api } | Should -Throw
    }
    It 'rejects mismatched tag, source, run or attempt before qualification' -ForEach @(@{Kind='tag'},@{Kind='source'},@{Kind='run'},@{Kind='attempt'},@{Kind='workflow'}) {
        switch ($Kind) {
            tag {$script:claims.workflow_ref=$script:claims.workflow_ref.Replace('dev.1','dev.2')}
            source {$script:claims.workflow_sha='e'*40}
            run {$script:claims.run_id='124'}
            attempt {$script:claims.run_attempt='1'}
            workflow {$script:claims.workflow_ref=$script:claims.workflow_ref.Replace('build.yml','other.yml')}
        }
        { Assert-ClcWorkflowSource $script:claims $script:configuration 'v1.2.3-dev.1' $script:caller 123 2 } | Should -Throw '*differs from selected producer*'
    }
    It 'requires protected integration history and an exact tagged shared pin' {
        $script:responses['/repos/clcdpc/example/branches/master'].protected=$false
        { Get-ClcProtectedWorkflowConfiguration $script:claims 'clcdpc/example' deploy $TestDrive $script:api } | Should -Throw '*not protected*'
        $script:responses['/repos/clcdpc/example/branches/master'].protected=$true
        $script:configuration.orchestration.sharedRevision='f'*40; Set-WorkflowConfigurationResponse
        { Get-ClcProtectedWorkflowConfiguration $script:claims 'clcdpc/example' deploy $TestDrive $script:api } | Should -Throw '*shared revision differs*'
    }
    It 'derives <Channel> target environment authorization and four labels without a group or variables' -ForEach @(@{Channel='DEV';Suffix='dev'},@{Channel='Production';Suffix='production'}) {
        $script:source.identity.channel=$Channel
        $route=Get-ClcDeploymentRoute $script:configuration $script:source
        $route.admitted | Should -BeTrue
        $id='example-'+$Suffix
        $route.target.targetId | Should -BeExactly $id
        $route.target.environment | Should -BeExactly $id
        $route.target.standingAuthorizationId | Should -BeExactly $id
        ($route.target.runnerLabels -join ',') | Should -BeExactly ('self-hosted,Windows,X64,'+$id)
        $route.target.Contains('runnerGroup') | Should -BeFalse
        $expected=Join-Path (Get-ClcProgramDataRoot) 'clc-example\Deployment\toolkit\policy\host-policy.json'
        (Get-ClcTargetLayout $script:configuration.applicationId $route.target.targetId '0.0.0').policyPath | Should -BeExactly $expected
    }
    It 'keeps beta and RC releases off deployment runners' {
        $script:source.identity.channel='ArtifactOnly'
        (Get-ClcDeploymentRoute $script:configuration $script:source).status | Should -BeExactly ArtifactOnly
    }
    It 'selects one exact artifact for source run and attempt' {
        $name='clc-package-'+$script:caller+'-123-2'
        $script:responses['/repos/clcdpc/example/actions/runs/123/artifacts?per_page=100&page=1']=@{artifacts=@(@{id=456L;name=$name},@{id=455L;name='old-attempt'})}
        Get-ClcQualifiedArtifactId $script:configuration $script:caller 123 2 $script:api | Should -Be 456
        $script:responses['/repos/clcdpc/example/actions/runs/123/artifacts?per_page=100&page=1'].artifacts+=@{id=457L;name=$name}
        { Get-ClcQualifiedArtifactId $script:configuration $script:caller 123 2 $script:api } | Should -Throw '*One exact qualified artifact*'
    }
    It 'rejects legacy versions and obsolete or infrastructure-owned fields' -ForEach @(@{Kind='version'},@{Kind='targets'},@{Kind='trustedFiles'},@{Kind='sourcePolicy'},@{Kind='applicationRoot'},@{Kind='runnerGroup'},@{Kind='runnerLabels'},@{Kind='enabled'},@{Kind='runnerAdmissionReady'},@{Kind='deploymentWorkflowPath'}) {
        if ($Kind -ceq 'deploymentWorkflowPath') {$script:configuration.orchestration.deploymentWorkflowPath='.github/workflows/deploy.yml'}
        elseif ($Kind -ceq 'version') {$script:configuration.contractVersion=1L} else {$script:configuration[$Kind]=@()}
        $bytes=[Text.Encoding]::UTF8.GetBytes(($script:configuration | ConvertTo-Json -Depth 12))
        { Read-ClcConsumerConfiguration -Bytes $bytes } | Should -Throw -ErrorId 'Clc.InvalidContract*'
    }
    It 'accepts exact comma-containing display names' -ForEach @(@{Name='Build, test, publish, and package'},@{Name='Frontend, CI checks and package'},@{Name=('A'*128)}) {
        $script:configuration.producer.jobName=$Name
        Set-WorkflowConfigurationResponse
        (Read-ClcConsumerConfiguration -Bytes ([Text.Encoding]::UTF8.GetBytes(($script:configuration | ConvertTo-Json -Depth 12)))).producer.jobName | Should -BeExactly $Name
    }
    It 'rejects malformed or overbound display names' -ForEach @(@{Name=''},@{Name=$null},@{Name=123},@{Name='Build: package'},@{Name="Build`n"},@{Name=('A'*129)}) {
        $script:configuration.producer.jobName=$Name
        { Read-ClcConsumerConfiguration -Bytes ([Text.Encoding]::UTF8.GetBytes(($script:configuration | ConvertTo-Json -Depth 12))) } | Should -Throw -ErrorId 'Clc.InvalidContract*'
    }
}
Describe 'Infrastructure-owned trust before the installed toolkit first import' {
    It 'rejects a runtime-writable fake policy before importing its selected module' {
        $script:firstImportPolicy=Join-Path $TestDrive 'clc-probe\Deployment\toolkit\policy\host-policy.json'
        $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($script:firstImportPolicy))
        [IO.File]::WriteAllText($script:firstImportPolicy,'{"activeToolkit":{"moduleManifestPath":"C:\\fake\\Clc.Deployment.psd1"}}')
        $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl=Get-Acl -LiteralPath $script:firstImportPolicy; $acl.SetOwner($sid)
        $acl.SetAccessRuleProtection($true,$false)
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,[Security.AccessControl.FileSystemRights]::FullControl,[Security.AccessControl.AccessControlType]::Allow))
        Set-Acl -LiteralPath $script:firstImportPolicy -AclObject $acl
        Mock Get-ClcProgramDataRoot { return $TestDrive }
        Mock Import-Module { throw 'UNSAFE_IMPORT' }
        { Open-ClcWorkflowToolkit -ApplicationId probe -TargetId probe-dev } | Should -Throw -ErrorId 'Clc.HostPreflightFailed*'
        Should -Invoke Import-Module -Times 0 -Exactly
        # Failure must release the held read handle without altering evidence.
        $stream=[IO.File]::Open($script:firstImportPolicy,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $stream.Dispose()
        [IO.File]::ReadAllText($script:firstImportPolicy) | Should -Match 'C:\\\\fake'
    }
}
Describe 'Prequalified CI artifacts use shared package inputs without a build pipeline' {
    BeforeAll { . "$PSScriptRoot/Support.ps1" }
    BeforeEach {
        $workspace=New-TestWorkspace; $inputs=New-TestPublish $workspace
        [IO.File]::WriteAllText((Join-Path $workspace 'Different.csproj'),'<Project Sdk="Microsoft.NET.Sdk.Web"><PropertyGroup><AssemblyName>Probe</AssemblyName></PropertyGroup></Project>')
        [IO.File]::WriteAllText((Join-Path $workspace 'packages.lock.json'),'{"version":1,"dependencies":{}}')
    }
    AfterEach { Remove-TestWorkspace $workspace }
    It 'packages an already-qualified publish directory with its actual SDK and literal project assembly identity' {
        $qualified=Get-ClcQualifiedPublishInputs @{project='Different.csproj'} $workspace $inputs.PublishRoot '10.0.403' ''
        $qualified.entryPoint | Should -BeExactly Probe.dll
        $metadata=Get-TestMetadata; $metadata.schemaVersion=2L; $metadata.changeKind='application-deployment'
        $metadata.validation.entryPoint=$qualified.entryPoint; $metadata.build.sdkVersion=$qualified.sdkVersion
        $metadata.build.dependencyLockSha256=(Get-FileHash -LiteralPath $qualified.dependencyLockPath -Algorithm SHA256).Hash.ToLowerInvariant()
        Write-TestJson $inputs.MetadataPath $metadata
        $before=Get-TestTreeHashes $inputs.PublishRoot
        $result=New-ClcRelease @inputs
        (Test-ClcRelease -ArchivePath $result.archivePath).packageContractVersion | Should -Be 2
        (Get-TestTreeHashes $inputs.PublishRoot) | Should -BeExactly $before
    }
    It 'supports a fixed DLL selector and root dependency lock when complex CI has no conventional project configuration' {
        $qualified=Get-ClcQualifiedPublishInputs @{} $workspace $inputs.PublishRoot '10.0.403' 'Probe.dll'
        $qualified.entryPoint | Should -BeExactly Probe.dll
        $qualified.dependencyLockPath | Should -BeExactly (Join-Path $workspace 'packages.lock.json')
    }
    It 'refuses an arbitrary script, argument list, evaluated name, or relative DLL path <EntryPoint>' -ForEach @(
        @{EntryPoint='deploy.ps1'},@{EntryPoint='Probe.dll --unsafe'},@{EntryPoint='../Probe.dll'},@{EntryPoint='$(AssemblyName).dll'}
    ) {
        { Get-ClcQualifiedPublishInputs @{} $workspace $inputs.PublishRoot '10.0.403' $EntryPoint } | Should -Throw
        [IO.File]::Exists($inputs.OutputPath) | Should -BeFalse
    }
    It 'records no lock evidence for independently qualified files without a NuGet lock' {
        [IO.File]::Delete((Join-Path $workspace 'packages.lock.json'))
        $qualified=Get-ClcQualifiedPublishInputs @{} $workspace $inputs.PublishRoot '10.0.403' 'Probe.dll'
        $qualified.dependencyLockPath | Should -BeNullOrEmpty
    }
    It 'requires explicit build facts instead of inferring a compiler or validation identity' {
        { Get-ClcQualifiedPublishInputs @{} $workspace $inputs.PublishRoot '10.0.403' '' } | Should -Throw '*fixed validation DLL*'
        { Get-ClcQualifiedPublishInputs @{} $workspace $inputs.PublishRoot 'latest' 'Probe.dll' } | Should -Throw
    }
}

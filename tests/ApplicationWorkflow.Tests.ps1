BeforeAll {
    . "$PSScriptRoot/../tools/release/Workflow.Common.ps1"
    function New-WorkflowFixture {
        $script:shared='c'*40; $script:caller='a'*40; $script:integration='b'*40
        $script:claims=@{iss='https://token.actions.githubusercontent.com';aud='clc-deployment';repository='clcdpc/example';workflow_ref='clcdpc/example/.github/workflows/deploy.yml@refs/heads/master';workflow_sha=$script:caller;job_workflow_ref=('clcdpc/clc-deployment/.github/workflows/application-deploy.yml@'+$script:shared);job_workflow_sha=$script:shared;event_name='workflow_run';actor='operator'}
        $script:configuration=@{contractVersion=1L;applicationId='example';repository='clcdpc/example';integrationBranch='master';sourcePolicy=@{allowPrDev=$true;allowSnapshots=$true;allowTestTags=$true};producer=@{workflowPath='.github/workflows/build.yml';job='build';jobName='package / build'};trustedFiles=@('.clc/release.json','.github/workflows/build.yml','.github/workflows/deploy.yml');requiredToolkitContractVersion=2L;
            orchestration=@{sharedRevision=$script:shared;deploymentWorkflowPath='.github/workflows/deploy.yml'};
            targets=@(@{channel='DEV';targetId='example-dev';environment='example-dev';runnerGroup='example-dev';runnerLabels=@('self-hosted','Windows','X64','example-dev');standingAuthorizationId='example-dev';enabled=$true;runnerAdmissionReady=$true},@{channel='Production';targetId='example-production';environment='example-production';runnerGroup='example-production';runnerLabels=@('self-hosted','Windows','X64','example-production');standingAuthorizationId='example-production';enabled=$false;runnerAdmissionReady=$false})}
        $script:responses=@{}
        $base='/repos/clcdpc/example'
        $script:responses[$base+'/branches/master']=@{protected=$true;commit=@{sha=$script:integration}}
        Set-WorkflowConfigurationResponse
        foreach ($commit in @($script:caller,$script:integration)) { $script:responses[$base+'/contents/.github/workflows/deploy.yml?ref='+$commit]=@{type='file';sha='same-workflow'} }
        $script:responses[$base+'/collaborators/operator/permission']=@{permission='write'}
        $script:api={param($method,$path,$body,[switch]$Bytes) if (-not $script:responses.ContainsKey($path)) { throw ('Unexpected API '+$path) }; return $script:responses[$path]}
        $script:source=@{superseded=$false;identity=@{channel='DEV';sourceClass='IntegrationTag'}}
    }
    function Set-WorkflowConfigurationResponse {
        $content=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($script:configuration | ConvertTo-Json -Depth 12 -Compress)))
        foreach ($commit in @($script:caller,$script:integration)) { $script:responses['/repos/clcdpc/example/contents/.clc/release.json?ref='+$commit]=@{type='file';sha=('d'*40);encoding='base64';size=100;content=$content} }
    }
}
Describe 'Reusable application workflow trust and routing' {
    BeforeEach { New-WorkflowFixture }
    It 'accepts pinned shared machinery called by unchanged protected deployment code' {
        $result=Get-ClcProtectedWorkflowConfiguration $script:claims 'clcdpc/example' deploy $TestDrive $script:api
        $result.configuration.applicationId | Should -BeExactly example
        (Get-ClcDeploymentRoute $result.configuration $script:source $true $script:claims $script:api).target.targetId | Should -BeExactly example-dev
    }
    It 'rejects mutable reusable refs and different shared code even when the caller is protected' -ForEach @(@{kind='ref'},@{kind='revision'}) {
        if ($kind -ceq 'ref') { $script:claims.job_workflow_ref='clcdpc/clc-deployment/.github/workflows/application-deploy.yml@refs/heads/master' }
        else { $script:claims.job_workflow_sha='e'*40 }
        { Get-ClcProtectedWorkflowConfiguration $script:claims 'clcdpc/example' deploy $TestDrive $script:api } | Should -Throw '*workflow identity refused*'
    }
    It 'rejects caller repository substitution' {
        $script:claims.repository='external/example'
        { Assert-ClcWorkflowClaims $script:claims 'clcdpc/example' deploy } | Should -Throw '*identity refused*'
    }
    It 'rejects a caller that runs from PR source instead of protected deployment code' {
        $script:claims.workflow_ref='clcdpc/example/.github/workflows/deploy.yml@refs/pull/1/merge'
        { Get-ClcProtectedWorkflowConfiguration $script:claims 'clcdpc/example' deploy $TestDrive $script:api } | Should -Throw '*protected integration branch*'
    }
    It 'rejects unprotected integration policy before runner routing' {
        $script:responses['/repos/clcdpc/example/branches/master'].protected=$false
        { Get-ClcProtectedWorkflowConfiguration $script:claims 'clcdpc/example' deploy $TestDrive $script:api } | Should -Throw '*not protected*'
    }
    It 'rejects substituted configuration and executing workflow bytes' -ForEach @(@{kind='config'},@{kind='workflow'}) {
        $path=if ($kind -ceq 'config') {'.clc/release.json'} else {'.github/workflows/deploy.yml'}
        $script:responses['/repos/clcdpc/example/contents/'+$path+'?ref='+$script:caller].sha='different'
        { Get-ClcProtectedWorkflowConfiguration $script:claims 'clcdpc/example' deploy $TestDrive $script:api } | Should -Throw
    }
    It 'rejects a shared revision that was not independently pinned in protected consumer policy' {
        $script:configuration.orchestration.sharedRevision='f'*40; Set-WorkflowConfigurationResponse
        { Get-ClcProtectedWorkflowConfiguration $script:claims 'clcdpc/example' deploy $TestDrive $script:api } | Should -Throw '*shared revision differs*'
    }
    It 'keeps disabled production and beta/RC off privileged runners' {
        $script:source.identity.channel='Production'
        (Get-ClcDeploymentRoute $script:configuration $script:source $true $script:claims $script:api).status | Should -BeExactly ActivationDisabled
        $script:source.identity.channel='ArtifactOnly'
        (Get-ClcDeploymentRoute $script:configuration $script:source $true $script:claims $script:api).status | Should -BeExactly ArtifactOnly
    }
    It 'skips an automatically superseded ASAP snapshot while allowing explicit authorized redeployment' {
        $script:source.superseded=$true
        (Get-ClcDeploymentRoute $script:configuration $script:source $true $script:claims $script:api).status | Should -BeExactly Superseded
        $script:claims.event_name='workflow_dispatch'
        (Get-ClcDeploymentRoute $script:configuration $script:source $false $script:claims $script:api).admitted | Should -BeTrue
    }
    It 'rejects attempts to disable automatic supersession outside authorized explicit dispatch' -ForEach @(@{kind='event'},@{kind='permission'}) {
        if ($kind -ceq 'permission') { $script:claims.event_name='workflow_dispatch'; $script:responses['/repos/clcdpc/example/collaborators/operator/permission'].permission='read' }
        { Get-ClcDeploymentRoute $script:configuration $script:source $false $script:claims $script:api } | Should -Throw '*redeployment requires*'
    }
    It 'selects one exact artifact for its immutable source run and attempt' {
        $name='clc-package-'+$script:caller+'-123-2'
        $script:responses['/repos/clcdpc/example/actions/runs/123/artifacts?per_page=100&page=1']=@{artifacts=@(@{id=456L;name=$name},@{id=455L;name='old-attempt'})}
        Get-ClcQualifiedArtifactId $script:configuration $script:caller 123 2 $script:api | Should -Be 456
        $script:responses['/repos/clcdpc/example/actions/runs/123/artifacts?per_page=100&page=1'].artifacts+=@{id=457L;name=$name}
        { Get-ClcQualifiedArtifactId $script:configuration $script:caller 123 2 $script:api } | Should -Throw '*One exact qualified artifact*'
    }
    It 'refuses unsafe routing fields and application-owned host paths in consumer configuration' -ForEach @(@{kind='labels'},@{kind='path'},@{kind='duplicate'}) {
        if ($kind -ceq 'labels') {$script:configuration.targets[0].runnerLabels=@('self-hosted','linux','X64')}
        elseif ($kind -ceq 'path') {$script:configuration.targets[0].applicationRoot='C:\forbidden'}
        else {$script:configuration.targets+=($script:configuration.targets[0].Clone())}
        $path=Join-Path $TestDrive 'bad.json'; [IO.File]::WriteAllText($path,($script:configuration | ConvertTo-Json -Depth 12))
        { Read-ClcConsumerConfiguration $path } | Should -Throw
    }
}
Describe 'Infrastructure-owned trust before the installed toolkit first import' {
    It 'rejects a runtime-writable fake policy before importing its selected module' {
        $script:firstImportPolicy=Join-Path $TestDrive 'host-policy.json'
        [IO.File]::WriteAllText($script:firstImportPolicy,'{"activeToolkit":{"moduleManifestPath":"C:\\fake\\CLC.Deployment.psd1"}}')
        $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl=Get-Acl -LiteralPath $script:firstImportPolicy; $acl.SetOwner($sid)
        $acl.SetAccessRuleProtection($true,$false)
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,[Security.AccessControl.FileSystemRights]::FullControl,[Security.AccessControl.AccessControlType]::Allow))
        Set-Acl -LiteralPath $script:firstImportPolicy -AclObject $acl
        Mock Get-ClcWorkflowPolicyPath { return $script:firstImportPolicy }
        Mock Import-Module { throw 'UNSAFE_IMPORT' }
        { Open-ClcWorkflowToolkit } | Should -Throw -ErrorId 'Clc.HostPreflightFailed*'
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
    It 'requires explicit build facts instead of inferring a compiler or dependency lock' {
        { Get-ClcQualifiedPublishInputs @{} $workspace $inputs.PublishRoot '10.0.403' '' } | Should -Throw '*fixed validation DLL*'
        { Get-ClcQualifiedPublishInputs @{} $workspace $inputs.PublishRoot 'latest' 'Probe.dll' } | Should -Throw
        [IO.File]::Delete((Join-Path $workspace 'packages.lock.json'))
        { Get-ClcQualifiedPublishInputs @{} $workspace $inputs.PublishRoot '10.0.403' 'Probe.dll' } | Should -Throw '*dependency lock*'
    }
}

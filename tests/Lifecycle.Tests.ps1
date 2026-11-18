
BeforeAll {
    . "$PSScriptRoot/Support.ps1"

    function New-LifecycleFixture {
        $parent=New-TestWorkspace
        $appRoot=Join-Path $parent 'clc-probe'
        $deployment=Join-Path $appRoot 'Deployment'
        $layout=@{root=$appRoot;programData=$parent;deployment=$deployment;application=(Join-Path $appRoot 'Application');
            config=(Join-Path $appRoot 'Config\application.json');keys=(Join-Path $appRoot 'Keys');logs=(Join-Path $appRoot 'Logs');
            inbox=(Join-Path $appRoot 'Inbox');hostRecord=(Join-Path $deployment 'host.json');state=(Join-Path $deployment 'state.json');
            lock=(Join-Path $deployment 'deployment.lock')}
        $init=@{ApplicationId='probe';TargetId='probe-dev';SiteName='Probe Dev';ApplicationPoolName='Probe.Dev';ReadinessUri='https://probe.invalid/health/ready'}
        $identity=@{ApplicationId='probe';TargetId='probe-dev';ExpectedRuntimeAccount='example\probe-service';RuntimeEnvironment='Staging'}
        $pool=@{Name=$init.ApplicationPoolName;AutoStart=$false;State='Stopped';ManagedRuntimeVersion='';
            ManagedPipelineMode='Integrated';Enable32BitAppOnWin64=$false;
            ProcessModel=@{IdentityType='ApplicationPoolIdentity';UserName='';MaxProcesses=1;LoadUserProfile=$true};
            Recycling=@{DisallowOverlappingRotation=$true}}
        $directory=@{Path='/';PhysicalPath=$layout.application}
        $app=@{Path='/';ApplicationPoolName=$pool.Name;VirtualDirectories=@{'/'=$directory}}
        $site=@{Name=$init.SiteName;Id=42;Applications=@{'/'=$app};State='Stopped';ServerAutoStart=$false;Bindings=@()}
        $iis=@{siteState='Stopped';poolState='Stopped';workerCount=0;siteAutoStart=$false;poolAutoStart=$false}
        $manager=[pscustomobject]@{}
        $manager | Add-Member ScriptMethod Dispose {}
        $global:ClcTestLifecycle=@{parent=$parent;layout=$layout;init=$init;identity=$identity;iis=$iis;manager=$manager;site=$site;pool=$pool;
            created=$false;conflict=$false;stoppedScaffold=$true;binding=$false;environment=$false;unusableWebConfig=$false;acl=$true;health=$true;operations=[Collections.Generic.List[string]]::new()}
        $manager | Add-Member ScriptMethod CommitChanges { $global:ClcTestLifecycle.created=$true }
        return $global:ClcTestLifecycle
    }

    function Set-LifecycleMocks {
        Mock Assert-ClcPlatform -ModuleName Clc.Deployment {}
        Mock Get-ClcHostLayout -ModuleName Clc.Deployment { $global:ClcTestLifecycle.layout }
        Mock Assert-ClcInitializationAccess -ModuleName Clc.Deployment {}
        Mock Open-ClcIis -ModuleName Clc.Deployment { $global:ClcTestLifecycle.manager }
        Mock Get-ClcHostingRuntime -ModuleName Clc.Deployment { 'mock-dotnet' }
        Mock Get-ClcIisResources -ModuleName Clc.Deployment {
            $fixture=$global:ClcTestLifecycle
            if ($fixture.created) { return @{site=$fixture.site;pool=$fixture.pool} }
            if ($fixture.conflict) { return @{site=$fixture.site;pool=$null} }
            return @{site=$null;pool=$null}
        }
        Mock Add-ClcIisResources -ModuleName Clc.Deployment {}
        Mock Assert-ClcIisOwnership -ModuleName Clc.Deployment {}
        Mock Assert-ClcIisPhysicalIsolation -ModuleName Clc.Deployment {}
        Mock Get-ClcIisState -ModuleName Clc.Deployment { $global:ClcTestLifecycle.iis.Clone() }
        Mock Resolve-ClcRuntimeSid -ModuleName Clc.Deployment {
            if ($Account -ieq 'example\probe-service') { return 'S-1-5-21-1-2-3-42' }
            return 'S-1-5-21-1-2-3-43'
        }
        Mock Assert-ClcRuntimeIdentity -ModuleName Clc.Deployment {}
        Mock Test-ClcIisHttpsBinding -ModuleName Clc.Deployment { $global:ClcTestLifecycle.binding }
        Mock Test-ClcIisEnvironment -ModuleName Clc.Deployment {
            $fixture=$global:ClcTestLifecycle
            $webConfig=Join-Path $fixture.layout.application 'web.config'
            if ($fixture.unusableWebConfig -and -not $SkipApplicationConfiguration -and [IO.File]::Exists($webConfig)) { return $false }
            return $fixture.environment
        }
        Mock Assert-ClcHostDirectoryAccess -ModuleName Clc.Deployment {
            if (-not $global:ClcTestLifecycle.acl) { throw 'private fixture sentinel' }
        }
        Mock Assert-ClcAccess -ModuleName Clc.Deployment {}
        Mock Assert-ClcApplicationAcl -ModuleName Clc.Deployment {}
        Mock Assert-ClcRuntimeAccess -ModuleName Clc.Deployment {}
        Mock New-ClcHostDirectory -ModuleName Clc.Deployment {
            if ([IO.Directory]::Exists($Path)) { throw 'Fixture already exists' }
            $null=[IO.Directory]::CreateDirectory($Path)
        }
        Mock Set-ClcManagedOwner -ModuleName Clc.Deployment {}
        Mock Set-ClcInstalledFileAcl -ModuleName Clc.Deployment {}
        Mock Invoke-ClcIisChange -ModuleName Clc.Deployment {
            $fixture=$global:ClcTestLifecycle
            $fixture.operations.Add($Operation)
            switch ($Operation) {
                DisableStartup { $fixture.iis.siteAutoStart=$false; $fixture.iis.poolAutoStart=$false }
                EnableStartup { $fixture.iis.siteAutoStart=$true; $fixture.iis.poolAutoStart=$true }
                StopSite { $fixture.iis.siteState='Stopped' }
                StopPool { $fixture.iis.poolState='Stopped'; $fixture.iis.workerCount=0 }
                StartPool { $fixture.iis.poolState='Started' }
                StartSite { $fixture.iis.siteState='Started'; $fixture.iis.workerCount=1 }
            }
        }
        Mock Invoke-ClcApplicationValidation -ModuleName Clc.Deployment {
            return @{revision='revision-one';keyStoreCompatibilityId='key-store-one';runtimeEnvironment='Staging'}
        }
        Mock Wait-ClcApplicationReady -ModuleName Clc.Deployment {
            if (-not $global:ClcTestLifecycle.health) { throw [Management.Automation.ErrorRecord]::new([IO.InvalidDataException]::new('Synthetic readiness identity failed.'),'Clc.ReadinessFailed','InvalidData',$null) }
            $global:ClcTestLifecycle.iis.Clone()
        }
    }

    function Initialize-TestTarget {
        param($Fixture)
        $initialize=$Fixture.init
        $null=Initialize-ClcDeploymentHost -Operation Initialize @initialize
        $Fixture.pool.ProcessModel.IdentityType='SpecificUser'
        $Fixture.pool.ProcessModel.UserName='example\probe-service'
        $Fixture.binding=$true
        $Fixture.environment=$true
        [IO.File]::WriteAllText($Fixture.layout.config,'private fixture sentinel')
        [IO.File]::WriteAllText((Join-Path $Fixture.layout.keys 'key.xml'),'persistent-key')
        [IO.File]::WriteAllText((Join-Path $Fixture.layout.logs 'example.log'),'persistent-log')
    }

    function New-LifecycleRelease {
        param($Fixture,[int] $Sequence,[string] $TargetId='probe-dev',[string] $ApplicationId='probe',[string] $ReleaseId)
        $build=Join-Path $Fixture.parent ('build-'+[guid]::NewGuid().ToString('N'))
        $inputs=New-TestPublish $build
        $metadata=Get-TestMetadata
        $metadata.applicationId=$ApplicationId
        $metadata.targetId=$TargetId
        $metadata.releaseId=if ($ReleaseId) {$ReleaseId} else {'v1-0-0-dev-'+$Sequence}
        Write-TestJson $inputs.MetadataPath $metadata
        [IO.File]::WriteAllText((Join-Path $inputs.PublishRoot 'Probe.dll'),('synthetic release '+$Sequence))
        $package=New-ClcRelease @inputs
        $parameters=$Fixture.identity.Clone()
        $parameters.ArchivePath=$package.archivePath
        $parameters.ExpectedSha256=$package.archiveSha256
        $parameters.ReleaseTag='v1.0.0-dev.'+$Sequence
        $parameters.ExpectedSourceCommit=$metadata.source.commit
        $parameters.ExpectedRepository=$metadata.source.repository
        return $parameters
    }

    function Get-LifecycleState($Fixture) {
        Get-Content -LiteralPath $Fixture.layout.state -Raw | ConvertFrom-Json -AsHashtable
    }
    function Get-UnresolvedAttempt($Fixture) {
        $state=Get-LifecycleState $Fixture
        $attemptId=$state.pending.attemptId
        return @{id=$attemptId;root=(Join-Path $Fixture.layout.deployment ('attempt-'+$attemptId))}
    }
}
AfterAll { Remove-Variable ClcTestLifecycle -Scope Global -ErrorAction SilentlyContinue }

Describe 'Host initialization and validation with synthetic IIS observations' {
    BeforeEach { $fixture=New-LifecycleFixture; Set-LifecycleMocks; $initialize=$fixture.init; $identity=$fixture.identity }
    AfterEach { Remove-TestWorkspace $fixture.parent }

    It 'previews the exact scaffold and stopped IIS settings without writing anything' {
        $result=Initialize-ClcDeploymentHost -Operation Preview @initialize
        $result.status | Should -BeExactly 'Preview'
        $result.root | Should -BeExactly $fixture.layout.root
        $result.planned.Count | Should -Be 11
        $result.iis.siteAutoStart | Should -BeFalse
        $result.iis.poolAutoStart | Should -BeFalse
        $result.iis.bindings | Should -BeNullOrEmpty
        $result.iis.initialIdentity | Should -Be 'ApplicationPoolIdentity'
        $result.iis.managedRuntime | Should -Be ''
        $result.iis.pipeline | Should -Be 'Integrated'
        $result.iis.enable32Bit | Should -BeFalse
        $result.iis.maxWorkers | Should -Be 1
        $result.iis.loadUserProfile | Should -BeTrue
        $result.iis.overlappingRecycling | Should -BeFalse
        $fixture.created | Should -BeFalse
        Should -Invoke New-ClcHostDirectory -ModuleName Clc.Deployment -Times 0 -Exactly
        @(Get-ChildItem -LiteralPath $fixture.parent -Force).Count | Should -Be 0
    }

    It 'creates only the scaffold and returns already initialized on the same request' {
        $sentinel=Join-Path $fixture.parent 'other-site.txt'
        [IO.File]::WriteAllText($sentinel,'preserve')
        $first=Initialize-ClcDeploymentHost -Operation Initialize @initialize
        $first.status | Should -Be 'InitializedNeedsConfiguration'
        $first.created.Count | Should -Be 11
        ($fixture.iis.siteState,$fixture.iis.poolState) | Should -Be @('Stopped','Stopped')
        (Get-ChildItem -LiteralPath $fixture.layout.root -Directory).Name | Sort-Object | Should -Be @('Application','Config','Deployment','Inbox','Keys','Logs')
        [IO.File]::Exists($fixture.layout.config) | Should -BeFalse
        $before=Get-TestTreeHashes $fixture.layout.root
        (Initialize-ClcDeploymentHost -Operation Initialize @initialize).status | Should -Be 'AlreadyInitialized'
        (Get-TestTreeHashes $fixture.layout.root) | Should -BeExactly $before
        [IO.File]::ReadAllText($sentinel) | Should -BeExactly 'preserve'
        Should -Invoke Invoke-ClcIisChange -ModuleName Clc.Deployment -Times 0 -Exactly
    }

    It 'refuses a partial scaffold or a competing IIS name' -ForEach @(@{Case='Directory'},@{Case='IIS'}) {
        if ($Case -ceq 'Directory') { $null=[IO.Directory]::CreateDirectory($fixture.layout.root) }
        else { $fixture.conflict=$true }
        $preview=Initialize-ClcDeploymentHost -Operation Preview @initialize
        $preview.status | Should -Be 'Blocked'
        $preview.present.Count | Should -Be 1
        { Initialize-ClcDeploymentHost -Operation Initialize @initialize } | Should -Throw -ErrorId 'Clc.ExistingResources*'
        Should -Invoke New-ClcHostDirectory -ModuleName Clc.Deployment -Times 0 -Exactly
    }

    It 'reports a missing host, missing manual settings and ready stopped host without exposing secrets' {
        (Test-ClcDeploymentHost @identity).status | Should -Be 'NotInitialized'
        $null=Initialize-ClcDeploymentHost -Operation Initialize @initialize
        $result=Test-ClcDeploymentHost @identity
        $result.status | Should -Be 'InitializedNeedsConfiguration'
        $result.findings.code | Should -Contain 'Clc.RuntimeIdentity'
        $result.findings.code | Should -Contain 'Clc.HttpsBinding'
        $result.findings.code | Should -Contain 'Clc.ConfigurationMissing'
        $fixture.pool.ProcessModel.IdentityType='SpecificUser'
        $fixture.pool.ProcessModel.UserName=$identity.ExpectedRuntimeAccount
        $fixture.binding=$true
        $fixture.environment=$true
        [IO.File]::WriteAllText($fixture.layout.config,'private fixture sentinel')
        $before=Get-TestTreeHashes $fixture.layout.root
        $ready=Test-ClcDeploymentHost @identity
        $ready.status | Should -Be 'ReadyForFirstDeployment'
        $ready.siteState | Should -Be 'Stopped'
        $ready.poolState | Should -Be 'Stopped'
        ($ready | ConvertTo-Json -Depth 6) | Should -Not -Match 'private fixture sentinel|example'
        (Get-TestTreeHashes $fixture.layout.root) | Should -BeExactly $before
        Should -Invoke Invoke-ClcIisChange -ModuleName Clc.Deployment -Times 0 -Exactly
    }

    It 'rejects mismatched identity, TLS, runtime access, environment, or application path' -ForEach @(
        @{Case='Account';Code='Clc.RuntimeIdentity'},@{Case='TLS';Code='Clc.HttpsBinding'},
        @{Case='ACL';Code='Clc.RuntimeAccess'},@{Case='Environment';Code='Clc.IisEnvironment'},@{Case='Path';Code='Clc.TargetMismatch'}
    ) {
        Initialize-TestTarget $fixture
        switch ($Case) {
            Account { $fixture.pool.ProcessModel.UserName='wrong\synthetic-account' }
            TLS { $fixture.binding=$false }
            ACL { $fixture.acl=$false }
            Environment { $fixture.environment=$false }
            Path { $fixture.layout.application=Join-Path $fixture.layout.root 'WrongApplication' }
        }
        $result=Test-ClcDeploymentHost @identity
        $result.ready | Should -BeFalse
        $result.findings.code | Should -Contain $Code
        ($result | ConvertTo-Json -Depth 5) | Should -Not -Match 'private fixture sentinel|wrong'
    }

    It 'blocks initialization when hosting components are unavailable' {
        Mock Get-ClcHostingRuntime -ModuleName Clc.Deployment { throw [Management.Automation.ErrorRecord]::new([IO.InvalidDataException]::new('Install the x64 Hosting Bundle.'),'Clc.HostingUnavailable','InvalidData',$null) }
        (Initialize-ClcDeploymentHost -Operation Preview @initialize).findings.code | Should -Contain 'Clc.HostingUnavailable'
        { Initialize-ClcDeploymentHost -Operation Initialize @initialize } | Should -Throw -ErrorId 'Clc.HostingUnavailable*'
        Should -Invoke New-ClcHostDirectory -ModuleName Clc.Deployment -Times 0 -Exactly
    }
}

Describe 'Deployment and recovery with native NTFS and synthetic IIS' {
    BeforeEach {
        $fixture=New-LifecycleFixture
        Set-LifecycleMocks
        Initialize-TestTarget $fixture
        $identity=$fixture.identity
    }
    AfterEach { Remove-TestWorkspace $fixture.parent }

    It 'rejects <Case> before locking, staging or touching IIS' -ForEach @(
        @{Case='hash';ErrorId='Clc.HashMismatch*'},@{Case='target';ErrorId='Clc.ReleaseMismatch*'},
        @{Case='application';ErrorId='Clc.ReleaseMismatch*'},@{Case='release';ErrorId='Clc.ReleaseMismatch*'},
        @{Case='commit';ErrorId='Clc.ReleaseMismatch*'},@{Case='repository';ErrorId='Clc.ReleaseMismatch*'},
        @{Case='structure';ErrorId='Clc.UnsafeArchive*'}
    ) {
        $deploy=New-LifecycleRelease $fixture 1
        switch ($Case) {
            hash { $deploy.ExpectedSha256='e'*64 }
            target { $deploy.TargetId='another-target' }
            application { $deploy.ApplicationId='another-app' }
            release { $deploy.ReleaseTag='v1.0.0-dev.2' }
            commit { $deploy.ExpectedSourceCommit='a'*40 }
            repository { $deploy.ExpectedRepository='another/repository' }
            structure {
                [IO.File]::WriteAllText($deploy.ArchivePath,'invalid zip')
                $deploy.ExpectedSha256=(Get-FileHash -LiteralPath $deploy.ArchivePath).Hash.ToLowerInvariant()
            }
        }
        { Invoke-ClcIisDeployment @deploy } | Should -Throw -ErrorId $ErrorId
        [IO.File]::Exists($fixture.layout.lock) | Should -BeFalse
        $fixture.operations.Count | Should -Be 0
        (Get-LifecycleState $fixture).pending | Should -BeNullOrEmpty
    }

    It 'commissions the first release then upgrades with a verified previous backup and untouched persistent files' {
        $first=New-LifecycleRelease $fixture 1
        $initial=Invoke-ClcIisDeployment @first
        $initial.status | Should -Be 'Deployed'
        $initial.siteState | Should -Be 'Started'
        $initial.poolState | Should -Be 'Started'
        $initial.workerCount | Should -Be 1
        ($fixture.operations -join ',') | Should -BeExactly 'DisableStartup,StopSite,StopPool,StartPool,StartSite,EnableStartup'
        $initial.siteAutoStart | Should -BeTrue
        $initial.poolAutoStart | Should -BeTrue
        (Test-ClcDeploymentHost @identity).status | Should -Be 'ReadyForDeployment'
        $before=Get-TestTreeHashes $fixture.layout.application
        $second=New-LifecycleRelease $fixture 2
        $upgraded=Invoke-ClcIisDeployment @second
        (Get-TestTreeHashes (Join-Path $upgraded.retainedPath 'backup')) | Should -BeExactly $before
        (Get-TestTreeHashes $fixture.layout.application) | Should -Not -BeExactly $before
        (Get-LifecycleState $fixture).current.release.attemptId | Should -BeExactly $upgraded.attemptId
        [IO.File]::ReadAllText($fixture.layout.config) | Should -BeExactly 'private fixture sentinel'
        [IO.File]::ReadAllText((Join-Path $fixture.layout.keys 'key.xml')) | Should -BeExactly 'persistent-key'
        [IO.File]::ReadAllText((Join-Path $fixture.layout.logs 'example.log')) | Should -BeExactly 'persistent-log'
    }

    It 'holds the real exclusive lock and refuses a competing deployment' {
        $held=Invoke-TestPrivate Enter-ClcDeploymentLock @($fixture.layout)
        try {
            $deploy=New-LifecycleRelease $fixture 1
            { Invoke-ClcIisDeployment @deploy } | Should -Throw -ErrorId 'Clc.DeploymentLocked*'
            (Get-LifecycleState $fixture).pending | Should -BeNullOrEmpty
            $fixture.operations.Count | Should -Be 0
        } finally { $held.Dispose() }
    }

    It 'rejects lower tags and changed bytes under an already recorded tag before IIS effects' {
        $newer=New-LifecycleRelease $fixture 2
        $null=Invoke-ClcIisDeployment @newer
        $older=New-LifecycleRelease $fixture 1
        $fixture.operations.Clear()
        { Invoke-ClcIisDeployment @older } | Should -Throw -ErrorId 'Clc.SupersededRelease*'
        $other=New-LifecycleRelease $fixture 3 -ReleaseId 'v1-0-0-dev-2'
        $other.ReleaseTag=$newer.ReleaseTag
        { Invoke-ClcIisDeployment @other } | Should -Throw -ErrorId 'Clc.ReleaseMismatch*'
        $fixture.operations.Count | Should -Be 0
    }

    It 'preserves a failed first install, blocks retries and explicitly restores an empty stopped site' {
        $deploy=New-LifecycleRelease $fixture 1
        $fixture.health=$false
        { Invoke-ClcIisDeployment @deploy } | Should -Throw -ErrorId 'Clc.ReadinessFailed*'
        $failed=Get-UnresolvedAttempt $fixture
        (Get-LifecycleState $fixture).current | Should -BeNullOrEmpty
        (Test-ClcDeploymentHost @identity).status | Should -Be 'RecoveryRequired'
        { Invoke-ClcIisDeployment @deploy } | Should -Throw -ErrorId 'Clc.RecoveryRequired*'
        Test-Path -LiteralPath (Join-Path $failed.root 'stage\Probe.dll') | Should -BeTrue
        $fixture.unusableWebConfig=$true
        $fixture.iis.siteState | Should -Be 'Stopped'
        $fixture.iis.poolState | Should -Be 'Stopped'
        (Restore-ClcIisDeployment @identity -AttemptId $failed.id -Reason 'incident-123').status | Should -Be 'RestoredEmpty'
        @(Get-ChildItem -LiteralPath $fixture.layout.application -Force).Count | Should -Be 0
        { Restore-ClcIisDeployment @identity -AttemptId $failed.id -Reason 'incident-123' } | Should -Throw -ErrorId 'Clc.RecoveryUnavailable*'
        (Test-ClcDeploymentHost @identity).status | Should -Be 'ReadyForFirstDeployment'
    }

    It 'restores a verified prior release explicitly after failed activation' {
        $first=New-LifecycleRelease $fixture 1
        $former=Invoke-ClcIisDeployment @first
        $previous=Get-TestTreeHashes $fixture.layout.application
        $second=New-LifecycleRelease $fixture 2
        $fixture.health=$false
        { Invoke-ClcIisDeployment @second } | Should -Throw -ErrorId 'Clc.ReadinessFailed*'
        $failed=Get-UnresolvedAttempt $fixture
        (Get-TestTreeHashes $fixture.layout.application) | Should -Not -BeExactly $previous
        (Get-LifecycleState $fixture).current.release.attemptId | Should -BeExactly $former.attemptId
        $fixture.health=$true
        $result=Restore-ClcIisDeployment @identity -AttemptId $failed.id -Reason 'incident-456'
        $result.status | Should -Be 'RestoredPrevious'
        $originalJournal=Get-Content -LiteralPath (Join-Path $failed.root 'before-recovery.json') -Raw | ConvertFrom-Json
        $originalJournal.phase | Should -Be 'Checking'
        $originalJournal.errorCode | Should -Be 'Clc.ReadinessFailed'
        (Get-TestTreeHashes $fixture.layout.application) | Should -BeExactly $previous
        (Get-TestTreeHashes (Join-Path $failed.root 'backup')) | Should -BeExactly $previous
        [IO.File]::ReadAllText($fixture.layout.config) | Should -BeExactly 'private fixture sentinel'
        [IO.File]::ReadAllText((Join-Path $fixture.layout.keys 'key.xml')) | Should -BeExactly 'persistent-key'
        [IO.File]::ReadAllText((Join-Path $fixture.layout.logs 'example.log')) | Should -BeExactly 'persistent-log'
    }

    It 'refuses ambiguous recovery for <Case> while preserving application bytes and state' -ForEach @(
        @{Case='corrupt backup'},@{Case='missing backup'},@{Case='live drift'},@{Case='unrecognized file'},@{Case='helper intent'},@{Case='interrupted recovery'}
    ) {
        $first=New-LifecycleRelease $fixture 1
        $null=Invoke-ClcIisDeployment @first
        $second=New-LifecycleRelease $fixture 2
        $fixture.health=$false
        { Invoke-ClcIisDeployment @second } | Should -Throw -ErrorId 'Clc.ReadinessFailed*'
        $failed=Get-UnresolvedAttempt $fixture
        $backup=Join-Path $failed.root 'backup\Probe.dll'
        $journal=Join-Path $failed.root 'attempt.json'
        switch ($Case) {
            'corrupt backup' { [IO.File]::WriteAllText($backup,'backup drift') }
            'missing backup' { [IO.File]::Delete($backup) }
            'live drift' { [IO.File]::WriteAllText((Join-Path $fixture.layout.application 'Probe.dll'),'unknown bytes') }
            'unrecognized file' { [IO.File]::WriteAllText((Join-Path $fixture.layout.application 'unknown.txt'),'unknown bytes') }
            'helper intent' {
                $record=Get-Content -LiteralPath $journal -Raw | ConvertFrom-Json -AsHashtable
                $record.helper=@{status='Intent';processId=$null;creationUtc=$null}
                Write-TestJson $journal $record
            }
            'interrupted recovery' {
                $record=Get-Content -LiteralPath $journal -Raw | ConvertFrom-Json -AsHashtable
                $record.phase='Recovering'
                $record.reason='prior-attempt'
                Write-TestJson $journal $record
            }
        }
        $fixture.operations.Clear()
        $before=Get-TestTreeHashes $fixture.layout.application
        { Restore-ClcIisDeployment @identity -AttemptId $failed.id -Reason 'incident-789' } | Should -Throw -ErrorId 'Clc.*'
        $fixture.operations.Count | Should -Be 0
        (Get-TestTreeHashes $fixture.layout.application) | Should -BeExactly $before
        (Get-LifecycleState $fixture).pending.attemptId | Should -BeExactly $failed.id
    }
}


Describe 'Canonical host path layout' {
    It 'uses native ProgramData on a non-C volume' {
        Mock Get-ClcProgramDataRoot -ModuleName Clc.Deployment { 'D:\NativeData' }
        Mock Assert-ClcPathSpelling -ModuleName Clc.Deployment {}
        $layout=Invoke-TestPrivate Get-ClcHostLayout @('probe')
        $layout.root | Should -BeExactly 'D:\NativeData\clc-probe'
        $layout.config | Should -BeExactly 'D:\NativeData\clc-probe\Config\application.json'
        $layout.deployment | Should -BeExactly 'D:\NativeData\clc-probe\Deployment'
    }
}

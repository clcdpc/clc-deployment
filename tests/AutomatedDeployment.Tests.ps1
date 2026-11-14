BeforeAll {
    . "$PSScriptRoot/Support.ps1"
    . "$PSScriptRoot/T2Support.ps1"
    . "$PSScriptRoot/T3Support.ps1"
    function New-AutomationFixture {
        param($Fixture,[string] $Tag='v1.0.0-dev.2',[long] $RunId=1,[long] $RunAttempt=1,[string] $Commit=('2'*40),[string] $ReleaseId)
        $tagInfo=Invoke-T2Private Get-ClcDeploymentTag @($Tag)
        $build=Join-Path $Fixture.workspace ($tagInfo.releaseId+'-'+$RunId+'-'+$RunAttempt)
        [void][IO.Directory]::CreateDirectory($build)
        $inputs=New-TestPublish $build
        $metadata=Get-TestMetadata; $metadata.releaseId='probe-'+$RunId+'-'+$RunAttempt+'-'+$tagInfo.releaseId; $metadata.source.commit=$Commit
        if ($ReleaseId) { $metadata.releaseId=$ReleaseId }
        $metadata.build.runId=$RunId; $metadata.build.runAttempt=$RunAttempt
        Write-TestJson $inputs.MetadataPath $metadata
        [IO.File]::WriteAllText((Join-Path $inputs.PublishRoot 'Probe.dll'),('Synthetic automated DLL '+$Tag+' '+$RunId+' '+$RunAttempt+' '+$Commit))
        $package=New-ClcRelease @inputs
        $Fixture.dllIdentities[(Get-FileHash -LiteralPath (Join-Path $inputs.PublishRoot 'Probe.dll')).Hash]=$metadata
        $archive=Join-Path $Fixture.target.artifactInboxRoot ($tagInfo.releaseId+'-'+$RunId+'-'+$RunAttempt+'.zip')
        Copy-Item -LiteralPath $package.archivePath -Destination $archive
        $root=Join-Path $Fixture.layout.approvalCatalogRoot 'standing'; [void][IO.Directory]::CreateDirectory($root)
        $s=Get-Content -LiteralPath (Join-Path $script:FixtureRoot 'standing-authorization.json') -Raw | ConvertFrom-Json -AsHashtable
        $s.targetId=$Fixture.target.targetId; $s.applicationId=$Fixture.target.applicationId; $s.environmentName=$Fixture.target.environmentName
        $s.sourceRepository=$metadata.source.repository; $s.buildWorkflowPath=$metadata.build.workflowPath; $s.buildJob=$metadata.build.job
        $path=Join-Path $root ($s.standingAuthorizationId+'.json'); Write-TestJson $path $s
        $p=[ordered]@{contractFamily='clc-file-iis-v1';schemaVersion=1;recordKind='verified-release';targetId=$s.targetId;applicationId=$s.applicationId;
            releaseId=$metadata.releaseId;tag=$Tag;sourceRepository=$metadata.source.repository;sourceCommit=$metadata.source.commit;
            releaseZipSha256=$package.archiveSha256;manifestSha256=$package.manifestSha256;
            provenance=@{workflowPath=$metadata.build.workflowPath;runId=$metadata.build.runId;runAttempt=$metadata.build.runAttempt;buildJob=$metadata.build.job;artifactId=($RunId*10+$RunAttempt);transportSha256=('f'*64)}}
        $evidence=Join-Path $Fixture.target.artifactInboxRoot ($tagInfo.releaseId+'-'+$RunId+'-'+$RunAttempt+'.json')
        Write-TestJson $evidence $p
        return @{standing=$s;path=$path;tag=$Tag;package=$package;archive=$archive;evidence=$evidence;identity=$p;releaseId=$metadata.releaseId}
    }
    function Invoke-Automation {
        param($Fixture,$Automation)
        Invoke-ClcIisDeployment -TargetId $Fixture.target.targetId -StandingAuthorizationId $Automation.standing.standingAuthorizationId -ReleaseTag $Automation.tag -ArchivePath $Automation.archive -VerifiedReleasePath $Automation.evidence
    }
}

Describe 'Central tag convention' {
    It 'classifies <Tag> as <Channel>' -ForEach @(
        @{Tag='v1.2.3-dev.1';Channel='DEV'},@{Tag='v1.2.3';Channel='Production'},
        @{Tag='v1.2.3-beta.1';Channel='ArtifactOnly'},@{Tag='v1.2.3-rc.1';Channel='ArtifactOnly'}
    ) { (Invoke-T2Private Get-ClcDeploymentTag @($Tag)).channel | Should -BeExactly $Channel }
    It 'rejects noncanonical or unbounded tag <Tag>' -ForEach @(
        @{Tag='v01.2.3'},@{Tag='1.2.3'},@{Tag='v1.2.3-dev.0'},@{Tag='v1.2.3-DEV.1'},@{Tag='v1.2.3+build'},@{Tag='v10000.0.0'},@{Tag='v1.0.0-dev.9999'},@{Tag='v1.0.0/../../'}
    ) { Test-TestRejection { Invoke-T2Private Get-ClcDeploymentTag @($Tag) } 'Clc.InvalidContract*' }
    It 'orders dev iterations, patch, minor and major numerically' {
        $tags=@('v1.0.0-dev.9','v1.0.0-dev.10','v1.0.0','v1.0.1-dev.1','v1.1.0-dev.1','v2.0.0-dev.1')
        $sequences=@($tags | ForEach-Object { (Invoke-T2Private Get-ClcDeploymentTag @($_)).releaseSequence })
        for ($i=1;$i -lt $sequences.Count;$i++) { $sequences[$i] | Should -BeGreaterThan $sequences[$i-1] }
    }
}

Describe 'Standing authority excludes initial deployment' {
    It 'rejects an empty target without publishing release authority or executing code' {
        $fixture=New-T2Fixture; Set-T2FixtureInModule $fixture; Set-T3Mocks
        try {
            $before=Get-T2TreeHashes $fixture
            Test-TestRejection { Invoke-ClcIisDeployment -TargetId example -StandingAuthorizationId example-dev -ReleaseTag v1.0.0-dev.1 -ArchivePath C:\unused.zip -VerifiedReleasePath C:\unused.json } 'Clc.AutomationRequiresBaseline*'
            (Get-T2TreeHashes $fixture) | Should -BeExactly $before
            $global:ClcLifecycle.operations.Count | Should -Be 0
        } finally { Remove-TestWorkspace $fixture.workspace }
    }
}

Describe 'Standing-policy admission using real NTFS, lock and lifecycle state' {
    BeforeEach {
        $fixture=New-T2Fixture; Set-T2FixtureInModule $fixture; Set-T3Mocks
        $baseline=New-T3Approval $fixture -Sequence 1 -Lineage probe-main
        $null=Invoke-ClcIisDeployment -TargetId example -ReleaseApprovalId $baseline.record.approvalId
        $auto=New-AutomationFixture $fixture
        $global:ClcLifecycle.operations.Clear()
    }
    AfterEach { Remove-TestWorkspace $fixture.workspace }
    It 'admits successive workflow-verified releases and makes identical retries NoOp' {
        (Invoke-Automation $fixture $auto).status | Should -Be Deployed
        $first=Get-Content -LiteralPath (Join-Path $fixture.controlRoot 'current.json') -Raw
        $approvalId=($first | ConvertFrom-Json).release.approvalId
        $approvalJson=Get-Content -LiteralPath (Join-Path $fixture.layout.approvalCatalogRoot ($approvalId+'.json')) -Raw
        Test-Json -Json $approvalJson -SchemaFile (Join-Path $script:RepositoryRoot 'schemas/release-approval.schema.json') | Should -BeTrue
        $extra=$approvalJson | ConvertFrom-Json -AsHashtable
        $extra.admission.untrustedOverride=$true
        Test-TestRejection { Invoke-T2Private Read-ClcJson @([Text.Encoding]::UTF8.GetBytes(($extra | ConvertTo-Json -Depth 20 -Compress)),'release-approval') } 'Clc.InvalidContract*'
        (Invoke-Automation $fixture $auto).status | Should -Be NoOp
        (Get-Content -LiteralPath (Join-Path $fixture.controlRoot 'current.json') -Raw) | Should -BeExactly $first
        $auto2=New-AutomationFixture $fixture 'v1.0.0-dev.3'
        (Invoke-Automation $fixture $auto2).status | Should -Be Deployed
        Test-TestRejection { Invoke-Automation $fixture $auto } 'Clc.DowngradeRejected*'
    }
    It 'admits stable releases only under the independent production scope' {
        $production=New-AutomationFixture $fixture 'v1.0.0'
        Test-TestRejection { Invoke-Automation $fixture $production } 'Clc.StandingAuthorizationRejected*'
        $production.standing.channel='Production'; Write-TestJson $production.path $production.standing
        (Invoke-Automation $fixture $production).status | Should -Be Deployed
    }
    It 'rejects standing <Field> mismatch before new authority or application effects' -ForEach @(
        @{Field='enabled';Value=$false},@{Field='targetId';Value='other'},@{Field='applicationId';Value='other'},
        @{Field='environmentName';Value='other'},@{Field='sourceRepository';Value='other/repo'},@{Field='channel';Value='Production'},@{Field='lineageId';Value='other'}
    ) {
        $auto.standing[$Field]=$Value; Write-TestJson $auto.path $auto.standing
        $before=Get-T2TreeHashes $fixture
        Test-TestRejection { Invoke-Automation $fixture $auto }
        (Get-T2TreeHashes $fixture) | Should -BeExactly $before
        $global:ClcLifecycle.operations.Count | Should -Be 0
    }
    It 'rejects absent, revoked, or runtime-writable policy' -ForEach @(@{Mode='absent'},@{Mode='revoked'},@{Mode='writable'}) {
        switch ($Mode) {
            absent { Remove-Item -LiteralPath $auto.path }
            revoked { $auto.standing.enabled=$false; Write-TestJson $auto.path $auto.standing }
            writable { $global:ClcUnsafeStanding=$auto.path; Mock -ModuleName CLC.Deployment Assert-ClcAccess { if ($Path -ceq $global:ClcUnsafeStanding) { throw 'Synthetic runtime write grant' }; return (Invoke-T2Private Get-ClcSecurityObservation @($Path)).sha256 } }
        }
        $before=Get-T2TreeHashes $fixture
        Test-TestRejection { Invoke-Automation $fixture $auto } 'Clc.StandingAuthorizationRejected*'
        (Get-T2TreeHashes $fixture) | Should -BeExactly $before
    }
    It 'requires the independently admitted elevated identity even with matching JSON and policy' -ForEach @(@{Mode='sid'},@{Mode='token'}) {
        if ($Mode -ceq 'sid') { Mock -ModuleName CLC.Deployment Get-ClcCallerSid { return 'S-1-5-21-1-2-3-9999' } }
        else { Mock -ModuleName CLC.Deployment Test-ClcAdministratorToken { return $false } }
        $before=Get-T2TreeHashes $fixture
        Test-TestRejection { Invoke-Automation $fixture $auto }
        (Get-T2TreeHashes $fixture) | Should -BeExactly $before
        $global:ClcLifecycle.operations.Count | Should -Be 0
    }
    It 'rejects verified release <Field> mismatch' -ForEach @(
        @{Field='targetId';Value='other'},@{Field='applicationId';Value='other'},@{Field='sourceRepository';Value='other/repo'},
        @{Field='sourceCommit';Value=('9'*40)},@{Field='releaseZipSha256';Value=('9'*64)},@{Field='manifestSha256';Value=('9'*64)},@{Field='releaseId';Value='other'}
    ) {
        $auto.identity[$Field]=$Value; Write-TestJson $auto.evidence $auto.identity
        $before=Get-T2TreeHashes $fixture
        Test-TestRejection { Invoke-Automation $fixture $auto }
        (Get-T2TreeHashes $fixture) | Should -BeExactly $before
    }
    It 'rejects modified package bytes before application effects' {
        [IO.File]::AppendAllText($auto.archive,'tamper')
        $before=Get-T2TreeHashes $fixture
        Test-TestRejection { Invoke-Automation $fixture $auto }
        (Get-T2TreeHashes $fixture) | Should -BeExactly $before
        $global:ClcLifecycle.operations.Count | Should -Be 0
    }
    It 'rejects artifact-only tags before admission effects' -ForEach @(@{Tag='v1.0.0-beta.1'},@{Tag='v1.0.0-rc.1'}) {
        $before=Get-T2TreeHashes $fixture
        Test-TestRejection { Invoke-ClcIisDeployment -TargetId example -StandingAuthorizationId $auto.standing.standingAuthorizationId -ReleaseTag $Tag -ArchivePath $auto.archive -VerifiedReleasePath $auto.evidence } 'Clc.StandingAuthorizationRejected*'
        (Get-T2TreeHashes $fixture) | Should -BeExactly $before
    }
    It 'does not let saved generated approval IDs bypass revocation or grant downgrade' {
        $null=Invoke-Automation $fixture $auto
        $current=Get-Content -LiteralPath (Join-Path $fixture.controlRoot 'current.json') -Raw | ConvertFrom-Json
        Test-TestRejection { Invoke-ClcIisDeployment -TargetId example -ReleaseApprovalId $current.release.approvalId -AllowDowngrade -Reason incident } 'Clc.DowngradeRejected*'
        $auto.standing.enabled=$false; Write-TestJson $auto.path $auto.standing
        Test-TestRejection { Invoke-ClcIisDeployment -TargetId example -ReleaseApprovalId $current.release.approvalId } 'Clc.StandingAuthorizationRejected*'
    }
    It 'deploys a fresh build of the same tag and preserves original approvals and evidence' -ForEach @(@{RunId=2;RunAttempt=1},@{RunId=1;RunAttempt=2}) {
        $null=Invoke-Automation $fixture $auto
        $first=Get-Content -LiteralPath (Join-Path $fixture.controlRoot 'current.json') -Raw | ConvertFrom-Json
        $originalPath=Join-Path $fixture.layout.approvalCatalogRoot ($first.release.approvalId+'.json')
        $original=[IO.File]::ReadAllText($originalPath)
        $evidencePath=Join-Path $fixture.layout.approvalCatalogRoot ('standing\'+$first.release.approvalId+'.verified.json')
        $originalEvidence=[IO.File]::ReadAllText($evidencePath)
        $rebuilt=New-AutomationFixture $fixture $auto.tag -RunId $RunId -RunAttempt $RunAttempt -ReleaseId $auto.releaseId
        $rebuilt.package.archiveSha256 | Should -Not -BeExactly $auto.package.archiveSha256
        (Invoke-Automation $fixture $rebuilt).status | Should -Be Deployed
        $second=Get-Content -LiteralPath (Join-Path $fixture.controlRoot 'current.json') -Raw | ConvertFrom-Json
        $second.release.approvalId | Should -Not -BeExactly $first.release.approvalId
        $second.approvalSnapshot.releaseSequence | Should -Be $first.approvalSnapshot.releaseSequence
        [IO.File]::ReadAllText($originalPath) | Should -BeExactly $original
        [IO.File]::ReadAllText($evidencePath) | Should -BeExactly $originalEvidence
        (Invoke-Automation $fixture $rebuilt).status | Should -Be NoOp
        $before=Get-T2TreeHashes $fixture
        Test-TestRejection { Invoke-Automation $fixture $auto } 'Clc.ReleaseIdentityConflict*'
        Test-TestRejection { Invoke-ClcIisDeployment -TargetId example -ReleaseApprovalId $first.release.approvalId } 'Clc.ReleaseIdentityConflict*'
        (Get-T2TreeHashes $fixture) | Should -BeExactly $before
    }
    It 'rejects a different source commit for an admitted tag even after a manual downgrade' {
        $null=Invoke-Automation $fixture $auto
        $null=Invoke-ClcIisDeployment -TargetId example -ReleaseApprovalId $baseline.record.approvalId -AllowDowngrade -Reason maintenance
        $rebuilt=New-AutomationFixture $fixture $auto.tag -RunId 2 -Commit ('3'*40)
        $before=Get-T2TreeHashes $fixture
        $global:ClcLifecycle.operations.Clear()
        Test-TestRejection { Invoke-Automation $fixture $rebuilt } 'Clc.ReleaseIdentityConflict*'
        (Get-T2TreeHashes $fixture) | Should -BeExactly $before
        $global:ClcLifecycle.operations.Count | Should -Be 0
    }
    It 'rejects conflicting reuse of the exact build approval without overwriting it' {
        $null=Invoke-Automation $fixture $auto
        $current=Get-Content -LiteralPath (Join-Path $fixture.controlRoot 'current.json') -Raw | ConvertFrom-Json
        $null=Invoke-ClcIisDeployment -TargetId example -ReleaseApprovalId $baseline.record.approvalId -AllowDowngrade -Reason maintenance
        $path=Join-Path $fixture.layout.approvalCatalogRoot ($current.release.approvalId+'.json')
        $approval=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
        $approval.enabled=$false; Write-TestJson $path $approval
        $before=Get-T2TreeHashes $fixture
        Test-TestRejection { Invoke-Automation $fixture $auto } 'Clc.ReleaseIdentityConflict*'
        (Get-T2TreeHashes $fixture) | Should -BeExactly $before
    }
    It 'reuses the original approval and evidence when identical identity JSON is reformatted' {
        $null=Invoke-Automation $fixture $auto
        $current=Get-Content -LiteralPath (Join-Path $fixture.controlRoot 'current.json') -Raw
        $id=($current | ConvertFrom-Json).release.approvalId
        $path=Join-Path $fixture.layout.approvalCatalogRoot ('standing\'+$id+'.verified.json')
        $original=[IO.File]::ReadAllText($path)
        [IO.File]::WriteAllText($auto.evidence,($auto.identity | ConvertTo-Json -Depth 24))
        (Invoke-Automation $fixture $auto).status | Should -Be NoOp
        [IO.File]::ReadAllText($path) | Should -BeExactly $original
        (Get-Content -LiteralPath (Join-Path $fixture.controlRoot 'current.json') -Raw) | Should -BeExactly $current
    }
    It 'refuses missing or corrupt durable admission material on exact retries' -ForEach @(@{Mode='binding'},@{Mode='zip'},@{Mode='evidence'}) {
        $null=Invoke-Automation $fixture $auto
        $current=Get-Content -LiteralPath (Join-Path $fixture.controlRoot 'current.json') -Raw | ConvertFrom-Json
        if ($Mode -ceq 'binding') {
            $binding=Get-ChildItem -LiteralPath (Join-Path $fixture.layout.approvalCatalogRoot 'standing') -Filter 'tag-*.json'
            Remove-Item -LiteralPath $binding.FullName
        } elseif ($Mode -ceq 'zip') { [IO.File]::AppendAllText((Join-Path $fixture.target.artifactInboxRoot ($current.release.approvalId+'.zip')),'tamper') }
        else {
            $auto.identity.sourceCommit='9'*40
            Write-TestJson (Join-Path $fixture.layout.approvalCatalogRoot ('standing\'+$current.release.approvalId+'.verified.json')) $auto.identity
        }
        $before=Get-T2TreeHashes $fixture
        $global:ClcLifecycle.operations.Clear()
        Test-TestRejection { Invoke-Automation $fixture $auto } 'Clc.AdmissionIncomplete*'
        (Get-T2TreeHashes $fixture) | Should -BeExactly $before
        $global:ClcLifecycle.operations.Count | Should -Be 0
    }
    It 'retains interrupted admission intent and refuses repair' {
        Mock -ModuleName CLC.Deployment Publish-ClcAutomatedApproval { throw 'Synthetic interruption before atomic approval publication' }
        try { Invoke-Automation $fixture $auto; throw 'Expected admission failure.' }
        catch {
            $_.FullyQualifiedErrorId | Should -BeLike 'Clc.AdmissionIncomplete*'
            $_.Exception.Message | Should -Match 'infrastructure maintenance'
        }
        @(Get-ChildItem -LiteralPath (Join-Path $fixture.layout.approvalCatalogRoot 'standing') -Filter '*.pending').Count | Should -Be 1
        Test-TestRejection { Invoke-Automation $fixture $auto } 'Clc.AdmissionIncomplete*'
        Test-TestRejection { Invoke-ClcIisDeployment -TargetId example -ReleaseApprovalId $baseline.record.approvalId } 'Clc.AdmissionIncomplete*'
        $global:ClcLifecycle.operations.Count | Should -Be 0
    }
    It 'rejects malformed identity JSON and build mismatches before authority publication' -ForEach @(
        @{Mode='duplicate'},@{Mode='extra'},@{Mode='run'},@{Mode='attempt'},@{Mode='workflow'},@{Mode='job'},@{Mode='tag'},@{Mode='legacy'}
    ) {
        switch ($Mode) {
            duplicate { [IO.File]::WriteAllText($auto.evidence,([IO.File]::ReadAllText($auto.evidence).TrimEnd('}')+',"targetId":"example"}')) }
            extra { $auto.identity.untrustedOverride=$true; Write-TestJson $auto.evidence $auto.identity }
            run { $auto.identity.provenance.runId=99; Write-TestJson $auto.evidence $auto.identity }
            attempt { $auto.identity.provenance.runAttempt=99; Write-TestJson $auto.evidence $auto.identity }
            workflow { $auto.identity.provenance.workflowPath='.github/workflows/other.yml'; Write-TestJson $auto.evidence $auto.identity }
            job { $auto.identity.provenance.buildJob='other'; Write-TestJson $auto.evidence $auto.identity }
            tag { $auto.identity.tag='v1.0.0-dev.3'; Write-TestJson $auto.evidence $auto.identity }
            legacy { $auto.identity.recordKind='automated-provenance'; Write-TestJson $auto.evidence $auto.identity }
        }
        $before=Get-T2TreeHashes $fixture
        Test-TestRejection { Invoke-Automation $fixture $auto }
        (Get-T2TreeHashes $fixture) | Should -BeExactly $before
        $global:ClcLifecycle.operations.Count | Should -Be 0
    }
    It 'rejects unsafe or unprotected inputs before new authority' -ForEach @(@{Mode='outside'},@{Mode='writable'},@{Mode='hardlink'}) {
        switch ($Mode) {
            outside { $outside=Join-Path $fixture.workspace 'outside.json'; Copy-Item -LiteralPath $auto.evidence -Destination $outside; $auto.evidence=$outside }
            writable { $global:ClcUnsafeInput=$auto.evidence; Mock -ModuleName CLC.Deployment Assert-ClcAccess { throw 'Synthetic runtime write grant' } -ParameterFilter { $Path -ceq $global:ClcUnsafeInput } }
            hardlink { $null=New-Item -ItemType HardLink -Path (Join-Path $fixture.target.artifactInboxRoot 'alias.json') -Target $auto.evidence }
        }
        $before=Get-T2TreeHashes $fixture
        Test-TestRejection { Invoke-Automation $fixture $auto }
        (Get-T2TreeHashes $fixture) | Should -BeExactly $before
        $global:ClcLifecycle.operations.Count | Should -Be 0
    }
    It 'serializes admission with the existing machine/pool deployment handle' {
        $context=Invoke-T2Private Open-ClcTrustedContext; $lock=$null
        try {
            $lock=Invoke-T2Private Enter-ClcDeploymentLock @($context,'example')
            Test-TestRejection { Invoke-Automation $fixture $auto } 'Clc.ConcurrentDeployment*'
        } finally { Invoke-T2Private Exit-ClcDeploymentLock @($lock); Invoke-T2Private Close-ClcTrustedContext @($context) }
    }
    It 'requires independent exact approval for recovery of generated releases even after revocation' {
        $null=Invoke-Automation $fixture $auto
        $current=Get-Content -LiteralPath (Join-Path $fixture.controlRoot 'current.json') -Raw | ConvertFrom-Json
        $auto.standing.enabled=$false; Write-TestJson $auto.path $auto.standing
        Test-TestRejection { Restore-ClcIisDeployment -TargetId example -AttemptId $current.attemptId -Mode AcceptCandidate -Reason incident } 'Clc.RecoveryApprovalRequired*'
        $manual=Get-Content -LiteralPath (Join-Path $fixture.layout.approvalCatalogRoot ($current.release.approvalId+'.json')) -Raw | ConvertFrom-Json -AsHashtable
        $manual.Remove('admission'); $manual.schemaVersion=1; $manual.approvalId='manual-recovery'
        $expectedCommit=$manual.sourceCommit; $manual.sourceCommit='9'*40
        Write-TestJson (Join-Path $fixture.layout.approvalCatalogRoot 'manual-recovery.json') $manual
        Test-TestRejection { Restore-ClcIisDeployment -TargetId example -AttemptId $current.attemptId -Mode AcceptCandidate -Reason incident -RecoveryApprovalId manual-recovery } 'Clc.ApprovalMismatch*'
        $manual.sourceCommit=$expectedCommit
        Write-TestJson (Join-Path $fixture.layout.approvalCatalogRoot 'manual-recovery.json') $manual
        (Restore-ClcIisDeployment -TargetId example -AttemptId $current.attemptId -Mode AcceptCandidate -Reason incident -RecoveryApprovalId manual-recovery).status | Should -Be AcceptedCandidate
    }
    It 'retains backups and requires explicit recovery after replacement/readiness failure' {
        $global:ClcLifecycle.ready=$false
        Mock -ModuleName CLC.Deployment Get-ClcReadinessElapsed { return 120 }
        Test-TestRejection { Invoke-Automation $fixture $auto } 'Clc.ReadinessFailed*'
        $j=Get-Content -LiteralPath (Join-Path $fixture.controlRoot 'journal.json') -Raw | ConvertFrom-Json
        $j.phase | Should -Be RecoveryRequired; $fixture.iis.poolState | Should -Be Stopped
        $backup=Join-Path $fixture.controlRoot ('backups\'+$j.attemptId+'\index.json')
        Test-Path -LiteralPath $backup | Should -BeTrue
        Test-TestRejection { Invoke-Automation $fixture $auto } 'Clc.AutomationRequiresBaseline*'
    }
}

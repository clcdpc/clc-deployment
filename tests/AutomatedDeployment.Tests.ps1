BeforeAll {
    . "$PSScriptRoot/Support.ps1"
    . "$PSScriptRoot/T2Support.ps1"
    . "$PSScriptRoot/T3Support.ps1"
    function New-AutomationFixture {
        param($Fixture,[string] $Tag='v1.0.0-dev.2')
        $tagInfo=Invoke-T2Private Get-ClcDeploymentTag @($Tag)
        $build=Join-Path $Fixture.workspace $tagInfo.releaseId
        [void][IO.Directory]::CreateDirectory($build)
        $inputs=New-TestPublish $build
        $metadata=Get-TestMetadata; $metadata.releaseId=$tagInfo.releaseId; $metadata.source.commit='2'*40
        Write-TestJson $inputs.MetadataPath $metadata
        [IO.File]::WriteAllText((Join-Path $inputs.PublishRoot 'Probe.dll'),('Synthetic automated DLL '+$Tag))
        $package=New-ClcRelease @inputs
        $Fixture.dllIdentities[(Get-FileHash -LiteralPath (Join-Path $inputs.PublishRoot 'Probe.dll')).Hash]=$metadata
        Copy-Item -LiteralPath $package.archivePath -Destination (Join-Path $Fixture.target.artifactInboxRoot ($tagInfo.releaseId+'.zip'))
        $bundle=Join-Path $Fixture.target.artifactInboxRoot ($tagInfo.releaseId+'.sigstore.json')
        [IO.File]::WriteAllText($bundle,'synthetic bundle; verifier boundary is mocked')
        $root=Join-Path $Fixture.layout.approvalCatalogRoot 'standing'; [void][IO.Directory]::CreateDirectory($root)
        $s=Get-Content -LiteralPath (Join-Path $script:FixtureRoot 'standing-authorization.json') -Raw | ConvertFrom-Json -AsHashtable
        $s.targetId=$Fixture.target.targetId; $s.applicationId=$Fixture.target.applicationId; $s.environmentName=$Fixture.target.environmentName
        $s.sourceRepository=$metadata.source.repository; $s.producer.buildWorkflowPath=$metadata.build.workflowPath; $s.producer.buildJob=$metadata.build.job
        $s.verifier.path=Join-Path $Fixture.workspace 'binaries\gh.exe'; $s.verifier.trustedRootPath=Join-Path $Fixture.workspace 'binaries\trusted-root.json'
        [IO.File]::WriteAllText($s.verifier.path,'synthetic trusted verifier; never executed')
        [IO.File]::WriteAllText($s.verifier.trustedRootPath,'synthetic trusted root')
        $s.verifier.sha256=(Get-FileHash -LiteralPath $s.verifier.path).Hash.ToLowerInvariant()
        $s.verifier.trustedRootSha256=(Get-FileHash -LiteralPath $s.verifier.trustedRootPath).Hash.ToLowerInvariant()
        $path=Join-Path $root ($s.standingAuthorizationId+'.json'); Write-TestJson $path $s
        $p=[ordered]@{contractFamily='clc-file-iis-v1';schemaVersion=1;recordKind='automated-provenance';targetId=$s.targetId;applicationId=$s.applicationId;
            releaseId=$metadata.releaseId;tag=$Tag;sourceRepository=$metadata.source.repository;sourceCommit=$metadata.source.commit;
            releaseZipSha256=$package.archiveSha256;manifestSha256=$package.manifestSha256;
            provenance=@{workflowPath=$metadata.build.workflowPath;runId=$metadata.build.runId;runAttempt=$metadata.build.runAttempt;buildJob=$metadata.build.job;artifactId=2;transportSha256=('f'*64)}}
        $ref='refs/tags/'+$Tag
        $c=@{issuer='https://token.actions.githubusercontent.com';sourceRepositoryURI=('https://github.com/'+$s.sourceRepository);sourceRepositoryDigest=$p.sourceCommit;sourceRepositoryRef=$ref;
            sourceRepositoryIdentifier=$s.sourceRepositoryId;sourceRepositoryOwnerIdentifier=$s.sourceOwnerId;
            buildSignerURI=('https://github.com/'+$s.producer.repository+'/'+$s.producer.workflowPath+'@'+$s.producer.sourceCommit);
            buildSignerDigest=$s.producer.sourceCommit;buildTrigger='push';runnerEnvironment='github-hosted';
            buildConfigURI=('https://github.com/'+$s.sourceRepository+'/'+$s.producer.buildWorkflowPath+'@'+$ref);
            runInvocationURI=('https://github.com/'+$s.sourceRepository+'/actions/runs/'+$p.provenance.runId+'/attempts/'+$p.provenance.runAttempt)}
        $global:ClcAutomation=@{predicate=$p;certificate=$c;arguments=@();exitCode=0}
        return @{standing=$s;path=$path;tag=$Tag;package=$package;bundle=$bundle;releaseId=$tagInfo.releaseId}
    }
    function Invoke-Automation {
        param($Fixture,$Automation)
        Invoke-ClcIisDeployment -TargetId $Fixture.target.targetId -StandingAuthorizationId $Automation.standing.standingAuthorizationId -ReleaseTag $Automation.tag
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
            Test-TestRejection { Invoke-ClcIisDeployment -TargetId example -StandingAuthorizationId example-dev -ReleaseTag v1.0.0-dev.1 } 'Clc.AutomationRequiresBaseline*'
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
        Mock -ModuleName CLC.Deployment Start-ClcAttestationVerifier {
            $global:ClcAutomation.arguments=$Arguments
            return Start-T3HarmlessHelper (@(@{predicate=$global:ClcAutomation.predicate;certificate=$global:ClcAutomation.certificate}) | ConvertTo-Json -Depth 24 -Compress -AsArray) $global:ClcAutomation.exitCode
        }
        $global:ClcLifecycle.operations.Clear()
    }
    AfterEach { Remove-TestWorkspace $fixture.workspace }
    It 'admits successive authenticated releases and makes identical retries NoOp' {
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
        $global:ClcAutomation.arguments | Should -Contain '--signer-digest'
        $global:ClcAutomation.arguments | Should -Contain '--source-ref'
        $global:ClcAutomation.arguments | Should -Contain '--custom-trusted-root'
        $global:ClcAutomation.arguments | Should -Contain '--deny-self-hosted-runners'
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
    It 'rejects fabricated certificate <Field>' -ForEach @(
        @{Field='issuer'},@{Field='sourceRepositoryURI'},@{Field='sourceRepositoryDigest'},@{Field='sourceRepositoryRef'},@{Field='sourceRepositoryIdentifier'},
        @{Field='sourceRepositoryOwnerIdentifier'},@{Field='buildSignerURI'},@{Field='buildSignerDigest'},@{Field='buildTrigger'},
        @{Field='runnerEnvironment'},@{Field='buildConfigURI'},@{Field='runInvocationURI'}
    ) {
        $global:ClcAutomation.certificate[$Field]='fabricated'
        $before=Get-T2TreeHashes $fixture
        Test-TestRejection { Invoke-Automation $fixture $auto } 'Clc.ProvenanceRejected*'
        (Get-T2TreeHashes $fixture) | Should -BeExactly $before
        $global:ClcLifecycle.operations.Count | Should -Be 0
    }
    It 'rejects signed predicate <Field> mismatch' -ForEach @(
        @{Field='targetId';Value='other'},@{Field='applicationId';Value='other'},@{Field='sourceRepository';Value='other/repo'},
        @{Field='sourceCommit';Value=('9'*40)},@{Field='releaseZipSha256';Value=('9'*64)},@{Field='manifestSha256';Value=('9'*64)},@{Field='releaseId';Value='other'}
    ) {
        $global:ClcAutomation.predicate[$Field]=$Value
        $before=Get-T2TreeHashes $fixture
        Test-TestRejection { Invoke-Automation $fixture $auto }
        (Get-T2TreeHashes $fixture) | Should -BeExactly $before
    }
    It 'rejects failed crypto, modified verifier, root or archive' -ForEach @(@{Mode='signature'},@{Mode='verifier'},@{Mode='root'},@{Mode='archive'},@{Mode='verifier-parent'}) {
        switch ($Mode) {
            signature { $global:ClcAutomation.exitCode=1 }
            verifier { [IO.File]::AppendAllText($auto.standing.verifier.path,'tamper') }
            root { [IO.File]::AppendAllText($auto.standing.verifier.trustedRootPath,'tamper') }
            archive { [IO.File]::AppendAllText((Join-Path $fixture.target.artifactInboxRoot ($auto.releaseId+'.zip')),'tamper') }
            verifier-parent {
                $global:ClcUnsafeVerifierParent=[IO.Path]::GetDirectoryName($auto.standing.verifier.path)
                Mock -ModuleName CLC.Deployment Assert-ClcAccess { if ($Path -ceq $global:ClcUnsafeVerifierParent) { throw 'Synthetic runtime sibling-file creation' }; return (Invoke-T2Private Get-ClcSecurityObservation @($Path)).sha256 }
            }
        }
        $before=Get-T2TreeHashes $fixture
        Test-TestRejection { Invoke-Automation $fixture $auto }
        (Get-T2TreeHashes $fixture) | Should -BeExactly $before
        $global:ClcLifecycle.operations.Count | Should -Be 0
    }
    It 'rejects artifact-only tags before invoking the verifier' -ForEach @(@{Tag='v1.0.0-beta.1'},@{Tag='v1.0.0-rc.1'}) {
        Test-TestRejection { Invoke-ClcIisDeployment -TargetId example -StandingAuthorizationId $auto.standing.standingAuthorizationId -ReleaseTag $Tag } 'Clc.StandingAuthorizationRejected*'
        Should -Invoke -ModuleName CLC.Deployment Start-ClcAttestationVerifier -Times 0 -Exactly
    }
    It 'does not let saved generated approval IDs bypass revocation or grant downgrade' {
        $null=Invoke-Automation $fixture $auto
        $current=Get-Content -LiteralPath (Join-Path $fixture.controlRoot 'current.json') -Raw | ConvertFrom-Json
        Test-TestRejection { Invoke-ClcIisDeployment -TargetId example -ReleaseApprovalId $current.release.approvalId -AllowDowngrade -Reason incident } 'Clc.DowngradeRejected*'
        $auto.standing.enabled=$false; Write-TestJson $auto.path $auto.standing
        Test-TestRejection { Invoke-ClcIisDeployment -TargetId example -ReleaseApprovalId $current.release.approvalId } 'Clc.StandingAuthorizationRejected*'
    }
    It 'rejects conflicting reuse of a release identity without overwriting authority' {
        $null=Invoke-Automation $fixture $auto
        [IO.File]::AppendAllText($auto.bundle,'different bundle')
        $before=Get-T2TreeHashes $fixture
        Test-TestRejection { Invoke-Automation $fixture $auto } 'Clc.ReleaseIdentityConflict*'
        (Get-T2TreeHashes $fixture) | Should -BeExactly $before
    }
    It 'retains interrupted admission intent and refuses repair' {
        $global:ClcAdmissionDestination=Join-Path $fixture.target.artifactInboxRoot ('auto-'+(Invoke-T2Private Get-ClcBytesHash @(,[Text.Encoding]::UTF8.GetBytes($fixture.target.targetId+[char]0+$auto.releaseId))).Substring(0,59)+'.zip')
        [IO.File]::WriteAllText($global:ClcAdmissionDestination,'unexpected destination')
        try { Invoke-Automation $fixture $auto; throw 'Expected admission failure.' }
        catch {
            $_.FullyQualifiedErrorId | Should -BeLike 'Clc.AdmissionIncomplete*'
            $_.Exception.Message | Should -Match 'infrastructure maintenance'
            $_.Exception.Message | Should -Match 'standing.*example.pending'
        }
        @(Get-ChildItem -LiteralPath (Join-Path $fixture.layout.approvalCatalogRoot 'standing') -Filter '*.pending').Count | Should -Be 1
        Test-TestRejection { Invoke-Automation $fixture $auto } 'Clc.AdmissionIncomplete*'
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

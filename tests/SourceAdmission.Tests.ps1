BeforeAll {
    . "$PSScriptRoot/Support.ps1"
    . "$PSScriptRoot/T2Support.ps1"
    . "$PSScriptRoot/T3Support.ps1"
    . "$PSScriptRoot/HookSupport.ps1"
    function New-SourceAdmissionFixture {
        param($Fixture,[string] $Reference='refs/heads/main',[long] $RunId=100,[string] $SourceClass='ProtectedBranch',[switch] $Hooks)
        $commit=$RunId.ToString('x40')
        $isSnapshot=$Reference.StartsWith('refs/heads/')
        $tagInfo=if (-not $isSnapshot) { Invoke-T2Private Get-ClcDeploymentTag @($Reference) }
        $releaseId=if ($isSnapshot) {'dev-'+$RunId+'-'+$commit.Substring(0,12)} else {$tagInfo.releaseId}
        $channel=if ($isSnapshot) {'DEV'} else {$tagInfo.channel}
        $build=Join-Path $Fixture.workspace ('source-'+$RunId); $null=[IO.Directory]::CreateDirectory($build)
        $inputs=New-TestPublish $build
        $metadata=Get-TestMetadata; $metadata.releaseId=$releaseId; $metadata.source.commit=$commit; $metadata.build.runId=$RunId
        if ($Hooks) {
            $metadata.schemaVersion=2L; $metadata.changeKind='application-deployment'
            $metadata.hooks=@{contractVersion=1L;stages=@(@{stage='BeforeStop';entryPoint='hooks/before.ps1'});planningEntryPoint=$null}
            $inputs.HookRoot=Join-Path $build 'hook-input'; $null=[IO.Directory]::CreateDirectory($inputs.HookRoot)
            [IO.File]::WriteAllText((Join-Path $inputs.HookRoot 'before.ps1'),'# Inert fixture: execution is mocked by Set-HookMocks.')
        }
        Write-TestJson $inputs.MetadataPath $metadata
        [IO.File]::WriteAllText((Join-Path $inputs.PublishRoot 'Probe.dll'),('Source admission '+$RunId))
        $package=New-ClcRelease @inputs
        $Fixture.dllIdentities[(Get-FileHash -LiteralPath (Join-Path $inputs.PublishRoot 'Probe.dll')).Hash]=$metadata
        $root=Join-Path $Fixture.layout.approvalCatalogRoot 'standing'; $null=[IO.Directory]::CreateDirectory($root)
        $standing=Get-Content (Join-Path $script:FixtureRoot 'standing-authorization.json') -Raw | ConvertFrom-Json -AsHashtable
        $standing.schemaVersion=2; $standing.targetId=$Fixture.target.targetId; $standing.applicationId=$Fixture.target.applicationId; $standing.environmentName=$Fixture.target.environmentName
        $standing.sourceRepository=$metadata.source.repository; $standing.buildWorkflowPath=$metadata.build.workflowPath; $standing.buildJob=$metadata.build.job; $standing.channel=$channel
        $standing.sourcePolicy=@{integrationBranch='main';allowUnmergedDevTags=$true;allowSnapshots=$true;allowTestTags=$true}
        $path=Join-Path $root ($standing.standingAuthorizationId+'.json'); Write-TestJson $path $standing
        $source=@{contractVersion=1L;kind=$(if ($isSnapshot) {'snapshot'} else {'tag'});sourceClass=$SourceClass;repository=$metadata.source.repository;sourceCommit=$commit;reference=$Reference;releaseId=$releaseId;channel=$channel;
            orderingKind=$(if ($isSnapshot) {'Snapshot'} else {'SemVer'});sequence=$(if ($isSnapshot) {$RunId} else {$tagInfo.releaseSequence});tag=$(if ($isSnapshot) {$null} else {$Reference});integrationBranch='main';integrationCommit=('b'*40)}
        $identity=@{contractFamily='clc-file-iis-v1';schemaVersion=2;recordKind='verified-release';targetId=$standing.targetId;applicationId=$standing.applicationId;releaseId=$releaseId;tag=$Reference;
            sourceRepository=$metadata.source.repository;sourceCommit=$commit;releaseZipSha256=$package.archiveSha256;manifestSha256=$package.manifestSha256;
            provenance=@{workflowPath=$metadata.build.workflowPath;runId=$RunId;runAttempt=$metadata.build.runAttempt;buildJob=$metadata.build.job;artifactId=$RunId;transportSha256=('f'*64)};sourceIdentity=$source}
        $archive=Join-Path $Fixture.target.artifactInboxRoot ('source-'+$RunId+'.zip'); Copy-Item $package.archivePath $archive
        $evidence=Join-Path $Fixture.target.artifactInboxRoot ('source-'+$RunId+'.json'); Write-TestJson $evidence $identity
        return @{standing=$standing;path=$path;identity=$identity;archive=$archive;evidence=$evidence;reference=$Reference}
    }
    function Invoke-SourceAdmission {
        param($Fixture,$Source)
        Invoke-ClcIisDeployment -TargetId $Fixture.target.targetId -StandingAuthorizationId $Source.standing.standingAuthorizationId -ReleaseTag $Source.reference -ArchivePath $Source.archive -VerifiedReleasePath $Source.evidence
    }
}

Describe 'Fresh source observations retain exact producer identity' {
    BeforeEach {
        $previous=@{schemaVersion=3;lineageId='example';releaseSequence=2;sourceRepository='clcdpc/example';sourceCommit=('a'*40);approvalId='previous';releaseId='v1-0-0-dev-1';releaseZipSha256=('b'*64);manifestSha256=('c'*64);
            provenance=@{workflowPath='.github/workflows/build.yml';runId=10;runAttempt=1;buildJob='build';artifactId=20;transportSha256=('d'*64)};
            admission=@{tag='v1.0.0-dev.1';sourceIdentity=@{orderingKind='SemVer';sourceClass='UnmergedDevTag'}}}
        $candidate=($previous | ConvertTo-Json -Depth 12 | ConvertFrom-Json -AsHashtable); $candidate.approvalId='candidate'; $candidate.admission.sourceIdentity.sourceClass='IntegrationTag'
    }
    It 'accepts newly integrated source observations only for identical source build and package bytes' {
        { Invoke-T2Private Assert-ClcAutomatedOrdering @($candidate,$previous) } | Should -Not -Throw
    }
    It 'rejects changed package bytes in the same producer run after a source classification change' {
        $candidate.releaseZipSha256='f'*64
        Test-TestRejection { Invoke-T2Private Assert-ClcAutomatedOrdering @($candidate,$previous) } 'Clc.ReleaseIdentityConflict*'
    }
    It 'rejects a different artifact identity in the same producer run' {
        $candidate.provenance.artifactId=21
        Test-TestRejection { Invoke-T2Private Assert-ClcAutomatedOrdering @($candidate,$previous) } 'Clc.ReleaseIdentityConflict*'
    }
}

Describe 'Versioned source admission preserves protected authority' {
    BeforeEach {
        $fixture=New-T2Fixture; Set-T2FixtureInModule $fixture; Set-T3Mocks
        $baseline=New-T3Approval $fixture -Sequence 1 -Lineage probe-main
        $null=Invoke-ClcIisDeployment -TargetId example -ReleaseApprovalId $baseline.record.approvalId
        $global:ClcLifecycle.operations.Clear()
    }
    AfterEach { Remove-TestWorkspace $fixture.workspace }
    It 'admits successive ASAP protected-main snapshots under a separate explicit source policy' {
        $first=New-SourceAdmissionFixture $fixture
        (Invoke-SourceAdmission $fixture $first).status | Should -BeExactly 'Deployed'
        $second=New-SourceAdmissionFixture $fixture -RunId 101
        (Invoke-SourceAdmission $fixture $second).status | Should -BeExactly 'Deployed'
        $current=Get-Content (Join-Path $fixture.controlRoot 'current.json') -Raw | ConvertFrom-Json
        $approval=Get-Content (Join-Path $fixture.layout.approvalCatalogRoot ($current.release.approvalId+'.json')) -Raw | ConvertFrom-Json
        $approval.schemaVersion | Should -Be 3
        ($approval | ConvertTo-Json -Depth 16) | Test-Json -SchemaFile (Join-Path $script:RepositoryRoot 'schemas/release-approval.schema.json') | Should -BeTrue
        $approval.admission.sourceIdentity.orderingKind | Should -BeExactly 'Snapshot'
        Test-TestRejection { Invoke-SourceAdmission $fixture $first } 'Clc.DowngradeRejected*'
    }
    It 'admits test tags only with explicitly enabled test channel and source authority' {
        $source=New-SourceAdmissionFixture $fixture -Reference 'v1.0.0-test.1' -SourceClass IntegrationTag
        $source.standing.sourcePolicy.allowTestTags=$false; Write-TestJson $source.path $source.standing
        Test-TestRejection { Invoke-SourceAdmission $fixture $source } 'Clc.StandingAuthorizationRejected*'
        $global:ClcLifecycle.operations.Count | Should -Be 0
        $source.standing.sourcePolicy.allowTestTags=$true; Write-TestJson $source.path $source.standing
        (Invoke-SourceAdmission $fixture $source).status | Should -BeExactly 'Deployed'
    }
    It 'admits tagged unmerged FA and SSRS DEV source only when independently enabled' {
        $source=New-SourceAdmissionFixture $fixture -Reference 'v1.0.0-dev.1' -SourceClass UnmergedDevTag
        $source.standing.sourcePolicy.allowUnmergedDevTags=$false; Write-TestJson $source.path $source.standing
        Test-TestRejection { Invoke-SourceAdmission $fixture $source } 'Clc.StandingAuthorizationRejected*'
        $global:ClcLifecycle.operations.Count | Should -Be 0
        $source.standing.sourcePolicy.allowUnmergedDevTags=$true; Write-TestJson $source.path $source.standing
        (Invoke-SourceAdmission $fixture $source).status | Should -BeExactly 'Deployed'
    }
    It 'propagates unmerged DEV source through standing and hook scope with standing=<Standing> hooks=<Hooks>' -ForEach @(
        @{Standing=$false;Hooks=$true},@{Standing=$true;Hooks=$false},@{Standing=$true;Hooks=$true}
    ) {
        Set-HookMocks
        $policy=New-HookPolicy $fixture
        if ($Hooks) {$policy.record.sourceClasses=@('UnmergedDevTag'); Write-TestJson $policy.path $policy.record}
        $source=New-SourceAdmissionFixture $fixture -Reference 'v1.0.0-dev.1' -SourceClass UnmergedDevTag -Hooks
        $source.standing.sourcePolicy.allowUnmergedDevTags=$Standing; Write-TestJson $source.path $source.standing
        foreach ($entry in @(
            @{value=$source.standing;schema='standing-authorization'},@{value=$source.identity;schema='verified-release'},@{value=$source.identity.sourceIdentity;schema='source-identity'}
        )) {
            $json=$entry.value | ConvertTo-Json -Depth 16
            Test-Json -Json $json -SchemaFile (Join-Path $script:RepositoryRoot ('schemas/'+$entry.schema+'.schema.json')) | Should -BeTrue
        }
        if ($Standing -and $Hooks) {
            (Invoke-SourceAdmission $fixture $source).status | Should -BeExactly Deployed
            @($global:ClcHooks.calls) | Should -Be @('BeforeStop')
            $current=Get-Content (Join-Path $fixture.controlRoot 'current.json') -Raw | ConvertFrom-Json
            $approval=Get-Content (Join-Path $fixture.layout.approvalCatalogRoot ($current.release.approvalId+'.json')) -Raw
            Test-Json -Json $approval -SchemaFile (Join-Path $script:RepositoryRoot 'schemas/release-approval.schema.json') | Should -BeTrue
            ($approval | ConvertFrom-Json).admission.sourceIdentity.sourceClass | Should -BeExactly UnmergedDevTag
        } else {
            Test-TestRejection { Invoke-SourceAdmission $fixture $source } $(if ($Standing) {'Clc.HookAuthorizationRejected*'} else {'Clc.StandingAuthorizationRejected*'})
            $global:ClcLifecycle.operations.Count | Should -Be 0; $global:ClcHooks.calls.Count | Should -Be 0
        }
    }
    It 'rejects unmerged source classification on non-DEV tag <Reference> before application execution' -ForEach @(
        @{Reference='v1.0.0'},@{Reference='v1.0.0-beta.1'},@{Reference='v1.0.0-rc.1'},@{Reference='v1.0.0-test.1'}
    ) {
        $source=New-SourceAdmissionFixture $fixture -Reference $Reference -SourceClass UnmergedDevTag
        Test-TestRejection { Invoke-T2Private Assert-ClcSourceIdentity @($source.identity.sourceIdentity) } 'Clc.InvalidContract*'
        # Artifact-only channels have no standing deployment policy and refuse
        # at that earlier authority boundary; all other channels reach evidence.
        $expected=if ($source.standing.channel -ceq 'ArtifactOnly') {'Clc.StandingAuthorizationRejected*'} else {'Clc.InvalidContract*'}
        Test-TestRejection { Invoke-SourceAdmission $fixture $source } $expected
        $global:ClcLifecycle.operations.Count | Should -Be 0
    }
    It 'rejects changed integration branch scope before application execution' -ForEach @(@{Reference='refs/heads/main';SourceClass='ProtectedBranch'},@{Reference='v1.0.0-dev.1';SourceClass='UnmergedDevTag'}) {
        $source=New-SourceAdmissionFixture $fixture -Reference $Reference -SourceClass $SourceClass
        $source.standing.sourcePolicy.integrationBranch='other'; Write-TestJson $source.path $source.standing
        Test-TestRejection { Invoke-SourceAdmission $fixture $source } 'Clc.StandingAuthorizationRejected*'
        $global:ClcLifecycle.operations.Count | Should -Be 0
    }
    It 'keeps snapshot and semantic ordering incomparable within one automated lineage' {
        $snapshot=New-SourceAdmissionFixture $fixture
        $null=Invoke-SourceAdmission $fixture $snapshot
        $tag=New-SourceAdmissionFixture $fixture -Reference 'v1.0.0-dev.1' -RunId 101 -SourceClass IntegrationTag
        $global:ClcLifecycle.operations.Clear()
        Test-TestRejection { Invoke-SourceAdmission $fixture $tag } 'Clc.DowngradeRejected*'
        $global:ClcLifecycle.operations.Count | Should -Be 0
    }
    It 'rechecks revocation on direct schema3 exact-approval retries' {
        $source=New-SourceAdmissionFixture $fixture
        $null=Invoke-SourceAdmission $fixture $source
        $current=Get-Content (Join-Path $fixture.controlRoot 'current.json') -Raw | ConvertFrom-Json
        $source.standing.enabled=$false; Write-TestJson $source.path $source.standing
        $global:ClcLifecycle.operations.Clear()
        Test-TestRejection { Invoke-ClcIisDeployment -TargetId example -ReleaseApprovalId $current.release.approvalId } 'Clc.StandingAuthorizationRejected*'
        $global:ClcLifecycle.operations.Count | Should -Be 0
    }
    It 'cannot reuse a retained semantic approval across an independently switched snapshot baseline' {
        $tag=New-SourceAdmissionFixture $fixture -Reference 'v1.0.0-dev.1' -SourceClass IntegrationTag
        $null=Invoke-SourceAdmission $fixture $tag
        $tagCurrent=Get-Content (Join-Path $fixture.controlRoot 'current.json') -Raw | ConvertFrom-Json
        $null=Invoke-ClcIisDeployment -TargetId example -ReleaseApprovalId $baseline.record.approvalId -AllowDowngrade -Reason maintenance
        $snapshot=New-SourceAdmissionFixture $fixture -RunId 101
        $null=Invoke-SourceAdmission $fixture $snapshot
        $global:ClcLifecycle.operations.Clear()
        Test-TestRejection { Invoke-ClcIisDeployment -TargetId example -ReleaseApprovalId $tagCurrent.release.approvalId } 'Clc.DowngradeRejected*'
        $global:ClcLifecycle.operations.Count | Should -Be 0
    }
    It 'rejects mismatched source identity before approval creation' {
        $source=New-SourceAdmissionFixture $fixture
        $source.identity.sourceIdentity.sourceCommit='9'*40; Write-TestJson $source.evidence $source.identity
        Test-TestRejection { Invoke-SourceAdmission $fixture $source } 'Clc.InvalidContract*'
        $global:ClcLifecycle.operations.Count | Should -Be 0
    }
}

BeforeAll {
    . "$PSScriptRoot/../../Support.ps1"
    . "$PSScriptRoot/../Scripts/Qualification.Process.ps1"
    $script:definitions=Get-QScenarioDefinitions
}
Describe 'Qualification admission and honest evidence' {
    BeforeEach { $script:workspace=New-TestWorkspace }
    AfterEach { Remove-TestWorkspace $script:workspace }
    It 'validates the synthetic configuration template against the strict schema but refuses executing it' {
        $path=Join-Path $script:RepositoryRoot 'tests/Qualification/Configuration/example.template.json'
        Test-Json -Json (Get-Content -LiteralPath $path -Raw) -SchemaFile (Join-Path $script:RepositoryRoot 'tests/Qualification/Configuration/qualification.schema.json') | Should -BeTrue
        { Read-QConfiguration $path } | Should -Throw '*concrete disposable target*'
    }
    It 'defaults to read-only preflight and refuses an unspecified host without creating output' {
        $output=Join-Path $workspace 'report'
        { & (Join-Path $script:RepositoryRoot 'tests/Qualification/Scripts/Invoke-IisQualification.ps1') -OutputRoot $output } | Should -Throw '*concrete selected configuration*'
        Test-Path -LiteralPath $output | Should -BeFalse
    }
    It 'rejects non-disposable and unknown configuration fields before host queries' {
        $config=Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'tests/Qualification/Configuration/example.template.json') -Raw | ConvertFrom-Json -AsHashtable
        $config.templateOnly=$false; $config.disposable=$false; $path=Join-Path $workspace 'invalid.json'; Write-TestJson $path $config
        { Read-QConfiguration $path } | Should -Throw
        $config.disposable=$true; $config.command='arbitrary-code'; Write-TestJson $path $config
        { Read-QConfiguration $path } | Should -Throw
    }
    It 'refuses a concrete but unauthorized machine selection without creating evidence or IIS resources' {
        $config=Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'tests/Qualification/Configuration/example.template.json') -Raw | ConvertFrom-Json -AsHashtable
        $config.templateOnly=$false; $config.machineIdentity='11111111-1111-1111-1111-111111111111'; $config.computerName='NOT-THE-AUTHORIZED-HOST'
        $path=Join-Path $workspace 'unauthorized.json'; Write-TestJson $path $config
        $output=Join-Path $workspace 'refused'
        { & (Join-Path $script:RepositoryRoot 'tests/Qualification/Scripts/Invoke-IisQualification.ps1') -ConfigurationPath $path -Operation Execute -ScenarioId deploy-initial-started -OutputRoot $output } | Should -Throw
        Test-Path -LiteralPath $output | Should -BeFalse
    }
    It 'accounts for every retained scenario as NOT RUN when no host is designated' {
        $output=Join-Path $workspace 'plan'
        & (Join-Path $script:RepositoryRoot 'tests/Qualification/Scripts/Invoke-IisQualification.ps1') -Operation Plan -OutputRoot $output
        $report=Get-Content -LiteralPath (Join-Path $output 'report.json') -Raw | ConvertFrom-Json -AsHashtable
        $report.results.Count | Should -Be $definitions.Count
        @($report.results | Where-Object status -CNE 'NOT RUN').Count | Should -Be 0
        $report.realHostQualified | Should -BeFalse
        $report.mandatoryExecutionComplete | Should -BeFalse
    }
    It 'rejects partial matrix reports and never equates assertion completion with independent qualification' {
        $results=@($definitions | ForEach-Object { New-QResult $_ 'synthetic-run' })
        { Write-QReport (Join-Path $workspace 'partial') @($results[0]) 'synthetic-run' } | Should -Throw '*every mandatory matrix case*'
        foreach ($result in $results) { $result.status='PASS'; $result.reason='Synthetic report-aggregation test only' }
        Write-QReport (Join-Path $workspace 'all') $results 'synthetic-run'
        $report=Read-DistJson ([IO.File]::ReadAllBytes((Join-Path $workspace 'all\report.json')))
        $report.mandatoryAssertionsPassed | Should -BeTrue
        $report.mandatoryExecutionComplete | Should -BeFalse
        $report.realHostQualified | Should -BeFalse
        $report.independentAcceptance | Should -BeExactly 'Required'
    }
    It 'refuses to suppress a canonical mandatory failure or blocked case through caller metadata' {
        foreach ($status in @('FAIL','BLOCKED')) {
            $results=@($definitions | ForEach-Object { New-QResult $_ 'synthetic-run' })
            foreach ($result in $results) { $result.status='PASS' }
            $results[0].status=$status; $results[0].mandatory=$false
            { Write-QReport (Join-Path $workspace $status) $results 'synthetic-run' -IndependentEvidenceVerified } | Should -Throw '*canonical mandatory*'
        }
    }
    It 'keeps fixed scenario selectors and rejects retired protocol actions' {
        @($definitions.id | Select-Object -Unique).Count | Should -Be $definitions.Count
        @($definitions | Where-Object { $_.action -cin @('Crash','Concurrency','GuardStop') -or $_.variant -cin @('ForeignTemporary','RestoreEmptyRetirement','RestoreEmptyMissingCheckpoint','RetirementCheckpointAltered') }).Count | Should -Be 0
        foreach ($case in $definitions) { $case.expected.Length | Should -BeGreaterThan 10; $case.mandatory | Should -BeTrue }
    }
    It 'observes only functions that exist in the current installed module' {
        foreach ($name in Get-QObservedCommands) {
            & (Get-Module CLC.Deployment) { param($n) (Get-Command $n -CommandType Function -ErrorAction Stop).Name } $name | Should -BeExactly $name
        }
    }
    It 'observes a real module command with an external debugger breakpoint without replacing its function' {
        $global:ClcQualificationCountTest=@{}
        $observedName='Get-ClcToolkitVersion'
        $breakpoint=Set-PSBreakpoint -Command Get-ClcToolkitVersion -Action {
            $global:ClcQualificationCountTest[$observedName]=1
            continue
        }.GetNewClosure()
        try {
            & (Get-Module CLC.Deployment) { Get-ClcToolkitVersion } | Should -BeExactly '0.1.0-dev.1'
            $global:ClcQualificationCountTest.ContainsKey('Get-ClcToolkitVersion') | Should -BeTrue
        } finally { Remove-PSBreakpoint $breakpoint; Remove-Variable ClcQualificationCountTest -Scope Global }
    }
    It 'records stable toolkit identity when prerelease metadata is absent' {
        $module=Get-Module CLC.Deployment
        $stable=[pscustomobject]@{Version=[version]'1.2.3';PrivateData=@{PSData=@{}}}
        & $module { param($Module) Get-ClcToolkitVersion -Module $Module } $stable | Should -BeExactly '1.2.3'
        $withoutPsData=[pscustomobject]@{Version=[version]'2.3.4';PrivateData=@{}}
        & $module { param($Module) Get-ClcToolkitVersion -Module $Module } $withoutPsData | Should -BeExactly '2.3.4'
    }
    It 'rejects malformed present prerelease metadata instead of emitting a trailing separator' {
        $module=Get-Module CLC.Deployment
        $invalid=[pscustomobject]@{Version=[version]'1.2.3';PrivateData=@{PSData=@{Prerelease=''}}}
        { & $module { param($Module) Get-ClcToolkitVersion -Module $Module } $invalid } | Should -Throw
    }
    It 'computes observed timing intervals without treating missing boundaries as zero' {
        $items=@(@{attemptId='synthetic';intent=@{operation='Stop';sequence=1;recordedUtc='2026-10-31T00:00:00Z'};observation=@{sequence=1;result='Stopped';observedUtc='2026-10-31T00:00:02Z'}},
            @{attemptId='synthetic';intent=@{operation='CheckReady';sequence=2;recordedUtc='2026-10-31T00:00:03Z'};observation=@{sequence=2;result='Ready';observedUtc='2026-10-31T00:00:08Z'}})
        $metrics=Get-QJournalMetrics $items
        $metrics.observedOperationIntervals.Count | Should -Be 2
        $metrics.unavailabilityUpperBoundSeconds | Should -Be 8
        (Get-QJournalMetrics @()).unavailabilityUpperBoundSeconds | Should -BeNullOrEmpty
    }
    It 'finds synthetic secrets and private config hashes without printing either value' {
        $evidence=Join-Path $workspace 'safe'; $null=[IO.Directory]::CreateDirectory($evidence)
        $configPath=Join-Path $workspace 'private.json'; $config=@{configurationRevision='privacy';keyStoreCompatibilityId='clc-probe-dpapi-user-v1';syntheticSecret='CLC_PRIVATE_SYNTHETIC_T4'}; Write-TestJson $configPath $config
        $scanner=Join-Path $script:RepositoryRoot 'tests/Qualification/Scripts/Test-QualificationEvidencePrivacy.ps1'
        [IO.File]::WriteAllText((Join-Path $evidence 'report.txt'),'safe report')
        (& $scanner -EvidenceRoot $evidence -OperationalConfigurationPath $configPath).privacyScanPassed | Should -BeTrue
        [IO.File]::WriteAllText((Join-Path $evidence 'report.txt'),$config.syntheticSecret)
        { & $scanner -EvidenceRoot $evidence -OperationalConfigurationPath $configPath } | Should -Throw '*PrivacyViolation*'
        [IO.File]::WriteAllText((Join-Path $evidence 'report.txt'),(Get-DistHash ([IO.File]::ReadAllBytes($configPath))))
        { & $scanner -EvidenceRoot $evidence -OperationalConfigurationPath $configPath } | Should -Throw '*PrivacyViolation*'
    }
    It 'scans XML CSV raw output and UTF16 binary captures and refuses uninspected compressed evidence' {
        $evidence=Join-Path $workspace 'captures'; $null=[IO.Directory]::CreateDirectory($evidence)
        $configPath=Join-Path $workspace 'private.json'; $sentinel='CLC_CAPTURE_SENTINEL_T4'; Write-TestJson $configPath @{syntheticSecret=$sentinel}
        $scanner=Join-Path $script:RepositoryRoot 'tests/Qualification/Scripts/Test-QualificationEvidencePrivacy.ps1'
        foreach ($extension in @('.xml','.csv','.out','.err','.etl')) {
            $path=Join-Path $evidence ('capture'+$extension)
            [IO.File]::WriteAllBytes($path,[Text.Encoding]::Unicode.GetBytes($sentinel))
            { & $scanner -EvidenceRoot $evidence -OperationalConfigurationPath $configPath } | Should -Throw '*PrivacyViolation*'
            [IO.File]::Delete($path)
        }
        [IO.File]::WriteAllBytes((Join-Path $evidence 'uninspected.zip'),[byte[]]@(1,2,3))
        { & $scanner -EvidenceRoot $evidence -OperationalConfigurationPath $configPath } | Should -Throw '*Compressed evidence*'
        [IO.File]::Delete((Join-Path $evidence 'uninspected.zip'))
        foreach ($header in @('504B030400000000','425A683100000000','FD377A585A000000','04224D1800000000','789C000000000000')) {
            [IO.File]::WriteAllBytes((Join-Path $evidence 'renamed.capture'),[Convert]::FromHexString($header))
            { & $scanner -EvidenceRoot $evidence -OperationalConfigurationPath $configPath } | Should -Throw '*renamed containers*'
        }
    }
    It 'selects separate campaign archives without accepting an unapproved or ambiguous evidence namespace' {
        $first=@{campaignId='first';evidenceRoot=(Join-Path $workspace 'first')}; $second=@{campaignId='second';evidenceRoot=(Join-Path $workspace 'second')}
        $path=Join-Path $second.evidenceRoot 'operator-evidence\reviewed\report.json'
        (Select-QReportCampaign $path @($first,$second)).campaignId | Should -BeExactly 'second'
        { Select-QReportCampaign (Join-Path $workspace 'foreign\report.json') @($first,$second) } | Should -Throw '*exactly one*'
        { Select-QReportCampaign $path @($second,$second) } | Should -Throw '*exactly one*'
    }
    It 'blocks synthetic padding as representative performance and refuses a mislabeled release profile' {
        . "$PSScriptRoot/../Scripts/Qualification.Scenarios.ps1"
        $manifest=@{source=@{commit=('a'*40)};build=@{dependencyLockSha256=('b'*64)};files=@(@{length=100})}
        $inputs=@{profile='Large';failureKind='None';sourceCommit=('a'*40);packageLockSha256=('b'*64);representative=$null}
        Assert-QWorkload $manifest $inputs Large | Should -BeFalse
        { Assert-QWorkload $manifest $inputs Small } | Should -Throw '*profile/build pins*'
        $inputs.profile='Comparable8MiB'
        { Assert-QWorkload $manifest $inputs Comparable8MiB } | Should -Throw '*68 files*'
    }
    It 'rejects forged PASS records with absent primary artifacts despite matching declared pins' {
        $definition=@($definitions | Where-Object action -CEQ 'Deploy')[0]
        $candidate=New-QResult $definition 'synthetic'
        $candidate.status='PASS'; $candidate.sourceCommit='a'*40; $candidate.installedDistributionSha256='b'*64; $candidate.environmentFingerprint='c'*64
        $candidate.actual=@{evidenceKind='Automatic'}; $candidate.supportingEvidencePath=Join-Path $workspace 'nonexistent'; $candidate.supportingEvidenceSha256='d'*64
        $review=@{sourceRoot=$workspace;sourceCommit=('a'*40);distributionSha256=('b'*64);approvedBySid='S-1-5-18'}
        { Confirm-QCandidateEvidence $candidate $definition $review $workspace } | Should -Throw
    }
    It 'binds an actual case receipt and artifact hash and rejects later primary tampering' {
        $definition=@($definitions | Where-Object action -CEQ 'Deploy')[0]; $caseRoot=Join-Path $workspace 'case'; $null=[IO.Directory]::CreateDirectory($caseRoot)
        $primary=Join-Path $caseRoot 'before.json'; Write-QJson $primary @{observation='synthetic native fixture only'}
        $candidate=New-QResult $definition 'synthetic'; $candidate.status='PASS'; $candidate.sourceCommit='a'*40; $candidate.installedDistributionSha256='b'*64; $candidate.environmentFingerprint='c'*64
        $candidate.actual=@{evidenceKind='Automatic'}; $candidate.supportingEvidencePath=$caseRoot; $candidate.evidenceArtifacts=@(@{path=$primary;sha256=(Get-FileHash -LiteralPath $primary).Hash.ToLowerInvariant()})
        $receipt=Join-Path $caseRoot 'scenario-result.json'; Write-QJson $receipt $candidate; $candidate.supportingEvidenceSha256=(Get-FileHash -LiteralPath $receipt).Hash.ToLowerInvariant()
        $review=@{sourceRoot=$workspace;sourceCommit=('a'*40);distributionSha256=('b'*64);approvedBySid='S-1-5-18'}
        { Confirm-QCandidateEvidence $candidate $definition $review $workspace } | Should -Not -Throw
        [IO.File]::WriteAllText($primary,'changed')
        { Confirm-QCandidateEvidence $candidate $definition $review $workspace } | Should -Throw '*bytes differ*'
    }
    It 'refuses a foreign IIS binding or pool configuration before cleanup' {
        . "$PSScriptRoot/../Scripts/Qualification.Ownership.ps1"
        $baseline=@{siteId=42;bindings=@(@{host='synthetic.invalid';port=4443});poolConfigurationSha256=('a'*64)}
        $foreign=@{siteId=42;bindings=@(@{host='synthetic.invalid';port=4443},@{host='foreign.invalid';port=4443});poolConfigurationSha256=('a'*64)}
        { Assert-QIisOwnershipSnapshot $baseline $foreign } | Should -Throw '*drifted*'
        $foreign.bindings=$baseline.bindings; $foreign.poolConfigurationSha256='b'*64
        { Assert-QIisOwnershipSnapshot $baseline $foreign } | Should -Throw '*drifted*'
        { Assert-QIisOwnershipSnapshot $baseline $baseline } | Should -Not -Throw
        $configuration=@{siteName='owned';poolName='owned-pool'}; $manager=@{Sites=@(@{Name='owned';Applications=@(@{ApplicationPoolName='owned-pool'})})}
        { Assert-QNoForeignPoolApplications $manager $configuration } | Should -Not -Throw
        $manager.Sites+=@{Name='foreign-added-during-stop';Applications=@(@{ApplicationPoolName='OWNED-POOL'})}
        { Assert-QNoForeignPoolApplications $manager $configuration } | Should -Throw '*shares the pool*'
    }
    It 'observes IIS configuration structure without reading a password value' {
        . "$PSScriptRoot/../Scripts/Qualification.Ownership.ps1"
        $attribute=[pscustomobject]@{Name='password'}; $attribute | Add-Member ScriptProperty Value { throw 'Credential value must never be read' }
        $element=[pscustomobject]@{Attributes=@($attribute);ChildElements=@();Schema=[pscustomobject]@{Name='processModel';CollectionSchema=$null}}
        (Convert-QIisElement $element pool).attributes.password | Should -BeExactly 'ProtectedValueNotRead'
    }
    It 'requires every readiness address to match the owned IPv4 loopback binding' {
        { Assert-QReadinessAddresses @([Net.IPAddress]::Parse('127.0.0.1')) } | Should -Not -Throw
        { Assert-QReadinessAddresses @([Net.IPAddress]::Parse('127.0.0.1'),[Net.IPAddress]::Parse('198.51.100.1')) } | Should -Throw '*exclusively*'
        { Assert-QReadinessAddresses @([Net.IPAddress]::Parse('::1')) } | Should -Throw
        { Assert-QReadinessAddresses @() } | Should -Throw
    }
    It 'probes actual DACL and owner access without changing file bytes or security' {
        $path=Join-Path $workspace 'owned.txt'; [IO.File]::WriteAllText($path,'owned access probe')
        $before=(Get-Acl -LiteralPath $path).Sddl; $bytes=(Get-FileHash -LiteralPath $path).Hash
        Initialize-DistNativePaths
        [Clc.Distribution.Paths]::ProbeAccess($path,$false,0x40000) | Should -BeTrue
        [Clc.Distribution.Paths]::ProbeAccess($path,$false,0x80000) | Should -BeTrue
        (Get-Acl -LiteralPath $path).Sddl | Should -BeExactly $before
        (Get-FileHash -LiteralPath $path).Hash | Should -BeExactly $bytes
    }
}

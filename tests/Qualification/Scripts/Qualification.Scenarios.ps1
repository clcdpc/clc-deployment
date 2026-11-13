. "$PSScriptRoot/Qualification.Process.ps1"
$script:QContext=$null; $script:QTarget=$null
function Open-QObservationContext($Configuration) {
    $script:QContext=Invoke-QPrivate Open-ClcTrustedContext
    try { $file=Invoke-QPrivate Read-ClcProtectedTarget @($script:QContext,$Configuration.targetId); $script:QTarget=$file.record }
    catch { Close-QObservationContext; throw }
}
function Close-QObservationContext {
    if ($null -ne $script:QContext) { Invoke-QPrivate Close-ClcTrustedContext @($script:QContext); $script:QContext=$null }
}
function Get-QStateAndPool($Configuration) {
    $pool=Get-QPoolObservation $Configuration; $records=@{}
    foreach ($name in @('journal','current')) {
        $path=Join-Path (Get-QControlRoot $Configuration) ($name+'.json')
        $records[$name]=if ([IO.File]::Exists($path)) { Get-DistHash ([IO.File]::ReadAllBytes($path)) } else { $null }
    }
    @{poolState=$pool.poolState;workerCount=$pool.workers.Count;records=$records}
}
function Read-QManifest($Configuration,[string] $Slot) {
    $release=$Configuration.probeReleases[$Slot]
    $archive=Join-Path $Configuration.artifactInboxRoot ($release.approvalId+'.zip')
    $inspection=Test-ClcRelease -ArchivePath $archive
    if ($inspection.archiveSha256 -cne $release.archiveSha256 -or $inspection.manifestSha256 -cne $release.manifestSha256 -or $inspection.sourceCommit -cne $release.sourceCommit -or $inspection.releaseId -cne $release.releaseId) { throw 'Probe fixture bytes differ from campaign.' }
    $zip=[IO.Compression.ZipFile]::OpenRead($archive)
    try { Read-DistJson (Read-DistEntry $zip.GetEntry('manifest.json') 4194304) } finally { $zip.Dispose() }
}
function Read-QRetainedManifest($Configuration,[string] $Slot) {
    $release=$Configuration.probeReleases[$Slot]
    $path=Join-Path (Get-QControlRoot $Configuration) ('releases\'+$release.approvalId+'.json')
    $bytes=Read-DistFileBytes $path
    if ((Get-DistHash $bytes) -cne $release.manifestSha256) { throw 'Retained manifest differs from the selected release.' }
    $manifest=Invoke-QPrivate Read-ClcJson @($bytes,'release-manifest')
    if ($manifest.releaseId -cne $release.releaseId -or $manifest.source.commit -cne $release.sourceCommit) { throw 'Retained release identity differs.' }
    $manifest
}
function Get-QCurrentSlot($Configuration,$Snapshot) {
    if ($null -eq $Snapshot.state.current) { throw 'This scenario requires an established current release.' }
    $current=$Snapshot.state.current.safe.release
    $slots=@('initial','newer' | Where-Object {
        $release=$Configuration.probeReleases[$_]
        $current.approvalId -ceq $release.approvalId -and $current.releaseId -ceq $release.releaseId -and $current.sourceCommit -ceq $release.sourceCommit -and
            $current.archiveSha256 -ceq $release.archiveSha256 -and $current.manifestSha256 -ceq $release.manifestSha256
    })
    if ($slots.Count -ne 1) { throw 'Current release is not an exact campaign release.' }
    $slots[0]
}
function Read-QBuildInputs($Configuration,[string] $Slot,$Manifest) {
    $release=$Configuration.probeReleases[$Slot]; $archive=Join-Path $Configuration.artifactInboxRoot ($release.approvalId+'.zip')
    $zip=[IO.Compression.ZipFile]::OpenRead($archive)
    try {
        $bytes=Read-DistEntry $zip.GetEntry('application/qualification-build-inputs.json') 4194304
        $record=@($Manifest.files | Where-Object path -CEQ 'application/qualification-build-inputs.json')
        if ($record.Count -ne 1 -or $record[0].sha256 -cne (Get-DistHash $bytes) -or $record[0].length -ne $bytes.Length) { throw 'Workload provenance is not an inventoried exact release file.' }
        Read-DistJson $bytes
    } finally { $zip.Dispose() }
}
function Assert-QWorkload($Manifest,$Inputs,[string] $Profile) {
    if ($Inputs.profile -cne $Profile -or $Inputs.failureKind -cne 'None' -or $Inputs.sourceCommit -cne $Manifest.source.commit -or $Inputs.packageLockSha256 -cne $Manifest.build.dependencyLockSha256) { throw 'Actual workload profile/build pins differ from the selected case.' }
    if ($Profile -ceq 'Comparable8MiB' -and ($Manifest.files.Count -ne 68 -or [long](($Manifest.files | Measure-Object length -Sum).Sum) -ne 8388608)) { throw 'Comparable workload must contain exactly 68 files and 8 MiB.' }
    if ($Profile -cin @('FrameworkPublish','Large') -and $null -eq $Inputs.representative) { return $false }
    $true
}
function Get-QHttpClient {
    $handler=[Net.Http.HttpClientHandler]::new(); $handler.AllowAutoRedirect=$false; $handler.UseCookies=$false; $handler.UseDefaultCredentials=$false; $handler.UseProxy=$false; $handler.CheckCertificateRevocationList=$true
    $client=[Net.Http.HttpClient]::new($handler); $client.Timeout=[TimeSpan]::FromSeconds(5)
    $client
}
function Assert-QReady($Configuration,$Manifest) {
    $response=Invoke-QPrivate Invoke-ClcReadinessRequest @($Configuration.readinessUri)
    $config=Read-DistJson ([IO.File]::ReadAllBytes($Configuration.operationalConfigPath))
    if (-not $response.Accepted -or -not (Invoke-QPrivate Test-ClcReadinessIdentity @($response.Bytes,$Manifest,@{runtimeEnvironment=$Configuration.runtimeEnvironment;revision=$config.configurationRevision}))) { throw 'Independent expected-release HTTPS readiness failed.' }
    $pool=Get-QPoolObservation $Configuration
    if ($pool.poolState -cne 'Started' -or $pool.workers.Count -ne 1) { throw 'Readiness has no exact single running worker.' }
}
function Assert-QLifecycleResult($Configuration,$WorkerResult,$After,[string] $Status,[string] $Slot) {
    if (-not $WorkerResult.success -or $WorkerResult.result.status -cne $Status -or $After.state.journal.safe.phase -cne 'Completed' -or $After.state.journal.safe.outcome -cne $Status) { throw 'Public lifecycle result and durable terminal differ.' }
    $manifest=Read-QRetainedManifest $Configuration $Slot
    $null=Invoke-QPrivate Get-ClcTreeInventory @($Configuration.applicationRoot,$manifest.files)
    if ($After.state.current.safe.release.releaseId -cne $manifest.releaseId -or $After.state.current.safe.release.sourceCommit -cne $manifest.source.commit) { throw 'Durable current identity differs.' }
    Assert-QReady $Configuration $manifest
    Assert-QTerminalEvidence $Configuration $After
}
function Assert-QTerminalEvidence($Configuration,$Snapshot) {
    $journal=$Snapshot.state.journal.safe
    $name=if ($null -eq $journal.recovery) {'deployment.json'} else {'recovery-'+$journal.recovery.sequence+'.json'}
    $path=Join-Path (Get-QControlRoot $Configuration) ('attempts\'+$journal.attemptId+'\'+$name)
    if ((Get-DistHash ([IO.File]::ReadAllBytes($path))) -cne $Snapshot.state.journal.sha256) { throw 'Completed phase journal and terminal snapshot differ.' }
}
function Assert-QBackupAndPublication($Configuration,$Before,$After) {
    $journal=$After.state.journal.safe; $root=Get-QControlRoot $Configuration
    $indexPath=Join-Path $root ('backups\'+$journal.attemptId+'\index.json')
    $bytes=[IO.File]::ReadAllBytes($indexPath); $index=Read-DistJson $bytes
    if ($null -eq $journal.backup -or -not $journal.backup.verified -or (Get-DistHash $bytes) -cne $journal.backup.indexSha256) { throw 'Actual backup/index is not bound to completed evidence.' }
    if ($null -eq $Before.state.current) {
        if (-not $index.priorEmpty -or $index.files.Count -ne 0 -or $After.state.current.safe.generation -ne 1) { throw 'Initial empty baseline/generation is not proven.' }
    } else {
        $priorSlot=Get-QCurrentSlot $Configuration $Before
        $prior=Read-QRetainedManifest $Configuration $priorSlot
        if ($index.priorEmpty -or $index.inventorySha256 -cne $prior.inventorySha256 -or $After.state.current.safe.generation -ne $Before.state.current.safe.generation+1) { throw 'Prior backup or current generation differs.' }
        $null=Invoke-QPrivate Get-ClcTreeInventory @((Join-Path $root ('backups\'+$journal.attemptId+'\application')),$prior.files)
    }
    Assert-QTerminalEvidence $Configuration $After
    @{backupVerified=$true;backupIndexSha256=$journal.backup.indexSha256;terminalVerified=$true}
}
function Invoke-QOwnedPoolOperation($Configuration,[ValidateSet('Stop','Recycle')][string] $Operation) {
    $pool=Get-QPoolObservation $Configuration
    if ($pool.poolName -ine $Configuration.poolName -or $pool.applications.Count -ne 1 -or $pool.applications[0].physicalPath -ine $Configuration.applicationRoot) { throw 'Owned pool topology changed.' }
    $info=[Diagnostics.ProcessStartInfo]::new($Configuration.appcmdPath); $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true; $info.Environment.Clear(); $info.Environment['SystemRoot']=[Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
    foreach ($arg in @($Operation.ToLowerInvariant(),'apppool',('/apppool.name:'+$Configuration.poolName))) { $info.ArgumentList.Add($arg) }
    $process=[Diagnostics.Process]::Start($info)
    try {
        Initialize-DistNativePaths
        $output=[Clc.Distribution.Capture]::Read($process.StandardOutput.BaseStream,8192); $errors=[Clc.Distribution.Capture]::Read($process.StandardError.BaseStream,8192)
        if (-not $process.WaitForExit(60000)) { $process.Kill(); if (-not $process.WaitForExit(10000)) { throw 'Test-owned appcmd exit is unknown.' }; throw 'Test-owned pool operation timed out.' }
        if (-not [Threading.Tasks.Task]::WhenAll([Threading.Tasks.Task[]]@($output,$errors)).Wait(10000) -or $process.ExitCode -ne 0 -or $output.GetAwaiter().GetResult().Overflow -or $errors.GetAwaiter().GetResult().Overflow) { throw 'Test-owned pool operation failed; no raw output retained.' }
    } finally { $process.Dispose() }
}
function Invoke-QDriftFixture($Configuration,[string] $Variant,[string] $EvidenceRoot) {
    $manifest=Read-QManifest $Configuration initial
    $entry=@($manifest.files | Where-Object { $_.path -ceq 'application/ClcQualificationProbe.dll' })[0]
    $managed=Join-Path $Configuration.applicationRoot 'ClcQualificationProbe.dll'
    if ((Get-FileHash -LiteralPath $managed).Hash.ToLowerInvariant() -cne $entry.sha256) { throw 'Drift fixture requires the exact ready initial release.' }
    $path=$managed; $expectedHash=$null; $sentinel='CLC_OWNED_DRIFT_SENTINEL_T4'
    switch ($Variant) {
        Modified { [IO.File]::WriteAllBytes($managed,[Text.Encoding]::ASCII.GetBytes($sentinel)); $expectedHash=Get-DistHash ([Text.Encoding]::ASCII.GetBytes($sentinel)) }
        Missing { $path=Join-Path $EvidenceRoot 'retained-managed-file.bin'; [IO.File]::Move($managed,$path,$false); $expectedHash=$entry.sha256 }
        UnexpectedExtra { $path=Join-Path $Configuration.applicationRoot 'foreign-owned-sentinel.txt'; if ([IO.File]::Exists($path)) { throw 'Fixture refuses a preexisting extra file.' }; [IO.File]::WriteAllText($path,$sentinel); $expectedHash=Get-DistHash ([Text.Encoding]::UTF8.GetBytes($sentinel)) }
        WrongWebConfig { $path=Join-Path $Configuration.applicationRoot 'web.config'; [IO.File]::WriteAllText($path,'<configuration/>'); $expectedHash=Get-DistHash ([Text.Encoding]::UTF8.GetBytes('<configuration/>')) }
        HardLink { $path=Join-Path $Configuration.applicationRoot 'owned-hardlink.bin'; $null=New-Item -ItemType HardLink -Path $path -Target $managed; $expectedHash=$entry.sha256 }
        Reparse { $path=Join-Path $Configuration.applicationRoot 'owned-junction'; $null=New-Item -ItemType Junction -Path $path -Target $EvidenceRoot }
        FileStream { $path=$managed+':clc-t4-owned'; Set-Content -LiteralPath $managed -Stream clc-t4-owned -Value $sentinel -NoNewline; $expectedHash=Get-DistHash ([Text.Encoding]::UTF8.GetBytes($sentinel)) }
        DirectoryStream { $path=$Configuration.applicationRoot+':clc-t4-owned'; [IO.File]::WriteAllText($path,$sentinel); $expectedHash=Get-DistHash ([Text.Encoding]::UTF8.GetBytes($sentinel)) }
        default { throw 'Unsupported controlled drift fixture.' }
    }
    $record=@{variant=$Variant;relativePath=$path.Substring($Configuration.applicationRoot.Length);expectedSha256=$expectedHash;originalManagedSha256=$entry.sha256;retained=$true}
    Write-QJson (Join-Path $EvidenceRoot 'injection.json') $record
    @{path=$path;expectedSha256=$expectedHash;record=$record}
}
function Test-QDriftPreserved($Injection) {
    if ($Injection.record.variant -ceq 'Reparse') { return (Get-Item -LiteralPath $Injection.path -Force).LinkType -ceq 'Junction' }
    if (-not [IO.File]::Exists($Injection.path)) { return $false }
    (Get-DistHash ([IO.File]::ReadAllBytes($Injection.path))) -ceq $Injection.expectedSha256
}
function Invoke-QScenario($Configuration,$Definition,[string] $AuthorizationPath,[string] $EvidenceRoot) {
    $before=Get-QSnapshot $Configuration
    if ($Definition.initialState -cne 'Either' -and $before.poolState -cne $Definition.initialState) { throw 'Scenario initial pool state is not established; use a separate authorized campaign.' }
    Write-QJson (Join-Path $EvidenceRoot 'before.json') $before
    $configBefore=Get-DistHash ([IO.File]::ReadAllBytes($Configuration.operationalConfigPath)) # Never serialized.
    $worker=$null; $workerResult=$null; $after=$null; $details=@{}; $slot='initial'
    try {
        switch ($Definition.action) {
            { $_ -in @('Deploy','Upgrade','NoOp','ConfigurationRestart','RejectSameRevision','Idle') } {
                if ($Definition.action -cne 'Deploy') { $slot=Get-QCurrentSlot $Configuration $before }
                if ($Definition.action -ceq 'Upgrade') { $slot='newer' }
                if ($Definition.action -ceq 'Deploy' -and ($null -ne $before.state.current -or $before.applicationFiles.Count -ne 0)) { throw 'Initial install requires an approved empty target and empty canonical state.' }
                if ($Definition.action -ceq 'Idle' -and $Definition.variant -ceq 'ActivateIdleWorker' -and ($before.poolState -cne 'Started' -or $before.workerCount -ne 0)) { throw 'Wait for actual idle Started/zero workers.' }
                if ($Definition.action -ceq 'Idle' -and $Definition.variant -ceq 'StoppedNotNoOp' -and $before.poolState -cne 'Stopped') { throw 'An initially stopped pool is required.' }
                $worker=Start-QWorker $Configuration $AuthorizationPath (Join-Path $EvidenceRoot 'invoke') -ApprovalSlot $slot
                $workerResult=Wait-QWorker $worker
                $after=Get-QSnapshot $Configuration
                if ($Definition.action -ceq 'RejectSameRevision') {
                    if ($workerResult.success -or $workerResult.code -cne 'Clc.ConfigurationRevisionDrift' -or $after.poolState -cne $before.poolState -or $after.applicationInventorySha256 -cne $before.applicationInventorySha256) { throw 'Same-revision rejection did not preserve the target.' }
                } else {
                    $status=if ($Definition.action -ceq 'NoOp' -or ($Definition.action -ceq 'Idle' -and $Definition.variant -ceq 'ActivateIdleWorker')) {'NoOp'} else {'Deployed'}
                    Assert-QLifecycleResult $Configuration $workerResult $after $status $slot
                    if ($status -ceq 'Deployed') { $details.publication=Assert-QBackupAndPublication $Configuration $before $after }
                    if ($status -ceq 'NoOp' -and ($after.state.current.sha256 -cne $before.state.current.sha256 -or $after.applicationInventorySha256 -cne $before.applicationInventorySha256 -or
                        $workerResult.observationCounts.ContainsKey('Start-ClcIisHelper') -or $workerResult.observationCounts.ContainsKey('Invoke-ClcManagedReplacement') -or
                        $workerResult.observationCounts.ContainsKey('Expand-ClcApprovedRelease') -or $workerResult.observationCounts.ContainsKey('New-ClcVerifiedBackup'))) { throw 'NoOp performed forbidden lifecycle effects.' }
                }
            }
            Drift {
                if ((Get-QCurrentSlot $Configuration $before) -cne 'initial') { throw 'Drift fixtures require the initial release baseline.' }
                $injection=Invoke-QDriftFixture $Configuration $Definition.variant $EvidenceRoot
                $worker=Start-QWorker $Configuration $AuthorizationPath (Join-Path $EvidenceRoot 'refusal')
                $workerResult=Wait-QWorker $worker
                $actual=Get-QStateAndPool $Configuration
                if ($workerResult.success -or $workerResult.code -cnotin @('Clc.ContentDrift','Clc.UnsafePath','Clc.HostPreflightFailed') -or -not (Test-QDriftPreserved $injection) -or
                    $actual.poolState -cne $before.poolState -or $actual.records.current -cne $before.state.current.sha256 -or $actual.records.journal -cne $before.state.journal.sha256) { throw 'Drift rejection or preservation failed.' }
                $details.injection=$injection.record; $details.finalObservation=$actual
                # Intentionally retain injected content. Fixture reset is an
                # explicit operator procedure, never automatic application repair.
            }
            Recovery {
                $mode=$Definition.variant
                $worker=Start-QWorker $Configuration $AuthorizationPath (Join-Path $EvidenceRoot 'restore') -Command Restore -Mode $mode
                $workerResult=Wait-QWorker $worker; $after=Get-QSnapshot $Configuration
                if (-not $workerResult.success) { throw 'Explicit recovery failed; inspect retained evidence.' }
                if ($mode -ceq 'RestoreEmpty') {
                    $manifest=Read-QRetainedManifest $Configuration initial; $guard=@($manifest.files | Where-Object path -CEQ 'application/web.config')[0]
                    if (-not $workerResult.success -or $workerResult.result.status -cne 'RestoredEmpty' -or $after.poolState -cne 'Stopped' -or $after.workerCount -ne 0 -or $null -ne $after.state.current -or $after.applicationFiles.Count -ne 1 -or $after.applicationFiles[0].sha256 -cne $guard.sha256) { throw 'Empty recovery lacks exact stopped/guard/current proof.' }
                } else {
                    $slot=Get-QCurrentSlot $Configuration $after
                    $status=if ($mode -ceq 'RestorePrevious') {'RestoredPrevious'} else {'AcceptedCandidate'}
                    Assert-QLifecycleResult $Configuration $workerResult $after $status $slot
                }
                Assert-QTerminalEvidence $Configuration $after
            }
            Dpapi {
                $slot=Get-QCurrentSlot $Configuration $before
                $client=Get-QHttpClient
                try {
                    $base=([uri]$Configuration.readinessUri).GetLeftPart([UriPartial]::Authority)
                    $token=$client.GetStringAsync($base+'/probe/protect').GetAwaiter().GetResult()
                    if ($token.Length -gt 4096) { throw 'Protection token exceeds bound.' }
                    switch ($Definition.variant) {
                        Recycle { Invoke-QOwnedPoolOperation $Configuration Recycle }
                        Restart { Invoke-QOwnedPoolOperation $Configuration Stop }
                        Upgrade { $slot='newer' }
                        Recovery { }
                    }
                    $command=if ($Definition.variant -ceq 'Recovery') {'Restore'} else {'Invoke'}
                    $worker=Start-QWorker $Configuration $AuthorizationPath (Join-Path $EvidenceRoot 'transition') -Command $command -Mode RestorePrevious -ApprovalSlot $slot
                    $workerResult=Wait-QWorker $worker
                    if (-not $workerResult.success) { throw 'DPAPI transition failed.' }
                    $content=[Net.Http.StringContent]::new($token,[Text.Encoding]::UTF8,'text/plain')
                    try { $response=$client.PostAsync($base+'/probe/unprotect',$content).GetAwaiter().GetResult(); try { if ([int]$response.StatusCode -ne 200) { throw 'Real cross-transition unprotect failed.' } } finally { $response.Dispose() } } finally { $content.Dispose() }
                    $details.protectUnprotectContinuity=$true; $details.transition=$Definition.variant
                } finally { $client.Dispose() }
                $after=Get-QSnapshot $Configuration
            }
            Performance {
                $first=Read-QManifest $Configuration initial; $second=Read-QManifest $Configuration newer
                $firstInputs=Read-QBuildInputs $Configuration initial $first; $secondInputs=Read-QBuildInputs $Configuration newer $second
                if (-not (Assert-QWorkload $first $firstInputs $Definition.variant) -or -not (Assert-QWorkload $second $secondInputs $Definition.variant)) {
                    return @{status='BLOCKED';reason='A realistic workload requires reviewed representative publish provenance for both releases.';details=@{profile=$Definition.variant};before=$before;after=$before;worker=$null;sentinelPreserved=$true}
                }
                $details.workloadInputs=@{initial=$firstInputs;newer=$secondInputs}
                if ($null -ne $before.state.current -or $before.applicationFiles.Count -ne 0) { throw 'Performance profile starts from an approved empty target.' }
                $measurements=[Collections.Generic.List[object]]::new()
                foreach ($step in @('Initial','Replacement','Recovery')) {
                    $command=if ($step -ceq 'Recovery') {'Restore'} else {'Invoke'}; $slot=if ($step -ceq 'Replacement') {'newer'} else {'initial'}
                    $worker=Start-QWorker $Configuration $AuthorizationPath (Join-Path $EvidenceRoot $step.ToLowerInvariant()) -Command $command -Mode RestorePrevious -ApprovalSlot $slot
                    $workerResult=Wait-QWorker $worker
                    if (-not $workerResult.success) { throw 'Representative workload exceeded a production limit or failed; inspect safe state evidence.' }
                    $measurements.Add(@{operation=$step;elapsedSeconds=$workerResult.elapsedSeconds;commandElapsedSeconds=$workerResult.commandElapsedSeconds;observationCounts=$workerResult.observationCounts;journalMetrics=$workerResult.journalMetrics;instrumented=$true})
                    $worker.process.Dispose(); $worker=$null
                }
                $details.performance=@{profile=$Definition.variant;initialFileCount=$first.files.Count;replacementFileCount=$second.files.Count;totalBytes=[long](($second.files | Measure-Object length -Sum).Sum);measurements=$measurements;cacheState='Not controlled';inclusiveTimingsOverlap=$true;maintenanceWindowQualified=$false;remaining='Review journal boundary intervals and storage/workload representativeness with the operator.'}
                $after=Get-QSnapshot $Configuration
            }
            default { return @{status='BLOCKED';reason='Requires the separately documented operator fixture/token/transport/storage procedure; no simulated pass is accepted.';details=@{procedure=$Definition.procedure};before=$before;after=$before;worker=$null;sentinelPreserved=$true} }
        }
        $preserved=(Get-DistHash ([IO.File]::ReadAllBytes($Configuration.operationalConfigPath))) -ceq $configBefore
        if (-not $preserved) { throw 'External protected configuration changed during the scenario.' }
        if ($null -ne $after) { Write-QJson (Join-Path $EvidenceRoot 'after.json') $after }
        Write-QJson (Join-Path $EvidenceRoot 'details.json') $details
        @{status='PASS';reason='Actual authorized scenario assertions passed';before=$before;after=$after;worker=$workerResult;details=$details;sentinelPreserved=$preserved}
    } finally {
        if ($null -ne $worker) { if (-not $worker.process.HasExited) { Stop-QOwnedProcess $worker }; $worker.process.Dispose() }
    }
}

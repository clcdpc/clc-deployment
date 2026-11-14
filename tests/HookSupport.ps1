# Owned NTFS fixtures and harmless bounded child processes only. No SQL or IIS.
function New-HookApproval {
    param($Fixture,[string] $Id='hooks-001',[long] $Sequence=1,[string[]] $Stages=@(),[switch] $Plan,[string] $Body)
    $build=Join-Path $Fixture.workspace $Id; $null=[IO.Directory]::CreateDirectory($build)
    $args=New-TestPublish $build
    $metadata=Get-TestMetadata; $metadata.schemaVersion=2L; $metadata.changeKind='application-deployment'
    $metadata.releaseId='probe-release-'+$Sequence; $metadata.source.commit=$Sequence.ToString('x40')
    [IO.File]::WriteAllText((Join-Path $args.PublishRoot 'Probe.dll'),('Synthetic approved hook application '+$Id))
    if ($Stages.Count -or $Plan) {
        $hookRoot=Join-Path $build 'hook-input'; $null=[IO.Directory]::CreateDirectory($hookRoot)
        if (-not $Body) {
            $Body='param([string] $ContextPath); $c=Get-Content -LiteralPath $ContextPath -Raw | ConvertFrom-Json; @{contractVersion=1;outcome="Success";stage=$c.stage;externalStateMayHaveChanged=$false;diagnosticId="synthetic-ok";requiresOperatorIntervention=$false} | ConvertTo-Json -Compress'
        }
        $metadata.hooks=@{contractVersion=1L;stages=@();planningEntryPoint=$null}
        foreach ($stage in $Stages) {
            $name=$stage.ToLowerInvariant()+'.ps1'; [IO.File]::WriteAllText((Join-Path $hookRoot $name),$Body)
            $metadata.hooks.stages+=@{stage=$stage;entryPoint=('hooks/'+$name)}
        }
        if ($Plan) { [IO.File]::WriteAllText((Join-Path $hookRoot 'plan.ps1'),$Body); $metadata.hooks.planningEntryPoint='hooks/plan.ps1' }
        [IO.File]::WriteAllText((Join-Path $hookRoot 'synthetic.sql'),'-- Verified inert SQL support input; never sent to a database.')
        $args.HookRoot=$hookRoot
    }
    Write-TestJson $args.MetadataPath $metadata
    $package=New-ClcRelease @args
    $a=Get-Content -LiteralPath (Join-Path $script:FixtureRoot 'release-approval.json') -Raw | ConvertFrom-Json -AsHashtable -DateKind String
    $a.approvalId=$Id; $a.targetId=$Fixture.target.targetId; $a.applicationId=$metadata.applicationId; $a.releaseId=$metadata.releaseId
    $a.sourceRepository=$metadata.source.repository; $a.sourceCommit=$metadata.source.commit; $a.lineageId='probe-main'; $a.releaseSequence=$Sequence
    $a.releaseZipSha256=$package.archiveSha256; $a.manifestSha256=$package.manifestSha256
    $a.provenance.workflowPath=$metadata.build.workflowPath; $a.provenance.runId=$metadata.build.runId; $a.provenance.runAttempt=$metadata.build.runAttempt; $a.provenance.buildJob=$metadata.build.job
    $path=Join-Path $Fixture.layout.approvalCatalogRoot ($Id+'.json'); Write-TestJson $path $a
    [IO.File]::Copy($package.archivePath,(Join-Path $Fixture.target.artifactInboxRoot ($Id+'.zip')),$false)
    if (-not $Fixture.ContainsKey('dllIdentities')) { $Fixture.dllIdentities=@{} }
    $Fixture.dllIdentities[(Get-FileHash -LiteralPath (Join-Path $args.PublishRoot 'Probe.dll')).Hash]=$metadata
    return @{record=$a;path=$path;package=$package;publish=$args.PublishRoot;metadata=$metadata}
}
function New-HookPolicy {
    param($Fixture,[switch] $Native)
    $root=Join-Path $Fixture.layout.approvalCatalogRoot 'hooks'; $null=[IO.Directory]::CreateDirectory($root)
    $pwsh=Join-Path $Fixture.workspace 'binaries\hooks\pwsh.exe'
    if ($Native) { $pwsh=(Get-Process -Id $PID).Path }
    else { $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($pwsh)); [IO.File]::WriteAllText($pwsh,'synthetic interpreter; mock launch only') }
    $policy=@{contractFamily='clc-file-iis-v1';schemaVersion=1L;recordKind='hook-policy';targetId=$Fixture.target.targetId;applicationId=$Fixture.target.applicationId;
        environmentName=$Fixture.target.environmentName;enabled=$true;exactApprovalChannel='DEV';channels=@('DEV');sourceClasses=@('ExactApproval');stages=@('Preflight','BeforeStop','AfterStop','AfterStart');allowPlanning=$true;
        pwshPath=$pwsh;pwshSha256=(Get-FileHash -LiteralPath $pwsh -Algorithm SHA256).Hash.ToLowerInvariant();timeoutSeconds=10L;
        authorization=@{authoritySid='S-1-5-18';reference='synthetic-hooks';approvedUtc='2026-01-01T00:00:00.0000000Z'}}
    $path=Join-Path $root ($Fixture.target.targetId+'.json'); Write-TestJson $path $policy
    return @{record=$policy;path=$path}
}
function Set-HookMocks {
    Set-T3Mocks
    $global:ClcHooks=@{mode='Success';failStage='';native=$false;calls=[Collections.Generic.List[string]]::new();observations=[Collections.Generic.List[object]]::new()}
    $global:ClcNativeHook=& (Get-Module CLC.Deployment) { (Get-Command Start-ClcHookHelper).ScriptBlock }
    Mock -ModuleName CLC.Deployment Start-ClcHookHelper {
        $context=Get-Content -LiteralPath $ContextPath -Raw | ConvertFrom-Json -AsHashtable
        $stage=$context.stage; $j=(Invoke-T2Private Read-ClcStateFile @($Session.lock,'journal')).record
        $j.nativeCall.operation | Should -BeExactly Hook; $j.nativeCall.launchState | Should -BeExactly Intent
        $j.hooks.externalStateMayHaveChanged | Should -BeTrue
        $j.hooks.executions[-1].stage | Should -BeExactly $stage; $j.hooks.executions[-1].status | Should -BeExactly Intent
        $global:ClcHooks.calls.Add($stage); $global:ClcLifecycle.operations.Add('Hook:'+$stage)
        $global:ClcHooks.observations.Add($context.observations)
        if ($stage -ceq 'AfterStop') { $context.observations.poolState | Should -BeExactly Stopped; $context.observations.workerCount | Should -Be 0 }
        if ($global:ClcHooks.native) { return & $global:ClcNativeHook $Session $EntryPoint $ContextPath }
        $mode=if (-not $global:ClcHooks.failStage -or $stage -ceq $global:ClcHooks.failStage) {$global:ClcHooks.mode} else {'Success'}
        switch ($mode) {
            Crash { return Start-T3HarmlessHelper '' 23 }
            Timeout { return Start-T3HarmlessHelper '' 0 10000 }
            Malformed { return Start-T3HarmlessHelper '{"contractVersion":1}' }
        }
        $result=@{contractVersion=1L;outcome=$(if ($mode -cin @('Failure','FailureExit')) {'Failure'} else {'Success'});stage=$stage;externalStateMayHaveChanged=($mode -ceq 'ExternalMutation');diagnosticId='synthetic-hook';requiresOperatorIntervention=$false}
        return Start-T3HarmlessHelper ($result | ConvertTo-Json -Compress) $(if ($mode -ceq 'FailureExit') {1} else {0})
    }
}
function Get-HookJournal {
    param($Fixture)
    return Get-Content -LiteralPath (Join-Path $Fixture.controlRoot 'journal.json') -Raw | ConvertFrom-Json -AsHashtable -DateKind String
}
function New-HookRecoveryApproval {
    param($Fixture,$Selected,[string] $Mode='RestorePrevious',[string] $Id='reconcile-external')
    $j=Get-HookJournal $Fixture
    $root=Join-Path $Fixture.layout.approvalCatalogRoot 'recovery'; $null=[IO.Directory]::CreateDirectory($root)
    $record=@{contractFamily='clc-file-iis-v1';schemaVersion=1L;recordKind='persistent-state-approval';approvalId=$Id;enabled=$true;targetId=$Fixture.target.targetId;
        attemptId=$j.attemptId;journalSha256=(Get-FileHash -LiteralPath (Join-Path $Fixture.controlRoot 'journal.json') -Algorithm SHA256).Hash.ToLowerInvariant();mode=$Mode;selectedManifestSha256=$Selected.record.manifestSha256;
        externalStateCompatible=$true;helpersQuiescentConfirmed=$true;authorization=@{authoritySid='S-1-5-18';reference='synthetic-reconciliation';approvedUtc='2026-01-01T00:00:00.0000000Z'}}
    $path=Join-Path $root ($Id+'.json'); Write-TestJson $path $record
    return @{record=$record;path=$path}
}

# Fixed lifecycle entry points, not a command interpreter. All application code
# remains explicitly trusted with the elevated deployment account's privileges.
function Assert-ClcHookResult {
    param($Value)
    Assert-ClcObject $Value @('contractVersion','outcome','stage','externalStateMayHaveChanged','diagnosticId','requiresOperatorIntervention')
    Assert-ClcInteger $Value.contractVersion 1 1
    Assert-ClcEnum $Value.outcome @('Success','Failure')
    Assert-ClcEnum $Value.stage @('Preflight','BeforeStop','AfterStop','AfterStart','Plan')
    Assert-ClcBoolean $Value.externalStateMayHaveChanged
    Assert-ClcCode $Value.diagnosticId 64
    Assert-ClcBoolean $Value.requiresOperatorIntervention
}
function Assert-ClcHookPolicy {
    param($Value)
    Assert-ClcObject $Value @('contractFamily','schemaVersion','recordKind','targetId','applicationId','environmentName','enabled','channels','exactApprovalChannel','sourceClasses','stages','allowPlanning','pwshPath','pwshSha256','timeoutSeconds','authorization')
    foreach ($key in @('targetId','applicationId')) { Assert-ClcId $Value[$key] }
    Assert-ClcText $Value.environmentName
    foreach ($key in @('enabled','allowPlanning')) { Assert-ClcBoolean $Value[$key] }
    foreach ($key in @('channels','sourceClasses','stages')) {
        if ($Value[$key] -isnot [object[]] -or $Value[$key].Count -gt 4 -or @($Value[$key] | Select-Object -Unique).Count -ne $Value[$key].Count) { Stop-ClcError Clc.InvalidContract }
    }
    foreach ($channel in $Value.channels) { Assert-ClcEnum $channel @('DEV','Production','Test') }
    Assert-ClcEnum $Value.exactApprovalChannel @('DEV','Production','Test')
    if ($Value.channels -cnotcontains $Value.exactApprovalChannel) { Stop-ClcError Clc.InvalidContract }
    foreach ($source in $Value.sourceClasses) { Assert-ClcEnum $source @('ExactApproval','IntegrationTag','ReviewedPr','ProtectedBranch') }
    foreach ($stage in $Value.stages) { Assert-ClcEnum $stage @('Preflight','BeforeStop','AfterStop','AfterStart') }
    Assert-ClcAbsolutePath $Value.pwshPath
    if ([IO.Path]::GetFileName($Value.pwshPath) -cne 'pwsh.exe') { Stop-ClcError Clc.InvalidContract }
    Assert-ClcHash $Value.pwshSha256
    Assert-ClcInteger $Value.timeoutSeconds 1 300
    Assert-ClcInfrastructureAuthorization $Value.authorization
}
function Assert-ClcInfrastructureAuthorization {
    param($Value)
    Assert-ClcObject $Value @('authoritySid','reference','approvedUtc')
    Assert-ClcSid $Value.authoritySid; Assert-ClcCode $Value.reference; Assert-ClcTimestamp $Value.approvedUtc
}
function Read-ClcHookAuthority {
    param($Session,[string] $Directory,[string] $Id,[string] $Kind)
    $lock=$Session.lock; $context=$lock.context
    $root=Join-Path $context.layout.approvalCatalogRoot $Directory
    $path=Join-Path $root ($Id+'.json')
    try {
        foreach ($item in @($root,$path)) { $null=Add-ClcProtectedPathPin $context $item -Directory:($item -ceq $root) -RuntimeSid $lock.targetFile.record.runtimeIdentitySid }
        $file=Read-ClcHeldRecord $path $Kind $context.handles
        $a=$file.record.authorization; $p=$context.policyFile.record
        if ($p.infrastructureOwnerSids -cnotcontains $a.authoritySid -or $p.deploymentSids -ccontains $a.authoritySid) { Stop-ClcError Clc.HookAuthorizationRejected }
        return $file
    } catch { Stop-ClcError Clc.HookAuthorizationRejected }
}
function Initialize-ClcHookAuthorization {
    param($Session)
    $m=$Session.release.manifest
    if (-not $m.Contains('hooks')) {
        if ($Session.operation -ceq 'ValidateOnly') { Stop-ClcError Clc.PlanningUnavailable }
        return
    }
    $lock=$Session.lock; $t=$lock.targetFile.record; $a=$Session.release.approvalFile.record
    $file=Read-ClcHookAuthority $Session hooks $t.targetId hook-policy; $p=$file.record
    # Legacy automatic evidence does not independently distinguish reviewed PR
    # code from integration history. It cannot authorize executable hooks.
    if ($a.schemaVersion -eq 2) { Stop-ClcError Clc.HookAuthorizationRejected }
    $sourceClass=if ($a.schemaVersion -eq 3) {$a.admission.sourceIdentity.sourceClass} else {'ExactApproval'}
    $channel=if ($a.schemaVersion -eq 3) {$a.admission.sourceIdentity.channel} else {$p.exactApprovalChannel}
    if (-not $p.enabled -or $p.targetId -cne $t.targetId -or $p.applicationId -cne $t.applicationId -or $p.environmentName -cne $t.environmentName -or
        $p.channels -cnotcontains $channel -or $p.sourceClasses -cnotcontains $sourceClass) { Stop-ClcError Clc.HookAuthorizationRejected }
    if ($Session.operation -ceq 'ValidateOnly') {
        if (-not $p.allowPlanning -or $null -eq $m.hooks.planningEntryPoint) { Stop-ClcError Clc.PlanningUnavailable }
    } else {
        foreach ($stage in $m.hooks.stages) { if ($p.stages -cnotcontains $stage.stage) { Stop-ClcError Clc.HookAuthorizationRejected } }
    }
    $null=Add-ClcProtectedPathPin $lock.context $p.pwshPath -SystemFile -RuntimeSid $t.runtimeIdentitySid
    $null=Add-ClcProtectedPathPin $lock.context ([IO.Path]::GetDirectoryName($p.pwshPath)) -Directory -SystemDirectory -RuntimeSid $t.runtimeIdentitySid
    Assert-ClcTrustAncestors $lock.context $p.pwshPath $t.runtimeIdentitySid
    $interpreter=Read-ClcHeldFile $p.pwshPath $lock.context.handles 268435456 -SystemFile -NoCapture
    if ($interpreter.sha256 -cne $p.pwshSha256) { Stop-ClcError Clc.HookAuthorizationRejected }
    $Session.hookPolicy=$file; $Session.hookChannel=$channel
}
function Assert-ClcHookJournal {
    param($Value)
    if ($null -eq $Value) { return }
    Assert-ClcObject $Value @('policySha256','operation','externalStateMayHaveChanged','executions')
    Assert-ClcHash $Value.policySha256
    Assert-ClcEnum $Value.operation @('Deploy','ValidateOnly')
    Assert-ClcBoolean $Value.externalStateMayHaveChanged
    if ($Value.executions -isnot [object[]] -or $Value.executions.Count -gt 4) { Stop-ClcError Clc.InvalidContract }
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in $Value.executions) {
        Assert-ClcObject $entry @('stage','entryPoint','status','result')
        Assert-ClcEnum $entry.stage @('Preflight','BeforeStop','AfterStop','AfterStart','Plan')
        Assert-ClcHookAssetName $entry.entryPoint
        if (-not $entry.entryPoint.EndsWith('.ps1',[StringComparison]::Ordinal) -or -not $seen.Add($entry.stage)) { Stop-ClcError Clc.InvalidContract }
        if (($Value.operation -ceq 'ValidateOnly') -ne ($entry.stage -ceq 'Plan')) { Stop-ClcError Clc.InvalidContract }
        Assert-ClcEnum $entry.status @('Intent','Succeeded','Failed')
        if ($entry.status -cne 'Intent') {
            Assert-ClcHookResult $entry.result
            if ($entry.result.stage -cne $entry.stage) { Stop-ClcError Clc.InvalidContract }
            if ($entry.status -ceq 'Succeeded' -and ($entry.result.outcome -cne 'Success' -or $entry.result.requiresOperatorIntervention -or
                ($entry.stage -ceq 'Plan' -and $entry.result.externalStateMayHaveChanged))) { Stop-ClcError Clc.InvalidContract }
        } elseif ($null -ne $entry.result) { Stop-ClcError Clc.InvalidContract }
    }
    if ($Value.executions.Count -gt 0 -and -not $Value.externalStateMayHaveChanged) { Stop-ClcError Clc.InvalidContract }
}
function Test-ClcExternalMutationIntent {
    param($Journal)
    return $Journal.schemaVersion -eq 3 -and $null -ne $Journal.hooks -and $Journal.hooks.externalStateMayHaveChanged
}
function Start-ClcHookHelper {
    param($Session,[string] $EntryPoint,[string] $ContextPath)
    return [Clc.Lifecycle.Native]::Hook($Session.hookPolicy.record.pwshPath,$EntryPoint,$ContextPath)
}
function Invoke-ClcDeploymentHook {
    param($Session,[ValidateSet('Preflight','BeforeStop','AfterStop','AfterStart','Plan')][string] $Stage)
    if (-not $Session.ContainsKey('hookPolicy')) { return }
    $m=$Session.release.manifest; $lock=$Session.lock
    $entry=if ($Stage -ceq 'Plan') {$m.hooks.planningEntryPoint} else { @($m.hooks.stages | Where-Object stage -CEQ $Stage | ForEach-Object entryPoint) }
    if ($null -eq $entry -or @($entry).Count -eq 0) { return }
    $entry=[string]$entry
    $pool=Assert-ClcEffectAuthority $Session
    if ($Stage -ceq 'AfterStop' -and ($pool.poolState -cne 'Stopped' -or $pool.workerCount -ne 0)) { Stop-ClcError Clc.ShutdownTimeout }
    if ($Stage -ceq 'AfterStart') { Assert-ClcReadyPool $pool }
    Assert-ClcHeldRecordUnchanged $lock.context $Session.hookPolicy Clc.HookAuthorizationRejected
    $root=Join-Path $Session.packageRoot 'hooks'
    $facts=Get-ClcPathObservation $root $lock.context.handles -Directory
    $files=Get-ClcPublishInventory $facts $lock.context.handles ([Diagnostics.Stopwatch]::StartNew()) -HookAssets -ExpectedFiles $m.hooks.files -Context $lock.context -RuntimeSid $lock.targetFile.record.runtimeIdentitySid -ControlRoot $lock.identity.controlRoot
    if ((Get-ClcInventoryHash $files) -cne $m.hooks.inventorySha256) { Stop-ClcError Clc.HashMismatch }
    $attempt=Join-Path $lock.identity.controlRoot ('attempts\'+$Session.attemptId)
    $diagnostics=Join-Path $attempt ('diagnostics-'+$Stage.ToLowerInvariant())
    New-ClcOwnedDirectory $lock $diagnostics -CreateNew
    $contextPath=Join-Path $attempt ('hook-'+$Stage.ToLowerInvariant()+'.json')
    $t=$lock.targetFile.record
    $context=[ordered]@{contractVersion=1L;applicationId=$m.applicationId;targetId=$t.targetId;attemptId=$Session.attemptId;
        environmentName=$t.environmentName;channel=$Session.hookChannel;releaseId=$m.releaseId;sourceRepository=$m.source.repository;sourceCommit=$m.source.commit;
        stage=$Stage;verifiedPackageRoot=$Session.packageRoot;supportRoot=$root;configurationPath=$t.operationalConfigPath;diagnosticRoot=$diagnostics;
        observations=@{initialPoolState=(Read-ClcStateFile $lock journal).record.initialPoolState;poolState=$pool.poolState;workerCount=$pool.workerCount}}
    $out=[IO.File]::Open($contextPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $out.Write([Text.Encoding]::UTF8.GetBytes(($context | ConvertTo-Json -Depth 8 -Compress))); $out.Flush($true) } finally { $out.Dispose() }
    $null=Get-ClcPathObservation $contextPath $lock.context.handles
    $null=Read-ClcHeldFile $contextPath $lock.context.handles 8192 -NoCapture
    # Persist uncertainty BEFORE launch, including Preflight and trusted planning.
    # A successful hook's false mutation flag never clears this sticky fact.
    $file=Write-ClcJournalIntent $lock Hook; $j=$file.record
    $j.hooks.externalStateMayHaveChanged=$true
    $j.hooks.executions+=@{stage=$Stage;entryPoint=$entry;status='Intent';result=$null}
    $null=Write-ClcStateRecord $lock journal $j $file.sha256
    $running=$null
    try {
        $null=Write-ClcNativeCallIntent $lock Hook
        $running=Start-ClcHookHelper $Session (Join-Path $Session.packageRoot $entry.Replace('/','\')) $contextPath
        $null=Write-ClcNativeCallStarted $lock $running.Process
        $output=[Clc.Lifecycle.Native]::Finish($running,([int]$Session.hookPolicy.record.timeoutSeconds*1000))
        if ($output.Failed) {
            if (-not $running.Process.HasExited) { $running.Process.Kill($true) }
            $null=Write-ClcNativeCallExited $lock $running.Process 0 30000
            if ($null -eq $output.Bytes -or $output.Overflow) { Stop-ClcError Clc.HookFailed }
        } else {
            $null=Write-ClcNativeCallExited $lock $running.Process 0 30000
        }
        try { $result=Read-ClcJson $output.Bytes hook-result 8192 } catch { Stop-ClcError $(if ($output.Failed) {'Clc.HookFailed'} else {'Clc.HookResultInvalid'}) }
        if ($result.stage -cne $Stage) { Stop-ClcError Clc.HookResultInvalid }
        $success=-not $output.Failed -and $result.outcome -ceq 'Success' -and -not $result.requiresOperatorIntervention -and ($Stage -cne 'Plan' -or -not $result.externalStateMayHaveChanged)
        $file=Read-ClcStateFile $lock journal; $j=$file.record
        $j.hooks.executions[-1].status=if ($success) {'Succeeded'} else {'Failed'}
        $j.hooks.executions[-1].result=$result
        $null=Write-ClcStateRecord $lock journal $j $file.sha256
        if (-not $success) { Stop-ClcError $(if ($Stage -ceq 'Plan' -and $result.externalStateMayHaveChanged) {'Clc.PlanningMutationReported'} else {'Clc.HookFailed'}) }
        $null=Assert-ClcEffectAuthority $Session
    } finally { if ($null -ne $running) { Stop-ClcOwnedHelper $running $lock } }
}
function Assert-ClcPersistentStateApproval {
    param($Value)
    Assert-ClcObject $Value @('contractFamily','schemaVersion','recordKind','approvalId','enabled','targetId','attemptId','journalSha256','mode','selectedManifestSha256','externalStateCompatible','helpersQuiescentConfirmed','authorization')
    foreach ($key in @('approvalId','targetId')) { Assert-ClcId $Value[$key] }
    Assert-ClcGuid $Value.attemptId
    foreach ($key in @('journalSha256','selectedManifestSha256')) { Assert-ClcHash $Value[$key] }
    foreach ($key in @('enabled','externalStateCompatible','helpersQuiescentConfirmed')) { Assert-ClcBoolean $Value[$key] }
    Assert-ClcEnum $Value.mode @('RestorePrevious','AcceptCandidate','RestoreEmpty')
    Assert-ClcInfrastructureAuthorization $Value.authorization
}
function Assert-ClcHookRecoveryAuthority {
    param($Session,$State,$Selected,[string] $Mode)
    if (-not (Test-ClcExternalMutationIntent $State.journal.record)) { return }
    if (-not $Session.persistentStateApprovalId) { Stop-ClcError Clc.PersistentStateApprovalRequired }
    $file=Read-ClcHookAuthority $Session recovery $Session.persistentStateApprovalId persistent-state-approval
    $p=$file.record; $j=$State.journal.record
    if (-not $p.enabled -or -not $p.externalStateCompatible -or -not $p.helpersQuiescentConfirmed -or $p.approvalId -cne $Session.persistentStateApprovalId -or
        $p.targetId -cne $Session.lock.targetFile.record.targetId -or $p.attemptId -cne $j.attemptId -or $p.journalSha256 -cne $State.journal.sha256 -or
        $p.mode -cne $Mode -or $p.selectedManifestSha256 -cne $Selected.approvalFile.record.manifestSha256) { Stop-ClcError Clc.PersistentStateApprovalRequired }
    $Session.persistentStateApproval=$file
}

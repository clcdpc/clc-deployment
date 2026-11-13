. "$PSScriptRoot/Qualification.Common.ps1"
function Get-QObservedCommands {
    @(
        'Get-ClcTreeInventory','Assert-ClcSafeDescendants','Get-ClcHostPreflight','Get-ClcToolkitInventory',
        'Start-ClcIisHelper','Start-ClcApplicationValidator','Expand-ClcApprovedRelease',
        'New-ClcVerifiedBackup','Invoke-ClcManagedReplacement','Copy-ClcPayloadFile'
    )
}
function Start-QWorker($Configuration,[string] $AuthorizationPath,[string] $OutputRoot,[ValidateSet('Invoke','Restore')][string] $Command='Invoke',[string] $ApprovalSlot='initial',[string] $Mode='AcceptCandidate') {
    Assert-DistLocalPath $OutputRoot
    if (-not $OutputRoot.StartsWith($Configuration.evidenceRoot+'\',[StringComparison]::Ordinal)) { throw 'Worker evidence must remain in the selected campaign evidence root.' }
    if ([IO.Directory]::Exists($OutputRoot)) { throw 'Worker evidence must be new.' }
    $null=[IO.Directory]::CreateDirectory($OutputRoot)
    $info=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path); $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $info.Environment.Clear(); $info.Environment['SystemRoot']=[Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
    foreach ($argument in @('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $PSScriptRoot 'Qualification.Worker.ps1'),'-ConfigurationPath',$Configuration._path,'-AuthorizationPath',$AuthorizationPath,'-OutputRoot',$OutputRoot,'-Command',$Command,'-ApprovalSlot',$ApprovalSlot,'-Mode',$Mode)) { $info.ArgumentList.Add($argument) }
    $process=[Diagnostics.Process]::Start($info)
    $creation=$process.StartTime.ToUniversalTime().ToFileTimeUtc()
    @{process=$process;processId=$process.Id;creationFiletime=$creation;outputRoot=$OutputRoot;controlRoot=(Get-QControlRoot $Configuration);observations=[Collections.Generic.List[object]]::new();lastJournalSha256=$null}
}
function Assert-QOwnedProcess($Worker) {
    if ($Worker.process.Id -ne $Worker.processId -or $Worker.process.StartTime.ToUniversalTime().ToFileTimeUtc() -ne $Worker.creationFiletime) { throw 'Owned process identity changed.' }
}
function Stop-QOwnedProcess($Worker) {
    Assert-QOwnedProcess $Worker
    if (-not $Worker.process.HasExited) { $Worker.process.Kill(); if (-not $Worker.process.WaitForExit(10000)) { throw 'Owned process termination is unconfirmed; preserve evidence.' } }
}
function Wait-QWorker($Worker, [int] $Seconds=1800) {
    Assert-QOwnedProcess $Worker
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while (-not $Worker.process.HasExited -and $clock.Elapsed.TotalSeconds -lt $Seconds) { Add-QJournalObservation $Worker; Start-Sleep -Milliseconds 50 }
    if (-not $Worker.process.HasExited) { Stop-QOwnedProcess $Worker; throw 'Qualification worker exceeded its bounded campaign lifetime.' }
    $path=Join-Path $Worker.outputRoot 'result.json'
    if (-not [IO.File]::Exists($path)) { throw 'Worker has no completed evidence; inspect pending state.' }
    Add-QJournalObservation $Worker
    $record=Read-DistJson ([IO.File]::ReadAllBytes($path))
    $metrics=Get-QJournalMetrics $Worker.observations.ToArray()
    Write-QJson (Join-Path $Worker.outputRoot 'journal-observations.json') @{method='External polling of durable intent/observation UTC times; intervals exclude work before intent and after observation; missed intervals remain null';observations=$Worker.observations.ToArray();metrics=$metrics}
    $record['journalMetrics']=$metrics
    $record
}
function Add-QJournalObservation($Worker) {
    $path=Join-Path $Worker.controlRoot 'journal.json'
    if (-not [IO.File]::Exists($path)) { return }
    try {
        $bytes=[IO.File]::ReadAllBytes($path); $hash=Get-DistHash $bytes
        if ($hash -ceq $Worker.lastJournalSha256) { return }
        if ($Worker.observations.Count -ge 50000) { throw 'Journal observation bound exceeded.' }
        $journal=Read-DistJson $bytes
        $Worker.observations.Add(@{attemptId=$journal.attemptId;phase=$journal.phase;intent=$journal.intent;observation=$journal.observation;observedByHarnessUtc=[DateTimeOffset]::UtcNow.ToString('o')})
        $Worker.lastJournalSha256=$hash
    } catch [IO.IOException] { } catch [Text.Json.JsonException] { }
}
function Get-QJournalMetrics([object[]] $Observations) {
    $intervals=[Collections.Generic.List[object]]::new(); $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($item in $Observations) {
        if ($null -eq $item.observation -or $item.observation.sequence -ne $item.intent.sequence) { continue }
        $key=$item.attemptId+':'+$item.intent.sequence
        if (-not $seen.Add($key)) { continue }
        $seconds=([DateTimeOffset]::Parse($item.observation.observedUtc)-[DateTimeOffset]::Parse($item.intent.recordedUtc)).TotalSeconds
        if ($seconds -lt 0) { throw 'Journal timing is contradictory.' }
        $intervals.Add(@{operation=$item.intent.operation;sequence=$item.intent.sequence;seconds=$seconds;result=$item.observation.result})
    }
    $stop=@($Observations | Where-Object { $_.intent.operation -ceq 'Stop' } | Select-Object -First 1)
    $ready=@($Observations | Where-Object { $null -ne $_.observation -and $_.observation.result -ceq 'Ready' } | Select-Object -Last 1)
    $unavailability=$null
    if ($stop.Count -and $ready.Count) { $unavailability=([DateTimeOffset]::Parse($ready[0].observation.observedUtc)-[DateTimeOffset]::Parse($stop[0].intent.recordedUtc)).TotalSeconds }
    @{observedOperationIntervals=$intervals.ToArray();unavailabilityUpperBoundSeconds=$unavailability;inclusiveIntervalsMayOverlap=$true;missedBoundariesAreNotZero=$true}
}

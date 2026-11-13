[CmdletBinding()]
param([string] $ConfigurationPath,[ValidateSet('Preflight','Plan','Execute','Collect')][string] $Operation='Preflight',
    [string] $AuthorizationPath,[string[]] $ScenarioId=@(),[Parameter(Mandatory)][string] $OutputRoot)
. "$PSScriptRoot/Qualification.Scenarios.ps1"
$definitions=Get-QScenarioDefinitions; $runId=[guid]::NewGuid().ToString('D')
$configuration=if ($ConfigurationPath) { Read-QConfiguration $ConfigurationPath } else { $null }
if ($Operation -cne 'Plan' -and $null -eq $configuration) { throw 'Read-only preflight requires a concrete selected configuration.' }
Assert-DistLocalPath $OutputRoot
if ([IO.Directory]::Exists($OutputRoot) -or [IO.File]::Exists($OutputRoot)) { throw 'A qualification report directory must be new.' }
$results=@($definitions | ForEach-Object { New-QResult $_ $runId $configuration })
if ($Operation -ceq 'Plan') { Write-QReport $OutputRoot $results $runId; return }
$preflight=Get-QPreflight $configuration
if ($Operation -ceq 'Execute') {
    $null=Assert-QAuthorization $configuration $AuthorizationPath @('execute','change-owned-iis','change-owned-fixtures','terminate-owned-process')
    if (-not $OutputRoot.StartsWith($configuration.evidenceRoot+'\',[StringComparison]::Ordinal)) { throw 'Execution evidence escapes the authorized campaign.' }
    if ($ScenarioId.Count -eq 0 -or @($ScenarioId | Where-Object { $_ -cnotin @($definitions.id) }).Count -ne 0) { throw 'Select exact known scenario IDs.' }
}
$null=[IO.Directory]::CreateDirectory($OutputRoot); Write-QJson (Join-Path $OutputRoot 'preflight.json') $preflight
if ($Operation -ceq 'Execute') {
    Open-QObservationContext $configuration
    try {
        foreach ($result in $results) {
            if ($ScenarioId -cnotcontains $result.scenarioId) { continue }
            $definition=@($definitions | Where-Object id -CEQ $result.scenarioId)[0]
            $result.environmentFingerprint=Get-DistHash ([Text.Encoding]::UTF8.GetBytes(($preflight | ConvertTo-Json -Depth 24 -Compress)))
            $result.probeReleases=@($configuration.probeReleases.initial,$configuration.probeReleases.newer)
            $clock=[Diagnostics.Stopwatch]::StartNew(); $caseRoot=Join-Path $OutputRoot $result.scenarioId; $null=[IO.Directory]::CreateDirectory($caseRoot)
            try {
                $actual=Invoke-QScenario $configuration $definition $AuthorizationPath $caseRoot
                $result.status=$actual.status; $result.reason=$actual.reason; $result.actual=$actual.details; $result.initialPoolState=$actual.before.poolState
                if ($actual.status -ceq 'PASS') { $result.actual['evidenceKind']='Automatic' }
                $result.protectedSentinelPreserved=$actual.sentinelPreserved
                if ($null -ne $actual.worker) { $result.safeErrorCode=$actual.worker.code }
                if ($null -ne $actual.after) {
                    $result.finalPoolState=$actual.after.poolState; $result.finalWorkerCount=$actual.after.workerCount
                    $result.currentSha256=if ($null -eq $actual.after.state.current) {$null} else {$actual.after.state.current.sha256}
                    $result.journalSha256=if ($null -eq $actual.after.state.journal) {$null} else {$actual.after.state.journal.sha256}
                    $result.applicationInventoryVerified=$actual.status -ceq 'PASS'
                }
                $result.cleanup='Retained application, control, fixture and recovery material; no automatic restore or deletion'
            } catch {
                $result.status='FAIL'; $result.reason='Actual execution failed or a required precondition/evidence assertion was not satisfied; inspect retained campaign evidence.'
                $result.safeErrorCode=if ($_.FullyQualifiedErrorId -like 'Clc.*') {$_.FullyQualifiedErrorId.Split(',')[0]} else {'Qualification.AssertionFailed'}
                try { $pool=Get-QPoolObservation $configuration; $result.finalPoolState=$pool.poolState; $result.finalWorkerCount=$pool.workers.Count } catch { }
                $result.cleanup='Preserve all resources and pending state; operator intervention required'
                Write-QJson (Join-Path $caseRoot 'failure.json') @{code=$result.safeErrorCode;poolState=$result.finalPoolState;workerCount=$result.finalWorkerCount;retained=$true}
            }
            $result.elapsedSeconds=$clock.Elapsed.TotalSeconds; $result.supportingEvidencePath=$caseRoot
            $primary=Get-QEvidenceInventory $caseRoot
            $result.evidenceArtifacts=@($primary | ForEach-Object { @{path=(Join-Path $caseRoot $_.path.Replace('/','\'));sha256=$_.sha256} })
            Write-QJson (Join-Path $caseRoot 'scenario-result.json') $result
            $result.supportingEvidenceSha256=(Get-FileHash -LiteralPath (Join-Path $caseRoot 'scenario-result.json')).Hash.ToLowerInvariant()
            # A failed or interrupted scenario needs operator reconciliation before
            # another case can act on this canonical target.
            if ($result.status -ceq 'FAIL') { break }
        }
    } finally { Close-QObservationContext }
}
Write-QReport $OutputRoot $results $runId
[pscustomobject]@{runId=$runId;operation=$Operation;reportPath=(Join-Path $OutputRoot 'report.json');realHostQualified=$false;pass=@($results | Where-Object status -CEQ 'PASS').Count;fail=@($results | Where-Object status -CEQ 'FAIL').Count;blocked=@($results | Where-Object status -CEQ 'BLOCKED').Count;notRun=@($results | Where-Object status -CEQ 'NOT RUN').Count}
if (@($results | Where-Object status -CEQ 'FAIL').Count) { throw 'Qualification failed; preserve evidence and reconcile the actual target.' }

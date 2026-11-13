[CmdletBinding()]
param([Parameter(Mandatory)][string] $ConfigurationPath,[Parameter(Mandatory)][string] $AuthorizationPath,
    [Parameter(Mandatory)][string] $ScenarioId,[Parameter(Mandatory)][ValidateSet('PASS','FAIL','BLOCKED')][string] $Conclusion,
    [Parameter(Mandatory)][string[]] $EvidencePath,[Parameter(Mandatory)][string] $BeforeSnapshotPath,[Parameter(Mandatory)][string] $AfterSnapshotPath,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9-]{0,127}$')][string] $ObservationReference,
    [Parameter(Mandatory)][string] $OutputPath)
. "$PSScriptRoot/Qualification.Common.ps1"
$configuration=Read-QConfiguration $ConfigurationPath
$null=Assert-QAuthorization $configuration $AuthorizationPath @('attest-observed-qualification')
if ((Get-QCallerSid) -cne $configuration.infrastructureSid) { throw 'Only the observing infrastructure operator may attest manually executed cases.' }
$null=Read-QOwnership $configuration; Import-QVerifiedToolkit $configuration
$definition=@((Get-QScenarioDefinitions) | Where-Object id -CEQ $ScenarioId)
if ($definition.Count -ne 1 -or $definition[0].action -cnotin @('Operator','Security','Transport')) { throw 'Use automatic execution for this scenario.' }
$protectedRoot=Join-Path $configuration.evidenceRoot 'operator-evidence'
Assert-DistLocalPath $OutputPath
if (-not $OutputPath.StartsWith($protectedRoot+'\',[StringComparison]::Ordinal)) { throw 'Operator observations require a separately protected evidence directory.' }
Assert-QProtectedAuthorization $protectedRoot $configuration
if ($EvidencePath.Count -lt 1 -or $EvidencePath.Count -gt 64) { throw 'Supply bounded primary evidence of actual observations.' }
$artifacts=@()
foreach ($path in @($EvidencePath)+@($BeforeSnapshotPath,$AfterSnapshotPath)) {
    $null=Get-DistPathFacts $path
    Assert-QProtectedAuthorization $path $configuration
    if (-not $path.StartsWith($configuration.evidenceRoot+'\',[StringComparison]::Ordinal) -or [IO.FileInfo]::new($path).Length -gt 16777216) { throw 'Primary evidence must remain in this retained campaign and within its bound.' }
    $artifacts += @{path=$path;sha256=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()}
}
$snapshot=Read-DistJson ([IO.File]::ReadAllBytes($AfterSnapshotPath))
$before=Read-DistJson (Read-DistFileBytes $BeforeSnapshotPath)
if ($snapshot.poolState -cnotin @('Started','Stopped','Unknown') -or $snapshot.workerCount -lt 0 -or $snapshot.workerCount -gt 4096) { throw 'After-observation facts are invalid.' }
$runId=[guid]::NewGuid().ToString('D'); $result=New-QResult $definition[0] $runId $configuration
$result.status=$Conclusion; $result.reason='Operator observed; independent review of primary evidence required'; $result.actual=@{evidenceKind='OperatorObserved';observerSid=$configuration.infrastructureSid;observationReference=$ObservationReference;observedUtc=[DateTimeOffset]::UtcNow.ToString('o');artifacts=$artifacts}
$result.initialPoolState=$before.poolState
if ($Conclusion -ceq 'PASS' -and $definition[0].initialState -cne 'Either' -and $before.poolState -cne $definition[0].initialState) { throw 'Operator observation does not establish the required initial state.' }
$result.environmentFingerprint=Get-DistHash ([Text.Encoding]::UTF8.GetBytes($configuration.machineIdentity+':'+$configuration._sha256))
$result.probeReleases=@($configuration.probeReleases.initial,$configuration.probeReleases.newer)
$result.finalPoolState=$snapshot.poolState; $result.finalWorkerCount=$snapshot.workerCount; $result.cleanup='Operator retained all primary evidence; inspect actual cleanup observations'
$result.supportingEvidencePath=$OutputPath
Write-QJson $OutputPath $result
# This records a human's actual observations. It does not execute a scenario or
# turn a skipped/synthetic case into an automatic pass, and never qualifies T4.

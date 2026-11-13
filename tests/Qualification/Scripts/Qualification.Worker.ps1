[CmdletBinding()]
param([Parameter(Mandatory)][string] $ConfigurationPath,[Parameter(Mandatory)][string] $AuthorizationPath,[Parameter(Mandatory)][string] $OutputRoot,
    [ValidateSet('Invoke','Restore')][string] $Command='Invoke',[ValidateSet('initial','newer')][string] $ApprovalSlot='initial',
    [ValidateSet('RestorePrevious','AcceptCandidate','RestoreEmpty')][string] $Mode='AcceptCandidate')
. "$PSScriptRoot/Qualification.Process.ps1"
$clock=[Diagnostics.Stopwatch]::StartNew(); $commandClock=$null; $breakpoints=@(); $success=$false; $code=$null; $result=$null; $admitted=$false
try {
    $configuration=Read-QConfiguration $ConfigurationPath
    $null=Assert-QAuthorization $configuration $AuthorizationPath @('execute')
    Assert-QReadinessNetwork $configuration
    $deploymentToken=Assert-QRoleToken $configuration Deployment
    if ((Get-QCallerSid) -cne $configuration.deploymentSid -or -not $OutputRoot.StartsWith($configuration.evidenceRoot+'\',[StringComparison]::Ordinal)) { throw 'Qualification worker scope differs.' }
    $admitted=$true
    $null=Read-QOwnership $configuration
    Import-QVerifiedToolkit $configuration
    $global:ClcQualificationObservationState=@{counts=@{}}
    # Command observers count calls without depending on source lines or locals.
    foreach ($observedName in Get-QObservedCommands) {
        $action={
            $state=$global:ClcQualificationObservationState
            if (-not $state.counts.ContainsKey($observedName)) { $state.counts[$observedName]=0 }; $state.counts[$observedName]++
            continue
        }.GetNewClosure()
        $breakpoints += Set-PSBreakpoint -Command $observedName -Action $action
    }
    $targetId=$configuration.targetId
    $commandClock=[Diagnostics.Stopwatch]::StartNew()
    if ($Command -ceq 'Invoke') { $result=Invoke-ClcIisDeployment -TargetId $targetId -ReleaseApprovalId $configuration.probeReleases[$ApprovalSlot].approvalId }
    else {
        $journal=Read-DistJson ([IO.File]::ReadAllBytes((Join-Path (Get-QControlRoot $configuration) 'journal.json')))
        $result=Restore-ClcIisDeployment -TargetId $targetId -AttemptId $journal.attemptId -Mode $Mode -Reason $configuration.authorizationReference
    }
    $success=$true
} catch {
    $code=if ($_.FullyQualifiedErrorId -like 'Clc.*') { $_.FullyQualifiedErrorId.Split(',')[0] } else { 'Qualification.WorkerRefused' }
} finally {
    if ($null -ne $commandClock) { $commandClock.Stop() }
    foreach ($breakpoint in $breakpoints) { Remove-PSBreakpoint -Breakpoint $breakpoint }
    $counts=if ($null -ne (Get-Variable ClcQualificationObservationState -Scope Global -ErrorAction SilentlyContinue)) { $global:ClcQualificationObservationState.counts } else { @{} }
    if ($admitted) { Write-QJson (Join-Path $OutputRoot 'result.json') @{securityModel='ElevatedV1';deploymentToken=$deploymentToken;success=$success;code=$code;result=$result;elapsedSeconds=$clock.Elapsed.TotalSeconds;commandElapsedSeconds=$(if ($null -eq $commandClock) {$null} else {$commandClock.Elapsed.TotalSeconds});observationCounts=$counts;instrumented=$true} }
}
if (-not $success) { exit 1 }

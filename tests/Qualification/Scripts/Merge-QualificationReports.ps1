[CmdletBinding()]
param([Parameter(Mandatory)][string] $ConfigurationPath,[Parameter(Mandatory)][string] $AuthorizationPath,
    [string[]] $AdditionalCampaignConfigurationPath=@(),[string[]] $AdditionalCampaignAuthorizationPath=@(),
    [Parameter(Mandatory)][string[]] $ReportPath,[Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string] $ExpectedSourceCommit,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string] $ExpectedDistributionSha256,[Parameter(Mandatory)][string] $OutputRoot)
. "$PSScriptRoot/Qualification.Common.ps1"
$configuration=Read-QConfiguration $ConfigurationPath
$null=Assert-QAuthorization $configuration $AuthorizationPath @('attest-observed-qualification')
if ($configuration.toolkit.sourceCommit -cne $ExpectedSourceCommit -or $configuration.toolkit.distributionSha256 -cne $ExpectedDistributionSha256) { throw 'Selected report candidate differs from independently approved configuration.' }
if ($AdditionalCampaignConfigurationPath.Count -gt 256 -or $AdditionalCampaignConfigurationPath.Count -ne $AdditionalCampaignAuthorizationPath.Count) { throw 'Additional campaigns require bounded matching configuration and authorization selections.' }
$configurations=[Collections.Generic.List[object]]::new(); $configurations.Add($configuration)
for ($index=0;$index -lt $AdditionalCampaignConfigurationPath.Count;$index++) {
    $other=Read-QConfiguration $AdditionalCampaignConfigurationPath[$index]
    $null=Assert-QAuthorization $other $AdditionalCampaignAuthorizationPath[$index] @('attest-observed-qualification')
    foreach ($name in @('machineIdentity','computerName','infrastructureSid')) { if ($other[$name] -cne $configuration[$name]) { throw 'Aggregated campaigns require the same exact host and independent infrastructure reviewer.' } }
    foreach ($name in @('sourceCommit','distributionSha256','inventorySha256','version')) { if ($other.toolkit[$name] -cne $configuration.toolkit[$name]) { throw 'Aggregated campaigns require the same exact toolkit candidate.' } }
    if (@($configurations | Where-Object { $_.campaignId -ceq $other.campaignId -or $_.evidenceRoot -ieq $other.evidenceRoot }).Count) { throw 'Duplicate campaign identity or evidence namespace.' }
    $configurations.Add($other)
}
if ($ReportPath.Count -lt 1 -or $ReportPath.Count -gt 1024) { throw 'Select a bounded set of actual reports/observations.' }
$runId=[guid]::NewGuid().ToString('D'); $definitions=Get-QScenarioDefinitions; $results=@{}; $sources=@()
foreach ($definition in $definitions) { $results[$definition.id]=New-QResult $definition $runId }
foreach ($path in $ReportPath) {
    $selected=Select-QReportCampaign $path $configurations.ToArray()
    $reviewed=Read-QReviewedReport $path $selected; $document=$reviewed.document
    $candidates=if ($document.Contains('results')) { @($document.results) } else { @($document) }
    foreach ($candidate in $candidates) {
        if (-not $results.ContainsKey($candidate.scenarioId) -or $candidate.status -cnotin @('PASS','FAIL','BLOCKED','NOT RUN')) { throw 'Unknown matrix case or status.' }
        $definition=@($definitions | Where-Object id -CEQ $candidate.scenarioId)[0]
        if ($candidate.mandatory -isnot [bool] -or $candidate.mandatory -ne $definition.mandatory) { throw 'Evidence cannot change canonical mandatory matrix membership.' }
        if ($candidate.status -ceq 'NOT RUN') { continue }
        if ($candidate.sourceCommit -cne $ExpectedSourceCommit -or $candidate.installedDistributionSha256 -cne $ExpectedDistributionSha256 -or -not $candidate.environmentFingerprint) { throw 'Evidence belongs to another or unobserved candidate environment.' }
        if ($candidate.status -ceq 'PASS' -and -not $candidate.supportingEvidencePath) { throw 'A passing case requires primary evidence.' }
        if ($candidate.status -ceq 'PASS') {
            Confirm-QCandidateEvidence $candidate $definition $reviewed.review $reviewed.archiveRoot
            if ($definition.initialState -cne 'Either' -and $candidate.initialPoolState -cne $definition.initialState) { throw 'Required actual initial pool state is unproven.' }
        }
        $existing=$results[$candidate.scenarioId]
        if ($existing.status -ceq 'FAIL' -and $candidate.status -ceq 'PASS') { throw 'Conflicting failure needs explicit independent disposition; do not silently overwrite it.' }
        if ($candidate.status -ceq 'FAIL' -or $existing.status -ceq 'NOT RUN' -or $candidate.status -ceq 'PASS') { $results[$candidate.scenarioId]=$candidate }
    }
    $sources += @{path=$path;sha256=$reviewed.review.reportSha256;campaignId=$selected.campaignId;configurationSha256=$selected._sha256}
}
$ordered=@($definitions | ForEach-Object { $results[$_.id] })
Write-QReport $OutputRoot $ordered $runId -IndependentEvidenceVerified
Write-QJson (Join-Path $OutputRoot 'source-reports.json') @{sourceCommit=$ExpectedSourceCommit;distributionSha256=$ExpectedDistributionSha256;reports=$sources;independentAcceptance='Required; review every automatic and operator-observed primary artifact before qualification'}

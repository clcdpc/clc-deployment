[CmdletBinding()]
param([Parameter(Mandatory)][string] $ConfigurationPath,[ValidateSet('Inspect','ActivateReplacement')][string] $Operation='Inspect',
    [string] $ReplacementConfigurationPath,[string] $ReplacementAuthorizationPath,[string] $DistributionPath)
. "$PSScriptRoot/Qualification.Common.ps1"
$configuration=Read-QConfiguration $ConfigurationPath
if ($Operation -ceq 'Inspect') { [pscustomobject]@{operation='Inspect';mutations=$false;selectedToolkit=$configuration.toolkit}; return }
$replacement=Read-QConfiguration $ReplacementConfigurationPath
$null=Assert-QAuthorization $replacement $ReplacementAuthorizationPath @('activate-compatible-toolkit')
if ((Get-QCallerSid) -cne $configuration.infrastructureSid -or $replacement.toolkit.version -ceq $configuration.toolkit.version) { throw 'Use infrastructure authority and a separate version directory.' }
foreach ($name in $configuration.Keys) {
    if ($name -in @('_sha256','_path','toolkit','authorizationReference')) { continue }
    if (($configuration[$name] | ConvertTo-Json -Depth 16 -Compress) -cne ($replacement[$name] | ConvertTo-Json -Depth 16 -Compress)) { throw 'Replacement activation cannot change target enrollment or approved application fixtures.' }
}
$marker=Read-QOwnership $configuration
$manifest=Get-QInstalledManifest $replacement; $versionRoot=[IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($manifest))
$null=& "$script:QualificationRepository/tools/Expand-ToolkitDistribution.ps1" -ArchivePath $DistributionPath -ExpectedSha256 $replacement.toolkit.distributionSha256 -ExpectedSourceCommit $replacement.toolkit.sourceCommit -ExpectedVersion $replacement.toolkit.version -VersionRoot $versionRoot -OperatorApprovalReference $replacement.authorizationReference
# The protected toolkit parent supplies inherited infrastructure ownership and
# read/execute-only deployment access. Verify it before active metadata changes.
Assert-QProtectedAuthorization $versionRoot $configuration
$policyPath=Join-Path $configuration.ownedRoot 'toolkit\policy\host-policy.json'
$policyBytes=[IO.File]::ReadAllBytes($policyPath); $policy=Read-DistJson $policyBytes
if ($policy.activeToolkit.sourceCommit -cne $configuration.toolkit.sourceCommit -or $policy.activeToolkit.distributionSha256 -cne $configuration.toolkit.distributionSha256) { throw 'Original activation identity differs.' }
$history=Join-Path $configuration.ownedRoot 'toolkit\policy\activation-history'; $null=[IO.Directory]::CreateDirectory($history)
$historyStream=[IO.FileStream]::new((Join-Path $history ('host-policy-'+$policy.generation+'.json')),[IO.FileMode]::CreateNew)
try { $historyStream.Write($policyBytes); $historyStream.Flush($true) } finally { $historyStream.Dispose() }
Write-QJson (Join-Path $history ('owner-'+$policy.generation+'.json')) $marker
$policy.generation=[long]$policy.generation+1
$policy.activeToolkit=@{version=$replacement.toolkit.version;sourceCommit=$replacement.toolkit.sourceCommit;distributionSha256=$replacement.toolkit.distributionSha256;inventorySha256=$replacement.toolkit.inventorySha256;moduleManifestPath=$manifest}
function Publish-QInfrastructureRecord([string] $Path,$Record) {
    $temporary=Join-Path ([IO.Path]::GetDirectoryName($Path)) ('.activation-'+[guid]::NewGuid().ToString('N')+'.tmp')
    Write-QJson $temporary $Record; [IO.File]::Move($temporary,$Path,$true)
}
Publish-QInfrastructureRecord $policyPath $policy
$marker.configurationSha256=$replacement._sha256
Publish-QInfrastructureRecord (Join-Path $configuration.ownedRoot '.clc-t4-owner.json') $marker
[pscustomobject]@{activated=$replacement.toolkit;previous=$configuration.toolkit;applicationStateChanged=$false;nextAction='Use a fresh replacement-config deployment-token process for preflight and explicit recovery; separately prove the old inactive toolkit refuses.'}
# Failure between policy/marker writes remains an operator-visible activation
# interruption. Neither file publication repairs or clears application state.

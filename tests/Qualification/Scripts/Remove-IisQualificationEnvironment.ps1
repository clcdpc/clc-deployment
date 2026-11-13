[CmdletBinding()]
param([Parameter(Mandatory)][string] $ConfigurationPath,[ValidateSet('Inspect','RetireIis')][string] $Operation='Inspect',[string] $AuthorizationPath,[string] $OutputPath)
. "$PSScriptRoot/Qualification.Ownership.ps1"
$configuration=Read-QConfiguration $ConfigurationPath
if ($Operation -ceq 'Inspect') { [pscustomobject]@{mutations=$false;site=$configuration.siteName;pool=$configuration.poolName;filesystemRetention='All application/control/config/key/evidence files retained'}; return }
$null=Assert-QAuthorization $configuration $AuthorizationPath @('cleanup','change-owned-iis')
if ((Get-QCallerSid) -cne $configuration.infrastructureSid) { throw 'Owned-resource retirement requires infrastructure authority.' }
$marker=Read-QOwnership $configuration; Import-QVerifiedToolkit $configuration
if (-not (Invoke-QPrivate Test-ClcValueEqual @($marker.ownedRootIdentities,(Get-QOwnedRootIdentities $configuration)))) { throw 'A campaign root physical identity changed; cleanup refuses.' }
$journalPath=Join-Path (Get-QControlRoot $configuration) 'journal.json'
if ([IO.File]::Exists($journalPath)) {
    $journal=Read-DistJson ([IO.File]::ReadAllBytes($journalPath))
    $null=Invoke-QPrivate Read-ClcJson @([IO.File]::ReadAllBytes($journalPath),'journal')
    if (-not (Invoke-QPrivate Test-ClcHelpersExited @($journal))) { throw 'Unknown or surviving helpers require the fenced maintenance procedure before retirement.' }
}
$assembly=Join-Path ([IO.Path]::GetDirectoryName($configuration.appcmdPath)) 'Microsoft.Web.Administration.dll'
Add-Type -LiteralPath $assembly; $manager=[Microsoft.Web.Administration.ServerManager]::new()
try {
    Assert-QIisOwnershipSnapshot $marker.iisOwnership (Get-QIisOwnershipSnapshot $manager $configuration)
    $site=$manager.Sites[$configuration.siteName]; $pool=$manager.ApplicationPools[$configuration.poolName]
    if ($null -eq $site -or $null -eq $pool -or $site.Applications.Count -ne 1 -or $site.Applications['/'].ApplicationPoolName -cne $configuration.poolName -or $site.Applications['/'].VirtualDirectories.Count -ne 1 -or $site.Applications['/'].VirtualDirectories['/'].PhysicalPath -cne $configuration.applicationRoot) { throw 'Owned IIS resource identity changed.' }
    Assert-QNoForeignPoolApplications $manager $configuration
    if ($pool.State.ToString() -cne 'Stopped') { $null=$pool.Stop() }
    $clock=[Diagnostics.Stopwatch]::StartNew()
    do {
        $manager.Dispose(); $manager=[Microsoft.Web.Administration.ServerManager]::new(); $pool=$manager.ApplicationPools[$configuration.poolName]
        $workers=@($manager.WorkerProcesses | Where-Object AppPoolName -CEQ $configuration.poolName)
        if ($pool.State.ToString() -ceq 'Stopped' -and $workers.Count -eq 0) { break }; Start-Sleep -Milliseconds 250
    } while ($clock.Elapsed.TotalSeconds -lt 60)
    if ($pool.State.ToString() -cne 'Stopped' -or $workers.Count -ne 0) { throw 'Retirement could not prove stopped/zero workers.' }
    Assert-QIisOwnershipSnapshot $marker.iisOwnership (Get-QIisOwnershipSnapshot $manager $configuration)
    Assert-QNoForeignPoolApplications $manager $configuration
    $manager.Sites.Remove($manager.Sites[$configuration.siteName]); $manager.ApplicationPools.Remove($pool); $manager.CommitChanges()
    if ($OutputPath) { Write-QJson $OutputPath @{campaignId=$configuration.campaignId;retiredSite=$configuration.siteName;retiredPool=$configuration.poolName;filesystemRetained=$true;accountsAndCertificatesRetained=$true} }
} finally { $manager.Dispose() }
# No recursive delete, wildcard cleanup, certificate/account removal, journal
# repair or activation of quarantined application content is provided.

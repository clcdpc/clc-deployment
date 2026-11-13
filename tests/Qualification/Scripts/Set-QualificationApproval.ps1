[CmdletBinding()]
param([Parameter(Mandatory)][string] $ConfigurationPath,[ValidateSet('Inspect','Approve','Disable','Enable')][string] $Operation='Inspect',
    [Parameter(Mandatory)][ValidateSet('initial','newer')][string] $ReleaseSlot,[string] $AuthorizationPath,[string] $ApprovalRecordPath,[string] $OriginalApprovalPath)
. "$PSScriptRoot/Qualification.Common.ps1"
$configuration=Read-QConfiguration $ConfigurationPath; $release=$configuration.probeReleases[$ReleaseSlot]
$catalog=Join-Path $configuration.ownedRoot 'toolkit\policy\approvals'; $destination=Join-Path $catalog ($release.approvalId+'.json')
if ($Operation -ceq 'Inspect') { [pscustomobject]@{operation='Inspect';mutations=$false;approvalId=$release.approvalId;catalogRecordPresent=[IO.File]::Exists($destination)}; return }
$null=Assert-QAuthorization $configuration $AuthorizationPath @('approve-probe-bytes')
if ((Get-QCallerSid) -cne $configuration.infrastructureSid) { throw 'Approval changes require the independent infrastructure token.' }
$null=Read-QOwnership $configuration
Import-QVerifiedToolkit $configuration
if ($Operation -ceq 'Approve') {
    if ([IO.File]::Exists($destination)) { throw 'Approval creation refuses an existing record.' }
    Assert-DistLocalPath $ApprovalRecordPath; $record=Read-DistJson ([IO.File]::ReadAllBytes($ApprovalRecordPath))
} else {
    $originalBytes=[IO.File]::ReadAllBytes($destination); $record=Read-DistJson $originalBytes
    $history=Join-Path $configuration.ownedRoot 'toolkit\policy\approval-history'; $null=[IO.Directory]::CreateDirectory($history)
    $historyPath=Join-Path $history ($release.approvalId+'-'+(Get-DistHash $originalBytes)+'.json')
    if (-not [IO.File]::Exists($historyPath)) { [IO.File]::WriteAllBytes($historyPath,$originalBytes) }
    if ($Operation -ceq 'Disable') { if (-not $record.enabled) { throw 'Approval is already disabled.' }; $record.enabled=$false }
    else {
        Assert-DistLocalPath $OriginalApprovalPath
        if (-not $OriginalApprovalPath.StartsWith($history+'\',[StringComparison]::Ordinal)) { throw 'Select exact independently retained approval history.' }
        $record=Read-DistJson ([IO.File]::ReadAllBytes($OriginalApprovalPath))
        if (-not $record.enabled) { throw 'Reenable requires the exact original enabled record.' }
    }
}
$bytes=[Text.Encoding]::UTF8.GetBytes(($record | ConvertTo-Json -Depth 16 -Compress))
$null=Invoke-QPrivate Read-ClcJson @($bytes,'release-approval')
if ($record.approvalId -cne $release.approvalId -or $record.targetId -cne $configuration.targetId -or $record.applicationId -cne 'clc-qualification-probe' -or
    $record.releaseId -cne $release.releaseId -or $record.sourceCommit -cne $release.sourceCommit -or $record.sourceRepository -cne 'clcdpc/clc-deployment' -or
    $record.releaseZipSha256 -cne $release.archiveSha256 -or $record.manifestSha256 -cne $release.manifestSha256 -or $record.authorization.authoritySid -cne $configuration.infrastructureSid -or
    $record.authorization.reference -cne $configuration.authorizationReference) { throw 'Operator approval does not bind the exact selected probe provenance and bytes.' }
if ($Operation -ceq 'Approve' -or $Operation -ceq 'Enable') {
    $inspection=Test-ClcRelease -ArchivePath (Join-Path $configuration.artifactInboxRoot ($release.approvalId+'.zip'))
    if ($inspection.archiveSha256 -cne $release.archiveSha256 -or $inspection.manifestSha256 -cne $release.manifestSha256) { throw 'Staged probe bytes differ.' }
}
$temporary=Join-Path $catalog ('.approval-'+[guid]::NewGuid().ToString('N')+'.tmp')
$stream=[IO.FileStream]::new($temporary,[IO.FileMode]::CreateNew)
try { $stream.Write($bytes); $stream.Flush($true) } finally { $stream.Dispose() }
[IO.File]::Move($temporary,$destination,($Operation -cne 'Approve'))
if ((Get-DistHash ([IO.File]::ReadAllBytes($destination))) -cne (Get-DistHash $bytes)) { throw 'Approval publication readback differs.' }
[pscustomobject]@{approvalId=$release.approvalId;enabled=$record.enabled;operation=$Operation;buildDidNotApproveItself=$true}

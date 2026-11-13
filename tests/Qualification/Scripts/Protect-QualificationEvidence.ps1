[CmdletBinding()]
param([Parameter(Mandatory)][string] $ConfigurationPath,[Parameter(Mandatory)][string] $AuthorizationPath,
    [Parameter(Mandatory)][string] $ReportPath,[Parameter(Mandatory)][string] $ArchiveRoot)
. "$PSScriptRoot/Qualification.Common.ps1"
$configuration=Read-QConfiguration $ConfigurationPath
$null=Assert-QAuthorization $configuration $AuthorizationPath @('attest-observed-qualification')
if ((Get-QCallerSid) -cne $configuration.infrastructureSid) { throw 'Independent evidence review/archive requires infrastructure identity.' }
$sourceRoot=[IO.Path]::GetDirectoryName($ReportPath); $protectedRoot=Join-Path $configuration.evidenceRoot 'operator-evidence'
foreach ($path in @($ReportPath,$ArchiveRoot)) { Assert-DistLocalPath $path }
if (-not $ReportPath.StartsWith($configuration.evidenceRoot+'\',[StringComparison]::Ordinal) -or -not $ArchiveRoot.StartsWith($protectedRoot+'\',[StringComparison]::Ordinal) -or
    $ArchiveRoot.StartsWith($sourceRoot+'\',[StringComparison]::OrdinalIgnoreCase) -or $sourceRoot.StartsWith($ArchiveRoot+'\',[StringComparison]::OrdinalIgnoreCase) -or [IO.Directory]::Exists($ArchiveRoot)) { throw 'Select new disjoint protected evidence archive within this campaign.' }
Assert-QProtectedAuthorization $protectedRoot $configuration
$null=Get-DistPathFacts $sourceRoot -Directory
$handles=[Collections.Generic.List[IDisposable]]::new(); $streams=@{}
try {
    # Pin the source namespace and files without following leaf reparse points.
    # Additional source entries cannot enter this explicit immutable copy list.
    $queue=[Collections.Generic.Queue[string]]::new(); $queue.Enqueue($sourceRoot); $count=0
    while ($queue.Count) {
        $directory=$queue.Dequeue(); $null=Get-DistPathFacts $directory -Directory
        $handles.Add([Clc.Distribution.Paths]::PinDirectory($directory))
        foreach ($path in [IO.Directory]::EnumerateFileSystemEntries($directory)) {
            $count++; if ($count -gt 20000) { throw 'Evidence archive exceeds its entry bound.' }
            if (([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::Directory) -ne 0) { $queue.Enqueue($path); continue }
            $null=Get-DistPathFacts $path
            $stream=[Clc.Distribution.Paths]::OpenEvidenceFile($path); $handles.Add($stream)
            $streams[$path.Substring($sourceRoot.Length+1)]=$stream
        }
    }
    $initial=Get-QEvidenceInventory $sourceRoot
    $null=& "$PSScriptRoot/Test-QualificationEvidencePrivacy.ps1" -EvidenceRoot $sourceRoot -OperationalConfigurationPath $configuration.operationalConfigPath
    $null=[IO.Directory]::CreateDirectory($ArchiveRoot)
    foreach ($relative in $streams.Keys) {
        $destination=Join-Path $ArchiveRoot $relative; Assert-DistLocalPath $destination
        $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
        $output=[IO.FileStream]::new($destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try { $streams[$relative].Position=0; $streams[$relative].CopyTo($output); $output.Flush($true) } finally { $output.Dispose() }
    }
    $copied=Get-QEvidenceInventory $ArchiveRoot; $final=Get-QEvidenceInventory $sourceRoot
    if ((Get-DistInventoryHash $initial) -cne (Get-DistInventoryHash $copied) -or (Get-DistInventoryHash $initial) -cne (Get-DistInventoryHash $final)) { throw 'Source evidence changed or archive bytes differ; retain unapproved material.' }
    $archivedReport=Join-Path $ArchiveRoot ([IO.Path]::GetFileName($ReportPath))
    $review=@{formatVersion=1;recordKind='qualification-evidence-review';campaignId=$configuration.campaignId;configurationSha256=$configuration._sha256;
        sourceCommit=$configuration.toolkit.sourceCommit;distributionSha256=$configuration.toolkit.distributionSha256;approvedBySid=$configuration.infrastructureSid;reference=$configuration.authorizationReference;
        sourceRoot=$sourceRoot;reportName=[IO.Path]::GetFileName($ReportPath);reportSha256=(Get-FileHash -LiteralPath $archivedReport).Hash.ToLowerInvariant();rootIdentity=(Get-DistPathFacts $ArchiveRoot -Directory).Identity;
        files=$copied;inventorySha256=(Get-DistInventoryHash $copied);reviewedUtc=[DateTimeOffset]::UtcNow.ToString('o')}
    Write-QJson (Join-Path $ArchiveRoot 'operator-review.json') $review
    # The preexisting archive parent must supply infrastructure ownership and
    # immutable deployment/runtime access; verify the final report/receipt too.
    Assert-QProtectedAuthorization $archivedReport $configuration
    Assert-QProtectedAuthorization (Join-Path $ArchiveRoot 'operator-review.json') $configuration
    [pscustomobject]@{archivedReportPath=$archivedReport;reportSha256=$review.reportSha256;inventorySha256=$review.inventorySha256;approvedBySid=$review.approvedBySid;automaticQualification=$false}
} finally { foreach ($handle in $handles) { $handle.Dispose() } }
# The human reviews primary effects BEFORE invoking this explicit approval tool.
# This archive is data approval only, never application execution authority.

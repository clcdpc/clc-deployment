[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RepositoryRoot,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string] $SourceCommit,
    [Parameter(Mandatory)][string] $OutputPath,
    [string] $ReleaseVersion
)
. "$PSScriptRoot/Distribution.Common.ps1"
Assert-DistLocalPath $RepositoryRoot; Assert-DistLocalPath $OutputPath
if ($ReleaseVersion) { Assert-DistVersion $ReleaseVersion }
if ([IO.File]::Exists($OutputPath) -or [IO.File]::Exists($OutputPath+'.identity.json') -or -not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($OutputPath))) { throw 'Distribution output must be new with an existing parent.' }
if ((Get-DistGit $RepositoryRoot @('rev-parse','HEAD')) -cne $SourceCommit -or
    (Get-DistGit $RepositoryRoot @('status','--porcelain=v1','--untracked-files=normal'))) { throw 'Source-pinned distribution requires the exact clean committed HEAD.' }
$temporary=Join-Path ([IO.Path]::GetDirectoryName($OutputPath)) ('.source-'+[guid]::NewGuid().ToString('N')+'.zip')
$zip=$null; $outputStream=$null; $outputZip=$null
try {
    $null=Get-DistGit $RepositoryRoot @('archive','--format=zip',('--output='+$temporary),$SourceCommit)
    $zip=[IO.Compression.ZipFile]::OpenRead($temporary)
    $treeBlobs=Get-DistGitTreeBlobMap $RepositoryRoot $SourceCommit
    $source=[Collections.Generic.List[object]]::new(); $module=[Collections.Generic.List[object]]::new(); $infrastructure=[Collections.Generic.List[object]]::new(); $payload=@{}; $versionBytes=$null
    $entries=@($zip.Entries | Where-Object { -not $_.FullName.EndsWith('/') } | Sort-Object FullName -CaseSensitive -Culture '')
    foreach ($entry in $entries) {
        Assert-DistName $entry.FullName
        $bytes=Read-DistEntry $entry
        if(-not $treeBlobs.ContainsKey($entry.FullName)){throw 'Archive entry is absent from the raw committed source tree.'}
        Assert-DistGitBlobBytes $bytes $treeBlobs[$entry.FullName]
        $null=$treeBlobs.Remove($entry.FullName)
        $source.Add([ordered]@{path=$entry.FullName;length=[long]$bytes.Length;sha256=(Get-DistHash $bytes)})
        if ($entry.FullName -ceq 'VERSION') { $versionBytes=$bytes }
        if ($entry.FullName.StartsWith('src/CLC.Deployment/',[StringComparison]::Ordinal)) {
            $relative=$entry.FullName.Substring(19)
            if ($relative -cnotmatch '^(CLC\.Deployment\.ps[dm]1|(Private|Public)/[A-Za-z0-9.-]+\.ps1)$') { throw 'Unexpected module runtime dependency.' }
            $module.Add([ordered]@{path=$relative;length=[long]$bytes.Length;sha256=(Get-DistHash $bytes)})
            $payload['CLC.Deployment/'+$relative]=$bytes
        }
        if ($entry.FullName -cin (Get-DistInfrastructureNames)) {
            $infrastructure.Add([ordered]@{path=$entry.FullName;length=[long]$bytes.Length;sha256=(Get-DistHash $bytes)})
            $payload[$entry.FullName]=$bytes
        }
    }
    # Refuse export-ignore, submodules, export transformations and incomplete
    # source archives. Every retained entry already matched its raw Git object.
    if ($treeBlobs.Count -ne 0) { throw 'Committed raw source tree and archive differ.' }
    $sourceFiles=Sort-DistFiles $source.ToArray()
    Assert-DistInventory $sourceFiles
    if ($null -eq $versionBytes) { throw 'Committed shared VERSION is missing.' }
    $version=Get-DistVersionFromBytes $versionBytes
    $manifestText=[Text.UTF8Encoding]::new($false,$true).GetString($payload['CLC.Deployment/CLC.Deployment.psd1'])
    if ((Get-DistModuleVersion $manifestText) -cne $version) { throw 'Committed module metadata differs from the shared repository version.' }
    $sourceManifest=$payload['CLC.Deployment/CLC.Deployment.psd1']
    if ($ReleaseVersion) {
        $version=$ReleaseVersion
        $generated=Get-DistVersionedManifestBytes $sourceManifest $version
        $payload['CLC.Deployment/CLC.Deployment.psd1']=$generated
        foreach ($file in $module) {
            if ($file.path -ceq 'CLC.Deployment.psd1') { $file.length=[long]$generated.Length; $file.sha256=Get-DistHash $generated }
        }
    }
    $moduleFiles=Sort-DistFiles $module.ToArray()
    Assert-DistInventory $moduleFiles
    $record=[ordered]@{distributionFormat='clc-toolkit-distribution';formatVersion=1;sourceCommit=$SourceCommit;moduleVersion=$version;
        files=$moduleFiles;inventorySha256=(Get-DistInventoryHash $moduleFiles);sourceFiles=$sourceFiles;sourceInventorySha256=(Get-DistInventoryHash $sourceFiles);
        toolchain=[ordered]@{powershell=$PSVersionTable.PSVersion.ToString();dotnetRuntime=[Environment]::Version.ToString();git=(Get-DistGit $RepositoryRoot @('--version'))};
        reproducibility='Stored ZIP, ordinal inventory, fixed 1980 timestamps; exact bytes repeat with the same source and toolchain. Rebuilt apps and cross-runtime ZIP identity are not claimed.'}
    if ($infrastructure.Count) {
        if ($infrastructure.Count -ne @(Get-DistInfrastructureNames).Count) { throw 'Incomplete infrastructure tooling inventory.' }
        $record.formatVersion=2
        $record.infrastructureFiles=Sort-DistFiles $infrastructure.ToArray()
        $record.infrastructureInventorySha256=Get-DistInventoryHash $record.infrastructureFiles
    }
    $payload['distribution.json']=[Text.Encoding]::UTF8.GetBytes(($record | ConvertTo-Json -Depth 16 -Compress))
    $payload['source.commit']=[Text.Encoding]::ASCII.GetBytes($SourceCommit)
    # Recheck before publication; do not claim a dirty checkout is a pinned input.
    if ((Get-DistGit $RepositoryRoot @('rev-parse','HEAD')) -cne $SourceCommit -or (Get-DistGit $RepositoryRoot @('status','--porcelain=v1','--untracked-files=normal'))) { throw 'Source changed during distribution creation.' }
    $outputStream=[IO.FileStream]::new($OutputPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $outputZip=[IO.Compression.ZipArchive]::new($outputStream,[IO.Compression.ZipArchiveMode]::Create,$true)
    $names=[string[]]@($payload.Keys); [Array]::Sort($names,[StringComparer]::Ordinal)
    foreach ($name in $names) {
        $entry=$outputZip.CreateEntry($name,[IO.Compression.CompressionLevel]::NoCompression)
        $entry.LastWriteTime=[DateTimeOffset]::new(1980,1,1,0,0,0,[TimeSpan]::Zero); $entry.ExternalAttributes=0
        $entryStream=$entry.Open(); try { $entryStream.Write($payload[$name]) } finally { $entryStream.Dispose() }
    }
    $outputZip.Dispose(); $outputZip=$null; $outputStream.Flush($true); $outputStream.Dispose(); $outputStream=$null
    $identity=[ordered]@{sourceCommit=$SourceCommit;moduleVersion=$version;distributionSha256=(Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash.ToLowerInvariant();inventorySha256=$record.inventorySha256;sourceInventorySha256=$record.sourceInventorySha256}
    [IO.File]::WriteAllText($OutputPath+'.identity.json',($identity | ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
    [pscustomobject]$identity
} finally {
    if ($null -ne $outputZip) { $outputZip.Dispose() }; if ($null -ne $outputStream) { $outputStream.Dispose() }
    if ($null -ne $zip) { $zip.Dispose() }
    if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
}

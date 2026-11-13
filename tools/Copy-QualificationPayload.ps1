[CmdletBinding()]
param([Parameter(Mandatory)][string] $PublishRoot,[Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string] $ExpectedInventorySha256,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')][string] $SourceRepository,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string] $SourceCommit,[Parameter(Mandatory)][string] $DestinationRoot,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9-]{0,127}$')][string] $ProducerReference,[Parameter(Mandatory)][switch] $DisposableTestPayload)
. "$PSScriptRoot/Distribution.Common.ps1"
if (-not $DisposableTestPayload) { throw 'Only an explicitly selected disposable test publish payload is allowed.' }
$sourceFacts=Get-DistPathFacts $PublishRoot -Directory; Assert-DistLocalPath $DestinationRoot
if ([IO.Directory]::Exists($DestinationRoot) -or $DestinationRoot.StartsWith($PublishRoot+'\',[StringComparison]::OrdinalIgnoreCase) -or $PublishRoot.StartsWith($DestinationRoot+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Payload destination must be new and disjoint.' }
$files=[Collections.Generic.List[object]]::new(); $queue=[Collections.Generic.Queue[string]]::new(); $queue.Enqueue($PublishRoot); $clock=[Diagnostics.Stopwatch]::StartNew(); $entries=0
while ($queue.Count) {
    foreach ($path in [IO.Directory]::EnumerateFileSystemEntries($queue.Dequeue())) {
        $entries++
        if ($clock.Elapsed.TotalSeconds -ge 300 -or $entries -gt 18000) { throw 'Payload enumeration exceeded its bound.' }
        $directory=([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::Directory) -ne 0
        $null=Get-DistPathFacts $path -Directory:$directory
        if ($directory) { $queue.Enqueue($path); continue }
        $name=$path.Substring($PublishRoot.Length+1).Replace('\','/'); Assert-DistName $name
        if ([IO.FileInfo]::new($path).Length -gt 268435456) { throw 'Payload file exceeds bound.' }
        $files.Add(@{path=$name;length=[long][IO.FileInfo]::new($path).Length;sha256=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()})
    }
}
$inventory=Sort-DistFiles $files.ToArray(); Assert-DistInventory $inventory
if ((Get-DistInventoryHash $inventory) -cne $ExpectedInventorySha256) { throw 'Independent representative payload inventory differs.' }
$selected=@($inventory | Where-Object {
    $leaf=[IO.Path]::GetFileName($_.path)
    [IO.Path]::GetExtension($leaf) -in @('.dll','.json','.css','.js','.png','.jpg','.svg','.html','.txt','.woff','.woff2','.ico','.dat') -and
    $leaf -inotmatch '^(appsettings|web\.config$|launchsettings|.*(private|secret|credential|password|certificate|key-ring))'
})
if ($selected.Count -lt 1) { throw 'Representative payload has no admitted files.' }
$null=[IO.Directory]::CreateDirectory($DestinationRoot)
foreach ($file in $selected) {
    if ($clock.Elapsed.TotalSeconds -ge 300) { throw 'Payload copy exceeded its bound.' }
    $source=Join-Path $PublishRoot $file.path.Replace('/','\'); $destination=Join-Path $DestinationRoot $file.path.Replace('/','\')
    Assert-DistLocalPath $destination; $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
    $inputStream=[IO.FileStream]::new($source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $outputStream=[IO.FileStream]::new($destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $inputStream.CopyTo($outputStream); $outputStream.Flush($true) } finally { $inputStream.Dispose(); $outputStream.Dispose() }
    if ([IO.FileInfo]::new($destination).Length -ne $file.length -or (Get-FileHash -LiteralPath $destination).Hash.ToLowerInvariant() -cne $file.sha256) { throw 'Copied representative bytes differ.' }
}
if ((Get-DistPathFacts $PublishRoot -Directory).Identity -cne $sourceFacts.Identity) { throw 'Representative root changed.' }
[pscustomobject]@{sourceRepository=$SourceRepository;sourceCommit=$SourceCommit;producerReference=$ProducerReference;inputInventorySha256=$ExpectedInventorySha256;selectedInventorySha256=(Get-DistInventoryHash $selected);selectedFileCount=$selected.Count;selectedBytes=[long](($selected | Measure-Object length -Sum).Sum);semanticReview='Application owner must verify content contains no private configuration/secrets; these payload files are measured as assets and are not executed as additional applications.'}

[CmdletBinding()]
param([Parameter(Mandatory)][string] $ArchivePath,[Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string] $ExpectedSha256,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string] $ExpectedSourceCommit,[Parameter(Mandatory)][string] $ExpectedVersion,
    [Parameter(Mandatory)][string] $VersionRoot,[Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9-]{0,127}$')][string] $OperatorApprovalReference)
. "$PSScriptRoot/Distribution.Common.ps1"
Assert-DistVersion $ExpectedVersion
Assert-DistLocalPath $VersionRoot
if ([IO.Path]::GetFileName($VersionRoot) -cne $ExpectedVersion -or [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($VersionRoot)) -cne 'versions' -or
    [IO.Directory]::Exists($VersionRoot) -or [IO.File]::Exists($VersionRoot)) { throw 'Select a new exact version directory under versions.' }
$null=Get-DistPathFacts ([IO.Path]::GetDirectoryName($VersionRoot)) -Directory
$null=Get-DistPathFacts $ArchivePath
$archiveStream=[IO.FileStream]::new($ArchivePath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
$zip=$null
try {
    # Hold the original bytes against write/delete throughout verification and
    # extraction, including standalone use outside the enrollment caller.
    $verified=& "$PSScriptRoot/Test-ToolkitDistribution.ps1" -ArchivePath $ArchivePath -ExpectedSha256 $ExpectedSha256 -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedVersion $ExpectedVersion
    $null=New-Item -ItemType Directory -Path $VersionRoot -ErrorAction Stop
    $zip=[IO.Compression.ZipArchive]::new($archiveStream,[IO.Compression.ZipArchiveMode]::Read,$true)
    $clock=[Diagnostics.Stopwatch]::StartNew(); $total=0L; $buffer=[byte[]]::new(65536)
    foreach ($entry in $zip.Entries) {
        if ($clock.Elapsed.TotalSeconds -ge 300) { throw 'Distribution extraction deadline exceeded.' }
        if (-not $entry.FullName.StartsWith('CLC.Deployment/',[StringComparison]::Ordinal) -and $entry.FullName -cnotin (Get-DistInfrastructureNames)) { continue }
        $path=Join-Path $VersionRoot $entry.FullName.Replace('/','\'); Assert-DistLocalPath $path
        $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
        $inputStream=$entry.Open(); $outputStream=[IO.FileStream]::new($path,[IO.FileMode]::CreateNew)
        try {
            $length=0L
            while (($count=$inputStream.Read($buffer,0,$buffer.Length)) -gt 0) {
                $length += $count; $total += $count
                if ($clock.Elapsed.TotalSeconds -ge 300 -or $length -gt 268435456 -or $length -gt $entry.Length -or $total -gt 1073741824) { throw 'Distribution extraction exceeds bounds.' }
                $outputStream.Write($buffer,0,$count)
            }
            if ($length -ne $entry.Length) { throw 'Distribution extracted length differs.' }
            $outputStream.Flush($true)
        } finally { $inputStream.Dispose(); $outputStream.Dispose() }
    }
    $archiveStream.Position=0
    $retained=[IO.FileStream]::new((Join-Path $VersionRoot 'distribution.zip'),[IO.FileMode]::CreateNew)
    try {
        $retainedLength=0L
        while (($count=$archiveStream.Read($buffer,0,$buffer.Length)) -gt 0) {
            $retainedLength += $count
            if ($retainedLength -gt 1073741824 -or $clock.Elapsed.TotalSeconds -ge 300) { throw 'Retained distribution exceeds bounds.' }
            $retained.Write($buffer,0,$count)
        }
        $retained.Flush($true)
    } finally { $retained.Dispose() }
    $source=[IO.FileStream]::new((Join-Path $VersionRoot 'source.commit'),[IO.FileMode]::CreateNew)
    try { $source.Write([Text.Encoding]::ASCII.GetBytes($ExpectedSourceCommit));$source.Flush($true) } finally {$source.Dispose()}
} finally { if ($null -ne $zip) {$zip.Dispose()}; $archiveStream.Dispose() }
$null=& "$PSScriptRoot/Test-ToolkitDistribution.ps1" -ArchivePath (Join-Path $VersionRoot 'distribution.zip') -ExpectedSha256 $ExpectedSha256 -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedVersion $ExpectedVersion -InstalledModuleRoot (Join-Path $VersionRoot 'CLC.Deployment')
[pscustomobject]@{extracted=$true;activated=$false;moduleManifestPath=(Join-Path $VersionRoot 'CLC.Deployment\CLC.Deployment.psd1');identity=$verified;operatorApprovalReference=$OperatorApprovalReference;nextAction='Infrastructure must protect ownership/ACLs and independently activate the exact pin before import.'}
# A failed extraction is retained as unactivated evidence, never repaired in place.

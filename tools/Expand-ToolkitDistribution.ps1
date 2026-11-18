[CmdletBinding()]
param([Parameter(Mandatory)][string] $ArchivePath,[Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string] $ExpectedSha256,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string] $ExpectedSourceCommit,[Parameter(Mandatory)][string] $ExpectedVersion,
    [Parameter(Mandatory)][string] $DestinationRoot)
. "$PSScriptRoot/Distribution.Common.ps1"
Assert-DistVersion $ExpectedVersion
Assert-DistLocalPath $DestinationRoot
if ([IO.Directory]::Exists($DestinationRoot) -or [IO.File]::Exists($DestinationRoot)) { throw 'Select a new extraction directory with an existing safe parent.' }
$null=Get-DistPathFacts ([IO.Path]::GetDirectoryName($DestinationRoot)) -Directory
$null=Get-DistPathFacts $ArchivePath
$archiveStream=[IO.FileStream]::new($ArchivePath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
$zip=$null
try {
    # Hold the original bytes against write/delete throughout verification and
    # extraction, including standalone use outside the enrollment caller.
    $verified=& "$PSScriptRoot/Test-ToolkitDistribution.ps1" -ArchivePath $ArchivePath -ExpectedSha256 $ExpectedSha256 -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedVersion $ExpectedVersion
    $moduleName=$verified.moduleName
    $null=New-Item -ItemType Directory -Path $DestinationRoot -ErrorAction Stop
    $zip=[IO.Compression.ZipArchive]::new($archiveStream,[IO.Compression.ZipArchiveMode]::Read,$true)
    $clock=[Diagnostics.Stopwatch]::StartNew(); $total=0L; $buffer=[byte[]]::new(65536)
    foreach ($entry in $zip.Entries) {
        if ($clock.Elapsed.TotalSeconds -ge 300) { throw 'Distribution extraction deadline exceeded.' }
        if (-not $entry.FullName.StartsWith(($moduleName+'/'),[StringComparison]::Ordinal)) { continue }
        $path=Join-Path $DestinationRoot $entry.FullName.Replace('/','\'); Assert-DistLocalPath $path
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
} finally { if ($null -ne $zip) {$zip.Dispose()}; $archiveStream.Dispose() }
$null=& "$PSScriptRoot/Test-ToolkitDistribution.ps1" -ArchivePath $ArchivePath -ExpectedSha256 $ExpectedSha256 -ExpectedSourceCommit $ExpectedSourceCommit -ExpectedVersion $ExpectedVersion -ExtractedModuleRoot (Join-Path $DestinationRoot $moduleName)
[pscustomobject]@{moduleManifestPath=(Join-Path $DestinationRoot ($moduleName+'\'+$moduleName+'.psd1'));identity=$verified}

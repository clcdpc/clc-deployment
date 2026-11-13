[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RepositoryRoot,
    [Parameter(Mandatory)][string] $Tag,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string] $SourceCommit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Distribution.Common.ps1')

$root=[IO.Path]::GetFullPath($RepositoryRoot)
Assert-DistLocalPath $root
if (-not [IO.Directory]::Exists($root)) { throw 'Release source directory is missing.' }
if (-not $Tag.StartsWith('v',[StringComparison]::Ordinal)) { throw 'Release tag must start with lowercase v.' }
$version=$Tag.Substring(1)
Assert-DistReleaseTag $Tag $version
$head=Get-DistGit $root @('rev-parse','HEAD')
if ($head -cne $SourceCommit) { throw 'Release source HEAD differs from the event commit.' }
if (Get-DistGit $root @('status','--porcelain=v1','--untracked-files=normal')) { throw 'Release source checkout is not clean.' }
try {
    $tagCommit=Get-DistGit $root @('rev-parse','--verify',($Tag+'^{commit}'))
} catch {
    throw 'The release tag is absent from the checked-out source.'
}
if ($tagCommit -cne $SourceCommit) { throw 'The release tag does not point to the checked-out source commit.' }

[pscustomobject][ordered]@{tag=$Tag;version=$version;sourceCommit=$SourceCommit;prerelease=($version.Contains('-'))}

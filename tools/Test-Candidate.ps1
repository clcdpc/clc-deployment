
[CmdletBinding()]
param([Parameter(Mandatory)][string] $OutputRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repository=Split-Path $PSScriptRoot -Parent
if ([IO.Directory]::Exists($OutputRoot)) { throw 'Select a new distribution test output directory.' }
$null=[IO.Directory]::CreateDirectory($OutputRoot)
$source=(& git -C $repository rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Could not identify the committed toolkit source.' }
$first=Join-Path $OutputRoot 'toolkit.zip'
$second=Join-Path $OutputRoot 'repeat.zip'
$identity=& "$PSScriptRoot/New-ToolkitDistribution.ps1" -RepositoryRoot $repository -SourceCommit $source -OutputPath $first
$repeat=& "$PSScriptRoot/New-ToolkitDistribution.ps1" -RepositoryRoot $repository -SourceCommit $source -OutputPath $second
if ($identity.distributionSha256 -cne $repeat.distributionSha256) { throw 'The exact toolkit build did not reproduce.' }
$extraction=& "$PSScriptRoot/Expand-ToolkitDistribution.ps1" -ArchivePath $first -ExpectedSha256 $identity.distributionSha256 -ExpectedSourceCommit $source -ExpectedVersion $identity.moduleVersion -DestinationRoot (Join-Path $OutputRoot 'toolkit')
Import-Module $extraction.moduleManifestPath -Force
$exports=@(Get-Command -Module Clc.Deployment)
if ($exports.Count -ne 6 -or (Test-ClcRelease -ReleaseTag v1.0.0-dev.1).releaseId -cne 'v1-0-0-dev-1') { throw 'The extracted toolkit public API did not load correctly.' }
[pscustomobject]@{sourceCommit=$source;toolkit=$identity;reproducible=$true;actualIis='NOT RUN'}

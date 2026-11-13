[CmdletBinding()]
param([Parameter(Mandatory)][string] $DestinationRoot)
Set-StrictMode -Version Latest; $ErrorActionPreference='Stop'
. "$PSScriptRoot/Distribution.Common.ps1"
Assert-DistLocalPath $DestinationRoot
if ([IO.Directory]::Exists($DestinationRoot) -or [IO.File]::Exists($DestinationRoot)) { throw 'Provision SDK into a new test dependency directory.' }
$pin=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'probe-sdk.lock.json') -Raw | ConvertFrom-Json -AsHashtable
$null=[IO.Directory]::CreateDirectory($DestinationRoot); $archive=Join-Path $DestinationRoot 'sdk.zip'
Invoke-WebRequest -Uri $pin.url -OutFile $archive -TimeoutSec 180
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA512).Hash.ToLowerInvariant() -cne $pin.sha512) { throw 'Official SDK distribution digest differs.' }
$root=Join-Path $DestinationRoot 'sdk'; [IO.Compression.ZipFile]::ExtractToDirectory($archive,$root)
$dotnet=Join-Path $root 'dotnet.exe'
if ((& $dotnet --version).Trim() -cne $pin.version -or $LASTEXITCODE -ne 0) { throw 'Pinned SDK identity differs.' }
[pscustomobject]@{dotnetPath=$dotnet;sdkVersion=$pin.version;archiveSha512=$pin.sha512;installation='Test dependency only; no system installation or trust-store change requested'}

# Dependencies are provisioned only on the disposable hosted validator/test runner.
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $Destination, [switch] $IncludeActionlint)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$lock = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'dependencies.lock.json') -Raw | ConvertFrom-Json -AsHashtable
if (Test-Path -LiteralPath $Destination) { throw 'Dependency destination must be new.' }
[void][IO.Directory]::CreateDirectory($Destination)
foreach ($name in @('yamlDotNet') + $(if ($IncludeActionlint) { 'actionlint' })) {
    $pin = $lock[$name]
    $archive = Join-Path $Destination ($name + '.zip')
    Invoke-WebRequest -Uri $pin.url -OutFile $archive -TimeoutSec 60 -MaximumRedirection 5
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -cne $pin.sha256) { throw 'Dependency archive digest mismatch.' }
    if ($name -ceq 'yamlDotNet') {
        $digest = [Convert]::ToBase64String([Security.Cryptography.SHA512]::HashData([IO.File]::ReadAllBytes($archive)))
        if ($digest -cne $pin.sha512Base64) { throw 'NuGet catalog digest mismatch.' }
    }
    [IO.Compression.ZipFile]::ExtractToDirectory($archive,(Join-Path $Destination $name))
}
$assembly = Join-Path $Destination ('yamlDotNet/' + $lock.yamlDotNet.assembly)
if ((Get-FileHash -LiteralPath $assembly).Hash.ToLowerInvariant() -cne $lock.yamlDotNet.assemblySha256) { throw 'YAML assembly digest mismatch.' }
[pscustomobject]@{ YamlAssemblyPath=$assembly; ActionlintPath=$(if ($IncludeActionlint) { Join-Path $Destination 'actionlint/actionlint.exe' }) }

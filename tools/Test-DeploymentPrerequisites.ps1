[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $PesterManifestPath,
    [Parameter(Mandatory)][string] $YamlAssemblyPath,
    [Parameter(Mandatory)][string] $ActionlintPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$lock=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'dependencies.lock.json') -Raw | ConvertFrom-Json -AsHashtable
$pesterRoot=Split-Path ([IO.Path]::GetFullPath($PesterManifestPath)) -Parent
$files=@(Get-ChildItem -LiteralPath $pesterRoot -Recurse -File -Force)
if ($files.Count -ne $lock.pester.files.Count) { throw 'Incomplete pinned Pester inventory.' }
foreach ($file in $files) {
    $name=$file.FullName.Substring($pesterRoot.Length+1).Replace('\','/')
    if (-not $lock.pester.files.Contains($name) -or (Get-FileHash -LiteralPath $file.FullName).Hash.ToLowerInvariant() -cne $lock.pester.files[$name]) { throw 'Pinned Pester inventory mismatch.' }
}
Import-Module $PesterManifestPath -Force
$env:CLC_PREREQUISITES_YAML=$YamlAssemblyPath
foreach ($file in Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -File | Where-Object Extension -In '.ps1','.psm1') {
    $tokens=$null; $parseErrors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$parseErrors)
    if ($parseErrors.Count) { throw ('PowerShell syntax error: '+$file.Name) }
}
$configuration=New-PesterConfiguration
$configuration.Run.Path=Join-Path $PSScriptRoot 'deployment-prerequisites/tests'
$configuration.Run.PassThru=$true
$configuration.Output.Verbosity='Detailed'
$result=Invoke-Pester -Configuration $configuration
if ($result.FailedCount -or $result.SkippedCount -or $result.NotRunCount -or $result.Result -cne 'Passed') { throw 'Prerequisites tests must pass without skips.' }
Push-Location $root
try {
    & $ActionlintPath -shellcheck= -pyflakes=
    if ($LASTEXITCODE -ne 0) { throw 'Workflow actionlint validation failed.' }
    & $ActionlintPath -shellcheck= -pyflakes= docs/examples/deployment-readiness.yml
    if ($LASTEXITCODE -ne 0) { throw 'Consumer workflow template actionlint validation failed.' }
} finally { Pop-Location }
Write-Host "Prerequisites validation: $($result.PassedCount) tests passed; all workflows passed YAML parsing and actionlint. No host operations were run."

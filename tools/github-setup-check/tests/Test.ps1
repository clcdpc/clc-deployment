[CmdletBinding()]
param([Parameter(Mandatory)][string] $PesterManifestPath,[Parameter(Mandatory)][string] $ActionlintPath)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$lock=Get-Content -LiteralPath (Join-Path $root 'tools/dependencies.lock.json') -Raw | ConvertFrom-Json -AsHashtable
$pesterRoot=Split-Path ([IO.Path]::GetFullPath($PesterManifestPath)) -Parent
$files=@(Get-ChildItem -LiteralPath $pesterRoot -File -Recurse -Force)
if ($files.Count -ne $lock.pester.files.Count) { throw 'Incomplete pinned Pester inventory.' }
foreach ($file in $files) {
    $name=$file.FullName.Substring($pesterRoot.Length+1).Replace('\','/')
    if (-not $lock.pester.files.Contains($name) -or (Get-FileHash -LiteralPath $file.FullName).Hash.ToLowerInvariant() -cne $lock.pester.files[$name]) { throw 'Pinned Pester inventory mismatch.' }
}
foreach ($file in Get-ChildItem -LiteralPath (Split-Path $PSScriptRoot -Parent) -Recurse -File -Filter '*.ps1') {
    $tokens=$null; $errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw "PowerShell syntax errors in $($file.Name): $errors" }
}
Import-Module ([IO.Path]::GetFullPath($PesterManifestPath)) -Force
$configuration=New-PesterConfiguration
$configuration.Run.Path=Join-Path $PSScriptRoot 'Check.Tests.ps1'
$configuration.Run.PassThru=$true
$configuration.Output.Verbosity='Detailed'
$result=Invoke-Pester -Configuration $configuration
if ($result.Result -cne 'Passed' -or $result.FailedCount -or $result.SkippedCount -or $result.NotRunCount) { throw 'GitHub setup tests must pass without skips.' }
# Actionlint also parses YAML, including reusable input/output types and example syntax.
Push-Location $root
try {
    & $ActionlintPath -shellcheck= -pyflakes=
    if ($LASTEXITCODE -ne 0) { throw 'Workflow YAML/actionlint validation failed.' }
    & $ActionlintPath -shellcheck= -pyflakes= docs/examples/check-github-setup.yml
    if ($LASTEXITCODE -ne 0) { throw 'Consumer example YAML/actionlint validation failed.' }
} finally { Pop-Location }
foreach ($file in @((Get-Item -LiteralPath (Join-Path $root 'README.md'))) + @(Get-ChildItem -LiteralPath (Join-Path $root 'docs') -Recurse -File -Filter '*.md')) {
    $content=Get-Content -LiteralPath $file.FullName -Raw
    foreach ($match in [regex]::Matches($content,'\[[^\]]*\]\(([^)]+)\)')) {
        $link=$match.Groups[1].Value
        if ($link -match '^[a-z]+://') { continue }
        $parts=$link.Split('#',2)
        $target=if ($parts[0]) { Join-Path $file.DirectoryName $parts[0] } else { $file.FullName }
        if (-not (Test-Path -LiteralPath $target)) { throw "Broken documentation link in $($file.Name): $link" }
        if ($parts.Count -eq 2 -and [IO.Path]::GetExtension($target) -eq '.md') {
            $headings=Get-Content -LiteralPath $target -Raw
            $anchors=@([regex]::Matches($headings,'(?m)^#{1,6} (.+?)\r?$') | ForEach-Object { ($_.Groups[1].Value.ToLowerInvariant() -replace '[^a-z0-9 -]','') -replace ' ','-' })
            if ($parts[1] -notin $anchors) { throw "Broken documentation anchor in $($file.Name): $link" }
        }
    }
}
Write-Host "GitHub setup: $($result.PassedCount) tests passed; syntax, workflow YAML, actionlint and documentation links passed."

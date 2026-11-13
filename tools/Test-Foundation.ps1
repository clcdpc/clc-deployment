[CmdletBinding()]
param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $PesterManifestPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot -Parent
$lock = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'dependencies.lock.json') -Raw | ConvertFrom-Json -AsHashtable
if (-not $IsWindows -or $PSVersionTable.PSVersion.ToString() -cne $lock.powershell.version) {
    throw 'Foundation verification requires Windows and the exact pinned PowerShell patch.'
}
$pesterManifest = [IO.Path]::GetFullPath($PesterManifestPath)
if ([IO.Path]::GetFileName($pesterManifest) -cne 'Pester.psd1') { throw 'Expected a provisioned Pester.psd1.' }
$pesterRoot = [IO.Path]::GetDirectoryName($pesterManifest)
$observed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($file in Get-ChildItem -LiteralPath $pesterRoot -File -Recurse -Force) {
    $name = $file.FullName.Substring($pesterRoot.Length+1).Replace('\','/')
    if (-not $observed.Add($name) -or -not $lock.pester.files.Contains($name) -or
        (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -cne $lock.pester.files[$name]) {
        throw 'Provisioned Pester inventory differs from the independently authenticated package pin.'
    }
}
if ($observed.Count -ne $lock.pester.files.Count) { throw 'Provisioned Pester files are incomplete.' }
foreach ($path in @('src','tests','tools')) {
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $repository $path) -Recurse -File | Where-Object { $_.Extension -in @('.ps1','.psm1','.psd1') }) {
        $tokens = $null; $parseErrors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$parseErrors)
        if ($parseErrors.Count -gt 0) { throw ('PowerShell syntax validation failed: ' + $file.Name) }
    }
}
foreach ($path in @('schemas','tests/Fixtures','tools')) {
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $repository $path) -Filter '*.json' -File) {
        $null = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -AsHashtable -Depth 64
    }
}
$null = Test-ModuleManifest -Path (Join-Path $repository 'src/CLC.Deployment/CLC.Deployment.psd1')
Import-Module $pesterManifest -Force
if ((Get-Module Pester).Version.ToString() -cne $lock.pester.version) { throw 'Unexpected Pester version.' }
Write-Host ('Toolchain: PowerShell ' + $PSVersionTable.PSVersion + '; Pester ' + $lock.pester.version + '; OS ' + [Environment]::OSVersion.VersionString + '; .NET ' + [Environment]::Version)
function Get-VerificationFingerprint {
    $names=[string[]]@(& git -C $repository ls-files --cached --others --exclude-standard -- src tests tools schemas .github global.json NuGet.Config | Select-Object -Unique)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot enumerate verification inputs.' }
    [Array]::Sort($names,[StringComparer]::Ordinal)
    $records=[Text.StringBuilder]::new()
    foreach ($name in $names) {
        if (-not [IO.File]::Exists((Join-Path $repository $name))) { continue }
        $hash=(Get-FileHash -LiteralPath (Join-Path $repository $name) -Algorithm SHA256).Hash.ToLowerInvariant()
        [void]$records.Append($name).Append([char]0).Append($hash).Append("`n")
    }
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($records.ToString()))).ToLowerInvariant()
}
$inputFingerprint=Get-VerificationFingerprint
$configuration = New-PesterConfiguration
$configuration.Run.Path = Join-Path $repository 'tests'
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'Normal'
$result = Invoke-Pester -Configuration $configuration
$finalFingerprint=Get-VerificationFingerprint
$summary = [pscustomobject]@{
    passed=$result.PassedCount; failed=$result.FailedCount; skipped=$result.SkippedCount;
    notRun=$result.NotRunCount; inconclusive=$result.InconclusiveCount; result=$result.Result;
    inputFingerprint=$inputFingerprint; finalFingerprint=$finalFingerprint; inputsUnchanged=($inputFingerprint -ceq $finalFingerprint)
}
$summary | Format-List | Out-Host
if ($result.Result -cne 'Passed' -or $result.FailedCount -gt 0 -or $result.SkippedCount -gt 0 -or $result.NotRunCount -gt 0 -or $result.InconclusiveCount -gt 0 -or $inputFingerprint -cne $finalFingerprint) {
    throw 'Foundation closure gate failed. Every required test must pass without skips.'
}
return $summary

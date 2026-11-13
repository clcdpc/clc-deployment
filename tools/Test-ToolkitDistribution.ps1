[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $ArchivePath,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string] $ExpectedSha256,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string] $ExpectedSourceCommit,
    [Parameter(Mandatory)][string] $ExpectedVersion,
    [string] $InstalledModuleRoot,
    [switch] $RequireInfrastructureTools
)
. "$PSScriptRoot/Distribution.Common.ps1"
Assert-DistVersion $ExpectedVersion
Assert-DistLocalPath $ArchivePath
$null=Get-DistPathFacts $ArchivePath
$stream=[IO.FileStream]::new($ArchivePath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read); $zip=$null
try {
    if ($stream.Length -gt 1073741824 -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant() -cne $ExpectedSha256) { throw 'Independently supplied distribution digest differs.' }
    $stream.Position=0; $zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Read,$true)
    if ($zip.Entries.Count -gt 20000) { throw 'Distribution entry count exceeds bound.' }
    $entries=@{}; $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $zip.Entries) {
        Assert-DistName $entry.FullName
        if (-not $seen.Add($entry.FullName) -or $entry.ExternalAttributes -ne 0) { throw 'Unexpected distribution entry.' }
        $entries[$entry.FullName]=$entry
    }
    if (-not $entries.ContainsKey('distribution.json') -or -not $entries.ContainsKey('source.commit')) { throw 'Missing distribution identity.' }
    $record=Read-DistJson (Read-DistEntry $entries['distribution.json'] 4194304)
    $fields=@('distributionFormat','formatVersion','sourceCommit','moduleVersion','files','inventorySha256','sourceFiles','sourceInventorySha256','toolchain','reproducibility')
    if ($record.formatVersion -eq 2) { $fields += 'infrastructureFiles','infrastructureInventorySha256' }
    Assert-DistFields $record $fields
    Assert-DistFields $record.toolchain @('powershell','dotnetRuntime','git')
    foreach ($name in @('powershell','dotnetRuntime','git')) { if ($record.toolchain[$name] -isnot [string] -or $record.toolchain[$name].Length -gt 128) { throw 'Invalid recorded toolchain.' } }
    if ($record.files -isnot [array] -or $record.sourceFiles -isnot [array] -or $record.reproducibility -isnot [string] -or $record.reproducibility.Length -gt 1024) { throw 'Invalid distribution field types.' }
    if ($record.distributionFormat -cne 'clc-toolkit-distribution' -or $record.formatVersion -isnot [long] -and $record.formatVersion -isnot [int] -or $record.formatVersion -notin @(1,2) -or
        $record.sourceCommit -cne $ExpectedSourceCommit -or $record.moduleVersion -cne $ExpectedVersion -or
        [Text.Encoding]::ASCII.GetString((Read-DistEntry $entries['source.commit'] 40)) -cne $ExpectedSourceCommit) { throw 'Distribution identity differs.' }
    Assert-DistInventory $record.files; Assert-DistInventory $record.sourceFiles
    $infrastructureFiles=@()
    if ($record.formatVersion -eq 2) {
        Assert-DistInventory $record.infrastructureFiles
        $infrastructureFiles=$record.infrastructureFiles
        if ($infrastructureFiles.Count -ne @(Get-DistInfrastructureNames).Count -or (Get-DistInventoryHash $infrastructureFiles) -cne $record.infrastructureInventorySha256) { throw 'Infrastructure inventory differs.' }
        foreach ($file in $infrastructureFiles) {
            if ($file.path -cnotin (Get-DistInfrastructureNames) -or -not $entries.ContainsKey($file.path)) { throw 'Unexpected infrastructure tooling.' }
            $bytes=Read-DistEntry $entries[$file.path]
            if ($bytes.Length -ne $file.length -or (Get-DistHash $bytes) -cne $file.sha256) { throw 'Infrastructure bytes differ.' }
            $sourceFile=@($record.sourceFiles | Where-Object {$_.path -ceq $file.path})
            if ($sourceFile.Count -ne 1 -or $sourceFile[0].length -ne $file.length -or $sourceFile[0].sha256 -cne $file.sha256) { throw 'Infrastructure/source inventory differs.' }
        }
    } elseif ($RequireInfrastructureTools) { throw 'Host enrollment requires a format-2 distribution with infrastructure tools.' }
    if ((Get-DistInventoryHash $record.files) -cne $record.inventorySha256 -or (Get-DistInventoryHash $record.sourceFiles) -cne $record.sourceInventorySha256 -or $entries.Count -ne $record.files.Count+$infrastructureFiles.Count+2) { throw 'Distribution inventory differs.' }
    foreach ($file in $record.files) {
        if ($file.path -cnotmatch '^(CLC\.Deployment\.ps[dm]1|(Private|Public)/[A-Za-z0-9.-]+\.ps1)$') { throw 'Unexpected module runtime file.' }
        $name='CLC.Deployment/'+$file.path
        if (-not $entries.ContainsKey($name)) { throw 'Missing module file.' }
        $bytes=Read-DistEntry $entries[$name]
        if ($bytes.Length -ne $file.length -or (Get-DistHash $bytes) -cne $file.sha256) { throw 'Module bytes differ.' }
        $sourceFile=@($record.sourceFiles | Where-Object { $_.path -ceq ('src/'+$name) })
        # The output manifest is version-stamped; all substantive module files remain source-exact.
        if ($sourceFile.Count -ne 1 -or ($file.path -cne 'CLC.Deployment.psd1' -and ($sourceFile[0].length -ne $file.length -or $sourceFile[0].sha256 -cne $file.sha256))) { throw 'Module/source inventory differs.' }
    }
    $moduleManifest=[Text.UTF8Encoding]::new($false,$true).GetString((Read-DistEntry $entries['CLC.Deployment/CLC.Deployment.psd1']))
    if ((Get-DistModuleVersion $moduleManifest) -cne $ExpectedVersion) { throw 'Module manifest version differs from distribution identity.' }
    if ($InstalledModuleRoot) {
        $null=Get-DistPathFacts $InstalledModuleRoot -Directory
        $allowedDirectories=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($file in $record.files) {
            $parent=[IO.Path]::GetDirectoryName($file.path.Replace('/','\'))
            while ($parent) { $null=$allowedDirectories.Add($parent); $parent=[IO.Path]::GetDirectoryName($parent) }
        }
        $queue=[Collections.Generic.Queue[string]]::new(); $queue.Enqueue($InstalledModuleRoot); $walkCount=0
        while ($queue.Count) {
            foreach ($path in [IO.Directory]::EnumerateFileSystemEntries($queue.Dequeue())) {
                $walkCount++; if ($walkCount -gt 20000) { throw 'Installed tree exceeds bound.' }
                $isDirectory=([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::Directory) -ne 0
                $null=Get-DistPathFacts $path -Directory:$isDirectory
                if ($isDirectory) {
                    if (-not $allowedDirectories.Contains($path.Substring($InstalledModuleRoot.Length+1))) { throw 'Unexpected installed directory.' }
                    $queue.Enqueue($path)
                }
            }
        }
        $installed=@(Get-ChildItem -LiteralPath $InstalledModuleRoot -Recurse -File -Force)
        if ($installed.Count -ne $record.files.Count) { throw 'Installed inventory count differs.' }
        foreach ($file in $installed) {
            $null=Get-DistPathFacts $file.FullName
            $name=$file.FullName.Substring($InstalledModuleRoot.Length+1).Replace('\','/')
            $expected=@($record.files | Where-Object { $_.path -ceq $name })
            if ($expected.Count -ne 1 -or $file.Length -ne $expected[0].length -or (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expected[0].sha256) { throw 'Installed file differs.' }
        }
        if ($infrastructureFiles.Count) {
            $versionRoot=[IO.Path]::GetDirectoryName($InstalledModuleRoot)
            $toolsRoot=Join-Path $versionRoot 'tools'
            $null=Get-DistPathFacts $toolsRoot -Directory
            $toolFiles=@(Get-ChildItem -LiteralPath $toolsRoot -File -Recurse -Force)
            if ($toolFiles.Count -ne $infrastructureFiles.Count) { throw 'Installed infrastructure inventory differs.' }
            foreach ($file in $toolFiles) {
                $null=Get-DistPathFacts $file.FullName
                $name=$file.FullName.Substring($versionRoot.Length+1).Replace('\','/')
                $expected=@($infrastructureFiles | Where-Object {$_.path -ceq $name})
                if ($expected.Count -ne 1 -or $file.Length -ne $expected[0].length -or (Get-FileHash -LiteralPath $file.FullName).Hash.ToLowerInvariant() -cne $expected[0].sha256) { throw 'Installed infrastructure bytes differ.' }
            }
            $directories=@(Get-ChildItem -LiteralPath $toolsRoot -Directory -Recurse -Force)
            if ($directories.Count -ne 1 -or $directories[0].FullName -cne (Join-Path $toolsRoot 'host')) { throw 'Unexpected installed infrastructure directory.' }
            $null=Get-DistPathFacts $directories[0].FullName -Directory
        }
    }
    [pscustomobject]@{integrityVerified=$true;authenticatedByThisCheck=$false;sourceCommit=$record.sourceCommit;moduleVersion=$record.moduleVersion;
        distributionSha256=$ExpectedSha256;inventorySha256=$record.inventorySha256;sourceInventorySha256=$record.sourceInventorySha256;fileCount=$record.files.Count;formatVersion=$record.formatVersion}
} finally { if ($null -ne $zip) { $zip.Dispose() }; $stream.Dispose() }

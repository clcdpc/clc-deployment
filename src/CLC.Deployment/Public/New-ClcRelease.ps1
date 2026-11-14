function New-ClcRelease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $PublishRoot,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $MetadataPath,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $OutputPath,
        [ValidateNotNullOrEmpty()][string] $HookRoot
    )
    $handles = [Collections.Generic.List[IDisposable]]::new()
    $output = $null
    $temporary = $null
    $ownedFacts = $null
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        $root = Get-ClcPathObservation $PublishRoot $handles -Directory
        $metadataFacts = Get-ClcPathObservation $MetadataPath $handles
        Assert-ClcDisjoint $root $metadataFacts
        Assert-ClcPathSpelling $OutputPath
        Assert-ClcProtectedPath $OutputPath
        $parent = Get-ClcPathObservation ([IO.Path]::GetDirectoryName($OutputPath)) $handles -Directory
        Assert-ClcDisjoint $root $parent
        if (Test-ClcPathAncestry $parent.CanonicalPath $metadataFacts.CanonicalPath) { Stop-ClcError Clc.UnsafePath }
        if ([IO.File]::Exists($OutputPath) -or [IO.Directory]::Exists($OutputPath)) { Stop-ClcError Clc.OutputExists }
        $metadataStream = Open-ClcReadFile $MetadataPath $metadataFacts $handles
        $metadataDigest = Read-ClcStream $metadataStream $script:ClcLimits.Json $clock -Capture
        $metadata = Read-ClcJson $metadataDigest.bytes 'release-metadata' ([int] $script:ClcLimits.Json)
        if ($metadata.builder.module -cne 'CLC.Deployment' -or $metadata.builder.version -cne (Get-ClcToolkitVersion)) { Stop-ClcError Clc.InvalidContract }
        $hookRootFacts=$null; $hookFiles=@()
        if ($metadata.Contains('hooks')) {
            if (-not $PSBoundParameters.ContainsKey('HookRoot')) { Stop-ClcError Clc.InvalidContract }
            $hookRootFacts=Get-ClcPathObservation $HookRoot $handles -Directory
            foreach ($other in @($root,$metadataFacts,$parent)) { Assert-ClcDisjoint $hookRootFacts $other }
            $hookFiles=Get-ClcPublishInventory $hookRootFacts $handles $clock -HookAssets
        } elseif ($PSBoundParameters.ContainsKey('HookRoot')) { Stop-ClcError Clc.InvalidContract }
        $files = Get-ClcPublishInventory $root $handles $clock
        if ($files.Count+$hookFiles.Count -ge $script:ClcLimits.Entries -or
            (@($files)+@($hookFiles) | Measure-Object length -Sum).Sum -gt $script:ClcLimits.Expanded) { Stop-ClcError Clc.UnsafeArchive }
        $manifestBytes = ConvertTo-ClcManifestBytes $metadata $files $hookFiles
        $manifest = Read-ClcJson $manifestBytes 'release-manifest' ([int] $script:ClcLimits.Json)
        $web = @($files | Where-Object { $_.path -ceq 'application/web.config' })
        $runtimeName = 'application/' + [IO.Path]::GetFileNameWithoutExtension($metadata.validation.entryPoint) + '.runtimeconfig.json'
        $runtime = @($files | Where-Object { $_.path -ceq $runtimeName })
        if ($web.Count -ne 1 -or $runtime.Count -ne 1) { Stop-ClcError Clc.UnsafeArchive }
        $webDigest = Read-ClcStream $web[0].stream $script:ClcLimits.Json $clock -Capture
        $web[0].stream.Position = 0
        Assert-ClcWebConfig $webDigest.bytes $metadata.validation.entryPoint
        $runtimeDigest = Read-ClcStream $runtime[0].stream $script:ClcLimits.Json $clock -Capture
        $runtime[0].stream.Position = 0
        Assert-ClcRuntimeConfig $runtimeDigest.bytes $metadata.runtime.framework
        # Reobserve held roots before the first create-new output write.
        $again = Get-ClcPathObservation $parent.CanonicalPath $handles -Directory
        if ($again.VolumeId -cne $parent.VolumeId -or $again.FileId -cne $parent.FileId) { Stop-ClcError Clc.UnsafePath }
        $temporary = Join-Path $parent.CanonicalPath ('.clc-build-' + [guid]::NewGuid().ToString('D') + '.tmp')
        $output = [Clc.Foundation.NativePaths]::CreateOutput($temporary)
        $ownedFacts = [Clc.Foundation.NativePaths]::Observe($output.SafeFileHandle)
        $zip = [IO.Compression.ZipArchive]::new($output,[IO.Compression.ZipArchiveMode]::Create,$true)
        try {
            $entry = $zip.CreateEntry('manifest.json',[IO.Compression.CompressionLevel]::NoCompression)
            $entry.LastWriteTime = [DateTimeOffset]::new(1980,1,1,0,0,0,[TimeSpan]::Zero)
            $entry.ExternalAttributes = 0
            $destination = $entry.Open()
            try { $destination.Write($manifestBytes,0,$manifestBytes.Length) } finally { $destination.Dispose() }
            foreach ($file in @($files)+@($hookFiles)) {
                Assert-ClcDeadline $clock
                $entry = $zip.CreateEntry($file.path,[IO.Compression.CompressionLevel]::NoCompression)
                $entry.LastWriteTime = [DateTimeOffset]::new(1980,1,1,0,0,0,[TimeSpan]::Zero)
                $entry.ExternalAttributes = 0
                $destination = $entry.Open()
                try { $digest = Read-ClcStream $file.stream $script:ClcLimits.File $clock -Destination $destination } finally { $destination.Dispose() }
                if ($digest.length -ne $file.length -or $digest.sha256 -cne $file.sha256) { Stop-ClcError Clc.ContentDrift }
                if ($output.Length -gt $script:ClcLimits.Compressed) { Stop-ClcError Clc.UnsafeArchive }
            }
        } finally { $zip.Dispose() }
        # Reenumerate to reject added/removed files as well as changed held file bytes.
        $rechecked = Get-ClcPublishInventory $root $handles $clock
        if ((Get-ClcInventoryHash $rechecked) -cne $manifest.inventorySha256) { Stop-ClcError Clc.ContentDrift }
        if ($null -ne $hookRootFacts) {
            $recheckedHooks=Get-ClcPublishInventory $hookRootFacts $handles $clock -HookAssets
            if ((Get-ClcInventoryHash $recheckedHooks) -cne $manifest.hooks.inventorySha256) { Stop-ClcError Clc.ContentDrift }
        }
        $output.Flush($true)
        $output.Position = 0
        $inspection = Test-ClcArchiveStream $output $clock
        $null = Get-ClcPathObservation $parent.CanonicalPath $handles -Directory
        # Non-overwriting rename is the only publication. A competing output is preserved.
        try { [Clc.Foundation.NativePaths]::PublishOutput($output.SafeFileHandle,$OutputPath) }
        catch {
            if ([IO.File]::Exists($OutputPath) -or [IO.Directory]::Exists($OutputPath)) { Stop-ClcError Clc.OutputExists }
            throw
        }
        $finalSource = Get-ClcPublishInventory $root $handles $clock
        if ((Get-ClcInventoryHash $finalSource) -cne $manifest.inventorySha256) { Stop-ClcError Clc.ContentDrift }
        if ($null -ne $hookRootFacts) {
            $finalHooks=Get-ClcPublishInventory $hookRootFacts $handles $clock -HookAssets
            if ((Get-ClcInventoryHash $finalHooks) -cne $manifest.hooks.inventorySha256) { Stop-ClcError Clc.ContentDrift }
        }
        $temporary = $null
        $output.Dispose()
        $output = $null
        return [pscustomobject][ordered]@{
            contractFamily='clc-file-iis-v1'; packageContractVersion=$inspection.packageContractVersion; releaseId=$inspection.releaseId; archivePath=$OutputPath;
            archiveSha256=$inspection.archiveSha256; manifestSha256=$inspection.manifestSha256; inventorySha256=$inspection.inventorySha256;
            fileCount=$inspection.fileCount; totalBytes=$inspection.totalBytes; builderVersion=$inspection.builderVersion
        }
    } catch {
        $code = 'Clc.UnsafePath'
        if ($_.FullyQualifiedErrorId -like 'Clc.*') { $code = $_.FullyQualifiedErrorId.Split(',')[0] }
        $PSCmdlet.ThrowTerminatingError([Management.Automation.ErrorRecord]::new(
            [IO.InvalidDataException]::new('Release packaging failed; existing inputs and outputs were preserved.'), $code,
            [Management.Automation.ErrorCategory]::InvalidData, $null))
    } finally {
        if ($null -ne $output) {
            try {
                if ($null -ne $temporary -and $null -ne $ownedFacts) {
                    $actual = [Clc.Foundation.NativePaths]::Observe($output.SafeFileHandle)
                    if ($actual.VolumeId -ceq $ownedFacts.VolumeId -and $actual.FileId -ceq $ownedFacts.FileId -and $actual.LinkCount -eq 1 -and ($actual.Attributes -band 0x410) -eq 0) {
                        [Clc.Foundation.NativePaths]::DeleteOutput($output.SafeFileHandle)
                    }
                }
            } catch { } finally { $output.Dispose() }
        }
        foreach ($handle in $handles) { $handle.Dispose() }
    }
}

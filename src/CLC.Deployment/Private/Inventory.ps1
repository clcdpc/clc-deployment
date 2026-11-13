$script:ClcLimits = @{ Json = 4194304L; Compressed = 1073741824L; Entries = 20000L; Expanded = 1073741824L; File = 268435456L; Ratio = 100L; Seconds = 300 }

function Get-ClcBytesHash {
    param([byte[]] $Bytes)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Get-ClcInventoryHash {
    param([object[]] $Files)
    $hash = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    try {
        $paths = [string[]] @($Files | ForEach-Object { $_.path })
        [Array]::Sort($paths, [StringComparer]::Ordinal)
        $lookup = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        foreach ($file in $Files) { $lookup.Add($file.path, $file) }
        foreach ($path in $paths) {
            $file = $lookup[$path]
            $line = $path + [char]0 + $file.length.ToString([Globalization.CultureInfo]::InvariantCulture) + [char]0 + $file.sha256 + "`n"
            $hash.AppendData([Text.Encoding]::UTF8.GetBytes($line))
        }
        return [Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant()
    } finally { $hash.Dispose() }
}

function Assert-ClcDeadline {
    param([Diagnostics.Stopwatch] $Clock, [int] $Seconds=$script:ClcLimits.Seconds)
    if ($Clock.Elapsed.TotalSeconds -ge $Seconds) { Stop-ClcError Clc.UnsafeArchive }
}

function Read-ClcStream {
    param([IO.Stream] $Stream, [long] $Limit, [Diagnostics.Stopwatch] $Clock, [switch] $Capture, [IO.Stream] $Destination, [int] $Seconds=$script:ClcLimits.Seconds)
    Assert-ClcDeadline $Clock $Seconds
    $hash = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    $memory = $null
    if ($Capture) { $memory = [IO.MemoryStream]::new() }
    try {
        $buffer = [byte[]]::new(65536)
        $length = 0L
        while (($read = $Stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            Assert-ClcDeadline $Clock $Seconds
            $length += $read
            if ($length -gt $Limit) { Stop-ClcError Clc.UnsafeArchive }
            $hash.AppendData($buffer, 0, $read)
            if ($Capture) { $memory.Write($buffer, 0, $read) }
            if ($null -ne $Destination) { $Destination.Write($buffer, 0, $read) }
        }
        Assert-ClcDeadline $Clock $Seconds
        $result = @{ length = $length; sha256 = [Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant(); bytes = $null }
        if ($Capture) { $result.bytes = $memory.ToArray() }
        return $result
    } finally { $hash.Dispose(); if ($null -ne $memory) { $memory.Dispose() } }
}

function Assert-ClcPublishName {
    param([string] $RelativePath)
    Assert-ClcArchiveName ('application/' + $RelativePath) -PayloadOnly
    $parts = $RelativePath.Split('/')
    $leaf = $parts[-1]
    # Bounded shared exclusions; application content/semantic checks belong to its build.
    if ($parts -imatch '^(toolkit|deployment|deploy|keys|certificates|\.git|\.github|\.vs|obj|tests?|reports?)$' -or
        $leaf -imatch '^appsettings\.(Development|Testing|Test)\.json$' -or
        $leaf -imatch '^(launchSettings|operational-config|deployment|deployment-config|host-policy|release-approval|target)\.json$' -or
        $leaf -imatch '\.(ps1|psm1|psd1|cmd|bat|pfx|p12|pem|key|cer|crt|snk)$') { Stop-ClcError Clc.UnsafeArchive }
}

function Get-ClcPublishInventory {
    param($Root, [Collections.Generic.List[IDisposable]] $Handles, [Diagnostics.Stopwatch] $Clock,
        [AllowNull()][object[]] $ExpectedFiles=$null, $Context=$null, [string] $RuntimeSid, [string] $ControlRoot)
    $queue = [Collections.Generic.Queue[string]]::new()
    $queue.Enqueue($Root.CanonicalPath)
    $files = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $expectedDirectories=$null
    if ($null -ne $ExpectedFiles) {
        $expectedDirectories=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($file in $ExpectedFiles) { foreach ($prefix in Get-ClcNamePrefixes ($file.path.Substring(12))) { $null=$expectedDirectories.Add($prefix) } }
    }
    $entries = 0
    $total = 0L
    if ($null -ne $Context) {
        if ($ControlRoot -and (Test-ClcPathAncestry $ControlRoot $Root.CanonicalPath)) {
            Assert-ClcControlAncestorAccess $Context $ControlRoot $Root.CanonicalPath $RuntimeSid $Handles $Clock
        }
        $null=Get-ClcPathObservation $Root.CanonicalPath $Handles -Directory
        Assert-ClcPathAccess $Context $Root.CanonicalPath $RuntimeSid Mutable
    }
    while ($queue.Count -gt 0) {
        Assert-ClcDeadline $Clock
        $directory = $queue.Dequeue()
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($directory)) {
            Assert-ClcDeadline $Clock
            $entries++
            if ($entries -gt $script:ClcLimits.Entries) { Stop-ClcError Clc.UnsafeArchive }
            $relative = $entry.Substring($Root.CanonicalPath.Length + 1).Replace('\', '/')
            Assert-ClcPublishName $relative
            if (-not $seen.Add($relative)) { Stop-ClcError Clc.UnsafePath }
            $attributes = [IO.File]::GetAttributes($entry)
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Stop-ClcError Clc.UnsafePath }
            if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
                if ($null -ne $expectedDirectories -and -not $expectedDirectories.Contains($relative)) { Stop-ClcError Clc.ContentDrift }
                $null = Get-ClcPathObservation $entry $Handles -Directory
                if ($null -ne $Context) { Assert-ClcPathAccess $Context $entry $RuntimeSid Mutable }
                $queue.Enqueue($entry)
            } else {
                if ($files.Count + 1 -ge $script:ClcLimits.Entries) { Stop-ClcError Clc.UnsafeArchive }
                $facts = Get-ClcPathObservation $entry $Handles
                if ($null -ne $Context) { Assert-ClcPathAccess $Context $entry $RuntimeSid Mutable }
                $stream = Open-ClcReadFile $entry $facts $Handles
                $digest = Read-ClcStream $stream $script:ClcLimits.File $Clock
                $stream.Position = 0
                $total += $digest.length
                if ($total -gt $script:ClcLimits.Expanded) { Stop-ClcError Clc.UnsafeArchive }
                $files.Add(@{ path = 'application/' + $relative; length = $digest.length; sha256 = $digest.sha256; stream = $stream; facts = $facts })
            }
        }
    }
    $paths = [string[]] @($files | ForEach-Object { $_.path })
    [Array]::Sort($paths, [StringComparer]::Ordinal)
    $lookup = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($file in $files) { $lookup.Add($file.path, $file) }
    $ordered = [Collections.Generic.List[object]]::new()
    foreach ($path in $paths) { $ordered.Add($lookup[$path]) }
    return ,$ordered.ToArray()
}

function ConvertTo-ClcManifestBytes {
    param($Metadata, [object[]] $Files)
    $manifest = [ordered]@{ contractFamily = 'clc-file-iis-v1'; schemaVersion = 1; recordKind = 'release-manifest' }
    foreach ($key in @('applicationId','releaseId','source','build','builder','runtime','changeKind','validation','readinessContractVersion')) {
        $value = $Metadata[$key]
        # Normalize known nested property order, regardless of metadata input order.
        $nestedKeys = switch ($key) {
            source { @('repository','commit') }
            build { @('workflowPath','runId','runAttempt','job','sdkVersion','dependencyLockSha256') }
            builder { @('module','version','sourceCommit','distributionSha256') }
            runtime { @('framework','rid','architecture','hostingModel','workerLimit') }
            validation { @('contractVersion','entryPoint') }
        }
        if ($null -ne $nestedKeys) {
            $nested = [ordered]@{}
            foreach ($nestedKey in $nestedKeys) { $nested[$nestedKey] = $value[$nestedKey] }
            $value = $nested
        }
        $manifest[$key] = $value
    }
    $manifest.files = @($Files | ForEach-Object { [ordered]@{ path = $_.path; length = $_.length; sha256 = $_.sha256 } })
    $manifest.inventorySha256 = Get-ClcInventoryHash $Files
    return ,([Text.Encoding]::UTF8.GetBytes(($manifest | ConvertTo-Json -Depth 10 -Compress) + "`n"))
}

function Assert-ClcWebConfig {
    param([byte[]] $Bytes, [string] $EntryPoint)
    $reader = $null
    $memory = [IO.MemoryStream]::new($Bytes, $false)
    try {
        $settings = [Xml.XmlReaderSettings]::new()
        $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $settings.MaxCharactersInDocument = 4194304
        $reader = [Xml.XmlReader]::Create($memory, $settings)
        $xml = [Xml.XmlDocument]::new()
        $xml.XmlResolver = $null
        $xml.Load($reader)
        # Whitelist the standard framework-dependent ANCM tree and exact attributes.
        $configuration = $xml.get_DocumentElement()
        Assert-ClcXmlElement $configuration 'configuration' @{}
        $location = Get-ClcOnlyXmlChild $configuration 'location'
        Assert-ClcXmlElement $location 'location' @{ path = '.'; inheritInChildApplications = 'false' }
        $server = Get-ClcOnlyXmlChild $location 'system.webServer'
        Assert-ClcXmlElement $server 'system.webServer' @{}
        $children = @($server.get_ChildNodes() | Where-Object { $_ -is [Xml.XmlElement] })
        if ($children.Count -ne 2 -or $children[0].get_Name() -cne 'handlers' -or $children[1].get_Name() -cne 'aspNetCore') { Stop-ClcError Clc.UnsafeArchive }
        Assert-ClcXmlElement $children[0] 'handlers' @{}
        $handler = Get-ClcOnlyXmlChild $children[0] 'add'
        Assert-ClcXmlElement $handler 'add' @{ name = 'aspNetCore'; path = '*'; verb = '*'; modules = 'AspNetCoreModuleV2'; resourceType = 'Unspecified' }
        $launchAttributes = @{ processPath = 'dotnet'; arguments = '.\' + $EntryPoint; stdoutLogEnabled = 'false'; hostingModel = 'inprocess' }
        if ($children[1].HasAttribute('stdoutLogFile')) { $launchAttributes.stdoutLogFile = '.\logs\stdout' }
        Assert-ClcXmlElement $children[1] 'aspNetCore' $launchAttributes
        foreach ($leaf in @($handler, $children[1])) {
            if (@($leaf.get_ChildNodes() | Where-Object { $_ -is [Xml.XmlElement] }).Count -ne 0) { Stop-ClcError Clc.UnsafeArchive }
        }
    } catch {
        if ($_.FullyQualifiedErrorId -like 'Clc.*') { throw }
        Stop-ClcError Clc.UnsafeArchive
    } finally { if ($null -ne $reader) { $reader.Dispose() }; $memory.Dispose() }
}

function Assert-ClcXmlElement {
    param([Xml.XmlElement] $Element, [string] $Name, [hashtable] $Attributes)
    if ($null -eq $Element -or $Element.get_Name() -cne $Name -or $Element.get_NamespaceURI() -or $Element.get_Attributes().Count -ne $Attributes.Count) { Stop-ClcError Clc.UnsafeArchive }
    foreach ($key in $Attributes.Keys) { if ($Element.GetAttribute($key) -cne $Attributes[$key]) { Stop-ClcError Clc.UnsafeArchive } }
    foreach ($child in $Element.get_ChildNodes()) {
        if ($child -isnot [Xml.XmlElement] -and $child -isnot [Xml.XmlWhitespace] -and $child -isnot [Xml.XmlComment]) { Stop-ClcError Clc.UnsafeArchive }
    }
}
function Get-ClcOnlyXmlChild {
    param([Xml.XmlElement] $Element, [string] $Name)
    $children = @($Element.get_ChildNodes() | Where-Object { $_ -is [Xml.XmlElement] })
    if ($children.Count -ne 1 -or $children[0].get_Name() -cne $Name) { Stop-ClcError Clc.UnsafeArchive }
    return $children[0]
}

function Assert-ClcRuntimeConfig {
    param([byte[]] $Bytes, [string] $Framework)
    # Runtimeconfig is application configuration, not a persistent toolkit record.
    # Parse duplicates strictly, then observe only the framework-dependent launch facts.
    $document = $null
    try {
        if ($Bytes.Length -gt $script:ClcLimits.Json) { Stop-ClcError Clc.UnsafeArchive }
        $document = [Text.Json.JsonDocument]::Parse([Text.UTF8Encoding]::new($false,$true).GetString($Bytes))
        $value = ConvertFrom-ClcJsonElement $document.RootElement
        if ($value -isnot [Collections.IDictionary] -or -not $value.Contains('runtimeOptions')) { Stop-ClcError Clc.UnsafeArchive }
        $options = $value.runtimeOptions
        if ($options -isnot [Collections.IDictionary] -or -not $options.Contains('tfm') -or $options.tfm -cne $Framework -or
            $options.Contains('includedFrameworks')) { Stop-ClcError Clc.UnsafeArchive }
        $frameworks = @()
        if ($options.Contains('framework')) { $frameworks += $options.framework }
        if ($options.Contains('frameworks')) { $frameworks += $options.frameworks }
        if ($frameworks.Count -eq 0 -or ($options.Contains('framework') -and $options.Contains('frameworks'))) { Stop-ClcError Clc.UnsafeArchive }
        foreach ($item in $frameworks) {
            Assert-ClcObject $item @('name','version')
            Assert-ClcEnum $item.name @('Microsoft.NETCore.App','Microsoft.AspNetCore.App')
            Assert-ClcVersion $item.version
            if (-not $Framework.Substring(3).Equals(($item.version -split '\.')[0..1] -join '.', [StringComparison]::Ordinal)) { Stop-ClcError Clc.UnsafeArchive }
        }
    } catch {
        if ($_.FullyQualifiedErrorId -like 'Clc.*') { throw }
        Stop-ClcError Clc.UnsafeArchive
    } finally { if ($null -ne $document) { $document.Dispose() } }
}

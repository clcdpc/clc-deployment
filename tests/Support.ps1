Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:RepositoryRoot = Split-Path $PSScriptRoot -Parent
$script:ModulePath = Join-Path $script:RepositoryRoot 'src/CLC.Deployment/CLC.Deployment.psd1'
$script:FixtureRoot = Join-Path $PSScriptRoot 'Fixtures'
Import-Module $script:ModulePath -Force

function New-TestWorkspace {
    $path = Join-Path ([IO.Path]::GetTempPath()) ('clc-' + [guid]::NewGuid().ToString('N'))
    [void] [IO.Directory]::CreateDirectory($path)
    return $path
}
function Remove-TestWorkspace {
    param([string] $Path)
    $resolved = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($resolved) -cne $parent -or [IO.Path]::GetFileName($resolved) -cnotmatch '^clc-[a-f0-9]{32}$') { throw 'Unsafe fixture cleanup.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
function Get-TestMetadata {
    return Get-Content -LiteralPath (Join-Path $script:FixtureRoot 'release-metadata.json') -Raw | ConvertFrom-Json -AsHashtable
}
function Write-TestJson {
    param([string] $Path, $Value)
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 32 -Compress), [Text.UTF8Encoding]::new($false))
}
function Get-TestWebConfig {
    return '<configuration><location path="." inheritInChildApplications="false"><system.webServer><handlers><add name="aspNetCore" path="*" verb="*" modules="AspNetCoreModuleV2" resourceType="Unspecified" /></handlers><aspNetCore processPath="dotnet" arguments=".\Probe.dll" stdoutLogEnabled="false" hostingModel="inprocess" /></system.webServer></location></configuration>'
}
function New-TestPublish {
    param([string] $Workspace)
    $publish = Join-Path $Workspace 'publish'
    $inputRoot = Join-Path $Workspace 'input'
    $output = Join-Path $Workspace 'output'
    foreach ($path in @($publish,$inputRoot,$output)) { [void] [IO.Directory]::CreateDirectory($path) }
    [IO.File]::WriteAllText((Join-Path $publish 'web.config'), (Get-TestWebConfig), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $publish 'Probe.runtimeconfig.json'), '{"runtimeOptions":{"tfm":"net10.0","framework":{"name":"Microsoft.AspNetCore.App","version":"10.0.0"}}}', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $publish 'Probe.dll'), 'synthetic fixture bytes; never executable', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllBytes((Join-Path $publish 'empty.txt'), [byte[]]::new(0))
    $metadata = Join-Path $inputRoot 'metadata.json'
    Write-TestJson $metadata (Get-TestMetadata)
    return @{ PublishRoot=$publish; MetadataPath=$metadata; OutputPath=(Join-Path $output 'release.zip') }
}
function Get-TestTreeHashes {
    param([string] $Root)
    $hashes = [ordered]@{}
    foreach ($file in Get-ChildItem -LiteralPath $Root -File -Recurse) {
        $hashes[$file.FullName.Substring($Root.Length)] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    return $hashes | ConvertTo-Json -Compress
}
function Get-TestZipEntries {
    param([string] $Path)
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entries = [Collections.Generic.List[object]]::new()
        foreach ($entry in $zip.Entries) {
            $stream = $entry.Open()
            $memory = [IO.MemoryStream]::new()
            try { $stream.CopyTo($memory); $entries.Add(@{ name=$entry.FullName; bytes=$memory.ToArray(); attributes=0 }) }
            finally { $stream.Dispose(); $memory.Dispose() }
        }
        return $entries.ToArray()
    } finally { $zip.Dispose() }
}
function New-TestZip {
    param([string] $Path, [object[]] $Entries, [IO.Compression.CompressionLevel] $Compression = [IO.Compression.CompressionLevel]::NoCompression)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            foreach ($item in $Entries) {
                $entry = $zip.CreateEntry($item.name, $Compression)
                $entry.LastWriteTime = [DateTimeOffset]::new(1980,1,1,0,0,0,[TimeSpan]::Zero)
                if ($item.ContainsKey('attributes')) { $entry.ExternalAttributes = [int] $item.attributes }
                $destination = $entry.Open()
                try { if ($item.bytes.Length -gt 0) { $destination.Write($item.bytes,0,$item.bytes.Length) } } finally { $destination.Dispose() }
            }
        } finally { $zip.Dispose() }
    } finally { $stream.Dispose() }
}
function Get-TestZipLayout {
    param([byte[]] $Bytes)
    $end = $Bytes.Length - 22
    $central = [BitConverter]::ToUInt32($Bytes,$end + 16)
    $positions = [Collections.Generic.List[int]]::new()
    $position = [int] $central
    for ($i = 0; $i -lt [BitConverter]::ToUInt16($Bytes,$end+10); $i++) {
        $positions.Add($position)
        $position += 46 + [BitConverter]::ToUInt16($Bytes,$position+28) + [BitConverter]::ToUInt16($Bytes,$position+30) + [BitConverter]::ToUInt16($Bytes,$position+32)
    }
    return @{ end=$end; central=[int]$central; positions=$positions.ToArray() }
}
function Set-TestUInt16 { param([byte[]] $Bytes,[int] $Offset,[uint16] $Value) [BitConverter]::GetBytes($Value).CopyTo($Bytes,$Offset) }
function Set-TestUInt32 { param([byte[]] $Bytes,[int] $Offset,[uint32] $Value) [BitConverter]::GetBytes($Value).CopyTo($Bytes,$Offset) }
function Test-TestRejection {
    param([scriptblock] $Action, [string] $Code = 'Clc.*')
    try { & $Action | Out-Null } catch { $_.FullyQualifiedErrorId | Should -BeLike $Code; return }
    throw 'Expected terminating rejection.'
}
function Invoke-TestRecord {
    param([byte[]] $Bytes, [string] $Kind)
    return & (Get-Module CLC.Deployment) { param($Data,$RecordKind) Read-ClcJson $Data $RecordKind } $Bytes $Kind
}

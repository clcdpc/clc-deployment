# Classic single-disk ZIP structure is checked independently of ZipArchive's permissive reader.
if ($null -eq ('Clc.Foundation.ZipEntryInput' -as [type])) {
    # This small ZIP-specific stream gives DeflateStream one byte at a time so it
    # cannot buffer past an end marker and hide trailing compressed bytes. An EOF
    # before that marker throws; ordinary DeflateStream can silently accept it.
    Add-Type -TypeDefinition @'
using System;
using System.IO;
namespace Clc.Foundation {
    public sealed class ZipEntryInput : Stream {
        private readonly Stream file;
        private readonly long count;
        public long Consumed { get; private set; }
        public ZipEntryInput(Stream file, long start, long count) { this.file=file; this.count=count; file.Position=start; }
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => count;
        public override long Position { get => Consumed; set => throw new NotSupportedException(); }
        public override int Read(byte[] buffer,int offset,int length) {
            if (length == 0) return 0;
            if (Consumed == count) throw new EndOfStreamException("Incomplete ZIP deflate stream.");
            int read=file.Read(buffer,offset,1);
            if (read != 1) throw new EndOfStreamException("Truncated ZIP entry.");
            Consumed += read;
            return read;
        }
        public override void Flush() {}
        public override long Seek(long offset,SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long length) => throw new NotSupportedException();
        public override void Write(byte[] buffer,int offset,int length) => throw new NotSupportedException();
    }
}
'@
}
$script:ClcCrcTable = [uint32[]]::new(256)
for ($i = 0; $i -lt 256; $i++) {
    $crc = [uint32] $i
    for ($bit = 0; $bit -lt 8; $bit++) {
        if ($crc -band 1) { $crc = ($crc -shr 1) -bxor [uint32]3988292384 } else { $crc = $crc -shr 1 }
    }
    $script:ClcCrcTable[$i] = $crc
}

function Read-ClcExactBytes {
    param([IO.BinaryReader] $Reader, [int] $Count)
    $bytes = $Reader.ReadBytes($Count)
    if ($bytes.Length -ne $Count) { Stop-ClcError Clc.UnsafeArchive }
    return ,$bytes
}

function Assert-ClcZipExtra {
    param([byte[]] $Bytes)
    $offset = 0
    $seen = [Collections.Generic.HashSet[int]]::new()
    while ($offset -lt $Bytes.Length) {
        if ($offset + 4 -gt $Bytes.Length) { Stop-ClcError Clc.UnsafeArchive }
        $id = [BitConverter]::ToUInt16($Bytes, $offset)
        $size = [BitConverter]::ToUInt16($Bytes, $offset + 2)
        $offset += 4
        # ZIP64, alternate Unicode names, strong encryption and AES are unsupported.
        if (-not $seen.Add($id) -or $id -in @(0x0001,0x7075,0x6375,0x0017,0x9901) -or $offset + $size -gt $Bytes.Length) { Stop-ClcError Clc.UnsafeArchive }
        $offset += $size
    }
}

function Get-ClcRawZipEntries {
    param([IO.Stream] $Stream, [Diagnostics.Stopwatch] $Clock)
    if ($Stream.Length -lt 22 -or $Stream.Length -gt $script:ClcLimits.Compressed) { Stop-ClcError Clc.UnsafeArchive }
    $reader = [IO.BinaryReader]::new($Stream, [Text.Encoding]::UTF8, $true)
    try {
        $tailSize = [int] [Math]::Min(65557, $Stream.Length)
        $Stream.Position = $Stream.Length - $tailSize
        $tail = Read-ClcExactBytes $reader $tailSize
        $end = -1
        for ($offset = $tailSize - 22; $offset -ge 0; $offset--) {
            if ([BitConverter]::ToUInt32($tail, $offset) -eq 0x06054b50 -and
                $offset + 22 + [BitConverter]::ToUInt16($tail, $offset + 20) -eq $tailSize) { $end = $offset; break }
        }
        if ($end -lt 0 -or [BitConverter]::ToUInt16($tail, $end + 4) -ne 0 -or [BitConverter]::ToUInt16($tail, $end + 6) -ne 0) { Stop-ClcError Clc.UnsafeArchive }
        $count = [BitConverter]::ToUInt16($tail, $end + 10)
        $centralSize = [long] [BitConverter]::ToUInt32($tail, $end + 12)
        $centralOffset = [long] [BitConverter]::ToUInt32($tail, $end + 16)
        if ($count -eq 0 -or $count -gt $script:ClcLimits.Entries -or $count -ne [BitConverter]::ToUInt16($tail, $end + 8) -or
            $centralOffset + $centralSize -ne $Stream.Length - $tailSize + $end) { Stop-ClcError Clc.UnsafeArchive }
        $Stream.Position = $centralOffset
        $entries = [Collections.Generic.List[object]]::new()
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $total = 0L
        for ($i = 0; $i -lt $count; $i++) {
            Assert-ClcDeadline $Clock
            $header = Read-ClcExactBytes $reader 46
            if ([BitConverter]::ToUInt32($header,0) -ne 0x02014b50) { Stop-ClcError Clc.UnsafeArchive }
            $needed = [BitConverter]::ToUInt16($header,6)
            $flags = [BitConverter]::ToUInt16($header,8)
            $method = [BitConverter]::ToUInt16($header,10)
            $compressed = [long] [BitConverter]::ToUInt32($header,20)
            $expanded = [long] [BitConverter]::ToUInt32($header,24)
            $nameLength = [BitConverter]::ToUInt16($header,28)
            $extraLength = [BitConverter]::ToUInt16($header,30)
            $commentLength = [BitConverter]::ToUInt16($header,32)
            $attributes = [BitConverter]::ToUInt32($header,38)
            $localOffset = [long] [BitConverter]::ToUInt32($header,42)
            if ($needed -gt 20 -or ($flags -band 0xf7f7) -ne 0 -or $method -notin @(0,8) -or
                [BitConverter]::ToUInt16($header,34) -ne 0 -or $localOffset -ge $centralOffset -or
                $expanded -gt $script:ClcLimits.File -or $compressed -gt $script:ClcLimits.Compressed -or
                ($expanded -gt 0 -and ($compressed -eq 0 -or $expanded -gt $compressed * $script:ClcLimits.Ratio)) -or
                ($method -eq 0 -and $compressed -ne $expanded)) { Stop-ClcError Clc.UnsafeArchive }
            $nameBytes = Read-ClcExactBytes $reader $nameLength
            if (@($nameBytes | Where-Object { $_ -gt 127 }).Count -gt 0) { Stop-ClcError Clc.UnsafeArchive }
            $name = [Text.Encoding]::ASCII.GetString($nameBytes)
            $isDirectory = $name.EndsWith('/')
            Assert-ClcArchiveName $name -Directory:$isDirectory
            $mode = ($attributes -shr 16) -band 0xf000
            if (($attributes -band 0x400) -ne 0 -or $mode -notin @(0,0x8000,0x4000) -or
                ($mode -eq 0x4000 -and -not $isDirectory) -or ($mode -eq 0x8000 -and $isDirectory) -or
                (($attributes -band 0x10) -ne 0 -and -not $isDirectory) -or
                ($isDirectory -and ($expanded -ne 0 -or $compressed -ne 0 -or $method -ne 0 -or [BitConverter]::ToUInt32($header,16) -ne 0))) { Stop-ClcError Clc.UnsafeArchive }
            if (-not $seen.Add($name.TrimEnd('/'))) { Stop-ClcError Clc.UnsafeArchive }
            Assert-ClcZipExtra (Read-ClcExactBytes $reader $extraLength)
            $null = Read-ClcExactBytes $reader $commentLength
            $total += $expanded
            if ($total -gt $script:ClcLimits.Expanded) { Stop-ClcError Clc.UnsafeArchive }
            $entries.Add(@{ name=$name; nameBytes=$nameBytes; directory=$isDirectory; needed=$needed; flags=$flags; method=$method;
                crc=[BitConverter]::ToUInt32($header,16); compressed=$compressed; length=$expanded; localOffset=$localOffset;
                time=[BitConverter]::ToUInt16($header,12); date=[BitConverter]::ToUInt16($header,14) })
        }
        if ($Stream.Position -ne $centralOffset + $centralSize) { Stop-ClcError Clc.UnsafeArchive }
        $files = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $entries) { if (-not $entry.directory) { $null = $files.Add($entry.name) } }
        foreach ($entry in $entries) {
            foreach ($prefix in (Get-ClcNamePrefixes $entry.name.TrimEnd('/'))) {
                if ($files.Contains($prefix)) { Stop-ClcError Clc.UnsafeArchive }
            }
            if ($entry.directory) {
                if (-not (@($files | Where-Object { $_.StartsWith($entry.name, [StringComparison]::Ordinal) }).Count -gt 0)) { Stop-ClcError Clc.UnsafeArchive }
            } elseif ($entry.name -cne 'manifest.json') {
                Assert-ClcArchiveName $entry.name -PayloadOnly
                Assert-ClcPublishName $entry.name.Substring(12)
            }
        }
        if (-not $files.Contains('manifest.json') -or -not (@($entries | Where-Object { $_.name -ceq 'manifest.json' }).Count -eq 1)) { Stop-ClcError Clc.UnsafeArchive }
        # No preamble, overlapping local extents, orphan local records, or unaccounted gaps.
        $position = 0L
        foreach ($entry in ($entries | Sort-Object localOffset)) {
            Assert-ClcDeadline $Clock
            if ($entry.localOffset -ne $position) { Stop-ClcError Clc.UnsafeArchive }
            $Stream.Position = $position
            $header = Read-ClcExactBytes $reader 30
            if ([BitConverter]::ToUInt32($header,0) -ne 0x04034b50 -or
                [BitConverter]::ToUInt16($header,4) -ne $entry.needed -or [BitConverter]::ToUInt16($header,6) -ne $entry.flags -or
                [BitConverter]::ToUInt16($header,8) -ne $entry.method -or [BitConverter]::ToUInt16($header,10) -ne $entry.time -or
                [BitConverter]::ToUInt16($header,12) -ne $entry.date) { Stop-ClcError Clc.UnsafeArchive }
            $localCrc = [BitConverter]::ToUInt32($header,14)
            $localCompressed = [BitConverter]::ToUInt32($header,18)
            $localLength = [BitConverter]::ToUInt32($header,22)
            if (($entry.flags -band 8) -eq 0) {
                if ($localCrc -ne $entry.crc -or $localCompressed -ne $entry.compressed -or $localLength -ne $entry.length) { Stop-ClcError Clc.UnsafeArchive }
            } elseif ($localCrc -ne 0 -or $localCompressed -ne 0 -or $localLength -ne 0) { Stop-ClcError Clc.UnsafeArchive }
            $localName = Read-ClcExactBytes $reader ([BitConverter]::ToUInt16($header,26))
            if ([Convert]::ToHexString($localName) -cne [Convert]::ToHexString($entry.nameBytes)) { Stop-ClcError Clc.UnsafeArchive }
            Assert-ClcZipExtra (Read-ClcExactBytes $reader ([BitConverter]::ToUInt16($header,28)))
            $entry.dataOffset = $Stream.Position
            $position = $Stream.Position + $entry.compressed
            if ($position -gt $centralOffset) { Stop-ClcError Clc.UnsafeArchive }
            if (($entry.flags -band 8) -ne 0) {
                $Stream.Position = $position
                $crc = $reader.ReadUInt32()
                if ($crc -eq 0x08074b50) { $crc = $reader.ReadUInt32() }
                if ($crc -ne $entry.crc -or $reader.ReadUInt32() -ne $entry.compressed -or $reader.ReadUInt32() -ne $entry.length) { Stop-ClcError Clc.UnsafeArchive }
                $position = $Stream.Position
            }
        }
        if ($position -ne $centralOffset) { Stop-ClcError Clc.UnsafeArchive }
        return ,$entries.ToArray()
    } finally { $reader.Dispose() }
}

function Read-ClcZipPayload {
    param([IO.Stream] $Stream, [long] $Limit, [Diagnostics.Stopwatch] $Clock, [switch] $Capture)
    $hash = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    $memory = $null
    if ($Capture) { $memory = [IO.MemoryStream]::new() }
    try {
        $buffer = [byte[]]::new(65536)
        $length = 0L
        $crc = [uint32]::MaxValue
        while (($read = $Stream.Read($buffer,0,$buffer.Length)) -gt 0) {
            Assert-ClcDeadline $Clock
            $length += $read
            if ($length -gt $Limit) { Stop-ClcError Clc.UnsafeArchive }
            $hash.AppendData($buffer,0,$read)
            for ($i = 0; $i -lt $read; $i++) { $crc = ($crc -shr 8) -bxor $script:ClcCrcTable[($crc -bxor $buffer[$i]) -band 255] }
            if ($Capture) { $memory.Write($buffer,0,$read) }
        }
        Assert-ClcDeadline $Clock
        $result = @{ length=$length; sha256=[Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant(); crc=$crc -bxor [uint32]::MaxValue; bytes=$null }
        if ($Capture) { $result.bytes = $memory.ToArray() }
        return $result
    } finally { $hash.Dispose(); if ($null -ne $memory) { $memory.Dispose() } }
}

function Test-ClcArchiveStream {
    param([IO.Stream] $Stream, [Diagnostics.Stopwatch] $Clock)
    $raw = Get-ClcRawZipEntries $Stream $Clock
    $Stream.Position = 0
    $archiveDigest = Read-ClcStream $Stream $script:ClcLimits.Compressed $Clock
    $Stream.Position = 0
    $zip = [IO.Compression.ZipArchive]::new($Stream, [IO.Compression.ZipArchiveMode]::Read, $true)
    try {
        if ($zip.Entries.Count -ne $raw.Count) { Stop-ClcError Clc.UnsafeArchive }
        $manifestBytes = $null
        $payload = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        $captured = [Collections.Generic.Dictionary[string,byte[]]]::new([StringComparer]::Ordinal)
        $expanded = 0L
        for ($i = 0; $i -lt $raw.Count; $i++) {
            Assert-ClcDeadline $Clock
            $entry = $zip.Entries[$i]
            $facts = $raw[$i]
            if ($entry.FullName -cne $facts.name -or $entry.Length -ne $facts.length -or $entry.CompressedLength -ne $facts.compressed) { Stop-ClcError Clc.UnsafeArchive }
            if ($facts.directory) { continue }
            $capture = $facts.name -ceq 'manifest.json' -or $facts.name -ceq 'application/web.config' -or
                $facts.name -cmatch '^application/[A-Za-z0-9_.-]+\.runtimeconfig\.json$'
            $limit = [Math]::Min($facts.length, $script:ClcLimits.File)
            if ($capture) { $limit = [Math]::Min($limit, $script:ClcLimits.Json) }
            $window = $null
            if ($facts.method -eq 8) {
                $window = [Clc.Foundation.ZipEntryInput]::new($Stream,$facts.dataOffset,$facts.compressed)
                $input = [IO.Compression.DeflateStream]::new($window,[IO.Compression.CompressionMode]::Decompress,$true)
            } else { $input = $entry.Open() }
            try {
                $digest = Read-ClcZipPayload $input $limit $Clock -Capture:$capture
                if ($null -ne $window -and $window.Consumed -ne $facts.compressed) { Stop-ClcError Clc.UnsafeArchive }
            } finally { $input.Dispose(); if ($null -ne $window) { $window.Dispose() } }
            if ($digest.length -ne $facts.length -or $digest.crc -ne $facts.crc) { Stop-ClcError Clc.UnsafeArchive }
            $expanded += $digest.length
            if ($expanded -gt $script:ClcLimits.Expanded) { Stop-ClcError Clc.UnsafeArchive }
            if ($facts.name -ceq 'manifest.json') { $manifestBytes = $digest.bytes }
            else {
                $payload.Add($facts.name, @{ path=$facts.name; length=$digest.length; sha256=$digest.sha256 })
                if ($capture) { $captured.Add($facts.name, $digest.bytes) }
            }
        }
        $manifest = Read-ClcJson $manifestBytes 'release-manifest' ([int] $script:ClcLimits.Json)
        if ($manifest.files.Count -ne $payload.Count) { Stop-ClcError Clc.HashMismatch }
        $total = 0L
        foreach ($file in $manifest.files) {
            if (-not $payload.ContainsKey($file.path) -or $payload[$file.path].length -ne $file.length -or $payload[$file.path].sha256 -cne $file.sha256) { Stop-ClcError Clc.HashMismatch }
            $total += $file.length
        }
        $runtimeName = 'application/' + [IO.Path]::GetFileNameWithoutExtension($manifest.validation.entryPoint) + '.runtimeconfig.json'
        if (-not $captured.ContainsKey('application/web.config') -or -not $captured.ContainsKey($runtimeName)) { Stop-ClcError Clc.UnsafeArchive }
        Assert-ClcWebConfig $captured['application/web.config'] $manifest.validation.entryPoint
        Assert-ClcRuntimeConfig $captured[$runtimeName] $manifest.runtime.framework
        return [pscustomobject][ordered]@{
            contractFamily='clc-file-iis-v1'; packageContractVersion=1; integrityVerified=$true; authorizedForDeployment=$false;
            applicationId=$manifest.applicationId; releaseId=$manifest.releaseId; sourceCommit=$manifest.source.commit;
            archiveSha256=$archiveDigest.sha256; manifestSha256=(Get-ClcBytesHash $manifestBytes); inventorySha256=$manifest.inventorySha256;
            fileCount=$payload.Count; totalBytes=$total; builderVersion=$manifest.builder.version
        }
    } finally { $zip.Dispose() }
}

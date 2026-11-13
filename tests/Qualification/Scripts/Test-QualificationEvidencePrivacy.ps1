[CmdletBinding()]
param([Parameter(Mandatory)][string] $EvidenceRoot,[Parameter(Mandatory)][string] $OperationalConfigurationPath)
. "$PSScriptRoot/Qualification.Common.ps1"
$null=Get-DistPathFacts $EvidenceRoot -Directory
$bytes=Read-DistFileBytes $OperationalConfigurationPath 16384; $config=Read-DistJson $bytes
$sentinels=@([string]$config.syntheticSecret,(Get-DistHash $bytes))
$patterns=[Collections.Generic.List[byte[]]]::new()
foreach ($sentinel in $sentinels) {
    if ($sentinel.Length -eq 0) { continue }
    foreach ($encoding in @([Text.Encoding]::UTF8,[Text.Encoding]::Unicode,[Text.Encoding]::BigEndianUnicode)) { $patterns.Add($encoding.GetBytes($sentinel)) }
}
$queue=[Collections.Generic.Queue[string]]::new(); $queue.Enqueue($EvidenceRoot); $count=0; $found=$false; $clock=[Diagnostics.Stopwatch]::StartNew(); $total=0L
while ($queue.Count) {
    foreach ($path in [IO.Directory]::EnumerateFileSystemEntries($queue.Dequeue())) {
        $count++; if ($count -gt 20000) { throw 'Evidence scan exceeds its bound.' }
        $directory=([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::Directory) -ne 0
        $null=Get-DistPathFacts $path -Directory:$directory
        if ($directory) { $queue.Enqueue($path); continue }
        if ([IO.Path]::GetExtension($path) -in @('.zip','.gz','.7z','.rar','.cab','.bz2','.bz','.xz','.lz4','.zst','.tgz','.tbz2','.txz','.br','.deflate','.zlib')) { throw 'Compressed evidence requires separately reviewed expansion and scanning; it cannot be declared clean from raw container bytes.' }
        $stream=[IO.FileStream]::new($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try {
            $header=[byte[]]::new(8); $headerLength=$stream.Read($header,0,$header.Length); $stream.Position=0
            $magic=[Convert]::ToHexString($header,0,$headerLength)
            if ($magic -match '^(504B0304|504B0506|504B0708|1F8B|377ABCAF271C|526172211A07|4D534346|28B52FFD|425A68|FD377A585A00|04224D18)' -or
                ($headerLength -ge 2 -and ($header[0] -band 15) -eq 8 -and (([int]$header[0]*256+[int]$header[1]) % 31) -eq 0)) { throw 'Compressed evidence requires separately reviewed expansion and scanning, including renamed containers.' }
            $total+=$stream.Length
            if ($stream.Length -gt 1073741824 -or $total -gt 4294967296) { throw 'Evidence exceeds its bounded privacy scan size.' }
            if ([Clc.Distribution.Capture]::ContainsAny($stream,$patterns.ToArray(),1073741824,$clock)) { $found=$true }
        } finally { $stream.Dispose() }
    }
}
if ($found) { throw 'Qualification.PrivacyViolation: protected sentinel or private configuration digest found; quarantine evidence without printing it.' }
[pscustomobject]@{privacyScanPassed=$true;filesObserved=$count;bytesObserved=$total;encodings=@('UTF-8','UTF-16LE','UTF-16BE');secretValuesPrinted=$false}

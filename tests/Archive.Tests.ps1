BeforeAll {
    . "$PSScriptRoot/Support.ps1"
    $seedWorkspace = New-TestWorkspace
    $publishArgs = New-TestPublish $seedWorkspace
    $seed = New-ClcRelease @publishArgs
    $seedEntries = @(Get-TestZipEntries $seed.archivePath)
    $seedBytes = [IO.File]::ReadAllBytes($seed.archivePath)
}
AfterAll { Remove-TestWorkspace $seedWorkspace }
Describe 'Complete raw ZIP validation without extraction' {
    BeforeEach {
        $workspace = New-TestWorkspace
        $archivePath = Join-Path $workspace 'candidate.zip'
        $sentinel = Join-Path $workspace 'sentinel.txt'
        [IO.File]::WriteAllText($sentinel,'filesystem-sentinel')
    }
    AfterEach {
        [IO.File]::ReadAllText($sentinel) | Should -Be 'filesystem-sentinel'
        @(Get-ChildItem -LiteralPath $workspace -Force).Count | Should -Be 2
        Remove-TestWorkspace $workspace
    }
    It 'accepts valid stored/deflated files and canonical directory prefixes' -ForEach @(
        @{Compression=[IO.Compression.CompressionLevel]::NoCompression},@{Compression=[IO.Compression.CompressionLevel]::Optimal}
    ) {
        $entries = @(@{name='application/';bytes=[byte[]]::new(0);attributes=16}) + $seedEntries
        New-TestZip $archivePath $entries $Compression
        $inspection = Test-ClcRelease $archivePath
        $inspection.integrityVerified | Should -BeTrue
        $inspection.authorizedForDeployment | Should -BeFalse
        $inspection.fileCount | Should -Be 4
    }
    It 'rejects malicious names <Name>' -ForEach @(
        @{Name='../escape.txt'},@{Name='/absolute.txt'},@{Name='//server/share.txt'},@{Name='C:/drive.txt'},
        @{Name='\\?\C:\device.txt'},@{Name='application\backslash.txt'},@{Name='application/name:stream'},
        @{Name='application/CON'},@{Name='application/NUL.txt'},@{Name='application/com1.dll'},@{Name='application/LPT9.txt'},
        @{Name='application/trailing.'},@{Name='application/trailing '},@{Name='application/./dot.txt'},
        @{Name='application/../parent.txt'},@{Name='application//empty.txt'},@{Name='application/café.txt'},
        @{Name='application/.clc-temporary'},@{Name='application/' + [char]0 + 'nul.txt'},@{Name='application/' + [char]10 + 'control.txt'},
        @{Name='application/' + ('a'*229)},@{Name='application/deployment/adapter.dll'},@{Name='application/appsettings.Development.json'},
        @{Name='application/toolkit/CLC.Deployment.dll'},@{Name='application/adapter.ps1'}
    ) {
        New-TestZip $archivePath ($seedEntries + @{name=$Name;bytes=[byte[]](1);attributes=0})
        Test-TestRejection { Test-ClcRelease $archivePath }
    }
    It 'rejects duplicate/case collisions, file-directory conflicts and empty unrelated trees' -ForEach @(
        @{Name='application/Probe.dll'},@{Name='application/probe.DLL'},@{Name='application/Probe.dll/child'},
        @{Name='application/empty.txt/'},@{Name='application/unrelated/'},@{Name='application/../unsafe/'}
    ) {
        $bytes = [byte[]](1)
        if ($Name.EndsWith('/')) { $bytes = [byte[]]::new(0) }
        New-TestZip $archivePath ($seedEntries + @{name=$Name;bytes=$bytes;attributes=0})
        Test-TestRejection { Test-ClcRelease $archivePath } 'Clc.UnsafeArchive*'
    }
    It 'rejects symlink, reparse, special file and inconsistent directory attributes' -ForEach @(
        @{Attributes=-1610612736},@{Attributes=1024},@{Attributes=268435456},@{Attributes=16},@{Attributes=1073741824}
    ) {
        $entries = @($seedEntries | ForEach-Object { $_.Clone() })
        $entries[1].attributes = $Attributes
        New-TestZip $archivePath $entries
        Test-TestRejection { Test-ClcRelease $archivePath } 'Clc.UnsafeArchive*'
    }
    It 'rejects missing, extra, altered and forged manifest payloads' -ForEach @(
        @{Mode='missing'},@{Mode='extra'},@{Mode='altered'},@{Mode='inventory'},@{Mode='length'},@{Mode='file hash'},@{Mode='family'},@{Mode='legacy receipt'},@{Mode='unknown manifest'}
    ) {
        $entries = @($seedEntries | ForEach-Object { $_.Clone() })
        $manifest = [Text.Encoding]::UTF8.GetString($entries[0].bytes) | ConvertFrom-Json -AsHashtable
        switch ($Mode) {
            missing { $entries = @($entries | Where-Object { $_.name -cne 'application/Probe.dll' }) }
            extra { $entries += @{name='application/unexpected.txt';bytes=[byte[]](1);attributes=0} }
            altered { $entries[1].bytes = [Text.Encoding]::UTF8.GetBytes('altered fixture') }
            inventory { $manifest.inventorySha256 = '0'*64 }
            length { $manifest.files[0].length++ }
            'file hash' { $manifest.files[0].sha256 = '0'*64 }
            family { $manifest.contractFamily = 'blueprint-v1' }
            'legacy receipt' { $manifest.recordKind = 'receipt' }
            'unknown manifest' { $manifest.approved = $true }
        }
        if ($Mode -notin @('missing','extra','altered')) { $entries[0].bytes = [Text.Encoding]::UTF8.GetBytes(($manifest | ConvertTo-Json -Depth 10 -Compress)) }
        New-TestZip $archivePath $entries
        Test-TestRejection { Test-ClcRelease $archivePath }
    }
    It 'rejects a strong-name key even when all declared hashes are rebuilt consistently' {
        $entries = @($seedEntries | ForEach-Object { $_.Clone() })
        $key = @{name='application/private.snk';bytes=[Text.Encoding]::UTF8.GetBytes('synthetic-private-key-sentinel');attributes=0}
        $manifest = [Text.Encoding]::UTF8.GetString($entries[0].bytes) | ConvertFrom-Json -AsHashtable
        $manifest.files += @{path=$key.name;length=$key.bytes.Length;sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($key.bytes)).ToLowerInvariant()}
        $paths = [string[]]@($manifest.files | ForEach-Object { $_.path })
        [Array]::Sort($paths,[StringComparer]::Ordinal)
        $manifest.files = @($paths | ForEach-Object { $path = $_; $manifest.files | Where-Object { $_.path -ceq $path } })
        $manifest.inventorySha256 = & (Get-Module CLC.Deployment) { param($Files) Get-ClcInventoryHash $Files } $manifest.files
        $entries[0].bytes = [Text.Encoding]::UTF8.GetBytes(($manifest | ConvertTo-Json -Depth 10 -Compress))
        New-TestZip $archivePath ($entries + $key)
        Test-TestRejection { Test-ClcRelease $archivePath } 'Clc.UnsafeArchive*'
    }
    It 'rejects structurally unsafe web.config even with consistent inventory: <Label>' -ForEach @(
        @{ Label='malformed'; Xml='<configuration>' },
        @{ Label='DTD/entity'; Xml='<!DOCTYPE configuration [<!ENTITY x "expanded">]><configuration>&x;</configuration>' },
        @{ Label='oversized'; Xml='<configuration><!--'+('x'*4194304)+'--></configuration>' }
    ) {
        $entries = @($seedEntries | ForEach-Object { $_.Clone() })
        $web = $entries | Where-Object { $_.name -ceq 'application/web.config' }
        $web.bytes = [Text.Encoding]::UTF8.GetBytes($Xml)
        $manifest = [Text.Encoding]::UTF8.GetString($entries[0].bytes) | ConvertFrom-Json -AsHashtable
        $file = $manifest.files | Where-Object { $_.path -ceq 'application/web.config' }
        $file.length = $web.bytes.Length
        $file.sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($web.bytes)).ToLowerInvariant()
        $manifest.inventorySha256 = & (Get-Module CLC.Deployment) { param($Files) Get-ClcInventoryHash $Files } $manifest.files
        $entries[0].bytes = [Text.Encoding]::UTF8.GetBytes(($manifest | ConvertTo-Json -Depth 10 -Compress))
        New-TestZip $archivePath $entries
        Test-TestRejection { Test-ClcRelease $archivePath } 'Clc.UnsafeArchive*'
    }
    It 'rejects raw local/central inconsistency and corruption <Mode>' -ForEach @(
        @{Mode='encrypted'},@{Mode='method'},@{Mode='unsupported flags'},@{Mode='central name'},@{Mode='local CRC'},
        @{Mode='both CRC'},@{Mode='length'},@{Mode='offset'},@{Mode='disk'},@{Mode='central signature'},
        @{Mode='local signature'},@{Mode='payload corruption'},@{Mode='truncation'},@{Mode='trailing data'},@{Mode='oversized file'},@{Mode='expanded bomb'}
    ) {
        $bytes = [byte[]]$seedBytes.Clone()
        $layout = Get-TestZipLayout $bytes
        $central = $layout.positions[0]
        switch ($Mode) {
            encrypted { Set-TestUInt16 $bytes 6 1; Set-TestUInt16 $bytes ($central+8) 1 }
            method { Set-TestUInt16 $bytes 8 99; Set-TestUInt16 $bytes ($central+10) 99 }
            'unsupported flags' { Set-TestUInt16 $bytes 6 32; Set-TestUInt16 $bytes ($central+8) 32 }
            'central name' { $bytes[$central+46] = [byte][char]'X' }
            'local CRC' { Set-TestUInt32 $bytes 14 0 }
            'both CRC' { Set-TestUInt32 $bytes 14 0; Set-TestUInt32 $bytes ($central+16) 0 }
            length { Set-TestUInt32 $bytes 22 1 }
            offset { Set-TestUInt32 $bytes ($central+42) 1 }
            disk { Set-TestUInt16 $bytes ($layout.end+4) 1 }
            'central signature' { $bytes[$central] = 0 }
            'local signature' { $bytes[0] = 0 }
            'payload corruption' { $bytes[30 + [BitConverter]::ToUInt16($bytes,26)] = 0 }
            truncation { $bytes = $bytes[0..($bytes.Length-2)] }
            'trailing data' { $bytes += [byte]0 }
            'oversized file' { Set-TestUInt32 $bytes ($central+24) 268435457; Set-TestUInt32 $bytes ($central+20) 268435457 }
            'expanded bomb' { foreach ($entryOffset in $layout.positions) { Set-TestUInt32 $bytes ($entryOffset+24) 268435456; Set-TestUInt32 $bytes ($entryOffset+20) 268435456 } }
        }
        [IO.File]::WriteAllBytes($archivePath,$bytes)
        Test-TestRejection { Test-ClcRelease $archivePath } 'Clc.UnsafeArchive*'
    }
    It 'rejects a real expansion ratio bomb with a tiny compressed payload' {
        New-TestZip $archivePath ($seedEntries + @{name='application/bomb.bin';bytes=[byte[]]::new(100000);attributes=0}) ([IO.Compression.CompressionLevel]::Optimal)
        Test-TestRejection { Test-ClcRelease $archivePath } 'Clc.UnsafeArchive*'
    }
    It 'rejects trailing or truncated compressed streams even with consistent raw ZIP extents' -ForEach @(
        @{Mode='trailing compressed bytes'},@{Mode='truncated end marker'},@{Mode='actual streamed length'}
    ) {
        New-TestZip $archivePath $seedEntries ([IO.Compression.CompressionLevel]::Optimal)
        $bytes = [IO.File]::ReadAllBytes($archivePath)
        [IO.File]::Delete($archivePath)
        $layout = Get-TestZipLayout $bytes
        $compressed = [int][BitConverter]::ToUInt32($bytes,18)
        $data = 30 + [BitConverter]::ToUInt16($bytes,26) + [BitConverter]::ToUInt16($bytes,28)
        $cut = $data + $compressed
        if ($Mode -ceq 'actual streamed length') {
            Set-TestUInt32 $bytes 22 1
            Set-TestUInt32 $bytes ($layout.central+24) 1
        } else {
            $delta = if ($Mode -ceq 'trailing compressed bytes') { 3 } else { -1 }
            $new = [byte[]]::new($bytes.Length+$delta)
            if ($delta -gt 0) {
                [Array]::Copy($bytes,0,$new,0,$cut)
                [Array]::Copy($bytes,$cut,$new,$cut+$delta,$bytes.Length-$cut)
            } else {
                [Array]::Copy($bytes,0,$new,0,$cut-1)
                [Array]::Copy($bytes,$cut,$new,$cut-1,$bytes.Length-$cut)
            }
            foreach ($central in $layout.positions) {
                $local = [int][BitConverter]::ToUInt32($bytes,$central+42)
                if ($local -gt 0) { Set-TestUInt32 $new ($central+$delta+42) ($local+$delta) }
            }
            Set-TestUInt32 $new 18 ($compressed+$delta)
            Set-TestUInt32 $new ($layout.central+$delta+20) ($compressed+$delta)
            Set-TestUInt32 $new ($layout.end+$delta+16) ($layout.central+$delta)
            $bytes = $new
        }
        [IO.File]::WriteAllBytes($archivePath,$bytes)
        Test-TestRejection { Test-ClcRelease $archivePath } 'Clc.UnsafeArchive*'
    }
    It 'rejects ZIP64, alternative Unicode, encryption and malformed local extra records' -ForEach @(
        @{Tag=1;Declared=0},@{Tag=0x7075;Declared=0},@{Tag=0x6375;Declared=0},@{Tag=0x0017;Declared=0},@{Tag=0x9901;Declared=0},@{Tag=0x1234;Declared=1}
    ) {
        $bytes = [byte[]]$seedBytes.Clone()
        $layout = Get-TestZipLayout $bytes
        $cut = 30 + [BitConverter]::ToUInt16($bytes,26)
        $new = [byte[]]::new($bytes.Length+4)
        [Array]::Copy($bytes,0,$new,0,$cut)
        [Array]::Copy($bytes,$cut,$new,$cut+4,$bytes.Length-$cut)
        Set-TestUInt16 $new 28 4
        Set-TestUInt16 $new $cut $Tag
        Set-TestUInt16 $new ($cut+2) $Declared
        foreach ($central in $layout.positions) {
            $local = [int][BitConverter]::ToUInt32($bytes,$central+42)
            if ($local -gt 0) { Set-TestUInt32 $new ($central+4+42) ($local+4) }
        }
        Set-TestUInt32 $new ($layout.end+4+16) ($layout.central+4)
        [IO.File]::WriteAllBytes($archivePath,$new)
        Test-TestRejection { Test-ClcRelease $archivePath } 'Clc.UnsafeArchive*'
    }
    It 'rejects 20,001 actual ZIP entries at the production count boundary' {
        $entries = [Collections.Generic.List[object]]::new()
        for ($i=0;$i -lt 20001;$i++) { $entries.Add(@{name=('application/f' + $i.ToString('D5') + '.txt');bytes=[byte[]]::new(0);attributes=0}) }
        New-TestZip $archivePath $entries.ToArray()
        Test-TestRejection { Test-ClcRelease $archivePath } 'Clc.UnsafeArchive*'
    }
    It 'enforces compressed, expanded, per-file and entry bounds using small injected ceilings' -ForEach @(
        @{Bound='Compressed';Limit=100L},@{Bound='Expanded';Limit=100L},@{Bound='File';Limit=100L},@{Bound='Entries';Limit=4L},@{Bound='Json';Limit=100L}
    ) {
        [IO.File]::WriteAllBytes($archivePath,$seedBytes)
        $old = & (Get-Module CLC.Deployment) { param($Name,$Limit) $previous=$script:ClcLimits[$Name]; $script:ClcLimits[$Name]=$Limit; $previous } $Bound $Limit
        try { Test-TestRejection { Test-ClcRelease $archivePath } } finally { & (Get-Module CLC.Deployment) { param($Name,$Limit) $script:ClcLimits[$Name]=$Limit } $Bound $old }
    }
    It 'fails closed when a stream throws midway through a read' {
        [IO.File]::WriteAllBytes($archivePath,$seedBytes)
        if ($null -eq ('Clc.Test.InterruptedStream' -as [type])) {
            Add-Type -TypeDefinition 'namespace Clc.Test { public sealed class InterruptedStream : System.IO.MemoryStream { public InterruptedStream(byte[] bytes) : base(bytes) {} public override int Read(byte[] buffer,int offset,int count) { if (Position > 64) throw new System.IO.IOException("fixture interruption"); return base.Read(buffer,offset,System.Math.Min(count,65)); } } }'
        }
        $stream = [Clc.Test.InterruptedStream]::new($seedBytes)
        try {
            { & (Get-Module CLC.Deployment) { param($InputStream) Test-ClcArchiveStream $InputStream ([Diagnostics.Stopwatch]::StartNew()) } $stream } | Should -Throw
        } finally { $stream.Dispose() }
    }
}

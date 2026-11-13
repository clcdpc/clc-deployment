BeforeAll { . "$PSScriptRoot/Support.ps1" }
Describe 'Ordinal streamed inventory identity' {
    It 'matches published SHA-256 vectors including an empty file' {
        & (Get-Module CLC.Deployment) {
            Get-ClcBytesHash ([byte[]]::new(0)) | Should -Be 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
            Get-ClcBytesHash ([Text.Encoding]::UTF8.GetBytes('abc')) | Should -Be 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
            Get-ClcInventoryHash @() | Should -Be 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
        }
    }
    It 'uses ordinal paths, NUL separators, invariant decimal lengths and LF without BOM' {
        $files = @(
            @{ path='application/a.txt'; length=0L; sha256='e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' },
            @{ path='application/Z.txt'; length=3L; sha256='ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad' }
        )
        $oldCulture = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            foreach ($culture in @('en-US','tr-TR','ar-SA')) {
                [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($culture)
                $digest = & (Get-Module CLC.Deployment) { param($Inventory) Get-ClcInventoryHash $Inventory } $files
                $digest | Should -Be '1f66dcfbe7c8bef583eb46ffb7d6345f2bf800cb3955e614bdb6343bf63f079a'
            }
        } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $oldCulture }
    }
    It 'rejects unsorted, duplicate, case-colliding and file/prefix inventories' {
        $raw = [IO.File]::ReadAllText((Join-Path $script:FixtureRoot 'release-manifest.json'))
        foreach ($mode in @('unsorted','duplicate','case','prefix','negative','oversized','hash')) {
            $record = $raw | ConvertFrom-Json -AsHashtable
            switch ($mode) {
                unsorted { [Array]::Reverse($record.files) }
                duplicate { $record.files += $record.files[0] }
                case { $copy = $record.files[0].Clone(); $copy.path = $copy.path.ToUpperInvariant(); $record.files += $copy }
                prefix { $copy = $record.files[0].Clone(); $copy.path += '/child.txt'; $record.files += $copy }
                negative { $record.files[0].length = -1 }
                oversized { $record.files[0].length = 268435457 }
                hash { $record.inventorySha256 = '0' * 64 }
            }
            Test-TestRejection { Invoke-TestRecord ([Text.Encoding]::UTF8.GetBytes(($record | ConvertTo-Json -Depth 10))) 'release-manifest' }
        }
    }
    It 'validates manifest-shaped nonempty backup entries and rejects fake backups' {
        $manifest = [IO.File]::ReadAllText((Join-Path $script:FixtureRoot 'release-manifest.json')) | ConvertFrom-Json -AsHashtable
        $backup = [IO.File]::ReadAllText((Join-Path $script:FixtureRoot 'backup-index.json')) | ConvertFrom-Json -AsHashtable
        $backup.priorEmpty = $false; $backup.priorApprovalId = 'example-001'; $backup.priorManifestSha256 = '0'*64
        $backup.files = $manifest.files; $backup.inventorySha256 = $manifest.inventorySha256
        $bytes = [Text.Encoding]::UTF8.GetBytes(($backup | ConvertTo-Json -Depth 10))
        (Invoke-TestRecord $bytes 'backup-index').files.Count | Should -Be 4
        $backup.files[0].unexpected = $true
        Test-TestRejection { Invoke-TestRecord ([Text.Encoding]::UTF8.GetBytes(($backup | ConvertTo-Json -Depth 10))) 'backup-index' }
    }
    It 'enforces actual stream lengths and standard CRC-32 independently of declarations' {
        & (Get-Module CLC.Deployment) {
            $stream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes('123456789'))
            try {
                $digest = Read-ClcZipPayload $stream 9 ([Diagnostics.Stopwatch]::StartNew())
                $digest.crc | Should -Be ([uint32]3421780262)
                $stream.Position = 0
                { Read-ClcStream $stream 8 ([Diagnostics.Stopwatch]::StartNew()) } | Should -Throw -ErrorId 'Clc.UnsafeArchive*'
                $stream.Position = 0
                { Read-ClcZipPayload $stream 8 ([Diagnostics.Stopwatch]::StartNew()) } | Should -Throw -ErrorId 'Clc.UnsafeArchive*'
            } finally { $stream.Dispose() }
        }
    }
}

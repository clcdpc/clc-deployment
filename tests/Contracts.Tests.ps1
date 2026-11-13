BeforeDiscovery {
    $recordCases = @('release-metadata','release-manifest','host-policy','target','release-approval','journal','current','backup-index','application-validation','readiness') | ForEach-Object { @{ Kind=$_ } }
}
BeforeAll { . "$PSScriptRoot/Support.ps1" }
Describe 'Strict UTF-8 versioned contract shapes' {
    It 'rejects the former version-one journal and removed per-file ownership records' {
        $j=Get-Content -LiteralPath (Join-Path $script:FixtureRoot 'journal.json') -Raw | ConvertFrom-Json -AsHashtable
        $j.schemaVersion=1
        Test-TestRejection { Invoke-TestRecord ([Text.Encoding]::UTF8.GetBytes(($j | ConvertTo-Json -Depth 24))) journal } 'Clc.UnsupportedContract*'
        Test-TestRejection { Invoke-TestRecord ([Text.Encoding]::UTF8.GetBytes('{"contractFamily":"clc-file-iis-v1","schemaVersion":1,"recordKind":"file-effect"}')) file-effect } 'Clc.UnsupportedContract*'
    }
    It 'accepts synthetic <Kind> with its standalone draft 2020-12 schema' -ForEach $recordCases {
        $path = Join-Path $script:FixtureRoot ($Kind + '.json')
        $bytes = [IO.File]::ReadAllBytes($path)
        $record = Invoke-TestRecord $bytes $Kind
        $record | Should -Not -BeNullOrEmpty
        $json = [Text.Encoding]::UTF8.GetString($bytes)
        Test-Json -Json $json -SchemaFile (Join-Path $script:RepositoryRoot ('schemas/' + $Kind + '.schema.json')) -ErrorAction Stop | Should -BeTrue
    }
    It 'rejects unknown and case-ambiguous root keys in <Kind>' -ForEach $recordCases {
        $json = [IO.File]::ReadAllText((Join-Path $script:FixtureRoot ($Kind + '.json'))).Trim()
        $unknown = $json.Substring(0,$json.Length-1) + ',"unexpected":1}'
        Test-TestRejection { Invoke-TestRecord ([Text.Encoding]::UTF8.GetBytes($unknown)) $Kind } 'Clc.InvalidContract*'
        $record = $json | ConvertFrom-Json -AsHashtable
        $key = @($record.Keys)[0]
        $same = $json.Substring(0,$json.Length-1) + ',"' + $key + '":1}'
        $case = $json.Substring(0,$json.Length-1) + ',"' + $key.ToUpperInvariant() + '":1}'
        foreach ($bad in @($same,$case)) { Test-TestRejection { Invoke-TestRecord ([Text.Encoding]::UTF8.GetBytes($bad)) $Kind } 'Clc.InvalidContract*' }
    }
    It 'rejects every missing required root field in <Kind>' -ForEach $recordCases {
        $record = [IO.File]::ReadAllText((Join-Path $script:FixtureRoot ($Kind + '.json'))) | ConvertFrom-Json -AsHashtable
        foreach ($key in @($record.Keys)) {
            $copy = $record | ConvertTo-Json -Depth 32 -Compress | ConvertFrom-Json -AsHashtable
            $copy.Remove($key)
            Test-TestRejection { Invoke-TestRecord ([Text.Encoding]::UTF8.GetBytes(($copy | ConvertTo-Json -Depth 32 -Compress))) $Kind }
        }
    }
    It 'rejects duplicates including escaped keys in nested objects' -ForEach @(
        @{Extra='"commit":"0000000000000000000000000000000000000000",'},
        @{Extra='"Commit":"0000000000000000000000000000000000000000",'},
        @{Extra='"\u0063ommit":"0000000000000000000000000000000000000000",'},
        @{Extra='"participants":[], '}
    ) {
        $json = [IO.File]::ReadAllText((Join-Path $script:FixtureRoot 'release-metadata.json')).Replace('"source": {','"source": {' + $Extra)
        Test-TestRejection { Invoke-TestRecord ([Text.Encoding]::UTF8.GetBytes($json)) 'release-metadata' } 'Clc.InvalidContract*'
    }
    It 'rejects strict JSON lexical failures <Label>' -ForEach @(
        @{Label='comment'; Tail=' /* comment */'},@{Label='trailing object'; Tail=' {}'},@{Label='trailing array'; Tail=' []'},
        @{Label='number'; Tail=' 1'},@{Label='trailing comma'; Tail=','}
    ) {
        $json = [IO.File]::ReadAllText((Join-Path $script:FixtureRoot 'release-metadata.json')) + $Tail
        Test-TestRejection { Invoke-TestRecord ([Text.Encoding]::UTF8.GetBytes($json)) 'release-metadata' } 'Clc.InvalidContract*'
    }
    It 'rejects BOM, invalid UTF-8, unpaired surrogates, coercion, floats and nulls' {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $script:FixtureRoot 'release-metadata.json'))
        Test-TestRejection { Invoke-TestRecord ([byte[]](0xef,0xbb,0xbf) + $bytes) 'release-metadata' }
        Test-TestRejection { Invoke-TestRecord ([byte[]](0xc0,0xaf)) 'release-metadata' }
        $json = [Text.Encoding]::UTF8.GetString($bytes)
        foreach ($bad in @($json.Replace('"probe"','"\ud800"'),$json.Replace('"workerLimit": 1','"workerLimit": "1"'),$json.Replace('"workerLimit": 1','"workerLimit": 1.0'),$json.Replace('"workerLimit": 1','"workerLimit": 1e0'),$json.Replace('"workerLimit": 1','"workerLimit": null'),$json.Replace('"workerLimit": 1','"workerLimit": true'))) {
            Test-TestRejection { Invoke-TestRecord ([Text.Encoding]::UTF8.GetBytes($bad)) 'release-metadata' }
        }
    }
    It 'rejects legacy blueprint and unsupported family/version/kind' -ForEach @(
        @{Field='contractFamily'; Value='clc-deployment-v1'},@{Field='contractFamily'; Value=$null},
        @{Field='schemaVersion'; Value=2},@{Field='schemaVersion'; Value='1'},@{Field='schemaVersion'; Value=$true},
        @{Field='recordKind'; Value='release-bundle'},@{Field='recordKind'; Value='artifact-receipt'},@{Field='recordKind'; Value='release-metadata-v1'}
    ) {
        $record = Get-TestMetadata; $record[$Field] = $Value
        Test-TestRejection { Invoke-TestRecord ([Text.Encoding]::UTF8.GetBytes(($record | ConvertTo-Json -Depth 10))) 'release-metadata' } 'Clc.UnsupportedContract*'
    }
    It 'rejects invalid package declarations <Label>' -ForEach @(
        @{Label='ID'; Parent=''; Field='releaseId'; Value='../release'},
        @{Label='commit casing'; Parent='source'; Field='commit'; Value=('A'*40)},
        @{Label='short hash'; Parent='builder'; Field='distributionSha256'; Value='abc'},
        @{Label='uppercase hash'; Parent='builder'; Field='distributionSha256'; Value=('A'*64)},
        @{Label='version'; Parent='builder'; Field='version'; Value='01.0.0'},
        @{Label='prerelease zeros'; Parent='builder'; Field='version'; Value='1.0.0-01'},
        @{Label='wrong module'; Parent='builder'; Field='module'; Value='CLC.Other'},
        @{Label='database'; Parent=''; Field='changeKind'; Value='database'},
        @{Label='services'; Parent=''; Field='changeKind'; Value='services'},
        @{Label='readiness'; Parent=''; Field='readinessContractVersion'; Value=2},
        @{Label='validation'; Parent='validation'; Field='contractVersion'; Value=2},
        @{Label='DLL traversal'; Parent='validation'; Field='entryPoint'; Value='../Probe.dll'},
        @{Label='RID'; Parent='runtime'; Field='rid'; Value='linux-x64'},
        @{Label='architecture'; Parent='runtime'; Field='architecture'; Value='x86'},
        @{Label='hosting'; Parent='runtime'; Field='hostingModel'; Value='outofprocess'},
        @{Label='workers'; Parent='runtime'; Field='workerLimit'; Value=2},
        @{Label='source URL'; Parent='source'; Field='repository'; Value='https://github.com/synthetic/probe'},
        @{Label='workflow'; Parent='build'; Field='workflowPath'; Value='.github/workflows/../exec.yml'},
        @{Label='negative run'; Parent='build'; Field='runId'; Value=-1},
        @{Label='null source'; Parent=''; Field='source'; Value=$null}
    ) {
        $record = Get-TestMetadata
        if ($Parent) { $record[$Parent][$Field] = $Value } else { $record[$Field] = $Value }
        Test-TestRejection { Invoke-TestRecord ([Text.Encoding]::UTF8.GetBytes(($record | ConvertTo-Json -Depth 10))) 'release-metadata' }
    }
    It 'requires controlStateRoot and forbids target-selected controlRoot and hostBootIdentity' {
        $policy = [IO.File]::ReadAllText((Join-Path $script:FixtureRoot 'host-policy.json')) | ConvertFrom-Json -AsHashtable
        $policy.Remove('controlStateRoot')
        Test-TestRejection { Invoke-TestRecord ([Text.Encoding]::UTF8.GetBytes(($policy | ConvertTo-Json -Depth 10))) 'host-policy' }
        $target = [IO.File]::ReadAllText((Join-Path $script:FixtureRoot 'target.json')) | ConvertFrom-Json -AsHashtable
        $target.controlRoot = 'C:\synthetic\alternate'
        Test-TestRejection { Invoke-TestRecord ([Text.Encoding]::UTF8.GetBytes(($target | ConvertTo-Json -Depth 10))) 'target' }
        $journal = [IO.File]::ReadAllText((Join-Path $script:FixtureRoot 'journal.json')) | ConvertFrom-Json -AsHashtable
        $journal.hostBootIdentity = 'not-authority'
        Test-TestRejection { Invoke-TestRecord ([Text.Encoding]::UTF8.GetBytes(($journal | ConvertTo-Json -Depth 32))) 'journal' }
    }
    It 'requires precise native process identity and complete recovery policy pins' {
        $raw = [IO.File]::ReadAllText((Join-Path $script:FixtureRoot 'journal.json'))
        foreach ($stamp in @('2026-01-01T00:00:00Z','2026-01-01T00:00:00.000Z','2026-01-01T00:00:00.0000000+00:00','1600-01-01T00:00:00.0000000Z','2026-02-30T00:00:00.0000000Z')) {
            $record = $raw | ConvertFrom-Json -AsHashtable; $record.nativeCall.creationUtc = $stamp
            Test-TestRejection { Invoke-TestRecord ([Text.Encoding]::UTF8.GetBytes(($record | ConvertTo-Json -Depth 32))) 'journal' }
        }
        foreach ($field in @('policyGeneration','policySha256')) {
            $record = $raw | ConvertFrom-Json -AsHashtable; $record.recovery.Remove($field)
            Test-TestRejection { Invoke-TestRecord ([Text.Encoding]::UTF8.GetBytes(($record | ConvertTo-Json -Depth 32))) 'journal' }
        }
        $record = $raw | ConvertFrom-Json -AsHashtable; $record.nativeCall.launchState = 'Intent'
        Test-TestRejection { Invoke-TestRecord ([Text.Encoding]::UTF8.GetBytes(($record | ConvertTo-Json -Depth 32))) 'journal' }
    }
    It 'rejects noncanonical machine GUIDs and duplicate/noncanonical SIDs' {
        $raw = [IO.File]::ReadAllText((Join-Path $script:FixtureRoot 'host-policy.json'))
        foreach ($guid in @('00000000-0000-0000-0000-000000000000','ffffffff-ffff-ffff-ffff-ffffffffffff','AAAAAAAA-1111-1111-1111-111111111111','{11111111-1111-1111-1111-111111111111}')) {
            $record = $raw | ConvertFrom-Json -AsHashtable; $record.machineIdentity = $guid
            Test-TestRejection { Invoke-TestRecord ([Text.Encoding]::UTF8.GetBytes(($record | ConvertTo-Json -Depth 10))) 'host-policy' }
        }
        foreach ($sids in @(@('S-1-5-18','S-1-5-18'),@('S-1-05-18'),@('username'),@())) {
            $record = $raw | ConvertFrom-Json -AsHashtable; $record.deploymentSids = $sids
            Test-TestRejection { Invoke-TestRecord ([Text.Encoding]::UTF8.GetBytes(($record | ConvertTo-Json -Depth 10))) 'host-policy' }
        }
    }
    It 'enforces an actual 4 MiB record boundary, response bounds and depth' {
        $raw = [IO.File]::ReadAllText((Join-Path $script:FixtureRoot 'release-metadata.json'))
        $exact = [Text.Encoding]::UTF8.GetBytes($raw + (' ' * (4194304 - [Text.Encoding]::UTF8.GetByteCount($raw))))
        (Invoke-TestRecord $exact 'release-metadata').releaseId | Should -Be 'probe-example-001'
        Test-TestRejection { Invoke-TestRecord ($exact + [byte]32) 'release-metadata' }
        foreach ($kind in @('application-validation','readiness')) {
            $response = [IO.File]::ReadAllText((Join-Path $script:FixtureRoot ($kind + '.json'))) + (' ' * 8193)
            Test-TestRejection { Invoke-TestRecord ([Text.Encoding]::UTF8.GetBytes($response)) $kind }
        }
        Test-TestRejection { Invoke-TestRecord ([Text.Encoding]::UTF8.GetBytes(('[' * 33) + '1' + (']' * 33))) 'release-metadata' }
    }
}


BeforeAll { . "$PSScriptRoot/Support.ps1" }
Describe 'Versioned package and companion contracts' {
    It 'validates the exact <Kind> fixture against the parser and schema' -ForEach @(
        @{Kind='release-metadata'},@{Kind='release-manifest'},@{Kind='application-validation'},@{Kind='readiness'}
    ) {
        $bytes=[IO.File]::ReadAllBytes((Join-Path $script:FixtureRoot ($Kind+'.json')))
        { Invoke-TestRecord $bytes $Kind } | Should -Not -Throw
        Test-Json -Json ([Text.Encoding]::UTF8.GetString($bytes)) -SchemaFile (Join-Path $script:RepositoryRoot ('schemas/'+$Kind+'.schema.json')) | Should -BeTrue
    }
    It 'rejects case-ambiguous, trailing and coerced metadata' -ForEach @(
        @{Mode='duplicate'},@{Mode='case'},@{Mode='trailing'},@{Mode='integer'},@{Mode='target'}
    ) {
        $json=Get-TestMetadata | ConvertTo-Json -Depth 8 -Compress
        switch ($Mode) {
            duplicate { $json='{"targetId":"probe-dev",'+$json.Substring(1) }
            case { $json='{"TargetId":"probe-dev",'+$json.Substring(1) }
            trailing { $json+='{}' }
            integer { $json=$json.Replace('"schemaVersion":3','"schemaVersion":3.0') }
            target { $json=$json.Replace('"targetId":"probe-dev"','"targetId":"bad/target"') }
        }
        { Invoke-TestRecord ([Text.Encoding]::UTF8.GetBytes($json)) 'release-metadata' } | Should -Throw -ErrorId 'Clc.*'
    }
    It 'requires explicit target and lock evidence fields while accepting null values for their documented cases' {
        $record=Get-TestMetadata
        $record.targetId=$null
        $record.build.dependencyLockSha256=$null
        { Invoke-TestRecord ([Text.Encoding]::UTF8.GetBytes(($record | ConvertTo-Json -Depth 8))) 'release-metadata' } | Should -Not -Throw
        $record.Remove('targetId')
        { Invoke-TestRecord ([Text.Encoding]::UTF8.GetBytes(($record | ConvertTo-Json -Depth 8))) 'release-metadata' } | Should -Throw -ErrorId 'Clc.InvalidContract*'
    }
}

Describe 'Strict versioned host record contracts' {
    It 'rejects malformed host record <_>' -ForEach @('extra','missing','legacyMissing','legacyUrl','version','type','foreign') {
        $record=@{schemaVersion=2;recordKind='host';applicationId='probe';targetId='probe-dev';siteName='Custom';
            applicationPoolName='Pool';applicationRoot='C:\ProgramData\clc-probe\Application';siteId=42}
        switch ($_) {
            extra { $record.readinessUri='https://old.invalid/health/ready' }
            missing { $record.Remove('siteId') }
            legacyMissing { $record.schemaVersion=1 }
            legacyUrl { $record.schemaVersion=1;$record.readinessUri='http://old.invalid/health/ready' }
            version { $record.schemaVersion=3 }
            type { $record.schemaVersion='2' }
            foreign { $record.recordKind='attempt' }
        }
        { Invoke-TestRecord ([Text.Encoding]::UTF8.GetBytes(($record | ConvertTo-Json))) host } | Should -Throw
    }
}

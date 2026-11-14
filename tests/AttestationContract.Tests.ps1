BeforeAll {
    . "$PSScriptRoot/Support.ps1"
    $script:evidenceRoot=Join-Path $script:FixtureRoot 'Attestation'
    $script:realOutput=[IO.File]::ReadAllBytes((Join-Path $script:evidenceRoot 'verified.json'))
    $script:qualification=Get-Content (Join-Path $script:evidenceRoot 'qualification.json') -Raw | ConvertFrom-Json -AsHashtable
    $script:actualPredicate=Get-Content (Join-Path $script:evidenceRoot 'predicate.json') -Raw | ConvertFrom-Json -AsHashtable
    $script:standing=@{sourceRepository='clcdpc/clc-deployment';sourceRepositoryId='1456920635';sourceOwnerId='2538422';
        producer=@{repository='clcdpc/clc-deployment';workflowPath='.github/workflows/clc-receipt-producer.yml';
            sourceCommit=$script:qualification.producerCommit;buildWorkflowPath='.github/workflows/receipt-qualification.yml';buildJob='build'}}
    $script:manifest=@{source=@{commit=$script:qualification.sourceCommit}}
    function Read-RealReceiptOutput {
        param([byte[]] $Bytes=$script:realOutput)
        & (Get-Module CLC.Deployment) {
            param($b,$s,$m,$t) ConvertFrom-ClcAttestationOutput $b $s $m $t
        } $Bytes $script:standing $script:manifest $script:actualPredicate.tag
    }
}

Describe 'Observed GitHub custom-attestation contract' {
    It 'accepts the unmodified actual pinned-verifier output from the hosted run' {
        $p=Read-RealReceiptOutput
        $p.sourceCommit | Should -BeExactly $script:qualification.sourceCommit
        $p.provenance.runId | Should -Be $script:qualification.runId
        $p.provenance.runAttempt | Should -Be $script:qualification.runAttempt
        $p.releaseZipSha256 | Should -BeExactly $script:qualification.packageSha256
        $p.manifestSha256 | Should -BeExactly $script:qualification.manifestSha256
        Test-Json -Json ($p | ConvertTo-Json -Depth 12) -SchemaFile (Join-Path $script:RepositoryRoot 'schemas/automated-provenance.schema.json') | Should -BeTrue
    }
    It 'retains the actual package, bundle and pinned trust bytes' {
        $inspection=Test-ClcRelease -ArchivePath (Join-Path $script:evidenceRoot 'release.zip')
        $inspection.archiveSha256 | Should -BeExactly $script:qualification.packageSha256
        $inspection.manifestSha256 | Should -BeExactly $script:qualification.manifestSha256
        (Get-FileHash (Join-Path $script:evidenceRoot 'receipt.sigstore.json')).Hash.ToLowerInvariant() | Should -BeExactly $script:qualification.bundleSha256
        (Get-FileHash (Join-Path $script:evidenceRoot 'trusted-root.jsonl')).Hash.ToLowerInvariant() | Should -BeExactly $script:qualification.trustedRootSha256
        $bundle=Get-Content (Join-Path $script:evidenceRoot 'receipt.sigstore.json') -Raw | ConvertFrom-Json
        $bundle.mediaType | Should -BeExactly 'application/vnd.dev.sigstore.bundle.v0.3+json'
    }
    It 'rejects a changed signed <Field> against the real run certificate' -ForEach @(@{Field='runId'},@{Field='runAttempt'}) {
        $values=ConvertFrom-Json -InputObject ([Text.Encoding]::UTF8.GetString($script:realOutput)) -AsHashtable -NoEnumerate
        $values[0].predicate.provenance[$Field]++
        $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $values -Depth 24 -Compress))
        Test-TestRejection { Read-RealReceiptOutput $bytes } 'Clc.ProvenanceRejected*'
    }
    It 'rejects missing observed certificate identity rather than filling it from the predicate' {
        $values=ConvertFrom-Json -InputObject ([Text.Encoding]::UTF8.GetString($script:realOutput)) -AsHashtable -NoEnumerate
        $values[0].certificate.Remove('sourceRepositoryIdentifier')
        $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $values -Depth 24 -Compress))
        Test-TestRejection { Read-RealReceiptOutput $bytes } 'Clc.ProvenanceRejected*'
    }
}

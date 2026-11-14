[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $EvidenceRoot,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string] $ProducerCommit
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repository=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repository 'src/CLC.Deployment/CLC.Deployment.psd1') -Force
$root=[IO.Path]::GetFullPath($EvidenceRoot)
$pin=Get-Content (Join-Path $PSScriptRoot 'automation-verifier.lock.json') -Raw | ConvertFrom-Json
$gh=Join-Path $root 'verifier/bin/gh.exe'
if ((Get-FileHash -LiteralPath $gh).Hash.ToLowerInvariant() -cne $pin.executableSha256) { throw 'Verifier pin mismatch' }
$trustedRoot=Join-Path $root 'trusted-root.jsonl'
$rootHash=(Get-FileHash -LiteralPath $trustedRoot).Hash.ToLowerInvariant()
$rootPin=Get-Content (Join-Path $PSScriptRoot 'receipt-qualification.lock.json') -Raw | ConvertFrom-Json
if ($rootHash -cne $rootPin.trustedRootSha256) { throw 'Qualification trusted-root pin mismatch' }
$predicate=Get-Content (Join-Path $root 'receipt/predicate.json') -Raw | ConvertFrom-Json -AsHashtable
$archive=Join-Path $root 'package/release.zip'
$bundle=Join-Path $root ('receipt/'+$predicate.releaseId+'.sigstore.json')
$inspection=Test-ClcRelease -ArchivePath $archive
$zip=[IO.Compression.ZipFile]::OpenRead($archive)
try {
    $reader=[IO.StreamReader]::new($zip.GetEntry('manifest.json').Open())
    try { $manifest=$reader.ReadToEnd() | ConvertFrom-Json -AsHashtable } finally { $reader.Dispose() }
} finally { $zip.Dispose() }
$standing=@{sourceRepository=$env:GITHUB_REPOSITORY;sourceRepositoryId=$env:GITHUB_REPOSITORY_ID;sourceOwnerId=$env:GITHUB_REPOSITORY_OWNER_ID;
    producer=@{repository='clcdpc/clc-deployment';workflowPath='.github/workflows/clc-receipt-producer.yml';sourceCommit=$ProducerCommit;
        buildWorkflowPath='.github/workflows/receipt-qualification.yml';buildJob='build'};
    verifier=@{trustedRootPath=$trustedRoot}}
if ($predicate.releaseZipSha256 -cne $inspection.archiveSha256 -or $predicate.manifestSha256 -cne $inspection.manifestSha256 -or
    $predicate.sourceCommit -cne $env:GITHUB_SHA -or $predicate.sourceRepository -cne $env:GITHUB_REPOSITORY -or
    $predicate.provenance.runId -ne [long]$env:GITHUB_RUN_ID -or $predicate.provenance.runAttempt -ne [long]$env:GITHUB_RUN_ATTEMPT -or
    $predicate.provenance.workflowPath -cne $standing.producer.buildWorkflowPath -or $predicate.provenance.buildJob -cne 'build' -or
    $predicate.targetId -cne 'receipt-qualification' -or $predicate.applicationId -cne 'probe') { throw 'Qualification predicate mismatch' }
$module=Get-Module CLC.Deployment
# Exactly the runtime verifier arguments, process launcher (cleared environment,
# bounded time/output) and parser. No certificate or process output is mocked.
$arguments=& $module { param($s,$a,$b,$m,$t) Get-ClcAttestationArguments $s $a $b $m $t } $standing $archive $bundle $manifest $predicate.tag
function Invoke-RealVerifier {
    param([string[]] $VerifierArguments)
    & $module {
        param($exe,$argv)
        $running=Start-ClcAttestationVerifier $exe $argv
        try {
            $output=Complete-ClcHelperOutput $running
            if ($output.Failed) { return @{failed=$true;bytes=$output.Bytes} }
            return @{failed=$false;bytes=$output.Bytes}
        } finally {
            $identity=Get-ClcProcessIdentity $running.Process
            $null=Wait-ClcTrackedProcess $running.Process $identity.creationUtc 0 30000
            $running.Process.Dispose()
        }
    } $gh $VerifierArguments
}
$verified=Invoke-RealVerifier $arguments
if ($verified.failed) { throw 'Actual offline GitHub verification failed' }
[IO.File]::WriteAllBytes((Join-Path $root 'verified.json'),$verified.bytes)
$accepted=& $module { param($b,$s,$m,$t) ConvertFrom-ClcAttestationOutput $b $s $m $t } $verified.bytes $standing $manifest $predicate.tag
if (($accepted | ConvertTo-Json -Depth 12 -Compress) -cne ($predicate | ConvertTo-Json -Depth 12 -Compress)) {
    if (-not (& $module { param($a,$b) Test-ClcValueEqual $a $b } $accepted $predicate)) { throw 'Signed predicate differs' }
}
$negativeResults=[ordered]@{}
foreach ($pair in @(
    @('--predicate-type','https://example.invalid/wrong'),
    @('--signer-digest',('0'*40)),
    @('--source-digest',('0'*40)),
    @('--source-ref','refs/tags/v0.0.0-dev.1')
)) {
    $wrong=[string[]]$arguments.Clone()
    $wrong[[Array]::IndexOf($wrong,$pair[0])+1]=$pair[1]
    if (-not (Invoke-RealVerifier $wrong).failed) { throw ('Verifier accepted wrong '+$pair[0]) }
    $negativeResults[$pair[0]]='rejected'
}
$tampered=Join-Path $root 'tampered.zip'
[IO.File]::WriteAllBytes($tampered,([IO.File]::ReadAllBytes($archive)+[byte[]]@(1)))
$wrong=[string[]]$arguments.Clone(); $wrong[2]=$tampered
if (-not (Invoke-RealVerifier $wrong).failed) { throw 'Verifier accepted changed package' }
$negativeResults['package-sha256']='rejected'
if ((Get-FileHash -LiteralPath $trustedRoot).Hash.ToLowerInvariant() -cne $rootHash) { throw 'Root drift' }
$summary=[ordered]@{cryptographicIntegrationVerified=$true;realHostQualified=$false;
    sourceCommit=$env:GITHUB_SHA;producerCommit=$ProducerCommit;runId=$predicate.provenance.runId;runAttempt=$predicate.provenance.runAttempt;
    verifierVersion=$pin.version;verifierSha256=$pin.executableSha256;trustedRootSha256=$rootHash;
    packageSha256=$inspection.archiveSha256;manifestSha256=$inspection.manifestSha256;
    bundleSha256=(Get-FileHash -LiteralPath $bundle).Hash.ToLowerInvariant();negativeChecks=$negativeResults}
$summary | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $root 'qualification.json') -Encoding utf8NoBOM
$summary


function Invoke-ClcIisDeployment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $ApplicationId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $TargetId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $ExpectedRuntimeAccount,
        [Parameter(Mandatory)][ValidateSet('Staging','Production',IgnoreCase=$false)][string] $RuntimeEnvironment,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $ArchivePath,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $ExpectedSha256,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $ReleaseTag,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $ExpectedSourceCommit,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $ExpectedRepository
    )
    Assert-ClcId $ApplicationId
    Assert-ClcId $TargetId
    Assert-ClcHash $ExpectedSha256
    Assert-ClcCommit $ExpectedSourceCommit
    Assert-ClcRepository $ExpectedRepository
    $tag=Get-ClcDeploymentTag $ReleaseTag
    if ($tag.channel -ceq 'ArtifactOnly') { Stop-ClcError Clc.ReleaseMismatch 'Use a DEV or stable release tag for IIS deployment.' }
    if ($tag.channel -ceq 'Production' -and $RuntimeEnvironment -cne 'Production') {
        Stop-ClcError Clc.ReleaseMismatch 'Stable release tags require the Production runtime environment.'
    }
    $handles=[Collections.Generic.List[IDisposable]]::new()
    $lock=$null; $attempt=$null; $committed=$false; $iisEffects=$false
    try {
        $facts=Get-ClcPathObservation $ArchivePath $handles
        $archive=Open-ClcReadFile $ArchivePath $facts $handles
        $package=Test-ClcArchiveStream $archive ([Diagnostics.Stopwatch]::StartNew()) -ExpectedSha256 $ExpectedSha256 -IncludeManifest
        $manifest=$package.manifest
        if ($manifest.applicationId -cne $ApplicationId -or $manifest.targetId -cne $TargetId -or
            $manifest.releaseId -cne $tag.releaseId -or $manifest.source.commit -cne $ExpectedSourceCommit -or
            $manifest.source.repository -cne $ExpectedRepository) {
            Stop-ClcError Clc.ReleaseMismatch 'Artifact application, target, tag or source differs from the trusted workflow inputs.'
        }
        Assert-ClcPlatform
        $layout=Get-ClcHostLayout $ApplicationId
        # An uninitialized or incomplete scaffold must not gain a lock file.
        Assert-ClcStoragePath $layout.root -Directory
        $target=Read-ClcLocalRecord $layout.hostRecord host
        if ($target.applicationId -cne $ApplicationId -or $target.targetId -cne $TargetId) { Stop-ClcError Clc.TargetMismatch 'Select the initialized application and deployment target.' }
        $lock=Enter-ClcDeploymentLock $layout
        $context=Open-ClcHostContext $ApplicationId $TargetId $ExpectedRuntimeAccount $RuntimeEnvironment
        Assert-ClcRunnableContext $context
        Assert-ClcOrdering $context.state $tag $package.archiveSha256 $context.previous $ExpectedRepository
        $previousFiles=@(if ($null -ne $context.previous) {$context.previous.files})
        Assert-ClcCompatibleLayout $previousFiles $manifest.files
        $context.configurationFile=Read-ClcHeldFile $layout.config $handles 4194304 -NoCapture

        $reference=@{attemptId=[guid]::NewGuid().ToString('D');tag=$tag.tag;archiveSha256=$package.archiveSha256;manifestSha256=$package.manifestSha256}
        $paths=Get-ClcAttemptPaths $layout $reference.attemptId
        $attempt=[ordered]@{schemaVersion=1;recordKind='attempt';applicationId=$ApplicationId;targetId=$TargetId;
            release=$reference;previous=$(if ($null -ne $context.state.current) {$context.state.current.release});
            phase='Preparing';backupVerified=$false;helper=$null;reason=$null;errorCode=$null;
            startedUtc=(Get-ClcUtc);toolkitVersion=(Get-ClcToolkitVersion)}
        $context.state.pending=$reference
        $context.state.highWater=$reference
        Write-ClcLocalRecord $layout.state $context.state -Replace
        $committed=$true
        New-ClcHostDirectory $paths.root
        Write-ClcLocalRecord $paths.journal $attempt
        Write-ClcLocalBytes $paths.manifest $package.manifestBytes
        Expand-ClcApplication $archive $manifest $paths.stage
        $configuration=Invoke-ClcApplicationValidation $context $attempt $paths $manifest $paths.stage

        $attempt.phase='Stopping'
        Write-ClcLocalRecord $paths.journal $attempt -Replace
        $iisEffects=$true
        Stop-ClcApplication $context
        New-ClcBackup $context $paths.backup $previousFiles
        $attempt.backupVerified=$true
        Write-ClcLocalRecord $paths.journal $attempt -Replace
        if ($null -ne $context.previous) {
            $prior=Invoke-ClcApplicationValidation $context $attempt $paths $context.previous $paths.backup
            if ($prior.revision -cne $configuration.revision -or $prior.keyStoreCompatibilityId -cne $configuration.keyStoreCompatibilityId -or
                $context.state.current.keyStoreCompatibilityId -cne $configuration.keyStoreCompatibilityId) {
                Stop-ClcError Clc.ConfigurationInvalid 'The candidate and previous release must agree on configuration revision and persistent key compatibility.'
            }
        }

        $attempt.phase='Replacing'
        Write-ClcLocalRecord $paths.journal $attempt -Replace
        Set-ClcApplicationFiles $context $paths.stage $manifest.files $previousFiles $paths.work
        $attempt.phase='Checking'
        Write-ClcLocalRecord $paths.journal $attempt -Replace
        $iis=Start-ClcApplication $context $manifest $configuration (Join-Path $paths.root 'deployment-readiness')
        $attempt.phase='Ready'
        Write-ClcLocalRecord $paths.journal $attempt -Replace
        $context.state.current=New-ClcCurrent $reference $configuration
        $context.state.pending=$null
        Write-ClcLocalRecord $layout.state $context.state -Replace
        $committed=$false
        return New-ClcDeploymentResult 'Deployed' $context $reference $paths $iis $manifest.releaseId
    } catch {
        if ($committed) { Stop-ClcFailedAttempt $_ $context $attempt $paths $iisEffects }
        $finding=Get-ClcSafeFinding $_
        Stop-ClcError $finding.code $finding.message
    } finally {
        foreach ($handle in $handles) { $handle.Dispose() }
        if ($null -ne $lock) { $lock.Dispose() }
    }
}

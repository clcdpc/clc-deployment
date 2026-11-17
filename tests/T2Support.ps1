# Synthetic fixtures only. No operational configuration or real authority.
function Invoke-T2Private {
    param([string] $Name, [object[]] $Arguments=@())
    if ($Name -ceq 'Open-ClcTrustedContext' -and $Arguments.Count -eq 0) { $Arguments=@($global:ClcTestFixture.target.targetId) }
    return & (Get-Module Clc.Deployment) { param($Name,$Arguments) & $Name @Arguments } $Name $Arguments
}
function New-T2Fixture {
    $workspace=New-TestWorkspace
    $targetRoot=Join-Path $workspace 'clc-example'; $deploymentRoot=Join-Path $targetRoot 'Deployment'; $toolkit=Join-Path $deploymentRoot 'toolkit'; $version=Join-Path $toolkit 'versions\0.1.0-dev.1'; $module=Join-Path $version 'Clc.Deployment'
    $layout=@{targetId='example';targetRoot=$targetRoot;deploymentRoot=$deploymentRoot;root=$toolkit;moduleRoot=$module;versionRoot=$version;manifestPath=(Join-Path $module 'Clc.Deployment.psd1');
        policyRoot=(Join-Path $toolkit 'policy');policyPath=(Join-Path $toolkit 'policy\host-policy.json');
        targetCatalogRoot=(Join-Path $toolkit 'policy\targets');approvalCatalogRoot=(Join-Path $toolkit 'policy\approvals');
        sourcePath=(Join-Path $version 'source.commit');distributionPath=(Join-Path $version 'distribution.zip');
        controlStateRoot=(Join-Path $deploymentRoot 'control');lockRoot=(Join-Path $deploymentRoot 'locks')}
    foreach ($path in @($module,$layout.targetCatalogRoot,$layout.approvalCatalogRoot,$layout.controlStateRoot,$layout.lockRoot,(Join-Path $targetRoot 'Application'),(Join-Path $targetRoot 'Config'),(Join-Path $targetRoot 'Keys'),(Join-Path $targetRoot 'Inbox'),'binaries')) {
        if (-not [IO.Path]::IsPathRooted($path)) { $path=Join-Path $workspace $path }; [void][IO.Directory]::CreateDirectory($path)
    }
    Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'src\Clc.Deployment') -Destination $version -Recurse -Force
    [IO.File]::WriteAllText($layout.sourcePath,('a'*40),[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($layout.distributionPath,'synthetic distribution; never installed or executed')
    $files=@(Get-ChildItem -LiteralPath $module -Recurse -File | ForEach-Object {
        @{path=$_.FullName.Substring($module.Length+1).Replace('\','/');length=[long]$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
    })
    $policy=Get-Content -LiteralPath (Join-Path $script:FixtureRoot 'host-policy.json') -Raw | ConvertFrom-Json -AsHashtable -DateKind String
    $policy.targetCatalogRoot=$layout.targetCatalogRoot; $policy.approvalCatalogRoot=$layout.approvalCatalogRoot
    $policy.controlStateRoot=$layout.controlStateRoot; $policy.lockRoot=$layout.lockRoot
    $policy.dotnetPath=Join-Path $workspace 'binaries\dotnet\dotnet.exe'; $policy.appcmdPath=Join-Path $workspace 'binaries\iis\appcmd.exe'
    foreach ($relative in @('dotnet','dotnet\host\fxr\10.0.12','dotnet\shared\Microsoft.NETCore.App\10.0.12','dotnet\shared\Microsoft.AspNetCore.App\10.0.12','iis')) {
        [void][IO.Directory]::CreateDirectory((Join-Path $workspace ('binaries\'+$relative)))
    }
    foreach ($path in @($policy.dotnetPath,$policy.appcmdPath,(Join-Path $workspace 'binaries\dotnet\host\fxr\10.0.12\hostfxr.dll'),
            (Join-Path $workspace 'binaries\iis\Microsoft.Web.Administration.dll'))) { [IO.File]::WriteAllText($path,'synthetic; never executed') }
    $policy.activeToolkit.moduleManifestPath=$layout.manifestPath; $policy.activeToolkit.sourceCommit='a'*40
    $policy.activeToolkit.inventorySha256=Invoke-T2Private Get-ClcInventoryHash @(,$files)
    $policy.activeToolkit.distributionSha256=(Get-FileHash -LiteralPath $layout.distributionPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-TestJson $layout.policyPath $policy
    $target=Get-Content -LiteralPath (Join-Path $script:FixtureRoot 'target.json') -Raw | ConvertFrom-Json -AsHashtable -DateKind String
    $target.applicationRoot=Join-Path $targetRoot 'Application'; $target.operationalConfigPath=Join-Path $targetRoot 'Config\application.json'
    $target.dataProtectionRoot=Join-Path $targetRoot 'Keys'; $target.artifactInboxRoot=Join-Path $targetRoot 'Inbox'
    [IO.File]::WriteAllText($target.operationalConfigPath,'synthetic external configuration; never executed')
    Write-TestJson (Join-Path $layout.targetCatalogRoot ($target.targetId+'.json')) $target
    $key='385c88656f98beb477be41f46381e9b9bb21cfb2dd8b3fcfd9aabdb69ce42c87' # Independently checked UTF-8 SHA-256 fixture.
    $control=Join-Path $policy.controlStateRoot $key; [void][IO.Directory]::CreateDirectory($control)
    $iis=@{siteName=$target.siteName;siteState='Started';poolName=$target.applicationPoolName;poolState='Stopped';
        applications=@(@{siteName=$target.siteName;path='/';poolName=$target.applicationPoolName;physicalPath=$target.applicationRoot});
        runtimeSid=$target.runtimeIdentitySid;maxProcesses=1L;disallowOverlappingRotation=$true;enable32Bit=$false;workers=@();
        environment=@(@{name='ASPNETCORE_ENVIRONMENT';value='Production';scope='Pool'});ancmPath=$policy.appcmdPath;
        bindings=@(@{protocol='https';host='synthetic.invalid';port=443L;address='127.0.0.1'})}
    return @{workspace=$workspace;layout=$layout;policy=$policy;target=$target;targetKey=$key;controlRoot=$control;iis=$iis}
}
function Set-T2FixtureInModule {
    param($Fixture)
    & (Get-Module Clc.Deployment) { param($Fixture) $global:ClcTestFixture=$Fixture } $Fixture
}
function Set-T2Mocks {
    Mock -ModuleName Clc.Deployment Get-ClcInstalledLayout {
        if ($TargetId -cne $global:ClcTestFixture.target.targetId) { Invoke-T2Private Stop-ClcError @('Clc.ToolkitNotActive') }
        return $global:ClcTestFixture.layout
    }
    Mock -ModuleName Clc.Deployment Get-ClcCallerSid { return 'S-1-5-19' }
    # Synthetic host only: no claim about the CI/workstation token or runtime.
    Mock -ModuleName Clc.Deployment Test-ClcAdministratorToken { return $true }
    Mock -ModuleName Clc.Deployment Assert-ClcRuntimeIdentity { }
    Mock -ModuleName Clc.Deployment Assert-ClcAccess { return (Invoke-T2Private Get-ClcSecurityObservation @($Path)).sha256 }
    Mock -ModuleName Clc.Deployment Assert-ClcTrustAncestors { }
    Mock -ModuleName Clc.Deployment Get-ClcMachineUuidObservation { return $global:ClcTestFixture.policy.machineIdentity }
    Mock -ModuleName Clc.Deployment Get-ClcIisPoolNames { return @($global:ClcTestFixture.target.applicationPoolName) }
    Mock -ModuleName Clc.Deployment Get-ClcIisObservation { return $global:ClcTestFixture.iis }
}
function Get-T2TreeHashes {
    param($Fixture)
    $hashes=[ordered]@{}
    foreach ($file in Get-ChildItem -LiteralPath $Fixture.workspace -Recurse -File) {
        if ($file.DirectoryName -ceq $Fixture.policy.lockRoot) { continue } # Owner's FileShare.None is intentional.
        $hashes[$file.FullName.Substring($Fixture.workspace.Length)]=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    return $hashes | ConvertTo-Json -Compress
}
function New-T2PreparedRecord {
    param($Lock)
    $j=Get-Content -LiteralPath (Join-Path $script:FixtureRoot 'journal.json') -Raw | ConvertFrom-Json -AsHashtable -DateKind String
    $j.targetKey=$Lock.identity.targetKey; $j.targetSnapshot=$Lock.identity.snapshot; $j.executingToolkit=$Lock.context.executingToolkit
    $j.policyGeneration=$Lock.context.policyFile.record.generation; $j.policySha256=$Lock.context.policyFile.sha256
    $j.phase='Prepared'; $j.outcome=$null; $j.liveMutationIntent=$false; $j.intent.operation='Stage'; $j.observation=$null
    $j.nativeCall=$null; $j.backup=$null; $j.recovery=$null; $j.publishedGeneration=$null; $j.failure=$null
    return $j
}
function New-T2Approval {
    param($Fixture)
    $inputs=New-TestPublish $Fixture.workspace
    $package=New-ClcRelease @inputs
    $approval=Get-Content -LiteralPath (Join-Path $script:FixtureRoot 'release-approval.json') -Raw | ConvertFrom-Json -AsHashtable -DateKind String
    $metadata=Get-TestMetadata
    $approval.targetId=$Fixture.target.targetId; $approval.applicationId=$metadata.applicationId; $approval.releaseId=$metadata.releaseId
    $approval.sourceRepository=$metadata.source.repository; $approval.sourceCommit=$metadata.source.commit
    $approval.releaseZipSha256=$package.archiveSha256; $approval.manifestSha256=$package.manifestSha256
    $approval.provenance.workflowPath=$metadata.build.workflowPath; $approval.provenance.runId=$metadata.build.runId
    $approval.provenance.runAttempt=$metadata.build.runAttempt; $approval.provenance.buildJob=$metadata.build.job
    $path=Join-Path $Fixture.layout.approvalCatalogRoot ($approval.approvalId+'.json')
    Write-TestJson $path $approval
    Copy-Item -LiteralPath $package.archivePath -Destination (Join-Path $Fixture.target.artifactInboxRoot ($approval.approvalId+'.zip'))
    return @{record=$approval;path=$path;package=$package}
}

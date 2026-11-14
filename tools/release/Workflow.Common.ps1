# The OIDC claims here are a projection of a token fetched directly from the
# GitHub job endpoint by the pinned inline workflow bootstrap. Never accept a
# downloaded artifact as a substitute for that platform channel.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Release.Common.ps1')
# These readers are from the independently pinned workflow checkout. Candidate
# installed code is not imported to authenticate its own first execution.
foreach ($helper in @('Paths','Inventory','NativeProcess','Trust')) { . (Join-Path $PSScriptRoot ('../../src/CLC.Deployment/Private/'+$helper+'.ps1')) }

function Get-ClcWorkflowPolicyPath {
    return Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) 'CLC\Deployment\Enrollment\toolkit\policy\host-policy.json'
}
function Open-ClcWorkflowToolkit {
    $handles=[Collections.Generic.List[IDisposable]]::new()
    $context=$null
    try {
        $path=Get-ClcWorkflowPolicyPath
        # Same fixed first-authority rule as host enrollment. Never obtain this
        # first owner/writer allowlist from the policy being authenticated.
        $trusted=[string[]]@('S-1-5-18','S-1-5-32-544')
        $null=Get-ClcPathObservation $path $handles
        $null=Assert-ClcAccess $path $trusted $trusted @()
        $structural=[string[]]@($trusted+'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
        $cursor=[IO.Path]::GetDirectoryName($path)
        while ($cursor) {
            $security=Get-ClcSecurityObservation $cursor
            if ($structural -cnotcontains $security.ownerSid) { Stop-ClcError Clc.ToolkitNotActive }
            foreach ($ace in $security.dacl) {
                if ($ace.AceQualifier -eq [Security.AccessControl.AceQualifier]::AccessAllowed -and
                    ($ace.AceFlags -band [Security.AccessControl.AceFlags]::InheritOnly) -eq 0 -and
                    (([long]$ace.AccessMask -band 0x000D0040L) -ne 0 -or ([long]$ace.AccessMask -band 0xF0000000L) -ne 0) -and
                    $structural -cnotcontains $ace.SecurityIdentifier.Value) { Stop-ClcError Clc.ToolkitNotActive }
            }
            $cursor=[IO.Path]::GetDirectoryName($cursor)
        }
        $file=Read-ClcHeldRecord $path host-policy $handles; $policy=$file.record
        $root=[IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($path))
        $versionRoot=Join-Path $root ('versions\'+$policy.activeToolkit.version)
        $moduleRoot=Join-Path $versionRoot 'CLC.Deployment'
        $manifest=Join-Path $moduleRoot 'CLC.Deployment.psd1'
        if ($policy.activeToolkit.moduleManifestPath -cne $manifest) { Stop-ClcError Clc.ToolkitNotActive }
        $context=@{policyFile=$file;layout=@{root=$root;moduleRoot=$moduleRoot};handles=$handles;pathPins=@{};ancestorPins=@{};pinGeneration=0L;
            helperRuntimeSids=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);closed=$false}
        Assert-ClcDeploymentToken $policy
        foreach ($directory in @($root,(Join-Path $root 'versions'),$versionRoot,$moduleRoot)) { $null=Add-ClcProtectedPathPin $context $directory -Directory }
        Assert-ClcTrustAncestors $context $moduleRoot
        if ((Get-ClcToolkitInventory $context) -cne $policy.activeToolkit.inventorySha256) { Stop-ClcError Clc.ToolkitNotActive }
        foreach ($name in @('distribution.zip','source.commit')) { $null=Add-ClcProtectedPathPin $context (Join-Path $versionRoot $name) }
        $source=Read-ClcHeldFile (Join-Path $versionRoot 'source.commit') $handles 40
        if ([Text.Encoding]::UTF8.GetString($source.bytes) -cne $policy.activeToolkit.sourceCommit) { Stop-ClcError Clc.ToolkitNotActive }
        $null=& (Join-Path $PSScriptRoot '../Test-ToolkitDistribution.ps1') -ArchivePath (Join-Path $versionRoot 'distribution.zip') `
            -ExpectedSha256 $policy.activeToolkit.distributionSha256 -ExpectedSourceCommit $policy.activeToolkit.sourceCommit -ExpectedVersion $policy.activeToolkit.version -InstalledModuleRoot $moduleRoot
        # All installed executable files and policy bytes remain held against
        # write/delete while the authenticated import and host invocation run.
        Import-Module $manifest -Force -Global
        return @{policy=$policy;handles=$handles}
    } catch { foreach ($handle in $handles) { $handle.Dispose() }; throw }
}

function Assert-ClcWorkflowClaims {
    param($Claims,[string] $Repository,[ValidateSet('build','release','deploy')][string] $Workflow)
    Assert-ClcRepository $Repository
    foreach ($key in @('workflow_sha','job_workflow_sha')) { Assert-ClcCommit $Claims[$key] }
    $expected='clcdpc/clc-deployment/.github/workflows/application-'+$Workflow+'.yml@'+$Claims.job_workflow_sha
    if ($Claims.iss -cne 'https://token.actions.githubusercontent.com' -or $Claims.aud -cne 'clc-deployment' -or
        $Claims.repository -cne $Repository -or $Claims.job_workflow_ref -cne $expected -or
        $Claims.event_name -cnotin @('push','workflow_run','workflow_dispatch')) { throw 'Caller or immutable reusable workflow identity refused.' }
    Assert-ClcText $Claims.workflow_ref 512
}

function Read-ClcConfigurationAtRevision {
    param([string] $Repository,[string] $Revision,[string] $Directory,[scriptblock] $Api)
    Assert-ClcCommit $Revision
    $file=& $Api GET ('/repos/'+$Repository+'/contents/.clc/release.json?ref='+$Revision) $null
    if ($null -eq $file -or $file.type -cne 'file' -or $file.encoding -cne 'base64' -or $file.size -gt 65536) { throw 'Protected consumer configuration is unavailable.' }
    $bytes=[Convert]::FromBase64String($file.content)
    if ($bytes.Length -gt 65536) { throw 'Protected consumer configuration exceeds its bound.' }
    $path=Join-Path $Directory ([guid]::NewGuid().ToString('N')+'.json')
    [IO.File]::WriteAllBytes($path,$bytes)
    return @{configuration=(Read-ClcConsumerConfiguration $path);blob=$file.sha;path=$path}
}

function Get-ClcProtectedWorkflowConfiguration {
    param($Claims,[string] $Repository,[ValidateSet('build','release','deploy')][string] $Workflow,[string] $Directory,[scriptblock] $Api)
    Assert-ClcWorkflowClaims $Claims $Repository $Workflow
    $candidate=Read-ClcConfigurationAtRevision $Repository $Claims.workflow_sha $Directory $Api
    $c=$candidate.configuration
    if ($c.repository -cne $Repository -or -not $c.Contains('orchestration')) { throw 'Consumer orchestration identity is required.' }
    $branch=& $Api GET ('/repos/'+$Repository+'/branches/'+[Uri]::EscapeDataString($c.integrationBranch)) $null
    if ($branch.protected -isnot [bool] -or -not $branch.protected) { throw 'Caller integration branch is not protected.' }
    Assert-ClcCommit $branch.commit.sha
    $trusted=Read-ClcConfigurationAtRevision $Repository $branch.commit.sha $Directory $Api
    if ($trusted.blob -cne $candidate.blob -or $c.orchestration.sharedRevision -cne $Claims.job_workflow_sha) { throw 'Caller policy or shared revision differs from protected configuration.' }
    $callerPath=if ($Workflow -ceq 'build') {$c.producer.workflowPath} else {$c.orchestration.deploymentWorkflowPath}
    $expectedRef=$Repository+'/'+$callerPath+'@refs/heads/'+$c.integrationBranch
    if ($Workflow -ceq 'build') {
        # Build runs may execute eligible tag source on an isolated hosted runner.
        if (-not $Claims.workflow_ref.StartsWith($Repository+'/'+$callerPath+'@refs/',[StringComparison]::Ordinal)) { throw 'Producer workflow path is not approved.' }
    } elseif ($Claims.workflow_ref -cne $expectedRef) { throw 'Deployment orchestration must run from the protected integration branch.' }
    $path=($callerPath.Split('/') | ForEach-Object {[Uri]::EscapeDataString($_)}) -join '/'
    $a=& $Api GET ('/repos/'+$Repository+'/contents/'+$path+'?ref='+$Claims.workflow_sha) $null
    $b=& $Api GET ('/repos/'+$Repository+'/contents/'+$path+'?ref='+$branch.commit.sha) $null
    if ($null -eq $a -or $null -eq $b -or $a.type -cne 'file' -or $b.type -cne 'file' -or $a.sha -cne $b.sha) { throw 'Executing caller workflow differs from protected code.' }
    return $trusted
}

function Get-ClcQualifiedArtifactId {
    param($Configuration,[string] $SourceCommit,[long] $RunId,[long] $RunAttempt,[scriptblock] $Api)
    $name='clc-package-'+$SourceCommit+'-'+$RunId+'-'+$RunAttempt
    $artifacts=Get-ClcGitHubCollection $Api ('/repos/'+$Configuration.repository+'/actions/runs/'+$RunId+'/artifacts') artifacts
    $selected=@($artifacts | Where-Object {$_.name -ceq $name})
    if ($selected.Count -ne 1) { throw 'One exact qualified artifact is required.' }
    return [long]$selected[0].id
}

function Get-ClcDeploymentRoute {
    param($Configuration,$Source,[bool] $Automatic,$Claims,[scriptblock] $Api)
    if (-not $Automatic) {
        if ($Claims.event_name -cne 'workflow_dispatch') { throw 'Explicit redeployment requires protected workflow dispatch.' }
        $permission=& $Api GET ('/repos/'+$Configuration.repository+'/collaborators/'+[Uri]::EscapeDataString($Claims.actor)+'/permission') $null
        if ($permission.permission -cnotin @('write','maintain','admin')) { throw 'Explicit redeployment requires repository write authority.' }
    }
    if ($Automatic -and $Source.superseded) { return @{admitted=$false;status='Superseded'} }
    if ($Source.identity.channel -ceq 'ArtifactOnly') { return @{admitted=$false;status='ArtifactOnly'} }
    if (-not $Configuration.Contains('targets')) { throw 'No deployment target configuration is installed.' }
    $routes=@($Configuration.targets | Where-Object {$_.channel -ceq $Source.identity.channel})
    if ($routes.Count -ne 1 -or -not $routes[0].enabled -or -not $routes[0].runnerAdmissionReady) { return @{admitted=$false;status='ActivationDisabled'} }
    return @{admitted=$true;status='Admitted';target=$routes[0]}
}

function Get-ClcWorkflowRelease {
    param($Configuration,[string] $Reference,[string] $SourceCommit,[long] $RunId,[long] $RunAttempt,[long] $ArtifactId,[scriptblock] $Api)
    if ($Reference -ceq $Configuration.integrationBranch) { $Reference='refs/heads/'+$Reference }
    $source=Get-ClcVerifiedSource $Configuration $Reference $SourceCommit $RunId $Api
    if ($ArtifactId -eq 0) { $ArtifactId=Get-ClcQualifiedArtifactId $Configuration $SourceCommit $RunId $RunAttempt $Api }
    $producer=Get-ClcVerifiedProducer $Configuration $source $RunId $RunAttempt $ArtifactId $Api
    return @{source=$source;producer=$producer}
}

function Get-ClcQualifiedPublishInputs {
    param($Configuration,[string] $SourceRoot,[string] $PublishRoot,[string] $SdkVersion,[string] $ValidationEntryPoint)
    Assert-ClcAbsolutePath $PublishRoot; Assert-ClcVersion $SdkVersion
    if (-not $ValidationEntryPoint) {
        if (-not $Configuration.Contains('project')) { throw 'Prequalified packages without a project require a fixed validation DLL name.' }
        $project=Join-Path $SourceRoot $Configuration.project
        $assembly=[IO.Path]::GetFileNameWithoutExtension($project)
        $xml=[xml][IO.File]::ReadAllText($project)
        $names=@($xml.SelectNodes('/Project/PropertyGroup/AssemblyName') | ForEach-Object {$_.InnerText} | Select-Object -Unique)
        if ($names.Count -eq 1) { $assembly=$names[0] }
        $ValidationEntryPoint=$assembly+'.dll'
    }
    # Evaluated/custom AssemblyName values require the CI's explicit fixed DLL
    # selector. No script, inline command, argument list, or relative path runs.
    Assert-ClcText $ValidationEntryPoint 240 '^[A-Za-z0-9_-][A-Za-z0-9_.-]*\.dll$'
    $directory=if ($Configuration.Contains('project')) {[IO.Path]::GetDirectoryName((Join-Path $SourceRoot $Configuration.project))} else {$SourceRoot}
    $lock=Join-Path $directory 'packages.lock.json'
    if (-not [IO.File]::Exists($lock)) { throw 'Application dependency lock is required.' }
    return @{publishRoot=$PublishRoot;entryPoint=$ValidationEntryPoint;sdkVersion=$SdkVersion;dependencyLockPath=$lock}
}

# The OIDC claims here are a projection of a token fetched directly from the
# GitHub job endpoint by the pinned inline workflow bootstrap. Never accept a
# downloaded artifact as a substitute for that platform channel.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Release.Common.ps1')
function Assert-ClcWorkflowClaims {
    param($Claims,[string] $Repository,[ValidateSet('build','release','deploy')][string] $Workflow)
    Assert-ClcRepository $Repository
    foreach ($key in @('workflow_sha','job_workflow_sha')) { Assert-ClcCommit $Claims[$key] }
    $expected='clcdpc/clc-deployment/.github/workflows/application-'+$Workflow+'.yml@'+$Claims.job_workflow_sha
    if ($Claims.iss -cne 'https://token.actions.githubusercontent.com' -or $Claims.aud -cne 'clc-deployment' -or
        $Claims.repository -cne $Repository -or $Claims.job_workflow_ref -cne $expected -or
        $Claims.event_name -cne 'push') { throw 'Caller or immutable reusable workflow identity refused.' }
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
    if ($c.orchestration.sharedRevision -cne $Claims.job_workflow_sha) { throw 'Caller shared revision differs from tagged configuration.' }
    $prefix=$Repository+'/'+$c.producer.workflowPath+'@refs/tags/'
    if (-not $Claims.workflow_ref.StartsWith($prefix,[StringComparison]::Ordinal)) { throw 'Caller must execute the configured workflow at the release tag.' }
    $tag=$Claims.workflow_ref.Substring($prefix.Length)
    $null=Get-ClcVerifiedSource $c $tag $Claims.workflow_sha 1 $Api
    return $candidate
}

function Assert-ClcWorkflowSource {
    param($Claims,$Configuration,[string] $Reference,[string] $SourceCommit,[long] $RunId,[long] $RunAttempt)
    $tag=(Get-ClcApplicationTag $Reference).tag
    $currentAttempt=0L
    if (-not [long]::TryParse([string]$Claims.run_attempt,[ref]$currentAttempt)) { throw 'Invalid GitHub run attempt.' }
    if ($Claims.workflow_sha -cne $SourceCommit -or $Claims.workflow_ref -cne ($Configuration.repository+'/'+$Configuration.producer.workflowPath+'@refs/tags/'+$tag) -or
        [string]$Claims.run_id -cne [string]$RunId -or $RunAttempt -lt 1 -or $RunAttempt -gt $currentAttempt) { throw 'Executing tag, source or run differs from the selected producer, or its attempt has not run yet.' }
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
    param($Configuration,$Source)
    if ($Source.identity.channel -ceq 'ArtifactOnly') { return @{targetId=$null} }
    Assert-ClcEnum $Source.identity.channel @('DEV','Production')
    $id=$Configuration.applicationId+'-'+$Source.identity.channel.ToLowerInvariant()
    Assert-ClcId $id
    $runtimeEnvironment=if ($Source.identity.channel -ceq 'DEV') {$Configuration.devRuntimeEnvironment} else {'Production'}
    return @{targetId=$id;environment=$id;runtimeEnvironment=$runtimeEnvironment;runnerLabels=@('self-hosted','Windows','X64',$id)}
}

function Get-ClcWorkflowRelease {
    param($Configuration,[string] $Reference,[string] $SourceCommit,[long] $RunId,[long] $RunAttempt,[long] $ArtifactId,[scriptblock] $Api)
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
    if (-not [IO.File]::Exists($lock)) { $lock=$null }
    return @{publishRoot=$PublishRoot;entryPoint=$ValidationEntryPoint;sdkVersion=$SdkVersion;dependencyLockPath=$lock}
}

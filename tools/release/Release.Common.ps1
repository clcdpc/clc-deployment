# GitHub orchestration stays outside the installed host engine. These functions
# accept a narrow API boundary so qualification uses deterministic offline data.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../../src/CLC.Deployment/Private/Contracts.ps1')
. (Join-Path $PSScriptRoot '../../src/CLC.Deployment/Private/Automation.ps1')
. (Join-Path $PSScriptRoot '../SharedReleasePublisher.Common.ps1')
. (Join-Path $PSScriptRoot '../Probe.Metadata.ps1')

function Assert-ClcCompiledApplicationIdentity {
    param($Metadata,[string] $ApplicationId,[string] $ReleaseId,[string] $SourceCommit)
    if ($Metadata['Clc.ApplicationId'] -cne $ApplicationId -or $Metadata['Clc.ReleaseId'] -cne $ReleaseId -or
        $Metadata['Clc.SourceCommit'] -cne $SourceCommit -or $Metadata['Clc.IdentityKind'] -cne 'Release') { throw 'Compiled application identity differs from the tagged release.' }
}

function Read-ClcConsumerConfiguration {
    [CmdletBinding(DefaultParameterSetName='Path')]
    param([Parameter(Mandatory,Position=0,ParameterSetName='Path')][string] $Path,
        [Parameter(Mandatory,ParameterSetName='Bytes')][byte[]] $Bytes)
    if ($PSCmdlet.ParameterSetName -ceq 'Path') {
        if ((Get-Item -LiteralPath $Path).Length -gt 65536) { throw 'Consumer configuration exceeds its bound.' }
        $Bytes=[IO.File]::ReadAllBytes($Path)
    }
    if ($bytes.Length -gt 65536) { throw 'Consumer configuration exceeds its bound.' }
    $document=[Text.Json.JsonDocument]::Parse([ReadOnlyMemory[byte]]$bytes)
    try { $c=ConvertFrom-ClcJsonElement $document.RootElement } finally { $document.Dispose() }
    $keys=@('contractVersion','applicationId','repository','integrationBranch','producer','requiredToolkitContractVersion')
    if ($c.Contains('project')) { $keys+='project' }
    foreach ($optional in @('testProject','orchestration','hooks')) { if ($c.Contains($optional)) { $keys+=$optional } }
    Assert-ClcObject $c $keys
    Assert-ClcInteger $c.contractVersion 2 2
    Assert-ClcId $c.applicationId; Assert-ClcRepository $c.repository
    Assert-ClcText $c.integrationBranch 100 '^[A-Za-z0-9][A-Za-z0-9_/-]*$'
    # Both conventional routes must fit the existing host identifier contract.
    Assert-ClcId ($c.applicationId+'-dev'); Assert-ClcId ($c.applicationId+'-production')
    $producerKeys=@('workflowPath','job'); if ($c.producer.Contains('jobName')) {$producerKeys+='jobName'}
    Assert-ClcObject $c.producer $producerKeys
    Assert-ClcWorkflow $c.producer.workflowPath; Assert-ClcCode $c.producer.job
    if ($c.producer.Contains('jobName')) { Assert-ClcText $c.producer.jobName 128 '^[A-Za-z0-9][A-Za-z0-9 /_,.-]*$' }
    Assert-ClcInteger $c.requiredToolkitContractVersion 2 2
    foreach ($projectKey in @('project','testProject')) {
        if ($c.Contains($projectKey)) {
            Assert-ClcText $c[$projectKey] 240 '^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*\.csproj$'
            if ($c[$projectKey].Split('/') -contains '..') { throw 'Project path is invalid.' }
        }
    }
    if ($c.Contains('orchestration')) {
        Assert-ClcObject $c.orchestration @('sharedRevision')
        Assert-ClcCommit $c.orchestration.sharedRevision
    }
    if ($c.Contains('hooks')) {
        Assert-ClcObject $c.hooks @('contractVersion','stages','planningEntryPoint')
        Assert-ClcInteger $c.hooks.contractVersion 1 1
        if ($c.hooks.stages -isnot [array] -or $c.hooks.stages.Count -gt 4) { throw 'Hook stages must be a bounded array.' }
        $stages=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($hook in $c.hooks.stages) {
            Assert-ClcObject $hook @('stage','entryPoint'); Assert-ClcEnum $hook.stage @('Preflight','BeforeStop','AfterStop','AfterStart')
            if (-not $stages.Add($hook.stage)) { throw 'Duplicate lifecycle stage.' }
            Assert-ClcText $hook.entryPoint 240 '^hooks/[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*\.ps1$'
            if ($hook.entryPoint.Split('/') -contains '..') { throw 'Hook entry point is invalid.' }
        }
        if ($null -ne $c.hooks.planningEntryPoint) {
            Assert-ClcText $c.hooks.planningEntryPoint 240 '^hooks/[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*\.ps1$'
            if ($c.hooks.planningEntryPoint.Split('/') -contains '..') { throw 'Planning entry point is invalid.' }
            if (@($c.hooks.stages | ForEach-Object { $_.entryPoint }) -ccontains $c.hooks.planningEntryPoint) { throw 'Planning must have its own entry point.' }
        }
    }
    return $c
}

function Get-ClcApplicationTag {
    param([string] $Tag)
    $tagIdentity=Get-ClcDeploymentTag $Tag
    return @{tag=$tagIdentity.tag;releaseId=$tagIdentity.releaseId;channel=$tagIdentity.channel;sequence=$tagIdentity.releaseSequence}
}
function Get-ClcGitHubCollection {
    param([scriptblock] $Api,[string] $Path,[string] $Property)
    $items=[Collections.Generic.List[object]]::new()
    for ($page=1;$page -le 10;$page++) {
        $separator=if ($Path.Contains('?')) {'&'} else {'?'}
        $response=& $Api GET ($Path+$separator+'per_page=100&page='+$page) $null
        $values=if ($Property) {@($response[$Property])} else {@($response)}
        foreach ($value in $values) { $items.Add($value) }
        if ($values.Count -lt 100) { return ,$items.ToArray() }
    }
    throw 'GitHub collection exceeded its page bound.'
}

function Get-ClcVerifiedSource {
    param($Configuration,[string] $Reference,[string] $SourceCommit,[long] $ProducerRunId,[scriptblock] $Api)
    Assert-ClcCommit $SourceCommit; Assert-ClcInteger $ProducerRunId 1
    $c=$Configuration; $base='/repos/'+$c.repository
    $branch=& $Api GET ($base+'/branches/'+[Uri]::EscapeDataString($c.integrationBranch)) $null
    if ($branch.protected -isnot [bool] -or -not $branch.protected) { throw 'The integration branch must be protected.' }
    $integration=$branch.commit.sha; Assert-ClcCommit $integration
    $identity=Get-ClcApplicationTag $Reference
    $tag=$identity.tag; $releaseId=$identity.releaseId; $channel=$identity.channel; $sequence=$identity.sequence
    $ref=& $Api GET ($base+'/git/ref/tags/'+[Uri]::EscapeDataString($tag)) $null
    for ($depth=0;$ref.object.type -ceq 'tag' -and $depth -lt 5;$depth++) { $ref=& $Api GET ($base+'/git/tags/'+$ref.object.sha) $null }
    if ($ref.object.type -cne 'commit' -or $ref.object.sha -cne $SourceCommit) { throw 'The tag moved or names another source commit.' }
    $comparison=& $Api GET ($base+'/compare/'+$SourceCommit+'...'+$integration) $null
    # GitHub returns 404 for comparisons without a common ancestor. The peeled
    # tag already proves repository membership; DEV needs no ancestry gate.
    $witness=$integration; $integrated=$false
    if ($null -ne $comparison) {
        $witness=$comparison.merge_base_commit.sha; Assert-ClcCommit $witness
        if ($comparison.status -cnotin @('ahead','identical','behind','diverged')) { throw 'Source ancestry is unavailable.' }
        $integrated=$comparison.status -cin @('ahead','identical') -and $witness -ceq $SourceCommit
    }
    if ($channel -ceq 'Production' -and -not $integrated) { throw 'Source is outside the protected integration history.' }
    # Native repository actor/tag policies authorize this exact commit, including
    # its workflows and configuration. No PR or master file-equality gate.
    $sourceClass=if ($integrated) {'IntegrationTag'} elseif ($channel -ceq 'DEV') {'UnmergedDevTag'} else {$null}
    return @{identity=[ordered]@{contractVersion=1L;kind='tag';sourceClass=$sourceClass;repository=$c.repository;sourceCommit=$SourceCommit;reference=$tag;releaseId=$releaseId;channel=$channel;orderingKind='SemVer';sequence=$sequence;tag=$tag;integrationBranch=$c.integrationBranch;integrationCommit=$witness};superseded=$false}
}

function Get-ClcVerifiedProducer {
    param($Configuration,$Source,[long] $RunId,[long] $RunAttempt,[long] $ArtifactId,[scriptblock] $Api)
    $c=$Configuration; $s=$Source.identity; $base='/repos/'+$c.repository
    foreach ($number in @($RunId,$RunAttempt,$ArtifactId)) { Assert-ClcInteger $number 1 }
    $run=& $Api GET ($base+'/actions/runs/'+$RunId+'/attempts/'+$RunAttempt) $null
    if ($run.id -ne $RunId -or $run.run_attempt -ne $RunAttempt -or $run.status -cnotin @('in_progress','completed') -or
        ($run.status -ceq 'completed' -and $run.conclusion -cne 'success') -or ($run.status -ceq 'in_progress' -and $null -ne $run.conclusion) -or
        $run.head_sha -cne $s.sourceCommit -or $run.repository.full_name -cne $c.repository -or $run.head_repository.full_name -cne $c.repository -or $run.path -cne $c.producer.workflowPath -or $run.event -cne 'push') { throw 'Producer run identity or qualification does not match.' }
    if ($run.head_branch -cne $s.tag) { throw 'Producer run reference does not match.' }
    $jobs=Get-ClcGitHubCollection $Api ($base+'/actions/runs/'+$RunId+'/attempts/'+$RunAttempt+'/jobs') jobs
    $jobName=if ($c.producer.Contains('jobName')) {$c.producer.jobName} else {$c.producer.job}
    $producerJobs=@($jobs | Where-Object {$_.name -ceq $jobName})
    if ($producerJobs.Count -ne 1 -or $producerJobs[0].status -cne 'completed' -or $producerJobs[0].conclusion -cne 'success' -or $producerJobs[0].run_id -ne $RunId -or
        $producerJobs[0].head_sha -cne $s.sourceCommit) { throw 'Exact successful producer job is missing.' }
    $artifact=& $Api GET ($base+'/actions/artifacts/'+$ArtifactId) $null
    $expectedName='clc-package-'+$s.sourceCommit+'-'+$RunId+'-'+$RunAttempt
    if ($artifact.id -ne $ArtifactId -or $artifact.expired -isnot [bool] -or $artifact.expired -or $artifact.name -cne $expectedName -or
        $artifact.workflow_run.id -ne $RunId -or $artifact.workflow_run.head_sha -cne $s.sourceCommit -or $artifact.digest -cnotmatch '^sha256:[a-f0-9]{64}$' -or $artifact.size_in_bytes -le 0 -or $artifact.size_in_bytes -gt 1073741824) { throw 'Artifact ownership, attempt, digest or size does not match.' }
    # Artifacts are run-scoped; the attempt-suffixed name plus timestamp window
    # prevents a stale attempt from being substituted for the qualified attempt.
    $created=[DateTimeOffset]::Parse($artifact.created_at)
    $started=[DateTimeOffset]::Parse($producerJobs[0].started_at); $completed=[DateTimeOffset]::Parse($producerJobs[0].completed_at)
    if ($started -lt [DateTimeOffset]::Parse($run.run_started_at) -or $completed -lt $started -or $created -lt $started -or $created -gt $completed) { throw 'Artifact was not produced during the selected producer job attempt.' }
    return @{workflowPath=$c.producer.workflowPath;runId=$RunId;runAttempt=$RunAttempt;buildJob=$c.producer.job;artifactId=$ArtifactId;transportSha256=$artifact.digest.Substring(7);artifactName=$expectedName}
}

function Invoke-ClcReleaseApi {
    param([string] $Repository,[string] $Method,[string] $Path,$Body=$null,[switch] $Bytes)
    if (-not $Path.StartsWith('/repos/'+$Repository+'/',[StringComparison]::Ordinal)) { throw 'API path is outside the selected repository.' }
    $client=New-SharedReleaseHttpClient
    $client.Timeout=[TimeSpan]::FromSeconds(60); $client.DefaultRequestHeaders.UserAgent.ParseAdd('clc-application-release/1')
    $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method),'https://api.github.com'+$Path)
    $request.Headers.Accept.ParseAdd($(if ($Bytes) {'application/octet-stream'} else {'application/vnd.github+json'}))
    $request.Headers.Add('X-GitHub-Api-Version','2022-11-28')
    try {
        if ($null -ne $Body) { $request.Content=[Net.Http.StringContent]::new(($Body | ConvertTo-Json -Depth 20 -Compress),[Text.Encoding]::UTF8,'application/json') }
        $actionsDownload=$Path -cmatch ('\A/repos/'+[regex]::Escape($Repository)+'/actions/artifacts/[1-9][0-9]*/zip\z')
        $response=Send-SharedReleaseHttpRequest -Client $client -Request $request -Repository $Repository -GitHubToken $env:GH_TOKEN -GitHubAuthorization -AllowActionsStorageRedirect:$actionsDownload -AllowedRedirectHosts @('api.github.com','release-assets.githubusercontent.com','objects.githubusercontent.com','results-receiver.actions.githubusercontent.com')
        try {
            if ([int]$response.StatusCode -eq 404) { return $null }
            if (-not $response.IsSuccessStatusCode) { throw ('GitHub request refused; status '+[int]$response.StatusCode+'.') }
            $limit=if ($Bytes) {1073741824L} else {4194304L}
            $bytes=Read-SharedReleaseBoundedResponseBytes $response.Content $limit
            if ($Bytes) { return ,$bytes }
            return [Text.UTF8Encoding]::new($false,$true).GetString($bytes) | ConvertFrom-Json -AsHashtable -DateKind String
        } finally { $response.Dispose() }
    } finally { $request.Dispose(); $client.Dispose() }
}

function Save-ClcVerifiedArtifact {
    param([string] $Repository,$Provenance,[string] $DestinationDirectory,[scriptblock] $Api)
    if ([IO.Directory]::Exists($DestinationDirectory) -or [IO.File]::Exists($DestinationDirectory)) { throw 'Artifact destination must be new.' }
    $bytes=& $Api GET ('/repos/'+$Repository+'/actions/artifacts/'+$Provenance.artifactId+'/zip') $null -Bytes
    if ($null -eq $bytes -or $bytes.Length -gt 1073741824 -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]$bytes)).ToLowerInvariant() -cne $Provenance.transportSha256) { throw 'Downloaded Actions artifact digest differs from GitHub provenance.' }
    $stream=[IO.MemoryStream]::new([byte[]]$bytes,$false)
    $zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Read,$false)
    try {
        if ($zip.Entries.Count -ne 1 -or $zip.Entries[0].FullName -cne 'release.zip' -or $zip.Entries[0].Length -le 0 -or $zip.Entries[0].Length -gt 1073741824 -or
            $zip.Entries[0].ExternalAttributes -band 0x410 -or $zip.Entries[0].Length -gt ([Math]::Max(1L,$zip.Entries[0].CompressedLength)*100L)) { throw 'Qualified artifact must contain only a bounded release.zip.' }
        $null=[IO.Directory]::CreateDirectory($DestinationDirectory)
        $path=Join-Path $DestinationDirectory 'release.zip'
        $input=$zip.Entries[0].Open(); $output=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try {
            $buffer=[byte[]]::new(65536); $total=0L; $watch=[Diagnostics.Stopwatch]::StartNew()
            while (($count=$input.Read($buffer,0,$buffer.Length)) -gt 0) {
                $total+=$count
                if ($total -gt $zip.Entries[0].Length -or $watch.Elapsed.TotalSeconds -gt 300) { throw 'Artifact extraction exceeded its bound.' }
                $output.Write($buffer,0,$count)
            }
            if ($total -ne $zip.Entries[0].Length) { throw 'Artifact entry length is inconsistent.' }
            $output.Flush($true)
        } finally { $input.Dispose(); $output.Dispose() }
        return $path
    } finally { $zip.Dispose(); $stream.Dispose() }
}

function New-ClcVerifiedPackageIdentity {
    param($Configuration,$Source,$Provenance,[string] $ArchivePath,[string] $TargetId)
    $stream=[IO.File]::Open($ArchivePath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $zip=$null
    try {
        $inspection=Test-ClcRelease -ArchivePath $ArchivePath
        if ($inspection.packageContractVersion -ne 2) { throw 'Shared routine orchestration requires package contract version 2.' }
        $zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Read,$true)
        $input=$zip.GetEntry('manifest.json').Open(); $reader=[IO.StreamReader]::new($input,[Text.UTF8Encoding]::new($false,$true))
        try { $manifest=$reader.ReadToEnd() | ConvertFrom-Json -AsHashtable -DateKind String } finally { $reader.Dispose() }
        $entry=$zip.GetEntry('application/'+$manifest.validation.entryPoint)
        if ($null -eq $entry -or $entry.Length -gt 268435456) { throw 'Compiled application identity is unavailable or exceeds its bound.' }
        $input=$entry.Open(); $assembly=[IO.MemoryStream]::new()
        try {
            $input.CopyTo($assembly); $assembly.Position=0
            $embedded=[Clc.Probe.Metadata]::Read($assembly)
            Assert-ClcCompiledApplicationIdentity $embedded $Configuration.applicationId $Source.identity.releaseId $Source.identity.sourceCommit
        } finally { $input.Dispose(); $assembly.Dispose() }
    } finally { if ($null -ne $zip) { $zip.Dispose() }; $stream.Dispose() }
    $s=$Source.identity; $p=$Provenance
    if ($inspection.applicationId -cne $Configuration.applicationId -or $inspection.releaseId -cne $s.releaseId -or $inspection.sourceCommit -cne $s.sourceCommit -or
        $manifest.source.repository -cne $s.repository -or $manifest.build.workflowPath -cne $p.workflowPath -or $manifest.build.runId -ne $p.runId -or $manifest.build.runAttempt -ne $p.runAttempt -or $manifest.build.job -cne $p.buildJob) { throw 'Package bytes do not bind the qualified source and producer.' }
    if (-not $Configuration.Contains('orchestration') -or $manifest.builder.sourceCommit -cne $Configuration.orchestration.sharedRevision) { throw 'Package builder revision differs from protected orchestration.sharedRevision.' }
    $provenance=[ordered]@{}; foreach ($field in @('workflowPath','runId','runAttempt','buildJob','artifactId','transportSha256')) { $provenance[$field]=$p[$field] }
    return [ordered]@{contractFamily='clc-file-iis-v1';schemaVersion=2L;recordKind='verified-release';targetId=$TargetId;applicationId=$Configuration.applicationId;
        releaseId=$s.releaseId;tag=$s.reference;sourceRepository=$s.repository;sourceCommit=$s.sourceCommit;releaseZipSha256=$inspection.archiveSha256;manifestSha256=$inspection.manifestSha256;provenance=$provenance;sourceIdentity=$s}
}

function Invoke-ClcApplicationPublication {
    param($Identity,$Assets,[scriptblock] $Api,[scriptblock] $AssetHash,[scriptblock] $Upload)
    if ($Identity.kind -cne 'tag') { throw 'Branch snapshots retain Actions artifacts and do not create GitHub Releases.' }
    $tag=Get-ClcApplicationTag $Identity.tag
    if ($tag.releaseId -cne $Identity.releaseId -or $tag.channel -cne $Identity.channel) { throw 'Publication identity is inconsistent.' }
    $sharedIdentity=@{repository=$Identity.repository;tag=$Identity.tag;sourceCommit=$Identity.sourceCommit;prerelease=($Identity.channel -cne 'Production')}
    return Invoke-SharedReleaseGitHubPublication $sharedIdentity $Assets $Api $AssetHash $Upload
}
function Send-ClcApplicationReleaseAsset {
    param([string] $Repository,$Release,$Asset)
    $expected='https://uploads.github.com/repos/'+$Repository+'/releases/'+$Release.id+'/assets{?name,label}'
    if ($Release.upload_url -cne $expected) { throw 'Release upload endpoint conflicts with repository identity.' }
    $uri=$expected.Substring(0,$expected.IndexOf('{'))+'?name='+[Uri]::EscapeDataString($Asset.name)
    $client=New-SharedReleaseHttpClient; $client.Timeout=[TimeSpan]::FromMinutes(10); $client.DefaultRequestHeaders.UserAgent.ParseAdd('clc-application-release/1')
    $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post,$uri)
    try {
        $input=[IO.File]::Open($Asset.path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $request.Content=[Net.Http.StreamContent]::new($input)
        if ($input.Length -ne $Asset.length -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($input)).ToLowerInvariant() -cne $Asset.sha256) { throw 'Asset changed before upload.' }
        $input.Position=0; $request.Content.Headers.ContentType=[Net.Http.Headers.MediaTypeHeaderValue]::new('application/octet-stream')
        $response=Send-SharedReleaseHttpRequest -Client $client -Request $request -Repository $Repository -GitHubToken $env:GH_TOKEN -GitHubAuthorization -AllowedRedirectHosts @('uploads.github.com')
        try { if (-not $response.IsSuccessStatusCode) { throw 'Asset upload refused.' } } finally { $response.Dispose() }
    } finally { $request.Dispose(); $client.Dispose() }
}

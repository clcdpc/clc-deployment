Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../Distribution.Common.ps1"
. "$PSScriptRoot/../release/Release.Common.ps1"
. "$PSScriptRoot/Reporting.ps1"

function Get-ClcDeploymentPrerequisiteApi {
    param($Context, [string] $Path)
    # No URLs from response bodies, caller-supplied endpoints, redirects or non-GET requests.
    if ($Path -cnotmatch '^/(repos|orgs)/[A-Za-z0-9_.%/?=&-]+$') { throw 'Invalid internal API path.' }
    $Context.requests++
    if ($Context.requests -gt 150 -or $Context.timer.Elapsed.TotalSeconds -gt 240) {
        return @{ ok=$false; code=0; reason='The bounded API request/time budget was exhausted.' }
    }
    try {
        $response = $Context.client.GetAsync('https://api.github.com' + $Path).GetAwaiter().GetResult()
        try {
            $code = [int]$response.StatusCode
            if ($code -ne 200) {
                $reason = switch ($code) {
                    401 { 'GitHub authentication is unavailable or expired.' }
                    403 { 'GitHub denied access (permissions, plan/policy, or rate limit).' }
                    404 { 'GitHub returned not found; this may conceal an inaccessible administrative resource.' }
                    429 { 'GitHub rate limited the request.' }
                    default { 'GitHub returned an unexpected API status; configuration was not determined.' }
                }
                return @{ ok=$false; code=$code; reason=$reason }
            }
            $bytes=$response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
            $null=Read-DistJson $bytes
            $data=[Text.UTF8Encoding]::new($false,$true).GetString($bytes) | ConvertFrom-Json -AsHashtable -Depth 64 -NoEnumerate -DateKind String
            return @{ ok=$true; code=200; data=$data; reason='' }
        } finally { $response.Dispose() }
    } catch {
        # Never emit exceptions: they can include headers, private response bodies or variable values.
        return @{ ok=$false; code=0; reason='GitHub transport, response-size, timeout or JSON failure; retry validation.' }
    }
}

function Get-ClcDeploymentPrerequisiteCollection {
    param($Context, [string] $Path, [string] $Property = '', [ValidateRange(1,100)][int] $PageSize = 100)
    $items = [Collections.Generic.List[object]]::new()
    $total=$null
    for ($page=1; $page -le 20; $page++) {
        $separator = if ($Path.Contains('?')) { '&' } else { '?' }
        $response = Get-ClcDeploymentPrerequisiteApi $Context ($Path + $separator + "per_page=$PageSize&page=" + $page)
        if (-not $response.ok) { return $response }
        $data = $response.data
        if ($Property) {
            if ($data -isnot [Collections.IDictionary] -or -not $data.Contains($Property)) { break }
            if ($data.Contains('total_count')) {
                $observed=$data['total_count']
                if (($observed -isnot [int] -and $observed -isnot [long]) -or $observed -lt 0 -or ($null -ne $total -and $total -ne $observed)) { break }
                $total=$observed
            }
            $data = $data[$Property]
        }
        if ($data -isnot [array]) { break }
        foreach ($item in $data) { $items.Add($item) }
        if ($null -ne $total -and ($items.Count -gt $total -or ($data.Count -lt $PageSize -and $items.Count -ne $total))) { break }
        if ($data.Count -lt $PageSize -or ($null -ne $total -and $items.Count -eq $total)) {
            return @{ ok=$true; code=200; data=$items.ToArray(); reason='' }
        }
    }
    return @{ ok=$false; code=0; reason='GitHub collection was incomplete, malformed or exceeded the 2,000-item bound.' }
}

function ConvertFrom-ClcDeploymentPrerequisiteYamlNode {
    param($Node, $Budget, [int] $Depth = 0)
    if ($Depth -gt 32 -or ++$Budget.nodes -gt 20000) { throw 'UnsupportedYaml' }
    if ((-not $Budget.allowAnchors -and -not $Node.Anchor.IsEmpty) -or (-not $Node.Tag.IsEmpty -and $Node.Tag.Value -notin @('tag:yaml.org,2002:map','tag:yaml.org,2002:seq','tag:yaml.org,2002:str','tag:yaml.org,2002:null','tag:yaml.org,2002:bool','tag:yaml.org,2002:int'))) { throw 'UnsupportedYaml' }
    switch ($Node.NodeType.ToString()) {
        Scalar { return [string]$Node.Value }
        Mapping {
            $map = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
            foreach ($pair in $Node.Children.GetEnumerator()) {
                if ($pair.Key.NodeType.ToString() -cne 'Scalar' -or $pair.Key.Value -ceq '<<') { throw 'UnsupportedYaml' }
                $key = [string]$pair.Key.Value
                if ($map.Contains($key)) { Stop-ClcDeploymentPrerequisiteObservation FAIL 'The observed YAML contains duplicate keys, multiple documents or an invalid root mapping.' }
                $map.Add($key,(ConvertFrom-ClcDeploymentPrerequisiteYamlNode $pair.Value $Budget ($Depth+1)))
            }
            return ,$map
        }
        Sequence {
            $items = @($Node.Children | ForEach-Object { ConvertFrom-ClcDeploymentPrerequisiteYamlNode $_ $Budget ($Depth+1) })
            return ,$items
        }
        default { throw 'UnsupportedYaml' }
    }
}

function ConvertFrom-ClcDeploymentPrerequisiteYaml {
    param([string] $Text, [switch] $AllowAnchors)
    if ([Text.Encoding]::UTF8.GetByteCount($Text) -gt 262144) { throw 'UnsupportedYaml' }
    # Bound the event stream before the representation loader resolves nodes/aliases.
    $preflight=[IO.StringReader]::new($Text)
    try {
        $parser=[YamlDotNet.Core.Parser]::new($preflight)
        $events=0; $depth=0
        while ($parser.MoveNext()) {
            if (++$events -gt 40000) { throw 'UnsupportedYaml' }
            $event=$parser.Current
            $kind=$event.GetType().Name
            if ($kind -cin @('MappingStart','SequenceStart')) { if (++$depth -gt 32) { throw 'UnsupportedYaml' } }
            if ($kind -cin @('MappingEnd','SequenceEnd')) { $depth-- }
            if (-not $AllowAnchors -and $kind -ceq 'AnchorAlias') { throw 'UnsupportedYaml' }
            if ($event -is [YamlDotNet.Core.Events.NodeEvent] -and ((-not $AllowAnchors -and -not $event.Anchor.IsEmpty) -or -not $event.Tag.IsEmpty)) { throw 'UnsupportedYaml' }
        }
    } finally { $preflight.Dispose() }
    $budget = @{nodes=0;allowAnchors=[bool]$AllowAnchors}
    $stream = [YamlDotNet.RepresentationModel.YamlStream]::new()
    $reader = [IO.StringReader]::new($Text)
    try { $stream.Load($reader) } finally { $reader.Dispose() }
    if ($stream.Documents.Count -ne 1) { Stop-ClcDeploymentPrerequisiteObservation FAIL 'The observed YAML contains duplicate keys, multiple documents or an invalid root mapping.' }
    $value = ConvertFrom-ClcDeploymentPrerequisiteYamlNode $stream.Documents[0].RootNode $budget
    if ($value -isnot [Collections.IDictionary]) { Stop-ClcDeploymentPrerequisiteObservation FAIL 'The observed YAML contains duplicate keys, multiple documents or an invalid root mapping.' }
    return ,$value
}

function Get-ClcDeploymentPrerequisiteFile {
    param($Context, [string] $Repository, [string] $Path, [string] $Commit)
    $response = Get-ClcDeploymentPrerequisiteApi $Context "/repos/$Repository/contents/$($Path)?ref=$Commit"
    if (-not $response.ok) { return $response }
    $file = $response.data
    if ($file -isnot [Collections.IDictionary] -or $file['type'] -cne 'file' -or $file['encoding'] -cne 'base64' -or ($file['size'] -isnot [int] -and $file['size'] -isnot [long]) -or $file['size'] -lt 0 -or $file['size'] -gt 262144) {
        return @{ ok=$false; code=0; reason='Workflow/configuration file is not a bounded regular UTF-8 file.' }
    }
    try {
        $bytes=[Convert]::FromBase64String($file['content'])
        if ($bytes.Length -ne $file['size'] -or $bytes.Length -gt 262144) {throw 'Invalid file observation length.'}
        $text = [Text.UTF8Encoding]::new($false,$true).GetString($bytes)
        return @{ ok=$true; code=200; text=$text }
    } catch { return @{ ok=$false; code=0; reason='GitHub file encoding could not be inspected.' } }
}

function Test-ClcDeploymentPrerequisiteInputs {
    param($Config)
    if ($Config.Repository -cnotmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}$') { throw 'Invalid repository identity.' }
    if ($Config.IntegrationBranch -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_./-]{0,127}$' -or $Config.IntegrationBranch -match '\.\.|//|/\.|\.lock$|[/.]$') { throw 'Invalid integration branch.' }
    foreach ($path in @($Config.ReleaseWorkflow,$Config.DeploymentWorkflow)) {
        if ($path -cnotmatch '^\.github/workflows/[A-Za-z0-9_-][A-Za-z0-9_.-]{0,100}\.ya?ml$' -or $path.Contains('..')) { throw 'Invalid workflow path.' }
    }
    if ($Config.ContainsKey('DiagnosticWorkflow') -and $Config.DiagnosticWorkflow -and ($Config.DiagnosticWorkflow -cnotmatch '^\.github/workflows/[A-Za-z0-9_-][A-Za-z0-9_.-]{0,100}\.ya?ml$' -or $Config.DiagnosticWorkflow.Contains('..'))) { throw 'Invalid diagnostic workflow path.' }
    if ($Config.ContainsKey('SharedRevision') -and $Config.SharedRevision -and $Config.SharedRevision -cnotmatch '^[a-f0-9]{40}$') { throw 'Invalid reviewed shared revision.' }
    foreach ($name in @($Config.EnvironmentName,$Config.RunnerGroup)) {
        if ($name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_. -]{0,99}$') { throw 'Environment name and runner group are required safe names.' }
    }
    if ($Config.ActivationVariable -cnotmatch '^[A-Z_][A-Z0-9_]{0,63}$' -or $Config.ActivationVariable -cmatch '^(GITHUB_|RUNNER_)') { throw 'Invalid activation variable name.' }
    if ($Config.DeploymentChannel -cnotin @('DEV','Test','Production')) { throw 'Deployment channel must be DEV, Test or Production.' }
    foreach ($key in @('ApplicationId','TargetId')) {
        if (-not $Config.ContainsKey($key) -or $Config[$key] -cnotmatch '^[a-z0-9][a-z0-9-]{0,63}$') { throw 'Invalid application or target selector.' }
    }
    if ($Config.ActivationState -cnotin @('enabled','disabled','missing-or-empty','invalid','unavailable')) { throw 'Invalid activation observation.' }
    $labels = @($Config.RunnerLabels.Split(','))
    if ($labels.Count -gt 10 -or @($labels | Where-Object { $_ -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$' }).Count) { throw 'Invalid comma-separated runner labels.' }
}

function Get-ClcDeploymentPrerequisiteBranchChecks {
    param($Context, $Config, $Branch)
    $action="Protect $($Config.IntegrationBranch) in Settings > Rules: require CI status checks and restrict force pushes, deletion and broad bypass actors."
    $path="/repos/$($Config.Repository)"
    $encoded=[uri]::EscapeDataString($Config.IntegrationBranch)
    $classic=Get-ClcDeploymentPrerequisiteApi $Context "$path/branches/$encoded/protection"
    $effective=Get-ClcDeploymentPrerequisiteCollection $Context "$path/rules/branches/$encoded"
    $rules=if ($effective.ok) {@($effective.data)} else {@()}
    $p=if ($classic.ok -and $classic.data -is [Collections.IDictionary]) {$classic.data} else {@{}}
    $complete=$effective.ok -and ($classic.ok -or ($classic.code -eq 404 -and $Branch['protected'] -eq $false))
    $status=if ($Branch['protected'] -isnot [bool]) {'UNVERIFIED'} elseif ($Branch['protected']) {'PASS'} else {'FAIL'}
    New-ClcDeploymentPrerequisiteCheck 'github.branch.protection' $status 'The integration branch protected flag was inspected at the selected branch.' $action -Name 'Integration branch protection'
    foreach ($item in @(@('force-push','allow_force_pushes','non_fast_forward'),@('deletion','allow_deletions','deletion'))) {
        $flag=$p[$item[1]]
        $present=($flag -is [Collections.IDictionary] -and $flag['enabled'] -is [bool] -and -not $flag['enabled']) -or @($rules | Where-Object {$_['type'] -ceq $item[2]}).Count -gt 0
        $status=if ($present) {'PASS'} elseif ($complete) {'FAIL'} else {'UNVERIFIED'}
        New-ClcDeploymentPrerequisiteCheck "github.branch.$($item[0])" $status 'Observed classic protection and active applicable rules were checked for this restriction.' $action -Name "Branch $($item[0]) restriction"
    }
    $ci=$p['required_status_checks']
    $ciRules=@($rules | Where-Object {$_['type'] -ceq 'required_status_checks'})
    $checks=@(@(if ($ci -is [Collections.IDictionary]) {@($ci['contexts']); @($ci['checks'])}) | Where-Object {$null -ne $_})
    foreach ($rule in $ciRules) {$checks+=@($rule['parameters']['required_status_checks']) | Where-Object {$null -ne $_}}
    $status=if ($checks.Count -gt 0) {'PASS'} elseif ($complete) {'FAIL'} else {'UNVERIFIED'}
    New-ClcDeploymentPrerequisiteCheck 'github.branch.required-checks' $status 'Required CI checks were inspected in classic protection and active rules.' $action -Name 'Required CI protections'
    $bypassKnown=$complete; $broad=$false
    foreach ($id in @($rules | Where-Object {$_.Contains('ruleset_id')} | ForEach-Object {$_['ruleset_id']} | Select-Object -Unique)) {
        if ($id -isnot [long] -and $id -isnot [int]) {$bypassKnown=$false;continue}
        $detail=Get-ClcDeploymentPrerequisiteApi $Context "$path/rulesets/$($id)?includes_parents=true"
        if (-not $detail.ok -or $detail.data['bypass_actors'] -isnot [array]) {$bypassKnown=$false;continue}
        if (@($detail.data['bypass_actors'] | Where-Object {$_['actor_type'] -ceq 'RepositoryRole'}).Count) {$broad=$true}
    }
    $status=if ($broad) {'FAIL'} elseif ($bypassKnown) {'PASS'} else {'UNVERIFIED'}
    New-ClcDeploymentPrerequisiteCheck 'github.branch.bypass' $status 'Observable applicable branch bypass settings were checked; broad repository-role bypass is not suitable for protected deployment source.' $action -Name 'Branch bypass restrictions'
    $pr=$p['required_pull_request_reviews']
    New-ClcDeploymentPrerequisiteCheck 'github.branch.reviews' PASS $(if ($null -ne $pr) {'Optional PR review controls are configured. No universal reviewer count or CODEOWNERS approval is required by commissioning.'} else {'No mandatory PR review or CODEOWNERS control is required by this checker.'}) -Name 'Optional branch reviews'
}

function Get-ClcDeploymentPrerequisiteTagChecks {
    param($Context, $Config, $SourcePolicy)
    $path="/repos/$($Config.Repository)/rulesets"
    $list=Get-ClcDeploymentPrerequisiteCollection $Context "$($path)?includes_parents=true"
    $action="Configure active tag creation/update/deletion restrictions for the selected $($Config.DeploymentChannel) version tags, with only independently controlled release bypass actors."
    $patterns=switch -CaseSensitive ($Config.DeploymentChannel) {
        DEV {@('refs/tags/v*-dev.*')}; Test {@('refs/tags/v*-beta.*','refs/tags/v*-rc.*')}; Production {@('refs/tags/v*')}
    }
    $found=@{};foreach ($pattern in $patterns) {$found[$pattern]=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)}
    $unknown=-not $list.ok; $bypassKnown=$list.ok; $broad=$false; $actors=$false
    if ($list.ok) { foreach ($entry in $list.data) {
        if ($entry['id'] -isnot [long] -and $entry['id'] -isnot [int]) {$unknown=$true;continue}
        $response=Get-ClcDeploymentPrerequisiteApi $Context "$path/$($entry['id'])?includes_parents=true"
        if (-not $response.ok) {$unknown=$true;$bypassKnown=$false;continue}
        $rule=$response.data
        if ($rule -isnot [Collections.IDictionary]) {$unknown=$true;continue}
        if ($rule['target'] -cne 'tag' -or $rule['enforcement'] -cne 'active') {continue}
        $refs=$rule['conditions']['ref_name']
        if ($null -eq $refs -or $refs['include'] -isnot [array] -or $refs['exclude'] -isnot [array]) {$unknown=$true;continue}
        if (@($refs['exclude']).Count) {$unknown=$true;continue}
        $applicable=@($patterns | Where-Object {$pattern=$_; @($refs['include'] | Where-Object {$_ -cin @('~ALL','refs/tags/*','refs/tags/v*',$pattern)}).Count -gt 0})
        if (-not $applicable.Count) {continue}
        if ($rule['bypass_actors'] -isnot [array]) {$bypassKnown=$false}
        else {
            $actors=$actors -or $rule['bypass_actors'].Count -gt 0
            if (@($rule['bypass_actors'] | Where-Object {$_['actor_type'] -ceq 'RepositoryRole'}).Count) {$broad=$true}
        }
        if ($rule['rules'] -isnot [array]) {$unknown=$true;continue}
        foreach ($pattern in $applicable) {foreach ($item in $rule['rules']) {if ($item['type'] -cin @('creation','update','deletion')) {[void]$found[$pattern].Add($item['type'])}}}
    }}
    foreach ($type in @('creation','update','deletion')) {
        $covered=@($patterns | Where-Object {-not $found[$_].Contains($type)}).Count -eq 0
        $status=if ($covered) {'PASS'} elseif ($unknown) {'UNVERIFIED'} else {'FAIL'}
        New-ClcDeploymentPrerequisiteCheck "github.tags.$type" $status "Active rules were inspected for $type of selected-channel version tags; evaluate-only rules do not enforce protection." $action -Name "Release tag $type restriction"
    }
    $status=if ($broad) {'FAIL'} elseif (-not $bypassKnown -or $unknown) {'UNVERIFIED'} else {'PASS'}
    New-ClcDeploymentPrerequisiteCheck 'github.tags.bypass' $status 'Observable tag bypass restrictions were inspected; unrestricted repository-role bypass broadens release admission.' $action -Name 'Tag bypass restrictions'
    New-ClcDeploymentPrerequisiteCheck 'github.tags.authority' UNVERIFIED $(if ($actors) {'Configured release bypass actors still require infrastructure ownership; API settings do not prove their future behavior.'} else {'API observations do not prove future release-producer or administrator behavior.'}) 'Retain independent control of release producers and authorized bypass identities.' -Name 'Release authority limitation'
}

function Get-ClcDeploymentPrerequisiteWorkflowObservation {
    param($Context,$Config,[string] $Path,[string] $Commit,[string] $Id)
    $action="Correct $Path at the protected integration branch; use the expected producer or deployment caller."
    $file=Get-ClcDeploymentPrerequisiteFile $Context $Config.Repository $Path $Commit
    if (-not $file.ok) {
        # Contents 404 on an identity-verified readable source is a missing required file.
        return @{workflow=$null;check=(New-ClcDeploymentPrerequisiteCheck $Id $(if ($file.code -eq 404) {'FAIL'} else {'UNVERIFIED'}) $file.reason $action -Name 'Required workflow source')}
    }
    try {
        $workflow=ConvertFrom-ClcDeploymentPrerequisiteYaml $file.text
        if ($workflow['jobs'] -isnot [Collections.IDictionary] -or -not $workflow['jobs'].Count -or -not $workflow.Contains('on')) {
            return @{workflow=$null;check=(New-ClcDeploymentPrerequisiteCheck $Id FAIL 'The workflow lacks required jobs or triggers.' $action -Name 'Required workflow structure')}
        }
        @{workflow=$workflow;check=(New-ClcDeploymentPrerequisiteCheck $Id PASS "The expected workflow $Path has bounded valid YAML, jobs and triggers at the observed source commit." -Name 'Required workflow source')}
    } catch {
        $status=if ($_.Exception -is [YamlDotNet.Core.YamlException] -or $_.Exception.InnerException -is [YamlDotNet.Core.YamlException] -or $_.Exception.Data['prerequisite_status'] -ceq 'FAIL') {'FAIL'} else {'UNVERIFIED'}
        @{workflow=$null;check=(New-ClcDeploymentPrerequisiteCheck $Id $status 'Workflow YAML is invalid or cannot be safely interpreted; inspect unsupported aliases/tags/merges and bounded syntax.' $action -Name 'Required workflow structure')}
    }
}

function Test-ClcDeploymentPrerequisiteDispatch {
    param($Workflow)
    if ($null -eq $Workflow) {return $false}
    $events=$Workflow['on']
    ($events -is [Collections.IDictionary] -and $events.Contains('workflow_dispatch')) -or ($events -is [array] -and $events -ccontains 'workflow_dispatch') -or ($events -is [string] -and $events -ceq 'workflow_dispatch')
}

function Get-ClcDeploymentPrerequisiteWorkflowChecks {
    param($Config,$Release,$Deployment)
    $action='Configure the producer version-tag trigger and protected caller completion trigger for that exact producer; dispatch never grants independent authority.'
    if ($null -eq $Release) {
        New-ClcDeploymentPrerequisiteCheck 'github.workflow.release-trigger' SKIPPED 'Producer workflow observation was not established.' $action -Reason 'github.workflow.producer' -Name 'Producer trigger'
    } else {
        $events=$Release['on'];$tags=@()
        if ($events -is [Collections.IDictionary] -and $events['push'] -is [Collections.IDictionary]) {$tags=@($events['push']['tags'])}
        $status=if ($tags -ccontains 'v*' -and -not @($tags | Where-Object {$_ -like '!*'}).Count) {'PASS'} elseif (-not $tags.Count) {'FAIL'} else {'UNVERIFIED'}
        New-ClcDeploymentPrerequisiteCheck 'github.workflow.release-trigger' $status 'The producer push tag filter was inspected for supported version-tag coverage.' $action -Name 'Producer trigger'
    }
    if ($null -eq $Deployment -or $null -eq $Release) {
        New-ClcDeploymentPrerequisiteCheck 'github.workflow.completion-trigger' SKIPPED 'Producer or caller source was unavailable.' $action -Reason 'workflow-source' -Name 'Producer completion routing'
    } else {
        $events=$Deployment['on'];$completion=if ($events -is [Collections.IDictionary]) {$events['workflow_run']} else {$null}
        $status=if ($completion -is [Collections.IDictionary] -and @($completion['types']) -ccontains 'completed' -and @($completion['workflows']) -ccontains $Release['name']) {'PASS'} else {'UNVERIFIED'}
        New-ClcDeploymentPrerequisiteCheck 'github.workflow.completion-trigger' $status 'The caller completion event was compared with the expected producer identity.' $action -Name 'Producer completion routing'
    }
    New-ClcDeploymentPrerequisiteCheck 'github.workflow.manual-dispatch' $(if (Test-ClcDeploymentPrerequisiteDispatch $Deployment) {'UNVERIFIED'} else {'PASS'}) 'Manual dispatch is only a request; independent actor, source, artifact and host authority remain enforced by trusted deployment code.' 'Keep protected manual redeployment authorization in the reviewed shared implementation.' -Name 'Manual dispatch authority'
    New-ClcDeploymentPrerequisiteCheck 'github.workflow.runtime-semantics' UNVERIFIED 'Static source/configuration inspection cannot prove every expression, future execution, artifact qualification or application behavior.' 'Review the immutable shared revision and perform separately authorized consumer deployment/recovery acceptance.' -Name 'Runtime behavior limitation'
}
function Get-ClcDeploymentPrerequisiteSharedWorkflowAssessment {
    param($Context,$Config,$Deployment,[string] $Commit)
    $checks=[Collections.Generic.List[object]]::new();$identity=$null;$established=$false;$record=$null;$definition=$null
    $action='Align the protected consumer caller, .clc/release.json and reviewed immutable shared orchestration revision; keep installed-toolkit identity separate.'
    $jobs=if ($null -ne $Deployment) {@($Deployment['jobs'].Values)} else {@()}
    $calls=@($jobs | Where-Object {$_['uses'] -is [string] -and $_['uses'] -cmatch '/\.github/workflows/application-deploy\.yml@'})
    $shared=($Config.SharedRevision -ne '') -or $calls.Count -gt 0
    if (-not $shared) {
        foreach ($id in @('shared-identity','shared-definition')) {$checks.Add((New-ClcDeploymentPrerequisiteCheck "github.workflow.$id" NOT_APPLICABLE 'The selected caller directly defines its deployment job.' -Reason 'direct-workflow' -Name 'Shared workflow identity'))}
        $identity="$($Config.Repository)/$($Config.DeploymentWorkflow)@refs/heads/$($Config.IntegrationBranch)"
        $established=$null -ne $Deployment
    } elseif (-not $Config.SharedRevision -or $null -eq $Deployment) {
        $checks.Add((New-ClcDeploymentPrerequisiteCheck 'github.workflow.shared-identity' UNVERIFIED 'The reviewed shared revision or observed consumer caller is unavailable.' $action -Name 'Shared workflow identity'))
    } else {
        $expected="clcdpc/clc-deployment/.github/workflows/application-deploy.yml@$($Config.SharedRevision)"
        $uses=@($jobs | Where-Object {$_['uses']} | ForEach-Object {$_['uses']})
        $bad=$calls.Count -ne 1 -or @($uses | Where-Object {$_ -ceq $expected}).Count -ne 1 -or
            @($uses | Where-Object {$_ -cmatch '/\.github/workflows/application-release\.yml@' -and $_ -cne "clcdpc/clc-deployment/.github/workflows/application-release.yml@$($Config.SharedRevision)"}).Count -gt 0
        $file=Get-ClcDeploymentPrerequisiteFile $Context $Config.Repository '.clc/release.json' $Commit
        if ($bad) {
            $checks.Add((New-ClcDeploymentPrerequisiteCheck 'github.workflow.shared-identity' FAIL 'The caller selects missing, duplicate or incorrect shared deployment/publication identities.' $action -Name 'Shared workflow identity'))
        } elseif (-not $file.ok) {
            $checks.Add((New-ClcDeploymentPrerequisiteCheck 'github.workflow.shared-identity' $(if ($file.code -eq 404) {'FAIL'} else {'UNVERIFIED'}) $file.reason $action -Name 'Shared workflow identity'))
        } else {
            try {$record=Read-ClcConsumerConfiguration -Bytes ([Text.Encoding]::UTF8.GetBytes($file.text))} catch {$record=$null}
            if ($null -eq $record -or $record['contractVersion'] -ne 1 -or $record['orchestration'] -isnot [Collections.IDictionary] -or $record['producer'] -isnot [Collections.IDictionary] -or $record['targets'] -isnot [array]) {
                $checks.Add((New-ClcDeploymentPrerequisiteCheck 'github.workflow.shared-identity' FAIL 'The protected consumer configuration is malformed or uses an unsupported contract.' $action -Name 'Shared workflow identity'))
                $record=$null
            } elseif ($record['repository'] -cne $Config.Repository -or $record['applicationId'] -cne $Config.ApplicationId -or
                $record['integrationBranch'] -cne $Config.IntegrationBranch -or $record['orchestration']['sharedRevision'] -cne $Config.SharedRevision -or
                $record['orchestration']['deploymentWorkflowPath'] -cne $Config.DeploymentWorkflow -or $record['producer']['workflowPath'] -cne $Config.ReleaseWorkflow) {
                $checks.Add((New-ClcDeploymentPrerequisiteCheck 'github.workflow.shared-identity' FAIL 'Protected configuration disagrees with the repository, application, branch, producer, caller or shared revision.' $action -Name 'Shared workflow identity'))
            } else {
                $identity=$expected;$established=$true
                $checks.Add((New-ClcDeploymentPrerequisiteCheck 'github.workflow.shared-identity' PASS "The observed caller and protected orchestration configuration select exactly $identity." -Name 'Shared workflow identity'))
            }
        }
        if ($established) {
            $file=Get-ClcDeploymentPrerequisiteFile $Context 'clcdpc/clc-deployment' '.github/workflows/application-deploy.yml' $Config.SharedRevision
            if ($file.ok) {
                try {
                    $definition=ConvertFrom-ClcDeploymentPrerequisiteYaml $file.text -AllowAnchors
                    $checks.Add((New-ClcDeploymentPrerequisiteCheck 'github.workflow.shared-definition' PASS 'The exact immutable shared job definition is accessible and its bounded YAML syntax is valid. Runtime semantics remain an advisory limitation.' -Name 'Shared workflow source'))
                } catch {$checks.Add((New-ClcDeploymentPrerequisiteCheck 'github.workflow.shared-definition' UNVERIFIED 'The shared definition could not be parsed within safe bounds.' $action -Name 'Shared workflow source'))}
            } else {$checks.Add((New-ClcDeploymentPrerequisiteCheck 'github.workflow.shared-definition' UNVERIFIED $file.reason $action -Name 'Shared workflow source'))}
        }
    }
    if ($shared -and -not @($checks | Where-Object id -CEQ 'github.workflow.shared-definition').Count) {
        $checks.Add((New-ClcDeploymentPrerequisiteCheck 'github.workflow.shared-definition' SKIPPED 'The shared identity was not established.' $action -Reason 'github.workflow.shared-identity' -Name 'Shared workflow source'))
    }
    $extra=@($jobs | Where-Object {$_['runs-on'] -is [Collections.IDictionary] -and $_['runs-on']['group'] -ceq $Config.RunnerGroup})
    $checks.Add((New-ClcDeploymentPrerequisiteCheck 'github.workflow.additional-jobs' $(if ($shared -and $extra.Count) {'FAIL'} elseif ($null -eq $Deployment) {'SKIPPED'} else {'PASS'}) 'The consumer caller was inspected for additional jobs directly selecting the privileged group.' $action -Reason 'caller-source' -Name 'Additional privileged caller jobs'))
    if (Test-ClcDeploymentPrerequisiteDispatch $Deployment) {
        $automatic=@($calls | Where-Object {$_['with'] -is [Collections.IDictionary] -and $_['with']['automatic'] -ceq 'true'}).Count -gt 0
        $checks.Add((New-ClcDeploymentPrerequisiteCheck 'github.workflow.manual-selection' $(if ($automatic) {'FAIL'} else {'PASS'}) 'Dispatch must preserve the explicit shared manual operation path and its independent actor verification; an automatic=true literal on a dispatch-capable caller is invalid.' $action -Name 'Manual operation selection'))
    } else {$checks.Add((New-ClcDeploymentPrerequisiteCheck 'github.workflow.manual-selection' NOT_APPLICABLE 'No manual dispatch entry point was observed.' -Reason 'no-dispatch' -Name 'Manual operation selection'))}
    @{checks=$checks.ToArray();identity=$identity;identityEstablished=$established;shared=$shared;configuration=$record;definition=$definition;
        unavailableEvidence=$(if ($established) {@()} else {@('protected workflow identity')})}
}

function Get-ClcDeploymentPrerequisiteEnvironmentChecks {
    param($Context,$Config)
    $action="Configure environment $($Config.EnvironmentName) with exactly the $($Config.IntegrationBranch) branch rule and no additional branch/tag rules. Review compatibility with unattended runner/workflow admission."
    $path="/repos/$($Config.Repository)/environments"
    $list=Get-ClcDeploymentPrerequisiteCollection $Context $path 'environments'
    $status=if (-not $list.ok) {'UNVERIFIED'} elseif (@($list.data | Where-Object {$_['name'] -ceq $Config.EnvironmentName}).Count -ne 1) {'FAIL'} else {'PASS'}
    New-ClcDeploymentPrerequisiteCheck 'github.environment.exists' $status 'The complete accessible environment list was checked for the exact expected name.' $action -Name 'Deployment environment'
    if ($status -cne 'PASS') {
        New-ClcDeploymentPrerequisiteCheck 'github.environment.restrictions' SKIPPED 'The exact environment was not established.' $action -Reason 'github.environment.exists' -Name 'Environment branch restrictions'
        return
    }
    $encoded=[uri]::EscapeDataString($Config.EnvironmentName)
    $response=Get-ClcDeploymentPrerequisiteApi $Context "$path/$encoded"
    if (-not $response.ok) {New-ClcDeploymentPrerequisiteCheck 'github.environment.restrictions' UNVERIFIED $response.reason $action -Name 'Environment branch restrictions';return}
    $environment=$response.data;$policy=$environment['deployment_branch_policy']
    $status='UNVERIFIED';$detail='The environment branch policy was not exposed in a supported shape.'
    if ($null -eq $policy) {$status='FAIL';$detail='The environment permits unrestricted deployment refs.'}
    elseif ($policy['custom_branch_policies'] -eq $true -and $policy['protected_branches'] -eq $false) {
        $policies=Get-ClcDeploymentPrerequisiteCollection $Context "$path/$encoded/deployment-branch-policies" 'branch_policies'
        if ($policies.ok) {
            $status=if ($policies.data.Count -eq 1 -and $policies.data[0]['name'] -ceq $Config.IntegrationBranch -and $policies.data[0]['type'] -ceq 'branch') {'PASS'} else {'FAIL'}
            $detail='The exact integration-branch-only environment policy was inspected, including additional tag or branch rules.'
        } else {$detail=$policies.reason}
    }
    New-ClcDeploymentPrerequisiteCheck 'github.environment.restrictions' $status $detail $action -Name 'Environment branch restrictions'
    $reviewers=@($environment['protection_rules'] | Where-Object {$_['type'] -ceq 'required_reviewers'})
    New-ClcDeploymentPrerequisiteCheck 'github.environment.protection' $(if ($reviewers.Count) {'UNVERIFIED'} else {'PASS'}) $(if ($reviewers.Count) {'Reviewers are configured and may require manual intervention. They are not a universal commissioning requirement.'} else {'No mandatory environment reviewers are imposed; exact runner/workflow admission remains independently required.'}) 'Remove unintended manual approval dependencies through the infrastructure procedure if unattended execution is intended.' -Name 'Environment protection compatibility'
}

function Get-ClcDeploymentPrerequisiteRunnerChecks {
    param($Context, $Config, [string] $RepositoryVisibility, $Assessment)
    $PrivilegedWorkflow=$Assessment.identity
    $section='Deployment runner'
    $owner=$Config.Repository.Split('/')[0]
    $path="/orgs/$owner/actions/runner-groups"
    $publicAccess = switch ($RepositoryVisibility) {
        'private' { 'disable public repositories' }
        'public' { 'enable public repositories for this public caller' }
        default { 'verify caller visibility through the repository API before choosing public repository access' }
    }
    $action="Organization Settings > Actions > Runner groups > $($Config.RunnerGroup): select only this repository, $publicAccess, restrict to the exact job-defining deployment workflow (shared immutable SHA or legacy protected branch), and inspect group runner labels. Organization Self-hosted runners: read may be unavailable to GITHUB_TOKEN; use explicitly authorized read-only administrative inspection when needed."
    if ($RepositoryVisibility) {
        New-ClcDeploymentPrerequisiteCheck 'github.runner.visibility' PASS "The identity-verified repository API reports a $RepositoryVisibility caller."
    } else {
        New-ClcDeploymentPrerequisiteCheck 'github.runner.visibility' UNVERIFIED 'The repository API did not establish a consistent public/private visibility for the caller.' $action
    }
    if ($RepositoryVisibility -ceq 'public') {
        New-ClcDeploymentPrerequisiteCheck 'github.runner.public-risk' UNVERIFIED 'Public self-hosted runners risk executing untrusted PR/fork code. Public access enables job eligibility only; it does not establish safe admission or readiness.' 'Infrastructure must independently review public self-hosted runner risk, exact selected repository/workflow enforcement and every privileged code path; never execute untrusted PR/fork code on the deployment host.'
    }
    $list=Get-ClcDeploymentPrerequisiteCollection $Context $path 'runner_groups'
    if (-not $list.ok) { New-ClcDeploymentPrerequisiteCheck 'github.runner.group' UNVERIFIED $list.reason $action; return }
    $matches=@($list.data | Where-Object { $_['name'] -ceq $Config.RunnerGroup })
    if ($matches.Count -ne 1) { New-ClcDeploymentPrerequisiteCheck 'github.runner.group' FAIL 'Expected group absent from the complete accessible organization list.' $action; return }
    $id=$matches[0]['id']
    if ($id -isnot [int] -and $id -isnot [long]) { New-ClcDeploymentPrerequisiteCheck 'github.runner.group' UNVERIFIED 'Malformed runner group identity.' $action; return }
    $response=Get-ClcDeploymentPrerequisiteApi $Context "$path/$id"
    if (-not $response.ok) { New-ClcDeploymentPrerequisiteCheck 'github.runner.group' UNVERIFIED $response.reason $action; return }
    $group=$response.data
    New-ClcDeploymentPrerequisiteCheck 'github.runner.group' PASS 'The exact expected runner group was found and its settings were read.' -Name 'Deployment runner group'
    if (-not $RepositoryVisibility) {
        New-ClcDeploymentPrerequisiteCheck 'github.runner.repository-access' UNVERIFIED 'Caller visibility could not be verified; public repository admission cannot be assessed.' $action
    } elseif ($group -isnot [Collections.IDictionary] -or $group['visibility'] -isnot [string] -or $group['allows_public_repositories'] -isnot [bool]) {
        New-ClcDeploymentPrerequisiteCheck 'github.runner.repository-access' UNVERIFIED 'Repository admission fields were missing or malformed.' $action
    } elseif ($group['visibility'] -cne 'selected') {
        New-ClcDeploymentPrerequisiteCheck 'github.runner.repository-access' FAIL 'Runner group access is not restricted to selected repositories.' $action
    } elseif ($group['allows_public_repositories'] -ne ($RepositoryVisibility -ceq 'public')) {
        $detail = if ($RepositoryVisibility -ceq 'public') { 'Public repository access is disabled, so this public caller cannot use the runner group.' } else { 'Public repository access must remain disabled for this private caller.' }
        New-ClcDeploymentPrerequisiteCheck 'github.runner.repository-access' FAIL $detail $action
    } else {
        $repos=Get-ClcDeploymentPrerequisiteCollection $Context "$path/$id/repositories" 'repositories'
        if (-not $repos.ok) { New-ClcDeploymentPrerequisiteCheck 'github.runner.repository-access' UNVERIFIED $repos.reason $action }
        elseif (@($repos.data).Count -eq 1 -and $repos.data[0]['full_name'] -ieq $Config.Repository) { New-ClcDeploymentPrerequisiteCheck 'github.runner.repository-access' PASS "Selected repository access is limited to the verified $RepositoryVisibility caller; public access matches its visibility. Workflow admission and independent administrative review remain separate requirements." }
        else { New-ClcDeploymentPrerequisiteCheck 'github.runner.repository-access' FAIL 'Selected repositories are not limited to the caller.' $action }
    }
    $sharedExpected=$Assessment.shared
    $allowed=@(if ($PrivilegedWorkflow) { $PrivilegedWorkflow }
        elseif ($Config.ContainsKey('SharedRevision') -and $Config.SharedRevision) { "clcdpc/clc-deployment/.github/workflows/application-deploy.yml@$($Config.SharedRevision)" }
        elseif (-not $sharedExpected) { "$($Config.Repository)/$($Config.DeploymentWorkflow)@refs/heads/$($Config.IntegrationBranch)" })
    $expectedIdentityKnown=$allowed.Count -gt 0
    if ($Config.ContainsKey('DiagnosticWorkflow') -and $Config.DiagnosticWorkflow) { $allowed+= "$($Config.Repository)/$($Config.DiagnosticWorkflow)@refs/heads/$($Config.IntegrationBranch)" }
    $selected=@($group['selected_workflows'])
    if ($group['restricted_to_workflows'] -is [bool] -and -not $group['restricted_to_workflows']) {
        New-ClcDeploymentPrerequisiteCheck 'github.runner.workflow-access' FAIL 'The runner group does not enforce selected-workflow restrictions.' $action
    } elseif ($group['restricted_to_workflows'] -isnot [bool] -or $group['selected_workflows'] -isnot [array] -or @($selected | Where-Object { $_ -isnot [string] }).Count) {
        New-ClcDeploymentPrerequisiteCheck 'github.runner.workflow-access' UNVERIFIED 'Workflow admission fields were missing or malformed.' $action
    } elseif ($expectedIdentityKnown -and ($selected.Count -ne $allowed.Count -or @($allowed | Where-Object { $selected -cnotcontains $_ }).Count -gt 0)) {
        # Reviewed expected identities can reject excess/wrong access even when
        # protected caller/config evidence is unavailable. They cannot grant PASS.
        New-ClcDeploymentPrerequisiteCheck 'github.runner.workflow-access' FAIL 'Repository access alone is insufficient; expected workflow restriction is broader or inconsistent.' $action
    } elseif ($sharedExpected -and $owner -ine 'clcdpc' -and $group['inherited'] -is [bool] -and -not $group['inherited']) {
        New-ClcDeploymentPrerequisiteCheck 'github.runner.workflow-access' FAIL 'The observed non-inherited organization-owned group cannot admit the shared workflow from another organization.' $action
    } elseif ($sharedExpected -and $owner -ine 'clcdpc' -and $group['inherited'] -isnot [bool]) {
        New-ClcDeploymentPrerequisiteCheck 'github.runner.workflow-access' UNVERIFIED 'The cross-organization group ownership could not be inspected.' $action
    } elseif ($sharedExpected -and -not $Assessment.identityEstablished) {
        New-ClcDeploymentPrerequisiteCheck 'github.runner.workflow-access' UNVERIFIED 'The defining reusable workflow identity was not independently established; caller-only admission is insufficient.' $action
    } else {
        New-ClcDeploymentPrerequisiteCheck 'github.runner.workflow-access' PASS 'Only the exact expected job-defining deployment workflow and optional protected-branch diagnostic definition are selected; reusable caller selection does not admit callee jobs.'
    }
    if ($sharedExpected -and $owner -ine 'clcdpc' -and $group['inherited'] -eq $true) {
        New-ClcDeploymentPrerequisiteCheck 'github.runner.enterprise' UNVERIFIED 'An inherited enterprise group exposes the exact repository/workflow restrictions; complete enterprise enforcement cannot be proven through this organization API.' 'Retain enterprise control of the configured admission restrictions.'
    }
    $runners=Get-ClcDeploymentPrerequisiteCollection $Context "$path/$id/runners" 'runners'
    if (-not $runners.ok) { New-ClcDeploymentPrerequisiteCheck 'github.runner.labels' UNVERIFIED $runners.reason $action; return }
    $expected=$Config.RunnerLabels.Split(',')
    if (@($runners.data | Where-Object { $_ -isnot [Collections.IDictionary] -or $_['labels'] -isnot [array] }).Count) {
        New-ClcDeploymentPrerequisiteCheck 'github.runner.labels' UNVERIFIED 'Runner label fields were not fully exposed.' $action
        return
    }
    $matching=@($runners.data | Where-Object {
        $observed=@($_['labels'] | ForEach-Object { $_['name'] })
        @($expected | Where-Object { $observed -inotcontains $_ }).Count -eq 0
    })
    if (@($matching | Where-Object {$_['status'] -ceq 'online'}).Count) { New-ClcDeploymentPrerequisiteCheck 'github.runner.labels' PASS 'One group runner has all expected labels; this does not qualify its installation or future availability.' }
    else { New-ClcDeploymentPrerequisiteCheck 'github.runner.labels' FAIL 'No online group runner has all expected labels.' $action }
}

function Get-ClcDeploymentPrerequisiteRoutingChecks {
    param($Config,$Deployment,$Assessment)
    $action='Correct the protected application/channel/target/environment/group/label route; never infer Test or production authority from DEV or ASP.NET runtimeEnvironment.'
    if ($Assessment.shared) {
        $record=$Assessment.configuration
        if ($null -eq $record -or -not $Assessment.identityEstablished) {
            foreach ($id in @('target','channel')) {New-ClcDeploymentPrerequisiteCheck "github.routing.$id" SKIPPED 'Protected shared configuration and identity were not established.' $action -Reason 'github.workflow.shared-identity' -Name "Protected $id routing"}
            return
        }
        $targets=@($record['targets'] | Where-Object {$_['channel'] -ceq $Config.DeploymentChannel})
        $bad=$targets.Count -ne 1
        if (-not $bad) {
            $route=$targets[0]
            $bad=$route['targetId'] -cne $Config.TargetId -or $route['environment'] -cne $Config.EnvironmentName -or
                $route['runnerGroup'] -cne $Config.RunnerGroup -or $route['runnerLabels'] -isnot [array] -or
                (@($route['runnerLabels'] | Sort-Object -CaseSensitive) -join ',') -cne (@($Config.RunnerLabels.Split(',') | Sort-Object -CaseSensitive) -join ',') -or
                $route['enabled'] -isnot [bool] -or $route['runnerAdmissionReady'] -isnot [bool]
        }
        $definition=$Assessment.definition
        $routing=$null -ne $definition -and $definition['jobs'] -is [Collections.IDictionary] -and $definition['jobs']['deploy'] -is [Collections.IDictionary]
        if ($routing) {
            $job=$definition['jobs']['deploy']
            $routing=$job['runs-on'] -is [Collections.IDictionary] -and $job['runs-on']['group'] -ceq '${{ needs.admit.outputs.runner-group }}' -and
                $job['runs-on']['labels'] -ceq '${{ fromJSON(needs.admit.outputs.runner-labels) }}' -and $job['environment'] -ceq '${{ needs.admit.outputs.environment }}'
        }
        $status=if ($bad) {'FAIL'} elseif ($null -eq $definition) {'SKIPPED'} elseif (-not $routing) {'FAIL'} else {'PASS'}
        New-ClcDeploymentPrerequisiteCheck 'github.routing.target' $status 'The protected route and actual shared deployment job group/labels/environment expressions were compared with the selected target.' $action -Reason 'shared-definition' -Name 'Protected deployment routing'
        $policy=$record['sourcePolicy']
        $valid=$policy -is [Collections.IDictionary] -and $policy['allowSnapshots'] -is [bool] -and $policy['allowUnmergedDevTags'] -is [bool] -and $policy['allowTestTags'] -is [bool]
        $separate=@($record['targets'] | Where-Object {$_['channel'] -cne $Config.DeploymentChannel -and ($_.targetId -ceq $Config.TargetId -or $_.environment -ceq $Config.EnvironmentName -or $_.runnerGroup -ceq $Config.RunnerGroup)})
        $status=if (-not $valid -or $separate.Count -or ($Config.DeploymentChannel -ceq 'Test' -and -not $policy['allowTestTags'])) {'FAIL'} else {'PASS'}
        New-ClcDeploymentPrerequisiteCheck 'github.routing.channel' $status 'Source-policy flags and explicit independent channel routing were inspected; Test requires allowTestTags=true and its own target/environment/runner scope.' $action -Name 'Channel authority scope'
        if (-not $bad) {
            New-ClcDeploymentPrerequisiteCheck 'github.routing.activation' $(if ($route['enabled'] -and $route['runnerAdmissionReady']) {'PASS'} else {'UNVERIFIED'}) 'Protected activation and runnerAdmissionReady are indicators only; disabled indicators are a pending activation step after commissioning.' 'Have infrastructure enable the reviewed target route when independently authorized to proceed.' -Name 'Pending target activation'
        }
    } else {
        $jobs=if ($null -ne $Deployment) {@($Deployment['jobs'].Values)} else {@()}
        $bound=@($jobs | Where-Object {
            $job=$_;$envName=if ($job['environment'] -is [Collections.IDictionary]) {$job['environment']['name']} else {$job['environment']}
            $on=$job['runs-on']
            $on -is [Collections.IDictionary] -and $on['group'] -ceq $Config.RunnerGroup -and $envName -ceq $Config.EnvironmentName -and
                @($Config.RunnerLabels.Split(',') | Where-Object {@($on['labels']) -cnotcontains $_}).Count -eq 0
        })
        New-ClcDeploymentPrerequisiteCheck 'github.routing.target' $(if ($null -eq $Deployment) {'SKIPPED'} elseif ($bound.Count -eq 1) {'PASS'} else {'UNVERIFIED'}) 'The direct job group, labels and environment were inspected.' $action -Reason 'github.workflow.caller' -Name 'Direct deployment routing'
        New-ClcDeploymentPrerequisiteCheck 'github.routing.channel' UNVERIFIED 'A legacy direct caller has no protected shared channel-policy record for this application and target.' 'Inspect the protected direct workflow channel authority or adopt the explicit protected shared route.' -Name 'Channel authority scope'
        New-ClcDeploymentPrerequisiteCheck 'github.routing.activation' $(if ($Config.ActivationState -ceq 'enabled') {'PASS'} else {'UNVERIFIED'}) 'The repository activation indicator was observed; missing or disabled activation is a pending commissioning step and never independent authority.' 'Configure and enable activation through the independently authorized infrastructure process.' -Name 'Pending target activation'
    }
}

function Set-ClcDeploymentPrerequisiteAuthentication {
    param($Client,[ValidateSet('Standard','Administrative')][string] $Mode='Standard')
    $token=if ($Mode -ceq 'Administrative') {$env:CLC_GITHUB_INSPECTION_TOKEN} else {$env:GH_TOKEN}
    if ($Mode -ceq 'Administrative' -and -not $token) {throw 'Administrative inspection requires the explicitly supplied read-only installation token.'}
    if ($token) {$Client.DefaultRequestHeaders.Authorization=[Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$token)}
}

function Invoke-ClcDeploymentPrerequisiteGitHubInspection {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $Config,[Parameter(Mandatory)][string] $YamlAssemblyPath,
        [ValidateSet('Standard','Administrative')][string] $AuthenticationMode='Standard')
    Test-ClcDeploymentPrerequisiteInputs $Config
    $lock=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'dependencies.lock.json') -Raw | ConvertFrom-Json -AsHashtable
    if ((Get-FileHash -LiteralPath $YamlAssemblyPath).Hash.ToLowerInvariant() -cne $lock.yamlDotNet.assemblySha256) {throw 'Untrusted YAML parser assembly.'}
    Add-Type -LiteralPath $YamlAssemblyPath
    $handler=[Net.Http.HttpClientHandler]::new();$handler.AllowAutoRedirect=$false
    $context=@{client=[Net.Http.HttpClient]::new($handler);requests=0;timer=[Diagnostics.Stopwatch]::StartNew();authenticationMode=$AuthenticationMode}
    $context.client.Timeout=[TimeSpan]::FromSeconds(20);$context.client.MaxResponseContentBufferSize=4194304
    $context.client.DefaultRequestHeaders.UserAgent.ParseAdd('CLC-Deployment-Prerequisites/3')
    $context.client.DefaultRequestHeaders.Accept.ParseAdd('application/vnd.github+json')
    $context.client.DefaultRequestHeaders.Add('X-GitHub-Api-Version','2022-11-28')
    $rows=[Collections.Generic.List[object]]::new();$commit=''
    try {
        Set-ClcDeploymentPrerequisiteAuthentication $context.client $AuthenticationMode
        $repo=Get-ClcDeploymentPrerequisiteApi $context "/repos/$($Config.Repository)"
        $source=$repo.ok -and $repo.data -is [Collections.IDictionary] -and $repo.data['full_name'] -is [string] -and $repo.data['full_name'] -ieq $Config.Repository
        $rows.Add((New-ClcDeploymentPrerequisiteCheck 'github.repository.identity' $(if ($source) {'PASS'} elseif ($repo.ok) {'FAIL'} else {'UNVERIFIED'}) 'The GitHub repository API was inspected for the exact expected consumer identity.' 'Verify repository identity, contents/actions read permissions and API access; retry.' -Name 'Repository identity'))
        $visibility=''
        if ($source) {
            $data=$repo.data
            if ($data.Contains('visibility')) {
                if ($data['visibility'] -is [string] -and $data['visibility'] -cin @('public','private') -and
                    (-not $data.Contains('private') -or ($data['private'] -is [bool] -and $data['private'] -eq ($data['visibility'] -ceq 'private')))) {$visibility=$data['visibility']}
            } elseif ($data['private'] -is [bool]) {$visibility=if ($data['private']) {'private'} else {'public'}}
        }
        $branch=Get-ClcDeploymentPrerequisiteApi $context "/repos/$($Config.Repository)/branches/$([uri]::EscapeDataString($Config.IntegrationBranch))"
        if ($source -and $branch.ok -and $branch.data['commit'] -is [Collections.IDictionary] -and $branch.data['commit']['sha'] -cmatch '^[a-f0-9]{40}$') {
            $commit=$branch.data['commit']['sha']
            foreach ($row in @(Get-ClcDeploymentPrerequisiteBranchChecks $context $Config $branch.data)) {$rows.Add($row)}
            $release=Get-ClcDeploymentPrerequisiteWorkflowObservation $context $Config $Config.ReleaseWorkflow $commit 'github.workflow.producer'
            $deployment=Get-ClcDeploymentPrerequisiteWorkflowObservation $context $Config $Config.DeploymentWorkflow $commit 'github.workflow.caller'
            $rows.Add($release.check);$rows.Add($deployment.check)
            foreach ($row in @(Get-ClcDeploymentPrerequisiteWorkflowChecks $Config $release.workflow $deployment.workflow)) {$rows.Add($row)}
            $shared=Get-ClcDeploymentPrerequisiteSharedWorkflowAssessment $context $Config $deployment.workflow $commit
            foreach ($row in $shared.checks) {$rows.Add($row)}
            foreach ($row in @(Get-ClcDeploymentPrerequisiteTagChecks $context $Config $shared.configuration)) {$rows.Add($row)}
            foreach ($row in @(Get-ClcDeploymentPrerequisiteRoutingChecks $Config $deployment.workflow $shared)) {$rows.Add($row)}
            foreach ($row in @(Get-ClcDeploymentPrerequisiteRunnerChecks $context $Config $visibility $shared)) {$rows.Add($row)}
            foreach ($row in @(Get-ClcDeploymentPrerequisiteEnvironmentChecks $context $Config)) {$rows.Add($row)}
        } else {
            $rows.Add((New-ClcDeploymentPrerequisiteCheck 'github.branch.protection' $(if ($source -and $branch.code -eq 404) {'FAIL'} else {'UNVERIFIED'}) 'The configured integration branch identity could not be established.' 'Verify the configured integration branch exists and is readable.' -Name 'Integration source'))
            $rows.Add((New-ClcDeploymentPrerequisiteCheck 'github.inspection' SKIPPED 'Protected source was not established; dependent GitHub inspections did not execute.' 'Correct repository/branch access and rerun.' -Reason 'github.repository.identity' -Name 'Dependent GitHub inspection'))
        }
    } catch {
        # Keep completed observations, including confirmed failures; suppress private error text.
        $rows.Add((New-ClcDeploymentPrerequisiteCheck 'github.inspection' UNVERIFIED 'Unexpected or incomplete API/configuration data interrupted inspection; private details were suppressed.' 'Retry inspection; if reproducible, correct the unsupported observation or checker implementation.' -Reason 'inspection-error' -Name 'GitHub inspection completion'))
    } finally {$context.client.Dispose();$handler.Dispose();$context.timer.Stop()}
    New-ClcDeploymentPrerequisiteReport $Config $rows.ToArray() $commit
}

Export-ModuleMember -Function Stop-ClcDeploymentPrerequisiteObservation,Invoke-ClcDeploymentPrerequisiteGitHubInspection,New-ClcDeploymentPrerequisiteCheck,New-ClcDeploymentPrerequisiteReport,Merge-ClcDeploymentPrerequisiteReports,Publish-ClcDeploymentPrerequisiteReport,Format-ClcDeploymentPrerequisiteSummary,ConvertTo-ClcDeploymentPrerequisiteStageReport

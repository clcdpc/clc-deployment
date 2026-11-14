Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Add-DpResult {
    param($Results, [string] $Section, [string] $Name, [ValidateSet('PASS','FAIL','UNVERIFIED')][string] $Status, [string] $Detail, [string] $Action = '')
    $Results.Add([pscustomobject]@{ section=$Section; name=$Name; status=$Status; detail=$Detail; action=$Action })
}

function Get-DpApi {
    param([string] $Path)
    # No URLs from response bodies, caller-supplied endpoints, redirects or non-GET requests.
    if ($Path -cnotmatch '^/(repos|orgs)/[A-Za-z0-9_.%/?=&-]+$') { throw 'Invalid internal API path.' }
    $script:Requests++
    if ($script:Requests -gt 150 -or $script:Timer.Elapsed.TotalSeconds -gt 240) {
        return @{ ok=$false; code=0; reason='The bounded API request/time budget was exhausted.' }
    }
    try {
        $response = $script:Client.GetAsync('https://api.github.com' + $Path).GetAwaiter().GetResult()
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
            $data = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable -Depth 64 -NoEnumerate
            return @{ ok=$true; code=200; data=$data; reason='' }
        } finally { $response.Dispose() }
    } catch {
        # Never emit exceptions: they can include headers, private response bodies or variable values.
        return @{ ok=$false; code=0; reason='GitHub transport, response-size, timeout or JSON failure; retry validation.' }
    }
}

function Get-DpCollection {
    param([string] $Path, [string] $Property = '', [ValidateRange(1,100)][int] $PageSize = 100)
    $items = [Collections.Generic.List[object]]::new()
    $total=$null
    for ($page=1; $page -le 20; $page++) {
        $separator = if ($Path.Contains('?')) { '&' } else { '?' }
        $response = Get-DpApi ($Path + $separator + "per_page=$PageSize&page=" + $page)
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

function ConvertFrom-DpYamlNode {
    param($Node, [int] $Depth = 0)
    if ($Depth -gt 32 -or ++$script:YamlNodes -gt 20000) { throw 'UnsupportedYaml' }
    if (-not $Node.Anchor.IsEmpty -or (-not $Node.Tag.IsEmpty -and $Node.Tag.Value -notin @('tag:yaml.org,2002:map','tag:yaml.org,2002:seq','tag:yaml.org,2002:str','tag:yaml.org,2002:null','tag:yaml.org,2002:bool','tag:yaml.org,2002:int'))) { throw 'UnsupportedYaml' }
    switch ($Node.NodeType.ToString()) {
        Scalar { return [string]$Node.Value }
        Mapping {
            $map = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
            foreach ($pair in $Node.Children.GetEnumerator()) {
                if ($pair.Key.NodeType.ToString() -cne 'Scalar' -or $pair.Key.Value -ceq '<<') { throw 'UnsupportedYaml' }
                $key = [string]$pair.Key.Value
                if ($map.Contains($key)) { throw 'InvalidYaml' }
                $map.Add($key,(ConvertFrom-DpYamlNode $pair.Value ($Depth+1)))
            }
            return ,$map
        }
        Sequence {
            $items = @($Node.Children | ForEach-Object { ConvertFrom-DpYamlNode $_ ($Depth+1) })
            return ,$items
        }
        default { throw 'UnsupportedYaml' }
    }
}

function ConvertFrom-DpYaml {
    param([string] $Text)
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
            if ($kind -ceq 'AnchorAlias') { throw 'UnsupportedYaml' }
            if ($event -is [YamlDotNet.Core.Events.NodeEvent] -and (-not $event.Anchor.IsEmpty -or -not $event.Tag.IsEmpty)) { throw 'UnsupportedYaml' }
        }
    } finally { $preflight.Dispose() }
    $script:YamlNodes = 0
    $stream = [YamlDotNet.RepresentationModel.YamlStream]::new()
    $reader = [IO.StringReader]::new($Text)
    try { $stream.Load($reader) } finally { $reader.Dispose() }
    if ($stream.Documents.Count -ne 1) { throw 'InvalidYaml' }
    $value = ConvertFrom-DpYamlNode $stream.Documents[0].RootNode
    if ($value -isnot [Collections.IDictionary]) { throw 'InvalidYaml' }
    return ,$value
}

function Get-DpFile {
    param([string] $Repository, [string] $Path, [string] $Commit)
    $response = Get-DpApi "/repos/$Repository/contents/$($Path)?ref=$Commit"
    if (-not $response.ok) { return $response }
    $file = $response.data
    if ($file -isnot [Collections.IDictionary] -or $file['type'] -cne 'file' -or $file['encoding'] -cne 'base64' -or $file['size'] -gt 262144) {
        return @{ ok=$false; code=0; reason='Workflow/configuration file is not a bounded regular UTF-8 file.' }
    }
    try {
        $text = [Text.UTF8Encoding]::new($false,$true).GetString([Convert]::FromBase64String($file['content']))
        return @{ ok=$true; code=200; text=$text }
    } catch { return @{ ok=$false; code=0; reason='GitHub file encoding could not be inspected.' } }
}

function Test-DpInputs {
    param($Config)
    if ($Config.Repository -cnotmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}$') { throw 'Invalid repository identity.' }
    if ($Config.IntegrationBranch -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_./-]{0,127}$' -or $Config.IntegrationBranch -match '\.\.|//|/\.|\.lock$|[/.]$') { throw 'Invalid integration branch.' }
    foreach ($path in @($Config.ReleaseWorkflow,$Config.DeploymentWorkflow)) {
        if ($path -cnotmatch '^\.github/workflows/[A-Za-z0-9_-][A-Za-z0-9_.-]{0,100}\.ya?ml$' -or $path.Contains('..')) { throw 'Invalid workflow path.' }
    }
    foreach ($name in @($Config.EnvironmentName,$Config.RunnerGroup)) {
        if ($name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_. -]{0,99}$') { throw 'Environment name and runner group are required safe names.' }
    }
    if ($Config.ActivationVariable -cnotmatch '^[A-Z_][A-Z0-9_]{0,63}$' -or $Config.ActivationVariable -cmatch '^(GITHUB_|RUNNER_)') { throw 'Invalid activation variable name.' }
    if ($Config.DeploymentChannel -cnotin @('DEV','Production')) { throw 'Deployment channel must be DEV or Production.' }
    if ($Config.EnvironmentProtection -cnotin @('runner-workflow','required-reviewers')) { throw 'Invalid environment protection model.' }
    if ($Config.ActivationState -cnotin @('enabled','disabled','missing-or-empty','invalid','unavailable')) { throw 'Invalid activation observation.' }
    $labels = @($Config.RunnerLabels.Split(','))
    if ($labels.Count -gt 10 -or @($labels | Where-Object { $_ -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$' }).Count) { throw 'Invalid comma-separated runner labels.' }
}

function Get-DpBranchResults {
    param($Config, $Results, $Branch)
    $section='Repository configuration'
    $action="Inspect Settings > Rules > Rulesets / Branches for the exact integration branch; require PRs, reviews, code-owner review and block force pushes/deletion."
    $path="/repos/$($Config.Repository)"
    $encoded=[uri]::EscapeDataString($Config.IntegrationBranch)
    $classic=Get-DpApi "$path/branches/$encoded/protection"
    $effective=Get-DpCollection "$path/rules/branches/$encoded"
    $rules=if ($effective.ok) { @($effective.data) } else { @() }
    $protection=if ($classic.ok) { $classic.data } else { @{} }
    $pr=$protection['required_pull_request_reviews']
    $pullRules=@($rules | Where-Object { $_['type'] -ceq 'pull_request' })
    $observations=[ordered]@{
        'Required pull requests'=($null -ne $pr -or $pullRules.Count -gt 0)
        'Required independent reviews'=($null -ne $pr -and $pr['required_approving_review_count'] -ge 1)
        'Force pushes restricted'=($null -ne $protection['allow_force_pushes'] -and $protection['allow_force_pushes']['enabled'] -eq $false)
        'Branch deletion restricted'=($null -ne $protection['allow_deletions'] -and $protection['allow_deletions']['enabled'] -eq $false)
        'Code-owner review enforced'=($null -ne $pr -and $pr['require_code_owner_reviews'] -eq $true)
    }
    foreach ($rule in $pullRules) {
        if ($rule['parameters']['required_approving_review_count'] -ge 1) { $observations['Required independent reviews']=$true }
        if ($rule['parameters']['require_code_owner_review'] -eq $true) { $observations['Code-owner review enforced']=$true }
    }
    if (@($rules | Where-Object { $_['type'] -ceq 'non_fast_forward' }).Count) { $observations['Force pushes restricted']=$true }
    if (@($rules | Where-Object { $_['type'] -ceq 'deletion' }).Count) { $observations['Branch deletion restricted']=$true }
    # A classic 404 proves absence only when branch metadata says unprotected AND active rules were enumerated.
    $complete=$effective.ok -and ($classic.ok -or ($classic.code -eq 404 -and $Branch['protected'] -eq $false))
    foreach ($item in $observations.GetEnumerator()) {
        if ($item.Value) { Add-DpResult $Results $section $item.Key PASS 'Enforced classic protection or an active applicable branch rule was observed.' }
        elseif ($complete) { Add-DpResult $Results $section $item.Key FAIL 'The required protection was not configured in the observed rules.' $action }
        else { Add-DpResult $Results $section $item.Key UNVERIFIED 'Classic or inherited protection could not be fully read.' $action }
    }
    Add-DpResult $Results $section 'Branch bypass and workflow ownership' UNVERIFIED 'Rule presence does not establish independent reviewer identities, bypass authority or effective CODEOWNERS coverage.' 'Review rule bypass actors and effective CODEOWNERS for both workflow paths and toolkit pins; require infrastructure ownership.'
}

function Get-DpTagResults {
    param($Config, $Results)
    $path="/repos/$($Config.Repository)/rulesets"
    $list=Get-DpCollection "$($path)?includes_parents=true"
    $action='Inspect Settings > Rules > Rulesets (including inherited rules): active tag rules covering all v* tags must restrict creation, updates and deletion; review authorized bypass actors.'
    $found=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $unknown=-not $list.ok
    if ($list.ok) {
        foreach ($entry in $list.data) {
            if ($entry['id'] -isnot [long] -and $entry['id'] -isnot [int]) { $unknown=$true; continue }
            $detail=Get-DpApi "$path/$($entry['id'])?includes_parents=true"
            if (-not $detail.ok) { $unknown=$true; continue }
            $rule=$detail.data
            if ($rule -isnot [Collections.IDictionary] -or -not $rule.Contains('target') -or -not $rule.Contains('enforcement')) { $unknown=$true; continue }
            if ($rule['target'] -cne 'tag' -or $rule['enforcement'] -cne 'active') { continue }
            $conditions=$rule['conditions']
            if ($null -eq $conditions -or $null -eq $conditions['ref_name']) { $unknown=$true; continue }
            $refs=$conditions['ref_name']
            # Only prove full-pattern coverage for these simple GitHub patterns. Never approximate fnmatch.
            if (@($refs['exclude']).Count -gt 0) { $unknown=$true; continue }
            if (-not @($refs['include'] | Where-Object { $_ -cin @('~ALL','refs/tags/*','refs/tags/v*') }).Count) {
                if (@($refs['include'] | Where-Object { $_ -match '[?\[\\]' }).Count) { $unknown=$true }
                continue
            }
            if ($null -eq $rule['rules']) { $unknown=$true; continue }
            foreach ($item in $rule['rules']) { if ($item['type'] -cin @('creation','update','deletion')) { [void]$found.Add($item['type']) } }
        }
    }
    foreach ($type in @('creation','update','deletion')) {
        if ($found.Contains($type)) { Add-DpResult $Results 'Repository configuration' "Release tag $type restricted" PASS 'An active inherited/repository tag ruleset covers all v* tags and enforces this operation restriction.' }
        elseif ($unknown) { Add-DpResult $Results 'Repository configuration' "Release tag $type restricted" UNVERIFIED 'Ruleset access or full v* pattern coverage could not be established.' $action }
        else { Add-DpResult $Results 'Repository configuration' "Release tag $type restricted" FAIL 'No active v* rule enforcing this operation restriction was found.' $action }
    }
    Add-DpResult $Results 'Repository configuration' 'Tag bypass authority' UNVERIFIED 'Authorized release producers and bypass identities require independent administrative review.' $action
}

function Get-DpWorkflow {
    param($Config, $Results, [string] $Path, [string] $Commit, [string] $Name)
    $file=Get-DpFile $Config.Repository $Path $Commit
    $action="Review $Path at the integration branch; configure the documented automatic release/deployment structure."
    if (-not $file.ok) {
        $status=if ($file.code -eq 404) { 'FAIL' } else { 'UNVERIFIED' }
        Add-DpResult $Results 'Repository configuration' "$Name workflow present" $status $file.reason $action
        return $null
    }
    try {
        $workflow=ConvertFrom-DpYaml $file.text
        if ($workflow['jobs'] -isnot [Collections.IDictionary] -or $workflow['jobs'].Count -eq 0 -or -not $workflow.Contains('on')) { throw 'InvalidYaml' }
    } catch {
        $status=if ($_.Exception.Message -match 'UnsupportedYaml') { 'UNVERIFIED' } else { 'FAIL' }
        Add-DpResult $Results 'Repository configuration' "$Name workflow structure" $status 'Workflow YAML is invalid or uses unsupported constructs (anchors, tags, merges or size/depth bounds).' $action
        return $null
    }
    Add-DpResult $Results 'Repository configuration' "$Name workflow present" PASS 'A workflow mapping with jobs and triggers exists at the observed integration commit.'
    return ,$workflow
}

function Get-DpWorkflowResults {
    param($Config, $Results, $Release, $Deployment)
    $action='Review the release and deployment workflows: v* tag builds, successful qualification, automatic trusted-branch deployment, no routine manual deployment dispatch.'
    if ($null -ne $Release) {
        $events=$Release['on']
        if ($events -is [Collections.IDictionary] -and $events['push'] -is [Collections.IDictionary]) {
            $tags=@($events['push']['tags'])
            if ($tags -ccontains 'v*' -and -not @($tags | Where-Object { $_ -like '!*' }).Count -and -not $events['push'].Contains('tags-ignore')) {
                Add-DpResult $Results 'Repository configuration' 'Version-tag release trigger' PASS 'push.tags includes v* without tag exclusions; optional fresh-build dispatch is permitted.'
            } else { Add-DpResult $Results 'Repository configuration' 'Version-tag release trigger' UNVERIFIED 'Complete v* trigger coverage could not be proved from the observed tag filters.' $action }
        } else { Add-DpResult $Results 'Repository configuration' 'Version-tag release trigger' FAIL 'No explicit push tag filter was found.' $action }
    }
    if ($null -ne $Deployment) {
        $events=$Deployment['on']
        $dispatch=($events -is [Collections.IDictionary] -and $events.Contains('workflow_dispatch')) -or ($events -is [array] -and $events -ccontains 'workflow_dispatch') -or ($events -is [string] -and $events -ceq 'workflow_dispatch')
        if ($dispatch) { Add-DpResult $Results 'Repository configuration' 'Routine deployment has no manual dispatch' FAIL 'The deployment workflow exposes workflow_dispatch.' $action }
        else { Add-DpResult $Results 'Repository configuration' 'Routine deployment has no manual dispatch' PASS 'The expected deployment workflow has no workflow_dispatch trigger.' }
        $completion=if ($events -is [Collections.IDictionary]) { $events['workflow_run'] } else { $null }
        if ($null -ne $Release -and $completion -is [Collections.IDictionary] -and @($completion['types']) -ccontains 'completed' -and @($completion['workflows']) -ccontains $Release['name']) {
            Add-DpResult $Results 'Repository configuration' 'Automatic release-completion trigger' PASS 'workflow_run names the release workflow and completed activity; success guards are assessed separately.'
        } else { Add-DpResult $Results 'Repository configuration' 'Automatic release-completion trigger' UNVERIFIED 'The small structural check cannot establish this automatic qualification handoff (including same-workflow/reusable alternatives).' $action }
    }
    Add-DpResult $Results 'Repository configuration' 'Successful qualification and trusted execution' UNVERIFIED 'YAML structure alone cannot prove expression logic, immutable checkout, helper code or artifact/source qualification.' 'Review success/repository/event/ref/source guards and every privileged checkout/helper; reject consumer PR/tag code on the host.'
}

function Get-DpEnvironmentResults {
    param($Config, $Results)
    $section='GitHub Environment'
    $action='Inspect Settings > Environments for the exact name, integration-branch-only deployment policy and the chosen protection model; check GitHub plan/visibility support.'
    $path="/repos/$($Config.Repository)"
    $list=Get-DpCollection "$path/environments" 'environments'
    if (-not $list.ok) { Add-DpResult $Results $section 'Environment exists' UNVERIFIED $list.reason $action; return }
    $matches=@($list.data | Where-Object { $_['name'] -ceq $Config.EnvironmentName })
    if ($matches.Count -ne 1) { Add-DpResult $Results $section 'Environment exists' FAIL 'The exact environment name is absent from the complete visible list.' $action; return }
    Add-DpResult $Results $section 'Environment exists' PASS 'The exact name was observed; existence alone does not satisfy its restrictions.'
    $encoded=[uri]::EscapeDataString($Config.EnvironmentName)
    $response=Get-DpApi "$path/environments/$encoded"
    if (-not $response.ok) { Add-DpResult $Results $section 'Environment restrictions' UNVERIFIED $response.reason $action; return }
    $environment=$response.data
    $policy=$environment['deployment_branch_policy']
    if ($null -eq $policy) { Add-DpResult $Results $section 'Environment branch restrictions' FAIL 'The environment allows unrestricted deployment refs.' $action }
    elseif ($policy['custom_branch_policies'] -eq $true -and $policy['protected_branches'] -eq $false) {
        $policies=Get-DpCollection "$path/environments/$encoded/deployment-branch-policies" 'branch_policies'
        if (-not $policies.ok) { Add-DpResult $Results $section 'Environment branch restrictions' UNVERIFIED $policies.reason $action }
        elseif (@($policies.data).Count -eq 1 -and $policies.data[0]['name'] -ceq $Config.IntegrationBranch -and $policies.data[0]['type'] -ceq 'branch') {
            Add-DpResult $Results $section 'Environment branch restrictions' PASS 'Exactly the integration branch is allowed, with no tag rules.'
        } else { Add-DpResult $Results $section 'Environment branch restrictions' FAIL 'Selected deployment rules do not allow only the expected integration branch.' $action }
    } else { Add-DpResult $Results $section 'Environment branch restrictions' UNVERIFIED 'Protected-branches-only or an unknown policy does not prove exact branch/workflow admission.' $action }
    if ($Config.EnvironmentProtection -ceq 'required-reviewers') {
        $reviewers=@($environment['protection_rules'] | Where-Object { $_['type'] -ceq 'required_reviewers' })
        if ($reviewers.Count -gt 0 -and @($reviewers[0]['reviewers']).Count -gt 0 -and $reviewers[0]['prevent_self_review'] -eq $true) {
            Add-DpResult $Results $section 'Required reviewers and no self-review' PASS 'Required reviewers and prevent_self_review are configured; reviewer independence still needs review.'
        } elseif ($environment.Contains('protection_rules')) { Add-DpResult $Results $section 'Required reviewers and no self-review' FAIL 'The selected reviewer model requires reviewers and prevention of self-review.' $action }
        else { Add-DpResult $Results $section 'Required reviewers and no self-review' UNVERIFIED 'Protection rule fields were not exposed.' $action }
        if ($environment.Contains('can_admins_bypass')) {
            $status=if ($environment['can_admins_bypass'] -eq $false) { 'PASS' } else { 'FAIL' }
            Add-DpResult $Results $section 'Environment administrator bypass disabled' $status 'Observed can_admins_bypass setting.' $(if ($status -ceq 'FAIL') { $action })
        } else { Add-DpResult $Results $section 'Environment administrator bypass disabled' UNVERIFIED 'GitHub did not expose can_admins_bypass.' $action }
    } else {
        Add-DpResult $Results $section 'Unattended protection model' UNVERIFIED 'Manual approval is not required by the selected model; independently enforced runner/workflow admission must be qualified.' 'Infrastructure must review selected-workflow runner admission and environment protection/bypass settings for unattended operation.'
    }
}

function Get-DpRunnerResults {
    param($Config, $Results)
    $section='Deployment runner'
    $owner=$Config.Repository.Split('/')[0]
    $path="/orgs/$owner/actions/runner-groups"
    $action="Organization Settings > Actions > Runner groups > $($Config.RunnerGroup): select only this repository, disable public repositories, restrict to the exact deployment workflow@refs/heads/$($Config.IntegrationBranch), and inspect group runner labels. Organization Self-hosted runners: read may be unavailable to GITHUB_TOKEN; no administrator credential is required by this validator."
    $list=Get-DpCollection $path 'runner_groups'
    if (-not $list.ok) { Add-DpResult $Results $section 'Restricted runner group' UNVERIFIED $list.reason $action; return }
    $matches=@($list.data | Where-Object { $_['name'] -ceq $Config.RunnerGroup })
    if ($matches.Count -ne 1) { Add-DpResult $Results $section 'Restricted runner group' FAIL 'Expected group absent from the complete accessible organization list.' $action; return }
    $id=$matches[0]['id']
    if ($id -isnot [int] -and $id -isnot [long]) { Add-DpResult $Results $section 'Restricted runner group' UNVERIFIED 'Malformed runner group identity.' $action; return }
    $response=Get-DpApi "$path/$id"
    if (-not $response.ok) { Add-DpResult $Results $section 'Restricted runner group' UNVERIFIED $response.reason $action; return }
    $group=$response.data
    if ($group['visibility'] -ceq 'selected' -and $group['allows_public_repositories'] -eq $false) {
        $repos=Get-DpCollection "$path/$id/repositories" 'repositories'
        if (-not $repos.ok) { Add-DpResult $Results $section 'Runner repository access' UNVERIFIED $repos.reason $action }
        elseif (@($repos.data).Count -eq 1 -and $repos.data[0]['full_name'] -ieq $Config.Repository) { Add-DpResult $Results $section 'Runner repository access' PASS 'Selected repository access is limited to the caller; public repository access is disabled.' }
        else { Add-DpResult $Results $section 'Runner repository access' FAIL 'Selected repositories are not limited to the caller.' $action }
    } elseif ($group.Contains('visibility') -and $group.Contains('allows_public_repositories')) {
        Add-DpResult $Results $section 'Runner repository access' FAIL 'Runner group access is broader than the selected private repository model.' $action
    } else { Add-DpResult $Results $section 'Runner repository access' UNVERIFIED 'Repository admission fields were not exposed.' $action }
    $allowed="$($Config.Repository)/$($Config.DeploymentWorkflow)@refs/heads/$($Config.IntegrationBranch)"
    if ($group['restricted_to_workflows'] -eq $true -and @($group['selected_workflows']).Count -eq 1 -and $group['selected_workflows'][0] -ceq $allowed) {
        Add-DpResult $Results $section 'Runner selected-workflow access' PASS 'Only the exact expected protected-branch deployment workflow is selected.'
    } elseif ($group.Contains('restricted_to_workflows') -and $group.Contains('selected_workflows')) { Add-DpResult $Results $section 'Runner selected-workflow access' FAIL 'Repository access alone is insufficient; expected workflow restriction is missing, broader or inconsistent.' $action }
    else { Add-DpResult $Results $section 'Runner selected-workflow access' UNVERIFIED 'Workflow admission fields were not exposed.' $action }
    $runners=Get-DpCollection "$path/$id/runners" 'runners'
    if (-not $runners.ok) { Add-DpResult $Results $section 'Expected runner labels' UNVERIFIED $runners.reason $action; return }
    $expected=$Config.RunnerLabels.Split(',')
    if (@($runners.data | Where-Object { $_ -isnot [Collections.IDictionary] -or $_['labels'] -isnot [array] }).Count) {
        Add-DpResult $Results $section 'Expected runner labels' UNVERIFIED 'Runner label fields were not fully exposed.' $action
        return
    }
    $matching=@($runners.data | Where-Object {
        $observed=@($_['labels'] | ForEach-Object { $_['name'] })
        @($expected | Where-Object { $observed -inotcontains $_ }).Count -eq 0
    })
    if ($matching.Count) { Add-DpResult $Results $section 'Expected runner labels' PASS 'One group runner has all expected labels; this does not qualify its installation or future availability.' }
    else { Add-DpResult $Results $section 'Expected runner labels' FAIL 'No group runner has all expected labels.' $action }
}

function Get-DpDeploymentResults {
    param($Config, $Results, $Deployment)
    $section='Deployment configuration'
    $action="Inspect repository/organization Actions variable $($Config.ActivationVariable) and the protected workflow. Leave disabled until independent infrastructure authorization."
    $status='UNVERIFIED'; $detail='The calling Actions configuration-variable observation is unavailable.'
    switch -CaseSensitive ($Config.ActivationState) {
        enabled { $status='PASS'; $detail='Configured and enabled in repository/organization Actions context. This is an indicator, never authorization.' }
        disabled { $status='FAIL'; $detail='Configured but intentionally disabled; activation requires independent authorization.' }
        missing-or-empty { $status='FAIL'; $detail='The activation variable is missing or empty in the calling Actions context.' }
        invalid { $status='FAIL'; $detail='The activation variable must compare as true or false in the Actions context; its value is not disclosed.' }
    }
    Add-DpResult $Results $section 'Activation indicator' $status $detail $(if ($status -cne 'PASS') { $action })
    $encoded=[uri]::EscapeDataString($Config.EnvironmentName)
    $variables=Get-DpCollection "/repos/$($Config.Repository)/environments/$encoded/variables" 'variables' -PageSize 30
    if (-not $variables.ok) { Add-DpResult $Results $section 'Environment activation override' UNVERIFIED $variables.reason 'Inspect environment Actions variables for conflicting activation values; pre-job admission must use repository/organization variables.' }
    else {
        $override=@($variables.data | Where-Object { $_['name'] -ceq $Config.ActivationVariable })
        if ($override.Count) { Add-DpResult $Results $section 'Environment activation override' FAIL 'An environment-scoped activation value conflicts with the repository/organization-only admission contract.' 'Remove the conflicting scope through independently reviewed configuration; use repository/organization activation for pre-job admission.' }
        else { Add-DpResult $Results $section 'Environment activation override' PASS 'No environment-scoped override of the selected activation variable was observed.' }
    }
    if ($null -ne $Deployment) {
        $jobs=@($Deployment['jobs'].Values)
        $direct=@($jobs | Where-Object { $_ -is [Collections.IDictionary] -and $_['runs-on'] -is [Collections.IDictionary] -and $_['runs-on']['group'] -ceq $Config.RunnerGroup })
        $bound=@($direct | Where-Object {
            $envName=if ($_['environment'] -is [Collections.IDictionary]) { $_['environment']['name'] } else { $_['environment'] }
            $envName -ceq $Config.EnvironmentName
        })
        if ($bound.Count -gt 0) { Add-DpResult $Results $section 'Privileged job environment binding' PASS 'A job selecting the exact expected runner group also names the exact environment.' }
        else { Add-DpResult $Results $section 'Privileged job environment binding' UNVERIFIED 'Static group/environment binding was not found; expressions or reusable jobs require review.' 'Verify that every privileged job directly selects the intended group/labels and environment, including reusable job definitions.' }
    }
    if ($Config.DeploymentChannel -ceq 'Production') {
        Add-DpResult $Results $section 'Explicit production gate' UNVERIFIED 'Production opt-in and its relationship to the chosen environment/runner protection cannot be proved by a variable or YAML token match.' 'Infrastructure must review the production-only opt-in guard and independently enforced protection; this validator never enables production.'
    }
}

function Get-DpToolkitResults {
    param($Config, $Results, $Release, $Deployment)
    # Deliberately independent of the unfinished standing-authorization API/schema.
    $section='Host and toolkit'
    $uses=@()
    foreach ($workflow in @($Release,$Deployment)) {
        if ($null -eq $workflow) { continue }
        foreach ($job in $workflow['jobs'].Values) {
            if ($job['uses']) { $uses += [string]$job['uses'] }
            foreach ($step in @($job['steps'])) { if ($null -ne $step -and $step['uses']) { $uses += [string]$step['uses'] } }
        }
    }
    $references=@($uses | Where-Object { $_ -clike 'clcdpc/clc-deployment/*' })
    if (@($references | Where-Object { $_ -cmatch '^clcdpc/clc-deployment/.+@[0-9a-f]{40}$' }).Count) {
        Add-DpResult $Results $section 'Shared toolkit workflow pin' PASS 'An immutable shared-toolkit uses reference was observed; this proves the reference only.'
    } else { Add-DpResult $Results $section 'Shared toolkit workflow pin' UNVERIFIED 'No direct immutable shared-toolkit uses reference was observed; installed-toolkit and script-based integration require review.' 'Review exact toolkit source/distribution pins and shared-toolkit calls in trusted workflow/helpers after PR #2 finalizes; do not bundle an independent deployment engine.' }
    foreach ($item in @(
        @('Shared toolkit execution model','Verify that trusted deployment invokes the independently installed shared toolkit and preserves its security checks; references/comments alone are insufficient.'),
        @('Compatible toolkit installation','Infrastructure must authenticate and install a compatible exact source/distribution pin before activation; see docs/installation.md.'),
        @('IIS target enrollment','Infrastructure must verify the exact target enrollment under separate authority; see docs/host-enrollment.md.'),
        @('Initial successful deployment baseline','Retain a separately authorized successful consumer baseline before routine activation; see docs/iis-verification.md.'),
        @('Standing authorization','Infrastructure must independently provision and verify the final standing-authorization contract; do not infer it from activation variables.'),
        @('Runtime identity and host permissions','Verify actual independent runtime identity and effective protected-resource write isolation on the host.'),
        @('Application configuration and Data Protection','Application and infrastructure owners must qualify external configuration, key paths and compatibility without disclosing private contents.'),
        @('Host readiness and recovery qualification','Complete separately scoped real-host readiness/deployment/recovery qualification; actual Server 2022/IIS qualification remains NOT RUN.')
    )) { Add-DpResult $Results $section $item[0] UNVERIFIED 'No independently trusted host qualification evidence is available to this hosted diagnostic.' $item[1] }
}

function Complete-DpReport {
    param($Config, $Results, [string] $Commit = '')
    $passed=@($Results | Where-Object status -CEQ PASS).Count
    $failed=@($Results | Where-Object status -CEQ FAIL).Count
    $unverified=@($Results | Where-Object status -CEQ UNVERIFIED).Count
    $ready=$Results.Count -gt 0 -and $failed -eq 0 -and $unverified -eq 0
    [pscustomobject]@{ repository=$Config.Repository; channel=$Config.DeploymentChannel; environment=$Config.EnvironmentName; observed_commit=$Commit; ready=$ready; passed_count=$passed; failed_count=$failed; unverified_count=$unverified; exit_code=$(if ($Config.Strict -and -not $ready) { 1 } else { 0 }); results=$Results.ToArray() }
}

function Invoke-DpSection {
    param($Results, [string] $Section, [scriptblock] $Check)
    try { & $Check }
    catch { Add-DpResult $Results $Section 'Incomplete configuration observation' UNVERIFIED 'An unexpected or incomplete API/configuration shape prevented this section from completing; private response details were suppressed.' 'Retry validation; if reproducible, review the API schema and validator support before activation.' }
}

function Invoke-DpValidation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $Config, [Parameter(Mandatory)][string] $YamlAssemblyPath)
    Test-DpInputs $Config
    $lock=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'dependencies.lock.json') -Raw | ConvertFrom-Json -AsHashtable
    if ((Get-FileHash -LiteralPath $YamlAssemblyPath).Hash.ToLowerInvariant() -cne $lock.yamlDotNet.assemblySha256) { throw 'Untrusted YAML parser assembly.' }
    Add-Type -LiteralPath $YamlAssemblyPath
    $results=[Collections.Generic.List[object]]::new()
    $script:Requests=0; $script:Timer=[Diagnostics.Stopwatch]::StartNew()
    $handler=[Net.Http.HttpClientHandler]::new(); $handler.AllowAutoRedirect=$false
    $script:Client=[Net.Http.HttpClient]::new($handler)
    $script:Client.Timeout=[TimeSpan]::FromSeconds(20)
    $script:Client.MaxResponseContentBufferSize=4194304
    $script:Client.DefaultRequestHeaders.UserAgent.ParseAdd('CLC-Deployment-Prerequisites/1')
    $script:Client.DefaultRequestHeaders.Accept.ParseAdd('application/vnd.github+json')
    $script:Client.DefaultRequestHeaders.Add('X-GitHub-Api-Version','2022-11-28')
    if ($env:GH_TOKEN) { $script:Client.DefaultRequestHeaders.Authorization=[Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$env:GH_TOKEN) }
    $commit=''
    try {
        $repo=Get-DpApi "/repos/$($Config.Repository)"
        $branch=Get-DpApi "/repos/$($Config.Repository)/branches/$([uri]::EscapeDataString($Config.IntegrationBranch))"
        $release=$null; $deployment=$null
        if ($repo.ok -and $branch.ok -and $repo.data -is [Collections.IDictionary] -and $repo.data['full_name'] -ieq $Config.Repository -and $branch.data -is [Collections.IDictionary] -and $branch.data['commit'] -is [Collections.IDictionary] -and $branch.data['commit']['sha'] -cmatch '^[0-9a-f]{40}$') {
            $commit=$branch.data['commit']['sha']
            Invoke-DpSection $results 'Repository configuration' { Get-DpBranchResults $Config $results $branch.data }
            Invoke-DpSection $results 'Repository configuration' { Get-DpTagResults $Config $results }
            $release=Get-DpWorkflow $Config $results $Config.ReleaseWorkflow $commit 'Release'
            $deployment=Get-DpWorkflow $Config $results $Config.DeploymentWorkflow $commit 'Deployment'
            Invoke-DpSection $results 'Repository configuration' { Get-DpWorkflowResults $Config $results $release $deployment }
        } else { Add-DpResult $results 'Repository configuration' 'Integration source inspection' UNVERIFIED 'Repository or integration branch identity could not be read reliably.' 'Verify contents: read and actions: read permissions, expected branch, repository access and API availability; retry.' }
        Invoke-DpSection $results 'GitHub Environment' { Get-DpEnvironmentResults $Config $results }
        Invoke-DpSection $results 'Deployment runner' { Get-DpRunnerResults $Config $results }
        Invoke-DpSection $results 'Deployment configuration' { Get-DpDeploymentResults $Config $results $deployment }
        Invoke-DpSection $results 'Host and toolkit' { Get-DpToolkitResults $Config $results $release $deployment }
        return Complete-DpReport $Config $results $commit
    } finally { $script:Client.Dispose(); $handler.Dispose(); $script:Timer.Stop() }
}

function Format-DpSummary {
    param([Parameter(Mandatory)] $Report)
    $lines=[Collections.Generic.List[string]]::new()
    $lines.Add("# Deployment prerequisites — $($Report.repository) / $($Report.channel)")
    $lines.Add('')
    $lines.Add("Environment: **$($Report.environment)**. Observed integration commit: ``$($Report.observed_commit)``.")
    foreach ($section in @('Repository configuration','GitHub Environment','Deployment runner','Deployment configuration','Host and toolkit')) {
        $lines.Add(''); $lines.Add("## $section"); $lines.Add('')
        $lines.Add('| Result | Check | Evidence / next action |'); $lines.Add('| --- | --- | --- |')
        foreach ($row in @($Report.results | Where-Object section -CEQ $section)) {
            $detail=($row.detail + ' ' + $row.action).Trim().Replace('|','&#124;').Replace('<','&lt;').Replace('>','&gt;').Replace("`n",' ').Replace("`r",' ')
            $lines.Add("| $($row.status) | $($row.name) | $detail |")
        }
    }
    $readiness=if ($Report.ready) { 'READY' } else { 'NOT READY' }
    $lines.Add(''); $lines.Add("Passed: **$($Report.passed_count)** · Failed: **$($Report.failed_count)** · Unverified: **$($Report.unverified_count)**")
    $lines.Add(''); $lines.Add("**Deployment readiness: $readiness**")
    $lines.Add(''); $lines.Add('Required next actions are listed beside every FAIL / UNVERIFIED result. Activation is configuration, never authorization. This report cannot replace deployment-engine checks or authorize deployment.')
    $lines.Add(''); $lines.Add("[Repository settings](https://github.com/$($Report.repository)/settings) · [Validator contract](https://github.com/clcdpc/clc-deployment/blob/master/docs/deployment-prerequisites.md)")
    return $lines -join "`n"
}

Export-ModuleMember -Function Invoke-DpValidation,Format-DpSummary

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $ApplicationId,
    [ValidateSet('DEV','Production')][string] $Channel = 'DEV',
    [ValidateNotNullOrEmpty()][string] $IntegrationBranch = 'master',
    [string] $RunnerGroup = '',
    [string] $ReleaseTagPattern = 'v*',
    [bool] $CheckReleaseImmutability = $true
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The reusable workflow supplies repository identity from github.repository.
if ($env:GITHUB_REPOSITORY -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'Invalid Actions repository context.' }
if ($env:GITHUB_SERVER_URL -cne 'https://github.com') { throw 'Only GitHub.com is supported.' }
if ($ApplicationId -cnotmatch '^[a-z0-9][a-z0-9-]{0,52}$' -or $IntegrationBranch -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_/-]{0,99}$' -or
    $RunnerGroup.Length -gt 128 -or $RunnerGroup -match '[\x00-\x1f\x7f]' -or $ReleaseTagPattern -cne 'v*') { throw 'Invalid setup input.' }
$EnvironmentName = $ApplicationId + '-' + $Channel.ToLowerInvariant()
$expectedLabels = @('self-hosted','Windows','X64',$EnvironmentName)
$repository = $env:GITHUB_REPOSITORY
$owner = $repository.Split('/')[0]
$repoPath = '/repos/' + $repository
$repoUrl = 'https://github.com/' + $repository
$groupUrl = 'https://github.com/organizations/' + $owner + '/settings/actions/runner-groups'
$guideUrl = 'https://github.com/clcdpc/clc-deployment/blob/' + (git -C $PSScriptRoot rev-parse HEAD) + '/docs/setup-guide.md'
if ($LASTEXITCODE -ne 0) { throw 'Cannot identify reviewed checker source.' }
$token = if ($env:CLC_INSPECTION_TOKEN) { $env:CLC_INSPECTION_TOKEN } else { $env:GITHUB_TOKEN }
if (-not $token) { throw 'A GitHub read token is required.' }
$headers = @{ Authorization='Bearer ' + $token; Accept='application/vnd.github+json'; 'X-GitHub-Api-Version'='2026-03-10' }
$requestCount = 0
$clock = [Diagnostics.Stopwatch]::StartNew()
$rows = [Collections.Generic.List[object]]::new()
$group = $null

function Uncertain([string] $Message) { throw [IO.InvalidDataException]::new($Message) }
function Require-Fields($Object, [string[]] $Names) {
    if ($Object -isnot [Collections.IDictionary]) { Uncertain 'Malformed API object.' }
    foreach ($name in $Names) { if (-not $Object.Contains($name) -or $null -eq $Object[$name]) { Uncertain 'Required API fields are unavailable.' } }
}
function Require-Bools($Object, [string[]] $Names) {
    Require-Fields $Object $Names
    foreach ($name in $Names) { if ($Object[$name] -isnot [bool]) { Uncertain 'Malformed boolean API setting.' } }
}
function Require-Strings($Object, [string[]] $Names) {
    Require-Fields $Object $Names
    foreach ($name in $Names) { if ($Object[$name] -isnot [string] -or [string]::IsNullOrWhiteSpace($Object[$name])) { Uncertain 'Malformed string API setting.' } }
}
function Read-GitHub([string] $Path) {
    if (++$script:requestCount -gt 100 -or $clock.Elapsed.TotalSeconds -gt 240) { Uncertain 'API inspection request/time budget reached.' }
    try {
        $response = Invoke-WebRequest -Uri ('https://api.github.com' + $Path) -Method Get -Headers $headers -ConnectionTimeoutSeconds 20 -OperationTimeoutSeconds 20 -MaximumRedirection 0 -SkipHttpErrorCheck
    } catch { Uncertain 'GitHub request failed or timed out; response details are withheld.' }
    if ($response.StatusCode -ne 200) {
        $reason = switch ([int]$response.StatusCode) {
            401 { 'authentication denied' }
            403 { 'permission denied or rate limited' }
            404 { 'not found or concealed by permissions; absence is not established' }
            default { 'API error or unsupported request' }
        }
        Uncertain "GitHub HTTP $($response.StatusCode): $reason."
    }
    if ($response.Content.Length -gt 4194304) { Uncertain 'API response exceeds inspection bound.' }
    try { $data = ConvertFrom-Json -InputObject $response.Content -AsHashtable -NoEnumerate -Depth 50 } catch { Uncertain 'Malformed GitHub JSON response.' }
    @{ Data=$data; Next=([string]($response.Headers['Link'] -join ',') -match 'rel="?next"?') }
}
function Read-List([string] $Path, [string] $Key = '', [int] $PageSize = 100) {
    $items = [Collections.Generic.List[object]]::new()
    $identities = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $total = $null
    for ($page=1; $page -le 10; $page++) {
        $separator = if ($Path.Contains('?')) { '&' } else { '?' }
        $response = Read-GitHub ($Path + $separator + "per_page=$PageSize&page=$page")
        $part = $response.Data
        if ($Key) {
            Require-Fields $part @($Key,'total_count')
            if ($part.total_count -isnot [long] -and $part.total_count -isnot [int]) { Uncertain 'Malformed API list total.' }
            if ($part.total_count -lt 0 -or ($null -ne $total -and $total -ne $part.total_count)) { Uncertain 'Contradictory API list totals.' }
            $total = $part.total_count
            $part = $part[$Key]
        }
        if ($part -isnot [array] -or $part.Count -gt $PageSize) { Uncertain 'Malformed API list.' }
        foreach ($item in $part) {
            Require-Fields $item @()
            $identity = if ($item.Contains('id')) { 'id:' + $item.id } elseif ($item.Contains('name')) { 'name:' + $item.name } elseif ($item.Contains('full_name')) { 'repository:' + $item.full_name } else { ConvertTo-Json -InputObject $item -Depth 50 -Compress }
            if (-not $identities.Add($identity)) { Uncertain 'Contradictory API pagination: duplicate resource or record.' }
            $items.Add($item)
        }
        if ($null -ne $total -and ($items.Count -gt $total -or ($items.Count -eq $total -and $response.Next))) { Uncertain 'Contradictory API pagination.' }
        if (-not $response.Next -and ($part.Count -lt $PageSize -or $items.Count -eq $total)) {
            if ($null -ne $total -and $items.Count -ne $total) { Uncertain 'Incomplete API pagination.' }
            return ,$items.ToArray()
        }
        if ($part.Count -eq 0) { Uncertain 'Incomplete API pagination.' }
    }
    Uncertain 'API pagination exceeds ten pages; inspect the complete list in GitHub.'
}
function Observation([string[]] $Missing = @(), [string[]] $Manual = @(), [string] $Confirmed) {
    $status = if ($Missing.Count) { 'NEEDS CONFIGURATION' } elseif ($Manual.Count) { 'CHECK MANUALLY' } else { 'CONFIGURED' }
    $details = @($Missing) + @($Manual)
    @{ Status=$status; Details=$(if ($details.Count) { $details -join ' ' } else { $Confirmed }) }
}
function Add-Category([string] $Name, [string] $Anchor, [string] $Url, [string] $Navigation, [string] $Expected, [scriptblock] $Inspect) {
    try { $result = & $Inspect } catch [IO.InvalidDataException] { $result = Observation -Manual $_.Exception.Message }
    $rows.Add(@{ Name=$Name; Status=$result.Status; Details=$result.Details; Guide="$guideUrl#$Anchor"; Url=$Url; Navigation=$Navigation; Expected=$Expected })
}
# Each independently enforcing, visible no-bypass ruleset can establish a control.
# Hidden or selected-actor bypass needs UI review; broad role bypass cannot establish it.
function Rule-Bypass($RuleSet) {
    if (-not $RuleSet.Contains('bypass_actors')) { return 'hidden' }
    if ($RuleSet.bypass_actors -isnot [array]) { Uncertain 'Malformed ruleset bypass settings.' }
    if (-not $RuleSet.bypass_actors.Count) { return 'none' }
    foreach ($actor in $RuleSet.bypass_actors) {
        Require-Strings $actor @('actor_type','bypass_mode')
        if ($actor.bypass_mode -cnotin @('always','pull_request','exempt')) { Uncertain 'Unsupported ruleset bypass mode.' }
        if ($actor.actor_type -in @('RepositoryRole','OrganizationAdmin','EnterpriseRole') -and $actor.bypass_mode -in @('always','exempt')) { return 'broad' }
    }
    'selected'
}
function Check-Controls([string[]] $Required, [string[]] $Present, [string[]] $Enforced, [bool] $Complete, [string[]] $Notes = @(), [string[]] $Bypassed = @(), [string[]] $UnknownBypass = @()) {
    $missing = @(); $manual = @()
    foreach ($control in $Required) {
        if ($control -in $Enforced) { continue }
        if ($control -notin $Present -and $Complete) { $missing += "Missing enforced $control restriction." }
        elseif ($Complete -and $control -in $Bypassed -and $control -notin $UnknownBypass) { $missing += "Broad administrator/role bypass defeats the $control restriction." }
        else { $manual += "Confirm $control enforcement and bypass in GitHub." }
    }
    if ($manual.Count) { $manual += $Notes }
    Observation -Missing $missing -Manual $manual -Confirmed 'Required restrictions and observable bypass confirmed.'
}

Add-Category 'Branch protection' '4-protect-master' "$repoUrl/settings/rules" 'Repository Settings > Rules > Rulesets / Settings > Branches' 'Existing integration branch; nonempty required status checks; force pushes and deletion restricted; no defeating bypass.' {
    $branches = Read-List "$repoPath/branches"
    foreach ($branch in $branches) { Require-Strings $branch @('name'); Require-Bools $branch @('protected') }
    $branchMatches = @($branches | Where-Object { $_.name -ceq $IntegrationBranch })
    if (-not $branchMatches.Count) { return Observation -Missing "Integration branch $IntegrationBranch does not exist." }
    if ($branchMatches.Count -ne 1) { Uncertain 'Contradictory branch list.' }
    $present = @(); $enforced = @(); $classicComplete = $false; $rulesComplete = $false
    $notes = @(); $bypassed = @(); $unknownBypass = @()
    try {
        $classic = (Read-GitHub "$repoPath/branches/$([uri]::EscapeDataString($IntegrationBranch))/protection").Data
        Require-Fields $classic @('enforce_admins','allow_force_pushes','allow_deletions')
        foreach ($name in @('enforce_admins','allow_force_pushes','allow_deletions')) { Require-Bools $classic[$name] @('enabled') }
        if (-not $classic.Contains('required_status_checks')) { Uncertain 'Classic required checks unavailable.' }
        if ($classic.required_status_checks) {
            Require-Fields $classic.required_status_checks @('contexts','checks')
            if ($classic.required_status_checks.contexts -isnot [array] -or $classic.required_status_checks.checks -isnot [array]) { Uncertain 'Malformed required checks.' }
            foreach ($context in $classic.required_status_checks.contexts) { if ($context -isnot [string] -or [string]::IsNullOrWhiteSpace($context)) { Uncertain 'Malformed required status-check context.' } }
            foreach ($check in $classic.required_status_checks.checks) { Require-Strings $check @('context') }
            if ($classic.required_status_checks.contexts.Count -or $classic.required_status_checks.checks.Count) { $present += 'status checks' }
        }
        if (-not $classic.allow_force_pushes.enabled) { $present += 'force push' }
        if (-not $classic.allow_deletions.enabled) { $present += 'deletion' }
        if ($classic.enforce_admins.enabled) { $enforced += $present } else { $bypassed += $present }
        $classicComplete = $true
    } catch [IO.InvalidDataException] { $notes += 'Classic protection: ' + $_.Exception.Message } # Rules can independently supply all controls.
    try {
        $rules = Read-List "$repoPath/rules/branches/$([uri]::EscapeDataString($IntegrationBranch))"
        $cache = @{}
        foreach ($rule in $rules) {
            Require-Strings $rule @('type'); Require-Fields $rule @('ruleset_id')
            $control = switch ($rule.type) { 'required_status_checks' { 'status checks' }; 'non_fast_forward' { 'force push' }; 'deletion' { 'deletion' } }
            if (-not $control) { continue }
            if ($control -eq 'status checks') {
                Require-Fields $rule @('parameters'); Require-Fields $rule.parameters @('required_status_checks')
                if ($rule.parameters.required_status_checks -isnot [array]) { Uncertain 'Malformed ruleset status checks.' }
                foreach ($check in $rule.parameters.required_status_checks) { Require-Strings $check @('context') }
                if (-not $rule.parameters.required_status_checks.Count) { continue }
            }
            $present += $control
            $id = [string]$rule.ruleset_id
            if ($id -notmatch '^[1-9][0-9]*$') { Uncertain 'Malformed ruleset identity.' }
            if (-not $cache.Contains($id)) { $cache[$id] = (Read-GitHub "$repoPath/rulesets/$id").Data }
            Require-Fields $cache[$id] @('id','enforcement','target')
            if ($cache[$id].id -ne $rule.ruleset_id -or $cache[$id].enforcement -cne 'active' -or $cache[$id].target -cne 'branch') { Uncertain 'Contradictory effective branch rules.' }
            switch (Rule-Bypass $cache[$id]) {
                'none' { $enforced += $control }
                'broad' { $bypassed += $control }
                default { $unknownBypass += $control }
            }
        }
        $rulesComplete = $true
    } catch [IO.InvalidDataException] { $notes += 'Effective rules: ' + $_.Exception.Message }
    if (-not $branchMatches[0].protected -and $enforced.Count) { Uncertain 'Branch protection indicator contradicts observed controls.' }
    if (-not $branchMatches[0].protected -and $rulesComplete -and -not $present.Count) { return Observation -Missing "Integration branch $IntegrationBranch has no effective branch protection." }
    Check-Controls @('status checks','force push','deletion') $present $enforced ($classicComplete -and $rulesComplete) $notes $bypassed $unknownBypass
}

Add-Category 'Tag protection' '3-protect-release-tags' "$repoUrl/settings/rules" 'Repository Settings > Rules > Rulesets > release-tag rules' "Active creation, update and deletion restrictions covering $ReleaseTagPattern, with controlled bypass." {
    if ($ReleaseTagPattern -cnotmatch '^[A-Za-z0-9._-]+\*$') { Uncertain 'Complex expected tag pattern; inspect full coverage and exclusions manually.' }
    $sets = Read-List "$repoPath/rulesets?includes_parents=true&targets=tag"
    $present = @(); $enforced = @(); $complete = $true; $bypassed = @(); $unknownBypass = @()
    foreach ($set in $sets) {
        Require-Fields $set @('id')
        if ([string]$set.id -notmatch '^[1-9][0-9]*$') { Uncertain 'Unrecognized ruleset identity.' }
        $detail = (Read-GitHub "$repoPath/rulesets/$($set.id)").Data
        Require-Fields $detail @('id'); Require-Strings $detail @('target','enforcement')
        if ($detail.id -ne $set.id -or $detail.target -cne 'tag') { Uncertain 'Contradictory tag ruleset.' }
        if ($detail.enforcement -cin @('disabled','evaluate')) { continue }
        if ($detail.enforcement -cne 'active') { Uncertain 'Unrecognized ruleset enforcement.' }
        Require-Fields $detail @('conditions','rules')
        Require-Fields $detail.conditions @('ref_name'); Require-Fields $detail.conditions.ref_name @('include','exclude')
        $conditions = $detail.conditions.ref_name
        if ($conditions.include -isnot [array] -or $conditions.exclude -isnot [array] -or $detail.rules -isnot [array]) { Uncertain 'Malformed tag ruleset conditions.' }
        $covers = $false
        foreach ($pattern in $conditions.include) {
            if ($pattern -isnot [string]) { Uncertain 'Malformed tag pattern.' }
            if ($pattern -ceq '~ALL') { $covers = $true }
            elseif ($pattern -cmatch '^refs/tags/([A-Za-z0-9._-]+)\*$') {
                if ($ReleaseTagPattern.StartsWith($Matches[1],[StringComparison]::Ordinal)) { $covers = $true }
            } else { $complete = $false }
        }
        if ($conditions.exclude.Count) { $complete = $false; continue }
        if (-not $covers) { continue }
        $bypass = Rule-Bypass $detail
        foreach ($rule in $detail.rules) {
            Require-Strings $rule @('type')
            if ($rule.type -in @('creation','update','deletion')) {
                $present += $rule.type
                if ($bypass -eq 'none') { $enforced += $rule.type }
                elseif ($bypass -eq 'broad') { $bypassed += $rule.type }
                else { $unknownBypass += $rule.type }
            }
        }
    }
    Check-Controls @('creation','update','deletion') $present $enforced $complete @() $bypassed $unknownBypass
}

Add-Category 'Restrict actors' '2-configure-restrict-actors' "$repoUrl/settings/actions/policies" 'Repository Settings > Actions > Policies > New policy > Restrict actors' 'Repository-wide native Restrict actors policy admits only authorized release developers and trusted automation.' {
    Observation -Manual 'Read-only APIs do not reliably expose this repository-wide policy. Review Restrict actors in GitHub; do not create a second application allowlist.'
}

Add-Category 'Workflow trigger' '9-verify-tag-deployments' "$repoUrl/tree/$IntegrationBranch/.github/workflows" 'Repository > Code > .github/workflows > application release workflow' 'Version-tag push only; package then publication then deployment using needs; caller runs at the tag, including unmerged DEV commits.' {
    Observation -Manual 'Review the tagged consumer workflow and immutable shared pins. No workflow_run or manual release trigger; ordinary build/test jobs use hosted runners. This diagnostic does not analyze workflow code.'
}

Add-Category 'Environment' '5-create-environments' "$repoUrl/settings/environments" "Repository Settings > Environments > $EnvironmentName > Deployment branches and tags / Deployment protection rules" 'No restriction for deployment branches and tags; no required reviewers or wait timer.' {
    $environments = Read-List "$repoPath/environments" 'environments'
    foreach ($item in $environments) { Require-Strings $item @('name') }
    $found = @($environments | Where-Object { $_.name -ieq $EnvironmentName })
    if (-not $found.Count) { return Observation -Missing "Environment $EnvironmentName does not exist." }
    if ($found.Count -ne 1) { Uncertain 'Contradictory environment list.' }
    $environment = $found[0]
    Require-Fields $environment @('protection_rules')
    if ($environment.protection_rules -isnot [array] -or -not $environment.Contains('deployment_branch_policy')) { Uncertain 'Environment protection settings unavailable.' }
    $missing = @(); $manual = @()
    if ($null -ne $environment.deployment_branch_policy) { $missing += 'Select No restriction for deployment branches and tags so unmerged DEV tags can deploy.' }
    foreach ($rule in $environment.protection_rules) {
        Require-Strings $rule @('type')
        switch ($rule.type) {
            'required_reviewers' { $missing += 'Required reviewers prevent automatic tag deployment.' }
            'wait_timer' {
                Require-Fields $rule @('wait_timer')
                if (($rule.wait_timer -isnot [int] -and $rule.wait_timer -isnot [long]) -or $rule.wait_timer -lt 0 -or $rule.wait_timer -gt 43200) { Uncertain 'Malformed environment wait timer.' }
                if ($rule.wait_timer -gt 0) { $missing += 'Remove the deployment wait timer.' }
            }
            'branch_policy' { }
            default { $manual += 'Review custom environment protection behavior.' }
        }
    }
    Observation -Missing $missing -Manual $manual -Confirmed "$EnvironmentName allows automatic version-tag deployment."
}

if ($RunnerGroup) {
    Add-Category 'Runner group' '6-register-deployment-runners' $groupUrl "Organization Settings > Actions > Runner groups > $RunnerGroup > Repository access" 'Optional organization group grants the application repository access; labels select the runner.' {
        $groups = Read-List "/orgs/$owner/actions/runner-groups" 'runner_groups'
        foreach ($item in $groups) { Require-Fields $item @('id'); Require-Strings $item @('name') }
        $found = @($groups | Where-Object { $_.name -ceq $RunnerGroup })
        if (-not $found.Count) { return Observation -Missing 'Requested optional runner group does not exist.' }
        if ($found.Count -ne 1 -or [string]$found[0].id -notmatch '^[1-9][0-9]*$') { Uncertain 'Ambiguous runner-group identity.' }
        $group=$found[0]; Require-Strings $group @('visibility')
        if ($group.visibility -ceq 'selected') {
            $repos=Read-List "/orgs/$owner/actions/runner-groups/$($group.id)/repositories" 'repositories'
            foreach ($item in $repos) { Require-Strings $item @('full_name') }
            if (-not @($repos | Where-Object { $_.full_name -ieq $repository }).Count) { return Observation -Missing 'Application repository is not admitted to the optional group.' }
        } elseif ($group.visibility -cne 'all') { Uncertain 'Review organization runner-group repository access.' }
        Observation -Confirmed 'Optional organization group grants repository access. No exact workflow allowlist is required by CLC.'
    }
}

Add-Category 'Runners' '6-register-deployment-runners' "$repoUrl/settings/actions/runners" 'Repository Settings > Actions > Runners (or Organization Settings > Actions > Runners)' "One online repository-accessible runner with labels: $($expectedLabels -join ', '). No runner group or routing variables required." {
    $runners=Read-List "$repoPath/actions/runners" 'runners'
    if (-not $runners.Count) { return Observation -Missing 'No repository-accessible deployment runner is registered.' }
    foreach ($runner in $runners) {
        Require-Strings $runner @('status'); Require-Fields $runner @('labels')
        if ($runner.status -cnotin @('online','offline') -or $runner.labels -isnot [array]) { Uncertain 'Malformed runner state.' }
        foreach ($label in $runner.labels) { Require-Strings $label @('name') }
        $actual=@($runner.labels | ForEach-Object { $_.name })
        if ($runner.status -ceq 'online' -and -not @($expectedLabels | Where-Object { $_ -notin $actual }).Count) { return Observation -Confirmed 'An online repository-accessible runner has every derived label.' }
    }
    Observation -Missing 'No online repository-accessible runner has all expected labels.'
}

if ($CheckReleaseImmutability) {
    Add-Category 'Release immutability' '3-protect-release-tags' "$repoUrl/settings#releases" 'Repository Settings > General > Releases > Release immutability' 'Enable release immutability (or owner-enforced immutability).' {
        $setting = (Read-GitHub "$repoPath/immutable-releases").Data
        Require-Bools $setting @('enabled','enforced_by_owner')
        if (-not $setting.enabled -and $setting.enforced_by_owner) { Uncertain 'Contradictory immutability settings.' }
        if (-not $setting.enabled) { return Observation -Missing 'Release immutability is not enabled.' }
        Observation -Confirmed 'Repository release immutability is enabled.'
    }
}

function Escape-Markdown([string] $Value) {
    $encoded = [Net.WebUtility]::HtmlEncode($Value)
    [regex]::Replace($encoded, '[\\`*{}_\[\]()|#!~\r\n]', { param($match) '&#' + [int][char]$match.Value[0] + ';' })
}
$configured = @($rows | Where-Object Status -CEQ 'CONFIGURED').Count
$needs = @($rows | Where-Object Status -CEQ 'NEEDS CONFIGURATION').Count
$manual = @($rows | Where-Object Status -CEQ 'CHECK MANUALLY').Count
$status = if ($needs) { 'NEEDS CONFIGURATION' } elseif ($manual) { 'CHECK MANUALLY' } else { 'CONFIGURED' }
$summary = [Collections.Generic.List[string]]::new()
$summary.Add('# GitHub Deployment Setup')
$summary.Add('')
foreach ($item in @(@('Repository',$repository),@('Branch',$IntegrationBranch),@('Environment',$EnvironmentName),@('Runner labels',($expectedLabels -join ', ')))) { $summary.Add("$($item[0]): $(Escape-Markdown $item[1])  ") }
$summary.Add('')
$summary.Add("Overall: **$status**  ")
$summary.Add("Configured: $configured | Needs configuration: $needs | Check manually: $manual")
$summary.Add('')
$summary.Add('| Status | Setting | Details |')
$summary.Add('| --- | --- | --- |')
foreach ($row in $rows) {
    $details = Escape-Markdown $row.Details
    if ($row.Status -cne 'CONFIGURED') { $details += ' Expected: ' + (Escape-Markdown $row.Expected) + ' GitHub UI: ' + (Escape-Markdown $row.Navigation) + ". [Open settings]($($row.Url))." }
    $summary.Add("| $($row.Status) | [$($row.Name)]($($row.Guide)) | $details |")
}
$summary.Add('')
$summary.Add('Optional GitHub configuration diagnostic. Separate host preparation, deployment preflight, authorization and application acceptance still apply.')
$text = ($summary -join "`n") + "`n"
if ($env:GITHUB_STEP_SUMMARY) { [IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY,$text) }
if ($env:GITHUB_OUTPUT) {
    [IO.File]::AppendAllText($env:GITHUB_OUTPUT,"status=$status`nconfigured_count=$configured`nneeds_configuration_count=$needs`nmanual_count=$manual`n")
}
$text

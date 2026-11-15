[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()][string] $IntegrationBranch = 'master',
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $EnvironmentName,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $RunnerGroup,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $RunnerLabels,
    [ValidateNotNullOrEmpty()][string] $ReleaseTagPattern = 'v*',
    [string] $RunnerGroupVariable = '',
    [string] $RunnerLabelsVariable = '',
    [string] $AdditionalVariableNames = '',
    [bool] $CheckReleaseImmutability = $true
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The reusable workflow supplies repository identity from github.repository, never an input.
if ($env:GITHUB_REPOSITORY -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'Invalid Actions repository context.' }
if ($env:GITHUB_SERVER_URL -cne 'https://github.com') { throw 'Only GitHub.com is supported.' }
foreach ($value in @($IntegrationBranch,$EnvironmentName,$RunnerGroup,$RunnerLabels,$ReleaseTagPattern)) {
    if ($value.Length -gt 256 -or $value -match '[\x00-\x1f\x7f]') { throw 'Invalid setup input.' }
}
function Split-Names([string] $Value) {
    if (-not $Value) { return }
    $names = @($Value.Split(',') | ForEach-Object { $_.Trim() })
    if ($names.Count -gt 30 -or @($names | Where-Object { -not $_ -or $_.Length -gt 100 -or $_ -match '[\x00-\x1f\x7f]' }).Count) { throw 'Invalid comma-separated names.' }
    $names | Sort-Object -Unique
}
$expectedLabels = @(Split-Names $RunnerLabels)
$variableNames = @(Split-Names (($RunnerGroupVariable,$RunnerLabelsVariable,$AdditionalVariableNames | Where-Object { $_ }) -join ','))
foreach ($name in $variableNames) { if ($name -cnotmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw 'Invalid variable name.' } }
if ($RunnerGroupVariable.Contains(',') -or $RunnerLabelsVariable.Contains(',')) { throw 'Runner variable inputs accept one name each.' }
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
function Same-Labels([string[]] $Left, [string[]] $Right) { (@($Left | Sort-Object -Unique) -join ',').ToLowerInvariant() -ceq (@($Right | Sort-Object -Unique) -join ',').ToLowerInvariant() }

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

Add-Category 'Branch protection' '2-configure-the-repository' "$repoUrl/settings/rules" 'Repository Settings > Rules > Rulesets / Settings > Branches' 'Existing integration branch; nonempty required status checks; force pushes and deletion restricted; no defeating bypass.' {
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
    $sets = Read-List "$repoPath/rulesets?includes_parents=true"
    $present = @(); $enforced = @(); $complete = $true; $bypassed = @(); $unknownBypass = @()
    foreach ($set in $sets) {
        Require-Fields $set @('id'); Require-Strings $set @('target','enforcement')
        if ($set.target -ne 'tag' -or $set.enforcement -in @('disabled','evaluate')) { continue }
        if ($set.enforcement -cne 'active' -or [string]$set.id -notmatch '^[1-9][0-9]*$') { Uncertain 'Unrecognized ruleset settings.' }
        $detail = (Read-GitHub "$repoPath/rulesets/$($set.id)").Data
        Require-Fields $detail @('id','target','enforcement','conditions','rules')
        if ($detail.id -ne $set.id -or $detail.target -cne 'tag' -or $detail.enforcement -cne 'active') { Uncertain 'Contradictory tag ruleset.' }
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

Add-Category 'Environment' '5-configure-github-environments' "$repoUrl/settings/environments" "Repository Settings > Environments > $EnvironmentName > Deployment branches and tags / Deployment protection rules" "Selected branches and tags: exactly branch $IntegrationBranch; no human approval gate for unattended execution." {
    $environments = Read-List "$repoPath/environments" 'environments'
    foreach ($item in $environments) { Require-Strings $item @('name') }
    $found = @($environments | Where-Object { $_.name -ieq $EnvironmentName })
    if (-not $found.Count) { return Observation -Missing "Environment $EnvironmentName does not exist." }
    if ($found.Count -ne 1) { Uncertain 'Contradictory environment list.' }
    $environment = $found[0]
    Require-Fields $environment @('protection_rules')
    if ($environment.protection_rules -isnot [array] -or -not $environment.Contains('deployment_branch_policy')) { Uncertain 'Environment protection settings unavailable.' }
    $missing = @(); $manual = @()
    $policy = $environment.deployment_branch_policy
    if ($null -eq $policy) { $missing += 'Environment allows unrestricted branches/tags.' }
    else {
        Require-Bools $policy @('custom_branch_policies','protected_branches')
        if (-not $policy.custom_branch_policies -or $policy.protected_branches) { $missing += 'Environment must select only the expected integration branch.' }
        else {
            $policies = Read-List "$repoPath/environments/$([uri]::EscapeDataString($EnvironmentName))/deployment-branch-policies" 'branch_policies'
            foreach ($item in $policies) { Require-Strings $item @('name','type') }
            if ($policies.Count -ne 1 -or $policies[0].name -cne $IntegrationBranch -or $policies[0].type -cne 'branch') { $missing += 'Environment branch/tag rules differ from the single expected branch.' }
        }
    }
    foreach ($rule in $environment.protection_rules) {
        Require-Strings $rule @('type')
        switch ($rule.type) {
            'required_reviewers' { $missing += 'Required reviewers prevent unattended deployment.' }
            'wait_timer' {
                Require-Fields $rule @('wait_timer')
                if (($rule.wait_timer -isnot [int] -and $rule.wait_timer -isnot [long]) -or $rule.wait_timer -lt 0 -or $rule.wait_timer -gt 43200) { Uncertain 'Malformed environment wait timer.' }
            }
            'branch_policy' { }
            default { $manual += 'Review custom environment protection behavior.' }
        }
    }
    Observation -Missing $missing -Manual $manual -Confirmed "$EnvironmentName selects only $IntegrationBranch with visible unattended protections."
}

Add-Category 'Runner group' '6-configure-self-hosted-runners' $groupUrl "Organization Settings > Actions > Runner groups > $RunnerGroup > Repository access / Workflow access" 'Selected repositories including this caller; matching public eligibility; Selected workflows with only approved definitions at explicit protected refs or full commits.' {
    $groups = Read-List "/orgs/$owner/actions/runner-groups" 'runner_groups'
    foreach ($item in $groups) { Require-Fields $item @('id'); Require-Strings $item @('name') }
    $found = @($groups | Where-Object { $_.name -ceq $RunnerGroup })
    if (-not $found.Count) { return Observation -Missing "Runner group $RunnerGroup does not exist; its settings cannot yet be inspected." }
    if ($found.Count -ne 1 -or [string]$found[0].id -notmatch '^[1-9][0-9]*$') { Uncertain 'Ambiguous runner-group identity.' }
    $script:group = $found[0]
    Require-Strings $group @('visibility'); Require-Fields $group @('selected_workflows'); Require-Bools $group @('allows_public_repositories','restricted_to_workflows')
    if ($group.selected_workflows -isnot [array]) { Uncertain 'Runner workflow allowlist unavailable.' }
    $missing = @(); $manual = @()
    if ($group.visibility -cne 'selected') { $missing += 'Runner group must use Selected repositories.' }
    else {
        $repos = Read-List "/orgs/$owner/actions/runner-groups/$($group.id)/repositories" 'repositories'
        foreach ($item in $repos) { Require-Strings $item @('full_name') }
        if (-not @($repos | Where-Object { $_.full_name -ieq $repository }).Count) { $missing += 'Consumer repository is not admitted to the selected runner group.' }
    }
    $metadata = (Read-GitHub $repoPath).Data
    Require-Bools $metadata @('private')
    if ($group.allows_public_repositories -eq $metadata.private) { $missing += 'Public-repository eligibility does not match caller visibility.' }
    if (-not $group.restricted_to_workflows -or -not $group.selected_workflows.Count) { $missing += 'Selected workflows must be enforced with a nonempty allowlist.' }
    else {
        foreach ($entry in $group.selected_workflows) {
            if ($entry -isnot [string]) { Uncertain 'Malformed selected workflow entry.' }
            if ($entry -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/\.github/workflows/[A-Za-z0-9_.-]+\.ya?ml@(.+)$') { $missing += 'Workflow access contains a wildcard or nonexplicit workflow definition.'; break }
            $ref = $Matches[1]
            if ($ref -cnotmatch '^[a-f0-9]{40}$' -and $ref -cne "refs/heads/$IntegrationBranch") { $manual += 'Confirm workflow allowlist refs are independently protected and intended.'; break }
        }
    }
    Observation -Missing $missing -Manual $manual -Confirmed 'Selected repository and explicit workflow restrictions observed; operator owns the exact approved allowlist.'
}

Add-Category 'Runners' 'register-runners-and-configure-labels' $groupUrl "Organization Settings > Actions > Runner groups > $RunnerGroup > Runners" "One online runner in this exact group with all labels: $($expectedLabels -join ', ')." {
    if ($null -eq $group) { Uncertain 'Expected runner group could not be resolved; inspect its registrations after resolving the group.' }
    $runners = Read-List "/orgs/$owner/actions/runner-groups/$($group.id)/runners" 'runners'
    if (-not $runners.Count) { return Observation -Missing 'Expected runner group has no registered runners.' }
    $online = 0
    foreach ($runner in $runners) {
        Require-Strings $runner @('status'); Require-Fields $runner @('labels')
        if ($runner.status -cnotin @('online','offline') -or $runner.labels -isnot [array]) { Uncertain 'Malformed runner state.' }
        if ($runner.status -ne 'online') { continue }
        $online++
        foreach ($label in $runner.labels) { Require-Strings $label @('name') }
        $actual = @($runner.labels | ForEach-Object { $_.name })
        if (-not @($expectedLabels | Where-Object { $_ -notin $actual }).Count) { return Observation -Confirmed 'An online runner in the expected group has every expected label.' }
    }
    Observation -Missing $(if ($online) { 'No online runner in this group has all expected labels.' } else { 'No runner in the expected group is online.' })
}

Add-Category 'Actions variables' '7-configure-deployment-routing-and-activation' "$repoUrl/settings/variables/actions" 'Repository Settings > Secrets and variables > Actions > Variables' "Requested repository variable names exist; selected runner variables match $RunnerGroup and the expected labels. Activation may remain false." {
    if (-not $variableNames.Count) { return Observation -Confirmed 'No repository variable names requested.' }
    $variables = Read-List "$repoPath/actions/variables" 'variables' 30
    $missing = @(); $manual = @()
    foreach ($variable in $variables) { Require-Strings $variable @('name') }
    foreach ($name in $variableNames) {
        $found = @($variables | Where-Object { $_.name -ieq $name })
        if (-not $found.Count) { $missing += "Repository variable $name does not exist."; continue }
        if ($found.Count -ne 1) { Uncertain 'Contradictory repository variable list.' }
        if ($name -ieq $RunnerGroupVariable -or $name -ieq $RunnerLabelsVariable) {
            if (-not $found[0].Contains('value') -or $found[0].value -isnot [string]) { $manual += "Value of $name is unavailable."; continue }
            if ($name -ieq $RunnerGroupVariable -and $found[0].value -cne $RunnerGroup) { $missing += "Runner-group variable $name differs from expected group." }
            if ($name -ieq $RunnerLabelsVariable) {
                # Malformed observed values are discrepancies, not input validation errors.
                $labels = @($found[0].value.Split(',') | ForEach-Object { $_.Trim() })
                if (-not (Same-Labels $labels $expectedLabels)) { $missing += "Runner-label variable $name differs from expected labels." }
            }
        }
    }
    Observation -Missing $missing -Manual $manual -Confirmed 'Requested variable names and expected runner values confirmed; activation values are not interpreted.'
}

if ($CheckReleaseImmutability) {
    Add-Category 'Release immutability' 'configure-release-immutability' "$repoUrl/settings#releases" 'Repository Settings > General > Releases > Release immutability' 'Enable release immutability (or owner-enforced immutability).' {
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
foreach ($item in @(@('Repository',$repository),@('Branch',$IntegrationBranch),@('Environment',$EnvironmentName),@('Runner group',$RunnerGroup))) { $summary.Add("$($item[0]): $(Escape-Markdown $item[1])  ") }
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

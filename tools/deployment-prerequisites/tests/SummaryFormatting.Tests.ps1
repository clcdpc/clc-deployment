BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '../Validation.psm1') -Force
}

Describe 'Prerequisite summary presentation' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'Fixtures.ps1')
        function ConvertFrom-SummaryText([string] $Text) { [Net.WebUtility]::HtmlDecode($Text) }
        function Get-PrimaryRows([string] $Summary) {
            ,@((($Summary -split '<details>',2)[0] -split "`n") | Where-Object {$_ -match '^\| \*\*(FAIL|UNVERIFIED|SKIPPED)\*\* ·'})
        }
        function Get-TechnicalDetails([string] $Summary) {
            (($Summary -split '<details><summary>Technical details</summary>',2)[1] -split '</details>',2)[0]
        }
        function ConvertTo-SummaryText($Value) {
            & (Get-Module Validation) {param($Text) ConvertTo-ClcDeploymentPrerequisiteText $Text} $Value
        }
        function New-CommissioningSummaryFixture {
            $rows=@(
                foreach ($id in @('github.environment.exists','github.runner.group','github.tags.creation','github.tags.update','github.tags.deletion','github.workflow.release-trigger')) {
                    New-ClcDeploymentPrerequisiteCheck $id FAIL "Full confirmed failure evidence for $id; preserve this qualification." "Full original corrective action for $id under independent infrastructure authority."
                }
                foreach ($id in @('github.workflow.completion-trigger','github.workflow.shared-identity','github.workflow.shared-definition','github.routing.target','github.routing.channel','github.tags.authority','github.branch.bypass-visibility','host.application.acceptance')) {
                    New-ClcDeploymentPrerequisiteCheck $id UNVERIFIED "Insufficient observation evidence for $id." "Full original verification action for $id."
                }
                foreach ($pair in @(@('github.environment.restrictions','github.environment.exists'),@('github.runner.repository-access','github.runner.group'),@('github.runner.workflow-access','github.runner.group'),@('github.runner.labels','github.runner.group'),@('github.workflow.additional-jobs','github.runner.group'),@('host.stage','stage-incomplete'))) {
                    New-ClcDeploymentPrerequisiteCheck $pair[0] SKIPPED "Inspection did not execute because $($pair[1]) was not established." 'Full original prerequisite setup and verification instructions.' -Reason $pair[1]
                }
                foreach ($id in @('github.repository.identity','github.branch.protection','github.branch.force-push','github.branch.deletion','github.branch.required-checks','github.branch.bypass','github.tags.bypass','github.workflow.producer','github.workflow.caller','github.runner.visibility','github.workflow.manual-selection','host.toolkit.authentication','host.identity.permissions')) {
                    New-ClcDeploymentPrerequisiteCheck $id PASS "Full successful evidence for $id."
                }
                New-ClcDeploymentPrerequisiteCheck host.standing.policy NOT_APPLICABLE 'No optional standing policy was selected.' -Reason not-selected
                New-ClcDeploymentPrerequisiteCheck host.state.current-release NOT_APPLICABLE 'Verified empty target.' -Reason empty-target
            )
            New-ClcDeploymentPrerequisiteReport (New-ValidationConfig) $rows ('b'*40)
        }
    }
    BeforeEach {
        $config=New-ValidationConfig
        $report=New-CommissioningSummaryFixture
    }

    It 'renders the representative 6/8/6/13/2 NOT READY checklist and preserved category results' {
        $summary=Format-ClcDeploymentPrerequisiteSummary $report
        $summary | Should -Match '^# NOT READY\n'
        $summary | Should -Match 'GitHub: \*\*FAIL\*\* \| Host: \*\*UNVERIFIED\*\*'
        $summary | Should -Match 'Failed: 6 \| Unverified: 8 \| Skipped: 6 \| Passed: 13 \| N/A: 2'
        $visible=ConvertFrom-SummaryText (($summary -split '<details>',2)[0])
        foreach ($value in @('Repository: example/app','Application: app','Target: app-dev','Environment: app-dev','Channel: DEV')) {
            $visible | Should -Match ([regex]::Escape($value))
        }
        $visible | Should -Not -Match 'Observed commit|Integration branch'
        $primary=Get-PrimaryRows $summary
        $primary.Count | Should -Be 18
        foreach ($i in 0..3) {
            $primary[$i] | Should -Match '^\| \*\*FAIL\*\* · Required \|'
            $cells=(ConvertFrom-SummaryText $primary[$i]).Split('|')
            $cells[2].Trim().Length | Should -BeLessOrEqual 40
            $cells[3].Trim().Length | Should -BeLessOrEqual 1800
            $cells[3] | Should -Not -Match 'See technical details'
        }
        foreach ($i in 4..11) {$primary[$i] | Should -Match '\*\*UNVERIFIED\*\*'}
        foreach ($i in 12..17) {$primary[$i] | Should -Match '\*\*SKIPPED\*\*'}
        $summary.IndexOf($primary[3]) | Should -BeLessThan $summary.IndexOf('<details>')
    }
    It 'renders READY and avoids an empty outstanding table' {
        $ready=New-ClcDeploymentPrerequisiteReport $config @((New-PassingStageChecks github)+(New-PassingStageChecks host))
        $summary=Format-ClcDeploymentPrerequisiteSummary $ready
        $summary | Should -Match '^# READY\n'
        $summary | Should -Match 'GitHub: \*\*PASS\*\* \| Host: \*\*PASS\*\*'
        $summary | Should -Match 'No outstanding prerequisites\.'
        $summary | Should -Not -Match '\| Next step \|'
        $ready.ready | Should -BeTrue
    }
    It 'uses report counts and does not confuse PASS with NOT_APPLICABLE' {
        $summary=ConvertFrom-SummaryText (Format-ClcDeploymentPrerequisiteSummary $report)
        $report.counts.passed | Should -Be 13
        $report.counts.not_applicable | Should -Be 2
        $summary | Should -Match '<summary>Passed and not applicable checks \(15\)</summary>'
        $success=($summary -split '<summary>Passed and not applicable checks \(15\)</summary>',2)[1] -split '</details>',2
        @($success[0] -split "`n" | Where-Object {$_ -match '^\| PASS \|'}).Count | Should -Be 13
        @($success[0] -split "`n" | Where-Object {$_ -match '^\| NOT_APPLICABLE \|'}).Count | Should -Be 2
        $success[0] | Should -Match '\| NOT_APPLICABLE \| Advisory \| Optional standing policy \|'
        (Get-PrimaryRows $summary) -join "`n" | Should -Not -Match '\*\*(PASS|NOT_APPLICABLE)\*\*'
    }
    It 'includes every outstanding finding with three primary columns and distinct grouped corrections' {
        $summary=Format-ClcDeploymentPrerequisiteSummary $report
        $summary | Should -Match '\| Status \| Prerequisite \| Explanation \|'
        $primary=Get-PrimaryRows $summary
        $presentation=& (Get-Module Validation) {Get-ClcDeploymentPrerequisitePresentation}
        foreach ($row in @($report.checks | Where-Object status -In FAIL,UNVERIFIED,SKIPPED)) {
            $entry=$presentation[$row.id]
            if ($row.id -like 'github.tags.*' -and $row.status -ceq 'FAIL') {
                @($primary | Where-Object { $_ -match ('href="[^"]+#'+$entry.anchor+'"') }).Count | Should -Be 1
            } else {
                @($primary | Where-Object { $_.Split('|')[2].Trim() -ceq $entry.label }).Count | Should -Be 1
            }
        }
        $primary.Count | Should -Be 18
        $report.counts.failed | Should -Be 6
        foreach ($line in $primary) {$line.Split('|').Count | Should -Be 5}
    }
    It 'sorts globally by status, required/advisory, category and ordinal ID regardless of input order' {
        $rows=@(
            New-ClcDeploymentPrerequisiteCheck github.workflow.producer FAIL 'Producer failure.' 'Original action.'
            New-ClcDeploymentPrerequisiteCheck github.branch.required-checks FAIL 'Branch failure.' 'Original action.'
            New-ClcDeploymentPrerequisiteCheck host.iis.configuration FAIL 'Host failure.' 'Original action.'
            New-ClcDeploymentPrerequisiteCheck host.standing.policy FAIL 'Advisory host failure.' 'Original action.'
            New-ClcDeploymentPrerequisiteCheck github.routing.activation FAIL 'Advisory GitHub failure.' 'Original action.'
            New-ClcDeploymentPrerequisiteCheck github.environment.exists UNVERIFIED 'Unavailable evidence.' 'Original action.'
            New-ClcDeploymentPrerequisiteCheck github.runner.labels SKIPPED 'Dependency unavailable.' 'Original action.' -Reason github.runner.group
        )
        $r=New-ClcDeploymentPrerequisiteReport $config $rows
        $r.checks=@($r.checks | Sort-Object id -Descending)
        $summary=Format-ClcDeploymentPrerequisiteSummary $r
        $primary=Get-PrimaryRows $summary
        $expected=@('Branch status checks','Release workflow','IIS configuration','Target activation','Optional standing policy','Deployment environment','Runner labels')
        for ($i=0;$i -lt $expected.Count;$i++) {$primary[$i].Split('|')[2].Trim() | Should -BeExactly $expected[$i]}
        $primary[2] | Should -Match 'FAIL.*Required'
        $primary[3] | Should -Match 'FAIL.*Advisory'
        $primary[4] | Should -Match 'FAIL.*Advisory'
        $primary[5] | Should -Match 'UNVERIFIED.*Required'
        $r.checks=@($r.checks | Sort-Object id)
        Format-ClcDeploymentPrerequisiteSummary $r | Should -BeExactly $summary
    }
    It 'uses ordinal rather than culture-dependent final ID ordering for future identities' {
        $r=New-ClcDeploymentPrerequisiteReport $config @($report.checks[0])
        $r.checks=@(foreach ($id in @('github.future.a','github.future.Z','github.future.A','github.future.a-b')) {
            [pscustomobject]@{id=$id;category='github';name='Identical title';status='FAIL';required=$true;detail='Evidence';action='Action';reason=''}
        })
        $originalCulture=[Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo('tr-TR')
            $primary=Get-PrimaryRows (ConvertFrom-SummaryText (Format-ClcDeploymentPrerequisiteSummary $r))
            ($primary | ForEach-Object {$_.Split('|')[2].Trim()}) -join ',' | Should -BeExactly 'github.future.A,github.future.Z,github.future.a,github.future.a-b'
        } finally {[Threading.Thread]::CurrentThread.CurrentCulture=$originalCulture}
    }
    It 'preserves visible advisory failures without changing READY or the underlying JSON' {
        $rows=@((New-PassingStageChecks github)+(New-PassingStageChecks host))
        $rows+=New-ClcDeploymentPrerequisiteCheck github.routing.activation FAIL 'Original advisory failure.' 'Original independent action.'
        $r=New-ClcDeploymentPrerequisiteReport $config $rows
        $before=ConvertTo-Json $r -Depth 16 -Compress
        $summary=Format-ClcDeploymentPrerequisiteSummary $r
        $summary | Should -Match '^# READY'
        (Get-PrimaryRows $summary)[0] | Should -Match '\*\*FAIL\*\* · Advisory \| Target activation'
        $summary | Should -Match 'Advisory findings do not block readiness'
        ConvertTo-Json $r -Depth 16 -Compress | Should -BeExactly $before
        $r.ready | Should -BeTrue
    }
    It 'shows failed stages, retained GitHub/host failures and skipped host inspection in the main view' {
        $g=New-ClcDeploymentPrerequisiteReport $config @(New-ClcDeploymentPrerequisiteCheck github.environment.exists FAIL 'Missing environment.' 'Original action.')
        $h=New-ClcDeploymentPrerequisiteReport $config @(New-ClcDeploymentPrerequisiteCheck host.iis.configuration FAIL 'Incorrect IIS configuration.' 'Original action.')
        $merged=Merge-ClcDeploymentPrerequisiteReports $g $h -GitHubJobResult failure -HostJobResult failure
        $visible=(Get-PrimaryRows (Format-ClcDeploymentPrerequisiteSummary $merged)) -join "`n"
        $visible | Should -Match 'FAIL.*Deployment environment'
        $visible | Should -Match 'FAIL.*IIS configuration'
        $visible | Should -Match 'UNVERIFIED.*GitHub inspection stage'
        $visible | Should -Match 'UNVERIFIED.*Host inspection stage'
        $skipped=Merge-ClcDeploymentPrerequisiteReports $g $null
        $primary=(Get-PrimaryRows (Format-ClcDeploymentPrerequisiteSummary $skipped)) -join "`n"
        $primary | Should -Match 'SKIPPED.*Host inspection stage.*Authorize and run the host inspection separately'
        $skipped.ready | Should -BeFalse
        $skipped.host_status | Should -Be UNVERIFIED
    }
    It 'explicitly reports an absent <Category> inspector without inventing check rows' -ForEach @(@{Category='github'},@{Category='host'}) {
        $other=if ($Category -ceq 'github') {'host'} else {'github'}
        $r=New-ClcDeploymentPrerequisiteReport $config @(New-PassingStageChecks $other)
        $summary=Format-ClcDeploymentPrerequisiteSummary $r
        $summary | Should -Match "$Category inspection: \*\*SKIPPED\*\*"
        @($r.checks | Where-Object category -CEQ $Category).Count | Should -Be 0
        $r.ready | Should -BeFalse
    }
    It 'distinguishes producer/caller and shared identity/definition despite identical original titles' {
        $rows=@(foreach ($id in @('github.workflow.producer','github.workflow.caller','github.workflow.shared-identity','github.workflow.shared-definition')) {
            New-ClcDeploymentPrerequisiteCheck $id UNVERIFIED 'Full original detail.' 'Full original action.' -Name 'Identical original title'
        })
        $r=New-ClcDeploymentPrerequisiteReport $config $rows
        $primary=Get-PrimaryRows (Format-ClcDeploymentPrerequisiteSummary $r)
        foreach ($label in @('Release workflow','Deployment workflow','Shared workflow identity','Shared workflow definition')) {
            @($primary | Where-Object {$_.Split('|')[2].Trim() -ceq $label}).Count | Should -Be 1
        }
        ($r.checks.name | Select-Object -Unique) | Should -BeExactly 'Identical original title'
        ($r.checks.id -join ',') | Should -BeExactly 'github.workflow.caller,github.workflow.producer,github.workflow.shared-definition,github.workflow.shared-identity'
    }
    It 'uses concise status-aware actions without concatenating or truncating original diagnostics' {
        $summary=ConvertFrom-SummaryText (Format-ClcDeploymentPrerequisiteSummary $report)
        $primary=(Get-PrimaryRows $summary) -join "`n"
        $primary | Should -Not -Match 'Full confirmed|Full original|Insufficient observation'
        $primary | Should -Match 'SKIPPED.*Runner workflow access \| Runner workflow access was not inspected\. Resolve prerequisite: Runner group\.'
        $primary | Should -Match 'UNVERIFIED.*Producer handoff \| Producer handoff could not be verified with the available evidence\. Inspect the protected release-to-deployment handoff\.'
        foreach ($line in @((Get-PrimaryRows $summary) | Where-Object {$_ -match '\*\*UNVERIFIED\*\*'})) {
            $line.Split('|')[3] | Should -Not -Match '\b(Create|Fix|missing|absent)\b'
        }
        Get-TechnicalDetails $summary | Should -Match 'Full original corrective action'
    }
    It 'uses source-owned dependency <Reason> and falls back safely for an unknown reason' -ForEach @(
        @{Reason='github.workflow.producer';Expected='Resolve prerequisite: Release workflow.'},
        @{Reason='workflow-source';Expected='Establish release and deployment workflow source first.'},
        @{Reason='host.filesystem.permissions/runtime.compatibility';Expected='Establish filesystem isolation and hosting components first.'},
        @{Reason='future-dependency';Expected='See technical details.'}
    ) {
        $row=New-ClcDeploymentPrerequisiteCheck github.workflow.completion-trigger SKIPPED 'Full original evidence.' 'Full original action.' -Reason $Reason
        $r=New-ClcDeploymentPrerequisiteReport $config @($row)
        $primary=Get-PrimaryRows (ConvertFrom-SummaryText (Format-ClcDeploymentPrerequisiteSummary $r))
        $primary[0].Split('|')[3].Trim() | Should -BeExactly ('Producer handoff was not inspected. '+$Expected)
    }
    It 'preserves all original technical fields in independent ordinal ID order' {
        $before=ConvertTo-Json $report -Depth 16 -Compress
        $summary=Format-ClcDeploymentPrerequisiteSummary $report
        $technical=ConvertFrom-SummaryText (Get-TechnicalDetails $summary)
        $technical | Should -Match 'Integration branch: master'
        $technical | Should -Match ('Observed commit: '+('b'*40))
        $last=-1
        foreach ($row in $report.checks) {
            $index=$technical.IndexOf("### $($row.id)`n",[StringComparison]::Ordinal)
            $index | Should -BeGreaterThan $last
            $last=$index
            $block=($technical.Substring($index) -split '\n### ',2)[0]
            foreach ($field in @('category','status','name','detail','action')) {
                $block | Should -Match ([regex]::Escape("- ${field}: $($row.$field)"))
            }
            $block | Should -Match $(if ($row.required) {'Impact: Required'} else {'Impact: Advisory'})
            if ($row.reason) {$block | Should -Match ([regex]::Escape('Dependency reason: '+$row.reason))}
        }
        ConvertTo-Json $report -Depth 16 -Compress | Should -BeExactly $before
        Format-ClcDeploymentPrerequisiteSummary $report | Should -BeExactly $summary
        (New-ClcDeploymentPrerequisiteReport $config $report.checks).ready | Should -Be $report.ready
    }
    It 'has distinct concise labels for every source-owned check without changing classifications' {
        $presentation=& (Get-Module Validation) {Get-ClcDeploymentPrerequisitePresentation}
        $definitions=& (Get-Module Validation) {Get-ClcDeploymentPrerequisiteDefinitions}
        @($definitions.Keys | Where-Object {-not $presentation.ContainsKey($_)}).Count | Should -Be 0
        @($presentation.Values | ForEach-Object {$_.label} | Select-Object -Unique).Count | Should -Be $definitions.Count
    }
    It 'does not render an empty success table' {
        $r=New-ClcDeploymentPrerequisiteReport $config @($report.checks | Where-Object status -EQ FAIL)
        Format-ClcDeploymentPrerequisiteSummary $r | Should -Not -Match 'Passed and not applicable checks'
    }
    It 'neutralizes Markdown and HTML while retaining readable text and literal entities' {
        $raw='| < > & ` [link](https://example.invalid) \ **bold** _em_ ![image] # @user &amp; </details>'
        $encoded=ConvertTo-SummaryText $raw
        ($encoded -replace '&#[0-9]+;','') | Should -Not -Match '[|<>&`\[\]\\*_!#@()]'
        ConvertFrom-SummaryText $encoded | Should -BeExactly $raw
        $encoded | Should -Match '&#124;.*&#60;.*&#62;.*&#38;.*&#96;.*&#91;'
        $encoded | Should -Not -Match '&amp;#'
    }
    It 'normalizes line breaks, controls and separators without adding rows or details blocks' {
        $payload="| </details><details><summary>Injected</summary>`r`n| FAIL | injected |`n`0`u{0009}`u{007f}`u{0085}`u{2028}`u{2029}`u{202e}"
        $report.subject.repository=$payload
        foreach ($row in $report.checks) {foreach ($field in @('name','detail','action','reason')) {$row.$field=$payload}}
        $summary=Format-ClcDeploymentPrerequisiteSummary $report
        ([regex]::Matches($summary,'<details>')).Count | Should -Be 2
        ([regex]::Matches($summary,'</details>')).Count | Should -Be 2
        ([regex]::Matches($summary,'<summary>')).Count | Should -Be 2
        $summary.Replace("`n",'') | Should -Not -Match '[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]'
        (Get-PrimaryRows $summary).Count | Should -Be 18
        foreach ($line in (Get-PrimaryRows $summary)) {$line.Split('|').Count | Should -Be 5}
        $summary | Should -Not -Match '\n\| FAIL \| injected'
        ConvertFrom-SummaryText (Get-TechnicalDetails $summary) | Should -Match ([regex]::Escape('| </details><details><summary>Injected</summary> | FAIL | injected | '))
    }
    It 'renders unknown IDs as distinct safely escaped text with conservative guidance' {
        $r=New-ClcDeploymentPrerequisiteReport $config @($report.checks[0])
        $r.checks=@(foreach ($id in @('github.future.|</details>','github.future.[link]')) {
            [pscustomobject]@{id=$id;category='github';name='Same original title';status='FAIL';required=$false;detail='Original detail';action='Original action';reason=''}
        })
        $summary=Format-ClcDeploymentPrerequisiteSummary $r
        $primary=Get-PrimaryRows $summary
        $primary.Count | Should -Be 2
        foreach ($line in $primary) {
            $line.Split('|').Count | Should -Be 5
            $line | Should -Match '· Advisory \|.*See technical details'
        }
        $summary | Should -Not -Match '\|</details>'
        (ConvertFrom-SummaryText ($primary -join "`n")) | Should -Match ([regex]::Escape('github.future.|</details>'))
        @($primary | Select-Object -Unique).Count | Should -Be 2
    }
    It 'renders real Markdown tables and inert dynamic HTML using the pinned PowerShell renderer' {
        $report.checks[0].detail='</details><script>injected</script> | [link](https://example.invalid)'
        $summary=Format-ClcDeploymentPrerequisiteSummary $report
        $html=(ConvertFrom-Markdown -InputObject $summary).Html
        ([regex]::Matches($html,'<table>')).Count | Should -Be 2
        ([regex]::Matches($html,'<details>')).Count | Should -Be 2
        ([regex]::Matches($html,'</details>')).Count | Should -Be 2
        ([regex]::Matches($html,'<th>')).Count | Should -Be 6
        $html | Should -Not -Match '<script>|<a href="https://example.invalid'
        $html | Should -Match '<ul>.*<li>.*<a href="https://github.com/clcdpc/clc-deployment/blob/master/docs/setup-guide.md#configure-release-tag-creation-restrictions"'
        $html | Should -Match '<td>The following findings need attention:<ul>(<li>.*?</li>){3}</ul></td>'
        $html | Should -Match '&#60;/details&#62;|&lt;/details&gt;|&#60;&#47;details&#62;'
    }
    It 'preserves unusually long evidence without arbitrary truncation or mutation' {
        $long=('Long | <evidence> & ` [x] \ '+('x'*30))*60
        $report.checks[0].detail=$long
        $report.checks[0].action=$long
        $before=ConvertTo-Json $report -Depth 16 -Compress
        $summary=Format-ClcDeploymentPrerequisiteSummary $report
        $technical=ConvertFrom-SummaryText (Get-TechnicalDetails $summary)
        $technical.Contains($long) | Should -BeTrue
        [Text.Encoding]::UTF8.GetByteCount($summary) | Should -BeLessThan 1048576
        ConvertTo-Json $report -Depth 16 -Compress | Should -BeExactly $before
    }
    It 'formats null and empty original optional values safely' {
        ConvertTo-SummaryText $null | Should -BeExactly ''
        ConvertTo-SummaryText '' | Should -BeExactly ''
        $report.checks[0].action=$null;$report.checks[0].reason='';$report.subject.observed_commit=''
        {Format-ClcDeploymentPrerequisiteSummary $report} | Should -Not -Throw
        $skipped=$report.checks | Where-Object status -CEQ SKIPPED | Select-Object -First 1
        $skipped.reason=$null
        {Format-ClcDeploymentPrerequisiteSummary $report} | Should -Not -Throw
    }
    It 'formats a JSON-round-tripped object as well as source-created dictionaries' {
        $copy=$report | ConvertTo-Json -Depth 16 | ConvertFrom-Json
        Format-ClcDeploymentPrerequisiteSummary $copy | Should -BeExactly (Format-ClcDeploymentPrerequisiteSummary $report)
    }
    It 'bounds oversized escaped evidence while retaining every checklist row, evidence identity and unchanged JSON' {
        foreach ($row in $report.checks) {foreach ($field in @('name','detail','action')) {$row.$field='<'*4096}}
        # Valid contract-3 input can still expand beyond GitHub's summary limit.
        ConvertTo-ClcDeploymentPrerequisiteStageReport $report | Should -Not -BeNullOrEmpty
        $before=ConvertTo-Json $report -Depth 16 -Compress
        $summary=Format-ClcDeploymentPrerequisiteSummary $report
        [Text.Encoding]::UTF8.GetByteCount($summary+"`n") | Should -BeLessOrEqual 1048576
        (Get-PrimaryRows $summary).Count | Should -Be 18
        $technical=Get-TechnicalDetails $summary
        $technical | Should -Match 'Complete escaped evidence exceeds the step-summary size limit'
        $technical | Should -Match 'unchanged JSON report'
        foreach ($row in $report.checks) {
            $technical | Should -Match ([regex]::Escape((ConvertTo-SummaryText $row.id)))
        }
        ConvertTo-Json $report -Depth 16 -Compress | Should -BeExactly $before
    }
    It 'publishes the exact existing Actions output names/values, appends the summary and leaves JSON unchanged' {
        $summaryPath=Join-Path $TestDrive 'summary.md';$outputs=Join-Path $TestDrive 'outputs.txt'
        $originalSummary=$env:GITHUB_STEP_SUMMARY;$originalOutputs=$env:GITHUB_OUTPUT
        $before=ConvertTo-Json $report -Depth 16 -Compress
        try {
            $env:GITHUB_STEP_SUMMARY=$summaryPath;$env:GITHUB_OUTPUT=$outputs
            [IO.File]::WriteAllText($summaryPath,"Existing summary`n")
            Publish-ClcDeploymentPrerequisiteReport $report
            [IO.File]::ReadAllText($outputs) | Should -BeExactly "github_status=FAIL`nhost_status=UNVERIFIED`nready=false`npassed_count=13`nfailed_count=6`nunverified_count=8`nskipped_count=6`nnot_applicable_count=2`n"
            [IO.File]::ReadAllText($summaryPath) | Should -BeExactly ("Existing summary`n"+(Format-ClcDeploymentPrerequisiteSummary $report)+"`n")
            ConvertTo-Json $report -Depth 16 -Compress | Should -BeExactly $before
        } finally {$env:GITHUB_STEP_SUMMARY=$originalSummary;$env:GITHUB_OUTPUT=$originalOutputs}
    }
    It 'groups three tag failures into one row with three specific linked bullets in ordinal ID order' {
        $summary=Format-ClcDeploymentPrerequisiteSummary $report
        $tags=@((Get-PrimaryRows $summary) | Where-Object {$_ -match '\| Release tag protection \|'})
        $tags.Count | Should -Be 1
        ([regex]::Matches($tags[0],'<li>')).Count | Should -Be 3
        ([regex]::Matches($tags[0],'</li>')).Count | Should -Be 3
        $anchors=@([regex]::Matches($tags[0],'href="https://github.com/clcdpc/clc-deployment/blob/master/docs/setup-guide.md#([^"]+)"') | ForEach-Object {$_.Groups[1].Value})
        $anchors -join ',' | Should -BeExactly 'configure-release-tag-creation-restrictions,configure-release-tag-deletion-restrictions,configure-release-tag-update-restrictions'
        $tags[0] | Should -Match '<a href="[^"]+">Enforce release&#45;tag creation restrictions'
        @((Get-PrimaryRows $summary) | Where-Object {$_ -match '\*\*FAIL\*\*'}).Count | Should -Be 4
        $summary | Should -Match 'Failed: 6'
    }
    It 'uses an ordinary explanation and a specific link for a single tag failure' {
        $r=New-ClcDeploymentPrerequisiteReport $config @(New-ClcDeploymentPrerequisiteCheck github.tags.creation FAIL 'Missing restriction.' 'Original action.')
        $primary=Get-PrimaryRows (Format-ClcDeploymentPrerequisiteSummary $r)
        $primary.Count | Should -Be 1
        $primary[0] | Should -Match '\| Release tag creation \|.*#configure-release-tag-creation-restrictions'
        $primary[0] | Should -Not -Match '<ul>|<li>'
    }
    It 'never merges confirmed, unverified and skipped findings from the same area' {
        $r=New-ClcDeploymentPrerequisiteReport $config @(
            (New-ClcDeploymentPrerequisiteCheck github.tags.creation FAIL 'Missing creation restriction.' 'Original action.'),
            (New-ClcDeploymentPrerequisiteCheck github.tags.update UNVERIFIED 'Denied evidence.' 'Original action.'),
            (New-ClcDeploymentPrerequisiteCheck github.tags.deletion SKIPPED 'Did not execute.' 'Original action.' -Reason inspection-incomplete)
        )
        $primary=Get-PrimaryRows (Format-ClcDeploymentPrerequisiteSummary $r)
        $primary.Count | Should -Be 3
        $primary[0] | Should -Match 'FAIL.*Required.*Release tag creation'
        $primary[1] | Should -Match 'UNVERIFIED.*Required.*Release tag updates'
        $primary[2] | Should -Match 'SKIPPED.*Required.*Release tag deletion'
        $primary -join "`n" | Should -Not -Match '<ul>'
    }
    It 'never merges different impacts or categories even for explicitly mapped group members' {
        $rows=@(foreach ($id in @('github.tags.creation','github.tags.update','github.tags.deletion')) {
            New-ClcDeploymentPrerequisiteCheck $id FAIL 'Confirmed observation.' 'Original action.'
        })
        # Deliberately synthetic presentation input proves the boundary independently of source classifications.
        $rows[1].required=$false
        $rows[2].category='host'
        $r=New-ClcDeploymentPrerequisiteReport $config $rows
        $before=$r | ConvertTo-Json -Depth 16 -Compress
        $primary=Get-PrimaryRows (Format-ClcDeploymentPrerequisiteSummary $r)
        $primary.Count | Should -Be 3
        $primary[0] | Should -Match 'FAIL.*Required.*Release tag creation'
        $primary[1] | Should -Match 'FAIL.*Required.*Release tag deletion'
        $primary[2] | Should -Match 'FAIL.*Advisory.*Release tag updates'
        $r | ConvertTo-Json -Depth 16 -Compress | Should -BeExactly $before
    }
    It 'groups only explicit setup areas, retaining every member action for <Area>' -ForEach @(
        @{Area='Integration branch protection';Ids=@('github.branch.force-push','github.branch.required-checks')},
        @{Area='Deployment environment';Ids=@('github.environment.exists','github.environment.restrictions')},
        @{Area='IIS configuration';Ids=@('host.iis.presence','host.iis.configuration','host.iis.environment')},
        @{Area='Deployment state';Ids=@('host.state.lock','host.state.consistency','host.state.inventory')}
    ) {
        $rows=@(foreach ($id in $Ids) {New-ClcDeploymentPrerequisiteCheck $id FAIL 'Confirmed observation.' 'Original action.'})
        $r=New-ClcDeploymentPrerequisiteReport $config $rows
        $before=$r | ConvertTo-Json -Depth 16 -Compress
        $primary=Get-PrimaryRows (Format-ClcDeploymentPrerequisiteSummary $r)
        $primary.Count | Should -Be 1
        $primary[0].Split('|')[2].Trim() | Should -BeExactly $Area
        ([regex]::Matches($primary[0],'<li>')).Count | Should -Be $Ids.Count
        ([regex]::Matches($primary[0],'<a href=')).Count | Should -Be $Ids.Count
        $r.counts.failed | Should -Be $Ids.Count
        $r | ConvertTo-Json -Depth 16 -Compress | Should -BeExactly $before
    }
    It 'keeps distinct runner corrections and unrelated GitHub/host areas separate' {
        $r=New-ClcDeploymentPrerequisiteReport $config @(
            (New-ClcDeploymentPrerequisiteCheck github.runner.group FAIL 'The expected deployment runner-group name was not configured.' 'Original group action.'),
            (New-ClcDeploymentPrerequisiteCheck github.runner.labels FAIL 'No online group runner has all expected labels.' 'Original labels action.'),
            (New-ClcDeploymentPrerequisiteCheck github.runner.workflow-access FAIL 'Wrong allowlist.' 'Original workflow action.'),
            (New-ClcDeploymentPrerequisiteCheck github.tags.creation FAIL 'Tag defect.' 'Original tag action.'),
            (New-ClcDeploymentPrerequisiteCheck host.iis.presence FAIL 'Host defect.' 'Original host action.')
        )
        $primary=Get-PrimaryRows (Format-ClcDeploymentPrerequisiteSummary $r)
        $primary.Count | Should -Be 5
        $primary[0] | Should -Match 'Runner group.*name is not configured.*#create-a-dedicated-runner-group'
        $primary[1] | Should -Match 'Runner labels.*No online runner.*#register-runners-and-configure-labels'
        $primary[2] | Should -Match 'Runner workflow access.*#restrict-runner-workflow-access'
        $primary[3] | Should -Match 'Release tag creation'
        $primary[4] | Should -Match 'IIS site and pool'
    }
    It 'provides actionable fixed documentation links for every source-owned failure without accepting diagnostic URLs' {
        $definitions=& (Get-Module Validation) {Get-ClcDeploymentPrerequisiteDefinitions}
        $presentation=& (Get-Module Validation) {Get-ClcDeploymentPrerequisitePresentation}
        $rows=@(foreach ($id in $definitions.Keys) {
            New-ClcDeploymentPrerequisiteCheck $id FAIL 'https://untrusted.invalid/ </a><script>x</script>' '[fix](https://untrusted.invalid/)'
        })
        $r=New-ClcDeploymentPrerequisiteReport $config $rows
        $before=$r | ConvertTo-Json -Depth 16 -Compress
        $summary=Format-ClcDeploymentPrerequisiteSummary $r
        $primary=(Get-PrimaryRows $summary) -join "`n"
        foreach ($id in $definitions.Keys) {
            $entry=$presentation[$id]
            $primary | Should -Match ([regex]::Escape('href="https://github.com/clcdpc/clc-deployment/blob/master/docs/setup-guide.md#'+$entry.anchor+'"'))
            $primary | Should -Match ([regex]::Escape('>'+ (ConvertTo-SummaryText $entry.failure)+'</a>'))
        }
        ([regex]::Matches($primary,'<a href=')).Count | Should -Be $definitions.Count
        $html=(ConvertFrom-Markdown -InputObject $summary).Html
        $html | Should -Not -Match '<script>|href="https://untrusted.invalid|href="[^"]*(placeholder|codex/)'
        $r | ConvertTo-Json -Depth 16 -Compress | Should -BeExactly $before
    }
    It 'uses conservative wording for denied evidence and preserves the manual-only architecture decision' {
        $r=New-ClcDeploymentPrerequisiteReport $config @(
            (New-ClcDeploymentPrerequisiteCheck github.environment.exists UNVERIFIED 'API 404 may conceal this resource.' 'Inspect with authorized read-only access.'),
            (New-ClcDeploymentPrerequisiteCheck github.workflow.release-trigger FAIL 'No push tag filter.' 'Original action.')
        )
        $primary=Get-PrimaryRows (ConvertFrom-SummaryText (Format-ClcDeploymentPrerequisiteSummary $r))
        $primary[0] | Should -Match 'FAIL.*no tag-push filter.*#review-intentional-workflow-differences.*resolve intentional workflow differences'
        $primary[1] | Should -Match 'UNVERIFIED.*could not be verified.*authorized read-only API access'
        $primary[1] | Should -Not -Match 'not found|missing|Create|absent'
    }
    It 'retains every actionable failure and identity in a near-limit all-check report' {
        $definitions=& (Get-Module Validation) {Get-ClcDeploymentPrerequisiteDefinitions}
        $rows=@(foreach ($id in $definitions.Keys) {New-ClcDeploymentPrerequisiteCheck $id FAIL ('<'*4096) ('<'*4096) -Name ('<'*4096)})
        $r=New-ClcDeploymentPrerequisiteReport $config $rows
        ConvertTo-ClcDeploymentPrerequisiteStageReport $r | Should -Not -BeNullOrEmpty
        $summary=Format-ClcDeploymentPrerequisiteSummary $r
        [Text.Encoding]::UTF8.GetByteCount($summary+"`n") | Should -BeLessOrEqual 1048576
        ([regex]::Matches((Get-PrimaryRows $summary) -join "`n",'<a href=')).Count | Should -Be $definitions.Count
        $technical=Get-TechnicalDetails $summary
        $technical | Should -Match 'unchanged JSON report'
        foreach ($id in $definitions.Keys) {$technical | Should -Match ([regex]::Escape((ConvertTo-SummaryText $id)))}
    }
}

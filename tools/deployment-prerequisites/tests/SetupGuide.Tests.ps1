BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '../Validation.psm1') -Force
}

Describe 'Operator setup documentation and report destinations' {
    BeforeAll {
        $root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
        $guidePath=Join-Path $root 'docs/setup-guide.md'
        $guide=Get-Content -LiteralPath $guidePath -Raw
        function Get-DocumentationAnchors([string] $Text) {
            # These source-owned headings use ASCII words; mirror GitHub punctuation removal.
            @([regex]::Matches($Text,'(?m)^#{1,6} (.+)\r?$') | ForEach-Object {
                ($_.Groups[1].Value.Trim().ToLowerInvariant() -replace '[^\w\- ]','') -replace ' ','-'
            })
        }
        function Assert-DocumentationDestination([string] $Path,[string] $Fragment) {
            Test-Path -LiteralPath $Path | Should -BeTrue -Because "documentation target $Path must exist"
            if ($Fragment) {
                Get-DocumentationAnchors (Get-Content -LiteralPath $Path -Raw) | Should -Contain $Fragment
            }
        }
    }
    It 'is the recommended README starting point with twelve ordered operator setup areas' {
        $guide | Should -Match '^# Deployment Setup Guide'
        Get-Content -LiteralPath (Join-Path $root 'README.md') -Raw | Should -Match '\[Deployment Setup Guide\]\(docs/setup-guide.md\)'
        $headings=@([regex]::Matches($guide,'(?m)^## (\d+)\. (.+)\r?$'))
        $headings.Count | Should -Be 12
        ($headings | ForEach-Object {$_.Groups[1].Value}) -join ',' | Should -BeExactly '1,2,3,4,5,6,7,8,9,10,11,12'
        foreach ($topic in @('Before you begin','Configure the repository','Protect release tags','Configure release and deployment workflows',
            'Configure GitHub environments','Configure self-hosted runners','Configure deployment routing and activation','Prepare the Windows/IIS host',
            'Install and configure the deployment toolkit','Verify host state and optional automation','Verify the completed setup','Troubleshooting and safe remediation')) {
            $headings.Groups.Value | Should -Contain $topic
        }
        $guide | Should -Not -Match '(?m)^#{1,6} .*\b(github|host)\.[a-z]+\.'
    }
    It 'resolves relative links and anchors in the guide and reconciled entry documents offline' {
        foreach ($relative in @('docs/setup-guide.md','README.md','docs/deployment-prerequisites.md','docs/github-setup.md',
            'docs/host-enrollment.md','docs/installation.md','docs/shared-release-orchestration.md','docs/contracts.md','docs/deployment.md')) {
            $path=Join-Path $root $relative
            $content=Get-Content -LiteralPath $path -Raw
            foreach ($match in [regex]::Matches($content,'(?<!!)\[[^\]\r\n]+\]\(([^\s)]+)\)')) {
                $target=$match.Groups[1].Value
                if ($target -match '^[a-z]+:') {continue}
                $parts=$target.Split('#',2)
                $resolved=if ($parts[0]) {Join-Path (Split-Path $path -Parent) $parts[0]} else {$path}
                Assert-DocumentationDestination $resolved $(if ($parts.Count -eq 2) {$parts[1]} else {''})
            }
        }
    }
    It 'links exact existing schemas and integration examples rather than copying configuration formats' {
        foreach ($target in @('../schemas/host-enrollment-authorization.schema.json','../schemas/deployment-configuration.schema.json',
            'examples/shared-conventional-build.yml','examples/shared-prequalified-build.yml','examples/shared-application-deploy.yml','examples/shared-release.json',
            'installation.md','host-enrollment.md','contracts.md','verified-workflow-integration.md')) {
            $guide | Should -Match ([regex]::Escape(']('+$target))
        }
    }
    It 'puts setup before verification and separates first deployment and independent authorization' {
        $guide.IndexOf('## 9. Install') | Should -BeLessThan $guide.IndexOf('### Run prerequisite verification')
        $guide.IndexOf('### Run prerequisite verification') | Should -BeLessThan $guide.IndexOf('### Authorize first deployment and acceptance')
        foreach ($statement in @('A diagnostic report does not authorize deployment','Routine deployment does not require running the checker',
            'A valid empty target can be READY','before first execution/import','Apply must have exact protected operation approval',
            'Never enable deployment merely to obtain a passing diagnostic','manual-only compatibility gap remains open',
            'Never delete locks, clear journals, replace protected records','qualification remain NOT RUN')) {
            $guide | Should -Match ([regex]::Escape($statement))
        }
    }
    It 'provides specific locally resolved source-owned setup destinations for every known failure' {
        $presentation=& (Get-Module Validation) {Get-ClcDeploymentPrerequisitePresentation}
        $definitions=& (Get-Module Validation) {Get-ClcDeploymentPrerequisiteDefinitions}
        foreach ($id in $definitions.Keys) {
            $entry=$presentation[$id]
            $entry.anchor | Should -Not -BeNullOrEmpty -Because "$id needs safe setup or investigation guidance"
            $entry.failure | Should -Not -BeNullOrEmpty
            $entry.finding | Should -Not -BeNullOrEmpty
            Assert-DocumentationDestination $guidePath $entry.anchor
            $entry.anchor | Should -Not -Match 'placeholder|<|>|codex/|deployment-setup-guide-and-report'
        }
        @($presentation.Keys | Where-Object {$definitions.Keys -cnotcontains $_}).Count | Should -Be 0
    }
}

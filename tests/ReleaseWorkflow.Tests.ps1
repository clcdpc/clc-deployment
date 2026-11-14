BeforeAll {
    . "$PSScriptRoot/Support.ps1"
    function Normalize-WorkflowLineEndings([string] $Text) {
        $Text.Replace("`r`n","`n").Replace("`r","`n")
    }
    $script:workflowPath=Join-Path $script:RepositoryRoot '.github/workflows/build-test-publish.yaml'
    $script:workflow=Normalize-WorkflowLineEndings ([IO.File]::ReadAllText($script:workflowPath))
    $script:workflowHeader=$script:workflow.Substring(0,$script:workflow.IndexOf('jobs:',[StringComparison]::Ordinal))
    $script:foundation=[regex]::Match($script:workflow,'(?ms)^  foundation:\r?\n(?<body>.*?)(?=^  publish:|\z)').Groups['body'].Value
    $script:publish=[regex]::Match($script:workflow,'(?ms)^  publish:\r?\n(?<body>.*)\z').Groups['body'].Value
}

Describe 'Shared release workflow permissions and artifact identity' {
    It 'normalizes Windows and Unix workflow line endings consistently' {
        $windowsWorkflow=[regex]::Replace($workflow,'(?<!\r)\n',"`r`n")
        Normalize-WorkflowLineEndings $windowsWorkflow | Should -BeExactly $workflow
    }

    It 'keeps pull request verification hosted and read-only' {
        $workflow | Should -Match '(?m)^  pull_request:\r?\n    branches: \[master\]$'
        $workflow | Should -Match '(?m)^permissions:\r?\n  contents: read$'
        $workflowHeader | Should -Not -Match 'pull_request_target|self-hosted|id-token:\s*write|contents:\s*write'
        $foundation | Should -Match '(?m)^    runs-on: windows-2022$'
        $foundation | Should -Not -Match 'id-token:\s*write|contents:\s*write|secrets\.'
        $publish | Should -Match "(?m)^    if: github\.event_name == 'push' && startsWith\(github\.ref, 'refs/tags/v'\)$"
    }

    It 'limits publication permission to protected release tags and excludes synthetic receipt tags' {
        $publish | Should -Match '(?m)^    environment: nuget-production$'
        $publish | Should -Match '(?ms)^    permissions:\r?\n      contents: write\r?\n      id-token: write$'
        $workflow | Should -Match "(?m)^    tags: \['v\*', '!v9999\.9999\.9999-dev\.\*'\]$"
        $workflow | Should -Match '(?m)^      - name: Validate shared release tag$'
        $workflow | Should -Match '(?m)^\s*uses: NuGet/login@[0-9a-f]{40}'
        $workflow | Should -Match '(?m)^          user: mfields$'
        $workflow | Should -Not -Match 'NUGET_PUBLISHER_USERNAME'
    }

    It 'publishes the exact tested artifacts from the producing run without rebuilding' {
        $foundation | Should -Match 'New-SharedReleaseArtifacts\.ps1'
        $foundation | Should -Match 'actions/upload-artifact@b7c566a772e6b6bfb58ed0dc250532a479d7789f # v6\.0\.0, Node\.js 24'
        $publish | Should -Match 'actions/download-artifact@37930b1c2abaa49bbe596cd826c3c89aef350131 # v7\.0\.0, Node\.js 24'
        $publish | Should -Match 'Test-SharedReleaseArtifacts\.ps1'
        $publish | Should -Match 'Publish-SharedRelease\.ps1'
        $publish | Should -Not -Match 'New-SharedReleaseArtifacts\.ps1|New-ToolkitDistribution\.ps1|dotnet pack'
        $publish | Should -Not -Match '--skip-duplicate|(?m)^\s+NUGET_API_KEY\s*:'
    }
}

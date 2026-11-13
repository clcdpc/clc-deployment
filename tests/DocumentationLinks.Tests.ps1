BeforeAll {
    . "$PSScriptRoot/Support.ps1"
    function Get-LocalMarkdownTargets([string] $Markdown,[string] $SourcePath) {
        foreach ($match in [regex]::Matches($Markdown,'(?<!!)\[[^\]]*\]\((?<target>[^)]+)\)')) {
            $target=$match.Groups['target'].Value.Trim()
            if ($target.StartsWith('<') -and $target.EndsWith('>')) { $target=$target.Substring(1,$target.Length-2) }
            $target=($target -split '[?#]',2)[0]
            if ([string]::IsNullOrWhiteSpace($target) -or $target -match '^(?i:([a-z][a-z0-9+.-]*:)?//)') { continue }
            if ($target -match '^(?i:mailto:|data:)') { continue }
            $target=[Uri]::UnescapeDataString($target)
            if ($target.StartsWith('/')) { $path=Join-Path $script:RepositoryRoot $target.TrimStart('/') }
            else { $path=Join-Path ([IO.Path]::GetDirectoryName($SourcePath)) $target }
            $resolved=[IO.Path]::GetFullPath($path)
            $repoPrefix=[IO.Path]::GetFullPath($script:RepositoryRoot).TrimEnd('\')+'\'
            if (-not $resolved.StartsWith($repoPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw "Markdown link escapes the repository: $target" }
            if (-not [IO.File]::Exists($resolved) -and -not [IO.Directory]::Exists($resolved)) { [pscustomobject]@{target=$target;path=$resolved} }
        }
    }
}

Describe 'Repository documentation links' {
    It 'resolves every relative Markdown link in the current tree' {
        $markdownFiles=@(
            Get-Item -LiteralPath (Join-Path $script:RepositoryRoot 'README.md')
            Get-Item -LiteralPath (Join-Path $script:RepositoryRoot 'AGENTS.md')
            Get-ChildItem -LiteralPath (Join-Path $script:RepositoryRoot 'docs') -Recurse -File -Filter '*.md'
            Get-Item -LiteralPath (Join-Path $script:RepositoryRoot 'tests/Fixtures/README.md')
            Get-Item -LiteralPath (Join-Path $script:RepositoryRoot 'tests/Qualification/README.md')
        )
        $broken=[Collections.Generic.List[string]]::new()
        foreach ($file in $markdownFiles) {
            $markdown=[IO.File]::ReadAllText($file.FullName)
            foreach ($target in (Get-LocalMarkdownTargets $markdown $file.FullName)) {
                $broken.Add(($file.FullName.Substring($script:RepositoryRoot.Length+1)+': '+$target.target))
            }
        }
        $broken | Should -BeNullOrEmpty
    }
}

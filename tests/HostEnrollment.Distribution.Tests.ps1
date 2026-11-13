BeforeAll {
    . "$PSScriptRoot/Support.ps1"
    . "$PSScriptRoot/HostEnrollment.Support.ps1"
    $script:distribution=New-HTestDistribution
}
AfterAll {Remove-TestWorkspace $script:distribution.workspace;Remove-TestWorkspace $script:HBootstrapWorkspace}
Describe 'Format-2 infrastructure distribution admission' {
    BeforeEach {$workspace=New-TestWorkspace}
    AfterEach {Remove-TestWorkspace $workspace}
    It 'reproduces identical exact distribution bytes in a separate pinned PowerShell process' {
        $path=Join-Path $workspace 'separate-process.zip'
        $info=[Diagnostics.ProcessStartInfo]::new([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
        $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
        foreach ($argument in @('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $script:RepositoryRoot 'tools/New-ToolkitDistribution.ps1'),'-RepositoryRoot',$distribution.repository,'-SourceCommit',$distribution.commit,'-OutputPath',$path)) {$info.ArgumentList.Add($argument)}
        $process=[Diagnostics.Process]::Start($info)
        try {
            $output=$process.StandardOutput.ReadToEndAsync();$errors=$process.StandardError.ReadToEndAsync()
            $process.WaitForExit(60000) | Should -BeTrue
            $process.ExitCode | Should -Be 0
            $output.GetAwaiter().GetResult().Length | Should -BeLessThan 8192
            $errors.GetAwaiter().GetResult().Length | Should -Be 0
            (Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() | Should -BeExactly $distribution.identity.distributionSha256
        } finally {if (-not $process.HasExited) {$process.Kill($true);$null=$process.WaitForExit(10000)};$process.Dispose()}
    }
    It 'verifies and installs the complete tools inventory outside the four-command module' {
        $versions=Join-Path $workspace 'versions';$null=[IO.Directory]::CreateDirectory($versions)
        $versionRoot=Join-Path $versions '0.1.0-dev.1'
        $result=& "$script:RepositoryRoot/tools/Expand-ToolkitDistribution.ps1" -ArchivePath $distribution.archive -ExpectedSha256 $distribution.identity.distributionSha256 -ExpectedSourceCommit $distribution.commit -ExpectedVersion '0.1.0-dev.1' -VersionRoot $versionRoot -OperatorApprovalReference synthetic-fixture
        $result.activated | Should -BeFalse
        $verified=& "$script:RepositoryRoot/tools/Test-ToolkitDistribution.ps1" -ArchivePath $distribution.archive -ExpectedSha256 $distribution.identity.distributionSha256 -ExpectedSourceCommit $distribution.commit -ExpectedVersion '0.1.0-dev.1' -InstalledModuleRoot (Join-Path $versionRoot 'CLC.Deployment') -RequireInfrastructureTools
        $verified.formatVersion | Should -Be 2
        @([IO.Directory]::EnumerateFiles((Join-Path $versionRoot 'CLC.Deployment\Public'))).Count | Should -Be 4
        Test-Path -LiteralPath (Join-Path $versionRoot 'tools\host\Get-ClcHostEnrollment.ps1') | Should -BeTrue
        $before=Get-TestTreeHashes $versionRoot
        {& "$script:RepositoryRoot/tools/Expand-ToolkitDistribution.ps1" -ArchivePath $distribution.archive -ExpectedSha256 $distribution.identity.distributionSha256 -ExpectedSourceCommit $distribution.commit -ExpectedVersion '0.1.0-dev.1' -VersionRoot $versionRoot -OperatorApprovalReference synthetic-fixture} | Should -Throw
        Get-TestTreeHashes $versionRoot | Should -BeExactly $before
    }
    It 'rejects <Change> infrastructure bytes despite an internally recomputed transport checksum' -ForEach @(@{Change='modified'},@{Change='missing'},@{Change='unexpected'}) {
        $entries=@(Get-TestZipEntries $distribution.archive)
        switch ($Change) {
            modified {($entries | Where-Object {$_.name -ceq 'tools/host/Get-ClcHostEnrollment.ps1'}).bytes=[Text.Encoding]::UTF8.GetBytes('throw "must never run"')}
            missing {$entries=@($entries | Where-Object {$_.name -cne 'tools/host/Get-ClcHostEnrollment.ps1'})}
            unexpected {$entries += @{name='tools/host/unapproved.ps1';bytes=[Text.Encoding]::UTF8.GetBytes('throw "must never run"');attributes=0}}
        }
        $archive=Join-Path $workspace 'changed.zip';New-TestZip $archive $entries
        $hash=(Get-FileHash -LiteralPath $archive).Hash.ToLowerInvariant()
        {& "$script:RepositoryRoot/tools/Test-ToolkitDistribution.ps1" -ArchivePath $archive -ExpectedSha256 $hash -ExpectedSourceCommit $distribution.commit -ExpectedVersion '0.1.0-dev.1' -RequireInfrastructureTools} | Should -Throw
        Test-Path -LiteralPath (Join-Path $workspace 'versions') | Should -BeFalse
    }
    It 'refuses installed tools drift and unknown tool directories' {
        $versions=Join-Path $workspace 'versions';$null=[IO.Directory]::CreateDirectory($versions);$versionRoot=Join-Path $versions '0.1.0-dev.1'
        $null=& "$script:RepositoryRoot/tools/Expand-ToolkitDistribution.ps1" -ArchivePath $distribution.archive -ExpectedSha256 $distribution.identity.distributionSha256 -ExpectedSourceCommit $distribution.commit -ExpectedVersion '0.1.0-dev.1' -VersionRoot $versionRoot -OperatorApprovalReference synthetic-fixture
        [IO.File]::AppendAllText((Join-Path $versionRoot 'tools\host\HostEnrollment.Common.ps1'),'# drift')
        {& "$script:RepositoryRoot/tools/Test-ToolkitDistribution.ps1" -ArchivePath $distribution.archive -ExpectedSha256 $distribution.identity.distributionSha256 -ExpectedSourceCommit $distribution.commit -ExpectedVersion '0.1.0-dev.1' -InstalledModuleRoot (Join-Path $versionRoot 'CLC.Deployment')} | Should -Throw
        $null=[IO.Directory]::CreateDirectory((Join-Path $versionRoot 'tools\unknown'))
        {& "$script:RepositoryRoot/tools/Test-ToolkitDistribution.ps1" -ArchivePath $distribution.archive -ExpectedSha256 $distribution.identity.distributionSha256 -ExpectedSourceCommit $distribution.commit -ExpectedVersion '0.1.0-dev.1' -InstalledModuleRoot (Join-Path $versionRoot 'CLC.Deployment')} | Should -Throw
    }
}

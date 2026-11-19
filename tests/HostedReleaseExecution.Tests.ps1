BeforeAll {
    . "$PSScriptRoot/Support.ps1"
    . "$script:RepositoryRoot/tools/HostedScratch.ps1"
    . "$script:RepositoryRoot/tools/Distribution.Common.ps1"
}

Describe 'Hosted NTFS scratch selection' {
    It 'creates a distinct writable directory under a verified RUNNER_TEMP' {
        $first = New-ClcHostedScratchDirectory -RunnerTemp $TestDrive
        $second = New-ClcHostedScratchDirectory -RunnerTemp $TestDrive
        [IO.Path]::GetDirectoryName($first) | Should -BeExactly $TestDrive
        [IO.Path]::GetDirectoryName($second) | Should -BeExactly $TestDrive
        $first | Should -Not -Be $second
        (Get-DistPathFacts $first -Directory).CanonicalPath | Should -BeExactly $first
        (Get-DistPathFacts $second -Directory).CanonicalPath | Should -BeExactly $second
        @(Get-ChildItem -LiteralPath $first -Force).Count | Should -Be 0
    }

    It 'falls back to the Windows known folder when RUNNER_TEMP fails the NTFS check' {
        Mock Get-ClcPathObservation -ParameterFilter { $Path -ceq $TestDrive } {
            throw [IO.IOException]::new('Simulated ReFS volume.')
        }
        $knownFolder = [Environment]::GetFolderPath('LocalApplicationData')
        $path = New-ClcHostedScratchDirectory -RunnerTemp $TestDrive
        try {
            [IO.Path]::GetDirectoryName($path) | Should -BeExactly $knownFolder
            (Get-DistPathFacts $path -Directory).CanonicalPath | Should -BeExactly $path
            Should -Invoke Get-ClcPathObservation -Exactly -Times 1 -ParameterFilter { $Path -ceq $TestDrive }
        } finally {
            [IO.Directory]::Delete($path)
        }
    }

    It 'falls back when RUNNER_TEMP allows creating directories but the scratch directory denies file creation' {
        $candidate = [IO.Directory]::CreateDirectory((Join-Path $TestDrive 'deny-file-creation'))
        $original = [IO.FileSystemAclExtensions]::GetAccessControl($candidate)
        $acl = [IO.FileSystemAclExtensions]::GetAccessControl($candidate)
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        try {
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity.User,
                'CreateFiles', 'ContainerInherit', 'InheritOnly', 'Deny'))
        } finally { $identity.Dispose() }
        [IO.FileSystemAclExtensions]::SetAccessControl($candidate, $acl)
        $path = $null
        try {
            $path = New-ClcHostedScratchDirectory -RunnerTemp $candidate.FullName
            [IO.Path]::GetDirectoryName($path) | Should -BeExactly ([Environment]::GetFolderPath('LocalApplicationData'))
            $candidate.GetDirectories().Count | Should -Be 1
        } finally {
            [IO.FileSystemAclExtensions]::SetAccessControl($candidate, $original)
            if ($path) { [IO.Directory]::Delete($path) }
        }
    }

    It 'fails before creating storage when no candidate can be verified as NTFS' {
        Mock Get-ClcPathObservation { throw [IO.IOException]::new('Simulated unsupported filesystem.') }
        $candidate = [IO.Directory]::CreateDirectory((Join-Path $TestDrive 'unsupported-filesystem'))
        { New-ClcHostedScratchDirectory -RunnerTemp $candidate.FullName } | Should -Throw '*requires writable NTFS*'
        Should -Invoke Get-ClcPathObservation -Exactly -Times 2
        $candidate.GetFileSystemInfos().Count | Should -Be 0
    }
}

Describe 'Hosted application release execution' {
    It 'packages from a fresh process and verifies publication and routing with offline HTTP responses on selected NTFS' {
        $work = New-ClcHostedScratchDirectory -RunnerTemp $TestDrive
        $fixtureRepo = Join-Path $work 'repo'
        $null = [IO.Directory]::CreateDirectory((Join-Path $fixtureRepo 'src'))
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'src/Clc.Deployment') -Destination (Join-Path $fixtureRepo 'src') -Recurse
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'tools') -Destination $fixtureRepo -Recurse
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'VERSION') -Destination $fixtureRepo
        # The isolated checkout replaces only the socket transport factory. The
        # release entry points, HTTP policy and all package checks are real.
        Add-Content -LiteralPath (Join-Path $fixtureRepo 'tools/SharedReleasePublisher.Common.ps1') -Value @'

function New-SharedReleaseHttpClient {
    [Net.Http.HttpClient]::new($global:ClcReleaseFixtureHttp, $false)
}
'@
        $null = Get-DistGit $fixtureRepo @('init','--initial-branch=master')
        $null = Get-DistGit $fixtureRepo @('config','user.name','CLC Release Fixture')
        $null = Get-DistGit $fixtureRepo @('config','user.email','release@example.invalid')
        $null = Get-DistGit $fixtureRepo @('config','core.autocrlf','false')
        $null = Get-DistGit $fixtureRepo @('add','.')
        $null = Get-DistGit $fixtureRepo @('-c','commit.gpgsign=false','commit','-m','Commit offline release fixture')
        $sharedRevision = Get-DistGit $fixtureRepo @('rev-parse','HEAD')

        $publish = (New-TestPublish $work).PublishRoot
        [IO.File]::Delete((Join-Path $publish 'Probe.dll'))
        $pwsh = Join-Path $PSHOME 'pwsh.exe'
        $output = & $pwsh -NoLogo -NoProfile -NonInteractive -File "$PSScriptRoot/Fixtures/Invoke-ReleaseExecution.ps1" $fixtureRepo $sharedRevision $work $publish 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        $output | Should -Contain 'Offline release execution verified.'
    }
}

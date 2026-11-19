# Scratch space for GitHub-hosted Windows jobs. The runner VM owns its lifetime.
. (Join-Path $PSScriptRoot '../src/Clc.Deployment/Private/Contracts.ps1')
. (Join-Path $PSScriptRoot '../src/Clc.Deployment/Private/Paths.ps1')

function New-ClcHostedScratchDirectory {
    [CmdletBinding()]
    param([string] $RunnerTemp = $env:RUNNER_TEMP)

    $ErrorActionPreference = 'Stop'
    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    foreach ($candidate in @($RunnerTemp, $localAppData)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $handles = [Collections.Generic.List[IDisposable]]::new()
        try {
            # The same handle-based checks used by package inspection require
            # physical NTFS and refuse reparse points, aliases and named streams.
            $parent = Get-ClcPathObservation ([IO.Path]::TrimEndingDirectorySeparator($candidate)) $handles -Directory -PinnedDirectory
            $path = Join-Path $parent.CanonicalPath ('clc-' + [guid]::NewGuid().ToString('N').Substring(0,16))
            Assert-ClcPathSpelling $path
            [Clc.Foundation.NativePaths]::CreateNewDirectory($path)
            $null = Get-ClcChildPathObservation $path $parent $handles -Directory -PinnedDirectory
            $probe = [IO.FileStream]::new((Join-Path $path 'write-probe'), [IO.FileMode]::CreateNew,
                [IO.FileAccess]::Write, [IO.FileShare]::None, 1, [IO.FileOptions]::DeleteOnClose)
            $probe.Dispose()
            return $path
        } catch {
            Write-Verbose "The hosted scratch candidate '$candidate' is unavailable: $($_.Exception.Message)"
        } finally {
            foreach ($handle in $handles) { $handle.Dispose() }
        }
    }
    throw 'Hosted release work requires writable NTFS in RUNNER_TEMP or the Windows LocalApplicationData folder.'
}

BeforeAll {
    . "$PSScriptRoot/Support.ps1"
    if ($null -eq ('Clc.Test.ShortPaths' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
namespace Clc.Test {
    public static class ShortPaths {
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern uint GetShortPathNameW(string path, StringBuilder value, uint size);
        public static string Get(string path) {
            var value = new StringBuilder(1024);
            uint size = GetShortPathNameW(path,value,1024);
            if (size == 0 || size >= 1024) throw new System.IO.IOException("Short-name fixture unavailable.");
            return value.ToString();
        }
    }
}
'@
    }
}
Describe 'Actual Windows NTFS path scope and identity' {
    BeforeEach { $workspace = New-TestWorkspace; $publishArgs = New-TestPublish $workspace }
    AfterEach { Remove-TestWorkspace $workspace }
    It 'observes physical file/volume IDs and allows casing aliases without losing identity' {
        & (Get-Module CLC.Deployment) {
            param($Path)
            $handles = [Collections.Generic.List[IDisposable]]::new()
            try {
                $first = Get-ClcPathObservation $Path $handles -Directory
                $second = Get-ClcPathObservation $Path.ToUpperInvariant() $handles -Directory
                $first.VolumeId | Should -BeExactly $second.VolumeId
                $first.FileId | Should -BeExactly $second.FileId
                $first.LinkCount | Should -Be 1
            } finally { foreach ($handle in $handles) { $handle.Dispose() } }
        } $publishArgs.PublishRoot
        $publishArgs.PublishRoot = $publishArgs.PublishRoot.ToUpperInvariant()
        (New-ClcRelease @publishArgs).fileCount | Should -Be 4
    }
    It 'allows prefix siblings and rejects containment in both ancestry directions' {
        $sibling = $publishArgs.PublishRoot + '-sibling'
        [void][IO.Directory]::CreateDirectory($sibling)
        $publishArgs.OutputPath = Join-Path $sibling 'release.zip'
        $null = New-ClcRelease @publishArgs
        $inside = Join-Path $publishArgs.PublishRoot 'nested'
        [void][IO.Directory]::CreateDirectory($inside)
        $publishArgs.OutputPath = Join-Path $inside 'release.zip'
        Test-TestRejection { New-ClcRelease @publishArgs } 'Clc.UnsafePath*'
        $publishArgs.OutputPath = Join-Path $workspace 'release.zip'
        Test-TestRejection { New-ClcRelease @publishArgs } 'Clc.UnsafePath*'
    }
    It 'rejects metadata inside the source or output parent' {
        $copy = Join-Path $publishArgs.PublishRoot 'metadata.json'
        [IO.File]::Copy($publishArgs.MetadataPath,$copy)
        $publishArgs.MetadataPath = $copy
        Test-TestRejection { New-ClcRelease @publishArgs } 'Clc.UnsafePath*'
        $copy = Join-Path (Split-Path $publishArgs.OutputPath) 'metadata.json'
        Write-TestJson $copy (Get-TestMetadata)
        $publishArgs.MetadataPath = $copy
        Test-TestRejection { New-ClcRelease @publishArgs } 'Clc.UnsafePath*'
        [IO.File]::Exists($publishArgs.OutputPath) | Should -BeFalse
    }
    It 'rejects unsafe rooted/UNC/device/ADS/relative/traversal spellings without touching them' -ForEach @(
        @{Path='C:\'},@{Path='\\synthetic.invalid\share\x.zip'},@{Path='\\?\C:\x.zip'},@{Path='\\.\C:\x.zip'},
        @{Path='C:\x.zip:stream'},@{Path='C:x.zip'},@{Path='relative.zip'},@{Path='C:\some\..\x.zip'},@{Path='C:\some\NUL.txt'},@{Path='C:\some\trailing.'}
    ) {
        $publishArgs.OutputPath = $Path
        Test-TestRejection { New-ClcRelease @publishArgs } 'Clc.UnsafePath*'
    }
    It 'rejects protected OS/program/config roots by read-only guards' {
        foreach ($root in @([Environment]::GetFolderPath('Windows'),[Environment]::GetFolderPath('ProgramFiles'),[Environment]::GetFolderPath('CommonApplicationData'))) {
            $publishArgs.OutputPath = Join-Path $root 'clc-never-written.zip'
            Test-TestRejection { New-ClcRelease @publishArgs } 'Clc.UnsafePath*'
        }
    }
    It 'rejects a real junction ancestor' {
        $alias = Join-Path $workspace 'alias'
        $null = New-Item -ItemType Junction -Path $alias -Target $publishArgs.PublishRoot
        try {
            $publishArgs.PublishRoot = $alias
            Test-TestRejection { New-ClcRelease @publishArgs } 'Clc.UnsafePath*'
            [IO.File]::Exists($publishArgs.OutputPath) | Should -BeFalse
        } finally { Remove-Item -LiteralPath $alias -Force }
    }
    It 'rejects a real junction descendant while preserving its target' {
        $target = Join-Path $workspace 'link-target'
        [void][IO.Directory]::CreateDirectory($target)
        $sentinel = Join-Path $target 'sentinel.txt'
        [IO.File]::WriteAllText($sentinel,'junction-target-sentinel')
        $alias = Join-Path $publishArgs.PublishRoot 'alias'
        $null = New-Item -ItemType Junction -Path $alias -Target $target
        try {
            Test-TestRejection { New-ClcRelease @publishArgs } 'Clc.UnsafePath*'
            [IO.File]::ReadAllText($sentinel) | Should -Be 'junction-target-sentinel'
        } finally { Remove-Item -LiteralPath $alias -Force }
    }
    It 'rejects actual hard links in a source tree and on inspected archives' {
        $original = Join-Path $publishArgs.PublishRoot 'Probe.dll'
        $alias = Join-Path $workspace 'hardlink.dll'
        $null = New-Item -ItemType HardLink -Path $alias -Target $original
        Test-TestRejection { New-ClcRelease @publishArgs } 'Clc.UnsafePath*'
        Remove-Item -LiteralPath $alias
        $result = New-ClcRelease @publishArgs
        $archiveAlias = Join-Path $workspace 'hardlink.zip'
        $null = New-Item -ItemType HardLink -Path $archiveAlias -Target $result.archivePath
        Test-TestRejection { Test-ClcRelease $archiveAlias } 'Clc.UnsafePath*'
        [IO.File]::ReadAllText($original) | Should -Be 'synthetic fixture bytes; never executable'
    }
    It 'rejects alternate data streams attached to actual regular source files' {
        [IO.File]::WriteAllText((Join-Path $publishArgs.PublishRoot 'Probe.dll') + ':hidden','ads-sentinel')
        Test-TestRejection { New-ClcRelease @publishArgs } 'Clc.UnsafePath*'
        [IO.File]::ReadAllText((Join-Path $publishArgs.PublishRoot 'Probe.dll') + ':hidden') | Should -Be 'ads-sentinel'
    }
    It 'rejects an actual subst drive alias and removes only its own mapping' {
        $used = @([IO.DriveInfo]::GetDrives().Name.Substring(0,1))
        $letter = @('Z','Y','X','W','V','U','T','S','R') | Where-Object { $used -notcontains $_ } | Select-Object -First 1
        if (-not $letter) { Set-ItResult -Skipped -Because 'No isolated drive letter available for mandatory subst fixture.'; return }
        $drive = $letter + ':'
        & subst.exe $drive $workspace
        if ($LASTEXITCODE -ne 0) { Set-ItResult -Skipped -Because 'Mandatory subst fixture could not be provisioned.'; return }
        try {
            $publishArgs.PublishRoot = $drive + '\publish'
            Test-TestRejection { New-ClcRelease @publishArgs } 'Clc.UnsafePath*'
            [IO.File]::Exists($publishArgs.OutputPath) | Should -BeFalse
        } finally {
            if ([Clc.Foundation.NativePaths]::DriveTarget($drive) -cne ('\??\' + $workspace)) { throw 'Fixture mapping changed; refusing cleanup.' }
            & subst.exe $drive /D
            if ($LASTEXITCODE -ne 0) { throw 'Failed to remove isolated subst fixture.' }
        }
    }
    It 'rejects a real 8.3 alias in an isolated regular file fixture' {
        $file = Join-Path $workspace 'long-native-fixture-name.txt'
        [IO.File]::WriteAllText($file,'short-name-sentinel')
        $short = [Clc.Test.ShortPaths]::Get($file)
        if ($short -ceq $file) {
            $fixtureResult = & fsutil.exe file setshortname $file 'CLCPRO~1.TXT' 2>&1
            if ($LASTEXITCODE -ne 0) {
                Set-ItResult -Skipped -Because 'Mandatory isolated 8.3 fixture needs an elevated test token to assign a short name; no system volume setting was changed.'
                return
            }
            $short = [Clc.Test.ShortPaths]::Get($file)
        }
        $short | Should -Not -BeExactly $file
        & (Get-Module CLC.Deployment) {
            param($Path)
            $handles = [Collections.Generic.List[IDisposable]]::new()
            try { { Get-ClcPathObservation $Path $handles } | Should -Throw -ErrorId 'Clc.UnsafePath*' }
            finally { foreach ($handle in $handles) { $handle.Dispose() } }
        } $short
        [IO.File]::ReadAllText($file) | Should -Be 'short-name-sentinel'
    }
    It 'holds source read handles that prohibit byte replacement and delete' {
        & (Get-Module CLC.Deployment) {
            param($Path)
            $handles = [Collections.Generic.List[IDisposable]]::new()
            try {
                $facts = Get-ClcPathObservation $Path $handles
                $stream = Open-ClcReadFile $Path $facts $handles
                { [IO.File]::WriteAllText($Path,'changed') } | Should -Throw
                { [IO.File]::Delete($Path) } | Should -Throw
                $stream.Length | Should -BeGreaterThan 0
            } finally { foreach ($handle in $handles) { $handle.Dispose() } }
        } (Join-Path $publishArgs.PublishRoot 'Probe.dll')
        [IO.File]::ReadAllText((Join-Path $publishArgs.PublishRoot 'Probe.dll')) | Should -Be 'synthetic fixture bytes; never executable'
    }
    It 'rejects an actual source full path longer than 240 characters before output' {
        $nested = Join-Path $publishArgs.PublishRoot ('a' * 90)
        [void][IO.Directory]::CreateDirectory($nested)
        $leafLength = 241 - $nested.Length - 1
        $path = Join-Path $nested (('b' * ($leafLength - 4)) + '.txt')
        $path.Length | Should -Be 241
        [IO.File]::WriteAllText($path,'long-path-sentinel')
        Test-TestRejection { New-ClcRelease @publishArgs } 'Clc.UnsafePath*'
        [IO.File]::Exists($publishArgs.OutputPath) | Should -BeFalse
        [IO.File]::ReadAllText($path) | Should -Be 'long-path-sentinel'
    }
}

BeforeAll {
    . "$PSScriptRoot/Support.ps1"; . "$PSScriptRoot/T2Support.ps1"
    if ($null -eq ('Clc.Test.ShortPaths' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
namespace Clc.Test {
    public static class ShortPaths {
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
        private static extern uint GetShortPathNameW(string path,StringBuilder value,uint size);
        public static string Get(string path) {
            var value=new StringBuilder(1024); uint size=GetShortPathNameW(path,value,1024);
            if (size==0 || size>=1024) throw new System.IO.IOException("Short path unavailable.");
            return value.ToString();
        }
    }
}
'@
    }
}
Describe 'Held-parent descendant walker preserves physical Windows rejection guards' {
    BeforeEach {
        $workspace=New-TestWorkspace; $tree=Join-Path $workspace 'tree'; $nested=Join-Path $tree 'assets'
        $null=[IO.Directory]::CreateDirectory($nested)
        $leaf=Join-Path $nested 'long-descendant-fixture-name.txt'; [IO.File]::WriteAllText($leaf,'owned-leaf-sentinel')
        $outside=Join-Path $workspace 'outside'; $null=[IO.Directory]::CreateDirectory($outside)
        $sentinel=Join-Path $outside 'sentinel.txt'; [IO.File]::WriteAllText($sentinel,'outside-leaf-sentinel')
    }
    AfterEach { Remove-TestWorkspace $workspace }
    It 'accepts a benign nested tree and releases every observation handle' {
        Invoke-T2Private Assert-ClcSafeDescendants @($tree)
        [IO.File]::WriteAllText($leaf,'observations-released')
        [IO.File]::ReadAllText($leaf) | Should -BeExactly 'observations-released'
    }
    It 'rejects an actual descendant <Attack> and preserves outside bytes' -ForEach @(@{Attack='Junction'},@{Attack='HardLink'},@{Attack='ADS'},@{Attack='DirectoryADS'},@{Attack='RootADS'},@{Attack='AncestorADS'}) {
        switch ($Attack) {
            Junction { $null=New-Item -ItemType Junction -Path (Join-Path $nested 'foreign') -Target $outside }
            HardLink { $null=New-Item -ItemType HardLink -Path (Join-Path $nested 'foreign.txt') -Target $sentinel }
            ADS { [IO.File]::WriteAllText(($leaf+':hidden'),'hidden-stream-sentinel') }
            DirectoryADS { [IO.File]::WriteAllText(($nested+':hidden'),'hidden-directory-stream-sentinel') }
            RootADS { [IO.File]::WriteAllText(($tree+':hidden'),'hidden-root-stream-sentinel') }
            AncestorADS { [IO.File]::WriteAllText(($workspace+':hidden'),'hidden-ancestor-stream-sentinel') }
        }
        Test-TestRejection { Invoke-T2Private Assert-ClcSafeDescendants @($tree) } 'Clc.UnsafePath*'
        [IO.File]::ReadAllText($sentinel) | Should -BeExactly 'outside-leaf-sentinel'
    }
    It 'rejects an actual descendant short-name alias against its held canonical parent' {
        $short=[Clc.Test.ShortPaths]::Get($leaf)
        if ($short -ceq $leaf) {
            $output=& fsutil.exe file setshortname $leaf 'CLCDES~1.TXT' 2>&1
            if ($LASTEXITCODE -ne 0) { throw 'Mandatory isolated short-name fixture unavailable; no volume setting changed.' }
            $short=[Clc.Test.ShortPaths]::Get($leaf)
        }
        $short | Should -Not -BeExactly $leaf
        $alias=Join-Path $nested ([IO.Path]::GetFileName($short))
        & (Get-Module CLC.Deployment) {
            param($ParentPath,$Alias)
            $handles=[Collections.Generic.List[IDisposable]]::new()
            try {
                $parent=Get-ClcPathObservation $ParentPath $handles -Directory
                { Get-ClcChildPathObservation $Alias $parent $handles } | Should -Throw -ErrorId 'Clc.UnsafePath*'
            } finally { foreach ($handle in $handles) { $handle.Dispose() } }
        } $nested $alias
        [IO.File]::ReadAllText($leaf) | Should -BeExactly 'owned-leaf-sentinel'
    }
    It 'rejects a descendant whose native case-sensitive-directory observation is nonzero' {
        $global:T3CasePath=$nested
        Mock -ModuleName CLC.Deployment Get-ClcDirectoryCaseFlags {
            if ([Clc.Foundation.NativePaths]::Observe($Handle).CanonicalPath -ceq $global:T3CasePath) { return 1 }; return 0
        }
        Test-TestRejection { Invoke-T2Private Assert-ClcSafeDescendants @($tree) } 'Clc.UnsafePath*'
        [IO.File]::ReadAllText($sentinel) | Should -BeExactly 'outside-leaf-sentinel'
    }
}

BeforeAll {
    . "$PSScriptRoot/Support.ps1"
    function Set-TestForeignStream {
        param([string] $Path)
        $writer=[IO.FileStream]::new($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try {
            $bytes=[Text.Encoding]::UTF8.GetBytes('owned unknown stream sentinel')
            $writer.Write($bytes,0,$bytes.Length); $writer.Flush($true)
        } finally {$writer.Dispose()}
    }
}
Describe 'Named directory data streams are outside the publish inventory' {
    BeforeEach {$workspace=New-TestWorkspace; $inputs=New-TestPublish $workspace}
    AfterEach {Remove-TestWorkspace $workspace}
    It 'rejects a named stream on the <Location> before creating an archive' -ForEach @(@{Location='PublishRoot'},@{Location='NestedDirectory'}) {
        $path=$inputs.PublishRoot
        if ($Location -ceq 'NestedDirectory') {
            $path=Join-Path $path 'assets'; $null=[IO.Directory]::CreateDirectory($path)
            [IO.File]::WriteAllText((Join-Path $path 'known.txt'),'owned inventoried file')
        }
        $named=$path+':unknown-data'; Set-TestForeignStream $named
        Test-TestRejection {New-ClcRelease @inputs} 'Clc.*'
        [IO.File]::Exists($inputs.OutputPath) | Should -BeFalse
        [IO.File]::ReadAllText($named) | Should -BeExactly 'owned unknown stream sentinel'
    }
}

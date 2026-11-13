BeforeAll {
    . "$PSScriptRoot/Support.ps1"; . "$PSScriptRoot/T2Support.ps1"; . "$PSScriptRoot/T3Support.ps1"
    function Set-T3ForeignStream {
        param([string] $Path)
        $writer=[IO.FileStream]::new($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try {
            $bytes=[Text.Encoding]::UTF8.GetBytes('owned unknown stream sentinel')
            $writer.Write($bytes,0,$bytes.Length); $writer.Flush($true)
        } finally {$writer.Dispose()}
    }
}
Describe 'Named directory data streams are outside approved publish inventory' {
    BeforeEach {$workspace=New-TestWorkspace; $inputs=New-TestPublish $workspace}
    AfterEach {Remove-TestWorkspace $workspace}
    It 'rejects a named stream on the <Location> before creating an archive' -ForEach @(@{Location='PublishRoot'},@{Location='NestedDirectory'}) {
        $path=$inputs.PublishRoot
        if ($Location -ceq 'NestedDirectory') {
            $path=Join-Path $path 'assets'; $null=[IO.Directory]::CreateDirectory($path)
            [IO.File]::WriteAllText((Join-Path $path 'known.txt'),'owned inventoried file')
        }
        $named=$path+':unknown-data'; Set-T3ForeignStream $named
        Test-TestRejection {New-ClcRelease @inputs} 'Clc.*'
        [IO.File]::Exists($inputs.OutputPath) | Should -BeFalse
        [IO.File]::ReadAllText($named) | Should -BeExactly 'owned unknown stream sentinel'
    }
}
Describe 'Public deployment preserves directory and late-added stream content' {
    BeforeEach {
        $fixture=New-T2Fixture; Set-T2FixtureInModule $fixture; Set-T3Mocks
        $first=New-T3Approval $fixture probe-approval-001 1L probe-main 0 128 -Nested
        $deployed=Invoke-ClcIisDeployment example $first.record.approvalId
        $next=New-T3Approval $fixture probe-approval-002 2L
        $global:ClcLifecycle.operations.Clear(); $global:T3StreamFired=$false; $global:T3ForeignStreamPath=$null
    }
    AfterEach {Remove-TestWorkspace $fixture.workspace}
    It 'rejects an existing <Location> stream before validation or shutdown and preserves current and live bytes' -ForEach @(@{Location='ApplicationRoot'},@{Location='KnownDirectory'}) {
        $path=$fixture.target.applicationRoot
        if ($Location -ceq 'KnownDirectory') {$path=Join-Path $path 'assets\deep'}
        $named=$path+':unknown-data'; Set-T3ForeignStream $named
        $before=Get-TestTreeHashes $fixture.target.applicationRoot
        $current=(Get-FileHash -LiteralPath (Join-Path $fixture.controlRoot 'current.json')).Hash
        Test-TestRejection {Invoke-ClcIisDeployment example $next.record.approvalId} 'Clc.UnsafePath*'
        @($global:ClcLifecycle.operations).Count | Should -Be 0
        (Get-TestTreeHashes $fixture.target.applicationRoot) | Should -BeExactly $before
        (Get-FileHash -LiteralPath (Join-Path $fixture.controlRoot 'current.json')).Hash | Should -BeExactly $current
        [IO.File]::ReadAllText($named) | Should -BeExactly 'owned unknown stream sentinel'
    }
}

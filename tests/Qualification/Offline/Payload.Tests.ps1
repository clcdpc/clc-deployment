BeforeAll {
    . "$PSScriptRoot/../../Support.ps1"
    . "$script:RepositoryRoot/tools/Distribution.Common.ps1"
    $script:payloadCopier=Join-Path $script:RepositoryRoot 'tools/Copy-QualificationPayload.ps1'
    function Get-PayloadInventory([string] $Root) {
        $files=@(Get-ChildItem -LiteralPath $Root -Recurse -File | ForEach-Object { @{path=$_.FullName.Substring($Root.Length+1).Replace('\','/');length=[long]$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant()} })
        Get-DistInventoryHash $files
    }
}
Describe 'Representative disposable workload input' {
    BeforeEach {
        $script:workspace=New-TestWorkspace; $script:publish=Join-Path $workspace 'publish'; $null=[IO.Directory]::CreateDirectory($publish)
        [IO.File]::WriteAllText((Join-Path $publish 'Payload.dll'),'inert synthetic fixture; never executed')
        [IO.File]::WriteAllText((Join-Path $publish 'appsettings.Production.json'),'excluded synthetic operational configuration')
        $script:destination=Join-Path $workspace 'selected'
        $script:arguments=@{PublishRoot=$publish;ExpectedInventorySha256=(Get-PayloadInventory $publish);SourceRepository='synthetic/disposable';SourceCommit=('a'*40);DestinationRoot=$destination;ProducerReference='synthetic-offline-fixture';DisposableTestPayload=$true}
    }
    AfterEach { Remove-TestWorkspace $script:workspace }
    It 'copies exact pinned inert payload files and excludes operational configuration without executing inputs' {
        $before=Get-TestTreeHashes $publish
        $result=& $payloadCopier @arguments
        $result.selectedFileCount | Should -Be 1
        Test-Path -LiteralPath (Join-Path $destination 'Payload.dll') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $destination 'appsettings.Production.json') | Should -BeFalse
        Get-TestTreeHashes $publish | Should -BeExactly $before
        $result.inputInventorySha256 | Should -BeExactly $arguments.ExpectedInventorySha256
    }
    It 'rejects changed inventory before creating destination content' {
        $arguments.ExpectedInventorySha256='0'*64
        { & $payloadCopier @arguments } | Should -Throw '*inventory differs*'
        Test-Path -LiteralPath $destination | Should -BeFalse
    }
    It 'rejects real source hard links without modifying either original' {
        $link=Join-Path $workspace 'source-link.dll'; $null=New-Item -ItemType HardLink -Path $link -Target (Join-Path $publish 'Payload.dll')
        { & $payloadCopier @arguments } | Should -Throw
        [IO.File]::ReadAllText($link) | Should -BeExactly 'inert synthetic fixture; never executed'
    }
    It 'requires explicit disposable selection and refuses an overlapping destination' {
        $arguments.DisposableTestPayload=$false
        { & $payloadCopier @arguments } | Should -Throw '*disposable test publish payload*'
        $arguments.DisposableTestPayload=$true; $arguments.DestinationRoot=Join-Path $publish 'nested'
        { & $payloadCopier @arguments } | Should -Throw '*disjoint*'
    }
}

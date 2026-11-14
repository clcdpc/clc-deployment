BeforeAll {
    . "$PSScriptRoot/Support.ps1"
    function New-HookPackageFixture([string] $Workspace) {
        $arguments=New-TestPublish $Workspace
        $hooks=Join-Path $Workspace 'hook-input'; $null=[IO.Directory]::CreateDirectory($hooks)
        $null=[IO.Directory]::CreateDirectory((Join-Path $hooks 'database'))
        foreach ($name in @('before.ps1','after.ps1','plan.ps1','support.psm1','database/schema.sql','database/application.dacpac')) {
            [IO.File]::WriteAllText((Join-Path $hooks $name),'synthetic verified input; never execute during package inspection')
        }
        $metadata=Get-TestMetadata; $metadata.schemaVersion=2; $metadata.changeKind='application-deployment'
        $metadata.hooks=@{contractVersion=1;stages=@(@{stage='AfterStop';entryPoint='hooks/after.ps1'},@{stage='BeforeStop';entryPoint='hooks/before.ps1'});planningEntryPoint='hooks/plan.ps1'}
        Write-TestJson $arguments.MetadataPath $metadata
        $arguments.HookRoot=$hooks
        return $arguments
    }
}
Describe 'Version-two application packages with separate verified hook inputs' {
    BeforeEach { $workspace=New-TestWorkspace; $arguments=New-HookPackageFixture $workspace }
    AfterEach { Remove-TestWorkspace $workspace }
    It 'keeps application and hook inventories separate and never executes packaged scripts' {
        $webBefore=Get-TestTreeHashes $arguments.PublishRoot; $hookBefore=Get-TestTreeHashes $arguments.HookRoot
        $built=New-ClcRelease @arguments; $inspection=Test-ClcRelease $built.archivePath
        $inspection.packageContractVersion | Should -Be 2
        $inspection.authorizedForDeployment | Should -BeFalse
        $inspection.fileCount | Should -Be 10
        $entries=@(Get-TestZipEntries $built.archivePath)
        $manifest=[Text.Encoding]::UTF8.GetString($entries[0].bytes) | ConvertFrom-Json -AsHashtable
        $manifest.files.Count | Should -Be 4; $manifest.hooks.files.Count | Should -Be 6
        @($manifest.files | Where-Object path -CNotLike 'application/*').Count | Should -Be 0
        @($manifest.hooks.files | Where-Object path -CNotLike 'hooks/*').Count | Should -Be 0
        @($manifest.hooks.stages.stage) | Should -Be @('BeforeStop','AfterStop')
        Test-Json -Json ([Text.Encoding]::UTF8.GetString($entries[0].bytes)) -SchemaFile (Join-Path $script:RepositoryRoot 'schemas/release-manifest.schema.json') | Should -BeTrue
        Test-Json -Json ([IO.File]::ReadAllText($arguments.MetadataPath)) -SchemaFile (Join-Path $script:RepositoryRoot 'schemas/release-metadata.schema.json') | Should -BeTrue
        (Get-TestTreeHashes $arguments.PublishRoot) | Should -BeExactly $webBefore
        (Get-TestTreeHashes $arguments.HookRoot) | Should -BeExactly $hookBefore
    }
    It 'produces deterministic hook bytes despite metadata stage order or file timestamps' {
        $first=New-ClcRelease @arguments
        $metadata=Get-Content -LiteralPath $arguments.MetadataPath -Raw | ConvertFrom-Json -AsHashtable
        [Array]::Reverse($metadata.hooks.stages); Write-TestJson $arguments.MetadataPath $metadata
        [IO.File]::SetLastWriteTimeUtc((Join-Path $arguments.HookRoot 'after.ps1'),[DateTime]::UtcNow)
        $arguments.OutputPath=Join-Path (Split-Path $arguments.OutputPath) 'second.zip'
        (New-ClcRelease @arguments).archiveSha256 | Should -BeExactly $first.archiveSha256
    }
    It 'accepts a minimal no-hook v2 package without a HookRoot or hooks section' {
        $metadata=Get-TestMetadata; $metadata.schemaVersion=2; $metadata.changeKind='application-deployment'
        Write-TestJson $arguments.MetadataPath $metadata; $arguments.Remove('HookRoot')
        $result=New-ClcRelease @arguments
        $result.packageContractVersion | Should -Be 2
        $entries=@(Get-TestZipEntries $result.archivePath)
        $manifest=[Text.Encoding]::UTF8.GetString($entries[0].bytes) | ConvertFrom-Json -AsHashtable
        $manifest.Contains('hooks') | Should -BeFalse
        $entries.Count | Should -Be 5
    }
    It 'rejects HookRoot/declaration mismatches before creating output' -ForEach @(@{Mode='missing-root'},@{Mode='undeclared-root'},@{Mode='v1-hooks'},@{Mode='overlap'}) {
        $metadata=Get-Content -LiteralPath $arguments.MetadataPath -Raw | ConvertFrom-Json -AsHashtable
        switch ($Mode) {
            missing-root { $arguments.Remove('HookRoot') }
            undeclared-root { $metadata.Remove('hooks') }
            v1-hooks { $metadata.schemaVersion=1; $metadata.changeKind='files-only' }
            overlap { $arguments.HookRoot=$arguments.PublishRoot }
        }
        Write-TestJson $arguments.MetadataPath $metadata
        Test-TestRejection { New-ClcRelease @arguments }
        [IO.File]::Exists($arguments.OutputPath) | Should -BeFalse
    }
    It 'rejects invalid lifecycle or planning declarations <Mode>' -ForEach @(
        @{Mode='unknown-stage'},@{Mode='duplicate-stage'},@{Mode='missing-script'},@{Mode='support-entry'},
        @{Mode='planning-is-lifecycle'},@{Mode='inline'},@{Mode='application-path'},@{Mode='empty-hooks'}
    ) {
        $metadata=Get-Content -LiteralPath $arguments.MetadataPath -Raw | ConvertFrom-Json -AsHashtable
        switch ($Mode) {
            unknown-stage { $metadata.hooks.stages[0].stage='DeployDatabase' }
            duplicate-stage { $metadata.hooks.stages[0].stage='BeforeStop' }
            missing-script { $metadata.hooks.stages[0].entryPoint='hooks/missing.ps1' }
            support-entry { $metadata.hooks.stages[0].entryPoint='hooks/database/schema.sql' }
            planning-is-lifecycle { $metadata.hooks.planningEntryPoint='hooks/before.ps1' }
            inline { $metadata.hooks.stages[0].command='Write-Output unsafe' }
            application-path { $metadata.hooks.stages[0].entryPoint='application/before.ps1' }
            empty-hooks { $metadata.hooks.stages=@(); $metadata.hooks.planningEntryPoint=$null }
        }
        Write-TestJson $arguments.MetadataPath $metadata
        Test-TestRejection { New-ClcRelease @arguments }
        [IO.File]::Exists($arguments.OutputPath) | Should -BeFalse
    }
    It 'rejects operational configuration, certificates and keys in hook inputs <Name>' -ForEach @(
        @{Name='application.json'},@{Name='appsettings.Production.json'},@{Name='operational-config.json'},
        @{Name='certificate.pfx'},@{Name='private.key'},@{Name='certificate.cer'},@{Name='private.snk'},@{Name='secrets.json'}
    ) {
        [IO.File]::WriteAllText((Join-Path $arguments.HookRoot $Name),'must remain external')
        Test-TestRejection { New-ClcRelease @arguments } 'Clc.UnsafeArchive*'
        [IO.File]::Exists($arguments.OutputPath) | Should -BeFalse
    }
    It 'rejects alternate streams and hardlinks in hook inputs before output' -ForEach @(@{Mode='stream'},@{Mode='hardlink'}) {
        $scriptPath=Join-Path $arguments.HookRoot 'before.ps1'
        if ($Mode -ceq 'stream') { [IO.File]::WriteAllText(($scriptPath+':hidden'),'unverified') }
        else { $null=New-Item -ItemType HardLink -Path (Join-Path $arguments.HookRoot 'alias.ps1') -Target $scriptPath }
        Test-TestRejection { New-ClcRelease @arguments }
        [IO.File]::Exists($arguments.OutputPath) | Should -BeFalse
    }
    It 'refuses a hook-support directory junction without changing its target' {
        $outside=Join-Path $workspace 'outside-hooks';$null=[IO.Directory]::CreateDirectory($outside)
        $sentinel=Join-Path $outside 'sentinel.txt';[IO.File]::WriteAllText($sentinel,'preserve-external-input')
        $null=New-Item -ItemType Junction -Path (Join-Path $arguments.HookRoot 'linked') -Target $outside
        Test-TestRejection { New-ClcRelease @arguments }
        [IO.File]::Exists($arguments.OutputPath) | Should -BeFalse
        [IO.File]::ReadAllText($sentinel) | Should -BeExactly 'preserve-external-input'
    }
    It 'rejects changed hook bytes, undeclared ZIP entries, and forged hook inventories' -ForEach @(@{Mode='bytes'},@{Mode='extra'},@{Mode='inventory'},@{Mode='v1'}) {
        $built=New-ClcRelease @arguments; $entries=@(Get-TestZipEntries $built.archivePath)
        $manifest=[Text.Encoding]::UTF8.GetString($entries[0].bytes) | ConvertFrom-Json -AsHashtable
        switch ($Mode) {
            bytes { ($entries | Where-Object name -CEQ 'hooks/before.ps1').bytes=[byte[]](1,2,3) }
            extra { $entries+=@{name='hooks/undeclared.ps1';bytes=[byte[]](4);attributes=0} }
            inventory { $manifest.hooks.inventorySha256='0'*64 }
            v1 { $manifest.schemaVersion=1; $manifest.changeKind='files-only'; $manifest.Remove('hooks') }
        }
        $entries[0].bytes=[Text.Encoding]::UTF8.GetBytes(($manifest | ConvertTo-Json -Depth 24 -Compress))
        $candidate=Join-Path $workspace 'tampered.zip'; New-TestZip $candidate $entries
        Test-TestRejection { Test-ClcRelease $candidate }
    }
    It 'extracts verified hooks beside the managed application tree' {
        $built=New-ClcRelease @arguments; $entries=@(Get-TestZipEntries $built.archivePath)
        $manifest=[Text.Encoding]::UTF8.GetString($entries[0].bytes) | ConvertFrom-Json -AsHashtable
        Mock -ModuleName CLC.Deployment Assert-ClcApprovedReleaseUnchanged { }
        Mock -ModuleName CLC.Deployment New-ClcOwnedDirectory { $null=[IO.Directory]::CreateDirectory($Path) }
        Mock -ModuleName CLC.Deployment Assert-ClcSafeDescendants { }
        Mock -ModuleName CLC.Deployment Assert-ClcPathAccess { }
        Mock -ModuleName CLC.Deployment Assert-ClcControlAncestorAccess { }
        $stage=Join-Path $workspace 'stage'; $archive=[IO.File]::OpenRead($built.archivePath)
        try {
            $result=& (Get-Module CLC.Deployment) {
                param($Stage,$Archive,$Manifest,$ControlRoot)
                $lock=@{identity=@{controlRoot=$ControlRoot};context=@{};targetFile=@{record=@{runtimeIdentitySid='S-1-5-21-1-2-3-1001'}}}
                Expand-ClcApprovedRelease $lock @{manifest=$Manifest;archive=@{stream=$Archive}} $Stage
            } $stage $archive $manifest $workspace
            $result | Should -BeExactly (Join-Path $stage 'application')
            (Get-TestTreeHashes $result) | Should -BeExactly (Get-TestTreeHashes $arguments.PublishRoot)
            (Get-TestTreeHashes (Join-Path $stage 'hooks')) | Should -BeExactly (Get-TestTreeHashes $arguments.HookRoot)
            @(Get-ChildItem -LiteralPath $result -Recurse -File -Filter '*.ps1').Count | Should -Be 0
        } finally { $archive.Dispose() }
    }
}

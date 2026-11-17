BeforeAll {
    . "$PSScriptRoot/Support.ps1"
    . "$PSScriptRoot/HostEnrollment.Support.ps1"
    $script:distribution=New-HTestDistribution
}
AfterAll {Remove-TestWorkspace $script:distribution.workspace;Remove-TestWorkspace $script:HBootstrapWorkspace}
Describe 'Format-3 infrastructure distribution admission' {
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
        $verified=& "$script:RepositoryRoot/tools/Test-ToolkitDistribution.ps1" -ArchivePath $distribution.archive -ExpectedSha256 $distribution.identity.distributionSha256 -ExpectedSourceCommit $distribution.commit -ExpectedVersion '0.1.0-dev.1' -InstalledModuleRoot (Join-Path $versionRoot 'Clc.Deployment') -RequireInfrastructureTools
        $verified.formatVersion | Should -Be 3
        @([IO.Directory]::EnumerateFiles((Join-Path $versionRoot 'Clc.Deployment\Public'))).Count | Should -Be 4
        Test-Path -LiteralPath (Join-Path $versionRoot 'tools\host\Get-ClcHostEnrollment.ps1') | Should -BeTrue
        $before=Get-TestTreeHashes $versionRoot
        {& "$script:RepositoryRoot/tools/Expand-ToolkitDistribution.ps1" -ArchivePath $distribution.archive -ExpectedSha256 $distribution.identity.distributionSha256 -ExpectedSourceCommit $distribution.commit -ExpectedVersion '0.1.0-dev.1' -VersionRoot $versionRoot -OperatorApprovalReference synthetic-fixture} | Should -Throw
        Get-TestTreeHashes $versionRoot | Should -BeExactly $before
    }
    It 'checks actual packaged bootstrap inventory and refuses identical code from another target location' {
        $versions=Join-Path $workspace 'versions';[void][IO.Directory]::CreateDirectory($versions)
        $version=Join-Path $versions '0.1.0-dev.1'
        $null=& "$script:RepositoryRoot/tools/Expand-ToolkitDistribution.ps1" -ArchivePath $distribution.archive -ExpectedSha256 $distribution.identity.distributionSha256 -ExpectedSourceCommit $distribution.commit -ExpectedVersion '0.1.0-dev.1' -VersionRoot $version -OperatorApprovalReference synthetic-bootstrap
        $bootstrap=Join-Path $workspace 'clc-a\Deployment\bootstrap';[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($bootstrap))
        Copy-Item -LiteralPath $version -Destination $bootstrap -Recurse
        $ps=[PowerShell]::Create()
        try {
            $null=$ps.AddScript({param($Bootstrap,$Wrong)
                . (Join-Path $Bootstrap 'tools/host/HostEnrollment.Common.ps1')
                # Synthetic ACL observations only; native identities, inventory,
                # directory shape and retained distribution checks remain real.
                function Assert-HAuthorityProtection($Path,$Handles,[switch]$Directory) {$null=Get-ClcPathObservation $Path $Handles -Directory:$Directory}
                $handles=[Collections.Generic.List[IDisposable]]::new()
                try {
                    Assert-HBootstrapProtection @{bootstrapRoot=$Bootstrap} $handles
                    $hash=Get-HBootstrapInventory
                    $protected=Join-Path $Bootstrap 'tools\host\Initialize-ClcHostEnrollment.ps1'
                    $writeRefused=$false;$deleteRefused=$false
                    try {[IO.File]::AppendAllText($protected,'# changed after inventory')} catch [IO.IOException] {$writeRefused=$true}
                    try {[IO.File]::Delete($protected)} catch [IO.IOException] {$deleteRefused=$true}
                    if (-not $writeRefused -or -not $deleteRefused -or (Get-HBootstrapInventory) -cne $hash) {throw 'Bootstrap bytes changed after verification.'}
                    try {Assert-HBootstrapProtection @{bootstrapRoot=$Wrong} $handles;throw 'Wrong target admitted'}
                    catch {if ($_.FullyQualifiedErrorId -notlike 'Clc.EnrollmentBootstrapMismatch*') {throw}}
                    return $hash
                } finally {foreach ($handle in $handles) {$handle.Dispose()}}
            }).AddArgument($bootstrap).AddArgument((Join-Path $workspace 'clc-b\Deployment\bootstrap'))
            $hash=$ps.Invoke()
            @($ps.Streams.Error | Where-Object {$_.FullyQualifiedErrorId -notlike 'Clc.EnrollmentBootstrapMismatch*'}).Count | Should -Be 0
            $hash.Count | Should -Be 1
            $hash[0] | Should -Match '^[a-f0-9]{64}$'
        } finally {$ps.Dispose()}
    }
    It 'rejects <Change> infrastructure bytes despite an internally recomputed transport checksum' -ForEach @(@{Change='modified'},@{Change='missing'},@{Change='unexpected'},@{Change='casing'}) {
        $entries=@(Get-TestZipEntries $distribution.archive)
        switch ($Change) {
            modified {($entries | Where-Object {$_.name -ceq 'tools/host/Get-ClcHostEnrollment.ps1'}).bytes=[Text.Encoding]::UTF8.GetBytes('throw "must never run"')}
            missing {$entries=@($entries | Where-Object {$_.name -cne 'tools/host/Get-ClcHostEnrollment.ps1'})}
            unexpected {$entries += @{name='tools/host/unapproved.ps1';bytes=[Text.Encoding]::UTF8.GetBytes('throw "must never run"');attributes=0}}
            casing {($entries | Where-Object {$_.name -ceq 'tools/host/Get-ClcHostEnrollment.ps1'}).name='Tools/host/Get-ClcHostEnrollment.ps1'}
        }
        $archive=Join-Path $workspace 'changed.zip';New-TestZip $archive $entries
        $hash=(Get-FileHash -LiteralPath $archive).Hash.ToLowerInvariant()
        {& "$script:RepositoryRoot/tools/Test-ToolkitDistribution.ps1" -ArchivePath $archive -ExpectedSha256 $hash -ExpectedSourceCommit $distribution.commit -ExpectedVersion '0.1.0-dev.1' -RequireInfrastructureTools} | Should -Throw
        Test-Path -LiteralPath (Join-Path $workspace 'versions') | Should -BeFalse
    }
    It 'rejects wrong module and identity entry casing with a recomputed archive digest' -ForEach @(
        @{Original='Clc.Deployment/Clc.Deployment.psd1';Replacement='CLC.Deployment/Clc.Deployment.psd1'},
        @{Original='Clc.Deployment/Clc.Deployment.psm1';Replacement='Clc.Deployment/CLC.Deployment.psm1'},
        @{Original='distribution.json';Replacement='Distribution.json'},@{Original='source.commit';Replacement='Source.commit'}
    ) {
        $entries=@(Get-TestZipEntries $distribution.archive)
        ($entries | Where-Object {$_.name -ceq $Original}).name=$Replacement
        $archive=Join-Path $workspace 'case.zip';New-TestZip $archive $entries
        {& "$script:RepositoryRoot/tools/Test-ToolkitDistribution.ps1" -ArchivePath $archive -ExpectedSha256 (Get-FileHash -LiteralPath $archive).Hash.ToLowerInvariant() -ExpectedSourceCommit $distribution.commit -ExpectedVersion '0.1.0-dev.1'} | Should -Throw
    }
    It 'refuses installed tools drift and unknown tool directories' {
        $versions=Join-Path $workspace 'versions';$null=[IO.Directory]::CreateDirectory($versions);$versionRoot=Join-Path $versions '0.1.0-dev.1'
        $null=& "$script:RepositoryRoot/tools/Expand-ToolkitDistribution.ps1" -ArchivePath $distribution.archive -ExpectedSha256 $distribution.identity.distributionSha256 -ExpectedSourceCommit $distribution.commit -ExpectedVersion '0.1.0-dev.1' -VersionRoot $versionRoot -OperatorApprovalReference synthetic-fixture
        [IO.File]::AppendAllText((Join-Path $versionRoot 'tools\host\HostEnrollment.Common.ps1'),'# drift')
        {& "$script:RepositoryRoot/tools/Test-ToolkitDistribution.ps1" -ArchivePath $distribution.archive -ExpectedSha256 $distribution.identity.distributionSha256 -ExpectedSourceCommit $distribution.commit -ExpectedVersion '0.1.0-dev.1' -InstalledModuleRoot (Join-Path $versionRoot 'Clc.Deployment')} | Should -Throw
        $null=[IO.Directory]::CreateDirectory((Join-Path $versionRoot 'tools\unknown'))
        {& "$script:RepositoryRoot/tools/Test-ToolkitDistribution.ps1" -ArchivePath $distribution.archive -ExpectedSha256 $distribution.identity.distributionSha256 -ExpectedSourceCommit $distribution.commit -ExpectedVersion '0.1.0-dev.1' -InstalledModuleRoot (Join-Path $versionRoot 'Clc.Deployment')} | Should -Throw
    }
    It 'verifies historical format <Format> using exact source-revision casing without reinterpreting it' -ForEach @(@{Format=1},@{Format=2}) {
        $source='b0ce6f377cfef371fa60d570e87f229bd809a528'
        $sourceZip=Join-Path $workspace 'historical-source.zip'
        $null=Get-DistGit $script:RepositoryRoot @('archive','--format=zip',('--output='+$sourceZip),$source)
        $zip=[IO.Compression.ZipFile]::OpenRead($sourceZip)
        $files=[Collections.Generic.List[object]]::new();$sourceFiles=[Collections.Generic.List[object]]::new();$infrastructure=[Collections.Generic.List[object]]::new();$payload=[Collections.Generic.List[object]]::new()
        try {
            foreach ($entry in $zip.Entries) {
                if ($entry.FullName.EndsWith('/')) {continue}
                $bytes=Read-DistEntry $entry
                $sourceFiles.Add(@{path=$entry.FullName;length=[long]$bytes.Length;sha256=(Get-DistHash $bytes)})
                if ($entry.FullName.StartsWith('src/CLC.Deployment/',[StringComparison]::Ordinal)) {
                    $name=$entry.FullName.Substring(19);$files.Add(@{path=$name;length=[long]$bytes.Length;sha256=(Get-DistHash $bytes)})
                    $payload.Add(@{name='CLC.Deployment/'+$name;bytes=$bytes;attributes=0})
                } elseif ($Format -eq 2 -and $entry.FullName -cin (Get-DistInfrastructureNames)) {
                    $infrastructure.Add(@{path=$entry.FullName;length=[long]$bytes.Length;sha256=(Get-DistHash $bytes)})
                    $payload.Add(@{name=$entry.FullName;bytes=$bytes;attributes=0})
                }
            }
        } finally {$zip.Dispose()}
        $moduleFiles=Sort-DistFiles $files.ToArray();$sources=Sort-DistFiles $sourceFiles.ToArray()
        $record=@{distributionFormat='clc-toolkit-distribution';formatVersion=$Format;sourceCommit=$source;moduleVersion='0.1.0-dev.1';files=$moduleFiles;inventorySha256=(Get-DistInventoryHash $moduleFiles);sourceFiles=$sources;sourceInventorySha256=(Get-DistInventoryHash $sources);toolchain=@{powershell='synthetic historical verification';dotnetRuntime='synthetic';git='synthetic'};reproducibility='Offline historical source fixture; no published archive is replaced.'}
        if ($Format -eq 2) {$record.infrastructureFiles=Sort-DistFiles $infrastructure.ToArray();$record.infrastructureInventorySha256=Get-DistInventoryHash $record.infrastructureFiles}
        $payload.Add(@{name='distribution.json';bytes=[Text.Encoding]::UTF8.GetBytes(($record | ConvertTo-Json -Depth 16 -Compress));attributes=0})
        $payload.Add(@{name='source.commit';bytes=[Text.Encoding]::ASCII.GetBytes($source);attributes=0})
        $archive=Join-Path $workspace 'historical.zip';New-TestZip $archive $payload.ToArray();$digest=(Get-FileHash -LiteralPath $archive).Hash.ToLowerInvariant()
        $verified=& "$script:RepositoryRoot/tools/Test-ToolkitDistribution.ps1" -ArchivePath $archive -ExpectedSha256 $digest -ExpectedSourceCommit $source -ExpectedVersion '0.1.0-dev.1'
        $verified.moduleName | Should -BeExactly 'CLC.Deployment'
        {& "$script:RepositoryRoot/tools/Test-ToolkitDistribution.ps1" -ArchivePath $archive -ExpectedSha256 $digest -ExpectedSourceCommit $source -ExpectedVersion '0.1.0-dev.1' -RequireInfrastructureTools} | Should -Throw '*format-3*'
        $versions=Join-Path $workspace 'versions';[void][IO.Directory]::CreateDirectory($versions)
        $expanded=& "$script:RepositoryRoot/tools/Expand-ToolkitDistribution.ps1" -ArchivePath $archive -ExpectedSha256 $digest -ExpectedSourceCommit $source -ExpectedVersion '0.1.0-dev.1' -VersionRoot (Join-Path $versions '0.1.0-dev.1') -OperatorApprovalReference historical-inspection
        $expanded.moduleManifestPath | Should -BeExactly (Join-Path $versions '0.1.0-dev.1\CLC.Deployment\CLC.Deployment.psd1')
    }
}

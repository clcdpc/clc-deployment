BeforeAll { . "$PSScriptRoot/Support.ps1" }
Describe 'Candidate public API and honest inspection' {
    It 'exports exactly four commands with the exact required explicit parameters' {
        $commands = @(Get-Command -Module CLC.Deployment | Sort-Object Name)
        $commands.Name | Should -Be @('Invoke-ClcIisDeployment','New-ClcRelease','Restore-ClcIisDeployment','Test-ClcRelease')
        $common = @('Verbose','Debug','ErrorAction','WarningAction','InformationAction','ProgressAction','ErrorVariable','WarningVariable','InformationVariable','OutVariable','OutBuffer','PipelineVariable')
        foreach ($command in $commands) {
            $expected = switch ($command.Name) {
                New-ClcRelease { @('HookRoot','MetadataPath','OutputPath','PublishRoot') }
                Test-ClcRelease { @('ArchivePath','ReleaseTag') }
                Invoke-ClcIisDeployment { @('AllowDowngrade','ArchivePath','Operation','Reason','ReleaseApprovalId','ReleaseTag','StandingAuthorizationId','TargetId','VerifiedReleasePath') }
                Restore-ClcIisDeployment { @('AttemptId','Mode','PersistentStateApprovalId','Reason','RecoveryApprovalId','TargetId') }
            }
            $actual = @($command.Parameters.Keys | Where-Object { $common -cnotcontains $_ } | Sort-Object)
            $actual | Should -Be $expected
            foreach ($parameter in $expected) {
                $type=switch ($parameter) { AllowDowngrade {[switch]}; AttemptId {[guid]}; default {[string]} }
                $command.Parameters[$parameter].ParameterType | Should -Be $type
                $mandatory=-not (($command.Name -ceq 'Invoke-ClcIisDeployment' -and $parameter -cin @('AllowDowngrade','Reason','Operation')) -or $parameter -cin @('RecoveryApprovalId','PersistentStateApprovalId','HookRoot'))
                @($command.Parameters[$parameter].Attributes | Where-Object { $_ -is [Management.Automation.ParameterAttribute] })[0].Mandatory | Should -Be $mandatory
            }
        }
    }
    It 'identifies the loaded candidate as 0.1.0-dev.1 and validates its manifest' {
        $manifest = Test-ModuleManifest -Path $script:ModulePath
        $manifest.Version.ToString() | Should -Be '0.1.0'
        $manifest.PrivateData.PSData.Prerelease | Should -Be 'dev.1'
        $manifest.PrivateData.PSData.LicenseUri | Should -Be 'https://github.com/clcdpc/clc-deployment/blob/master/LICENSE'
        & (Get-Module CLC.Deployment) { Get-ClcToolkitVersion } | Should -Be '0.1.0-dev.1'
    }
    It 'offers read-only tag classification and rejects mixed authorization parameter sets' {
        $tag=Test-ClcRelease -ReleaseTag v1.2.3-dev.4
        $tag.channel | Should -BeExactly DEV
        $tag.releaseId | Should -BeExactly v1-2-3-dev-4
        $tag.authorizedForDeployment | Should -BeFalse
        Test-TestRejection { Test-ClcRelease -ReleaseTag v1.0.0 -ArchivePath x } '*'
        Test-TestRejection { Invoke-ClcIisDeployment -TargetId x -StandingAuthorizationId x -ReleaseTag v1.0.0 -ArchivePath x -VerifiedReleasePath x -AllowDowngrade -Reason incident } '*'
    }
    It 'returns exact PackageResult and ReleaseInspection field sets without authorization material' {
        $workspace = New-TestWorkspace
        try {
            $publishArgs = New-TestPublish $workspace
            $result = New-ClcRelease @publishArgs
            $result.PSObject.Properties.Name | Should -Be @('contractFamily','packageContractVersion','releaseId','archivePath','archiveSha256','manifestSha256','inventorySha256','fileCount','totalBytes','builderVersion')
            $inspection = Test-ClcRelease $result.archivePath
            $inspection.PSObject.Properties.Name | Should -Be @('contractFamily','packageContractVersion','integrityVerified','authorizedForDeployment','applicationId','releaseId','sourceCommit','archiveSha256','manifestSha256','inventorySha256','fileCount','totalBytes','builderVersion')
            $inspection.authorizedForDeployment | Should -BeFalse
            $inspection.integrityVerified | Should -BeTrue
            $inspection.builderVersion | Should -Be '0.1.0-dev.1'
            $inspection.packageContractVersion | Should -Be 1
            $inspection.contractFamily | Should -Be 'clc-file-iis-v1'
        } finally { Remove-TestWorkspace $workspace }
    }
    It 'preserves native parameter binder validation and stable sanitized module errors' {
        Test-TestRejection { Test-ClcRelease -ArchivePath '' } 'ParameterArgumentValidationError*'
        Test-TestRejection { New-ClcRelease -PublishRoot '' -MetadataPath 'x' -OutputPath 'y' } 'ParameterArgumentValidationError*'
        try { Test-ClcRelease -ArchivePath 'C:\synthetic-never-read\private-token-sentinel.zip'; throw 'Expected failure.' }
        catch {
            $_.FullyQualifiedErrorId | Should -BeLike 'Clc.*'
            $_.Exception.Message | Should -Not -Match 'private-token-sentinel|C:\\'
        }
    }
}

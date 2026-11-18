
BeforeAll { . "$PSScriptRoot/Support.ps1" }
Describe 'Clc.Deployment public API' {
    It 'exports exactly the six lifecycle commands' {
        $names=@(Get-Command -Module Clc.Deployment | Sort-Object Name | ForEach-Object Name)
        ($names -join ',') | Should -BeExactly 'Initialize-ClcDeploymentHost,Invoke-ClcIisDeployment,New-ClcRelease,Restore-ClcIisDeployment,Test-ClcDeploymentHost,Test-ClcRelease'
    }
    It 'requires every trusted deployment input' {
        $command=Get-Command Invoke-ClcIisDeployment
        $required=@($command.ParameterSets[0].Parameters | Where-Object IsMandatory | ForEach-Object Name)
        ($required | Sort-Object) -join ',' | Should -BeExactly 'ApplicationId,ArchivePath,ExpectedRepository,ExpectedRuntimeAccount,ExpectedSha256,ExpectedSourceCommit,ReleaseTag,RuntimeEnvironment,TargetId'
    }
    It 'uses the established tag convention for <Tag>' -ForEach @(
        @{ Tag='v1.2.3'; Channel='Production' },@{ Tag='v1.2.3-dev.1'; Channel='DEV' },
        @{ Tag='v1.2.3-beta.1'; Channel='ArtifactOnly' },@{ Tag='v1.2.3-rc.1'; Channel='ArtifactOnly' }
    ) {
        $result=Test-ClcRelease -ReleaseTag $Tag
        $result.channel | Should -BeExactly $Channel
        $result.releaseId | Should -BeExactly $Tag.Replace('.','-')
    }
}

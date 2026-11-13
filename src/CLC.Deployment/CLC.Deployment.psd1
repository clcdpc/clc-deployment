@{
    RootModule = 'CLC.Deployment.psm1'
    ModuleVersion = '0.1.0'
    GUID = '06389081-3a35-4dfb-8b17-0a78a2f30fe5'
    Author = 'CLC'
    Description = 'Candidate file-only IIS deployment, explicit recovery, packaging and inspection; real IIS qualification pending.'
    PowerShellVersion = '7.6'
    CompatiblePSEditions = @('Core')
    FunctionsToExport = @('New-ClcRelease', 'Test-ClcRelease', 'Invoke-ClcIisDeployment', 'Restore-ClcIisDeployment')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{ PSData = @{ Prerelease = 'dev.1'; LicenseUri = 'https://github.com/clcdpc/clc-deployment/blob/master/LICENSE' } }
}

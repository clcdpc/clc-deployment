. "$PSScriptRoot/Reporting.ps1"
# Loaded from the independently authenticated, immutable diagnostic checkout.
# Every helper below is from THAT checkout; none is read from the candidate tree.
# Run in a fresh pwsh process. Existing framework/native types must also be trusted.
foreach ($helper in @('Contracts','Paths','Inventory','Archive','NativeProcess','Trust','State')) {
    . (Join-Path $PSScriptRoot ("../../src/CLC.Deployment/Private/$helper.ps1"))
}

function Get-ClcDeploymentPrerequisiteEnrollmentRoot {
    Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) 'CLC\Deployment\Enrollment'
}

function Test-ClcDeploymentPrerequisiteInstalledDistribution {
    param($Context, $Pin)
    & (Join-Path $PSScriptRoot '../Test-ToolkitDistribution.ps1') -ArchivePath $Context.layout.distributionPath -ExpectedSha256 $Pin.distributionSha256 -ExpectedSourceCommit $Pin.sourceCommit -ExpectedVersion $Pin.version -InstalledModuleRoot $Context.layout.moduleRoot
}

function Confirm-ClcDeploymentPrerequisiteBootstrapAuthority {
    param([string] $Path, $Handles)
    # Conservative fixed authority pattern from Assert-HAuthorityProtection,
    # SYSTEM/Administrators only. Broader valid enrollment-policy ACLs remain
    # UNVERIFIED: their own owner list cannot expand this initial trust boundary.
    $trusted=[string[]]@('S-1-5-18','S-1-5-32-544')
    $null=Get-ClcPathObservation $Path $Handles
    $null=Assert-ClcAccess $Path $trusted $trusted @()
    $cursor=[IO.Path]::GetDirectoryName($Path)
    $trustedInstaller='S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
    while ($cursor) {
        $null=Get-ClcPathObservation $cursor $Handles -Directory -AllowVolumeRoot
        $security=Get-ClcSecurityObservation $cursor
        if (@($trusted+$trustedInstaller) -cnotcontains $security.ownerSid) { Stop-ClcDeploymentPrerequisiteObservation FAIL 'The independently observed protected policy, authority, active pin or requested manifest path does not match the fixed trusted installation.' }
        foreach ($ace in $security.dacl) {
            if ($ace.AceQualifier -eq [Security.AccessControl.AceQualifier]::AccessAllowed -and
                ($ace.AceFlags -band [Security.AccessControl.AceFlags]::InheritOnly) -eq 0 -and
                (([long]$ace.AccessMask -band 0x000D0040L) -ne 0 -or ([long]$ace.AccessMask -band 0xF0000000L) -ne 0) -and
                @($trusted+$trustedInstaller) -cnotcontains $ace.SecurityIdentifier.Value) { Stop-ClcDeploymentPrerequisiteObservation FAIL 'The independently observed protected policy, authority, active pin or requested manifest path does not match the fixed trusted installation.' }
        }
        $cursor=[IO.Path]::GetDirectoryName($cursor)
    }
}

function Import-ClcDeploymentPrerequisiteTrustedToolkit {
    param([Parameter(Mandatory)][string] $ManifestPath, [Parameter(Mandatory)][scriptblock] $Inspect)
    $anchorHandles=[Collections.Generic.List[IDisposable]]::new(); $context=$null
    try {
        $root=Join-Path (Get-ClcDeploymentPrerequisiteEnrollmentRoot) 'toolkit'
        $policyPath=Join-Path $root 'policy/host-policy.json'
        Confirm-ClcDeploymentPrerequisiteBootstrapAuthority $policyPath $anchorHandles
        $policyFile=Read-ClcHeldRecord $policyPath 'host-policy' $anchorHandles
        $pin=$policyFile.record.activeToolkit
        $versionRoot=Join-Path $root ('versions/'+$pin.version)
        $moduleRoot=Join-Path $versionRoot 'CLC.Deployment'
        $expected=Join-Path $moduleRoot 'CLC.Deployment.psd1'
        if (-not [IO.Path]::IsPathFullyQualified($ManifestPath) -or $ManifestPath -cne $expected -or $pin.moduleManifestPath -cne $expected) { Stop-ClcDeploymentPrerequisiteObservation FAIL 'The independently observed protected policy, authority, active pin or requested manifest path does not match the fixed trusted installation.' }
        # Overrides are local to this trusted bootstrap, never candidate functions.
        function Get-ClcInstalledLayout {
            @{ root=$root;moduleRoot=$moduleRoot;versionRoot=$versionRoot;manifestPath=$expected;
                policyRoot=(Join-Path $root 'policy');policyPath=$policyPath;
                targetCatalogRoot=(Join-Path $root 'policy/targets');approvalCatalogRoot=(Join-Path $root 'policy/approvals');
                sourcePath=(Join-Path $versionRoot 'source.commit');distributionPath=(Join-Path $versionRoot 'distribution.zip');
                controlStateRoot=(Join-Path (Get-ClcDeploymentPrerequisiteEnrollmentRoot) 'control');lockRoot=(Join-Path (Get-ClcDeploymentPrerequisiteEnrollmentRoot) 'locks') }
        }
        function Get-ClcToolkitVersion { $pin.version }
        # Authenticate every installed module byte/dependency using the existing
        # protected policy inventory, held files, paths, source and archive pin.
        $context=Open-ClcTrustedContext
        if ($context.policyFile.sha256 -cne $policyFile.sha256) { Stop-ClcDeploymentPrerequisiteObservation FAIL 'The independently observed protected policy, authority, active pin or requested manifest path does not match the fixed trusted installation.' }
        $null=Test-ClcDeploymentPrerequisiteInstalledDistribution $context $pin
        Assert-ClcTrustedContextUnchanged $context
        # All authenticated module streams and physical identities remain held
        # against write/delete until import AND the read-only inspection finish.
        $module=Import-Module -Name $expected -Force -PassThru -Scope Local
        & $Inspect $module
        Assert-ClcTrustedContextUnchanged $context
    } finally {
        if ($null -ne $context) { Close-ClcTrustedContext $context }
        foreach ($handle in $anchorHandles) { $handle.Dispose() }
    }
}

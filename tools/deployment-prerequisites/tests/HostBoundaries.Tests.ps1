BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '../Validation.psm1') -Force
    $root=Join-Path $PSScriptRoot '../../..'
    Import-Module (Join-Path $root 'src/CLC.Deployment/CLC.Deployment.psd1') -Force
    $m=Get-Module CLC.Deployment
    . $m { param($Path) . $Path } (Join-Path $root 'tools/deployment-prerequisites/Host.ps1')
}

Describe 'Existing canonical lock observation without mutation' {
    InModuleScope CLC.Deployment {
        BeforeEach {
            Mock Assert-ClcLockOwned {}
            Mock Assert-ClcNoNamedStreams {}
            Mock Assert-ClcPathAccess {}
        }
        It 'opens an existing lock read-only and never writes bytes' {
            $path=Join-Path $TestDrive 'existing.lock'
            [IO.File]::WriteAllText($path,'synthetic lock')
            $lock=Open-ClcDeploymentPrerequisiteExistingLock @{} @{record=@{runtimeIdentitySid='synthetic'}} @{lockPath=$path}
            try {
                $lock.stream.CanRead | Should -BeTrue
                $lock.stream.CanWrite | Should -BeFalse
                { [IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) } | Should -Throw
            } finally {$lock.stream.Dispose()}
            [IO.File]::ReadAllText($path) | Should -BeExactly 'synthetic lock'
        }
        It 'never creates a missing lock' {
            $path=Join-Path $TestDrive 'missing.lock'
            { Open-ClcDeploymentPrerequisiteExistingLock @{} @{record=@{runtimeIdentitySid='synthetic'}} @{lockPath=$path} } | Should -Throw
            Test-Path -LiteralPath $path | Should -BeFalse
        }
        It 'leaves a busy lock untouched' {
            $path=Join-Path $TestDrive 'busy.lock'
            [IO.File]::WriteAllText($path,'synthetic lock')
            $busy=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
            try { { Open-ClcDeploymentPrerequisiteExistingLock @{} @{record=@{runtimeIdentitySid='synthetic'}} @{lockPath=$path} } | Should -Throw }
            finally {$busy.Dispose()}
            [IO.File]::ReadAllText($path) | Should -BeExactly 'synthetic lock'
        }
    }
}

Describe 'Protected workflow boundaries and host entry point' {
    BeforeAll {
        $root=Join-Path $PSScriptRoot '../../..'
        $workflow=Get-Content -LiteralPath (Join-Path $root '.github/workflows/validate-deployment.yml') -Raw
        $example=Get-Content -LiteralPath (Join-Path $root 'docs/examples/deployment-readiness.yml') -Raw
    }
    It 'keeps administrative tokens in the protected hosted dispatch job only' {
        $workflow | Should -Match 'environment: deployment-configuration-inspection'
        $workflow | Should -Match "inputs.administrative && github.event_name == 'workflow_dispatch'.*github.ref_protected"
        $workflow | Should -Match 'CLC_GITHUB_INSPECTION_TOKEN: \$\{\{ secrets.inspection_token \}\}'
        $workflow | Should -Not -Match 'secrets: inherit|runs-on: self-hosted|id-token: write'
        $standard=$workflow.Substring($workflow.IndexOf("`n  validate:"),$workflow.IndexOf("`n  administrative:")-$workflow.IndexOf("`n  validate:"))
        $standard | Should -Not -Match 'CLC_GITHUB_INSPECTION_TOKEN|secrets.inspection_token'
    }
    It 'keeps host access in a protected directly defined consumer job with an always aggregator' {
        $example | Should -Match 'github.workflow_ref.*diagnose-deployment.yml@refs/heads/master'
        $example | Should -Match 'github.event_name.*workflow_dispatch.*github.ref_protected'
        $example | Should -Match 'if: always\(\)'
        $example | Should -Match 'needs.host.result'
        $hostJob=$example.Substring($example.IndexOf('  host:'),$example.IndexOf('  report:')-$example.IndexOf('  host:'))
        $hostJob | Should -Not -Match 'inspection_token|secrets\.|Invoke-ClcIisDeployment|Restore-ClcIisDeployment|Initialize-ClcHostEnrollment|refs/pull/'
        $hostJob | Should -Match 'ref: ''0{40}'''
    }
    It 'reports a missing synthetic installed manifest without importing repository toolkit code' {
        $r=& (Join-Path $root 'tools/deployment-prerequisites/Test-DeploymentHost.ps1') -ApplicationId app -TargetId app-dev -EnvironmentName app-dev -DeploymentChannel DEV -Repository example/app -ReleaseWorkflow .github/workflows/release.yml -BuildJob package -StandingAuthorizationId routine-dev -ToolkitManifestPath (Join-Path $TestDrive 'CLC.Deployment.psd1')
        $r.host_status | Should -BeExactly FAIL
        $r.ready | Should -BeFalse
        $r.checks.Count | Should -Be 2
    }
    It 'preserves observed host <_> and prevents READY after a late bootstrap failure' -ForEach @('FAIL','PASS') {
        $case=$_
        # Execute the unchanged entry point in an isolated fixture checkout.
        # Only the trusted bootstrap/host observation boundaries are stubs; no
        # candidate module, native host reader or actual host is invoked.
        $fixtureRoot=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $diagnostic=Join-Path $fixtureRoot 'tools/deployment-prerequisites'
        $null=New-Item -ItemType Directory -Path $diagnostic
        foreach ($name in @('Test-DeploymentHost.ps1','Validation.psm1','Reporting.ps1')) {
            Copy-Item -LiteralPath (Join-Path $root ('tools/deployment-prerequisites/'+$name)) -Destination $diagnostic
        }
        Copy-Item -LiteralPath (Join-Path $root 'tools/Distribution.Common.ps1') -Destination (Join-Path $fixtureRoot 'tools')
        # The report-only fixture module needs no shared configuration reader.
        $fixtureModule=Join-Path $diagnostic 'Validation.psm1'
        (Get-Content -LiteralPath $fixtureModule -Raw).Replace('../release/Release.Common.ps1','../Distribution.Common.ps1') | Set-Content -LiteralPath $fixtureModule
        Set-Content -LiteralPath (Join-Path $diagnostic 'Import-TrustedToolkit.ps1') @'
function Import-ClcDeploymentPrerequisiteTrustedToolkit {
    param($ManifestPath,$Inspect)
    $module=New-Module -ScriptBlock {}
    & $Inspect $module
    throw 'SENSITIVE_BOUNDARY_DETAIL final trust observation unavailable'
}
'@
        $hostStub=@'
function Invoke-ClcDeploymentPrerequisiteHostInspection {
    param($Config)
    [pscustomobject]@{id='host.state.consistency';category='host';name='State consistency';status='STATUS';required=$true;detail='Observed protected state';action='Retain concrete infrastructure action';reason=''}
}
'@
        Set-Content -LiteralPath (Join-Path $diagnostic 'Host.ps1') ($hostStub.Replace('STATUS',$case))
        $manifest=Join-Path $fixtureRoot 'CLC.Deployment.psd1'
        Set-Content -LiteralPath $manifest '@{}'
        try {
            $r=& (Join-Path $diagnostic 'Test-DeploymentHost.ps1') -ApplicationId app -TargetId app-dev -EnvironmentName app-dev -DeploymentChannel DEV -Repository example/app -ReleaseWorkflow .github/workflows/release.yml -BuildJob package -StandingAuthorizationId routine-dev -ToolkitManifestPath $manifest
            ($r.checks | Where-Object id -EQ 'host.state.consistency').status | Should -BeExactly $case
            ($r.checks | Where-Object id -EQ 'host.state.consistency').action | Should -BeExactly 'Retain concrete infrastructure action'
            ($r.checks | Where-Object id -EQ 'host.toolkit.stability').status | Should -BeExactly UNVERIFIED
            $r.host_status | Should -BeExactly $(if ($case -ceq 'FAIL') {'FAIL'} else {'UNVERIFIED'})
            $r.ready | Should -BeFalse
            ($r | ConvertTo-Json -Depth 12) | Should -Not -Match SENSITIVE_BOUNDARY_DETAIL
        } finally {
            Get-Module Validation -All | Where-Object Path -EQ (Join-Path $diagnostic 'Validation.psm1') | Remove-Module -Force
            Import-Module (Join-Path $root 'tools/deployment-prerequisites/Validation.psm1') -Force
        }
    }
}

BeforeDiscovery {
    $bootstrap=Join-Path $PSScriptRoot '../Import-TrustedToolkit.ps1'
    $null=New-Module -Name DiagnosticBootstrap -ScriptBlock { param($Path) . $Path } -ArgumentList $bootstrap | Import-Module -Force
}

Describe 'Independent read-only authentication before candidate import' {
    InModuleScope DiagnosticBootstrap {
        BeforeEach {
            $script:enrollment=Join-Path $TestDrive 'Enrollment'
            $script:expected=Join-Path $enrollment 'toolkit/versions/0.1.0-dev.1/CLC.Deployment/CLC.Deployment.psd1'
            $script:policy=@{activeToolkit=@{version='0.1.0-dev.1';sourceCommit=('b'*40);distributionSha256=('c'*64);inventorySha256=('d'*64);moduleManifestPath=$expected}}
            $script:fixtureContext=@{policyFile=@{sha256=('e'*64)};handles=[Collections.Generic.List[IDisposable]]::new();layout=@{moduleRoot=(Split-Path $expected);distributionPath=(Join-Path $enrollment 'toolkit/versions/0.1.0-dev.1/distribution.zip')}}
            $script:order=[Collections.Generic.List[string]]::new()
            Mock Get-ClcDeploymentPrerequisiteEnrollmentRoot { $enrollment }
            Mock Confirm-ClcDeploymentPrerequisiteBootstrapAuthority { $order.Add('fixed independent authority') }
            Mock Read-ClcHeldRecord { $order.Add('protected pin'); @{record=$policy;sha256=('e'*64)} }
            Mock Open-ClcTrustedContext { $order.Add('held complete inventory/source/distribution'); $script:fixtureContext }
            Mock Test-ClcDeploymentPrerequisiteInstalledDistribution { $order.Add('archive and every dependency verified') }
            Mock Assert-ClcTrustedContextUnchanged { $order.Add('stable') }
            Mock Close-ClcTrustedContext { $order.Add('closed') }
            Mock Import-Module { $order.Add('import'); 'authenticated-module-fixture' }
        }
        It 'authenticates the independently protected exact code inventory and distribution before first import and holds through inspection' {
            $r=Import-ClcDeploymentPrerequisiteTrustedToolkit $expected { param($Module) $order.Add('inspect'); $Module }
            $r | Should -BeExactly 'authenticated-module-fixture'
            ($order -join '|') | Should -BeExactly 'fixed independent authority|protected pin|held complete inventory/source/distribution|archive and every dependency verified|stable|import|inspect|stable|closed'
            Should -Invoke Test-ClcDeploymentPrerequisiteInstalledDistribution -Times 1 -Exactly -ParameterFilter {
                $Pin.sourceCommit -ceq ('b'*40) -and $Pin.distributionSha256 -ceq ('c'*64) -and $Pin.inventorySha256 -ceq ('d'*64) -and $Context.layout.moduleRoot -ceq (Split-Path $expected)
            }
            Should -Invoke Import-Module -Times 1 -Exactly -ParameterFilter { $Name -ceq $expected -and $Scope -ceq 'Local' }
        }
        It 'never imports a module when <Boundary> cannot authenticate the candidate' -ForEach @(
            @{Boundary='fixed policy protection';Command='Confirm-ClcDeploymentPrerequisiteBootstrapAuthority'},
            @{Boundary='protected policy record';Command='Read-ClcHeldRecord'},
            @{Boundary='active source/inventory/dependency drift';Command='Open-ClcTrustedContext'},
            @{Boundary='distribution or dependency mismatch';Command='Test-ClcDeploymentPrerequisiteInstalledDistribution'},
            @{Boundary='concurrent protected drift';Command='Assert-ClcTrustedContextUnchanged'}
        ) {
            Mock $Command { throw 'Authentication unavailable or mismatch' }
            { Import-ClcDeploymentPrerequisiteTrustedToolkit $expected { throw 'MUST NOT INSPECT' } } | Should -Throw
            Should -Invoke Import-Module -Times 0 -Exactly
        }
        It 'rejects a selector or protected pin pointing outside the fixed active installation: <_>' -ForEach @('selector','pin') {
            $Selection=$_
            $candidate=$expected
            if ($Selection -ceq 'selector') { $candidate=Join-Path $TestDrive 'untrusted/CLC.Deployment.psd1' }
            else { $policy.activeToolkit.moduleManifestPath=Join-Path $TestDrive 'untrusted/CLC.Deployment.psd1' }
            { Import-ClcDeploymentPrerequisiteTrustedToolkit $candidate {} } | Should -Throw
            Should -Invoke Import-Module -Times 0 -Exactly
        }
        It 'rejects changed policy bytes between initial trust and complete context' {
            $script:fixtureContext.policyFile.sha256='f'*64
            { Import-ClcDeploymentPrerequisiteTrustedToolkit $expected {} } | Should -Throw
            Should -Invoke Import-Module -Times 0 -Exactly
            Should -Invoke Close-ClcTrustedContext -Times 1 -Exactly
        }
        It 'retains observed inspection failures and actions when the final independent trust observation is unavailable' {
            $script:stabilityChecks=0
            Mock Assert-ClcTrustedContextUnchanged {
                $script:stabilityChecks++
                if ($script:stabilityChecks -eq 2) { throw 'Final independent observation unavailable' }
            }
            $observed=[Collections.Generic.List[object]]::new()
            { Import-ClcDeploymentPrerequisiteTrustedToolkit $expected {
                $observed.Add([pscustomobject]@{status='FAIL';name='Standing authorization';detail='Disabled protected policy';action='Infrastructure must reconcile authority'})
            } } | Should -Throw
            $observed.Count | Should -Be 1
            $observed[0].status | Should -BeExactly FAIL
            $observed[0].action | Should -BeExactly 'Infrastructure must reconcile authority'
            Should -Invoke Close-ClcTrustedContext -Times 1 -Exactly
        }
        It 'does not execute a real untrusted sentinel module when independent trust is unavailable' {
            $candidateRoot=Join-Path $TestDrive 'sentinel'
            $null=New-Item -ItemType Directory -Path $candidateRoot
            $marker=Join-Path $candidateRoot 'executed'
            $sentinel=Join-Path $candidateRoot 'CLC.Deployment.psd1'
            Set-Content -LiteralPath $sentinel "@{RootModule='candidate.psm1';ModuleVersion='1.0.0'}"
            Set-Content -LiteralPath (Join-Path $candidateRoot 'candidate.psm1') "[IO.File]::WriteAllText('$marker','untrusted code executed')"
            Mock Confirm-ClcDeploymentPrerequisiteBootstrapAuthority { throw 'No independently protected trust anchor' }
            { Import-ClcDeploymentPrerequisiteTrustedToolkit $sentinel {} } | Should -Throw
            Test-Path -LiteralPath $marker | Should -BeFalse
            Should -Invoke Import-Module -Times 0 -Exactly
        }
        It 'keeps the production bootstrap rooted in trusted source without candidate helper evaluation' {
            $source=Get-Content -LiteralPath (Join-Path $PSScriptRoot '../Import-TrustedToolkit.ps1') -Raw
            $source | Should -Match '../../src/CLC.Deployment/Private/'
            $source | Should -Not -Match 'Invoke-Expression|Test-ModuleManifest|Import-PowerShellDataFile|Initialize-ClcHostEnrollment|Invoke-ClcIisDeployment|Restore-ClcIisDeployment'
            $source.IndexOf('Open-ClcTrustedContext') | Should -BeLessThan $source.IndexOf('Import-Module -Name')
        }
    }
}

Describe 'Fixed pre-import trust anchor does not trust policy-supplied owners' {
    InModuleScope DiagnosticBootstrap {
        BeforeEach {
            $handles=[Collections.Generic.List[IDisposable]]::new()
            $path=Join-Path $TestDrive 'Enrollment/toolkit/policy/host-policy.json'
            $script:owner='S-1-5-32-544'; $script:dacl=@()
            Mock Get-ClcPathObservation {}
            Mock Assert-ClcAccess { 'authenticated-descriptor-fixture' }
            Mock Get-ClcSecurityObservation { @{ownerSid=$script:owner;dacl=$script:dacl} }
        }
        It 'uses the existing independently provisioned SYSTEM/Administrators leaf boundary' {
            Confirm-ClcDeploymentPrerequisiteBootstrapAuthority $path $handles
            Should -Invoke Assert-ClcAccess -Times 1 -Exactly -ParameterFilter {
                ($Owners -join ',') -ceq 'S-1-5-18,S-1-5-32-544' -and ($Writers -join ',') -ceq 'S-1-5-18,S-1-5-32-544'
            }
        }
        It 'rejects an untrusted ancestor owner even if a candidate policy could name that owner' {
            $script:owner='S-1-5-21-100-200-300-400'
            { Confirm-ClcDeploymentPrerequisiteBootstrapAuthority $path $handles } | Should -Throw
        }
        It 'rejects unknown ancestor replacement authority' {
            $script:dacl=@([Security.AccessControl.CommonAce]::new([Security.AccessControl.AceFlags]::None,[Security.AccessControl.AceQualifier]::AccessAllowed,0x00040000,[Security.Principal.SecurityIdentifier]::new('S-1-5-21-100-200-300-400'),$false,$null))
            { Confirm-ClcDeploymentPrerequisiteBootstrapAuthority $path $handles } | Should -Throw
        }
        It 'does not turn inaccessible structural protection into independent trust' {
            Mock Assert-ClcAccess { throw 'Unreadable or untrusted descriptor' }
            { Confirm-ClcDeploymentPrerequisiteBootstrapAuthority $path $handles } | Should -Throw
        }
    }
}

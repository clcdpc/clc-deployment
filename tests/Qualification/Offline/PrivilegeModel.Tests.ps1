BeforeAll {
    . "$PSScriptRoot/../../Support.ps1"
    . "$PSScriptRoot/../Scripts/Qualification.Access.ps1"
}
Describe 'Qualification selected identity and enabled token expectations' {
    BeforeEach {
        $configuration=@{infrastructureSid='S-1-5-21-1-2-3-1001';deploymentSid='S-1-5-21-1-2-3-1002';runtimeSid='S-1-5-21-1-2-3-1003'}
    }
    It 'admits <Role> only with the required actual token' -ForEach @(
        @{Role='Infrastructure';Sid='S-1-5-21-1-2-3-1001';Enabled=$true;Present=$true},
        @{Role='Deployment';Sid='S-1-5-21-1-2-3-1002';Enabled=$true;Present=$true},
        @{Role='Runtime';Sid='S-1-5-21-1-2-3-1003';Enabled=$false;Present=$false}
    ) {
        $script:QTestToken=@{actualSid=$Sid;administratorRoleEnabled=$Enabled;administratorSidPresent=$Present}
        Mock Get-QTokenObservation { $script:QTestToken }
        (Assert-QRoleToken $configuration $Role).actualSid | Should -BeExactly $Sid
    }
    It 'rejects <Case> before host effects' -ForEach @(
        @{Case='filtered deployment administrator';Role='Deployment';Sid='S-1-5-21-1-2-3-1002';Enabled=$false;Present=$true},
        @{Case='nonadministrator deployer';Role='Deployment';Sid='S-1-5-21-1-2-3-1002';Enabled=$false;Present=$false},
        @{Case='wrong elevated deployment SID';Role='Deployment';Sid='S-1-5-21-1-2-3-1001';Enabled=$true;Present=$true},
        @{Case='runtime administrator';Role='Runtime';Sid='S-1-5-21-1-2-3-1003';Enabled=$true;Present=$true},
        @{Case='filtered runtime administrator';Role='Runtime';Sid='S-1-5-21-1-2-3-1003';Enabled=$false;Present=$true},
        @{Case='unelevated infrastructure';Role='Infrastructure';Sid='S-1-5-21-1-2-3-1001';Enabled=$false;Present=$true}
    ) {
        $script:QTestToken=@{actualSid=$Sid;administratorRoleEnabled=$Enabled;administratorSidPresent=$Present}
        Mock Get-QTokenObservation { $script:QTestToken }
        { Assert-QRoleToken $configuration $Role } | Should -Throw
    }
    It 'rejects overlapping configured account SIDs even with an elevated caller' {
        $configuration.runtimeSid=$configuration.deploymentSid
        Mock Get-QTokenObservation { @{actualSid='S-1-5-21-1-2-3-1002';administratorRoleEnabled=$true;administratorSidPresent=$true} }
        { Assert-QRoleToken $configuration Deployment } | Should -Throw '*distinct*'
    }
    It 'records actual Windows token role separately from Administrators SID presence' {
        $token=Get-QTokenObservation
        $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
        try {
            $token.actualSid | Should -BeExactly $identity.User.Value
            $token.administratorRoleEnabled | Should -Be ([Security.Principal.WindowsPrincipal]::new($identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
            $token.administratorSidPresent | Should -Be (@($identity.Groups | ForEach-Object Value) -ccontains 'S-1-5-32-544')
        } finally { $identity.Dispose() }
    }
}
Describe 'Read-only access evidence and deterministic mandatory matrix' {
    BeforeEach { $workspace=New-TestWorkspace }
    AfterEach { Remove-TestWorkspace $workspace }
    It 'observes actual current-token control rights without altering protected fixture bytes or ACLs' {
        Initialize-DistNativePaths
        $path=Join-Path $workspace 'protected.json'; [IO.File]::WriteAllText($path,'test-owned nonauthoritative access fixture')
        $before=(Get-FileHash -LiteralPath $path).Hash; $sddl=(Get-Acl -LiteralPath $path).Sddl
        $rights=Get-QAccessRights $path $false Deployment $false
        @($rights | Where-Object { -not $_.passed }).Count | Should -Be 0
        $rights.Count | Should -Be 7
        (Get-FileHash -LiteralPath $path).Hash | Should -BeExactly $before
        (Get-Acl -LiteralPath $path).Sddl | Should -BeExactly $sddl
    }
    It 'uses native Authz group access rather than only the current individual SID' {
        $sid=& (Get-Module CLC.Deployment) { Get-ClcCallerSid }
        $descriptor=[Security.AccessControl.RawSecurityDescriptor]::new('O:SYG:SYD:(A;;0x1;;;WD)')
        $bytes=[byte[]]::new($descriptor.BinaryLength); $descriptor.GetBinaryForm($bytes,0)
        (& (Get-Module CLC.Deployment) { param($b,$s) Get-ClcEffectiveAccess $b $s } $bytes $sid) | Should -Be 1L
        $context=@{policyFile=@{record=@{infrastructureOwnerSids=@('S-1-1-0');deploymentSids=@('S-1-5-21-1-2-3-9999')}}}
        # Everyone is a synthetic privileged role only in this no-effect fixture.
        { & (Get-Module CLC.Deployment) { param($c,$s) Assert-ClcRuntimeIdentity $c $s } $context $sid } | Should -Throw '*'
    }
    It 'observes actual directories and streams files without capturing their contents or masking probes' {
        $path=Join-Path $workspace 'fixture.json'; [IO.File]::WriteAllText($path,'safe private fixture')
        $handles=[Collections.Generic.List[IDisposable]]::new()
        try {
            $facts=Get-QAccessPathObservation $workspace $handles $true
            $facts.CanonicalPath | Should -BeExactly $workspace
            foreach ($handle in $handles) { $handle.Dispose() }; $handles.Clear()
            $file=Read-QAccessFile $path $handles
            $file.bytes | Should -BeNullOrEmpty; $file.sha256 | Should -BeExactly ((Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant())
        } finally { foreach ($handle in $handles) { $handle.Dispose() } }
    }
    It 'regenerates the retained catalog byte-identically without fabricating host or administrator evidence' {
        $first=Join-Path $workspace 'first'; $second=Join-Path $workspace 'second'
        $null=[IO.Directory]::CreateDirectory($first); $null=[IO.Directory]::CreateDirectory($second)
        $generator=Join-Path $script:RepositoryRoot 'tools/Update-QualificationMatrix.ps1'
        & $generator -OutputRoot $first; & $generator -OutputRoot $second
        foreach ($name in @('t4-qualification-matrix.json','t4-qualification-matrix.md')) {
            (Get-FileHash -LiteralPath (Join-Path $first $name)).Hash | Should -BeExactly (Get-FileHash -LiteralPath (Join-Path $second $name)).Hash
        }
        $report=Get-Content -LiteralPath (Join-Path $first 't4-qualification-matrix.json') -Raw | ConvertFrom-Json -AsHashtable
        $report.results.Count | Should -Be (Get-QScenarioDefinitions).Count
        @($report.results | Where-Object { $_.status -cne 'NOT RUN' -or -not $_.mandatory -or $null -ne $_.actual }).Count | Should -Be 0
        $report.realHostQualified | Should -BeFalse; $report.mandatoryExecutionComplete | Should -BeFalse
        (Get-Content -LiteralPath (Join-Path $first 't4-qualification-matrix.md'))[2] | Should -BeExactly ('Real-host verification: NOT RUN. All '+(Get-QScenarioDefinitions).Count+' retained scenarios are NOT RUN.')
        @($report.results | Where-Object scenarioId -CEQ 'security-deployment')[0].expected | Should -Match 'enabled elevated'
    }
}
Describe 'Runtime token probes without control-tree read privileges' {
    BeforeEach {
        $workspace=New-TestWorkspace
        $configuration=@{ownedRoot=$workspace;machineIdentity='12345678-1234-1234-1234-123456789abc';poolName='synthetic';
            applicationRoot=(Join-Path $workspace 'app');artifactInboxRoot=(Join-Path $workspace 'inbox');dataProtectionRoot=(Join-Path $workspace 'keys');
            operationalConfigPath=(Join-Path $workspace 'config\app.json');probeReleases=@{initial=@{approvalId='initial'};newer=@{approvalId='newer'}}}
        $layout=@{root=(Join-Path $workspace 'toolkit');moduleRoot=(Join-Path $workspace 'toolkit\module');lockRoot=(Join-Path $workspace 'locks');
            approvalCatalogRoot=(Join-Path $workspace 'toolkit\policy\approvals');policyRoot=(Join-Path $workspace 'toolkit\policy');manifestPath=(Join-Path $workspace 'toolkit\module\CLC.Deployment.psd1');
            policyPath=(Join-Path $workspace 'toolkit\policy\host-policy.json');sourcePath=(Join-Path $workspace 'toolkit\source.commit')}
        foreach ($path in @($configuration.applicationRoot,$layout.root,[IO.Path]::GetDirectoryName($configuration.operationalConfigPath))) { $null=[IO.Directory]::CreateDirectory($path) }
        $global:QWritableLeaf=''; $global:QWritableMask=2; $global:QKeysPath=$configuration.dataProtectionRoot
        Mock Get-QNativeAccess {
            if ($Path -ceq $global:QWritableLeaf -and $Mask -eq $global:QWritableMask) { return [Clc.Distribution.Paths]::ProbeAccess($Path,$Directory,$Mask) }
            return ($Path -ceq $global:QKeysPath -and $Mask -in @(2,4,16,256,0x10000))
        }
        Initialize-DistNativePaths
    }
    AfterEach { Remove-TestWorkspace $workspace }
    It 'uses fixed control/lock leaves without requiring those trees to exist or be listable in this synthetic probe fixture' {
        $observations=Get-QRuntimeAccessEvidence $configuration $layout
        @($observations | Where-Object { @($_.rights | Where-Object { -not $_.passed }).Count }).Count | Should -Be 0
        @($observations | Where-Object resource -In @('journal','current','lock-file')).Count | Should -Be 3
        @($observations | Where-Object structuralProtectionVerified).Count | Should -Be 0
    }
    It 'detects actual <Right> rights on one existing <Resource> leaf even with simulated denied parent writes' -ForEach @(
        @{Resource='application';Name='Probe.dll';Mask=2;Directory=$false;Right='WriteDataOrCreate'},
        @{Resource='toolkit';Name='Trust.ps1';Mask=2;Directory=$false;Right='WriteDataOrCreate'},
        @{Resource='configuration';Name='private.json';Mask=2;Directory=$false;Right='WriteDataOrCreate'},
        @{Resource='application';Name='append-only.dll';Mask=4;Directory=$false;Right='AppendOrCreateSubdirectory'},
        @{Resource='application';Name='subdirectory-only';Mask=4;Directory=$true;Right='AppendOrCreateSubdirectory'},
        @{Resource='toolkit';Name='delete-child';Mask=0x40;Directory=$true;Right='DeleteChild'},
        @{Resource='application';Name='write-ea.dll';Mask=16;Directory=$false;Right='WriteExtendedAttributes'},
        @{Resource='toolkit';Name='write-attributes.ps1';Mask=256;Directory=$false;Right='WriteAttributes'}
    ) {
        $root=switch ($Resource) { application {$configuration.applicationRoot};toolkit {$layout.root};configuration {[IO.Path]::GetDirectoryName($configuration.operationalConfigPath)} }
        $global:QWritableLeaf=Join-Path $root $Name; $global:QWritableMask=$Mask
        if ($Directory) { $null=[IO.Directory]::CreateDirectory($global:QWritableLeaf) } else { [IO.File]::WriteAllText($global:QWritableLeaf,'test-owned readable/writable leaf') }
        $observations=Get-QRuntimeAccessEvidence $configuration $layout
        $leaf=@($observations | Where-Object leafName -CEQ $Name)[0]
        @($leaf.rights | Where-Object { $_.right -ceq $Right -and $_.granted -and -not $_.passed }).Count | Should -Be 1
    }
}
Describe 'Qualification access-policy drift admission' {
    BeforeEach {
        $configuration=Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'tests/Qualification/Configuration/example.template.json') -Raw | ConvertFrom-Json -AsHashtable
        $infra=@($configuration.infrastructureSid,'S-1-5-18','S-1-5-32-544')
        $layout=@{targetCatalogRoot='C:\synthetic\targets';approvalCatalogRoot='C:\synthetic\approvals';controlStateRoot='C:\synthetic\control';lockRoot='C:\synthetic\locks'}
        $policy=@{machineIdentity=$configuration.machineIdentity;dotnetPath=$configuration.dotnetPath;appcmdPath=$configuration.appcmdPath;infrastructureOwnerSids=$infra;deploymentSids=@($configuration.deploymentSid);
            activeToolkit=@{version=$configuration.toolkit.version;sourceCommit=$configuration.toolkit.sourceCommit;distributionSha256=$configuration.toolkit.distributionSha256;inventorySha256=$configuration.toolkit.inventorySha256;moduleManifestPath=(Get-QInstalledManifest $configuration)}}
        foreach ($name in $layout.Keys) { $policy[$name]=$layout[$name] }
    }
    It 'accepts the selected structural identity without requiring separate administrative groups' {
        { Assert-QAccessPolicy $configuration $layout $policy $infra } | Should -Not -Throw
    }
    It 'refuses <Drift> in the selected protected policy' -ForEach @(
        @{Drift='machineIdentity'},@{Drift='dotnetPath'},@{Drift='appcmdPath'},@{Drift='approvalCatalogRoot'},@{Drift='sourceCommit'},@{Drift='infrastructureOwnerSids'}
    ) {
        if ($Drift -ceq 'sourceCommit') { $policy.activeToolkit.sourceCommit='b'*40 }
        elseif ($Drift -ceq 'infrastructureOwnerSids') { $policy.infrastructureOwnerSids+=@($configuration.runtimeSid) }
        else { $policy[$Drift]='unexpected' }
        { Assert-QAccessPolicy $configuration $layout $policy $infra } | Should -Throw
    }
}

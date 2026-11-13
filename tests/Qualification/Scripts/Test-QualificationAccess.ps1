[CmdletBinding()]
param([Parameter(Mandatory)][string] $ConfigurationPath,[Parameter(Mandatory)][ValidateSet('Deployment','Runtime','Infrastructure')][string] $Role,[Parameter(Mandatory)][string] $AuthorizationPath,[Parameter(Mandatory)][string] $OutputPath)
. "$PSScriptRoot/Qualification.Access.ps1"
$configuration=Read-QConfiguration $ConfigurationPath
Assert-DistLocalPath $OutputPath
if (-not $OutputPath.StartsWith($configuration.evidenceRoot+'\',[StringComparison]::Ordinal)) { throw 'Access evidence must remain outside authoritative resources in the selected evidence root.' }
$null=Assert-QAuthorization $configuration $AuthorizationPath @('execute','change-owned-fixtures')
$token=Assert-QRoleToken $configuration $Role
$null=Read-QOwnership $configuration
Import-QVerifiedToolkit $configuration
Initialize-DistNativePaths
$infra=Get-QInfrastructureSids $configuration; $runtime=$configuration.runtimeSid
$layout=Invoke-QPrivate Get-ClcInstalledLayout
$handles=[Collections.Generic.List[IDisposable]]::new()
$protectedRecords=[Collections.Generic.List[object]]::new()
try {
    $policyFile=Invoke-QPrivate Read-ClcHeldRecord @($layout.policyPath,'host-policy',$handles)
    $protectedRecords.Add($policyFile)
    $policy=$policyFile.record
    Assert-QAccessPolicy $configuration $layout $policy $infra
    Invoke-QPrivate Assert-ClcRuntimeIdentity @(@{policyFile=@{record=$policy}},$runtime)
    foreach ($id in @($configuration.targetId,$configuration.alternateTargetId)) {
        $file=Invoke-QPrivate Read-ClcHeldRecord @((Join-Path $layout.targetCatalogRoot ($id+'.json')),'target',$handles)
        $protectedRecords.Add($file)
        foreach ($name in @('applicationRoot','operationalConfigPath','dataProtectionRoot','artifactInboxRoot','siteName','readinessUri','runtimeEnvironment')) {
            if ($file.record[$name] -cne $configuration[$name]) { throw 'Protected target path drift.' }
        }
        if ($file.record.targetId -cne $id -or $file.record.applicationPoolName -cne $configuration.poolName -or $file.record.runtimeIdentitySid -cne $runtime) { throw 'Protected target identity drift.' }
    }
    foreach ($slot in @('initial','newer')) {
        if (-not [IO.File]::Exists((Join-Path $layout.approvalCatalogRoot ($configuration.probeReleases[$slot].approvalId+'.json')))) { throw 'Required approval leaf is absent.' }
    }
    # Access probes must not be suppressed by our own no-write/delete-share pins.
    foreach ($handle in $handles) { $handle.Dispose() }; $handles.Clear()
    if ($Role -ceq 'Runtime') {
        $observations=Get-QRuntimeAccessEvidence $configuration $layout
    } else {
    $roots=[ordered]@{toolkit=$layout.root;configuration=[IO.Path]::GetDirectoryName($configuration.operationalConfigPath);
        application=$configuration.applicationRoot;inbox=$configuration.artifactInboxRoot;control=$policy.controlStateRoot;locks=$policy.lockRoot;keys=$configuration.dataProtectionRoot}
    $observations=[Collections.Generic.List[object]]::new(); $clock=[Diagnostics.Stopwatch]::StartNew(); $count=0
    foreach ($resource in $roots.Keys) {
        $queue=[Collections.Generic.Queue[string]]::new(); $queue.Enqueue($roots[$resource])
        while ($queue.Count) {
            $path=$queue.Dequeue(); $count++
            if ($count -gt 20000 -or $clock.Elapsed.TotalSeconds -ge 300) { throw 'Access observation exceeded its bound.' }
            $directory=[IO.Directory]::Exists($path)
            $facts=Get-QAccessPathObservation $path $handles $directory
            foreach ($handle in $handles) { $handle.Dispose() }; $handles.Clear()
            $mutable=$resource -cin @('application','inbox','control','locks'); $keys=$resource -ceq 'keys'
            $owners=if ($mutable) { $infra+@($configuration.deploymentSid) } else { $infra }
            $writers=if ($keys) { $infra+@($runtime) } else { $owners }
            $denied=if ($keys) { [string[]]@() } else { [string[]]@($runtime) }
            $null=Invoke-QPrivate Assert-ClcAccess @($path,$owners,$writers,[string[]]@(),$denied,0L)
            $security=Invoke-QPrivate Get-ClcSecurityObservation @($path)
            if ($keys -and ((Invoke-QPrivate Get-ClcEffectiveAccess @($security.bytes,$runtime)) -band 0x000C0000L) -ne 0) { throw 'Runtime controls key-root ownership or DACL.' }
            $actualMask=Invoke-QPrivate Get-ClcEffectiveAccess @($security.bytes,$token.actualSid)
            $rights=Get-QAccessRights $path $directory $Role $keys
            $after=Get-QAccessPathObservation $path $handles $directory
            foreach ($handle in $handles) { $handle.Dispose() }; $handles.Clear()
            if ($facts.VolumeId -cne $after.VolumeId -or $facts.FileId -cne $after.FileId -or
                (Invoke-QPrivate Get-ClcSecurityObservation @($path)).sha256 -cne $security.sha256) { throw 'Access observation drift.' }
            $parent=[IO.Path]::GetDirectoryName($path)
            while ($parent) {
                $parentSecurity=Invoke-QPrivate Get-ClcSecurityObservation @($parent)
                if ($parentSecurity.ownerSid -ceq $runtime -or ((Invoke-QPrivate Get-ClcEffectiveAccess @($parentSecurity.bytes,$runtime)) -band 0x000D0040L) -ne 0) { throw 'Runtime can replace or control a protected parent.' }
                $parent=[IO.Path]::GetDirectoryName($parent)
            }
            $aces=@($security.dacl | ForEach-Object { @{sid=$_.SecurityIdentifier.Value;qualifier=$_.AceQualifier.ToString();mask=[long]$_.AccessMask;inherited=$_.IsInherited} })
            $observations.Add(@{resource=$resource;relativePath=$path.Substring($roots[$resource].Length);ownerSid=$security.ownerSid;acl=$aces;
                effectiveAccessMask=$actualMask;directDeploymentAces=@($aces | Where-Object { $_.sid -ceq $configuration.deploymentSid -and -not $_.inherited });
                administratorsAces=@($aces | Where-Object sid -CEQ 'S-1-5-32-544');rights=$rights;structuralProtectionVerified=$true})
            if ($directory -and -not $keys) { foreach ($child in [IO.Directory]::EnumerateFileSystemEntries($path)) { $queue.Enqueue($child) } }
            elseif (-not $directory) {
                $null=Read-QAccessFile $path $handles
                foreach ($handle in $handles) { $handle.Dispose() }; $handles.Clear()
            }
        }
    }
    }
    Import-QVerifiedToolkit $configuration
    foreach ($original in $protectedRecords) {
        $final=Invoke-QPrivate Read-ClcHeldRecord @($original.path,$original.record.recordKind,$handles)
        if ($final.sha256 -cne $original.sha256 -or $final.facts.VolumeId -cne $original.facts.VolumeId -or $final.facts.FileId -cne $original.facts.FileId) { throw 'Protected access-policy bytes or physical identity changed.' }
    }
    $passed=@($observations | Where-Object { @($_.rights | Where-Object { -not $_.passed }).Count }).Count -eq 0
    Write-QJson $OutputPath @{formatVersion=1;securityModel='ElevatedV1';campaignId=$configuration.campaignId;configurationSha256=$configuration._sha256;
        role=$Role;expectedSid=$(switch ($Role) {Deployment {$configuration.deploymentSid};Runtime {$runtime};Infrastructure {$configuration.infrastructureSid}});
        actualSid=$token.actualSid;administratorSidPresent=$token.administratorSidPresent;administratorRoleEnabled=$token.administratorRoleEnabled;
        administrativeBypass='Expected for administrators; no containment claim';deploymentInfrastructureIsolation='Accepted elevated-V1 limitation';approvalSeparation='Independent infrastructure procedure';
        observations=$observations.ToArray();roleAccessVerified=$passed;actualRuntimeTokenIsolationVerified=($Role -ceq 'Runtime' -and $passed);administrativeStructuralChecksVerified=($Role -cne 'Runtime' -and $passed);structuralEvidenceRequired=($Role -ceq 'Runtime');passed=$passed}
    if (-not $passed) { throw 'Actual role access failed. Keep host qualification blocked.' }
} finally { foreach ($handle in $handles) { $handle.Dispose() } }

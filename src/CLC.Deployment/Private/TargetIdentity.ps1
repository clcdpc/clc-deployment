function Get-ClcMachineUuidObservation {
    return @(Get-CimInstance -Namespace root/CIMV2 -ClassName Win32_ComputerSystemProduct -Property UUID -OperationTimeoutSec 10 -ErrorAction Stop | ForEach-Object { $_.UUID })
}

function Get-ClcMachineIdentity {
    param([string] $EnrolledIdentity)
    try {
        $values = @(Get-ClcMachineUuidObservation)
        $guid = [guid]::Empty
        if ($values.Count -ne 1 -or $values[0] -isnot [string] -or
            -not [guid]::TryParseExact($values[0],'D',[ref]$guid)) { Stop-ClcError Clc.HostPreflightFailed }
        $identity = $guid.ToString('D').ToLowerInvariant()
        Assert-ClcGuid $identity -Machine
        if ($identity -cne $EnrolledIdentity) { Stop-ClcError Clc.HostPreflightFailed }
        return $identity
    } catch { Stop-ClcError Clc.HostPreflightFailed }
}

function Get-ClcCanonicalPoolName {
    param([string] $RequestedName, [string[]] $ActualNames)
    Assert-ClcText $RequestedName 64 '^[A-Za-z0-9_.-]{1,64}$'
    $matches = @($ActualNames | Where-Object { [string]::Equals($_,$RequestedName,[StringComparison]::OrdinalIgnoreCase) })
    if ($matches.Count -ne 1) { Stop-ClcError Clc.HostPreflightFailed }
    Assert-ClcText $matches[0] 64 '^[A-Za-z0-9_.-]{1,64}$'
    return $matches[0].ToUpperInvariant()
}

function Get-ClcTargetKey {
    param([string] $MachineIdentity, [string] $NormalizedPoolName)
    Assert-ClcGuid $MachineIdentity -Machine
    Assert-ClcText $NormalizedPoolName 64 '^[A-Z0-9_.-]{1,64}$'
    return Get-ClcBytesHash ([Text.Encoding]::UTF8.GetBytes($MachineIdentity + [char]0 + $NormalizedPoolName))
}

function ConvertTo-ClcRootIdentity {
    param($Facts)
    return [ordered]@{ volumeId=$Facts.VolumeId; fileId=$Facts.FileId; canonicalPath=$Facts.CanonicalPath }
}

function Test-ClcValueEqual {
    param($First, $Second)
    if ($null -eq $First -or $null -eq $Second) { return $null -eq $First -and $null -eq $Second }
    if ($First -is [Collections.IDictionary] -and $Second -is [Collections.IDictionary]) {
        if ($First.Count -ne $Second.Count) { return $false }
        foreach ($key in $First.Keys) {
            if (@($Second.Keys) -cnotcontains $key -or -not (Test-ClcValueEqual $First[$key] $Second[$key])) { return $false }
        }
        return $true
    }
    if ($First -is [array] -and $Second -is [array]) {
        if ($First.Count -ne $Second.Count) { return $false }
        for ($i=0;$i -lt $First.Count;$i++) { if (-not (Test-ClcValueEqual $First[$i] $Second[$i])) { return $false } }
        return $true
    }
    return $First -ceq $Second
}

function Get-ClcTargetIdentity {
    param($Context, $TargetFile)
    Assert-ClcHeldRecordUnchanged $Context $TargetFile 'Clc.HostPreflightFailed'
    $target=$TargetFile.record; $policy=$Context.policyFile.record
    $machine=Get-ClcMachineIdentity $policy.machineIdentity
    $pool=Get-ClcCanonicalPoolName $target.applicationPoolName (Get-ClcIisPoolNames $Context)
    $key=Get-ClcTargetKey $machine $pool
    $facts=@{}
    foreach ($name in @('applicationRoot','operationalConfigPath','dataProtectionRoot','artifactInboxRoot')) {
        $facts[$name]=Get-ClcPathObservation $target[$name] $Context.handles -Directory:($name -cne 'operationalConfigPath')
    }
    $facts.configDirectory=Get-ClcPathObservation ([IO.Path]::GetDirectoryName($target.operationalConfigPath)) $Context.handles -Directory
    $facts.controlRoot=Add-ClcProtectedPathPin $Context (Join-Path $policy.controlStateRoot $key) -Directory -Mutable -RuntimeSid $target.runtimeIdentitySid
    $disjoint=@($facts.applicationRoot,$facts.configDirectory,$facts.dataProtectionRoot,$facts.artifactInboxRoot,
        $Context.rootFacts.controlStateRoot,$Context.rootFacts.lockRoot,$Context.pathPins[$Context.layout.root].facts)
    for ($i=0;$i -lt $disjoint.Count;$i++) { for ($j=$i+1;$j -lt $disjoint.Count;$j++) { Assert-ClcDisjoint $disjoint[$i] $disjoint[$j] } }
    $roots=[ordered]@{}
    foreach ($name in @('applicationRoot','operationalConfigPath','dataProtectionRoot','controlRoot','artifactInboxRoot')) { $roots[$name]=ConvertTo-ClcRootIdentity $facts[$name] }
    $snapshot=[ordered]@{ machineIdentity=$machine; siteName=$target.siteName; applicationPoolName=$pool; rootIdentities=$roots }
    Assert-ClcTargetSnapshot $snapshot
    $iis=Get-ClcIisObservation $Context $target
    Assert-ClcIisTargetBinding $target $iis $pool
    $snapshot.siteName=$iis.siteName
    return @{ targetKey=$key; snapshot=$snapshot; facts=$facts; iis=$iis;
        lockPath=(Join-Path $policy.lockRoot ($key+'.lock')); controlRoot=$facts.controlRoot.CanonicalPath }
}

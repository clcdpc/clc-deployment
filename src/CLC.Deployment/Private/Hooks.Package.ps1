# Package declarations describe verified inputs, never authority to execute them.
function Assert-ClcHookAssetName {
    param($Path)
    Assert-ClcArchiveName $Path -HookOnly
    Assert-ClcPublishName $Path.Substring(6) -HookAssets
}
function Assert-ClcHookManifest {
    param($Value, [switch] $Manifest)
    $keys=@('contractVersion','stages','planningEntryPoint')
    if ($Manifest) { $keys+='files','inventorySha256' }
    Assert-ClcObject $Value $keys
    Assert-ClcInteger $Value.contractVersion 1 1
    if ($Value.stages -isnot [object[]] -or $Value.stages.Count -gt 4) { Stop-ClcError Clc.InvalidContract }
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $entryPoints=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in $Value.stages) {
        Assert-ClcObject $entry @('stage','entryPoint')
        Assert-ClcEnum $entry.stage @('Preflight','BeforeStop','AfterStop','AfterStart')
        if (-not $seen.Add($entry.stage)) { Stop-ClcError Clc.InvalidContract }
        Assert-ClcHookAssetName $entry.entryPoint
        if (-not $entry.entryPoint.EndsWith('.ps1',[StringComparison]::Ordinal)) { Stop-ClcError Clc.InvalidContract }
        $null=$entryPoints.Add($entry.entryPoint)
    }
    if ($null -ne $Value.planningEntryPoint) {
        Assert-ClcHookAssetName $Value.planningEntryPoint
        if (-not $Value.planningEntryPoint.EndsWith('.ps1',[StringComparison]::Ordinal) -or
            $entryPoints.Contains($Value.planningEntryPoint)) { Stop-ClcError Clc.InvalidContract }
        $null=$entryPoints.Add($Value.planningEntryPoint)
    }
    if ($entryPoints.Count -eq 0) { Stop-ClcError Clc.InvalidContract }
    if ($Manifest) {
        Assert-ClcFiles $Value.files -HookAssets
        Assert-ClcHash $Value.inventorySha256
        if ($Value.inventorySha256 -cne (Get-ClcInventoryHash $Value.files)) { Stop-ClcError Clc.HashMismatch }
        foreach ($entryPoint in $entryPoints) {
            if (@($Value.files.path) -cnotcontains $entryPoint) { Stop-ClcError Clc.InvalidContract }
        }
    }
}

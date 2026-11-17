# Validate complete trees at admission and completion. Inner operations only
# observe their own paths and the pool; no host audits, leases or per-file state.
function Assert-ClcPayloadLayout {
    param([object[]] $OldFiles,[object[]] $NewFiles)
    $paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in @($OldFiles)+@($NewFiles)) { if ($null -ne $file) { $null=$paths.Add($file.path) } }
    foreach ($path in $paths) {
        foreach ($prefix in Get-ClcNamePrefixes $path) {
            if ($paths.Contains($prefix)) { Stop-ClcError Clc.ReplacementFailed }
        }
    }
}
function Remove-ClcPayloadFile {
    param([string] $Path)
    Assert-ClcFilePath $Path
    [IO.File]::Delete($Path)
}
function Invoke-ClcManagedReplacement {
    param($Session,[string] $Source,[object[]] $SelectedFiles,[object[]] $ExistingFiles,[switch] $Partial,[object[]] $OtherFiles=@(),[switch] $AllowChanged)
    $clock=[Diagnostics.Stopwatch]::StartNew(); $lock=$Session.lock; $root=$lock.targetFile.record.applicationRoot
    $null=Assert-ClcEffectAuthority $Session -Stopped
    if ($SelectedFiles.Count -eq 1 -and $SelectedFiles[0].path -ceq 'application/web.config') {
        $null=Get-ClcTreeInventory $Source $Session.release.manifest.files -DeadlineClock $clock
    } else { $null=Get-ClcTreeInventory $Source $SelectedFiles -DeadlineClock $clock }
    $live=Get-ClcTreeInventory $root $ExistingFiles -Partial:$Partial -OtherFiles $OtherFiles -AllowChanged:$AllowChanged -DeadlineClock $clock
    Assert-ClcPayloadLayout $live.files $SelectedFiles
    $null=Write-ClcJournalIntent $lock Replace
    $Session.replacementBegun=$true
    $selected=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($file in $SelectedFiles) { $null=$selected.Add($file.path) }
    foreach ($file in $live.files) {
        Assert-ClcDeadline $clock
        if ($selected.Contains($file.path) -or $file.path -ceq 'application/web.config') { continue }
        Assert-ClcIisQuiescent $lock
        Remove-ClcPayloadFile (Get-ClcManagedPath $root $file.path)
    }
    # Keep ANCM configuration present while replacing an existing application.
    # The first installation writes it before any executable application file.
    foreach ($file in @($SelectedFiles | Sort-Object @{Expression={if ($_.path -ceq 'application/web.config') {0} else {1}}},path)) {
        Assert-ClcDeadline $clock
        $destination=Get-ClcManagedPath $root $file.path
        $parent=[IO.Path]::GetDirectoryName($destination)
        $current=$root
        foreach ($part in $parent.Substring($root.Length).TrimStart('\').Split('\',[StringSplitOptions]::RemoveEmptyEntries)) {
            Assert-ClcFilePath $current -Directory
            $current=Join-Path $current $part
            if (-not [IO.Directory]::Exists($current)) { $null=[IO.Directory]::CreateDirectory($current) }
            Assert-ClcFilePath $current -Directory
        }
        Assert-ClcIisQuiescent $lock
        Copy-ClcPayloadFile (Get-ClcManagedPath $Source $file.path) $destination $true
    }
    $needed=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $oldDirectories=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($file in $SelectedFiles) { foreach ($prefix in Get-ClcNamePrefixes $file.path) { $null=$needed.Add($prefix) } }
    foreach ($file in $live.files) { foreach ($prefix in Get-ClcNamePrefixes $file.path) { $null=$oldDirectories.Add($prefix) } }
    foreach ($relative in @($oldDirectories | Sort-Object Length -Descending)) {
        if ($relative -ceq 'application' -or $needed.Contains($relative)) { continue }
        Assert-ClcDeadline $clock; Assert-ClcIisQuiescent $lock
        $path=Get-ClcManagedPath $root ($relative+'/placeholder')
        $path=[IO.Path]::GetDirectoryName($path)
        Assert-ClcFilePath $path -Directory
        [IO.Directory]::Delete($path,$false)
    }
    $null=Get-ClcTreeInventory $root $SelectedFiles -DeadlineClock $clock
    Assert-ClcIisQuiescent $lock
    Assert-ClcDeadline $clock
    $Session.replacementSeconds=$clock.Elapsed.TotalSeconds
}

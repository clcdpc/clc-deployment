function Get-ClcToolkitVersion {
    [CmdletBinding()]
    param($Module = $ExecutionContext.SessionState.Module)

    if ($null -eq $Module -or $Module.Version -isnot [version]) { Stop-ClcError Clc.InvalidContract }
    $version = $Module.Version.ToString()
    $privateData = $Module.PrivateData
    if ($null -ne $privateData) {
        if ($privateData -isnot [Collections.IDictionary]) { Stop-ClcError Clc.InvalidContract }
        if ($privateData.Contains('PSData')) {
            $psData = $privateData['PSData']
            if ($null -ne $psData) {
                if ($psData -isnot [Collections.IDictionary]) { Stop-ClcError Clc.InvalidContract }
                if ($psData.Contains('Prerelease')) {
                    $prerelease = $psData['Prerelease']
                    if ($prerelease -isnot [string] -or [string]::IsNullOrWhiteSpace($prerelease)) { Stop-ClcError Clc.InvalidContract }
                    $version += '-' + $prerelease
                }
            }
        }
    }
    Assert-ClcVersion $version
    return $version
}

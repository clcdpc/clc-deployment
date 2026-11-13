. "$PSScriptRoot/Qualification.Common.ps1"
function Assert-QNoForeignPoolApplications($Manager,$Configuration) {
    foreach ($site in $Manager.Sites) { foreach ($application in $site.Applications) {
        if ($site.Name -ine $Configuration.siteName -and $application.ApplicationPoolName -ieq $Configuration.poolName) { throw 'Another application now shares the pool; retirement refuses.' }
    } }
}
function Convert-QIisElement($Element,[string] $Location,[int] $Depth=0) {
    if ($Depth -gt 16 -or $Element.Attributes.Count -gt 512 -or $Element.ChildElements.Count -gt 512) { throw 'IIS ownership observation exceeds its bound.' }
    $attributes=[ordered]@{}
    foreach ($attribute in @($Element.Attributes | Sort-Object Name -CaseSensitive -Culture '')) {
        $name=[string]$attribute.Name
        # Never read a credential value, raw XML or an arbitrary environment value.
        if ($name -imatch 'password|credential|secret|token|privatekey|connectionstring' -or ($Location -imatch 'environmentVariables/add$' -and $name -ceq 'value')) {
            $attributes[$name]='ProtectedValueNotRead'; continue
        }
        $value=$attribute.Value
        $attributes[$name]=if ($null -eq $value) {$null} elseif ($value -is [byte[]]) {[Convert]::ToHexString($value)} elseif ($value -is [IFormattable]) {$value.ToString($null,[Globalization.CultureInfo]::InvariantCulture)} else {[string]$value}
        if ($null -ne $attributes[$name] -and $attributes[$name].Length -gt 4096) { throw 'IIS attribute exceeds its observation bound.' }
    }
    $children=@()
    foreach ($child in @($Element.ChildElements | Sort-Object { $_.Schema.Name } -CaseSensitive -Culture '')) { $children += Convert-QIisElement $child ($Location+'/'+$child.Schema.Name) ($Depth+1) }
    $elements=@()
    if ($null -ne $Element.Schema.CollectionSchema) {
        $collection=$Element.GetCollection()
        if ($collection.Count -gt 4096) { throw 'IIS collection exceeds its observation bound.' }
        foreach ($child in $collection) { $elements += Convert-QIisElement $child ($Location+'/'+$child.Schema.Name) ($Depth+1) }
    }
    [ordered]@{name=[string]$Element.Schema.Name;attributes=$attributes;children=$children;elements=$elements}
}
function Get-QIisOwnershipSnapshot($Manager,$Configuration) {
    $site=$Manager.Sites[$Configuration.siteName]; $pool=$Manager.ApplicationPools[$Configuration.poolName]
    if ($null -eq $site -or $null -eq $pool) { throw 'Owned IIS resources are missing.' }
    $bindings=@($site.Bindings | Sort-Object Protocol,Host,@{Expression={$_.EndPoint.Port}} -CaseSensitive -Culture '' | ForEach-Object {
        @{protocol=$_.Protocol;host=$_.Host;address=$_.EndPoint.Address.ToString();port=[long]$_.EndPoint.Port;sslFlags=$_.SslFlags.ToString();certificateStore=$_.CertificateStoreName;certificateThumbprint=$(if ($null -eq $_.CertificateHash) {''} else {[Convert]::ToHexString($_.CertificateHash)})}
    })
    $environment=@($pool.GetCollection('environmentVariables') | ForEach-Object {
        $name=[string]$_['name']
        if ($name -cnotin @('ASPNETCORE_ENVIRONMENT','CLC_PROBE_CONFIGURATION_PATH','CLC_PROBE_DATA_PROTECTION_ROOT')) { throw 'Unexpected pool environment prevents ownership cleanup.' }
        @{name=$name;value=[string]$_['value']}
    } | Sort-Object name -CaseSensitive -Culture '')
    $expected=@{ASPNETCORE_ENVIRONMENT=$Configuration.runtimeEnvironment;CLC_PROBE_CONFIGURATION_PATH=$Configuration.operationalConfigPath;CLC_PROBE_DATA_PROTECTION_ROOT=$Configuration.dataProtectionRoot}
    if ($environment.Count -ne 3) { throw 'Pool environment ownership differs.' }
    foreach ($item in $environment) { if ($item.value -cne $expected[$item.name]) { throw 'Pool environment ownership differs.' } }
    $siteProjection=Convert-QIisElement $site 'site'; $poolProjection=Convert-QIisElement $pool 'pool'
    [ordered]@{siteId=[long]$site.Id;siteName=$site.Name;poolName=$pool.Name;bindings=$bindings;environment=$environment;
        siteConfigurationSha256=(Get-DistHash ([Text.Encoding]::UTF8.GetBytes(($siteProjection | ConvertTo-Json -Depth 32 -Compress))));
        poolConfigurationSha256=(Get-DistHash ([Text.Encoding]::UTF8.GetBytes(($poolProjection | ConvertTo-Json -Depth 32 -Compress))))}
}
function Assert-QIisOwnershipSnapshot($Expected,$Actual) {
    if ($null -eq $Expected -or -not (Invoke-QPrivate Test-ClcValueEqual @($Expected,$Actual))) { throw 'Owned IIS binding/site/pool configuration drifted; retain resources for independent operator review.' }
}
function Get-QOwnedRootIdentities($Configuration) {
    $paths=[ordered]@{applicationRoot=$Configuration.applicationRoot;configurationDirectory=[IO.Path]::GetDirectoryName($Configuration.operationalConfigPath);dataProtectionRoot=$Configuration.dataProtectionRoot;artifactInboxRoot=$Configuration.artifactInboxRoot;
        controlStateRoot=(Join-Path $Configuration.ownedRoot 'control');lockRoot=(Join-Path $Configuration.ownedRoot 'locks');toolkitRoot=(Join-Path $Configuration.ownedRoot 'toolkit')}
    $result=[ordered]@{}
    foreach ($name in $paths.Keys) { $result[$name]=(Get-DistPathFacts $paths[$name] -Directory).Identity }
    $result
}

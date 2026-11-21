function Get-ClcIisPhysicalRoot {
    param([string] $Path,[Diagnostics.Stopwatch] $Clock)
    # Read-only IIS configuration observation, not a selectable deployment root.
    # Unknown expansion, network paths and physical aliases are uncertain and
    # refuse. Never expand IIS paths through the caller's environment.
    $windows=[Clc.Foundation.NativePaths]::WindowsDirectory()
    $drive=[IO.Path]::GetPathRoot($windows).TrimEnd('\')
    foreach ($token in [regex]::Matches($Path,'%([^%]+)%')) {
        if ($token.Groups[1].Value -inotin @('SystemDrive','SystemRoot','windir','ProgramData')) {Stop-ClcError Clc.HostPreflightFailed}
    }
    $expanded=[regex]::Replace($Path,'%([^%]+)%',[Text.RegularExpressions.MatchEvaluator]{param($match)
        switch ($match.Groups[1].Value.ToLowerInvariant()) {
            systemdrive {return $drive}
            systemroot {return $windows}
            windir {return $windows}
            programdata {return Get-ClcProgramDataRoot}
            default {Stop-ClcError Clc.HostPreflightFailed}
        }
    })
    if ($expanded.Contains('%')) {Stop-ClcError Clc.HostPreflightFailed}
    Assert-ClcPathSpelling $expanded
    $handles=[Collections.Generic.List[IDisposable]]::new()
    try {
        $cursor=$expanded;$parts=[Collections.Generic.List[string]]::new()
        while (-not [IO.Directory]::Exists($cursor)) {
            Assert-ClcDeadline $Clock 30
            if ([IO.File]::Exists($cursor) -or $parts.Count -ge 32) {Stop-ClcError Clc.HostPreflightFailed}
            $existing=[Clc.Foundation.NativePaths]::OpenExistingOrNull($cursor)
            if ($null -ne $existing) { $existing.Dispose();Stop-ClcError Clc.HostPreflightFailed }
            $parts.Insert(0,[IO.Path]::GetFileName($cursor));$cursor=[IO.Path]::GetDirectoryName($cursor)
            if (-not $cursor) {Stop-ClcError Clc.HostPreflightFailed}
        }
        # Other IIS directories are read-only observations and can legitimately
        # be outside CLC namespaces. Native identity/alias/stream checks remain.
        $facts=Get-ClcPathObservation $cursor $handles -Directory -AllowVolumeRoot
        $physical=$facts.PhysicalPath
        foreach ($part in $parts) {$physical=Join-Path $physical $part}
        return @{physicalPath=$physical;volumeId=$facts.VolumeId;fileId=$(if ($parts.Count -eq 0) {$facts.FileId} else {$null})}
    } finally {foreach ($handle in $handles) {$handle.Dispose()}}
}

function Assert-ClcIisPhysicalIsolation {
    param($Manager,$Target,[switch] $IncludeSelected)
    $clock=[Diagnostics.Stopwatch]::StartNew()
    if ($Manager.Sites.Count -gt 4096 -or $Manager.ApplicationPools.Count -gt 4096) {Stop-ClcError Clc.HostPreflightFailed}
    $selected=Get-ClcIisPhysicalRoot $Target.applicationRoot $clock
    $apps=0;$directories=0
    foreach ($site in $Manager.Sites) {
        foreach ($app in $site.Applications) {
            $apps++;if ($apps -gt 4096) {Stop-ClcError Clc.HostPreflightFailed}
            foreach ($directory in $app.VirtualDirectories) {
                Assert-ClcDeadline $clock 30
                $directories++;if ($directories -gt 4096) {Stop-ClcError Clc.HostPreflightFailed}
                # Only the selected root application/root vdir may use this tree.
                if (-not $IncludeSelected -and $site.Name -ieq $Target.siteName -and $app.Path -ceq '/' -and $directory.Path -ceq '/' -and $app.ApplicationPoolName -ieq $Target.applicationPoolName) {continue}
                $other=Get-ClcIisPhysicalRoot ([string]$directory.PhysicalPath) $clock
                if (($null -ne $selected.fileId -and $null -ne $other.fileId -and $selected.volumeId -ceq $other.volumeId -and $selected.fileId -ceq $other.fileId) -or
                    (Test-ClcPathAncestry $selected.physicalPath $other.physicalPath) -or (Test-ClcPathAncestry $other.physicalPath $selected.physicalPath)) {Stop-ClcError Clc.HostPreflightFailed}
            }
        }
    }
    Assert-ClcDeadline $clock 30
}


function Open-ClcIis {
    $path = Join-Path ([Clc.Foundation.NativePaths]::WindowsDirectory()) 'System32\inetsrv\Microsoft.Web.Administration.dll'
    $handles = [Collections.Generic.List[IDisposable]]::new()
    try {
        $null = Get-ClcPathObservation $path $handles -SystemFile
        $type = 'Microsoft.Web.Administration.ServerManager' -as [type]
        if ($null -eq $type) {
            Add-Type -LiteralPath $path
            $type = 'Microsoft.Web.Administration.ServerManager' -as [type]
        }
        if ($null -eq $type -or $type.Assembly.IsDynamic -or $type.Assembly.Location -ine $path) {
            Stop-ClcError Clc.IisUnavailable 'Load IIS management components from the native Windows IIS installation.'
        }
        return [Activator]::CreateInstance($type)
    } catch { Stop-ClcError Clc.IisUnavailable 'Install IIS and its management components and use an elevated x64 PowerShell session.' }
    finally { foreach ($handle in $handles) { $handle.Dispose() } }
}

function Get-ClcIisResources {
    param($Manager,$Target)
    if ($Manager.Sites.Count -gt 4096 -or $Manager.ApplicationPools.Count -gt 4096) {
        Stop-ClcError Clc.IisConflict 'The IIS inventory exceeds the supported inspection bound.'
    }
    return @{
        site=$Manager.Sites[$Target.siteName]
        pool=$Manager.ApplicationPools[$Target.applicationPoolName]
    }
}

function Assert-ClcIisOwnership {
    param($Manager,$Target,$Resources)
    $site=$Resources.site; $pool=$Resources.pool
    if ($null -eq $site -or $null -eq $pool -or $site.Applications.Count -ne 1) {
        Stop-ClcError Clc.IisConflict 'The recorded site and pool must exist with exactly one root application.'
    }
    $app=$site.Applications['/']
    if ($null -eq $app -or $app.ApplicationPoolName -ine $Target.applicationPoolName -or
        $app.VirtualDirectories.Count -ne 1 -or $app.VirtualDirectories['/'].PhysicalPath -ine $Target.applicationRoot) {
        Stop-ClcError Clc.IisConflict 'The recorded site must use the dedicated pool and canonical Application directory.'
    }
    $count=0
    foreach ($other in $Manager.Sites) {
        foreach ($entry in $other.Applications) {
            $count++
            if ($count -gt 4096 -or ($entry.ApplicationPoolName -ieq $pool.Name -and $other.Name -ine $site.Name)) {
                Stop-ClcError Clc.IisConflict 'Remove competing IIS applications from the dedicated pool through IIS Manager.'
            }
        }
    }
}

function Test-ClcIisPoolSettings {
    param($Pool)
    return $Pool.ManagedRuntimeVersion -ceq '' -and $Pool.ManagedPipelineMode.ToString() -ceq 'Integrated' -and
        -not $Pool.Enable32BitAppOnWin64 -and $Pool.ProcessModel.MaxProcesses -eq 1 -and
        $Pool.ProcessModel.LoadUserProfile -and $Pool.Recycling.DisallowOverlappingRotation
}

function Add-ClcIisResources {
    param($Manager,$Target)
    $resources=Get-ClcIisResources $Manager $Target
    if ($null -ne $resources.site -or $null -ne $resources.pool) {
        Stop-ClcError Clc.IisConflict 'An IIS site or pool with the requested name already exists.'
    }
    Assert-ClcIisPhysicalIsolation $Manager $Target -IncludeSelected
    $pool=$Manager.ApplicationPools.Add($Target.applicationPoolName)
    $pool.AutoStart=$false
    $pool.ManagedRuntimeVersion=''
    $pool.ManagedPipelineMode='Integrated'
    $pool.Enable32BitAppOnWin64=$false
    $pool.ProcessModel.MaxProcesses=1
    $pool.ProcessModel.LoadUserProfile=$true
    $pool.ProcessModel.IdentityType='ApplicationPoolIdentity'
    $pool.Recycling.DisallowOverlappingRotation=$true

    # The IIS site schema allows an omitted bindings collection. The typed
    # Add overloads require a binding, so add the site configuration element.
    $id=1L
    $used=[Collections.Generic.HashSet[long]]::new()
    foreach ($existing in $Manager.Sites) { $null=$used.Add([long]$existing.Id) }
    while ($used.Contains($id)) { $id++ }
    $sites=$Manager.GetApplicationHostConfiguration().GetSection('system.applicationHost/sites').GetCollection()
    $site=$sites.CreateElement('site')
    $site['name']=$Target.siteName
    $site['id']=$id
    $site['serverAutoStart']=$false
    # Clear inherited siteDefaults bindings before this element is committed.
    $site.GetCollection('bindings').Clear()
    $apps=$site.GetCollection()
    $app=$apps.CreateElement('application')
    $app['path']='/'
    $app['applicationPool']=$Target.applicationPoolName
    $directories=$app.GetCollection()
    $directory=$directories.CreateElement('virtualDirectory')
    $directory['path']='/'
    $directory['physicalPath']=$Target.applicationRoot
    $directories.Add($directory)
    $apps.Add($app)
    $sites.Add($site)
}
function Get-ClcIisState {
    param($Manager,$Resources)
    $workers=0; $observed=0
    foreach ($worker in $Manager.WorkerProcesses) {
        if (++$observed -gt 4096) { Stop-ClcError Clc.IisStateUnknown 'IIS worker inventory exceeded the inspection bound.' }
        if ($worker.AppPoolName -ieq $Resources.pool.Name) { $workers++ }
    }
    return @{siteState=$Resources.site.State.ToString();poolState=$Resources.pool.State.ToString();workerCount=$workers;
        siteAutoStart=[bool]$Resources.site.ServerAutoStart;poolAutoStart=[bool]$Resources.pool.AutoStart}
}

function ConvertTo-ClcBindingHostname {
    param([string] $Name)
    # Canonical ASCII DNS labels make comparison independent of casing and IDN spelling.
    if (-not $Name -or $Name.Length -gt 254) { return }
    try { $dns=[Globalization.IdnMapping]::new().GetAscii($Name).ToLowerInvariant() } catch { return }
    if ($dns.EndsWith('.')) { $dns=$dns.Substring(0,$dns.Length-1) }
    if ($dns.Length -gt 253 -or $dns -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*$' -or
        [uri]::CheckHostName($dns) -ne 'Dns') { return }
    return $dns
}

function Test-ClcCertificateIdentity {
    param([Security.Cryptography.X509Certificates.X509Certificate2] $Certificate,[string] $Hostname)
    $now=[DateTime]::Now
    return $Certificate.HasPrivateKey -and $Certificate.NotBefore -le $now -and $Certificate.NotAfter -gt $now -and
        $Certificate.MatchesHostname($Hostname,$true,$false)
}

function Test-ClcBindingTrust {
    param([Security.Cryptography.X509Certificates.X509Certificate2] $Certificate,
        [Security.Cryptography.X509Certificates.X509Chain] $Chain)
    # Read-only preflight uses local trust and cached revocation data. Each HTTPS
    # request independently performs the platform's online TLS checks.
    $policy=$Chain.ChainPolicy
    $policy.DisableCertificateDownloads=$true
    $policy.RevocationMode='Offline'
    $policy.VerificationFlags='IgnoreEndRevocationUnknown, IgnoreCertificateAuthorityRevocationUnknown, IgnoreRootRevocationUnknown'
    $null=$policy.ApplicationPolicy.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.1'))
    return $Chain.Build($Certificate)
}

function Test-ClcBindingCertificate {
    param($Binding,[string] $Hostname)
    $inventory=$null; $certificates=$null
    $store=[Security.Cryptography.X509Certificates.X509Store]::new($Binding.CertificateStoreName,'LocalMachine')
    try {
        $store.Open('ReadOnly, OpenExistingOnly')
        $inventory=$store.Certificates
        $certificates=$inventory.Find('FindByThumbprint',[Convert]::ToHexString($Binding.CertificateHash),$false)
        if ($certificates.Count -ne 1 -or -not (Test-ClcCertificateIdentity $certificates[0] $Hostname)) { return $false }
        $chain=[Security.Cryptography.X509Certificates.X509Chain]::new($true)
        try { return Test-ClcBindingTrust $certificates[0] $chain }
        finally { $chain.Dispose() }
    } catch { return $false }
    finally {
        foreach ($certificate in $certificates) { $certificate.Dispose() }
        foreach ($certificate in $inventory) { $certificate.Dispose() }
        $store.Dispose()
    }
}

function Get-ClcIisBindingSnapshot {
    param($Manager,$Site)
    $count=$Site.Bindings.Count
    $result=@{configured=$count;valid=0;endpoints=@();signature='';findings=@()}
    $messages=[Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    $entries=[Collections.Generic.List[object]]::new()
    $clock=[Diagnostics.Stopwatch]::StartNew()
    try {
        if ($count -lt 1 -or $count -gt 16 -or $Manager.Sites.Count -gt 4096) {
            throw 'Binding inspection limit.'
        }
        foreach ($binding in $Site.Bindings) {
            Assert-ClcDeadline $clock 30
            $name=ConvertTo-ClcBindingHostname $binding.Host
            if ($binding.Protocol -cne 'https' -or -not $name -or $binding.EndPoint -isnot [Net.IPEndPoint] -or
                $binding.EndPoint.Port -lt 1 -or [int]$binding.SslFlags -notin @(0,1)) {
                $null=$messages.Add('Use HTTPS with an explicit DNS hostname, port and local certificate, with optional SNI.')
                continue
            }
            $port=$binding.EndPoint.Port
            $address=$binding.EndPoint.Address
            if ($address.IsIPv4MappedToIPv6) { $address=$address.MapToIPv4() }
            $uri=[UriBuilder]::new('https',$name,$port,'/health/ready').Uri.AbsoluteUri
            $thumbprint=if ($null -ne $binding.CertificateHash) { [Convert]::ToHexString($binding.CertificateHash) }
            $valid=$binding.CertificateStoreName -match '^[a-z0-9]+$' -and $thumbprint -and
                (Test-ClcBindingCertificate $binding $name)
            if (-not $valid) { $null=$messages.Add('Verify every binding has a trusted server certificate and private key in LocalMachine. Check the hostname, dates and installed chain.') }
            $signature="$uri|$address|$([int]$binding.SslFlags)|$($binding.CertificateStoreName)|$thumbprint"
            $entries.Add(@{name=$name;port=$port;address=$address;sni=([int]$binding.SslFlags -eq 1);uri=$uri;signature=$signature;valid=$valid})
        }
        # Compare host routing even across disjoint addresses because DNS selects the address.
        # On overlapping listeners require distinct SNI names for TLS isolation.
        $inspected=0
        foreach ($other in $Manager.Sites) {
            Assert-ClcDeadline $clock 30
            foreach ($binding in $other.Bindings) {
                if (++$inspected -gt 4096) { throw 'Binding inspection limit.' }
                if ($binding.Protocol -cnotin @('https','http')) { continue }
                $sameSite=$other.Name -ieq $Site.Name
                $name=ConvertTo-ClcBindingHostname $binding.Host
                $wildcardSuffix=if ($binding.Host -and $binding.Host.StartsWith('*.')) { ConvertTo-ClcBindingHostname $binding.Host.Substring(2) }
                $address=$binding.EndPoint.Address
                if ($address.IsIPv4MappedToIPv6) { $address=$address.MapToIPv4() }
                $port=$binding.EndPoint.Port
                foreach ($entry in $entries) {
                    if ($entry.port -ne $port) { continue }
                    $sameHost=$entry.name -ceq $name
                    $overlap=$address.Equals($entry.address) -or $address.ToString() -in @('0.0.0.0','::') -or $entry.address.ToString() -in @('0.0.0.0','::')
                    if ($sameSite -and $sameHost -and $address.Equals($entry.address) -and $binding.Protocol -ceq 'https') { continue }
                    $matchesRoute=$sameHost -or (-not $name -and -not $wildcardSuffix) -or
                        ($wildcardSuffix -and $entry.name.EndsWith('.'+$wildcardSuffix,[StringComparison]::Ordinal))
                    $sharesTlsListener=$overlap -and (-not $name -or -not $entry.sni -or $binding.Protocol -cne 'https' -or [int]$binding.SslFlags -ne 1)
                    if (($matchesRoute -and $binding.Protocol -ceq 'https') -or $sharesTlsListener) {
                        $entry.valid=$false
                        $null=$messages.Add('Remove competing host or port bindings and use distinct SNI names on shared listeners.')
                    }
                }
            }
        }
        $uris=[Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
        $signatures=[Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
        foreach ($entry in $entries) {
            if (-not $uris.Add($entry.uri)) { $null=$messages.Add('Remove duplicate hostname and port definitions.') }
            $null=$signatures.Add($entry.signature)
        }
        foreach ($group in ($entries | Group-Object -Property { $_.uri })) {
            if ($group.Count -eq 1 -and $group.Group[0].valid) { $result.valid++ }
        }
        $result.endpoints=@($uris)
        $result.signature=$signatures -join "`n"
        Assert-ClcDeadline $clock 30
    } catch {
        $null=$messages.Add('Configure 1 to 16 dedicated HTTPS bindings and verify the local IIS binding and certificate inventory can be inspected.')
    }
    $result.findings=@(foreach ($message in $messages) { @{code='Clc.HttpsBinding';message=$message} })
    return $result
}

function Invoke-ClcIisChange {
    param($HostContext,[ValidateSet('DisableStartup','EnableStartup','StopSite','StopPool','StartPool','StartSite')][string] $Operation)
    $manager=Open-ClcIis
    try {
        $target=$HostContext.target
        $resources=Get-ClcIisResources $manager $target
        Assert-ClcIisOwnership $manager $target $resources
        if ($resources.site.Id -ne $HostContext.siteId) { Stop-ClcError Clc.IisConflict 'The recorded IIS site ID changed during the attempt.' }
        $clock=[Diagnostics.Stopwatch]::StartNew()
        switch ($Operation) {
            DisableStartup {
                $resources.site.ServerAutoStart=$false
                $resources.pool.AutoStart=$false
                $manager.CommitChanges()
            }
            EnableStartup {
                $resources.site.ServerAutoStart=$true
                $resources.pool.AutoStart=$true
                $manager.CommitChanges()
            }
            StopSite { if ($resources.site.State.ToString() -ne 'Stopped') { $null=$resources.site.Stop() } }
            StopPool { if ($resources.pool.State.ToString() -ne 'Stopped') { $null=$resources.pool.Stop() } }
            StartPool { if ($resources.pool.State.ToString() -ne 'Started') { $null=$resources.pool.Start() } }
            StartSite { if ($resources.site.State.ToString() -ne 'Started') { $null=$resources.site.Start() } }
        }
        Assert-ClcDeadline $clock 60
    } finally { $manager.Dispose() }
}

function Get-ClcLiveIisState {
    param($HostContext)
    $manager=Open-ClcIis
    try {
        $resources=Get-ClcIisResources $manager $HostContext.target
        Assert-ClcIisOwnership $manager $HostContext.target $resources
        if ($resources.site.Id -ne $HostContext.siteId) { Stop-ClcError Clc.IisConflict 'The recorded IIS site ID changed.' }
        return Get-ClcIisState $manager $resources
    } finally { $manager.Dispose() }
}

function Wait-ClcIisState {
    param($HostContext,[ValidateSet('Stopped','Started')][string] $State)
    $clock=[Diagnostics.Stopwatch]::StartNew()
    do {
        $iis=Get-ClcLiveIisState $HostContext
        if ($clock.Elapsed.TotalSeconds -lt 60 -and $iis.siteState -ceq $State -and $iis.poolState -ceq $State -and
            $iis.workerCount -le 1 -and ($State -ceq 'Started' -or $iis.workerCount -eq 0)) { return $iis }
        Start-Sleep -Milliseconds 500
    } while ($clock.Elapsed.TotalSeconds -lt 60)
    Stop-ClcError Clc.IisStateUnknown 'Could not verify the requested site, pool and worker state within 60 seconds. Inspect IIS before recovery.'
}


function Test-ClcIisEnvironment {
    param($Manager,$Resources,[string] $Environment,[switch] $SkipApplicationConfiguration)
    $seen=0
    $values=[Collections.Generic.List[object]]::new()
    $machine=[Environment]::GetEnvironmentVariables('Machine')
    foreach ($key in $machine.Keys) {
        if ($key -imatch '^(DOTNET_|ASPNETCORE_|COMPlus_|CORECLR_)') { $values.Add(@{name=$key;value=$machine[$key]}) }
    }
    foreach ($element in $Resources.pool.GetCollection('environmentVariables')) {
        $values.Add(@{name=$element['name'];value=$element['value']})
    }
    # Observe effective application-level selectors only once a web.config exists.
    $root=$Resources.site.Applications['/'].VirtualDirectories['/'].PhysicalPath
    $webConfig=Join-Path $root 'web.config'
    if (-not $SkipApplicationConfiguration -and (Test-ClcStorageEntry $webConfig)) {
        Assert-ClcStoragePath $webConfig
        $config=$Manager.GetWebConfiguration($Resources.site.Name)
        $ancm=$config.GetSection('system.webServer/aspNetCore')
        if ($ancm['hostingModel'].ToString() -ine 'inprocess') { return $false }
        foreach ($element in $ancm.GetCollection('environmentVariables')) {
            $values.Add(@{name=$element['name'];value=$element['value']})
        }
    }
    foreach ($entry in $values) {
        if ($entry.name -iin @('ASPNETCORE_ENVIRONMENT','DOTNET_ENVIRONMENT')) {
            $seen++
            if ($entry.value -cne $Environment) { return $false }
        } elseif ($entry.name -imatch '^(DOTNET_|ASPNETCORE_|COMPlus_|CORECLR_)') { return $false }
    }
    return $seen -gt 0 -or $Environment -ceq 'Production'
}

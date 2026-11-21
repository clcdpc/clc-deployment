
$script:ClcAdministrators = @('S-1-5-18','S-1-5-32-544')
$script:ClcHostDirectories = @('Application','Config','Keys','Logs','Inbox','Deployment')

function Get-ClcHostLayout {
    param([string] $ApplicationId)
    Assert-ClcId $ApplicationId
    $programData=Get-ClcProgramDataRoot
    $root=[IO.Path]::Combine($programData,('clc-'+$ApplicationId))
    Assert-ClcPathSpelling $root
    $deployment=[IO.Path]::Combine($root,'Deployment')
    return @{root=$root;programData=$programData;deployment=$deployment;application=([IO.Path]::Combine($root,'Application'));
        config=([IO.Path]::Combine($root,'Config\application.json'));keys=([IO.Path]::Combine($root,'Keys'));logs=([IO.Path]::Combine($root,'Logs'));
        inbox=([IO.Path]::Combine($root,'Inbox'));hostRecord=([IO.Path]::Combine($deployment,'host.json'));state=([IO.Path]::Combine($deployment,'state.json'));
        lock=([IO.Path]::Combine($deployment,'deployment.lock'))}
}

function Get-ClcPlatformObservation {
    $os=Get-CimInstance -ClassName Win32_OperatingSystem -Property BuildNumber,ProductType -OperationTimeoutSec 10
    return @{build=[string]$os.BuildNumber;productType=[int]$os.ProductType;
        architecture=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString();powershell=$PSVersionTable.PSVersion}
}

function Assert-ClcPlatform {
    if (-not $IsWindows) { Stop-ClcError Clc.PlatformUnsupported 'Use x64 Windows Server 2022.' }
    $platform=Get-ClcPlatformObservation
    $version=$platform.powershell
    if ($platform.build -cne '20348' -or $platform.productType -ne 3 -or $platform.architecture -cne 'X64' -or
        $version.Major -ne 7 -or $version.PreReleaseLabel -or $version -lt [semver]'7.6.6') {
        Stop-ClcError Clc.PlatformUnsupported 'Use x64 Windows Server 2022 and stable x64 PowerShell 7.6.6 or later within 7.x.'
    }
    if (-not (Test-ClcAdministratorToken)) {
        Stop-ClcError Clc.InsufficientAccess 'Run under an enabled elevated local Administrators token.'
    }
}
function Get-ClcFileX64 {
    param([string] $Path,$Handles)
    $file=Read-ClcHeldFile $Path $Handles 268435456 -SystemFile -NoCapture
    $stream=$file.stream; $header=[byte[]]::new(64); $stream.ReadExactly($header)
    if ($header[0] -ne 0x4d -or $header[1] -ne 0x5a) { Stop-ClcError Clc.HostPreflightFailed }
    $offset=[BitConverter]::ToInt32($header,60)
    if ($offset -lt 64 -or $offset -gt $stream.Length-6) { Stop-ClcError Clc.HostPreflightFailed }
    $stream.Position=$offset; $pe=[byte[]]::new(6); $stream.ReadExactly($pe)
    return [BitConverter]::ToUInt32($pe,0) -eq 0x00004550 -and [BitConverter]::ToUInt16($pe,4) -eq 0x8664
}


function Get-ClcHostingRuntime {
    param($Manager)
    $programFiles=[Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
    $dotnet=Join-Path $programFiles 'dotnet\dotnet.exe'
    $handles=[Collections.Generic.List[IDisposable]]::new()
    try {
        $modules=@($Manager.GetApplicationHostConfiguration().GetSection('system.webServer/globalModules').GetCollection() |
            Where-Object { $_['name'] -ceq 'AspNetCoreModuleV2' })
        if ($modules.Count -ne 1) { throw 'Missing ANCM.' }
        $ancm=([string]$modules[0]['image']).Replace('%ProgramFiles%',$programFiles,[StringComparison]::OrdinalIgnoreCase).
            Replace('%windir%',[Clc.Foundation.NativePaths]::WindowsDirectory(),[StringComparison]::OrdinalIgnoreCase)
        if (-not (Get-ClcFileX64 $dotnet $handles) -or -not (Get-ClcFileX64 $ancm $handles)) { throw 'Non-x64 hosting runtime.' }
        $aspnetVersion=[Diagnostics.FileVersionInfo]::GetVersionInfo($ancm)
        # The .NET 10 Hosting Bundle registers ANCM V2 file version 20.x.
        if ($aspnetVersion.FileMajorPart -ne 20) { throw 'Unsupported ANCM.' }
        $bytes=[Clc.Host.Native]::ListRuntimes($dotnet)
        $list=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)
        foreach ($framework in @('Microsoft.NETCore.App','Microsoft.AspNetCore.App')) {
            if ($list -cnotmatch ('(?m)^'+[regex]::Escape($framework)+' 10\.0\.[0-9]+ \[')) { throw 'Missing stable runtime.' }
        }
        return $dotnet
    } catch { Stop-ClcError Clc.HostingUnavailable 'Install or repair the x64 .NET 10 Hosting Bundle, ASP.NET Core runtime and registered ANCM V2.' }
    finally { foreach ($handle in $handles) { $handle.Dispose() } }
}

function Test-ClcStorageEntry {
    param([string] $Path)
    Assert-ClcPathSpelling $Path
    $handle=[Clc.Foundation.NativePaths]::OpenExistingOrNull($Path)
    if ($null -eq $handle) { return $false }
    $handle.Dispose()
    return $true
}
function Assert-ClcStoragePath {
    param([string] $Path,[switch] $Directory,[switch] $SystemPath)
    $handles=[Collections.Generic.List[IDisposable]]::new()
    try { $null=Get-ClcPathObservation $Path $handles -Directory:$Directory -AllowVolumeRoot:$SystemPath -SystemFile:($SystemPath -and -not $Directory) }
    finally { foreach ($handle in $handles) { $handle.Dispose() } }
}
function Assert-ClcInitializationAccess {
    param($Layout)
    Assert-ClcStoragePath $Layout.programData -Directory -SystemPath
    $security=Get-ClcSecurityObservation $Layout.programData
    if (((Get-ClcEffectiveAccess $security.bytes (Get-ClcCallerSid)) -band 4) -eq 0) {
        Stop-ClcError Clc.InsufficientAccess 'The deployment administrator needs permission to create a directory in native ProgramData.'
    }
    $iisConfig=Join-Path ([Clc.Foundation.NativePaths]::WindowsDirectory()) 'System32\inetsrv\config\applicationHost.config'
    Assert-ClcStoragePath $iisConfig -SystemPath
    $security=Get-ClcSecurityObservation $iisConfig
    if (((Get-ClcEffectiveAccess $security.bytes (Get-ClcCallerSid)) -band 2) -eq 0) {
        Stop-ClcError Clc.InsufficientAccess 'The deployment administrator needs write access to local IIS configuration.'
    }
}

function New-ClcHostDirectory {
    param([string] $Path)
    if (Test-ClcStorageEntry $Path) { Stop-ClcError Clc.ExistingResources 'A scaffold directory already exists. Inspect the partial or unrelated installation.' }
    $acl=[Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true,$false)
    $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    foreach ($id in $script:ClcAdministrators) {
        $rule=[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($id),
            'FullControl','ContainerInherit, ObjectInherit','None','Allow')
        $acl.AddAccessRule($rule)
    }
    [IO.FileSystemAclExtensions]::Create([IO.DirectoryInfo]::new($Path),$acl)
    Assert-ClcStoragePath $Path -Directory
    $null=Assert-ClcAccess $Path $script:ClcAdministrators $script:ClcAdministrators @()
}

function Resolve-ClcRuntimeSid {
    param([string] $Account)
    try {
        return [Security.Principal.NTAccount]::new($Account).Translate([Security.Principal.SecurityIdentifier]).Value
    } catch { Stop-ClcError Clc.RuntimeIdentity 'Set the dedicated pool to the expected specific service account and verify directory or local account resolution.' }
}

function Assert-ClcRuntimeIdentity {
    param([string] $RuntimeSid)
    $privileged=$script:ClcAdministrators+@((Get-ClcCallerSid),'S-1-5-19','S-1-5-20')
    if ($RuntimeSid -cin $privileged -or $RuntimeSid -like 'S-1-5-82-*') {
        Stop-ClcError Clc.RuntimeIdentity 'Configure a distinct nonadministrator service account for the application pool.'
    }
    $aces=($privileged | Select-Object -Unique | ForEach-Object {'(A;;0x1;;;'+$_+')'}) -join ''
    $descriptor=[Security.AccessControl.RawSecurityDescriptor]::new(('O:SYG:SYD:'+$aces))
    $bytes=[byte[]]::new($descriptor.BinaryLength)
    $descriptor.GetBinaryForm($bytes,0)
    if ((Get-ClcEffectiveAccess $bytes $RuntimeSid) -ne 0) {
        Stop-ClcError Clc.RuntimeIdentity 'Remove the runtime account from local Administrators, including indirect membership.'
    }
}

function Assert-ClcRuntimeAccess {
    param([string] $Path,[string] $RuntimeSid,[ValidateSet('Protected','Read','Write')][string] $Role)
    $writers=$script:ClcAdministrators
    $owners=$writers
    $readers=@()
    $denied=@($RuntimeSid)
    if ($Role -cne 'Protected') { $readers=@($RuntimeSid) }
    if ($Role -ceq 'Write') { $writers+=@($RuntimeSid,'S-1-3-0'); $owners+=@($RuntimeSid); $denied=@() }
    $null=Assert-ClcAccess $Path $owners $writers $readers $denied -ReadMask 0x1200A9
    if ($Role -ceq 'Write') {
        $mask=Get-ClcEffectiveAccess (Get-ClcSecurityObservation $Path).bytes $RuntimeSid
        if (($mask -band 0x1301bf) -ne 0x1301bf) { Stop-ClcError Clc.RuntimeAccess 'Grant the runtime account inherited Modify access for Keys and Logs.' }
    }
}

function Assert-ClcApplicationAcl {
    param([string] $Path,[string] $RuntimeSid)
    Assert-ClcRuntimeAccess $Path $RuntimeSid Read
    $acl=Get-Acl -LiteralPath $Path
    # Files and directories created by the runner must inherit runtime read/execute.
    $flags=[Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $account=[Security.Principal.SecurityIdentifier]::new($RuntimeSid)
    $rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]) | Where-Object {
        $_.IdentityReference -eq $account -and $_.AccessControlType -eq 'Allow' -and
        ($_.InheritanceFlags -band $flags) -eq $flags -and $_.PropagationFlags -eq 'None' -and
        ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::ReadAndExecute) -eq [Security.AccessControl.FileSystemRights]::ReadAndExecute
    })
    if ($rules.Count -eq 0) { Stop-ClcError Clc.RuntimeAccess 'Grant the service account inherited Read and Execute on Application.' }
}

function Assert-ClcSafeDescendants {
    param([string] $Root,[string] $ConfigRuntimeSid,[Diagnostics.Stopwatch] $Clock=$null)
    if ($null -eq $Clock) { $Clock=[Diagnostics.Stopwatch]::StartNew() }
    $directoryHandles=[Collections.Generic.List[IDisposable]]::new()
    try {
        $rootFacts=Get-ClcPathObservation $Root $directoryHandles -Directory
        $queue=[Collections.Generic.Queue[object]]::new(); $queue.Enqueue($rootFacts)
        $count=0
        $aclCache=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        while ($queue.Count -gt 0) {
            $parent=$queue.Dequeue()
            foreach ($path in [IO.Directory]::EnumerateFileSystemEntries($parent.CanonicalPath)) {
                Assert-ClcDeadline $Clock; $count++; if ($count -gt 20000) { Stop-ClcError Clc.UnsafePath }
                $directory=([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::Directory) -ne 0
                $handles=[Collections.Generic.List[IDisposable]]::new()
                try {
                    $facts=Get-ClcChildPathObservation $path $parent $handles -Directory:$directory
                    if ($ConfigRuntimeSid) {
                        $null=Assert-ClcAccess $path $script:ClcAdministrators $script:ClcAdministrators @() @($ConfigRuntimeSid) -Cache $aclCache
                    }
                    if ($directory) { $queue.Enqueue($facts); foreach ($handle in $handles) { $directoryHandles.Add($handle) }; $handles.Clear() }
                } finally { foreach ($handle in $handles) { $handle.Dispose() } }
            }
        }
        Assert-ClcDeadline $Clock
    } finally { foreach ($handle in $directoryHandles) { $handle.Dispose() } }
}

function Assert-ClcHostDirectoryAccess {
    param($Layout,[string] $RuntimeSid)
    foreach ($path in @($Layout.root,$Layout.deployment,$Layout.inbox)) {
        Assert-ClcRuntimeAccess $path $RuntimeSid Protected
    }
    Assert-ClcApplicationAcl $Layout.application $RuntimeSid
    foreach ($path in @((Join-Path $Layout.root 'Config'),$Layout.config)) {
        Assert-ClcRuntimeAccess $path $RuntimeSid Read
    }
    foreach ($path in @($Layout.keys,$Layout.logs)) { Assert-ClcRuntimeAccess $path $RuntimeSid Write }
    Assert-ClcSafeDescendants (Join-Path $Layout.root 'Config') -ConfigRuntimeSid $RuntimeSid
    Assert-ClcSafeDescendants $Layout.keys
    $cursor=$Layout.programData
    while ($cursor) {
        $acl=Get-ClcSecurityObservation $cursor
        if (((Get-ClcEffectiveAccess $acl.bytes $RuntimeSid) -band 0x000D0040) -ne 0 -or $acl.ownerSid -ceq $RuntimeSid) {
            Stop-ClcError Clc.RuntimeAccess 'Remove runtime delete-child or security-control access on ProgramData and its ancestors.'
        }
        $cursor=[IO.Path]::GetDirectoryName($cursor)
    }
}

function Open-ClcHostContext {
    param([string] $ApplicationId,[string] $TargetId,[string] $ExpectedRuntimeAccount,[string] $RuntimeEnvironment,
        [switch] $Recovery)
    Assert-ClcId $TargetId
    Assert-ClcPlatform
    $layout=Get-ClcHostLayout $ApplicationId
    $manager=Open-ClcIis
    try {
        if (-not (Test-ClcStorageEntry $layout.root)) { Stop-ClcError Clc.NotInitialized 'Run initialization Preview to check for existing IIS resources before scaffolding.' }
        Assert-ClcStoragePath $layout.root -Directory
        if (-not (Test-ClcStorageEntry $layout.hostRecord)) { Stop-ClcError Clc.ExistingResources 'The application root exists without a completed host record. Inspect the partial or existing resources.' }
        foreach ($name in $script:ClcHostDirectories) { Assert-ClcStoragePath (Join-Path $layout.root $name) -Directory }
        $target=Read-ClcLocalRecord $layout.hostRecord host
        if ($target.applicationId -cne $ApplicationId -or $target.targetId -cne $TargetId -or $target.applicationRoot -ine $layout.application) {
            Stop-ClcError Clc.TargetMismatch 'Select the application and deployment target recorded by initialization.'
        }
        $resources=Get-ClcIisResources $manager $target
        Assert-ClcIisOwnership $manager $target $resources
        Assert-ClcIisPhysicalIsolation $manager $target
        if ($resources.site.Id -ne $target.siteId -or -not (Test-ClcIisPoolSettings $resources.pool)) {
            Stop-ClcError Clc.IisSettings 'Verify the recorded IIS site and standard dedicated one-worker pool settings.'
        }

        $state=Read-ClcLocalRecord $layout.state state
        if ($null -ne $state.pending -and -not $Recovery) {
            Assert-ClcHostState @{target=$target;state=$state;iis=$null}
        }
        $runtime=Get-ClcHostingRuntime $manager
        $findings=[Collections.Generic.List[object]]::new()
        $sid=$null
        try {
            if ($resources.pool.ProcessModel.IdentityType.ToString() -cne 'SpecificUser') { Stop-ClcError Clc.RuntimeIdentity 'Configure the expected service account on the dedicated pool in IIS Manager.' }
            $sid=Resolve-ClcRuntimeSid $ExpectedRuntimeAccount
            if ((Resolve-ClcRuntimeSid $resources.pool.ProcessModel.UserName) -cne $sid) { Stop-ClcError Clc.RuntimeIdentity 'The pool identity must resolve to the expected service account.' }
            Assert-ClcRuntimeIdentity $sid
        } catch { $findings.Add(@{code='Clc.RuntimeIdentity';message='Configure the expected distinct nonadministrator service account in IIS Manager and verify account resolution.'}); $sid=$null }
        $bindings=Get-ClcIisBindingSnapshot $manager $resources.site
        foreach ($finding in $bindings.findings) { $findings.Add($finding) }
        if (-not (Test-ClcStorageEntry $layout.config)) {
            $findings.Add(@{code='Clc.ConfigurationMissing';message='Provision Config\application.json and the application dependencies before deployment.'})
        } else {

            Assert-ClcStoragePath $layout.config
            $configurationInfo=[IO.FileInfo]::new($layout.config)
            if ($configurationInfo.Length -le 0 -or $configurationInfo.Length -gt 4194304) {
                $findings.Add(@{code='Clc.ConfigurationInvalid';message='Provision a nonempty external configuration file of at most 4 MiB.'})
            }
            if ($null -ne $sid) {
                try { Assert-ClcHostDirectoryAccess $layout $sid }
                catch { $findings.Add(@{code='Clc.RuntimeAccess';message='Verify inherited runtime Read and Execute on Application and Config, Modify on Keys and Logs, and write isolation for the remaining directories.'}) }
            }
        }

        if (-not (Test-ClcIisEnvironment $manager $resources $RuntimeEnvironment -SkipApplicationConfiguration:$Recovery)) {
            $findings.Add(@{code='Clc.IisEnvironment';message='Set the expected ASP.NET Core environment on the dedicated pool. Remove conflicting .NET environment overrides.'})
        }
        $iis=Get-ClcIisState $manager $resources
        $context=@{bindings=$bindings;readiness=$null;target=$target;layout=$layout;siteId=$target.siteId;runtimeSid=$sid;dotnet=$runtime;environment=$RuntimeEnvironment;
            ignoreLiveWebConfig=[bool]$Recovery;iis=$iis;state=$state;findings=$findings.ToArray()}
        Assert-ClcHostState $context -Recovery:$Recovery
        return $context
    } finally { $manager.Dispose() }
}

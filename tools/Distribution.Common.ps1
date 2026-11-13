# Independently review this verifier and its source revision BEFORE using it to
# establish first-import trust. Nothing in an archive authenticates itself.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DistHash {
    param([byte[]] $Bytes)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}
$script:DistVersionPattern = '\A(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*)?\z'
function Assert-DistVersion([object] $Version) {
    if ($Version -isnot [string] -or $Version.Length -gt 128 -or $Version -cnotmatch $script:DistVersionPattern) {
        throw 'Invalid shared release version.'
    }
    $coreVersion=$Version.Split('-')[0]
    $parsedVersion=$null
    if (-not [version]::TryParse($coreVersion,[ref]$parsedVersion)) { throw 'Invalid shared release version.' }
}
function Get-DistVersionFromBytes([byte[]] $Bytes) {
    $value = [Text.UTF8Encoding]::new($false,$true).GetString($Bytes)
    $crlf = [string]::Concat([char]13,[char]10)
    if ($value.EndsWith($crlf,[StringComparison]::Ordinal)) { $value = $value.Substring(0,$value.Length-2) }
    elseif ($value.EndsWith([string][char]10,[StringComparison]::Ordinal)) { $value = $value.Substring(0,$value.Length-1) }
    if ($value.Contains([char]13) -or $value.Contains([char]10)) { throw 'Shared VERSION must contain one version line.' }
    Assert-DistVersion $value
    return $value
}
function Assert-DistReleaseTag([string] $Tag,[string] $Version) {
    Assert-DistVersion $Version
    if ($Tag -cne ('v'+$Version)) { throw 'Release tag does not match the shared repository version.' }
}
function Get-DistModuleVersion([string] $ManifestText) {
    if ($ManifestText -isnot [string]) { throw 'Module manifest text is invalid.' }
    $baseMatches=[regex]::Matches($ManifestText,"(?m)^\s*ModuleVersion\s*=\s*'([^']+)'")
    $prereleaseAssignments=[regex]::Matches($ManifestText,'\bPrerelease\s*=')
    $prereleaseMatches=[regex]::Matches($ManifestText,"\bPrerelease\s*=\s*'([^']*)'")
    if ($baseMatches.Count -ne 1 -or $prereleaseAssignments.Count -gt 1 -or $prereleaseMatches.Count -ne $prereleaseAssignments.Count) {
        throw 'Module manifest version metadata is invalid.'
    }
    $version=$baseMatches[0].Groups[1].Value
    if ($prereleaseMatches.Count -eq 1) { $version += '-'+$prereleaseMatches[0].Groups[1].Value }
    Assert-DistVersion $version
    return $version
}

function Get-DistVersionedManifestBytes([byte[]] $SourceBytes,[string] $Version) {
    Assert-DistVersion $Version
    if ($SourceBytes.Length -gt 65536) { throw 'Source module manifest exceeds its bound.' }
    $text=[Text.UTF8Encoding]::new($false,$true).GetString($SourceBytes)
    $null=Get-DistModuleVersion $text
    $dash=$Version.IndexOf('-')
    $core=if ($dash -ge 0) { $Version.Substring(0,$dash) } else { $Version }
    $prerelease=if ($dash -ge 0) { $Version.Substring($dash+1) } else { $null }
    $basePattern=[regex]::new("(?m)(^\s*ModuleVersion\s*=\s*)'[^']+'")
    $text=$basePattern.Replace($text,('$1'''+$core+''''),1)
    $prePattern=[regex]::new("\bPrerelease\s*=\s*'[^']*'\s*;?")
    if ($null -eq $prerelease) {
        $text=$prePattern.Replace($text,'',1)
    } elseif ($prePattern.IsMatch($text)) {
        $text=$prePattern.Replace($text,("Prerelease = '$prerelease';"),1)
    } else {
        $psDataPattern=[regex]::new('\bPSData\s*=\s*@\{')
        if ($psDataPattern.Matches($text).Count -ne 1) { throw 'Source module manifest requires exactly one PSData table for version generation.' }
        $text=$psDataPattern.Replace($text,("PSData = @{ Prerelease = '$prerelease';"),1)
    }
    if ((Get-DistModuleVersion $text) -cne $Version) { throw 'Generated module version differs.' }
    return ,([Text.UTF8Encoding]::new($false).GetBytes($text))
}

function Get-DistInfrastructureNames {
    @('tools/Distribution.Common.ps1','tools/Expand-ToolkitDistribution.ps1','tools/Test-ToolkitDistribution.ps1',
        'tools/host/Get-ClcHostEnrollment.ps1','tools/host/Initialize-ClcHostEnrollment.ps1','tools/host/HostEnrollment.Common.ps1',
        'tools/host/HostEnrollment.Iis.ps1','tools/host/HostEnrollment.Resources.ps1')
}
function Read-DistJson {
    param([byte[]] $Bytes)
    if ($Bytes.Length -gt 4194304) { throw 'Distribution JSON exceeds its bound.' }
    $document=[Text.Json.JsonDocument]::Parse([ReadOnlyMemory[byte]]$Bytes)
    function Test-DistElement($Element, [int] $Depth=0) {
        if ($Depth -gt 32) { throw 'Distribution JSON nesting exceeds its bound.' }
        if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
            $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($property in $Element.EnumerateObject()) {
                if (-not $seen.Add($property.Name)) { throw 'Duplicate JSON property.' }
                Test-DistElement $property.Value ($Depth+1)
            }
        } elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
            foreach ($elementValue in $Element.EnumerateArray()) { Test-DistElement $elementValue ($Depth+1) }
        }
    }
    try { Test-DistElement $document.RootElement }
    finally { $document.Dispose() }
    [Text.UTF8Encoding]::new($false,$true).GetString($Bytes) | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
}
function Read-DistFileBytes([string] $Path,[long] $Limit=4194304) {
    $stream=[IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        if ($stream.Length -gt $Limit -or $stream.Length -gt [int]::MaxValue) { throw 'File exceeds its bounded capture size.' }
        $bytes=[byte[]]::new([int]$stream.Length); $stream.ReadExactly($bytes); return ,$bytes
    } finally { $stream.Dispose() }
}
function Assert-DistFields($Value, [string[]] $Names) {
    if ($Value -isnot [Collections.IDictionary] -or $Value.Count -ne $Names.Count) { throw 'Unexpected distribution shape.' }
    foreach ($name in $Names) { if (@($Value.Keys) -cnotcontains $name) { throw 'Unexpected distribution shape.' } }
}
function Assert-DistName([string] $Name) {
    if ($Name.Length -gt 240 -or $Name -cnotmatch '^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$') { throw 'Unsafe distribution name.' }
    foreach ($part in $Name.Split('/')) {
        if ($part -in @('.','..') -or $part.EndsWith('.') -or $part -imatch '^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(\.|$)') { throw 'Unsafe distribution component.' }
    }
}
function Get-DistInventoryHash([object[]] $Files) {
    $names=[string[]]@($Files | ForEach-Object { $_.path }); [Array]::Sort($names,[StringComparer]::Ordinal)
    $byName=@{}; foreach ($file in $Files) { $byName[$file.path]=$file }
    $text=[Text.StringBuilder]::new()
    foreach ($name in $names) {
        $file=$byName[$name]
        [void]$text.Append($name).Append([char]0).Append(([long]$file.length).ToString([Globalization.CultureInfo]::InvariantCulture)).Append([char]0).Append($file.sha256).Append("`n")
    }
    Get-DistHash ([Text.Encoding]::UTF8.GetBytes($text.ToString()))
}
function Assert-DistInventory([object[]] $Files) {
    if ($Files.Count -lt 1 -or $Files.Count -gt 20000) { throw 'Invalid inventory count.' }
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase); $prior=$null; $total=0L
    foreach ($file in $Files) {
        Assert-DistFields $file @('path','length','sha256'); Assert-DistName $file.path
        if ($file.path -isnot [string] -or $file.sha256 -isnot [string] -or -not $seen.Add($file.path) -or ($null -ne $prior -and [StringComparer]::Ordinal.Compare($prior,$file.path) -ge 0) -or
            $file.length -isnot [long] -and $file.length -isnot [int] -or $file.length -lt 0 -or $file.length -gt 268435456 -or $file.sha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'Invalid inventory entry.' }
        foreach ($ancestor in $seen) { if ($ancestor -cne $file.path -and $file.path.StartsWith($ancestor+'/',[StringComparison]::OrdinalIgnoreCase)) { throw 'Inventory file/directory conflict.' } }
        $prior=$file.path; $total += $file.length
        if ($total -gt 1073741824) { throw 'Inventory exceeds its byte bound.' }
    }
}
function Read-DistEntry($Entry, [long] $Limit=268435456) {
    if ($Entry.Length -gt $Limit) { throw 'Distribution entry exceeds its bound.' }
    $inputStream=$Entry.Open(); $memory=[IO.MemoryStream]::new(); $buffer=[byte[]]::new(65536)
    try {
        while (($count=$inputStream.Read($buffer,0,$buffer.Length)) -gt 0) {
            if ($memory.Length+$count -gt $Limit) { throw 'Distribution entry exceeds its streamed bound.' }
            $memory.Write($buffer,0,$count)
        }
        if ($memory.Length -ne $Entry.Length) { throw 'Distribution entry length differs.' }
        return ,$memory.ToArray()
    } finally { $inputStream.Dispose(); $memory.Dispose() }
}
function Get-DistNuGetPackageIdentity([string] $PackagePath) {
    Assert-DistLocalPath $PackagePath
    $null=Get-DistPathFacts $PackagePath
    $stream=[IO.FileStream]::new($PackagePath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $zip=$null
    try {
        if ($stream.Length -gt 268435456) { throw 'Package exceeds its size bound.' }
        $zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Read,$true)
        $nuspecs=@($zip.Entries | Where-Object { $_.FullName.EndsWith('.nuspec',[StringComparison]::OrdinalIgnoreCase) -and -not $_.FullName.Contains('/') })
        if ($nuspecs.Count -ne 1) { throw 'Package must contain exactly one root nuspec.' }
        $bytes=Read-DistEntry $nuspecs[0] 1048576
        $xml=[Xml.XmlDocument]::new(); $xml.XmlResolver=$null
        $settings=[Xml.XmlReaderSettings]::new(); $settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit; $settings.XmlResolver=$null; $settings.MaxCharactersInDocument=1048576
        $memory=[IO.MemoryStream]::new($bytes,$false); $reader=$null
        try { $reader=[Xml.XmlReader]::Create($memory,$settings); $xml.Load($reader) }
        finally { if ($null -ne $reader) { $reader.Dispose() }; $memory.Dispose() }
        if ($xml.DocumentElement.LocalName -cne 'package' -or $xml.DocumentElement.NamespaceURI -cnotin @('http://schemas.microsoft.com/packaging/2012/06/nuspec.xsd','http://schemas.microsoft.com/packaging/2013/05/nuspec.xsd')) {
            throw 'Package nuspec root or namespace is unsupported.'
        }
        $ns=[Xml.XmlNamespaceManager]::new($xml.NameTable)
        $ns.AddNamespace('n',$xml.DocumentElement.NamespaceURI)
        $metadata=$xml.SelectSingleNode('/n:package/n:metadata',$ns)
        if ($null -eq $metadata) { throw 'Package nuspec metadata is missing.' }
        $idNode=$metadata.SelectSingleNode('n:id',$ns); $versionNode=$metadata.SelectSingleNode('n:version',$ns)
        $license=$metadata.SelectSingleNode('n:license',$ns); $repository=$metadata.SelectSingleNode('n:repository',$ns)
        if ($null -eq $idNode -or $null -eq $versionNode -or $null -eq $license -or $null -eq $repository) { throw 'Package identity metadata is incomplete.' }
        [pscustomobject][ordered]@{
            id=$idNode.InnerText
            version=$versionNode.InnerText
            licenseType=$license.GetAttribute('type')
            licenseExpression=$license.InnerText
            repositoryType=$repository.GetAttribute('type')
            repositoryUrl=$repository.GetAttribute('url')
            repositoryCommit=$repository.GetAttribute('commit')
        }
    } finally {
        if ($null -ne $zip) { $zip.Dispose() }
        $stream.Dispose()
    }
}
function Assert-DistLocalPath([string] $Path) {
    if ($Path -cnotmatch '^[A-Za-z]:\\' -or $Path.Length -gt 240 -or $Path.Contains('/') -or $Path.Substring(2).Contains(':') -or
        -not [IO.Path]::GetFullPath($Path).Equals($Path,[StringComparison]::Ordinal)) { throw 'Expected a canonical absolute local path.' }
    $cursor=$Path
    while ($cursor.Length -gt 3) {
        if ([IO.File]::Exists($cursor) -or [IO.Directory]::Exists($cursor)) {
            if (([IO.File]::GetAttributes($cursor) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Reparse path refused.' }
        }
        foreach ($part in @([IO.Path]::GetFileName($cursor))) {
            if ($part.EndsWith('.') -or $part.EndsWith(' ') -or $part -in @('.','..') -or $part -imatch '^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(\.|$)' -or $part -match '[\x00-\x1f*?]') { throw 'Alias path refused.' }
        }
        $cursor=[IO.Path]::GetDirectoryName($cursor)
    }
}
function Initialize-DistNativePaths {
    if ($null -ne ('Clc.Distribution.Paths' -as [type])) { return }
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace Clc.Distribution {
 public sealed class Captured { public byte[] Bytes; public bool Overflow; }
 public static class Capture {
  public static bool ContainsAny(Stream input,byte[][] patterns,long limit, System.Diagnostics.Stopwatch clock) {
   int longest=1; foreach(var p in patterns) { if(p.Length>longest) longest=p.Length; }
   var buffer=new byte[65536+longest]; int carry=0,n; long total=0;
   while((n=input.Read(buffer,carry,65536))>0) {
    total+=n; if(total>limit || clock.Elapsed.TotalSeconds>=300) throw new IOException("Evidence scan bound.");
    int length=carry+n; foreach(var p in patterns) { if(p.Length>0 && buffer.AsSpan(0,length).IndexOf(p)>=0) return true; }
    carry=Math.Min(longest-1,length); Array.Copy(buffer,length-carry,buffer,0,carry);
   }
   return false;
  }
  public static async System.Threading.Tasks.Task<Captured> Read(Stream input,int limit) {
   using(var memory=new MemoryStream()) {
    var buffer=new byte[4096]; int count; bool overflow=false;
    while((count=await input.ReadAsync(buffer,0,buffer.Length))>0) { if(memory.Length+count>limit) overflow=true; if(!overflow) memory.Write(buffer,0,count); }
    return new Captured { Bytes=memory.ToArray(), Overflow=overflow };
   }
  }
 }
 public sealed class Facts { public string Identity; public string CanonicalPath; }
 public static class Paths {
  [StructLayout(LayoutKind.Sequential)] struct Info { public uint Attributes, CL,CH,AL,AH,WL,WH,Volume,SizeHigh,SizeLow,Links,IndexHigh,IndexLow; }
  [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct StreamInfo { public long Size; [MarshalAs(UnmanagedType.ByValTStr,SizeConst=296)] public string Name; }
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFileW(string p,uint a,uint s,IntPtr q,uint c,uint f,IntPtr t);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle h,out Info i);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern uint GetFinalPathNameByHandleW(SafeFileHandle h,StringBuilder b,uint n,uint f);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern uint GetLongPathNameW(string p,StringBuilder b,uint n);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetFileInformationByHandleEx(SafeFileHandle h,int c,out uint flags,uint size);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool GetVolumeInformationByHandleW(SafeFileHandle h,StringBuilder v,uint n,out uint serial,out uint max,out uint flags,StringBuilder fs,uint size);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr FindFirstStreamW(string p,int level,out StreamInfo i,uint f);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool FindNextStreamW(IntPtr h,out StreamInfo i);
  [DllImport("kernel32.dll")] static extern bool FindClose(IntPtr h);
  public static bool ProbeAccess(string path,bool directory,uint access) {
   using(var h=CreateFileW(path,access,7,IntPtr.Zero,3,directory ? 0x02200000u : 0x00200000u,IntPtr.Zero)) {
    if(!h.IsInvalid) return true;
    if(Marshal.GetLastWin32Error()==5) return false;
    throw new IOException("Access probe is uncertain.");
   }
  }
  public static SafeFileHandle PinDirectory(string path) {
   var h=CreateFileW(path,0x20080,1,IntPtr.Zero,3,0x02200000,IntPtr.Zero);
   Info i; if(h.IsInvalid || !GetFileInformationByHandle(h,out i) || (i.Attributes&0x410)!=16) { h.Dispose(); throw new IOException("Unsafe evidence directory."); }
   return h;
  }
  public static FileStream OpenEvidenceFile(string path) {
   var h=CreateFileW(path,0x80000000,1,IntPtr.Zero,3,0x00200000,IntPtr.Zero);
   Info i; if(h.IsInvalid || !GetFileInformationByHandle(h,out i) || (i.Attributes&0x410)!=0 || i.Links!=1) { h.Dispose(); throw new IOException("Unsafe evidence file."); }
   try { return new FileStream(h,FileAccess.Read); } catch { h.Dispose(); throw; }
  }
  public static Facts Observe(string path,bool directory) {
   using(var h=CreateFileW(path,0x20080,1,IntPtr.Zero,3,0x02200000,IntPtr.Zero)) {
    Info i; if(h.IsInvalid || !GetFileInformationByHandle(h,out i) || (i.Attributes&0x400)!=0 || ((i.Attributes&16)!=0)!=directory || (!directory && i.Links!=1)) throw new IOException("Unsafe physical path.");
    var b=new StringBuilder(32768); if(GetFinalPathNameByHandleW(h,b,(uint)b.Capacity,0)==0 || !b.ToString().StartsWith(@"\\?\")) throw new IOException("Unknown path identity.");
    var canonical=b.ToString().Substring(4); if(!String.Equals(canonical,path,StringComparison.OrdinalIgnoreCase)) throw new IOException("Path alias.");
    b.Clear(); if(GetLongPathNameW(path,b,(uint)b.Capacity)==0 || !String.Equals(b.ToString(),path,StringComparison.OrdinalIgnoreCase)) throw new IOException("Short path alias.");
    uint flags; if(directory && (!GetFileInformationByHandleEx(h,23,out flags,4) || flags!=0)) throw new IOException("Unknown directory mode.");
    var fs=new StringBuilder(64); uint serial,max; if(!GetVolumeInformationByHandleW(h,null,0,out serial,out max,out flags,fs,(uint)fs.Capacity) || fs.ToString()!="NTFS") throw new IOException("NTFS required.");
    StreamInfo stream; var sh=FindFirstStreamW(path,0,out stream,0);
    if(sh==new IntPtr(-1)) { if(Marshal.GetLastWin32Error()!=38) throw new IOException("Unknown streams."); }
    else { try { do { if(stream.Name!="::$DATA") throw new IOException("Unexpected named stream."); } while(FindNextStreamW(sh,out stream)); if(Marshal.GetLastWin32Error()!=38) throw new IOException("Unknown streams."); } finally { FindClose(sh); } }
    return new Facts { Identity=i.Volume.ToString("x8")+":"+i.IndexHigh.ToString("x8")+i.IndexLow.ToString("x8"), CanonicalPath=canonical };
   }
  }
 }
}
'@
}
function Get-DistPathFacts([string] $Path, [switch] $Directory) {
    Assert-DistLocalPath $Path; Initialize-DistNativePaths
    $cursor=[IO.Path]::GetDirectoryName($Path)
    while ($cursor.Length -gt 3) { $null=[Clc.Distribution.Paths]::Observe($cursor,$true); $cursor=[IO.Path]::GetDirectoryName($cursor) }
    [Clc.Distribution.Paths]::Observe($Path,[bool]$Directory)
}
function Sort-DistFiles([object[]] $Files) {
    $map=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($file in $Files) { $map.Add($file.path,$file) }
    $names=[string[]]@($map.Keys); [Array]::Sort($names,[StringComparer]::Ordinal)
    return ,@($names | ForEach-Object { $map[$_] })
}
function Get-DistGit([string] $Repository, [string[]] $Arguments) {
    $info=[Diagnostics.ProcessStartInfo]::new('git'); $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    $archiveConfig=if($Arguments.Count -gt 0 -and $Arguments[0] -ceq 'archive'){@('-c','core.autocrlf=false','-c','core.eol=lf')}else{@()}
    foreach ($arg in @('-C',$Repository)+$archiveConfig+$Arguments) { $info.ArgumentList.Add($arg) }
    $process=[Diagnostics.Process]::Start($info)
    try {
        $output=$process.StandardOutput.ReadToEndAsync(); $errorOutput=$process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) { $process.Kill(); throw 'Git operation timed out.' }
        if ($process.ExitCode -ne 0) { throw 'Git operation failed.' }
        $null=$errorOutput.GetAwaiter().GetResult()
        $value=$output.GetAwaiter().GetResult()
        if ($value.Length -gt 8388608) { throw 'Git output exceeds its bound.' }
        $value.TrimEnd("`r","`n")
    } finally { $process.Dispose() }
}
function Get-DistGitTreeBlobMap {
    param([string] $Repository,[string] $SourceCommit)
    $map=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $tree=Get-DistGit $Repository @('ls-tree','-r','-z',$SourceCommit)
    foreach($entry in $tree.Split([char]0,[StringSplitOptions]::RemoveEmptyEntries)){
        # Ordinary source blobs only. Symlinks, submodules and quoted/aliased
        # paths are not a distribution source namespace.
        $match=[regex]::Match($entry,'\A100(?:644|755) blob ([a-f0-9]{40}|[a-f0-9]{64})\t(.+)\z',[Text.RegularExpressions.RegexOptions]::CultureInvariant,[TimeSpan]::FromMilliseconds(100))
        if(-not $match.Success -or $map.Count -ge 20000){throw 'Unsupported committed source tree entry.'}
        $name=$match.Groups[2].Value;Assert-DistName $name
        if(-not $map.TryAdd($name,$match.Groups[1].Value)){throw 'Duplicate committed source tree entry.'}
    }
    if($map.Count -eq 0){throw 'Empty committed source tree.'}
    return ,$map
}
function Assert-DistGitBlobBytes {
    param([byte[]] $Bytes,[string] $ObjectId)
    if($ObjectId -cnotmatch '\A(?:[a-f0-9]{40}|[a-f0-9]{64})\z'){throw 'Unsupported Git blob identity.'}
    $algorithm=if($ObjectId.Length -eq 40){[Security.Cryptography.HashAlgorithmName]::SHA1}else{[Security.Cryptography.HashAlgorithmName]::SHA256}
    $hash=[Security.Cryptography.IncrementalHash]::CreateHash($algorithm)
    try{
        # Git object identity covers the raw byte length, NUL and unconverted
        # contents. Archive/export attributes may never silently change them.
        $header='blob '+$Bytes.LongLength.ToString([Globalization.CultureInfo]::InvariantCulture)+[char]0
        $hash.AppendData([Text.Encoding]::ASCII.GetBytes($header));$hash.AppendData($Bytes)
        if([Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant() -cne $ObjectId){throw 'Archive entry differs from raw committed Git blob bytes.'}
    }finally{$hash.Dispose()}
}

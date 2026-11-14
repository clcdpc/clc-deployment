# Windows file identity interop and exact-handle publication of owned build output.
if ($null -eq ('Clc.Foundation.NativePaths' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace Clc.Foundation {
    public sealed class PathFacts {
        public string CanonicalPath, VolumeId, FileId, PhysicalPath;
        public uint Attributes, LinkCount;
    }
    public static class NativePaths {
        [StructLayout(LayoutKind.Sequential)]
        private struct Info {
            public uint Attributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME Creation, Access, Write;
            public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct StreamInfo {
            public long Size;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 296)] public string Name;
        }
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security, uint mode, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out Info info);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool GetFileInformationByHandleEx(SafeFileHandle handle, int kind, out uint info, uint size);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, StringBuilder path, uint size, uint flags);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern uint GetLongPathNameW(string path, StringBuilder result, uint size);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern uint QueryDosDeviceW(string name, StringBuilder target, uint size);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern bool GetVolumeInformationByHandleW(SafeFileHandle handle, StringBuilder name, uint nameSize, out uint serial, out uint max, out uint flags, StringBuilder fs, uint fsSize);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern IntPtr FindFirstStreamW(string path, int level, out StreamInfo info, uint flags);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern bool FindNextStreamW(IntPtr handle, out StreamInfo info);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool FindClose(IntPtr handle);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool SetFileInformationByHandle(SafeFileHandle handle, int kind, IntPtr data, uint size);
        [DllImport("advapi32.dll", SetLastError=true)]
        private static extern bool GetKernelObjectSecurity(SafeFileHandle handle, uint requested, byte[] descriptor, uint length, out uint needed);
        private static IOException Failure() { return new IOException("Windows path observation failed.", new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error())); }
        public static SafeFileHandle Open(string path) {
            // Metadata observation only. Read sharing with metadata-only access
            // does NOT constitute a byte or directory-rename lease.
            var handle = CreateFileW(path, 0x20080, 1, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
            if (handle.IsInvalid) { handle.Dispose(); throw Failure(); }
            return handle;
        }
        public static SafeFileHandle OpenPinnedDirectory(string path) {
            // LIST_DIRECTORY + READ_CONTROL + READ_ATTRIBUTES, read sharing only.
            // Keep this separate from transient observations and state-CAS handles.
            var handle = CreateFileW(path, 0x20081, 1, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
            if (handle.IsInvalid) { handle.Dispose(); throw Failure(); }
            return handle;
        }
        public static SafeFileHandle OpenPinnedMutableDirectory(string path) {
            // Mutable output parents must permit the target-directory write open
            // used by FileRenameInfo. LIST_DIRECTORY plus no delete sharing still
            // prevents renaming this held directory; child CAS remains possible.
            var handle = CreateFileW(path, 0x20081, 3, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
            if (handle.IsInvalid) { handle.Dispose(); throw Failure(); }
            return handle;
        }
        public static SafeFileHandle OpenExistingOrNull(string path) {
            // OPEN_REPARSE_POINT lets callers reject even a dangling reparse leaf.
            var handle = CreateFileW(path, 0x20080, 1, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
            if (!handle.IsInvalid) return handle;
            int error = Marshal.GetLastWin32Error();
            handle.Dispose();
            if (error == 2 || error == 3) return null; // genuine file/path absence only
            throw new IOException("Windows path observation failed.", new System.ComponentModel.Win32Exception(error));
        }
        public static FileStream CreateOutput(string path) {
            // CREATE_NEW with DELETE access permits rename/delete of this exact held file.
            // Only the derived owned temp uses an extended DOS path: its GUID leaf may
            // exceed MAX_PATH while the separately validated final destination stays <=240.
            var handle = CreateFileW(@"\\?\" + path, 0xC0010000, 0, IntPtr.Zero, 1, 0x80, IntPtr.Zero);
            if (handle.IsInvalid) { handle.Dispose(); throw Failure(); }
            try { return new FileStream(handle, FileAccess.ReadWrite); }
            catch { DeleteOutput(handle); handle.Dispose(); throw; }
        }
        public static string SecurityHash(SafeFileHandle handle) {
            uint needed;
            GetKernelObjectSecurity(handle,7,null,0,out needed);
            if (needed==0 || needed>65536) throw Failure();
            var data=new byte[needed];
            if (!GetKernelObjectSecurity(handle,7,data,needed,out needed)) throw Failure();
            return Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(data)).ToLowerInvariant();
        }
        public static void PublishOutput(SafeFileHandle handle, string destination, bool replace = false) {
            byte[] name = Encoding.Unicode.GetBytes(destination);
            int rootOffset = IntPtr.Size == 8 ? 8 : 4;
            int lengthOffset = rootOffset + IntPtr.Size;
            int nameOffset = lengthOffset + 4;
            int size = nameOffset + name.Length + 2;
            IntPtr data = Marshal.AllocHGlobal(size);
            try {
                for (int i = 0; i < size; i++) Marshal.WriteByte(data,i,0);
                Marshal.WriteByte(data, replace ? (byte)1 : (byte)0);
                Marshal.WriteIntPtr(data,rootOffset,IntPtr.Zero);
                Marshal.WriteInt32(data,lengthOffset,name.Length);
                Marshal.Copy(name,0,IntPtr.Add(data,nameOffset),name.Length);
                // FileRenameInfo: build output never replaces; state publication explicitly does.
                if (!SetFileInformationByHandle(handle,3,data,(uint)size)) throw Failure();
            } finally { Marshal.FreeHGlobal(data); }
        }
        public static void DeleteOutput(SafeFileHandle handle) {
            IntPtr data = Marshal.AllocHGlobal(1);
            try {
                Marshal.WriteByte(data,1);
                if (!SetFileInformationByHandle(handle,4,data,1)) throw Failure();
            } finally { Marshal.FreeHGlobal(data); }
        }
        public static string DriveTarget(string drive) {
            var value = new StringBuilder(1024);
            if (QueryDosDeviceW(drive, value, 1024) == 0) throw Failure();
            return value.ToString();
        }
        public static string LongPath(string path) {
            var value = new StringBuilder(1024);
            uint size = GetLongPathNameW(path, value, 1024);
            if (size == 0 || size >= 1024) throw Failure();
            return value.ToString();
        }
        public static uint DirectoryCaseFlags(SafeFileHandle handle) {
            uint flags;
            // FileCaseSensitiveInfo on the exact directory handle, Windows 2022+.
            if (!GetFileInformationByHandleEx(handle,23,out flags,4)) throw Failure();
            return flags;
        }
        private static string FinalPath(SafeFileHandle handle, uint flags) {
            var value = new StringBuilder(1024);
            uint size = GetFinalPathNameByHandleW(handle, value, 1024, flags);
            if (size == 0 || size >= 1024) throw Failure();
            return value.ToString();
        }
        public static PathFacts Observe(SafeFileHandle handle) {
            Info info;
            if (!GetFileInformationByHandle(handle, out info)) throw Failure();
            var fs = new StringBuilder(32);
            uint serial, max, flags;
            if (!GetVolumeInformationByHandleW(handle, null, 0, out serial, out max, out flags, fs, 32) || fs.ToString() != "NTFS") throw Failure();
            string dos = FinalPath(handle, 0);
            string volume = FinalPath(handle, 1);
            if (!dos.StartsWith(@"\\?\") || !volume.StartsWith(@"\\?\Volume{")) throw Failure();
            int end = volume.IndexOf('}');
            return new PathFacts { CanonicalPath=dos.Substring(4), VolumeId=volume.Substring(0,end+2).ToLowerInvariant(),
                PhysicalPath=volume.Substring(0,end+2).ToLowerInvariant()+volume.Substring(end+2),
                FileId=(((ulong)info.IndexHigh << 32) | info.IndexLow).ToString("x16"), Attributes=info.Attributes, LinkCount=info.Links };
        }
        public static void CheckStreams(string path) {
            StreamInfo info;
            IntPtr handle = FindFirstStreamW(path, 0, out info, 0);
            if (handle == new IntPtr(-1)) {
                if (Marshal.GetLastWin32Error() == 38) return; // empty stream enumeration
                throw Failure();
            }
            try {
                do { if (info.Name != "::$DATA") throw Failure(); } while (FindNextStreamW(handle, out info));
                if (Marshal.GetLastWin32Error() != 38) throw Failure();
            } finally { FindClose(handle); }
        }
    }
}
'@
}

function Assert-ClcPathComponent {
    param($Name, [string] $Code = 'Clc.UnsafePath', [switch] $Ascii, [switch] $AllowTemporary)
    if ($Name -isnot [string] -or -not $Name -or $Name -in @('.','..') -or $Name -match '[\x00-\x1f\x7f\\/:*?"<>|]' -or $Name -match '[. ]$' -or
        ($Ascii -and $Name -cnotmatch '^[A-Za-z0-9_.-]+$') -or
        (-not $AllowTemporary -and $Name.StartsWith('.clc-', [StringComparison]::OrdinalIgnoreCase)) -or
        $Name -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])($|\.)') { Stop-ClcError $Code }
}

function Assert-ClcArchiveName {
    param($Name, [switch] $PayloadOnly, [switch] $Directory, [switch] $AllowTemporary, [switch] $HookOnly)
    if ($Name -isnot [string] -or $Name.Length -gt 240 -or $Name.Length -eq 0) { Stop-ClcError Clc.UnsafeArchive }
    if ($Directory) {
        if (-not $Name.EndsWith('/')) { Stop-ClcError Clc.UnsafeArchive }
        $Name = $Name.Substring(0, $Name.Length - 1)
    }
    foreach ($part in $Name.Split('/')) { Assert-ClcPathComponent $part Clc.UnsafeArchive -Ascii -AllowTemporary:$AllowTemporary }
    if ($PayloadOnly -and (-not $Name.StartsWith('application/', [StringComparison]::Ordinal) -or $Name.Length -eq 12)) { Stop-ClcError Clc.UnsafeArchive }
    if ($HookOnly -and (-not $Name.StartsWith('hooks/', [StringComparison]::Ordinal) -or $Name.Length -eq 6)) { Stop-ClcError Clc.UnsafeArchive }
}

function Get-ClcNamePrefixes {
    param([string] $Name)
    $index = $Name.IndexOf('/')
    while ($index -ge 0) {
        $Name.Substring(0, $index)
        $index = $Name.IndexOf('/', $index + 1)
    }
}

function Test-ClcPathAncestry {
    param([string] $Ancestor, [string] $Child)
    return $Child.Equals($Ancestor, [StringComparison]::OrdinalIgnoreCase) -or
        $Child.StartsWith($Ancestor.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Assert-ClcPathSpelling {
    param([string] $Path, [switch] $Temporary)
    if (-not $IsWindows -or $Path.Length -gt 240 -or $Path -cnotmatch '^[A-Za-z]:\\' -or $Path.Substring(2).Contains(':')) { Stop-ClcError Clc.UnsafePath }
    if ($Path.Length -gt 3) {
        $components=$Path.Substring(3).Split('\')
        for ($i=0;$i -lt $components.Count;$i++) {
            $ownedLeaf=$Temporary -and $i -eq $components.Count-1 -and $components[$i] -cmatch '^\.clc-[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\.tmp$'
            Assert-ClcPathComponent $components[$i] -AllowTemporary:$ownedLeaf
        }
    }
    if ([Clc.Foundation.NativePaths]::DriveTarget($Path.Substring(0,2)) -cnotmatch '^\\Device\\HarddiskVolume[0-9]+$') { Stop-ClcError Clc.UnsafePath }
}

function Assert-ClcProtectedPath {
    param([string] $Path, $Facts = $null)
    if ($Path.Length -le 3) { Stop-ClcError Clc.UnsafePath }
    $windows = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
    $protected = @($windows, [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86))
    foreach ($root in $protected) {
        if (-not $root) { continue }
        if (Test-ClcPathAncestry $root $Path) { Stop-ClcError Clc.UnsafePath }
        if ($null -ne $Facts) {
            $handle = [Clc.Foundation.NativePaths]::Open($root)
            try {
                $protectedFacts = [Clc.Foundation.NativePaths]::Observe($handle)
                if (Test-ClcPathAncestry $protectedFacts.PhysicalPath $Facts.PhysicalPath) { Stop-ClcError Clc.UnsafePath }
            } finally { $handle.Dispose() }
        }
    }
    # Infrastructure may provision dedicated CLC namespaces in ProgramData for
    # host-local configuration/keys/enrollment. Never admit ProgramData itself or
    # another product's namespace. The ordinary physical/ACL/disjoint checks are
    # still mandatory; this is a path admission rule, never authorization.
    $programData=[Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    if ($programData -and (Test-ClcPathAncestry $programData $Path)) {
        $relative=$Path.Substring($programData.Length).TrimStart('\')
        if ($relative -inotmatch '^(CLC|clc-[a-z0-9][a-z0-9-]{0,63})(\\|$)') { Stop-ClcError Clc.UnsafePath }
    }
    if ($programData -and $null -ne $Facts) {
        $handle=[Clc.Foundation.NativePaths]::Open($programData)
        try {
            $programDataFacts=[Clc.Foundation.NativePaths]::Observe($handle)
            if (Test-ClcPathAncestry $programDataFacts.PhysicalPath $Facts.PhysicalPath) {
                $relative=$Facts.PhysicalPath.Substring($programDataFacts.PhysicalPath.Length).TrimStart('\')
                if ($relative -inotmatch '^(CLC|clc-[a-z0-9][a-z0-9-]{0,63})(\\|$)') { Stop-ClcError Clc.UnsafePath }
            }
        } finally { $handle.Dispose() }
    }
    if ($Path.Substring(3) -imatch '^(\$Recycle\.Bin|System Volume Information|Recovery|Boot)(\\|$)') { Stop-ClcError Clc.UnsafePath }
}

function Get-ClcDirectoryCaseFlags {
    param([Microsoft.Win32.SafeHandles.SafeFileHandle] $Handle)
    try { return [Clc.Foundation.NativePaths]::DirectoryCaseFlags($Handle) }
    catch { Stop-ClcError Clc.UnsafePath }
}

function Assert-ClcNoNamedStreams {
    param([string] $Path)
    try { [Clc.Foundation.NativePaths]::CheckStreams($Path) }
    catch { Stop-ClcError Clc.UnsafePath }
}

function Get-ClcPathObservation {
    param([string] $Path, [Collections.Generic.List[IDisposable]] $Handles, [switch] $Directory, [switch] $AllowVolumeRoot, [switch] $SystemFile, [switch] $Temporary, [switch] $PinnedDirectory)
    if ($PinnedDirectory -and -not $Directory) { Stop-ClcError Clc.UnsafePath }
    if ($Temporary -and ($Directory -or $AllowVolumeRoot -or $SystemFile)) { Stop-ClcError Clc.UnsafePath }
    Assert-ClcPathSpelling $Path -Temporary:$Temporary
    if ($SystemFile -and ($Directory -or $AllowVolumeRoot)) { Stop-ClcError Clc.UnsafePath }
    if (-not $AllowVolumeRoot -and -not $SystemFile) { Assert-ClcProtectedPath $Path }
    $parts = @($Path.Substring(0,3))
    if ($Path.Length -gt 3) {
        $prefix = $Path.Substring(0,2)
        foreach ($part in $Path.Substring(3).Split('\')) { $prefix += '\' + $part; $parts += $prefix }
    }
    $facts = $null
    foreach ($part in $parts) {
        $handle = if ($PinnedDirectory -and $part -ceq $Path) { [Clc.Foundation.NativePaths]::OpenPinnedDirectory($part) }
            else { [Clc.Foundation.NativePaths]::Open($part) }
        $Handles.Add($handle)
        $facts = [Clc.Foundation.NativePaths]::Observe($handle)
        if (($facts.Attributes -band 0x10) -ne 0 -and (Get-ClcDirectoryCaseFlags $handle) -ne 0) { Stop-ClcError Clc.UnsafePath }
        if (($facts.Attributes -band 0x400) -ne 0 -or -not $facts.CanonicalPath.Equals($part, [StringComparison]::OrdinalIgnoreCase) -or
            -not [Clc.Foundation.NativePaths]::LongPath($part).Equals($part, [StringComparison]::OrdinalIgnoreCase)) { Stop-ClcError Clc.UnsafePath }
        if (($facts.Attributes -band 0x10) -eq 0) {
            if ($part -ne $Path -or $Directory -or $facts.LinkCount -ne 1) { Stop-ClcError Clc.UnsafePath }
        }
        # Directories can have named $DATA streams too; those bytes are absent
        # from ordinary child enumeration and must never become cleanup material.
        Assert-ClcNoNamedStreams $part
    }
    if ($Directory -and ($facts.Attributes -band 0x10) -eq 0) { Stop-ClcError Clc.UnsafePath }
    if (-not $Directory -and ($facts.Attributes -band 0x10) -ne 0 -and -not $AllowVolumeRoot) { Stop-ClcError Clc.UnsafePath }
    if (-not $AllowVolumeRoot -and -not $SystemFile) { Assert-ClcProtectedPath $Path $facts }
    return $facts
}

function Assert-ClcDisjoint {
    param($First, $Second)
    if (($First.VolumeId -ceq $Second.VolumeId -and $First.FileId -ceq $Second.FileId) -or
        (Test-ClcPathAncestry $First.PhysicalPath $Second.PhysicalPath) -or
        (Test-ClcPathAncestry $Second.PhysicalPath $First.PhysicalPath)) { Stop-ClcError Clc.UnsafePath }
}

# For a bounded descendant walk whose complete directory ancestry is already
# held by this invocation. Observe the child itself without reopening every
# ancestor/protected root for every sibling. No caller-selected root is trusted.
function Get-ClcChildPathObservation {
    param([string] $Path, $Parent, [Collections.Generic.List[IDisposable]] $Handles, [switch] $Directory, [switch] $Temporary, [switch] $PinnedDirectory)
    try {
    Assert-ClcPathSpelling $Path -Temporary:$Temporary
    if (-not [IO.Path]::GetDirectoryName($Path).Equals($Parent.CanonicalPath,[StringComparison]::OrdinalIgnoreCase)) { Stop-ClcError Clc.UnsafePath }
    if ($PinnedDirectory -and -not $Directory) { Stop-ClcError Clc.UnsafePath }
    $handle=if ($PinnedDirectory) { [Clc.Foundation.NativePaths]::OpenPinnedDirectory($Path) }
        else { [Clc.Foundation.NativePaths]::Open($Path) }
    $Handles.Add($handle)
    $facts=[Clc.Foundation.NativePaths]::Observe($handle)
    $physical=Join-Path $Parent.PhysicalPath ([IO.Path]::GetFileName($Path))
    if (($facts.Attributes -band 0x400) -ne 0 -or $facts.VolumeId -cne $Parent.VolumeId -or
        -not $facts.CanonicalPath.Equals($Path,[StringComparison]::OrdinalIgnoreCase) -or
        -not $facts.PhysicalPath.Equals($physical,[StringComparison]::OrdinalIgnoreCase) -or
        -not [Clc.Foundation.NativePaths]::LongPath($Path).Equals($Path,[StringComparison]::OrdinalIgnoreCase) -or
        ((($facts.Attributes -band 0x10) -ne 0) -ne [bool]$Directory)) { Stop-ClcError Clc.UnsafePath }
    if ($Directory) { if ((Get-ClcDirectoryCaseFlags $handle) -ne 0) { Stop-ClcError Clc.UnsafePath } }
    else { if ($facts.LinkCount -ne 1) { Stop-ClcError Clc.UnsafePath } }
    Assert-ClcNoNamedStreams $Path
    return $facts
    } catch { Stop-ClcError Clc.UnsafePath }
}

function Open-ClcReadFile {
    param([string] $Path, $Facts, [Collections.Generic.List[IDisposable]] $Handles)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $Handles.Add($stream)
    $opened = [Clc.Foundation.NativePaths]::Observe($stream.SafeFileHandle)
    if ($opened.VolumeId -cne $Facts.VolumeId -or $opened.FileId -cne $Facts.FileId -or $opened.LinkCount -ne 1 -or ($opened.Attributes -band 0x410) -ne 0) { Stop-ClcError Clc.UnsafePath }
    return $stream
}

# Native boundaries contain no application launch or IIS mutation operation.
if ($null -eq ('Clc.Host.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;
namespace Clc.Host {
    public sealed class ProcessFacts {
        public uint ProcessId;
        public long CreationFileTime;
        public bool Exited;
        public uint ExitCode;
    }
    public static class Native {
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern SafeProcessHandle OpenProcess(uint access, bool inherit, uint pid);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool GetProcessTimes(SafeProcessHandle h, out long created, out long exited, out long kernel, out long user);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern uint WaitForSingleObject(SafeProcessHandle h, uint milliseconds);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool GetExitCodeProcess(SafeProcessHandle h, out uint code);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool TerminateProcess(SafeProcessHandle h, uint code);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security, uint mode, uint flags, IntPtr template);
        private static Exception Failure() { return new IOException("Required Windows observation failed."); }
        public static FileStream OpenLock(string path) {
            // OPEN_ALWAYS, OPEN_REPARSE_POINT; null security attributes means non-inheritable.
            var h = CreateFileW(path,0xC0000000,0,IntPtr.Zero,4,0x00200080,IntPtr.Zero);
            if (h.IsInvalid) { h.Dispose(); throw Failure(); }
            try { return new FileStream(h,FileAccess.ReadWrite); }
            catch { h.Dispose(); throw; }
        }
        public static ProcessFacts Observe(SafeProcessHandle h, uint pid) {
            long created, exited, kernel, user; uint code;
            if (!GetProcessTimes(h,out created,out exited,out kernel,out user)) throw Failure();
            uint wait = WaitForSingleObject(h,0);
            if (wait != 0 && wait != 258) throw Failure();
            if (!GetExitCodeProcess(h,out code)) throw Failure();
            return new ProcessFacts { ProcessId=pid, CreationFileTime=created, Exited=wait==0, ExitCode=code };
        }
        public static ProcessFacts Lookup(uint pid) {
            using (var h = OpenProcess(0x00101000,false,pid)) {
                if (h.IsInvalid) {
                    if (Marshal.GetLastWin32Error()==87) return null; // PID absent, not access denied.
                    throw Failure();
                }
                return Observe(h,pid);
            }
        }
        public static ProcessFacts Wait(Process p, long expected, uint milliseconds, bool terminate) {
            return Wait(p,expected,milliseconds,terminate,30000);
        }
        public static ProcessFacts Wait(Process p, long expected, uint milliseconds, bool terminate, uint terminationMilliseconds) {
            var before = Observe(p.SafeHandle,(uint)p.Id);
            if (before.CreationFileTime != expected) throw Failure();
            uint wait = WaitForSingleObject(p.SafeHandle,milliseconds);
            if (wait==258 && terminate) {
                if (!TerminateProcess(p.SafeHandle,0xE0000001) && WaitForSingleObject(p.SafeHandle,0)!=0) throw Failure();
                wait = WaitForSingleObject(p.SafeHandle,terminationMilliseconds);
            }
            if (wait!=0) throw Failure();
            return Observe(p.SafeHandle,(uint)p.Id);
        }
        [StructLayout(LayoutKind.Sequential)] private struct Luid { public uint Low; public int High; }
        [StructLayout(LayoutKind.Sequential)] private struct Request { public uint Desired; public IntPtr Self, Types; public uint Count; public IntPtr Optional; }
        [StructLayout(LayoutKind.Sequential)] private struct Reply { public uint Count; public IntPtr Granted, Sacl, Error; }
        [DllImport("authz.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern bool AuthzInitializeResourceManager(uint flags, IntPtr a, IntPtr b, IntPtr c, string name, out IntPtr rm);
        [DllImport("authz.dll", SetLastError=true)]
        private static extern bool AuthzInitializeContextFromSid(uint flags, byte[] sid, IntPtr rm, IntPtr expires, Luid id, IntPtr args, out IntPtr context);
        [DllImport("authz.dll", SetLastError=true)]
        private static extern bool AuthzInitializeContextFromToken(uint flags, IntPtr token, IntPtr rm, IntPtr expires, Luid id, IntPtr args, out IntPtr context);
        [DllImport("authz.dll", SetLastError=true)]
        private static extern bool AuthzAccessCheck(uint flags, IntPtr context, ref Request request, IntPtr audit, byte[] sd, IntPtr optional, uint count, ref Reply reply, IntPtr results);
        [DllImport("authz.dll")] private static extern bool AuthzFreeContext(IntPtr context);
        [DllImport("authz.dll")] private static extern bool AuthzFreeResourceManager(IntPtr rm);
        private static uint Access(byte[] sd, string sid, bool current) {
            IntPtr rm=IntPtr.Zero, context=IntPtr.Zero, granted=IntPtr.Zero, error=IntPtr.Zero;
            using (var identity=WindowsIdentity.GetCurrent()) {
                try {
                    if (!AuthzInitializeResourceManager(1,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,"CLC read-only access observation",out rm)) throw Failure();
                    if (current) {
                        if (identity.User.Value!=sid || !AuthzInitializeContextFromToken(0,identity.Token,rm,IntPtr.Zero,new Luid(),IntPtr.Zero,out context)) throw Failure();
                    } else {
                        var user=new SecurityIdentifier(sid); byte[] data=new byte[user.BinaryLength]; user.GetBinaryForm(data,0);
                        // Require S4U group evidence. Never silently omit groups or downgrade to SID-only.
                        if (!AuthzInitializeContextFromSid(4,data,rm,IntPtr.Zero,new Luid(),IntPtr.Zero,out context)) throw Failure();
                    }
                    granted=Marshal.AllocHGlobal(4); error=Marshal.AllocHGlobal(4);
                    Marshal.WriteInt32(granted,0); Marshal.WriteInt32(error,0);
                    var request=new Request { Desired=0x02000000 }; // MAXIMUM_ALLOWED
                    var reply=new Reply { Count=1,Granted=granted,Error=error };
                    if (!AuthzAccessCheck(0,context,ref request,IntPtr.Zero,sd,IntPtr.Zero,0,ref reply,IntPtr.Zero)) throw Failure();
                    int result=Marshal.ReadInt32(error);
                    if (result!=0 && result!=5) throw Failure();
                    return unchecked((uint)Marshal.ReadInt32(granted));
                } finally {
                    if (context!=IntPtr.Zero) AuthzFreeContext(context);
                    if (rm!=IntPtr.Zero) AuthzFreeResourceManager(rm);
                    if (granted!=IntPtr.Zero) Marshal.FreeHGlobal(granted);
                    if (error!=IntPtr.Zero) Marshal.FreeHGlobal(error);
                }
            }
        }
        public static uint AccessBounded(byte[] sd, string sid, bool current) {
            var task=Task.Run(()=>Access(sd,sid,current));
            if (!task.Wait(10000)) throw Failure();
            return task.GetAwaiter().GetResult();
        }
        private static async Task<byte[]> ReadBounded(Stream stream) {
            using (var memory=new MemoryStream()) {
                byte[] buffer=new byte[4096]; int count;
                while ((count=await stream.ReadAsync(buffer,0,buffer.Length))!=0) {
                    if (memory.Length+count>65536) throw Failure();
                    memory.Write(buffer,0,count);
                }
                return memory.ToArray();
            }
        }
        // Used only by the explicit read-only appcmd/dotnet query wrappers below.
        public static byte[] Query(string executable, string operation, string poolName) {
            string[] arguments;
            switch (operation) {
                case "PoolNames": arguments=new[] { "list","apppool","/text:name" }; break;
                case "PoolState":
                    if (poolName==null || !System.Text.RegularExpressions.Regex.IsMatch(poolName,@"\A[A-Za-z0-9_.-]{1,64}\z")) throw Failure();
                    arguments=new[] { "list","apppool",poolName,"/text:state" }; break;
                case "Runtimes": arguments=new[] { "--list-runtimes" }; break;
                default: throw Failure();
            }
            string expected=operation=="Runtimes" ? "dotnet.exe" : "appcmd.exe";
            if (!String.Equals(Path.GetFileName(executable),expected,StringComparison.OrdinalIgnoreCase)) throw Failure();
            var info=new ProcessStartInfo(executable) { UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true,WorkingDirectory=Path.GetDirectoryName(executable) };
            info.Environment.Clear();
            string windows=Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            info.Environment["SystemRoot"]=windows; info.Environment["WINDIR"]=windows;
            foreach (string arg in arguments) info.ArgumentList.Add(arg);
            using (var p=new Process { StartInfo=info }) {
                if (!p.Start()) throw Failure();
                var identity=Observe(p.SafeHandle,(uint)p.Id);
                var output=ReadBounded(p.StandardOutput.BaseStream);
                var errors=ReadBounded(p.StandardError.BaseStream);
                var all=Task.WhenAll(output,errors);
                try {
                    if (!all.Wait(30000) || !p.WaitForExit(1000) || p.ExitCode!=0) throw Failure();
                    return output.GetAwaiter().GetResult();
                } catch {
                    Wait(p,identity.CreationFileTime,0,true);
                    throw Failure();
                }
            }
        }
    }
}
'@
}

function Get-ClcProcessIdentity {
    param([Parameter(Mandatory)][Diagnostics.Process] $Process)
    try {
        $facts = [Clc.Host.Native]::Observe($Process.SafeHandle, [uint32] $Process.Id)
        return @{ processId=[long]$facts.ProcessId; creationUtc=[DateTime]::FromFileTimeUtc($facts.CreationFileTime).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ', [Globalization.CultureInfo]::InvariantCulture) }
    } catch { Stop-ClcError Clc.HelperQuiescenceUnknown }
}

function Get-ClcNativeProcessObservation {
    param([long] $ProcessId, [string] $CreationUtc)
    Assert-ClcInteger $ProcessId 1 4294967295
    Assert-ClcTimestamp $CreationUtc -Native
    try {
        $facts = [Clc.Host.Native]::Lookup([uint32]$ProcessId)
        if ($null -eq $facts) { return 'Exited' }
        $expected = [DateTime]::ParseExact($CreationUtc,'yyyy-MM-ddTHH:mm:ss.fffffffZ',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal).ToFileTimeUtc()
        if ($facts.CreationFileTime -ne $expected) { return 'Exited' } # Reused PID: that exact old process is gone.
        if ($facts.Exited) { return 'Exited' }
        return 'Running'
    } catch { return 'Unknown' }
}

function Wait-ClcTrackedProcess {
    param([Parameter(Mandatory)][Diagnostics.Process] $Process, [string] $CreationUtc,
        [ValidateRange(0,30000)][int] $TimeoutMilliseconds = 30000,
        [ValidateRange(0,30000)][int] $TerminationMilliseconds = 30000)
    Assert-ClcTimestamp $CreationUtc -Native
    try {
        $expected = [DateTime]::ParseExact($CreationUtc,'yyyy-MM-ddTHH:mm:ss.fffffffZ',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal).ToFileTimeUtc()
        $facts = [Clc.Host.Native]::Wait($Process,$expected,[uint32]$TimeoutMilliseconds,$true,[uint32]$TerminationMilliseconds)
        return [long][BitConverter]::ToInt32([BitConverter]::GetBytes($facts.ExitCode),0)
    } catch { Stop-ClcError Clc.HelperQuiescenceUnknown }
}

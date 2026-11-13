if ($null -eq ('Clc.Lifecycle.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Diagnostics;
using System.Threading.Tasks;
using System.Net;
using System.Net.Http;
using System.Threading;
namespace Clc.Lifecycle {
    public sealed class Captured { public byte[] Bytes; public bool Overflow; }
    public sealed class Running { public Process Process; public Task<Captured> Output, Errors; }
    public sealed class ValidationOutput { public byte[] Bytes; public bool Failed; }
    public sealed class HealthOutput { public byte[] Bytes; public bool Accepted; }
    public static class Native {
        private static async Task<Captured> Read(Stream source, int limit) {
            using (var buffer = new MemoryStream()) {
                var chunk=new byte[4096]; int n; bool overflow=false;
                while ((n=await source.ReadAsync(chunk,0,chunk.Length))>0) {
                    if (buffer.Length+n>limit) overflow=true;
                    if (!overflow) buffer.Write(chunk,0,n);
                }
                return new Captured { Bytes=buffer.ToArray(), Overflow=overflow };
            }
        }
        private static ProcessStartInfo Info(string executable, string directory) {
            var info=new ProcessStartInfo(executable) { UseShellExecute=false, CreateNoWindow=true,
                RedirectStandardOutput=true, RedirectStandardError=true, WorkingDirectory=directory };
            info.Environment.Clear();
            var windows=Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            info.Environment["SystemRoot"]=windows; info.Environment["WINDIR"]=windows;
            return info;
        }
        private static Running Start(ProcessStartInfo info, int limit) {
            var p=new Process { StartInfo=info };
            try {
                if (!p.Start()) throw new IOException("Helper launch failed.");
                return new Running { Process=p, Output=Read(p.StandardOutput.BaseStream,limit), Errors=Read(p.StandardError.BaseStream,limit) };
            } catch { p.Dispose(); throw; }
        }
        public static Running Validator(string executable, string dll, string configuration, string keys, string environment) {
            if (!String.Equals(Path.GetFileName(executable),"dotnet.exe",StringComparison.OrdinalIgnoreCase) ||
                Path.GetExtension(dll)!=".dll" || (environment!="Production" && environment!="Staging")) throw new IOException("Invalid validator.");
            var info=Info(executable,Path.GetDirectoryName(dll));
            foreach (var arg in new[] {dll,"--validate-deployment","--configuration-path",configuration,"--data-protection-root",keys,"--environment",environment}) info.ArgumentList.Add(arg);
            return Start(info,8192);
        }
        public static Running Iis(string executable, string operation, string pool) {
            if (!String.Equals(Path.GetFileName(executable),"appcmd.exe",StringComparison.OrdinalIgnoreCase) ||
                (operation!="Stop" && operation!="Start") ||
                !System.Text.RegularExpressions.Regex.IsMatch(pool,@"\A[A-Z0-9_.-]{1,64}\z")) throw new IOException("Invalid IIS operation.");
            var info=Info(executable,Path.GetDirectoryName(executable));
            foreach (var arg in new[] {operation=="Start" ? "start" : "stop","apppool","/apppool.name:"+pool}) info.ArgumentList.Add(arg);
            return Start(info,8192);
        }
        // Read-only attestation verifier; never inherits credentials, CLI config,
        // proxy overrides, PATH or a caller-selected executable/argument string.
        public static Running Attestation(string executable, string[] arguments) {
            var info=Info(executable,Path.GetDirectoryName(executable));
            foreach (var arg in arguments) info.ArgumentList.Add(arg);
            return Start(info,4194304);
        }
        public static ValidationOutput Finish(Running running, int milliseconds) {
            var clock=Stopwatch.StartNew(); var all=Task.WhenAll(running.Output,running.Errors);
            if (!all.Wait(milliseconds)) return new ValidationOutput { Failed=true };
            int remaining=Math.Max(0,milliseconds-(int)clock.ElapsedMilliseconds);
            if (!running.Process.WaitForExit(remaining)) return new ValidationOutput { Failed=true };
            var output=running.Output.GetAwaiter().GetResult(); var errors=running.Errors.GetAwaiter().GetResult();
            return new ValidationOutput { Bytes=output.Bytes, Failed=output.Overflow || errors.Overflow || running.Process.ExitCode!=0 };
        }
        public static HttpClientHandler ReadinessHandler() {
            return new HttpClientHandler { AllowAutoRedirect=false, UseCookies=false, UseDefaultCredentials=false,
                Credentials=null, PreAuthenticate=false, UseProxy=false, CheckCertificateRevocationList=true };
        }
        public static HealthOutput HealthResponse(HttpResponseMessage response, CancellationToken token) {
            var type=response.Content.Headers.ContentType;
            if (response.StatusCode!=HttpStatusCode.OK || type==null || !String.Equals(type.MediaType,"application/json",StringComparison.OrdinalIgnoreCase) ||
                (type.CharSet!=null && !String.Equals(type.CharSet,"utf-8",StringComparison.OrdinalIgnoreCase)) ||
                type.Parameters.Count>1 || (type.Parameters.Count==1 && type.CharSet==null) ||
                response.Headers.Location!=null || response.Headers.WwwAuthenticate.Count>0 || response.Headers.Contains("Set-Cookie") ||
                response.Headers.CacheControl==null || !response.Headers.CacheControl.NoStore ||
                (response.Headers.Age.HasValue && response.Headers.Age.Value>TimeSpan.Zero) || response.Content.Headers.ContentLength>4096) return new HealthOutput();
            using (var stream=response.Content.ReadAsStreamAsync(token).GetAwaiter().GetResult())
            using (var memory=new MemoryStream()) {
                var chunk=new byte[1024]; int n;
                while ((n=stream.ReadAsync(chunk,0,chunk.Length,token).GetAwaiter().GetResult())>0) {
                    if (memory.Length+n>4096) return new HealthOutput();
                    memory.Write(chunk,0,n);
                }
                return new HealthOutput { Accepted=true, Bytes=memory.ToArray() };
            }
        }
        public static HealthOutput Health(string address) {
            var uri=new Uri(address);
            if (uri.Scheme!="https" || uri.AbsolutePath!="/health/ready" || uri.UserInfo!="" || uri.Query!="" || uri.Fragment!="") throw new IOException("Invalid readiness URI.");
            using (var handler=ReadinessHandler())
            using (var client=new HttpClient(handler) { Timeout=Timeout.InfiniteTimeSpan })
            using (var cancel=new CancellationTokenSource(5000))
            using (var request=new HttpRequestMessage(HttpMethod.Get,uri)) {
                request.Headers.CacheControl=new System.Net.Http.Headers.CacheControlHeaderValue { NoStore=true, NoCache=true };
                request.Headers.Accept.ParseAdd("application/json");
                using (var response=client.SendAsync(request,HttpCompletionOption.ResponseHeadersRead,cancel.Token).GetAwaiter().GetResult()) {
                    return HealthResponse(response,cancel.Token);
                }
            }
        }
    }
}
'@
}

function Open-ClcConfiguration {
    param($Lock)
    $target=$Lock.targetFile.record
    $file=Read-ClcHeldFile $target.operationalConfigPath $Lock.context.handles 4194304 -NoCapture
    return @{file=$file;record=@{privateSha256=$file.sha256;revision='pending-validation';keyStoreCompatibilityId='pending-validation';runtimeEnvironment=$target.runtimeEnvironment}}
}

function Assert-ClcConfigurationUnchanged {
    param($Session, [Diagnostics.Stopwatch] $Clock=$null, [int] $Seconds=300)
    if ($null -eq $Clock) { $Clock=[Diagnostics.Stopwatch]::StartNew() }
    $file=$Session.configuration.file
    $file.stream.Position=0
    try { $digest=Read-ClcStream $file.stream 4194304 $Clock -Seconds $Seconds }
    finally { $file.stream.Position=0 }
    if ($digest.sha256 -cne $file.sha256) { Stop-ClcError Clc.ConfigurationRevisionDrift }
}

function Invoke-ClcNativeApplicationValidator {
    param([string] $DotnetPath,[string] $Dll,[string] $ConfigurationPath,[string] $DataProtectionRoot,[string] $RuntimeEnvironment)
    return [Clc.Lifecycle.Native]::Validator($DotnetPath,$Dll,$ConfigurationPath,$DataProtectionRoot,$RuntimeEnvironment)
}
function Start-ClcApplicationValidator {
    param($Lock,[string] $Dll,[Diagnostics.Stopwatch] $DeadlineClock=$null,[int] $DeadlineSeconds=30)
    Assert-ClcHelperProtection $Lock.context
    if ($null -ne $DeadlineClock -and $DeadlineClock.Elapsed.TotalSeconds -ge $DeadlineSeconds) { Stop-ClcError Clc.ConfigurationInvalid }
    $target=$Lock.targetFile.record
    return Invoke-ClcNativeApplicationValidator $Lock.context.policyFile.record.dotnetPath $Dll $target.operationalConfigPath $target.dataProtectionRoot $target.runtimeEnvironment
}
function Complete-ClcHelperOutput {
    param($Running,[ValidateRange(1,30000)][int] $TimeoutMilliseconds=30000)
    return [Clc.Lifecycle.Native]::Finish($Running,$TimeoutMilliseconds)
}
function Stop-ClcOwnedHelper {
    param($Running,$Lock)
    if ($null -eq $Running) { return }
    try {
        $identity=Get-ClcProcessIdentity $Running.Process
        $null=Wait-ClcTrackedProcess $Running.Process $identity.creationUtc 0 30000
        $file=Read-ClcStateFile $Lock journal
        if ($file.record.nativeCall.launchState -ceq 'Started' -and $file.record.nativeCall.processId -eq $identity.processId -and
            $file.record.nativeCall.creationUtc -ceq $identity.creationUtc) {
            $null=Write-ClcNativeCallExited $Lock $Running.Process 0 0
        }
    } finally { $Running.Process.Dispose() }
}
function Invoke-ClcTrackedHelper {
    param($Session,[ValidateSet('Validate','Stop','Start')][string] $Operation,[string] $Dll)
    $lock=$Session.lock; $running=$null; $clock=[Diagnostics.Stopwatch]::StartNew()
    try {
        $null=Write-ClcNativeCallIntent $lock $Operation
        if ($Operation -ceq 'Validate') { $running=Start-ClcApplicationValidator $lock $Dll $clock 30 }
        else { $running=Start-ClcIisHelper $lock $Operation $clock }
        $null=Write-ClcNativeCallStarted $lock $running.Process
        $remaining=[Math]::Min(30000,[Math]::Max(1,[int]((30-$clock.Elapsed.TotalSeconds)*1000)))
        $output=Complete-ClcHelperOutput $running $remaining
        $remaining=[Math]::Min(30000,[Math]::Max(0,[int]((30-$clock.Elapsed.TotalSeconds)*1000)))
        $exited=Write-ClcNativeCallExited $lock $running.Process 0 $remaining
        if ($output.Failed -or $exited.record.nativeCall.exitCode -ne 0 -or $clock.Elapsed.TotalSeconds -ge 30) {
            if ($Operation -ceq 'Validate') { Stop-ClcError Clc.ConfigurationInvalid }
            if ($Operation -ceq 'Start') { Stop-ClcError Clc.StartupFailed }
            Stop-ClcError Clc.ShutdownTimeout
        }
        return $output
    } finally { Stop-ClcOwnedHelper $running $lock }
}
function Invoke-ClcApplicationValidation {
    param($Session,$Release,[string] $ApplicationRoot,[switch] $BindConfiguration)
    $lock=$Session.lock
    $null=Assert-ClcEffectAuthority $Session
    $null=Get-ClcTreeInventory $ApplicationRoot $Release.manifest.files
    $output=Invoke-ClcTrackedHelper $Session Validate (Join-Path $ApplicationRoot $Release.manifest.validation.entryPoint)
    try { $validation=Read-ClcJson $output.Bytes application-validation }
    catch { Stop-ClcError Clc.ConfigurationInvalid }
    $m=$Release.manifest
    if (-not $validation.valid -or $validation.errorCodes.Count -ne 0 -or $validation.applicationId -cne $m.applicationId -or
        $validation.releaseId -cne $m.releaseId -or $validation.sourceCommit -cne $m.source.commit -or
        $validation.runtimeEnvironment -cne $lock.targetFile.record.runtimeEnvironment) { Stop-ClcError Clc.ConfigurationInvalid }
    $configuration=@{privateSha256=$Session.configuration.file.sha256;revision=$validation.configurationRevision;
        keyStoreCompatibilityId=$validation.keyStoreCompatibilityId;runtimeEnvironment=$validation.runtimeEnvironment}
    $null=Assert-ClcEffectAuthority $Session
    if ($BindConfiguration) {
        $file=Read-ClcStateFile $lock journal; $j=$file.record; $j.configuration=$configuration
        $null=Write-ClcStateRecord $lock journal $j $file.sha256
        $Session.configuration.record=$configuration
    } elseif (-not (Test-ClcValueEqual $configuration $Session.configuration.record)) { Stop-ClcError Clc.PreviousConfigurationIncompatible }
    return $configuration
}
function Get-ClcValidationElapsed { param([Diagnostics.Stopwatch] $Clock) return $Clock.Elapsed.TotalSeconds }

function Invoke-ClcReadinessRequest {
    param([string] $Uri)
    try { return [Clc.Lifecycle.Native]::Health($Uri) }
    catch { return @{Accepted=$false;Bytes=[byte[]]::new(0)} }
}
function Test-ClcReadinessIdentity {
    param([byte[]] $Bytes, $Manifest, $Configuration)
    try {
        $ready=Read-ClcJson $Bytes readiness
        return $ready.applicationId -ceq $Manifest.applicationId -and $ready.releaseId -ceq $Manifest.releaseId -and
            $ready.sourceCommit -ceq $Manifest.source.commit -and $ready.runtimeEnvironment -ceq $Configuration.runtimeEnvironment -and
            $ready.configurationRevision -ceq $Configuration.revision
    } catch { return $false }
}

function Wait-ClcApplicationReady {
    param($Session,$Release,[switch] $NoOpProbe)
    $lock=$Session.lock; $clock=[Diagnostics.Stopwatch]::StartNew()
    if (-not $NoOpProbe) { $null=Write-ClcJournalIntent $lock CheckReady }
    $null=Assert-ClcEffectAuthority $Session
    do {
        if ((Get-ClcReadinessElapsed $clock) -ge 115) { break }
        $response=Invoke-ClcReadinessRequest $lock.targetFile.record.readinessUri
        if ($response.Accepted -and (Test-ClcReadinessIdentity $response.Bytes $Release.manifest $Session.configuration.record)) {
            $pool=Get-ClcLivePool $lock
            if ($pool.poolState -ceq 'Started' -and $pool.workerCount -eq 1) {
                $null=Get-ClcTreeInventory $lock.targetFile.record.applicationRoot $Release.manifest.files -DeadlineClock $clock -DeadlineSeconds 120
                $null=Assert-ClcEffectAuthority $Session
                if ((Get-ClcReadinessElapsed $clock) -ge 120) { break }
                return @{releaseId=$Release.manifest.releaseId;sourceCommit=$Release.manifest.source.commit;runtimeEnvironment=$Session.configuration.record.runtimeEnvironment;
                    configurationRevision=$Session.configuration.record.revision;checkedUtc=(Get-ClcUtcTimestamp)}
            }
        }
        if ($NoOpProbe) { return $null }
        Start-Sleep -Milliseconds 2000
    } while ((Get-ClcReadinessElapsed $clock) -lt 115)
    if ($NoOpProbe) { return $null }
    Stop-ClcError Clc.ReadinessFailed
}
function Get-ClcReadinessElapsed { param([Diagnostics.Stopwatch] $Clock) return $Clock.Elapsed.TotalSeconds }

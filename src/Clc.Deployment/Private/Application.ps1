if ($null -eq ('Clc.Lifecycle.V2.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Diagnostics;
using System.Threading.Tasks;
using System.Net;
using System.Net.Http;
using System.Threading;
namespace Clc.Lifecycle.V2 {
    public sealed class Captured { public byte[] Bytes; public bool Overflow; }
    public sealed class Running { public Process Process; public Task<Captured> Output, Errors; }
    public sealed class ValidationOutput { public byte[] Bytes; public bool Failed; public bool Overflow; }
    public sealed class HealthOutput { public byte[] Bytes=Array.Empty<byte>(); public bool Accepted; public string Status="InvalidResponse"; }
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
        public static ValidationOutput Finish(Running running, int milliseconds) {
            var clock=Stopwatch.StartNew(); var all=Task.WhenAll(running.Output,running.Errors);
            if (!all.Wait(milliseconds)) return new ValidationOutput { Failed=true };
            int remaining=Math.Max(0,milliseconds-(int)clock.ElapsedMilliseconds);
            if (!running.Process.WaitForExit(remaining)) return new ValidationOutput { Failed=true };
            var output=running.Output.GetAwaiter().GetResult(); var errors=running.Errors.GetAwaiter().GetResult();
            return new ValidationOutput { Bytes=output.Bytes, Overflow=output.Overflow || errors.Overflow, Failed=output.Overflow || errors.Overflow || running.Process.ExitCode!=0 };
        }
        public static HttpClientHandler ReadinessHandler() {
            return new HttpClientHandler { AllowAutoRedirect=false, UseCookies=false, UseDefaultCredentials=false,
                Credentials=null, PreAuthenticate=false, UseProxy=false, CheckCertificateRevocationList=true };
        }
        public static async Task<HealthOutput> HealthResponse(HttpResponseMessage response, CancellationToken token) {
            var type=response.Content.Headers.ContentType;
            if (response.StatusCode!=HttpStatusCode.OK || type==null || !String.Equals(type.MediaType,"application/json",StringComparison.OrdinalIgnoreCase) ||
                (type.CharSet!=null && !String.Equals(type.CharSet,"utf-8",StringComparison.OrdinalIgnoreCase)) ||
                type.Parameters.Count>1 || (type.Parameters.Count==1 && type.CharSet==null) ||
                response.Headers.Location!=null || response.Headers.WwwAuthenticate.Count>0 || response.Headers.Contains("Set-Cookie") ||
                response.Headers.CacheControl==null || !response.Headers.CacheControl.NoStore ||
                (response.Headers.Age.HasValue && response.Headers.Age.Value>TimeSpan.Zero) || response.Content.Headers.ContentLength>4096) return new HealthOutput();
            using (var stream=await response.Content.ReadAsStreamAsync(token).ConfigureAwait(false))
            using (var memory=new MemoryStream()) {
                var chunk=new byte[1024]; int n;
                while ((n=await stream.ReadAsync(chunk,0,chunk.Length,token).ConfigureAwait(false))>0) {
                    if (memory.Length+n>4096) return new HealthOutput();
                    memory.Write(chunk,0,n);
                }
                return new HealthOutput { Accepted=true, Bytes=memory.ToArray() };
            }
        }
        private static async Task<HealthOutput> Probe(HttpClient client, string address, CancellationToken token) {
            var uri=new Uri(address);
            if (uri.Scheme!="https" || uri.AbsolutePath!="/health/ready" || uri.UserInfo!="" || uri.Query!="" || uri.Fragment!="") throw new IOException("Invalid readiness URI.");
            try {
                using var request=new HttpRequestMessage(HttpMethod.Get,uri);
                request.Headers.CacheControl=new System.Net.Http.Headers.CacheControlHeaderValue { NoStore=true, NoCache=true };
                request.Headers.Accept.ParseAdd("application/json");
                using var response=await client.SendAsync(request,HttpCompletionOption.ResponseHeadersRead,token).ConfigureAwait(false);
                return await HealthResponse(response,token).ConfigureAwait(false);
            } catch (OperationCanceledException) { return new HealthOutput { Status="Timeout" }; }
            catch (HttpRequestException e) {
                return new HealthOutput { Status=e.HttpRequestError==HttpRequestError.SecureConnectionError ? "TlsFailure" : "Unreachable" };
            } catch (IOException) { return new HealthOutput { Status="Unreachable" }; }
        }
        public static HealthOutput[] ProbeAll(string[] addresses, int milliseconds) {
            if (addresses.Length<1 || addresses.Length>16 || milliseconds<1 || milliseconds>5000) throw new ArgumentOutOfRangeException();
            using var handler=ReadinessHandler();
            using var client=new HttpClient(handler) { Timeout=Timeout.InfiniteTimeSpan };
            using var cancel=new CancellationTokenSource(milliseconds);
            var tasks=Array.ConvertAll(addresses,address=>Probe(client,address,cancel.Token));
            return Task.WhenAll(tasks).GetAwaiter().GetResult();
        }
    }
}
'@
}


function Start-ClcApplicationValidator {
    param($Context,[string] $Dll)
    return [Clc.Lifecycle.V2.Native]::Validator($Context.dotnet,$Dll,$Context.layout.config,$Context.layout.keys,$Context.environment)
}
function Complete-ClcApplicationValidator {
    param($Running)
    return [Clc.Lifecycle.V2.Native]::Finish($Running,30000)
}
function Assert-ClcHelperExited {
    param($Helper)
    if ($null -eq $Helper -or $Helper.status -ceq 'Exited') { return }
    if ($Helper.status -ceq 'Started' -and (Get-ClcNativeProcessObservation $Helper.processId $Helper.creationUtc) -ceq 'Exited') { return }
    Stop-ClcError Clc.HelperQuiescenceUnknown 'The application validator may still be running. Preserve the attempt and reconcile the process identity before recovery.'
}

function Invoke-ClcApplicationValidation {
    param($Context,$Attempt,$Paths,$Manifest,[string] $Root)
    $null=Get-ClcTreeInventory $Root $Manifest.files -RuntimeSid $Context.runtimeSid -Protected:($Root -ine $Context.layout.application)
    Assert-ClcEffectContext $Context
    $running=$null; $identity=$null
    $Attempt.helper=@{status='Intent';processId=$null;creationUtc=$null}
    Write-ClcLocalRecord $Paths.journal $Attempt -Replace
    try {
        $running=Start-ClcApplicationValidator $Context (Join-Path $Root $Manifest.validation.entryPoint)
        $identity=Get-ClcProcessIdentity $running.Process
        $Attempt.helper=@{status='Started';processId=$identity.processId;creationUtc=$identity.creationUtc}
        Write-ClcLocalRecord $Paths.journal $Attempt -Replace
        $output=Complete-ClcApplicationValidator $running
    } finally {
        if ($null -ne $running) {
            try {
                if ($null -ne $identity) {
                    $exitCode=Wait-ClcTrackedProcess $running.Process $identity.creationUtc 0 30000
                    $Attempt.helper=@{status='Exited';processId=$identity.processId;creationUtc=$identity.creationUtc}
                    Write-ClcLocalRecord $Paths.journal $Attempt -Replace
                }
            } finally { $running.Process.Dispose() }
        }
    }
    if ($output.Failed -or $exitCode -ne 0) { Stop-ClcError Clc.ConfigurationInvalid 'The application validator failed. Review application prerequisites and local configuration.' }
    try { $validation=Read-ClcJson $output.Bytes 'application-validation' }
    catch { Stop-ClcError Clc.ConfigurationInvalid 'The application validator did not return a valid deployment result.' }
    if (-not $validation.valid -or $validation.errorCodes.Count -ne 0 -or $validation.applicationId -cne $Manifest.applicationId -or
        $validation.releaseId -cne $Manifest.releaseId -or $validation.sourceCommit -cne $Manifest.source.commit -or
        $validation.runtimeEnvironment -cne $Context.environment) {
        Stop-ClcError Clc.ConfigurationInvalid 'The application validator rejected configuration or reported a different release, source or environment.'
    }
    Assert-ClcEffectContext $Context
    $null=Get-ClcTreeInventory $Root $Manifest.files -RuntimeSid $Context.runtimeSid -Protected:($Root -ine $Context.layout.application)
    return @{revision=$validation.configurationRevision;keyStoreCompatibilityId=$validation.keyStoreCompatibilityId;runtimeEnvironment=$validation.runtimeEnvironment}
}
function Invoke-ClcReadinessRequests {
    param([string[]] $Endpoints,[int] $Milliseconds)
    return [Clc.Lifecycle.V2.Native]::ProbeAll($Endpoints,$Milliseconds)
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
    param($Context,$Manifest,$Configuration,[string] $DiagnosticPath)
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $endpoints=$Context.bindings.endpoints
    $statuses=[ordered]@{}
    $ready=$false
    $verified=0
    do {
        $budget=[Math]::Min(5000,120000-$clock.ElapsedMilliseconds)
        if ($budget -le 0) { break }
        $responses=@(Invoke-ClcReadinessRequests $endpoints $budget)
        $verified=0
        for ($i=0; $i -lt $endpoints.Count; $i++) {
            $response=$responses[$i]
            $status=$response.Status
            if ($response.Accepted) {
                if (Test-ClcReadinessIdentity $response.Bytes $Manifest $Configuration) {
                    $status='Verified'
                    $verified++
                } else { $status='IdentityMismatch' }
            }
            $statuses[$endpoints[$i]]=$status
        }
        if ($verified -gt 0) {
            $iis=Get-ClcLiveIisState $Context
            $ready=$iis.siteState -ceq 'Started' -and $iis.poolState -ceq 'Started' -and $iis.workerCount -eq 1 -and $clock.ElapsedMilliseconds -lt 120000
            if ($ready) { break }
        }
        if ($clock.Elapsed.TotalSeconds -ge 113) { break }
        Start-Sleep -Milliseconds 2000
    } while ($clock.Elapsed.TotalSeconds -lt 115)
    $classifications=@{}
    foreach ($status in $statuses.Values) {
        if ($status -cne 'Verified') { $classifications[$status]++ }
    }
    $Context.readiness=@{verified=$verified;unsuccessful=$endpoints.Count-$verified;failures=$classifications}
    $evidence=@{configured=$Context.bindings.configured;valid=$Context.bindings.valid;counts=$Context.readiness;endpoints=$statuses}
    Write-ClcLocalBytes $DiagnosticPath ([Text.Encoding]::UTF8.GetBytes(($evidence | ConvertTo-Json -Depth 4)))
    if ($ready) { return $iis }
    Stop-ClcError Clc.ReadinessFailed 'Readiness did not report the expected release, source, environment and configuration with one IIS worker. Inspect local readiness diagnostics.'
}

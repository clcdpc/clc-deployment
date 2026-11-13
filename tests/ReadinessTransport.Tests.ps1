BeforeAll {
    . "$PSScriptRoot/Support.ps1"; . "$PSScriptRoot/T2Support.ps1"
    if ($null -eq ('Clc.Test.LocalHealthPeer' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Sockets;
using System.Net.Security;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Threading;
using System.Threading.Tasks;
namespace Clc.Test {
    public sealed class LocalHealthPeer : IDisposable {
        private TcpListener listener; private CancellationTokenSource cancel=new CancellationTokenSource(10000);
        private Task work; private X509Certificate2 certificate; private RSA key;
        public int Port; public bool ReceivedHttp;
        public LocalHealthPeer(bool tls) {
            listener=new TcpListener(IPAddress.Loopback,0); listener.Start(); Port=((IPEndPoint)listener.LocalEndpoint).Port;
            if (tls) {
                key=RSA.Create(2048);
                var request=new CertificateRequest("CN=clc-untrusted-loopback-fixture",key,HashAlgorithmName.SHA256,RSASignaturePadding.Pkcs1);
                var names=new SubjectAlternativeNameBuilder(); names.AddIpAddress(IPAddress.Loopback); request.CertificateExtensions.Add(names.Build());
                certificate=request.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-1),DateTimeOffset.UtcNow.AddMinutes(5));
            }
            work=Task.Run(async()=> {
                try {
                    using (var client=await listener.AcceptTcpClientAsync(cancel.Token)) {
                        if (!tls) { await Task.Delay(10000,cancel.Token); return; }
                        using (var stream=new SslStream(client.GetStream(),false)) {
                            await stream.AuthenticateAsServerAsync(new SslServerAuthenticationOptions {
                                ServerCertificate=certificate,ClientCertificateRequired=false,EnabledSslProtocols=SslProtocols.Tls12|SslProtocols.Tls13
                            },cancel.Token);
                            var bytes=new byte[4096]; int count=await stream.ReadAsync(bytes,cancel.Token); ReceivedHttp=count>0;
                        }
                    }
                } catch (OperationCanceledException) {} catch (AuthenticationException) {} catch (System.IO.IOException) {} catch (ObjectDisposedException) {}
            });
        }
        public void Dispose() {
            cancel.Cancel(); listener.Stop();
            try { if (!work.Wait(6000)) throw new System.IO.IOException("Owned loopback peer did not exit."); }
            finally { certificate?.Dispose(); key?.Dispose(); cancel.Dispose(); }
        }
    }
}
'@
    }
}
Describe 'Production HTTPS client against bounded test-owned loopback peers without IIS or trust-store changes' {
    It 'rejects a self-signed loopback TLS certificate before sending application HTTP' {
        $peer=[Clc.Test.LocalHealthPeer]::new($true)
        try {
            $response=Invoke-T2Private Invoke-ClcReadinessRequest @('https://127.0.0.1:'+$peer.Port+'/health/ready')
            $response.Accepted | Should -BeFalse; $response.Bytes.Length | Should -Be 0
        } finally { $peer.Dispose() }
        $peer.ReceivedHttp | Should -BeFalse
    }
    It 'cancels an unresponsive loopback TLS peer within the fixed per-request budget' {
        $peer=[Clc.Test.LocalHealthPeer]::new($false); $clock=[Diagnostics.Stopwatch]::StartNew()
        try {
            $response=Invoke-T2Private Invoke-ClcReadinessRequest @('https://127.0.0.1:'+$peer.Port+'/health/ready')
            $response.Accepted | Should -BeFalse; $response.Bytes.Length | Should -Be 0
            $clock.Elapsed.TotalSeconds | Should -BeLessThan 12
        } finally { $peer.Dispose() }
    }
}

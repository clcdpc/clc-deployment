BeforeAll {
    . "$PSScriptRoot/Support.ps1"
    function New-TestBinding([string] $Dns='portal.example.org',[int] $Port=443,[string] $Address='0.0.0.0') {
        @{Protocol='https';Host=$Dns;EndPoint=[Net.IPEndPoint]::new([ipaddress]$Address,$Port);SslFlags=1;
            CertificateHash=[byte[]](1,2,3);CertificateStoreName='My'}
    }
}
Describe 'Managed HTTPS binding discovery' {
    BeforeEach {
        $first=New-TestBinding
        $alias=New-TestBinding 'ALIAS.example.org'
        $site=@{Name='Managed';Bindings=@($first)}
        $other=@{Name='Other';Bindings=@()}
        $manager=@{Sites=@($site,$other)}
        Mock Test-ClcBindingCertificate -ModuleName Clc.Deployment { $true }
    }
    It 'derives sorted canonical endpoints and an order-independent snapshot' {
        $single=Invoke-TestPrivate Get-ClcIisBindingSnapshot @($manager,$site)
        $single.valid | Should -Be 1
        $internal=New-TestBinding 'internal.example.org' 8443
        $site.Bindings=@($internal,$first,$alias)
        $snapshot=Invoke-TestPrivate Get-ClcIisBindingSnapshot @($manager,$site)
        $snapshot.findings | Should -BeNullOrEmpty
        $snapshot.valid | Should -Be 3
        $snapshot.endpoints | Should -Be @('https://alias.example.org/health/ready','https://internal.example.org:8443/health/ready','https://portal.example.org/health/ready')
        [array]::Reverse($site.Bindings)
        (Invoke-TestPrivate Get-ClcIisBindingSnapshot @($manager,$site)).signature | Should -BeExactly $snapshot.signature
        $alias.CertificateHash=[byte[]](4,5,6)
        (Invoke-TestPrivate Get-ClcIisBindingSnapshot @($manager,$site)).signature | Should -Not -BeExactly $snapshot.signature
    }
    It 'blocks an invalid binding even with a healthy primary for <_>' -ForEach @(
        'NoBindings','Empty','Wildcard','Ip','Http','CentralStore','StoreName','NoCertificate','Duplicate','NoSni','OtherName',
        'WildcardAddress','MappedAddress','WildcardHostname','ExplicitAddress','HostlessFallback','TooMany'
    ) {
        $case=$_
        $site.Bindings=@($first,$alias)
        switch ($case) {
            NoBindings { $site.Bindings=@() }
            Empty { $alias.Host='' }
            Wildcard { $alias.Host='*.example.org' }
            Ip { $alias.Host='127.0.0.1' }
            Http { $alias.Protocol='http' }
            CentralStore { $alias.SslFlags=3 }
            StoreName { $alias.CertificateStoreName='../My' }
            NoCertificate { $alias.CertificateHash=$null }
            Duplicate { $alias.Host='PORTAL.example.org.' }
            NoSni { $alias.SslFlags=0 }
            OtherName { $other.Bindings=@(New-TestBinding 'PORTAL.EXAMPLE.ORG') }
            WildcardAddress { $other.Bindings=@(New-TestBinding 'other.example.org' 443 '10.0.0.1'); $other.Bindings[0].SslFlags=0 }
            MappedAddress {
                $first.EndPoint=[Net.IPEndPoint]::new([ipaddress]'10.0.0.1',443)
                $site.Bindings=@($first)
                $other.Bindings=@(New-TestBinding 'other.example.org' 443 '::ffff:10.0.0.1')
                $other.Bindings[0].SslFlags=0
            }
            WildcardHostname { $other.Bindings=@(New-TestBinding '*.example.org') }
            ExplicitAddress { $first.EndPoint=[Net.IPEndPoint]::new([ipaddress]'10.0.0.1',443);$other.Bindings=@(New-TestBinding $first.Host 443 '10.0.0.2') }
            HostlessFallback { $other.Bindings=@(New-TestBinding '') }
            TooMany { $site.Bindings=@($first)*17 }
        }
        (Invoke-TestPrivate Get-ClcIisBindingSnapshot @($manager,$site)).findings.code | Should -Contain 'Clc.HttpsBinding'
    }
    It 'allows distinct dedicated addresses or noncompeting SNI names' {
        $other.Bindings=@(New-TestBinding 'other.example.org')
        (Invoke-TestPrivate Get-ClcIisBindingSnapshot @($manager,$site)).valid | Should -Be 1
        $site.Bindings=@(New-TestBinding 'portal.example.org' 443 '10.0.0.1')
        $other.Bindings=@(New-TestBinding 'other.example.org' 443 '10.0.0.2')
        $other.Bindings[0].SslFlags=0
        (Invoke-TestPrivate Get-ClcIisBindingSnapshot @($manager,$site)).findings | Should -BeNullOrEmpty
    }
    It 'checks certificate dates, private key and SAN using in-memory certificates' {
        $key=[Security.Cryptography.RSA]::Create(2048)
        $request=[Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=fixture',$key,'SHA256',[Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $san=[Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
        $san.AddDnsName($first.Host)
        $request.CertificateExtensions.Add($san.Build())
        $now=[DateTimeOffset]::UtcNow
        $valid=$request.CreateSelfSigned($now.AddDays(-1),$now.AddDays(1))
        $expired=$request.CreateSelfSigned($now.AddDays(-2),$now.AddDays(-1))
        $public=[Security.Cryptography.X509Certificates.X509CertificateLoader]::LoadCertificate($valid.RawData)
        try {
            $chain=[Security.Cryptography.X509Certificates.X509Chain]::new($true)
            try {
                Invoke-TestPrivate Test-ClcBindingTrust @($valid,$chain) | Should -BeFalse
                $chain.Reset()
                $chain.ChainPolicy.TrustMode='CustomRootTrust'
                $chain.ChainPolicy.CustomTrustStore.Add($public)
                Invoke-TestPrivate Test-ClcBindingTrust @($valid,$chain) | Should -BeTrue
            } finally { $chain.Dispose() }
            Invoke-TestPrivate Test-ClcCertificateIdentity @($valid,$first.Host) | Should -BeTrue
            Invoke-TestPrivate Test-ClcCertificateIdentity @($valid,$alias.Host) | Should -BeFalse
            Invoke-TestPrivate Test-ClcCertificateIdentity @($expired,$first.Host) | Should -BeFalse
            Invoke-TestPrivate Test-ClcCertificateIdentity @($public,$first.Host) | Should -BeFalse
        } finally { $public.Dispose();$expired.Dispose();$valid.Dispose();$key.Dispose() }
    }
}

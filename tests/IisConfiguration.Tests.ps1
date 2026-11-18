
BeforeAll {
    . "$PSScriptRoot/Support.ps1"
    if ($null -eq ('Clc.Test.IisConfiguration' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
namespace Clc.Test {
    public sealed class IisConfiguration {
        public readonly NamedSites Sites = new();
        public readonly NamedPools ApplicationPools = new();
        public readonly Elements SiteElements = new();
        public IisConfiguration GetApplicationHostConfiguration() => this;
        public IisConfiguration GetSection(string name) {
            if (name != "system.applicationHost/sites") throw new ArgumentException();
            return this;
        }
        public Elements GetCollection() => SiteElements;
    }
    public sealed class NamedSites : List<Site> {
        public Site this[string name] => Find(site => site.Name.Equals(name,StringComparison.OrdinalIgnoreCase));
    }
    public sealed class Site {
        public string Name {get;set;}
        public long Id {get;set;}
    }
    public sealed class NamedPools : List<Pool> {
        public Pool this[string name] => Find(pool => pool.Name.Equals(name,StringComparison.OrdinalIgnoreCase));
        public Pool Add(string name) { var pool = new Pool {Name=name}; base.Add(pool); return pool; }
    }
    public sealed class Pool {
        public string Name {get;set;}
        public bool AutoStart {get;set;} = true;
        public string ManagedRuntimeVersion {get;set;} = "v4.0";
        public string ManagedPipelineMode {get;set;} = "Classic";
        public bool Enable32BitAppOnWin64 {get;set;} = true;
        public ProcessModel ProcessModel {get;} = new();
        public Recycling Recycling {get;} = new();
    }
    public sealed class ProcessModel {
        public int MaxProcesses {get;set;} = 3;
        public bool LoadUserProfile {get;set;}
        public string IdentityType {get;set;} = "LocalSystem";
    }
    public sealed class Recycling { public bool DisallowOverlappingRotation {get;set;} }
    public sealed class Elements : List<Element> {
        public Element CreateElement(string name) => new(name);
    }
    public sealed class Element {
        private readonly Dictionary<string,object> fields = new();
        private readonly Elements children = new();
        private readonly Elements bindings = new();
        public Element(string name) {
            if (name == "site") {
                var inherited = new Element("binding");
                inherited["protocol"]="http";
                bindings.Add(inherited);
            }
        }
        public object this[string name] {get => fields[name];set => fields[name]=value;}
        public Elements GetCollection() => children;
        public Elements GetCollection(string name) {
            if (name != "bindings") throw new ArgumentException();
            return bindings;
        }
    }
}
'@
    }
}
Describe 'IIS scaffold configuration construction' {
    BeforeEach {
        $manager=[Clc.Test.IisConfiguration]::new()
        $manager.Sites.Add([Clc.Test.Site]@{Name='Unrelated site';Id=1})
        $null=$manager.ApplicationPools.Add('Unrelated.Pool')
        $target=@{siteName='Probe Dev';applicationPoolName='Probe.Dev';applicationRoot='D:\NativeData\clc-probe\Application'}
        Mock Assert-ClcIisPhysicalIsolation -ModuleName Clc.Deployment {}
    }

    It 'creates one stopped-by-configuration site and pool with inherited bindings cleared' {
        Invoke-TestPrivate Add-ClcIisResources @($manager,$target)
        $site=$manager.SiteElements[0]
        $site['id'] | Should -Be 2
        $site['name'] | Should -Be 'Probe Dev'
        $site['serverAutoStart'] | Should -BeFalse
        $site.GetCollection('bindings').Count | Should -Be 0
        $app=$site.GetCollection()[0]
        $app['path'] | Should -Be '/'
        $app['applicationPool'] | Should -Be 'Probe.Dev'
        $root=$app.GetCollection()[0]
        $root['path'] | Should -Be '/'
        $root['physicalPath'] | Should -BeExactly $target.applicationRoot
        $pool=$manager.ApplicationPools['Probe.Dev']
        $pool.AutoStart | Should -BeFalse
        $pool.ProcessModel.IdentityType | Should -Be 'ApplicationPoolIdentity'
        (Invoke-TestPrivate Test-ClcIisPoolSettings @($pool)) | Should -BeTrue
        $manager.Sites[0].Name | Should -Be 'Unrelated site'
        $manager.ApplicationPools['Unrelated.Pool'].AutoStart | Should -BeTrue
    }

    It 'does not build a scaffold over an existing site or pool name' {
        $target.siteName='Unrelated site'
        { Invoke-TestPrivate Add-ClcIisResources @($manager,$target) } | Should -Throw -ErrorId 'Clc.IisConflict*'
        $manager.SiteElements.Count | Should -Be 0
        $manager.ApplicationPools.Count | Should -Be 1
    }
}

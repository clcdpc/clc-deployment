Set-StrictMode -Version Latest; $ErrorActionPreference='Stop'
if ($null -eq ('Clc.Probe.Metadata' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Collections.Generic;
using System.Reflection.Metadata;
using System.Reflection.PortableExecutable;
namespace Clc.Probe {
 public static class Metadata {
  public static Dictionary<string,string> Read(string path) {
   using(var file=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.Read)) {
    if(file.Length>268435456) throw new IOException("Metadata bound.");
    using(var pe=new PEReader(file)) {
     var reader=pe.GetMetadataReader(); var result=new Dictionary<string,string>(StringComparer.Ordinal);
     foreach(var handle in reader.GetAssemblyDefinition().GetCustomAttributes()) {
      var attribute=reader.GetCustomAttribute(handle);
      if(attribute.Constructor.Kind!=HandleKind.MemberReference) continue;
      var constructor=reader.GetMemberReference((MemberReferenceHandle)attribute.Constructor);
      if(constructor.Parent.Kind!=HandleKind.TypeReference) continue;
      var type=reader.GetTypeReference((TypeReferenceHandle)constructor.Parent);
      if(reader.GetString(type.Namespace)!="System.Reflection" || reader.GetString(type.Name)!="AssemblyMetadataAttribute") continue;
      var blob=reader.GetBlobReader(attribute.Value); if(blob.ReadUInt16()!=1) throw new IOException("Invalid metadata.");
      var key=blob.ReadSerializedString(); var value=blob.ReadSerializedString();
      if(key==null || value==null || value.Length>256 || !result.TryAdd(key,value)) throw new IOException("Invalid metadata.");
     }
     return result;
    }
   }
  }
 }
}
'@
}
function Get-ProbeEmbeddedMetadata([string] $Path) { [Clc.Probe.Metadata]::Read($Path) }

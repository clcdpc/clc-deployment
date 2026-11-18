function Get-ClcCallerSid {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { return $identity.User.Value } finally { $identity.Dispose() }
}

function Test-ClcAdministratorToken {
    # IsInRole tests the enabled role in THIS token. A deny-only Administrators
    # SID in a UAC-filtered token is not admission. Never attempt self-elevation.
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { return [Security.Principal.WindowsPrincipal]::new($identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
    finally { $identity.Dispose() }
}

function Get-ClcSecurityObservation {
    param([string] $Path)
    try {
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        $bytes = $acl.GetSecurityDescriptorBinaryForm()
        $raw = [Security.AccessControl.RawSecurityDescriptor]::new($bytes,0)
        if ($null -eq $raw.DiscretionaryAcl -or -not $acl.AreAccessRulesCanonical) { Stop-ClcError Clc.HostPreflightFailed }
        foreach ($ace in $raw.DiscretionaryAcl) {
            if ($ace -isnot [Security.AccessControl.CommonAce] -or $ace.IsCallback -or
                $ace.AceQualifier -notin @([Security.AccessControl.AceQualifier]::AccessAllowed,[Security.AccessControl.AceQualifier]::AccessDenied)) { Stop-ClcError Clc.HostPreflightFailed }
        }
        return @{ ownerSid=$raw.Owner.Value; sha256=(Get-ClcBytesHash $bytes); bytes=$bytes; dacl=$raw.DiscretionaryAcl }
    } catch { Stop-ClcError Clc.HostPreflightFailed }
}

function Get-ClcEffectiveAccess {
    param([byte[]] $Descriptor, [string] $Sid)
    try { return [long][Clc.Host.Native]::AccessBounded($Descriptor,$Sid,($Sid -ceq (Get-ClcCallerSid))) }
    catch { Stop-ClcError Clc.HostPreflightFailed }
}

function Assert-ClcAccess {
    param([string] $Path, [string[]] $Owners, [string[]] $Writers, [string[]] $Readers,
        [string[]] $DeniedWriters = @(), [long] $ReadMask = 0x120089, [long] $WriteMask = 0, $Cache = $null)
    try {
    $security = Get-ClcSecurityObservation $Path
    if ($null -ne $Cache -and $Cache.Contains($security.sha256)) { return $security.sha256 }
    if ($Owners -cnotcontains $security.ownerSid) { Stop-ClcError Clc.HostPreflightFailed }
    # Conservatively refuse unknown writable trustees, even when a deny happens to mask them.
    # This also avoids treating omitted logon groups as proof of runtime non-write access.
    $mutationMask = 0x000D0156L # data/append/EA/attributes/delete-child/delete/DACL/owner
    foreach ($ace in $security.dacl) {
        if ($ace.AceQualifier -eq [Security.AccessControl.AceQualifier]::AccessAllowed -and
            (([long]$ace.AccessMask -band $mutationMask) -ne 0 -or ([long]$ace.AccessMask -band 0xF0000000L) -ne 0) -and
            $Writers -cnotcontains $ace.SecurityIdentifier.Value) { Stop-ClcError Clc.HostPreflightFailed }
    }
    foreach ($sid in $Readers) {
        $mask = Get-ClcEffectiveAccess $security.bytes $sid
        if (($mask -band $ReadMask) -ne $ReadMask) { Stop-ClcError Clc.HostPreflightFailed }
    }
    foreach ($sid in $DeniedWriters) {
        if (((Get-ClcEffectiveAccess $security.bytes $sid) -band $mutationMask) -ne 0 -or $security.ownerSid -ceq $sid) { Stop-ClcError Clc.HostPreflightFailed }
    }
    if ($WriteMask -ne 0 -and ((Get-ClcEffectiveAccess $security.bytes (Get-ClcCallerSid)) -band $WriteMask) -ne $WriteMask) { Stop-ClcError Clc.HostPreflightFailed }
    if ($null -ne $Cache) { $null=$Cache.Add($security.sha256) }
    return $security.sha256
    } catch { Stop-ClcError Clc.HostPreflightFailed }
}

function Read-ClcHeldFile {
    param([string] $Path, [Collections.Generic.List[IDisposable]] $Handles, [long] $Limit = 4194304, [switch] $SystemFile, [switch] $NoCapture, [switch] $Temporary,
        [Diagnostics.Stopwatch] $Clock=$null, [int] $Seconds=300)
    if ($null -eq $Clock) { $Clock=[Diagnostics.Stopwatch]::StartNew() }
    $facts = Get-ClcPathObservation $Path $Handles -SystemFile:$SystemFile -Temporary:$Temporary
    $stream = Open-ClcReadFile $Path $facts $Handles
    $digest = Read-ClcStream $stream $Limit $Clock -Capture:(-not $NoCapture) -Seconds $Seconds
    $stream.Position = 0
    return @{ path=$Path; facts=$facts; stream=$stream; bytes=$digest.bytes; sha256=$digest.sha256 }
}

# Contract validators consume untrusted data. They check data shapes and bounds.
function Stop-ClcError {
    [CmdletBinding()]
    param([string] $Code, [string] $Message = 'Input rejected by the deployment contract.')
    $record = [Management.Automation.ErrorRecord]::new(
        [IO.InvalidDataException]::new($Message), $Code,
        [Management.Automation.ErrorCategory]::InvalidData, $null)
    $PSCmdlet.ThrowTerminatingError($record)
}

function ConvertFrom-ClcJsonElement {
    param([System.Text.Json.JsonElement] $Element)
    switch ($Element.ValueKind) {
        Object {
            $keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            $value = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
            foreach ($property in $Element.EnumerateObject()) {
                if (-not $keys.Add($property.Name)) { Stop-ClcError Clc.InvalidContract }
                $value.Add($property.Name, (ConvertFrom-ClcJsonElement $property.Value))
            }
            return ,$value
        }
        Array {
            $value = [Collections.Generic.List[object]]::new()
            foreach ($item in $Element.EnumerateArray()) { $value.Add((ConvertFrom-ClcJsonElement $item)) }
            return ,$value.ToArray()
        }
        String { return $Element.GetString() }
        Number {
            $value = 0L
            if (-not $Element.TryGetInt64([ref] $value)) { Stop-ClcError Clc.InvalidContract }
            return $value
        }
        True { return $true }
        False { return $false }
        Null { return $null }
        default { Stop-ClcError Clc.InvalidContract }
    }
}

function Read-ClcJson {
    param([byte[]] $Bytes, [string] $Kind, [int] $MaxBytes = 4194304)
    if ($Kind -ceq 'application-validation') { $MaxBytes = [Math]::Min($MaxBytes,8192) }
    if ($Kind -ceq 'readiness') { $MaxBytes = [Math]::Min($MaxBytes,4096) }
    if ($Bytes.Length -eq 0 -or $Bytes.Length -gt $MaxBytes) { Stop-ClcError Clc.InvalidContract }
    $document = $null
    try {
        # JsonDocument preserves duplicate properties; check them BEFORE deserialization.
        $utf8 = [Text.UTF8Encoding]::new($false, $true)
        $json = $utf8.GetString($Bytes)
        $options = [Text.Json.JsonDocumentOptions]::new()
        $options.MaxDepth = 32
        $document = [Text.Json.JsonDocument]::Parse($json, $options)
        $value = ConvertFrom-ClcJsonElement $document.RootElement
        Assert-ClcRecord $value $Kind
        return ,$value
    } catch {
        if ($_.FullyQualifiedErrorId -like 'Clc.*') { throw }
        Stop-ClcError Clc.InvalidContract
    } finally { if ($null -ne $document) { $document.Dispose() } }
}

function Assert-ClcObject {
    param($Value, [string[]] $Keys)
    if ($Value -isnot [Collections.IDictionary] -or $Value.Count -ne $Keys.Count) { Stop-ClcError Clc.InvalidContract }
    foreach ($key in $Keys) {
        if (-not (@($Value.Keys) -ccontains $key)) { Stop-ClcError Clc.InvalidContract }
    }
}

function Assert-ClcText {
    param($Value, [int] $Max = 256, [string] $Pattern = '^[^\x00-\x1f\x7f]+$')
    if ($Value -isnot [string] -or $Value.Length -eq 0 -or $Value.Length -gt $Max -or $Value -cnotmatch $Pattern) {
        Stop-ClcError Clc.InvalidContract
    }
    for ($i=0;$i -lt $Value.Length;$i++) {
        if ([char]::IsControl($Value[$i])) { Stop-ClcError Clc.InvalidContract }
        if ([char]::IsHighSurrogate($Value[$i])) {
            if ($i+1 -ge $Value.Length -or -not [char]::IsLowSurrogate($Value[$i+1])) { Stop-ClcError Clc.InvalidContract }
            $i++
        } elseif ([char]::IsLowSurrogate($Value[$i])) { Stop-ClcError Clc.InvalidContract }
    }
}

function Assert-ClcInteger {
    param($Value, [long] $Min = 0, [long] $Max = [long]::MaxValue)
    if (($Value -isnot [long] -and $Value -isnot [int]) -or $Value -lt $Min -or $Value -gt $Max) { Stop-ClcError Clc.InvalidContract }
}

function Assert-ClcBoolean {
    param($Value)
    if ($Value -isnot [bool]) { Stop-ClcError Clc.InvalidContract }
}

function Assert-ClcEnum {
    param($Value, [string[]] $Allowed)
    if ($Value -isnot [string] -or $Allowed -cnotcontains $Value) { Stop-ClcError Clc.InvalidContract }
}

function Assert-ClcId { param($Value) Assert-ClcText $Value 64 '^[a-z0-9][a-z0-9-]{0,63}$' }
function Assert-ClcHash { param($Value) Assert-ClcText $Value 64 '^[a-f0-9]{64}$' }
function Assert-ClcCommit { param($Value) Assert-ClcText $Value 40 '^[a-f0-9]{40}$' }
function Assert-ClcCode { param($Value, [int] $Max = 128) Assert-ClcText $Value $Max '^[A-Za-z0-9][A-Za-z0-9_.-]*$' }

function Assert-ClcGuid {
    param($Value, [switch] $Machine)
    Assert-ClcText $Value 36 '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$'
    if ($Value -ceq '00000000-0000-0000-0000-000000000000' -or ($Machine -and $Value -ceq 'ffffffff-ffff-ffff-ffff-ffffffffffff')) {
        Stop-ClcError Clc.InvalidContract
    }
}

function Assert-ClcTimestamp {
    param($Value, [switch] $Native)
    $pattern = '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,7})?Z$'
    if ($Native) { $pattern = '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$' }
    Assert-ClcText $Value 28 $pattern
    $stamp = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($Value, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None, [ref] $stamp) -or ($Native -and $stamp.Year -lt 1601)) { Stop-ClcError Clc.InvalidContract }
}

function Assert-ClcVersion {
    param($Value)
    Assert-ClcText $Value 256 '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'
}

function Assert-ClcRepository { param($Value) Assert-ClcText $Value 256 '^[A-Za-z0-9_-]+/[A-Za-z0-9_-][A-Za-z0-9_.-]*$' }
function Assert-ClcWorkflow {
    param($Value)
    Assert-ClcText $Value 240 '^\.github/workflows/[A-Za-z0-9_-][A-Za-z0-9_.-]*\.ya?ml$'
}
function Assert-ClcAbsolutePath {
    param($Value)
    Assert-ClcText $Value 240 '^[A-Za-z]:\\[^\x00-\x1f\x7f/:*?"<>|]+$'
    if ($Value.Contains('~') -or $Value.EndsWith('\')) { Stop-ClcError Clc.InvalidContract }
    foreach ($part in $Value.Substring(3).Split('\')) { Assert-ClcPathComponent $part Clc.InvalidContract }
}
function Assert-ClcSid {
    param($Value)
    Assert-ClcText $Value 184 '^S-1-(0|[1-9][0-9]*)(-(0|[1-9][0-9]*)){1,15}$'
    try {
        $sid = [Security.Principal.SecurityIdentifier]::new($Value)
        if ($sid.Value -cne $Value) { Stop-ClcError Clc.InvalidContract }
    } catch { Stop-ClcError Clc.InvalidContract }
}
function Assert-ClcPackage {
    param($Value, [switch] $Manifest)
    $keys = @('contractFamily','schemaVersion','recordKind','applicationId','targetId','releaseId','source','build','builder','runtime','changeKind','validation','readinessContractVersion')
    if ($Manifest) { $keys += 'files','inventorySha256' }
    Assert-ClcObject $Value $keys
    Assert-ClcId $Value.applicationId
    if ($null -ne $Value.targetId) { Assert-ClcId $Value.targetId }
    Assert-ClcId $Value.releaseId
    Assert-ClcObject $Value.source @('repository','commit')
    Assert-ClcRepository $Value.source.repository
    Assert-ClcCommit $Value.source.commit
    Assert-ClcObject $Value.build @('workflowPath','runId','runAttempt','job','sdkVersion','dependencyLockSha256')
    Assert-ClcWorkflow $Value.build.workflowPath
    Assert-ClcInteger $Value.build.runId 1
    Assert-ClcInteger $Value.build.runAttempt 1
    Assert-ClcCode $Value.build.job
    Assert-ClcVersion $Value.build.sdkVersion
    if ($null -ne $Value.build.dependencyLockSha256) { Assert-ClcHash $Value.build.dependencyLockSha256 }
    Assert-ClcEnum $Value.builder.module @('Clc.Deployment')
    Assert-ClcVersion $Value.builder.version
    Assert-ClcCommit $Value.builder.sourceCommit
    Assert-ClcHash $Value.builder.distributionSha256
    Assert-ClcObject $Value.runtime @('framework','rid','architecture','hostingModel','workerLimit')
    Assert-ClcEnum $Value.runtime.framework @('net10.0')
    Assert-ClcEnum $Value.runtime.rid @('win-x64')
    Assert-ClcEnum $Value.runtime.architecture @('x64')
    Assert-ClcEnum $Value.runtime.hostingModel @('inprocess')
    Assert-ClcInteger $Value.runtime.workerLimit 1 1
    Assert-ClcEnum $Value.changeKind @('files-only')
    Assert-ClcObject $Value.validation @('contractVersion','entryPoint')
    Assert-ClcInteger $Value.validation.contractVersion 1 1
    Assert-ClcText $Value.validation.entryPoint 240 '^[A-Za-z0-9_-][A-Za-z0-9_.-]*\.dll$'
    Assert-ClcPathComponent $Value.validation.entryPoint Clc.InvalidContract
    Assert-ClcInteger $Value.readinessContractVersion 1 1
    if ($Manifest) {
        Assert-ClcFiles $Value.files
        Assert-ClcHash $Value.inventorySha256
        if ($Value.inventorySha256 -cne (Get-ClcInventoryHash $Value.files)) { Stop-ClcError Clc.HashMismatch }
        if (@($Value.files.path) -cnotcontains ('application/' + $Value.validation.entryPoint)) { Stop-ClcError Clc.InvalidContract }
    }
}

function Assert-ClcFiles {
    param($Value)
    if ($Value -isnot [object[]] -or $Value.Count -gt 19999) { Stop-ClcError Clc.InvalidContract }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $prior = $null
    $total = 0L
    foreach ($file in $Value) {
        Assert-ClcObject $file @('path','length','sha256')
        Assert-ClcArchiveName $file.path -PayloadOnly
        if (-not $seen.Add($file.path) -or ($null -ne $prior -and [StringComparer]::Ordinal.Compare($prior, $file.path) -ge 0)) { Stop-ClcError Clc.InvalidContract }
        foreach ($prefix in (Get-ClcNamePrefixes $file.path)) { if ($seen.Contains($prefix)) { Stop-ClcError Clc.InvalidContract } }
        Assert-ClcInteger $file.length 0 268435456
        Assert-ClcHash $file.sha256
        $total += $file.length
        if ($total -gt 1073741824) { Stop-ClcError Clc.InvalidContract }
        $prior = $file.path
    }
}

function Assert-ClcRecord {
    param($Value, [string] $Kind)
    if ($Kind -cin @('application-validation','readiness')) {
        $keys = @('applicationId','releaseId','sourceCommit','runtimeEnvironment','configurationRevision')
        if ($Kind -ceq 'readiness') { $keys += 'readinessContractVersion','status' }
        else { $keys += 'validationContractVersion','valid','keyStoreCompatibilityId','errorCodes' }
        Assert-ClcObject $Value $keys
        Assert-ClcId $Value.applicationId
        Assert-ClcId $Value.releaseId
        Assert-ClcCommit $Value.sourceCommit
        Assert-ClcEnum $Value.runtimeEnvironment @('Production','Staging')
        Assert-ClcCode $Value.configurationRevision 64
        if ($Kind -ceq 'readiness') {
            Assert-ClcInteger $Value.readinessContractVersion 1 1
            Assert-ClcEnum $Value.status @('ready')
        } else {
            Assert-ClcInteger $Value.validationContractVersion 1 1
            Assert-ClcBoolean $Value.valid
            Assert-ClcCode $Value.keyStoreCompatibilityId 128
            if ($Value.errorCodes -isnot [object[]] -or $Value.errorCodes.Count -gt 128) { Stop-ClcError Clc.InvalidContract }
            foreach ($code in $Value.errorCodes) { Assert-ClcCode $code }
        }
        return
    }
    if ($Kind -cin @('release-metadata','release-manifest')) {
        if ($Value -isnot [Collections.IDictionary] -or -not $Value.Contains('contractFamily') -or
            -not $Value.Contains('schemaVersion') -or -not $Value.Contains('recordKind') -or
            $Value.contractFamily -cne 'clc-iis-release' -or $Value.schemaVersion -isnot [long] -or
            $Value.schemaVersion -ne 3 -or $Value.recordKind -cne $Kind) { Stop-ClcError Clc.UnsupportedContract }
        Assert-ClcPackage $Value -Manifest:($Kind -ceq 'release-manifest')
        return
    }
    Assert-ClcHostRecord $Value $Kind
}

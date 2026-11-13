# Contract validators consume untrusted data. They never resolve policy or grant authority.
function Stop-ClcError {
    [CmdletBinding()]
    param([string] $Code, [string] $Message = 'Input rejected by the foundation contract.')
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
function Assert-ClcSids {
    param($Value)
    if ($Value -isnot [object[]] -or $Value.Count -lt 1 -or $Value.Count -gt 128) { Stop-ClcError Clc.InvalidContract }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($sid in $Value) { Assert-ClcSid $sid; if (-not $seen.Add($sid)) { Stop-ClcError Clc.InvalidContract } }
}

function Assert-ClcToolkit {
    param($Value, [switch] $Active)
    $keys = @('version','sourceCommit','distributionSha256','inventorySha256')
    if ($Active) { $keys += 'moduleManifestPath' }
    Assert-ClcObject $Value $keys
    Assert-ClcVersion $Value.version
    Assert-ClcCommit $Value.sourceCommit
    Assert-ClcHash $Value.distributionSha256
    Assert-ClcHash $Value.inventorySha256
    if ($Active) { Assert-ClcAbsolutePath $Value.moduleManifestPath }
}

function Assert-ClcPackage {
    param($Value, [switch] $Manifest)
    $keys = @('contractFamily','schemaVersion','recordKind','applicationId','releaseId','source','build','builder','runtime','changeKind','validation','readinessContractVersion')
    if ($Manifest) { $keys += 'files','inventorySha256' }
    Assert-ClcObject $Value $keys
    Assert-ClcId $Value.applicationId
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
    Assert-ClcHash $Value.build.dependencyLockSha256
    Assert-ClcObject $Value.builder @('module','version','sourceCommit','distributionSha256')
    Assert-ClcEnum $Value.builder.module @('CLC.Deployment')
    Assert-ClcVersion $Value.builder.version
    Assert-ClcCommit $Value.builder.sourceCommit
    Assert-ClcHash $Value.builder.distributionSha256
    Assert-ClcObject $Value.runtime @('framework','rid','architecture','hostingModel','workerLimit')
    Assert-ClcText $Value.runtime.framework 32 '^net[1-9][0-9]*\.[0-9]+$'
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

function Assert-ClcApprovalSnapshot {
    param($Value)
    Assert-ClcObject $Value @('approvalId','sha256','lineageId','releaseSequence')
    Assert-ClcId $Value.approvalId
    Assert-ClcHash $Value.sha256
    Assert-ClcId $Value.lineageId
    Assert-ClcInteger $Value.releaseSequence 1
}
function Assert-ClcReleaseIdentity {
    param($Value)
    Assert-ClcObject $Value @('approvalId','applicationId','releaseId','sourceCommit','archiveSha256','manifestSha256','inventorySha256')
    foreach ($key in @('approvalId','applicationId','releaseId')) { Assert-ClcId $Value[$key] }
    Assert-ClcCommit $Value.sourceCommit
    foreach ($key in @('archiveSha256','manifestSha256','inventorySha256')) { Assert-ClcHash $Value[$key] }
}
function Assert-ClcConfiguration {
    param($Value)
    Assert-ClcObject $Value @('privateSha256','revision','keyStoreCompatibilityId','runtimeEnvironment')
    Assert-ClcHash $Value.privateSha256
    Assert-ClcCode $Value.revision 64
    Assert-ClcCode $Value.keyStoreCompatibilityId 128
    Assert-ClcEnum $Value.runtimeEnvironment @('Production','Staging')
}
function Assert-ClcTargetSnapshot {
    param($Value)
    Assert-ClcObject $Value @('machineIdentity','siteName','applicationPoolName','rootIdentities')
    Assert-ClcGuid $Value.machineIdentity -Machine
    Assert-ClcText $Value.siteName
    Assert-ClcText $Value.applicationPoolName 64 '^[A-Za-z0-9_.-]{1,64}$'
    Assert-ClcObject $Value.rootIdentities @('applicationRoot','operationalConfigPath','dataProtectionRoot','controlRoot','artifactInboxRoot')
    foreach ($identity in $Value.rootIdentities.Values) {
        Assert-ClcObject $identity @('volumeId','fileId','canonicalPath')
        Assert-ClcText $identity.volumeId 49 '^\\\\\?\\volume\{[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\}\\$'
        Assert-ClcText $identity.fileId 16 '^[a-f0-9]{16}$'
        Assert-ClcAbsolutePath $identity.canonicalPath
    }
}
function Assert-ClcReadySnapshot {
    param($Value)
    Assert-ClcObject $Value @('releaseId','sourceCommit','runtimeEnvironment','configurationRevision','checkedUtc')
    Assert-ClcId $Value.releaseId
    Assert-ClcCommit $Value.sourceCommit
    Assert-ClcEnum $Value.runtimeEnvironment @('Production','Staging')
    Assert-ClcCode $Value.configurationRevision 64
    Assert-ClcTimestamp $Value.checkedUtc
}

function Assert-ClcJournal {
    param($Value)
    Assert-ClcObject $Value @('contractFamily','schemaVersion','recordKind','attemptId','targetKey','targetSnapshot','executingToolkit','policyGeneration','policySha256','approvalSnapshot','candidate','previous','initialPoolState','initialTargetEmpty','phase','outcome','liveMutationIntent','intent','observation','nativeCall','configuration','backup','recovery','publishedGeneration','createdUtc','updatedUtc','failure')
    Assert-ClcGuid $Value.attemptId
    Assert-ClcHash $Value.targetKey
    Assert-ClcTargetSnapshot $Value.targetSnapshot
    Assert-ClcToolkit $Value.executingToolkit
    Assert-ClcInteger $Value.policyGeneration 1
    Assert-ClcHash $Value.policySha256
    Assert-ClcApprovalSnapshot $Value.approvalSnapshot
    Assert-ClcReleaseIdentity $Value.candidate
    Assert-ClcConfiguration $Value.configuration
    Assert-ClcEnum $Value.initialPoolState @('Started','Stopped')
    Assert-ClcBoolean $Value.initialTargetEmpty
    Assert-ClcBoolean $Value.liveMutationIntent
    Assert-ClcEnum $Value.phase @('Prepared','Mutating','RecoveryRequired','Completed')
    if ($null -ne $Value.outcome) { Assert-ClcEnum $Value.outcome @('Deployed','NoOp','FailedPreserved','RestoredPrevious','AcceptedCandidate','RestoredEmpty') }
    if (($Value.phase -ceq 'Completed') -ne ($null -ne $Value.outcome)) { Stop-ClcError Clc.InvalidContract }
    if (($null -eq $Value.previous) -ne $Value.initialTargetEmpty) { Stop-ClcError Clc.InvalidContract }
    if ($null -ne $Value.previous) {
        Assert-ClcObject $Value.previous @('generation','attemptId','approvalSnapshot','release','configuration')
        Assert-ClcInteger $Value.previous.generation 1
        Assert-ClcGuid $Value.previous.attemptId
        Assert-ClcApprovalSnapshot $Value.previous.approvalSnapshot
        Assert-ClcReleaseIdentity $Value.previous.release
        Assert-ClcConfiguration $Value.previous.configuration
    }
    Assert-ClcObject $Value.intent @('sequence','operation','recordedUtc')
    Assert-ClcInteger $Value.intent.sequence 1
    Assert-ClcEnum $Value.intent.operation @('Stage','Validate','Stop','Backup','Replace','Start','CheckReady','PublishCurrent','Complete')
    Assert-ClcTimestamp $Value.intent.recordedUtc
    if ($null -ne $Value.observation) {
        Assert-ClcObject $Value.observation @('sequence','result','observedPoolState','workerCount','observedUtc')
        Assert-ClcInteger $Value.observation.sequence 1
        Assert-ClcCode $Value.observation.result
        Assert-ClcEnum $Value.observation.observedPoolState @('Started','Stopped','Unknown')
        Assert-ClcInteger $Value.observation.workerCount 0 1
        Assert-ClcTimestamp $Value.observation.observedUtc
    }
    if ($null -ne $Value.nativeCall) {
        $native = $Value.nativeCall
        Assert-ClcObject $native @('callId','operation','launchState','processId','creationUtc','exitCode')
        Assert-ClcGuid $native.callId
        Assert-ClcEnum $native.operation @('Validate','Stop','Start')
        Assert-ClcEnum $native.launchState @('Intent','Started','Exited')
        if ($native.launchState -ceq 'Intent') {
            if ($null -ne $native.processId -or $null -ne $native.creationUtc -or $null -ne $native.exitCode) { Stop-ClcError Clc.InvalidContract }
        } else {
            Assert-ClcInteger $native.processId 1 4294967295
            Assert-ClcTimestamp $native.creationUtc -Native
            if ($native.launchState -ceq 'Exited') { Assert-ClcInteger $native.exitCode ([int]::MinValue) ([int]::MaxValue) }
            elseif ($null -ne $native.exitCode) { Stop-ClcError Clc.InvalidContract }
        }
    }
    if ($null -ne $Value.backup) {
        Assert-ClcObject $Value.backup @('verified','indexSha256','inventorySha256','priorEmpty')
        Assert-ClcBoolean $Value.backup.verified
        Assert-ClcHash $Value.backup.indexSha256
        Assert-ClcHash $Value.backup.inventorySha256
        Assert-ClcBoolean $Value.backup.priorEmpty
    }
    if ($null -ne $Value.recovery) {
        $recovery = $Value.recovery
        Assert-ClcObject $recovery @('sequence','mode','reason','originalJournalSha256','executingToolkit','policyGeneration','policySha256','baselineGeneration')
        Assert-ClcInteger $recovery.sequence 1
        Assert-ClcEnum $recovery.mode @('RestorePrevious','AcceptCandidate','RestoreEmpty')
        Assert-ClcText $recovery.reason 128 '^[a-z0-9][a-z0-9-]{0,127}$'
        Assert-ClcHash $recovery.originalJournalSha256
        Assert-ClcToolkit $recovery.executingToolkit
        Assert-ClcInteger $recovery.policyGeneration 1
        Assert-ClcHash $recovery.policySha256
        Assert-ClcInteger $recovery.baselineGeneration
    }
    if ($null -ne $Value.publishedGeneration) { Assert-ClcInteger $Value.publishedGeneration 1 }
    Assert-ClcTimestamp $Value.createdUtc
    Assert-ClcTimestamp $Value.updatedUtc
    if ($null -ne $Value.failure) {
        Assert-ClcObject $Value.failure @('code','nextAction','observedPoolState','workerCount')
        Assert-ClcCode $Value.failure.code
        Assert-ClcCode $Value.failure.nextAction
        Assert-ClcEnum $Value.failure.observedPoolState @('Started','Stopped','Unknown')
        if ($null -ne $Value.failure.workerCount) { Assert-ClcInteger $Value.failure.workerCount 0 1 }
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
    if ($Value -isnot [Collections.IDictionary] -or -not $Value.Contains('contractFamily') -or -not $Value.Contains('schemaVersion') -or -not $Value.Contains('recordKind')) {
        Stop-ClcError Clc.UnsupportedContract
    }
    if ($Value.contractFamily -cne 'clc-file-iis-v1' -or $Value.schemaVersion -isnot [long] -or $Value.schemaVersion -ne $(if ($Kind -ceq 'journal') {2} else {1}) -or $Value.recordKind -cne $Kind) { Stop-ClcError Clc.UnsupportedContract }
    switch -CaseSensitive ($Kind) {
        release-metadata { Assert-ClcPackage $Value }
        release-manifest { Assert-ClcPackage $Value -Manifest }
        host-policy {
            Assert-ClcObject $Value @('contractFamily','schemaVersion','recordKind','generation','machineIdentity','activeToolkit','targetCatalogRoot','approvalCatalogRoot','controlStateRoot','lockRoot','dotnetPath','appcmdPath','infrastructureOwnerSids','deploymentSids')
            Assert-ClcInteger $Value.generation 1
            Assert-ClcGuid $Value.machineIdentity -Machine
            Assert-ClcToolkit $Value.activeToolkit -Active
            foreach ($key in @('targetCatalogRoot','approvalCatalogRoot','controlStateRoot','lockRoot','dotnetPath','appcmdPath')) { Assert-ClcAbsolutePath $Value[$key] }
            Assert-ClcSids $Value.infrastructureOwnerSids
            Assert-ClcSids $Value.deploymentSids
        }
        target {
            Assert-ClcObject $Value @('contractFamily','schemaVersion','recordKind','targetId','applicationId','environmentName','runtimeEnvironment','siteName','applicationPoolName','applicationRoot','operationalConfigPath','dataProtectionRoot','artifactInboxRoot','runtimeIdentitySid','readinessUri')
            Assert-ClcId $Value.targetId
            Assert-ClcId $Value.applicationId
            Assert-ClcText $Value.environmentName
            Assert-ClcEnum $Value.runtimeEnvironment @('Production','Staging')
            Assert-ClcText $Value.siteName
            Assert-ClcText $Value.applicationPoolName 64 '^[A-Za-z0-9_.-]{1,64}$'
            foreach ($key in @('applicationRoot','operationalConfigPath','dataProtectionRoot','artifactInboxRoot')) { Assert-ClcAbsolutePath $Value[$key] }
            Assert-ClcSid $Value.runtimeIdentitySid
            Assert-ClcText $Value.readinessUri 256 '^https://[^/?#@]+/health/ready$'
            $uri = $null
            if (-not [Uri]::TryCreate($Value.readinessUri, [UriKind]::Absolute, [ref] $uri) -or $uri.Host.Length -eq 0 -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -cne '/health/ready') { Stop-ClcError Clc.InvalidContract }
        }
        release-approval {
            Assert-ClcObject $Value @('contractFamily','schemaVersion','recordKind','approvalId','targetId','enabled','applicationId','releaseId','sourceRepository','sourceCommit','lineageId','releaseSequence','releaseZipSha256','manifestSha256','provenance','authorization')
            foreach ($key in @('approvalId','targetId','applicationId','releaseId','lineageId')) { Assert-ClcId $Value[$key] }
            Assert-ClcBoolean $Value.enabled
            Assert-ClcRepository $Value.sourceRepository
            Assert-ClcCommit $Value.sourceCommit
            Assert-ClcInteger $Value.releaseSequence 1
            Assert-ClcHash $Value.releaseZipSha256
            Assert-ClcHash $Value.manifestSha256
            Assert-ClcObject $Value.provenance @('workflowPath','runId','runAttempt','buildJob','artifactId','transportSha256')
            Assert-ClcWorkflow $Value.provenance.workflowPath
            foreach ($key in @('runId','runAttempt','artifactId')) { Assert-ClcInteger $Value.provenance[$key] 1 }
            Assert-ClcCode $Value.provenance.buildJob
            Assert-ClcHash $Value.provenance.transportSha256
            Assert-ClcObject $Value.authorization @('authoritySid','reference','approvedUtc')
            Assert-ClcSid $Value.authorization.authoritySid
            Assert-ClcCode $Value.authorization.reference
            Assert-ClcTimestamp $Value.authorization.approvedUtc
        }
        journal { Assert-ClcJournal $Value }
        current {
            Assert-ClcObject $Value @('contractFamily','schemaVersion','recordKind','generation','targetKey','targetSnapshot','attemptId','recoverySequence','approvalSnapshot','release','executingToolkit','configuration','hostObservationSha256','readiness','completedUtc')
            Assert-ClcInteger $Value.generation 1
            Assert-ClcHash $Value.targetKey
            Assert-ClcTargetSnapshot $Value.targetSnapshot
            Assert-ClcGuid $Value.attemptId
            Assert-ClcInteger $Value.recoverySequence
            Assert-ClcApprovalSnapshot $Value.approvalSnapshot
            Assert-ClcReleaseIdentity $Value.release
            Assert-ClcToolkit $Value.executingToolkit
            Assert-ClcConfiguration $Value.configuration
            Assert-ClcHash $Value.hostObservationSha256
            Assert-ClcReadySnapshot $Value.readiness
            Assert-ClcTimestamp $Value.completedUtc
        }
        backup-index {
            Assert-ClcObject $Value @('contractFamily','schemaVersion','recordKind','attemptId','targetKey','priorEmpty','priorApprovalId','priorManifestSha256','files','inventorySha256')
            Assert-ClcGuid $Value.attemptId
            Assert-ClcHash $Value.targetKey
            Assert-ClcBoolean $Value.priorEmpty
            Assert-ClcFiles $Value.files
            Assert-ClcHash $Value.inventorySha256
            if ($Value.inventorySha256 -cne (Get-ClcInventoryHash $Value.files)) { Stop-ClcError Clc.HashMismatch }
            if ($Value.priorEmpty) {
                if ($null -ne $Value.priorApprovalId -or $null -ne $Value.priorManifestSha256 -or $Value.files.Count -ne 0) { Stop-ClcError Clc.InvalidContract }
            } else {
                Assert-ClcId $Value.priorApprovalId
                Assert-ClcHash $Value.priorManifestSha256
                if ($Value.files.Count -eq 0) { Stop-ClcError Clc.InvalidContract }
            }
        }
        default { Stop-ClcError Clc.UnsupportedContract }
    }
}

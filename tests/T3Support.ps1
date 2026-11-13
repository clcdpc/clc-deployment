# Synthetic IIS/application boundaries; actual lock, trust readers, NTFS effects
# and durable state writers remain production code.
function Set-T3Mocks {
    Set-T2Mocks
    $global:ClcLifecycle=@{revision='example-001';keyId='probe-example';operations=[Collections.Generic.List[string]]::new();ready=$true;startIdle=$true;failStart=$false;failStop=$false}
    Mock -ModuleName CLC.Deployment Get-ClcPlatformObservation { return @{build='20348';productType=3L;is64Bit=$true;powershellMajor=7L} }
    Mock -ModuleName CLC.Deployment Get-ClcRuntimeObservation { return @{frameworks=@(@{name='Microsoft.NETCore.App';version='10.0.12'},@{name='Microsoft.AspNetCore.App';version='10.0.12'});ancmMajor=20L;ancmX64=$true;dotnetX64=$true} }
    Mock -ModuleName CLC.Deployment Assert-ClcHostAccess { }
    Mock -ModuleName CLC.Deployment Start-ClcApplicationValidator {
        $global:ClcLifecycle.operations.Add('Validate')
        $identity=Get-T3DllIdentity $Dll
        $record=@{validationContractVersion=1L;valid=$true;applicationId=$identity.applicationId;releaseId=$identity.releaseId;sourceCommit=$identity.source.commit;
            runtimeEnvironment='Production';configurationRevision=$global:ClcLifecycle.revision;keyStoreCompatibilityId=$global:ClcLifecycle.keyId;errorCodes=@()}
        return Start-T3HarmlessHelper ($record | ConvertTo-Json -Compress)
    }
    Mock -ModuleName CLC.Deployment Start-ClcIisHelper {
        $global:ClcLifecycle.operations.Add($Operation)
        $state=Invoke-T2Private Read-ClcDeploymentState @($Lock)
        $state.journal.record.intent.operation | Should -BeExactly $Operation
        $state.journal.record.nativeCall.launchState | Should -BeExactly 'Intent'
        if ($Operation -ceq 'Start') {
            if ($global:ClcLifecycle.failStart) { return Start-T3HarmlessHelper '' 1 }
            $global:ClcTestFixture.iis.poolState='Started'; $global:ClcTestFixture.iis.workers=@()
            if (-not $global:ClcLifecycle.startIdle) { $global:ClcTestFixture.iis.workers=@(4711L) }
        } else {
            if ($global:ClcLifecycle.failStop) { return Start-T3HarmlessHelper '' 1 }
            $global:ClcTestFixture.iis.poolState='Stopped'; $global:ClcTestFixture.iis.workers=@()
        }
        return Start-T3HarmlessHelper ''
    }
    Mock -ModuleName CLC.Deployment Get-ClcPoolObservation { return @{poolState=$global:ClcTestFixture.iis.poolState;workerCount=[long]$global:ClcTestFixture.iis.workers.Count} }
    Mock -ModuleName CLC.Deployment Invoke-ClcReadinessRequest {
        return Get-T3SyntheticReadiness
    }
}
function Get-T3SyntheticReadiness {
    $global:ClcLifecycle.operations.Add('Ready')
    if (-not $global:ClcLifecycle.ready) { return @{Accepted=$false;Bytes=[byte[]]::new(0)} }
    $identity=Get-T3DllIdentity (Join-Path $global:ClcTestFixture.target.applicationRoot 'Probe.dll')
    $global:ClcTestFixture.iis.workers=@(4711L)
    $record=@{readinessContractVersion=1L;status='ready';applicationId=$identity.applicationId;releaseId=$identity.releaseId;sourceCommit=$identity.source.commit;
        runtimeEnvironment='Production';configurationRevision=$global:ClcLifecycle.revision}
    return @{Accepted=$true;Bytes=[Text.Encoding]::UTF8.GetBytes(($record | ConvertTo-Json -Compress))}
}
function Start-T3HarmlessHelper {
    param([string] $Output, [int] $ExitCode=0, [int] $DelayMilliseconds=0)
    $info=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    $info.Environment.Clear(); $info.Environment['SystemRoot']=$env:SystemRoot
    $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Output))
    foreach ($arg in @('-NoLogo','-NoProfile','-NonInteractive','-Command',('Start-Sleep -Milliseconds '+$DelayMilliseconds+'; [Console]::Write([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('''+$encoded+'''))); exit '+$ExitCode))) { $info.ArgumentList.Add($arg) }
    $p=[Diagnostics.Process]::new(); $p.StartInfo=$info
    if (-not $p.Start()) { throw 'Harmless helper failed' }
    # Exercise the production bounded native capture, using its fixed IIS wrapper
    # result type without executing IIS or application code.
    $type='Clc.Lifecycle.Running' -as [type]; $running=[Activator]::CreateInstance($type); $running.Process=$p
    $capture= ('Clc.Lifecycle.Native' -as [type]).GetMethod('Read',[Reflection.BindingFlags]'Static,NonPublic')
    $running.Output=$capture.Invoke($null,@($p.StandardOutput.BaseStream,8192))
    $running.Errors=$capture.Invoke($null,@($p.StandardError.BaseStream,8192))
    return $running
}
function Get-T3DllIdentity {
    param([string] $Path)
    $hash=(Get-FileHash -LiteralPath $Path).Hash
    return $global:ClcTestFixture.dllIdentities[$hash]
}
function New-T3Approval {
    param($Fixture, [string] $Id='probe-approval-001', [long] $Sequence=1L, [string] $Lineage='probe-main', [int] $FileCount=0, [int] $PayloadBytes=128, [switch] $Nested, [switch] $VaryPayload)
    $build=Join-Path $Fixture.workspace $Id; [void][IO.Directory]::CreateDirectory($build)
    $args=New-TestPublish $build
    $metadata=Get-TestMetadata; $metadata.releaseId='probe-release-'+$Sequence; $metadata.source.commit=$Sequence.ToString('x40')
    Write-TestJson $args.MetadataPath $metadata
    [IO.File]::WriteAllText((Join-Path $args.PublishRoot 'Probe.dll'),('Synthetic approved DLL '+$Id))
    for ($i=0;$i -lt $FileCount;$i++) { [IO.File]::WriteAllText((Join-Path $args.PublishRoot ('payload-'+$i+'.dll')),([string]::new([char]120,$PayloadBytes))) }
    if ($Nested) {
        $nestedRoot=Join-Path $args.PublishRoot 'assets\deep'; $null=[IO.Directory]::CreateDirectory($nestedRoot)
        [IO.File]::WriteAllText((Join-Path $nestedRoot 'obsolete.txt'),'nested-managed-sentinel')
    }
    if ($VaryPayload) {
        # Benchmark-only synthetic whitespace changes preserve valid XML/JSON
        # while changing every file, including web.config and the empty file.
        foreach ($file in Get-ChildItem -LiteralPath $args.PublishRoot -File -Recurse) {
            [IO.File]::AppendAllText($file.FullName,([string]::new([char]32,[int]($Sequence%31L)+1)),[Text.UTF8Encoding]::new($false))
        }
    }
    $package=New-ClcRelease @args
    $a=Get-Content -LiteralPath (Join-Path $script:FixtureRoot 'release-approval.json') -Raw | ConvertFrom-Json -AsHashtable -DateKind String
    $a.approvalId=$Id; $a.targetId=$Fixture.target.targetId; $a.applicationId=$metadata.applicationId; $a.releaseId=$metadata.releaseId
    $a.sourceRepository=$metadata.source.repository; $a.sourceCommit=$metadata.source.commit; $a.lineageId=$Lineage; $a.releaseSequence=$Sequence
    $a.releaseZipSha256=$package.archiveSha256; $a.manifestSha256=$package.manifestSha256
    $a.provenance.workflowPath=$metadata.build.workflowPath; $a.provenance.runId=$metadata.build.runId; $a.provenance.runAttempt=$metadata.build.runAttempt; $a.provenance.buildJob=$metadata.build.job
    $path=Join-Path $Fixture.layout.approvalCatalogRoot ($Id+'.json'); Write-TestJson $path $a
    Copy-Item -LiteralPath $package.archivePath -Destination (Join-Path $Fixture.target.artifactInboxRoot ($Id+'.zip'))
    if (-not $Fixture.ContainsKey('dllIdentities')) { $Fixture.dllIdentities=@{} }
    $Fixture.dllIdentities[(Get-FileHash -LiteralPath (Join-Path $args.PublishRoot 'Probe.dll')).Hash]=$metadata
    return @{record=$a;path=$path;package=$package;publish=$args.PublishRoot;metadata=$metadata}
}

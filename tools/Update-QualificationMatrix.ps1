[CmdletBinding()]
param([string] $OutputRoot=(Join-Path $PSScriptRoot '../docs'))
. "$PSScriptRoot/../tests/Qualification/Scripts/Qualification.Common.ps1"
$OutputRoot=[IO.Path]::GetFullPath($OutputRoot)
if (-not [IO.Directory]::Exists($OutputRoot)) { throw 'Matrix documentation output directory must exist.' }
$definitions=Get-QScenarioDefinitions
$results=@($definitions | ForEach-Object { New-QResult $_ 'unexecuted-matrix-v1' })
$report=[ordered]@{formatVersion=1;runId='unexecuted-matrix-v1';securityModel='ElevatedV1';realHostQualified=$false;
    mandatoryAssertionsPassed=$false;mandatoryExecutionComplete=$false;independentAcceptance='Required';results=$results}
[IO.File]::WriteAllText((Join-Path $OutputRoot 't4-qualification-matrix.json'),($report | ConvertTo-Json -Depth 24 -Compress)+"`n",[Text.UTF8Encoding]::new($false))
$lines=[Collections.Generic.List[string]]::new()
foreach ($line in @('# Retained IIS verification scenarios','',('Real-host verification: NOT RUN. All '+$definitions.Count+' retained scenarios are NOT RUN.'),'',
    'The obsolete 222-case campaign is retired. This catalog supports separately scoped checks; it is not the required qualification matrix for the simplified engine. Start with [the practical IIS procedure](iis-verification.md).','',
    'Elevated V1: independent procedural infrastructure approval; enabled elevated local administrator deployment; separate nonadministrator runtime with enforced isolation. Administrator containment is unavailable.','',
    '| Scenario | Requirement | Status | Reason |','| --- | --- | --- | --- |')) { $lines.Add($line) }
foreach ($definition in $definitions) { $lines.Add('| '+$definition.id+' | '+$definition.expected.Replace('|','\|')+' | NOT RUN | No authorized disposable host execution |') }
[IO.File]::WriteAllText((Join-Path $OutputRoot 't4-qualification-matrix.md'),($lines -join "`n")+"`n",[Text.UTF8Encoding]::new($false))

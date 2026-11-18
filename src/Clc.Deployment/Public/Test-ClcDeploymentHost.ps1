
function Test-ClcDeploymentHost {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $ApplicationId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $TargetId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $ExpectedRuntimeAccount,
        [Parameter(Mandatory)][ValidateSet('Staging','Production')][string] $RuntimeEnvironment
    )
    $result=[ordered]@{applicationId=$ApplicationId;targetId=$TargetId;status='InvalidConfiguration';ready=$false;findings=@()}
    try {
        $context=Open-ClcHostContext $ApplicationId $TargetId $ExpectedRuntimeAccount $RuntimeEnvironment
        $result.root=$context.layout.root
        $result.site=$context.target.siteName
        $result.applicationPool=$context.target.applicationPoolName
        $result.siteState=$context.iis.siteState
        $result.poolState=$context.iis.poolState
        $result.workerCount=$context.iis.workerCount
        $result.findings=$context.findings
        if ($context.findings.Count) {
            if ($null -eq $context.state.current) { $result.status='InitializedNeedsConfiguration' }
        } else {
            $result.status=if ($null -eq $context.state.current) {'ReadyForFirstDeployment'} else {'ReadyForDeployment'}
            $result.ready=$true
        }
    } catch {
        $finding=Get-ClcSafeFinding $_
        $result.findings=@($finding)
        if ($finding.code -ceq 'Clc.NotInitialized') { $result.status='NotInitialized' }
        if ($finding.code -ceq 'Clc.RecoveryRequired') { $result.status='RecoveryRequired' }
    }
    return [pscustomobject]$result
}

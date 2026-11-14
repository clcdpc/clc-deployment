function Test-ClcRelease {
    [CmdletBinding(DefaultParameterSetName='Archive')]
    param(
        [Parameter(Mandatory,ParameterSetName='Archive',Position=0)][ValidateNotNullOrEmpty()][string] $ArchivePath,
        [Parameter(Mandatory,ParameterSetName='Tag')][ValidateNotNullOrEmpty()][string] $ReleaseTag
    )
    $handles = [Collections.Generic.List[IDisposable]]::new()
    try {
        if ($PSCmdlet.ParameterSetName -ceq 'Tag') {
            $tag=Get-ClcDeploymentTag $ReleaseTag
            return [pscustomobject][ordered]@{tag=$tag.tag;releaseId=$tag.releaseId;channel=$tag.channel;releaseSequence=$tag.releaseSequence;authorizedForDeployment=$false}
        }
        $facts = Get-ClcPathObservation $ArchivePath $handles
        $stream = Open-ClcReadFile $ArchivePath $facts $handles
        Test-ClcArchiveStream $stream ([Diagnostics.Stopwatch]::StartNew())
    } catch {
        $code = 'Clc.UnsafeArchive'
        if ($_.FullyQualifiedErrorId -like 'Clc.*') { $code = $_.FullyQualifiedErrorId.Split(',')[0] }
        $PSCmdlet.ThrowTerminatingError([Management.Automation.ErrorRecord]::new(
            [IO.InvalidDataException]::new('Release inspection failed; no deployment authorization was issued.'), $code,
            [Management.Automation.ErrorCategory]::InvalidData, $null))
    } finally { foreach ($handle in $handles) { $handle.Dispose() } }
}

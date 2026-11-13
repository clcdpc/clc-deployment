function Test-ClcRelease {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $ArchivePath)
    $handles = [Collections.Generic.List[IDisposable]]::new()
    try {
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

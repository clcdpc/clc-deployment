function Get-ClcDeploymentTag {
    param($Tag)
    Assert-ClcText $Tag 64 '^v(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})(-(dev|beta|rc)\.([1-9][0-9]{0,3}))?$'
    $m=[regex]::Match($Tag,'^v([0-9]+)\.([0-9]+)\.([0-9]+)(?:-(dev|beta|rc)\.([0-9]+))?$')
    $kind=$m.Groups[4].Value
    $channel=if ($kind -ceq 'dev') {'DEV'} elseif ($kind -ceq '') {'Production'} else {'ArtifactOnly'}
    $ordinal=if ($kind -ceq '') {9999L} else {[long]$m.Groups[5].Value}
    if ($ordinal -gt 9998 -and $kind) { Stop-ClcError Clc.InvalidContract }
    $sequence=(([long]$m.Groups[1].Value*10000L+[long]$m.Groups[2].Value)*10000L+[long]$m.Groups[3].Value)*10000L+$ordinal
    return @{tag=$Tag;channel=$channel;releaseId=$Tag.Replace('.','-');releaseSequence=$sequence}
}

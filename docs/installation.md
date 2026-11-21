# Acquire a trusted toolkit version

Use a specific immutable shared toolkit commit or a versioned toolkit ZIP. The reusable deployment workflow checks out the exact shared workflow revision authenticated by GitHub. Setup workflows can likewise use an immutable checkout selected by trusted protected workflow code. Import `src/Clc.Deployment/Clc.Deployment.psd1` from that checkout.

For a published ZIP, obtain the expected version, source commit and SHA-256 from trusted release metadata. Use a protected temporary directory or runner workspace for verification and extraction. Run these utilities from a trusted checkout:

```powershell
$toolkit = ./tools/Expand-ToolkitDistribution.ps1 -ArchivePath $downloadedToolkit `
    -ExpectedSha256 $trustedToolkitSha256 -ExpectedSourceCommit $trustedToolkitCommit `
    -ExpectedVersion $version -DestinationRoot $newExtractionDirectory
Import-Module $toolkit.moduleManifestPath
```

The extractor verifies the format-4 archive and module inventory and creates a new extraction directory. ProgramData is reserved for the initialized application and its deployment state. Upgrade by selecting another reviewed version in workflow configuration. Prepare Windows, IIS and the Hosting Bundle separately as described in the [setup guide](setup-guide.md).

Use a fresh PowerShell process when switching pinned toolkit revisions. PowerShell retains loaded native helper types for the lifetime of the process. Legacy toolkits can still operate on their original single-binding schema 1 hosts. See the [local record contracts](contracts.md#local-deployment-records) before selecting an older release.

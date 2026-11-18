# Testing

The [Windows CI workflow](../.github/workflows/build-test-publish.yaml) uses pinned PowerShell and Pester and a pinned .NET SDK. `tools/Test-Foundation.ps1 -PesterManifestPath <verified-manifest>` parses PowerShell and JSON contracts, verifies the module manifest and runs the repository Pester suite. The lifecycle suite uses real NTFS packaging, locks, files, backup and state with synthetic IIS and validator observations. Archive and path tests cover unsafe ZIP entries, reparse points, hard links and alternate streams.

`tools/Test-ClcDeploymentAspNetCore.ps1 -DotnetPath <pinned-sdk> -OutputRoot <new-directory>` packs and exercises the companion package. `tools/Test-Candidate.ps1 -OutputRoot <new-directory>` builds the exact committed toolkit twice, checks reproducibility, extracts it and imports the module. Use [IIS acceptance](iis-verification.md) for actual host qualification.

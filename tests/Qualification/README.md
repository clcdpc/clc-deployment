# Retained IIS qualification tools

This is test-only tooling outside the installed module. Start with the [seven-check real-IIS procedure](../../docs/iis-verification.md) for initial deployment, upgrade, healthy NoOp, configuration restart, failed readiness, backup preservation and explicit recovery. Real-IIS testing remains **NOT RUN**. The [scenario definitions](Scenarios/matrix.json) support additional separately scoped checks, not a mandatory release campaign.

`Scripts/Invoke-IisQualification.ps1` defaults to read-only preflight. `-Operation Plan` writes all retained scenario statuses as NOT RUN without a host. Execute requires a concrete checked disposable Server 2022 configuration, independent protected operator authorization, owned resource marker, exact installed distribution and enabled elevated deployment token. The harness cannot target DEV or an existing real application; those use their own separately authorized target/procedure. No template authorizes provisioning or execution.

```powershell
& .\tests\Qualification\Scripts\Invoke-IisQualification.ps1 -Operation Plan -OutputRoot $newPlanDirectory
& .\tests\Qualification\Scripts\Invoke-IisQualification.ps1 -ConfigurationPath $localConfiguration -OutputRoot $newPreflightDirectory
& .\tests\Qualification\Scripts\Invoke-IisQualification.ps1 -ConfigurationPath $localConfiguration -Operation Execute -AuthorizationPath $protectedAuthorization -ScenarioId deploy-initial-stopped -OutputRoot $newCampaignEvidenceDirectory
```

`ProbeApp` is the healthy net10.0/win-x64/in-process application. `FailureApp` builds separately approved immutable readiness/startup negatives with the same safe validator/configuration loader. `Offline/*.Tests.ps1` exercise owned NTFS/process fixtures, synthetic IIS and actual loopback Kestrel/current-user DPAPI. Passing these tests is not real IIS, service-token, TLS or infrastructure qualification.

Automatic scenarios cover lifecycle, controlled drift, explicit recovery, idle activation, DPAPI transitions and performance profiles. Fixed command observers and external phase-journal polling record counts/timing. Recovery verifies retained manifest JSON and backups; it does not expect retained ZIPs. NoOp/configuration/idle checks use the exact current release, including after upgrade.

`Scenarios/matrix.json` is a catalog for separately selected checks, not a mandatory release campaign. Operator-controlled identity/TLS/storage/failure checks remain BLOCKED until actually performed and evidenced. `Register-QualificationObservation`, protected evidence review/archiving and report merging preserve actual observations and primary hashes; they never execute missing tests. Reports account for the retained catalog and never automatically declare `realHostQualified=true`.

Accounts, credentials, components, trust, approvals and operational configuration remain infrastructure-owned. Deployment is elevated, approval separation is procedural, and approved validation is not sandboxed. Runtime stays separate and nonadministrator with effective protected-resource write isolation. No harness command changes administrator membership or adds privileged PR CI.

Keep configuration outside source or at ignored `Configuration/local*.json`, and evidence outside removable owned resources. Generate a NOT RUN plan in a new owned results directory with `tools/Update-QualificationMatrix.ps1 -OutputRoot <results-directory>`; generation is not execution evidence, and generated reports do not belong in source.

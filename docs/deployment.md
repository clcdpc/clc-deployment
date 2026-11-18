# Deployment and explicit recovery

Run [setup and host validation](setup-guide.md) on each target. Use the [six-command reference](contracts.md) for parameters.

## Routine deployment

GitHub-hosted jobs build, test and publish the application. The dedicated Windows job verifies the protected tag, exact source, successful producer and artifact against GitHub metadata. Pass the resulting expected ZIP digest and source identity to the toolkit. The archive itself supplies no trust to the caller.

```powershell
Invoke-ClcIisDeployment @hostInputs -ArchivePath $verifiedArchive -ExpectedSha256 $trustedSha256 `
    -ReleaseTag $trustedTag -ExpectedSourceCommit $trustedCommit -ExpectedRepository $trustedRepository
```

The engine checks target and package identity and obtains the exclusive target lock. It confirms local state, verifies the live managed inventory, records intent, stages the candidate, and runs the application validator. It disables IIS automatic startup for the replacement interval and stops the site and pool. With zero workers, it verifies a complete backup and installs only managed application files. It starts the configured pool and site, checks exact release readiness and final hashes, enables automatic startup, and publishes current state.

Older tags and changed bytes under an already recorded tag are rejected. An exact same-tag retry can run the full lifecycle when no attempt is pending. Recovery retains the highest selected tag even when files return to an earlier release. An unrelated file, unverified backup, or unsafe sharing or path observation stops the operation.

## Operator procedure

1. Inspect the failed attempt ID, local attempt directory, and reported site, pool, worker, and startup state. Preserve the state, logs, staged files, and backup. Avoid competing IIS, filesystem, or deployment changes while investigating.
2. Check application configuration, persistent keys and external systems with the application owner. The application validator checks configuration and key compatibility. Database and external-state recovery require their own procedure.
3. Use the exact unresolved attempt and a nonsecret reason when the retained evidence supports file recovery.

```powershell
Restore-ClcIisDeployment @hostInputs -AttemptId $failedAttempt -Reason 'incident-123'
```

With a prior release, recovery verifies its manifest, backup bytes when replacement could have started, and live contents. It validates the prior release under the current external configuration, then verifies its readiness after restoring it. A failed first deployment can recover to an empty, stopped application with automatic startup disabled. When a failure occurred before replacement, recovery can use the intact live prior release. The original attempt record is retained as before-recovery.json. Config, Keys, Logs, and external dependencies stay outside file recovery.

Unknown files, uncertain helper or worker state, missing required backup, and an interrupted recovery require manual reconciliation. A retained pending attempt blocks ordinary retries. Individual file publication is atomic on the application volume. A host reboot or storage failure during replacement can still require manual intervention. Never remove the lock or rewrite a pending state record to bypass these checks.

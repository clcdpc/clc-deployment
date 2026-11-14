# IIS deployment and explicit recovery

Follow the [public contracts](contracts.md) for command, approval, package and state formats, and [application hooks](application-hooks.md) for V2 policy, planning and persistent-state recovery.

## Prerequisites and commands

Import the exact independently installed manifest in a fresh trusted PowerShell process. Infrastructure must provision and approve the dedicated Windows Server 2022/IIS target, elevated deployment identity, separate nonadministrator runtime, .NET/ANCM, protected configuration/keys, target/approval catalogs and exact toolkit pin. `Test-ClcRelease` reports integrity only.

For a consumer using GitHub Actions, complete the [GitHub setup checklist](github-setup.md) before enabling its trusted automatic deployment consumer. The recommended integration consumes successful eligible tagged builds under standing policy after an independently approved baseline. Runner admission and infrastructure-approved environment protection are separate from protected host and exact-byte release approval. The exact manual commands below remain supported for independently authorized operations.

```powershell
Import-Module 'C:\approved-toolkit\versions\<version>\CLC.Deployment\CLC.Deployment.psd1'
Invoke-ClcIisDeployment -TargetId example -ReleaseApprovalId example-002
Invoke-ClcIisDeployment -TargetId example -ReleaseApprovalId example-001 -AllowDowngrade -Reason approved-incident
Restore-ClcIisDeployment -TargetId example -AttemptId '<latest-attempt-guid>' -Mode RestorePrevious -Reason approved-incident
```

These are nonoperational placeholders. Public commands accept no credentials, callbacks, arbitrary target/state paths or trust-bypass flag. The independently protected enabled approval supplies the expected hashes; an inspection result, manifest, caller expectation or release name never authorizes code. Deployment never provisions credentials or operational configuration.

For an already deployed baseline, infrastructure may separately enable [tag-authorized routine deployment](automated-deployments.md). `Invoke-ClcIisDeployment -TargetId $target -StandingAuthorizationId $standing -ReleaseTag $tag -ArchivePath $zip -VerifiedReleasePath $identity` validates trusted workflow-supplied release identity and exact package bytes and publishes exact authority under the same lock before this sequence. Revoked/changed policy blocks routine use of its generated approvals, including direct exact-ID retries. Existing manual approval commands need no standing policy.

## Deployment sequence and safeguards

1. Resolve the protected target/release approval using the fixed installed toolkit context, verify the toolkit and acquire one fail-fast exclusive OS file handle for the actual machine/pool. Read that pool's state and reject unresolved attempts. Never delete a lock file or infer completion from its age or released handle.
2. Verify approved ZIP SHA-256 once, exact manifest bytes/source/build identity and safe archive contents. Preflight dedicated IIS configuration, physical paths, platform/runtime, external configuration, separate identities and effective protected-resource access. Reject reparse points, hard links, unsafe aliases/streams, overlapping roots and unknown files.
3. For a **V1** exact current release with matching host observations, verify its installed approved inventory before running its fixed application validator against current configuration. If configuration matches, check fresh expected-release readiness and record NoOp without extraction, staging, backup or stop/copy/start; preserve current state and save the completed attempt. **V2 always performs the full cycle**, even on identical repeats.
4. Otherwise extract safely to protected staging, verify inventory before application validation, run the approved fixed validator and check previous configuration compatibility. Changed configuration revisions require restart; failed NoOp readiness follows this staged deployment path.
5. Persist stop and backup intent, stop, confirm Stopped/zero workers and copy the exact approved old inventory. Verify the complete backup/index before replacement. Track bounded helper launches and exact process creation identity; unknown helper lifetime blocks recovery.
6. Persist replacement intent, replace only the approved managed union using ordinary literal .NET file operations and affected-path checks, and verify the destination inventory. Confirm Stopped/zero workers at each file effect. External configuration, keys, logs and data stay outside the replaceable tree; unexpected files are never cleanup candidates. Recovery never restores external configuration or Data Protection keys with application files.
7. Persist startup intent, start and poll exact release/source/environment/configuration readiness. Verify final hashes and exactly one worker before publishing current and a matching terminal record, with durable intent before current publication. Persistence failures cannot return success.

V2 hook packages retain a verified online backup of exact prior managed bytes before any hook. Preflight and BeforeStop run before the first IIS stop; AfterStop runs only after Stopped/zero workers; AfterStart follows exact-release readiness. This reuses the same stop/replacement/start engine. No-hook V2 keeps the stopped backup sequence. Every started hook is possible persistent mutation regardless of its result flag. SQL/DACPAC/Hangfire semantics remain application-owned.

Comprehensive host/access checks are lifecycle gates, not operations repeated for every file. The independently trusted toolkit/Windows/.NET installation and restricted runtime access are the operational trust assumptions; approved validation executes elevated without a sandbox.

The toolkit verifies `web.config` integrity and bounded XML structure; applications validate its IIS semantics in CI. An authorized release may change application-level IIS settings, managed through source/release review and independent infrastructure host configuration and authorization. The retained approved `web.config` in RestoreEmpty is recovery material, not an activation barrier; that outcome requires Stopped/zero workers and must remain stopped pending separately authorized deployment.

Freeze competing trusted configuration, filesystem and IIS changes throughout deployment and recovery. A held default-stream handle does not prevent another trusted writer from adding a named stream; fresh checks do not make stream absence atomic. These checks do not contain a compromised administrator or trusted application process.

## Failure behavior

| Failure boundary | Behavior |
| --- | --- |
| Approval, archive, host, staging or validation failure before IIS changes | Preserve application and original pool state; retain available failure/staging information |
| Any hook failure or later failure after a hook began | Retain possible external mutation and RecoveryRequired. BeforeStop failure leaves the original pool when IIS effects have not begun. Never automatically restart previous code or retry SQL; after live effects use bounded stop |
| Stop or backup failure before replacement begins | When helper exit, unchanged prior files, configuration and target authority are proven, restore the prior running pool if appropriate. An initially stopped pool stays stopped |
| Replacement has begun, startup/readiness fails, or current/terminal publication fails | Attempt bounded stop and zero-worker observation; retain backup, stage, journal and current evidence. Do not automatically restore or start previous files |
| Stop cannot be proven or helper lifetime is unknown | Report actual Started/Stopped/Unknown facts and require operator intervention; never claim a stopped target without observation |
| Process termination or unexpected OS reboot during file copy | No cleanup guarantee. Files may be mixed, and IIS may activate them. Routine retry refuses the pending journal; manual recovery may be required |

An OS reboot during physical replacement is an explicitly accepted operational limitation. There is no Closed/Candidate/Released fence, startup hook, named-pipe activation broker, job-object admission service or per-file transaction protocol.

## Explicit recovery

`Restore-ClcIisDeployment` requires the exact latest attempt, an explicit mode and a nonsecret incident/change reason. It takes the same lock, rechecks protected approvals, target identity, unchanged compatible external configuration and helper quiescence. It retains a before-recovery snapshot and never guesses an arbitrary backup path.

After possible hook mutation, also provide `-PersistentStateApprovalId` selecting independent protected authority for the exact latest journal, selected manifest and recovery mode. Infrastructure must confirm external-state compatibility and helper quiescence. Recovery records that exact approval, executes no hooks and does not claim database rollback. Existing generated releases still need their separate RecoveryApprovalId. A schema-1 release approval or a hook's `externalStateMayHaveChanged=false` alone cannot authorize this reconciliation. See [the exact record and operator obligations](application-hooks.md#failure-and-explicit-recovery).

When the selected recovery release has an automatically generated approval, also supply `-RecoveryApprovalId` selecting an independent normal schema-1 approval with matching exact release/target/source/lineage/provenance/hashes. Standing authority does not authorize recovery. Preserve the generated approval and journal bytes; a revoked standing policy does not prevent this separately approved recovery. Existing manually approved recovery is unchanged.

| Mode | Required material and outcome |
| --- | --- |
| RestorePrevious | Enabled prior approval, approval-pinned retained manifest, exact verified backup/index and compatible configuration. Stop/observe, replace only the managed union from backup, verify, start, check previous release readiness and publish a new generation |
| AcceptCandidate | Enabled candidate approval and a complete exact installed candidate inventory. Validate, explicitly stop/start, check readiness and publish success. It cannot complete a partial copy |
| RestoreEmpty | Failed first installation, verified empty backup and complete verified stage. Stop, remove only known candidate file paths, retain the approved web.config guard, preserve any matching uncommitted current as evidence and leave no ready current |

Partial managed files can be overwritten by an explicitly selected verified backup; unexpected paths, unsafe filesystem objects, corrupt backup/source material or incompatible configuration refuse. Recovery failure after its live boundary attempts stop only and retains all evidence. No recovery recursively invokes another recovery.

## Operator procedure

1. Preserve the application tree, `journal.json`, `current.json`, attempt snapshots, staging, retained manifests and backup/index. Read the safe error's attempt, pool/worker observations and retained control path.
2. Freeze concurrent configuration/deployment/IIS changes. Fence application exposure/activation if necessary. Confirm exact machine/pool/root identities and helper exit. Unknown launch identity, corrupt state or unsupported legacy journals require infrastructure maintenance; ordinary commands never reset or adopt them.
3. Independently confirm enabled approval, exact backup/stage bytes and selected application/configuration/key compatibility. File restoration says nothing about database compatibility.
4. Select the exact latest attempt and recovery mode with a nonsecret reason. Run the independently installed toolkit in a fresh trusted PowerShell process.
5. Accept success only after exact readiness, final hashes and durable current/terminal state. Retain all recovery material until infrastructure authorizes retention cleanup.

A defective toolkit requires independent installation/activation of a reviewed compatible replacement. Lost approvals, unverifiable files, unknown helpers or unsupported state require a separately authorized manual maintenance plan. Do not edit a journal to Completed, delete evidence, adopt mixed content or assume a reboot made recovery safe. The shared elevated administrator is privileged; independent approval remains procedural against that account. Actual IIS/runtime-token/profile/TLS/storage behavior still needs real-host evidence.

## Plan-only diagnostics

Use the same approved invocation with `-Operation ValidateOnly`. Only the separately declared and policy-authorized planning entry point runs. It may retain reviewed SQL plan/report diagnostics locally, returns Planned on success and leaves IIS/current unchanged. It does not execute lifecycle hooks. Read-only behavior depends on independently reviewed code; it is not enforced by a sandbox. Failure or reported mutation requires reconciliation, and planning may have no file backup suitable for ordinary recovery. The separate prerequisite diagnostic in PR #3 remains read-only and does not execute this application code.

# Public and persistent contracts

[Schemas](../schemas) and [Contracts.ps1](../src/Clc.Deployment/Private/Contracts.ps1) define exact fields, types and bounds. This reference explains behavior and trust requirements. Unsupported legacy per-file/retirement journals refuse; operational state is never automatically migrated.

| Fixed source | Compatibility evidence |
| --- | --- |
| [a3a94cd](https://github.com/clcdpc/clc-deployment/tree/a3a94cd26daa583d392f73e99e56872876a88467), MIT beta.3 | Four exact-approval/file-only commands, journal 2 |
| [7f814ef](https://github.com/clcdpc/clc-deployment/tree/7f814ef838abcfd12ade494c429918657598c35d) | Retained tag/standing admission |
| [557192e](https://github.com/clcdpc/clc-deployment/tree/557192eff5eea651d6f1a393eb3b196053a985e5), beta.4 | Target-local format-3 distribution with the historical target-derived root |

Offline fixtures prove supported shapes/paths, not published-artifact, real-host or consumer qualification. The optional [GitHub check](github-setup-check.md) reads settings without granting authority.

## Four commands

```powershell
New-ClcRelease -PublishRoot <publish-directory> -MetadataPath <release-metadata.json> -OutputPath <new-release.zip> [-HookRoot <separate-hooks-directory>]
Test-ClcRelease -ArchivePath <release.zip>
Test-ClcRelease -ReleaseTag <vMAJOR.MINOR.PATCH[-dev.N|-beta.N|-rc.N]>
Invoke-ClcIisDeployment -TargetId <safe-id> -ReleaseApprovalId <safe-id> [-AllowDowngrade -Reason <change-id>] [-Operation Deploy|ValidateOnly]
Invoke-ClcIisDeployment -TargetId <safe-id> -StandingAuthorizationId <safe-id> -ReleaseTag <tag> -ArchivePath <inbox.zip> -VerifiedReleasePath <inbox.json>
Restore-ClcIisDeployment -TargetId <safe-id> -AttemptId <latest-guid> -Mode RestorePrevious|AcceptCandidate|RestoreEmpty -Reason <change-id> [-RecoveryApprovalId <safe-id>] [-PersistentStateApprovalId <safe-id>]
```

These are the only exports. Parameter rules:

- Paths are literal; IDs match lowercase `[a-z0-9][a-z0-9-]{0,63}`. Reasons are nonsecret lowercase safe IDs, maximum 128 characters. Invoke requires Reason with AllowDowngrade and rejects it otherwise; Restore requires Reason and a nonempty GUID.
- Automated selection excludes exact-selection/downgrade flags. It accepts `-Operation`; `-ReleaseReference` aliases `-ReleaseTag` for protected branches. Deploy is default.
- No credentials, inline commands, arbitrary hook entry points, policy overrides, caller journal paths, approval objects or trust-bypass flags.

| Command | Result/effects |
| --- | --- |
| New | Deterministic inventoried ZIP and package/hash/count/builder identity; no build, approval or payload execution |
| Test archive | Full ZIP/manifest/file verification without extraction; `integrityVerified=true`, `authorizedForDeployment=false`, release/source/hash/count/builder identity. Invalid input throws |
| Test tag | Tag/releaseId/channel/releaseSequence, `authorizedForDeployment=false`; no file/host access |
| Invoke | Protected authority, lock, preflight and lifecycle. V1 may return NoOp; V2 repeats the full cycle. Safe identity/toolkit/generation/pool/worker results |
| ValidateOnly | Separate authorized planning code, Planned result; IIS unchanged; no current/readiness publication |
| Restore | Latest attempt under the same trust/lock; RestoredPrevious/AcceptedCandidate/RestoredEmpty with attempt/recovery/release/toolkit/generation/pool/worker identity. Empty stays stopped without ready current |

Errors terminate with stable `Clc.*` IDs and safe attempt/pool/worker/retained-path/operator-action facts. Secrets, private configuration hashes and raw native output are excluded. Partial work/persistence failure cannot return success.

## Format and bounds

Strict UTF-8 JSON rejects duplicate/case-ambiguous keys, unknown/missing fields, coercion, comments, nonintegral numbers, unsupported versions and trailing data. Required fields are nonnull unless explicitly nullable. IDs, hashes, GUIDs, commits and timestamps are canonical. Valid shape grants no authority.

| Record | Supported version |
| --- | --- |
| [Metadata](../schemas/release-metadata.schema.json) / [manifest](../schemas/release-manifest.schema.json) | 1, 2 |
| [Release approval](../schemas/release-approval.schema.json) | Manual 1; generated 2, 3 |
| [Standing authorization](../schemas/standing-authorization.schema.json) / [verified release](../schemas/verified-release.schema.json) | 1, 2; matching versions |
| [Journal](../schemas/journal.schema.json) | 2 (V1), 3 (V2 hook/planning/recovery evidence); version 1 unsupported |
| Policy, target, current, backup, tag binding | Schema 1 |
| [Hook policy](../schemas/hook-policy.schema.json) / [persistent-state approval](../schemas/persistent-state-approval.schema.json) | Schema 1 |
| [Hook result](../schemas/hook-result.schema.json) / [source identity](../schemas/source-identity.schema.json) | Contract 1 |
| Application validation/readiness | Contract 1 |
| Host enrollment | Separate `clc-host-enrollment-v1`, schema 1 |

Host/package records retain `contractFamily=clc-file-iis-v1` and exact `recordKind`; package V2 does not rename that family.

| Limit | Bound |
| --- | --- |
| Record/manifest/metadata | 4 MiB |
| ZIP compressed/expanded; entries; file; expansion | 1 GiB; 20,000; 256 MiB; 100:1; actual streamed lengths enforced |
| Relative/full path | 240 characters |
| Lock / helpers / stop / start | Fail-fast / 30 s / 60 s / 60 s |
| Readiness | 120 s overall, 5 s/request, 2 s polling |
| Archive / stage / backup / replace | 300 s each |
| Hook/context result; hook execution | 8 KiB; independently protected 1–300 s plus bounded helper termination |

Late synchronous OS returns prevent further effects/success. Raw hook diagnostics stay local, outside shared workflow publication.

## Package and trusted CI digest

| Package | Contents and behavior |
| --- | --- |
| V1 | Only `manifest.json` and complete `application/`, including web.config; `changeKind=files-only`; healthy NoOp supported |
| V2 | `changeKind=application-deployment`; full-cycle repeats; optional separately inventoried `hooks/` assets, hook contract 1 |

`manifest.files`/`inventorySha256` cover application files only. V2 `manifest.hooks.files`/inventory cover all hook/support files. Archive/entry/aggregate bounds cover both trees. Metadata/manifest schemas define source, producer, builder, runtime, validation and readiness identities; see [hooks](application-hooks.md).

### Dependency and builder identity

- V1 requires `build.dependencyLockSha256`. V2 keeps the field required but allows explicit JSON null for independently qualified builds without a NuGet lock.
- Otherwise hash actual project-adjacent `packages.lock.json` bytes (source-root when no project is configured). Omitted/placeholder/alternative evidence is invalid.
- The conventional builder requires the lock and `--locked-mode`. Prequalified CI owns build qualification; recording lock bytes does not prove locked restore.
- Both paths require exact producer/source/artifact verification, package hashes and builder identity.

Shared packaging requires `builder.sourceCommit` equal to tagged `orchestration.sharedRevision`. Conventional/prequalified producers reject mismatched SharedSourceCommit before work; publication/admission recheck after byte/source/producer verification. Builder-distribution verification and independent host-toolkit pins remain separate; no new signing contract is implied.

### Digest rules

Inventory SHA-256 covers ordinal-sorted UTF-8 `path + NUL + invariant-length + NUL + lowercase-hash + LF`, without BOM. Manifest digest covers exact UTF-8 bytes; ZIP digest covers the entire archive. CI publishes New's digest/provenance; protected approval supplies the trusted deployment expectation. Compare ZIP once per invocation, outside copy loops.

### Archive and application boundaries

Reject:

- Traversal, absolute/UNC/device/drive/ADS paths, backslashes, reserved DOS names, trailing dots/spaces, ambiguous Unicode/case and collisions.
- Symlinks/reparse/special attributes, encryption, unsupported compression and bound violations.
- Unexpected files/unrelated empty directories. Inspect raw ZIP/full inventory before create-new extraction; verify staged hashes and deny runtime staging writes.

`application/web.config` must match inventory and parse as XML within 4 MiB, with DTD/external entities disabled. The toolkit never rewrites it. Application CI owns IIS semantics, including handlers/modules, ANCM arguments, environment and logging.

Application-level IIS changes require source/release review, independent infrastructure host configuration and exact authorization. Dedicated-host/path/access/validator/readiness checks remain enforced. Exclude scripts/toolkit, operational configuration, development/test settings, keys and certificates; application builds own secret/content semantics.

## Existing protected authority and preflight

All policy and state for one target are local to native `%ProgramData%\clc-<application-id>\Deployment`. Deployment and recovery derive the application ID from the installed module's canonical location. The active policy must pin that exact installation and the protected catalog must contain only the requested target, with the same application ID and canonical resource paths.

| Record/boundary | Requirement |
| --- | --- |
| [Host policy](../schemas/host-policy.schema.json) | Generation, machine, trusted directories/helpers/identities and exact active toolkit version/source/distribution/module inventory/manifest |
| [Target](../schemas/target.schema.json) | Dedicated application/site/pool, identities/environment/readiness and canonical sibling Application, Config/application.json, Keys and Inbox roots |
| Manual exact approval | Enabled protected authority; select only `<approvalId>.zip` from inbox; match ZIP/manifest/source/build/provenance |
| Ordering | Downgrade/incomparable lineage needs AllowDowngrade/reason. Equal sequence with changed identity refuses except later admitted same-tag/source builds |
| Identities | Admitted deployment SID plus enabled elevated Administrators token; distinct runtime nonadministrator with effective protected-write isolation. Independent approval against administrator remains procedural |

Infrastructure authenticates first import and installed Windows/.NET/IIS. Roots must be existing, disjoint canonical local NTFS objects; mutable OS directories, aliases/reparse/hard links/named streams refuse. Configuration is an external protected regular file.

### Generated approvals and source classes

Only trusted installed admission code creates generated approvals after policy scope, workflow-authenticated identity, package bytes, immutable source binding and ordering checks. Schema 2 binds exact standing bytes/tag/evidence; schema 3 adds source identity. Direct retries still require the original enabled standing bytes. No AllowDowngrade, exceptional recovery or hooks are authorized by standing authority alone.

| Source class (contract 1) | Scope |
| --- | --- |
| IntegrationTag | Tag contained in protected master history |
| UnmergedDevTag | Explicitly enabled DEV outside master; never Production/other channels |
| ProtectedBranch | Authorized integration-branch snapshot; branch name is not permanently bound to one commit |

Schema-2 standing policy requires `sourcePolicy.allowUnmergedDevTags`. Consumer configuration 2 admits unmerged DEV without another flag or master-file equality. An authorized exact tag needs no PR approval/branch protection; master stays protected. Hook policy must separately admit UnmergedDevTag. Producer/artifact/package/builder checks remain mandatory.

Source/order kinds cannot silently mix. Existing approvals/snapshots/backups remain readable; [workflow trust](verified-workflow-integration.md) and [automation](automated-deployments.md) define admission details.

### IIS and path gates

- Verify sole site/root application/pool, physical root/runtime SID, one-worker maximum, no overlap rotation, x64 .NET/ANCM, environment, HTTPS binding and effective access.
- Bounded IIS observations inspect **all** applications/non-root virtual directories, across sites/pools. Exact/ancestor/descendant/physical-identity overlaps with Application refuse, even when selected pool is stopped.
- Reject uncertain aliases/network paths/unknown expansion. IIS `%SystemDrive%`, `%SystemRoot%`, `%windir%` use native facts; `%ProgramData%` uses the trusted known-folder resolver. Other-root handles are temporary; there is no cross-application coordination.
- Repeat full checks at lifecycle/effect gates, after replacement inventory and between deletion/copy/directory retirement. Per-file effects check affected paths and Stopped/zero workers.

| Pool observation | Permitted boundary |
| --- | --- |
| Started, zero/one workers | Idle preflight |
| Stopped, zero workers | Backup/replacement |
| Started, exactly one worker | Ready success |

After live effects, private bounded safety Stop may omit only a foreign different-pool root scan. Held target/native machine/root identity, selected site/root/pool, runtime SID and sole selected-pool application remain mandatory. It cannot Start, affect another pool or admit replacement/recovery; ordinary paths refuse unresolved conflicts.

## Application-owned validation/configuration/readiness

The fixed approved DLL receives `--validate-deployment --configuration-path <file> --data-protection-root <keys> --environment Production|Staging` through installed dotnet with cleared environment and bounded output/time. It executes **elevated without sandboxing**. [Validation schema](../schemas/application-validation.schema.json) defines exact response fields; configurationRevision/keyStoreCompatibilityId use safe-code grammar, maximum 64/128 characters respectively.

Configuration rules:

- Hold/hash privately; never copy/log. Changed bytes under a successful unchanged revision reject; new revision requires restart even for identical release bytes.
- Candidate/prior validators must agree on current configuration/key compatibility. Mid-attempt drift aborts; keys may evolve outside replacement.
- V1 NoOp verifies live inventory, unchanged configuration/host, validation and fresh readiness. It saves journal/attempt without stage/backup/application/current changes; current generation stays unchanged.
- V2 reruns full cycle/hooks. ValidateOnly preserves current/generation, performs no readiness and records successful trusted planning as Planned.

Readiness uses anonymous HTTPS GET `/health/ready`, normal TLS, no redirects/cookies/auth forwarding, JSON ≤4 KiB and `Cache-Control:no-store`. Match every [readiness field](../schemas/readiness.schema.json), including expected release/source/environment/configuration. Generic 200, stale identity, TLS failure or malformed/extra/private fields fail.

## Canonical lock and phase state

Machine identity is the enrolled local nonzero/non-all-ones SMBIOS UUID. Uppercase the actual ASCII IIS pool name; targetKey is SHA-256 of UTF-8 `machineIdentity + NUL + uppercase-pool`. One noninheritable FileShare.None handle remains with the mutator in target-local locks. Crash release never proves completion.

```text
controlStateRoot/<targetKey>/
  journal.json; current.json
  attempts/<attempt>/deployment.json
  attempts/<attempt>/before-recovery-<sequence>.json
  attempts/<attempt>/recovery-<sequence>.json
  staging/<attempt>/application/...
  backups/<attempt>/index.json; application/...
  releases/<approvalId>.json       # exact approval-pinned manifest
```

| State | Invariant |
| --- | --- |
| [Journal](../schemas/journal.schema.json) | Prepared/Mutating/RecoveryRequired/Completed; durable intent before effects; unresolved phases block Invoke. No per-file ownership log |
| V3 hook evidence | Intent/possible external mutation before launch, safe results, separate planning and exact persistent-state recovery approval. False mutation result never clears failure uncertainty |
| Native launch | Intent/Started/Exited, exact process ID/creation time/exit. Recovery must prove that helper exited; unknown identity refuses, without reboot inference/override |
| [Current](../schemas/current.schema.json) | Generation/release/toolkit/configuration/host and completed readiness identity; historical readiness, never present health |
| [Backup index](../schemas/backup-index.schema.json) | Exact prior identity/inventory; verify bytes before recording and recovery. Empty means no files |

Journal intents are Stage/Validate/Stop/Backup/Replace/Start/CheckReady/PublishCurrent/Complete; V3 also Hook. Every attempt records executing toolkit/policy identity. Upgrades/recovery use approval-pinned retained manifests and selected backup, without historical ZIP verification/unrelated history scans.

State writes use same-directory temporary → flush → rename → reopen/verify. Unknown leftover temporaries block admission. Success order:

1. Readiness/final hashes.
2. Prospective generation intent, then current.
3. Matching Completed journal and create-new terminal snapshot.
4. Final authority observation.

Failures retain evidence. Recovery saves before-recovery state; RestoreEmpty preserves matching uncommitted current before removal. Interrupted retirement may require maintenance. **Reboot during replacement may require manual recovery:** pending state does not prevent WAS activation; no startup interception/transaction engine exists. See [recovery](deployment.md#operator-procedure).

Enrollment remains outside the module: Get/Plan read only; Apply needs exact machine/config/bootstrap/toolkit/operation authority. It provisions dedicated directories/ACLs/stopped IIS settings only. Accounts/secrets/certificates/trust/components stay external. Cutover needs Stopped/zero workers and verified approved original backup; missing records with prior evidence require reconciliation. Follow [enrollment](host-enrollment.md).

## Toolkit distribution reference

Format 3 contains exactly `Clc.Deployment/`, `source.commit` (40 lowercase ASCII bytes, no newline), `distribution.json` and eight allowlisted infrastructure files from `Get-DistInfrastructureNames` under `tools/`. Tools remain outside module exports/application ZIPs. Policy, approvals, targets, configuration, keys, credentials and state are excluded.

| Distribution identity | Meaning |
| --- | --- |
| Format/source/version | `clc-toolkit-distribution`/3, exact committed HEAD/full shared version |
| Module inventory | Complete module-relative path/length/hash entries and digest; activeToolkit.inventorySha256 |
| Infrastructure inventory | Formats 2/3: exact allowlist checked against committed source |
| Source inventory | Complete committed repository; source is not bundled executable dependencies |
| Toolchain/reproducibility | Actual PowerShell/.NET/Git; fixed stored entries/timestamps/ordinal sorting |

Use the [inventory algorithm](#digest-rules). Bootstrap authorization includes `Clc.Deployment/`-prefixed module entries plus infrastructure files. Archive digest cannot appear inside itself; separate builder identity remains an unauthenticated integrity claim.

Build/verification rules:

- `New-ToolkitDistribution.ps1` requires full lowercase HEAD, clean tracked/untracked tree and complete Git archive. Check committed blob bytes, not CRLF-converted worktree; ReleaseVersion stamps only output manifest. Output must be new.
- Same source/version/toolchain must reproduce identical bytes; toolchain changes may change ZIPs. Rebuilt application artifacts are not retained originals.
- Independently reviewed verifier checks bounds, exact entries/inventories/source/version/metadata without importing distribution code. Installed checks reject extra files/directories, changed bytes, reparse/alias/hard links, streams and unknown/case-sensitive directory mode. Deployment repeats policy/effective-access checks.
- Extractor holds original archive against write/delete through bounded verification/create-new extraction/retention; imports nothing, returns `activated=false`. Failed extraction remains evidence; no in-place repair. Acquisition/import/activation require independent trust; follow [installation](installation.md).

Historical format-1/2 `CLC.Deployment` archives remain inspectable but cannot initialize target-local runtime. V1 packages retain historical builder.module acceptance; new producers/V2 use Clc.Deployment. Fixed refactor baseline: [b0ce6f3](https://github.com/clcdpc/clc-deployment/tree/b0ce6f377cfef371fa60d570e87f229bd809a528).

[Testing](testing.md), [releasing](releasing.md), [dependency pins](../tools/dependencies.lock.json) and [SDK pin](../tools/probe-sdk.lock.json) define evidence. Hosted artifacts retain identical builds, installed checks, probe releases, negatives and candidate-evidence.json. Producer/adjacent metadata never authorizes installation or qualifies IIS.

# Application hooks and planning

Package schema 2 extends the existing four commands and IIS engine. Its `changeKind` is `application-deployment`; schema 1 remains `files-only` with its existing NoOp behavior. Every V2 deployment stages, validates, stops, replaces, starts and checks exact-release readiness, including identical repeats. Hooks must be idempotent. The ASP.NET Core validator and readiness contracts are unchanged.

## Packaging

Use V2 metadata with an optional `hooks` object:

```json
{
  "contractVersion": 1,
  "stages": [
    {"stage": "BeforeStop", "entryPoint": "hooks/before-stop.ps1"},
    {"stage": "AfterStop", "entryPoint": "hooks/after-stop.ps1"}
  ],
  "planningEntryPoint": "hooks/plan.ps1"
}
```

`New-ClcRelease -HookRoot <separate-directory>` inventories this directory as `hooks/`; the manifest records its complete files and inventory SHA-256 separately from `application/`. The archive and exact manifest approval cover both trees. SQL/DACPAC inputs and supporting scripts belong here. Operational configuration, credentials, certificates and keys remain external. No-hook packages omit `hooks` and need no HookRoot. Entry points must be declared `.ps1` files; each stage appears at most once. Planning must use a distinct entry point. There are exactly four lifecycle stages; Plan is a separate operation.

The host extracts hook assets beside the staged application, outside the managed IIS root, and verifies them before execution. Supporting files remain held against ordinary write/delete while hooks run. Write diagnostics only to the supplied diagnostic directory. Application hook code is trusted and can access anything the elevated deployment account can access; neither ZIP integrity nor the process boundary supplies a sandbox.

## Independent infrastructure policy

Infrastructure installs `approvalCatalogRoot/hooks/<targetId>.json` using [hook-policy schema 1](../schemas/hook-policy.schema.json), structural protection and its independent approval procedure. No command generates this policy. It binds target/application/environment, enabled state, allowed channels/source classes/stages, `allowPlanning`, an exact protected `pwsh.exe` path/SHA-256 and a 1–300 second execution bound. Infrastructure independently trusts the complete installed PowerShell runtime and its dependencies, as for .NET/IIS.

Source classes are `ExactApproval`, `IntegrationTag`, `UnmergedDevTag` and `ProtectedBranch`. Generated schema-3 approvals carry independently workflow-verified source classification, including protected master. `UnmergedDevTag` requires `sourcePolicy.allowUnmergedDevTags=true` in consumer and standing policies plus explicit inclusion in hook policy `sourceClasses`; the valid DEV tag supplies release authorization without a separate PR reviewer. Production needs its own target policy and approved hook set. Legacy generated schema-2 approvals lack this classification and cannot execute hooks. Manual schema-1 exact approvals independently authorize the complete reviewed bytes, with channel selected by policy `exactApprovalChannel`; environmentName is an operator label and never implies a channel. That channel must belong to the policy's allowed channels.

Policy approval is additional to exact release authority and standing scope. A checksum or consumer manifest alone never grants privileged execution. Revocation is checked on fresh admission/direct retries; infrastructure fences policy replacement against active execution. Recovery executes no hooks and uses its separate independent authority.

## Lifecycle and script protocol

The shared engine authorizes release/policy, takes the existing machine/pool lock, checks host/configuration, stages and validates. For a hook package it retains an exact verified backup **before any hook**, while leaving the initial pool state unchanged. Existing runtime write isolation and before/after live inventory verification make this an online read of approved managed bytes. V1 and no-hook V2 backups retain their stopped-pool sequence.

It then runs Preflight, BeforeStop, stops/observes zero workers, runs AfterStop, replaces managed files, starts/checks readiness, runs AfterStart, verifies final files/host state and durably publishes success. Favorite Authors can compose its DDL in BeforeStop; ASAP can compose DACPAC/Hangfire work in AfterStop. The toolkit does not interpret SQL, select destructive database options or infer database compatibility.

Each script accepts only `param([string] $ContextPath)`. The UTF-8 JSON context has `contractVersion=1`, application/target/attempt identity, environment/channel, release/repository/commit, stage, verified package/support paths, external configuration path, diagnostic directory and initial/current pool/worker observations. It contains no configuration contents or credentials. The host starts the policy-pinned PowerShell with `-NoLogo -NoProfile -NonInteractive -File`, a cleared environment and bounded output/time. Ambient CI tokens are not forwarded.

Write one JSON object to standard output, with [hook-result schema 1](../schemas/hook-result.schema.json):

```json
{"contractVersion":1,"outcome":"Success","stage":"AfterStop","externalStateMayHaveChanged":true,"diagnosticId":"database-applied","requiresOperatorIntervention":false}
```

Outcome is Success/Failure. Stage must match. Diagnostics are safe identifiers, not raw SQL/native errors. Valid failure results are retained, including a nonzero exit; malformed/truncated output or a crash remains uncertain. Raw output/error streams are bounded and never logged. Scripts must synchronously await tools and leave no detached/background work. Timeout attempts process-tree termination and tracks the exact direct helper identity; arbitrary elevated code can escape process lifetime observation, so recovery additionally requires independent confirmation of helper quiescence. This is a trust contract, not containment.

## Failure and explicit recovery

Journal V3 records policy identity, stage intent before launch, possible external mutation and safe results. Once any hook is attempted, a false mutation result cannot establish unchanged persistent state. Failure, timeout, crash, invalid output or any later failure leaves RecoveryRequired. Ordinary deployment cannot bypass it through a different release/target selector.

BeforeStop failure leaves the original pool state when no IIS effect began; it does not unnecessarily stop/restart healthy previous code. After live effects, the existing bounded stop rules apply. Backups, stages, hook diagnostics and before-recovery snapshots remain protected. No automatic file/database rollback or previous-version restart occurs after hook uncertainty.

Restore requires the usual exact release/configuration/backup/helper checks plus `-PersistentStateApprovalId <id>` when hook execution may have changed external state. Infrastructure independently publishes `approvalCatalogRoot/recovery/<id>.json` using [persistent-state-approval schema 1](../schemas/persistent-state-approval.schema.json): enabled exact target/attempt/**latest journal SHA-256**, selected manifest SHA-256 and recovery mode, `externalStateCompatible=true`, `helpersQuiescentConfirmed=true`, independent authority/reference/time. This records an operator's reviewed compatibility decision, not database rollback proof. Generated release selection still needs its separate schema-1 `RecoveryApprovalId`. Recovery records the persistent-state approval ID/hash and never reruns hooks. A failed recovery changes journal bytes and needs fresh independent reconciliation authority.

## Validation-only operation

`Invoke-ClcIisDeployment ... -Operation ValidateOnly` uses the same release/target/standing authorization, lock, package/host/configuration validation and protected staging. It invokes **only** the separately declared, policy-enabled planning script, with stage Plan. It performs no backup, IIS stop/start, replacement or readiness/current publication. Success returns Planned and preserves current bytes/generation. The planning contract requires independently reviewed read-only logic; PowerShell side effects cannot be technically prevented by this process boundary. Reporting possible mutation, failure or ambiguous output blocks ordinary retry and requires reconciliation.

Plan diagnostic artifacts stay on the protected host; the reusable workflow uploads only a safe summary. Planning failure may have no deployment backup or installed candidate, so ordinary file recovery may be inadmissible and a fenced infrastructure maintenance reconciliation can be necessary. Never edit/delete a journal to retry. Prerequisite-validator PR #3 remains a separate read-only diagnostic and must never execute application validators, planning scripts or hooks.

Actual Server 2022/IIS, database integration, independent-identity acceptance and consumer adoption remain **NOT RUN**. Offline tests use disposable files, harmless processes and synthetic IIS/database observations.

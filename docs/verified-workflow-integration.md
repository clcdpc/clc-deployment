# Verified workflow integration contract

This is the revised PR #2 integration contract. It replaces the unreleased signed-receipt interface. The four module exports and published schema-1 manual approvals remain supported.

```powershell
$classification = Test-ClcRelease -ReleaseTag $tag
Invoke-ClcIisDeployment -TargetId $targetId -StandingAuthorizationId $standingId `
    -ReleaseTag $tag -ArchivePath $inboxZip -VerifiedReleasePath $inboxIdentity
```

All five Invoke parameters are mandatory in the Automated parameter set. They cannot combine with ReleaseApprovalId, AllowDowngrade or Reason. Both paths are absolute literal paths to existing regular files directly inside the protected target's artifactInboxRoot. Choose unique filenames per build; the toolkit holds both inputs against replacement during admission. No fixed input filename, signature, signing producer, verifier, network access or GitHub API client is required.

The trusted deployment workflow writes the following strict UTF-8 JSON after independently verifying GitHub provenance. Fields are required, unknown/duplicate keys are rejected, hashes and full commits are lowercase, and numeric identities are positive JSON integers within Int64. This file is evidence supplied by trusted infrastructure code; it is not authority by itself.

```json
{
  "contractFamily": "clc-file-iis-v1",
  "schemaVersion": 1,
  "recordKind": "verified-release",
  "targetId": "example-dev",
  "applicationId": "example",
  "releaseId": "example-123-1",
  "tag": "v1.0.0-dev.2",
  "sourceRepository": "owner/application",
  "sourceCommit": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "releaseZipSha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "manifestSha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
  "provenance": {
    "workflowPath": ".github/workflows/release.yml",
    "runId": 123,
    "runAttempt": 1,
    "buildJob": "release",
    "artifactId": 456,
    "transportSha256": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
  }
}
```

The inner ZIP and exact manifest bytes must match the supplied SHA-256 values. Complete package inspection verifies the manifest inventory and every application file. Manifest application/release/source and build workflow/run/attempt/job must match this identity. releaseId is the application's safe ID from its compiled release and manifest; it need not equal the classifier's tag-derived suggested releaseId. The package format is unchanged. The workflow verifies the outer Actions transport digest and artifact ownership; the toolkit retains that identity for audit and does not download or authenticate the outer transport.

Standing authorization resolves only from approvals/standing/<standingId>.json under the independently installed host policy. Its strict scope includes enabled, targetId, applicationId, environmentName, channel (DEV or Production), sourceRepository, buildWorkflowPath, buildJob, lineageId and infrastructure authorization. It contains no signing or verifier configuration. A successful independently approved baseline is required. Beta/RC remain artifact-only. Numeric tag sequence is toolkit-owned; a lower sequence or different lineage refuses.

Under the existing exclusive machine/pool lock, admission checks protected authority and input access, rejects unresolved lifecycle/admission state, verifies bytes and identities, and publishes a durable schema-2 exact approval. Its ID deterministically hashes the exact target, lineage, tag, release/source, build/artifact and package identities plus the exact standing policy. Different builds have different IDs; existing approvals are never overwritten. An immutable protected tag/source binding prevents a later rebuild substituting another source commit. A fresh run or run attempt for the same tag/commit can deploy different package bytes without advancing the tag sequence. Older builds of the installed tag cannot replace a newer build; an identical current build retries through normal fresh-readiness NoOp. Historical approvals and packages remain retained.

Admission retains the original exact JSON bytes in protected approvals/standing/<generatedApprovalId>.verified.json and their digest in admission.verifiedReleaseSha256, alongside the immutable approval and inbox <generatedApprovalId>.zip. Retry the original identity file; changed JSON bytes for an existing identity are conflicting evidence. Missing or corrupt admission material fails closed. A durable standing/<targetId>.pending intent precedes these effects and blocks ordinary deployment until infrastructure reconciles an interrupted admission.

The existing engine returns one object with status=Deployed|NoOp, attemptId, targetId, releaseId, sourceCommit, executingToolkit, currentGeneration, observedPoolState and workerCount. NoOp requires exact current identity, installed bytes, compatible unchanged configuration and fresh expected readiness. Errors terminate with stable Clc.* IDs and retained-state instructions. Pending admission or deployment requires infrastructure reconciliation or explicit recovery; no automatic repair/restore is added.

The privileged protected workflow is trusted infrastructure code. Before invoking the exact authenticated installed module it must independently establish repository identity, immutable tag/object and commit, source eligibility, reviewed workflow/support code, successful exact build job/run/attempt, artifact ID/ownership, transport digest and inner package identity. Repeat eligibility and tag checks after queueing. Obtain no executable privileged code from the artifact or arbitrary PR checkout. Restrict runner admission and credentials to that workflow, with separate DEV/production targets, environments and standing policies. The toolkit verifies its authorized elevated deployment identity and protected policy; it cannot distinguish trusted and malicious code running as that same administrator. Arbitrary downloaded JSON, a hash or Test-ClcRelease output grants no authority. This procedural boundary is unchanged from the shared administrator model.

Infrastructure installs/revokes standing policies independently and fences active writers. Revoked or byte-changed policy blocks generated approval retries, including direct ReleaseApprovalId selection. Initial installation/enrollment/baseline/cutover, toolkit changes, downgrades and exceptional recovery require separate authority. Recovery of a generated release requires an independent matching schema-1 RecoveryApprovalId, even after policy revocation.

Reference architecture inspected read-only: ssrs-web PR #1 at cdba54d0a0dff2f8d0bef4c0c7adb81055cd4ac7, especially TagRelease.Common.ps1, Test-TagReleaseAdmission.ps1 and AutomaticDeployment.Adapter.ps1. Its existing protected workflow owns the GitHub checks above. Consumer integration must adopt the final exact toolkit pin and this adapter contract under its own task. Public/private repositories use the same host API; no artifact-attestation entitlement is needed. Actual Server 2022/IIS and independent-identity/consumer qualification remain NOT RUN.

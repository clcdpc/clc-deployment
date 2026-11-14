# Standing authorization for verified workflow releases

Infrastructure can authorize routine tagged releases for one established target without manually approving each build. A protected GitHub Actions deployment workflow independently verifies source, build, artifact ownership and transport integrity. The installed toolkit checks infrastructure-owned standing policy, verifies exact package/manifest bytes, creates a durable exact approval under the machine/pool lock, and invokes the existing deployment engine.

The [consumer integration contract](verified-workflow-integration.md) defines the complete public API, required verified-release JSON, identity checks, results and trust boundary. The four exports remain unchanged. Existing schema-1 manual approvals and recovery continue to work without standing policy. Routine admission needs no artifact signing, GitHub CLI, trusted roots, reusable producer or private-repository attestation entitlement. GitHub API checks remain in trusted workflow code.

## Infrastructure setup

Independently authenticate/install an exact compatible toolkit and enroll the dedicated target. Complete a successful independently approved baseline before enabling standing authority. Infrastructure writes an explicit protected policy at approvalCatalogRoot/standing/<standingAuthorizationId>.json, retaining the same infrastructure ownership, structural ACLs and runtime write isolation as exact approvals. Never grant the deployment account's individual SID protected-resource write access. The authorized elevated administrator remains procedurally trusted; hashes and NTFS do not contain it.

The strict [standing schema](../schemas/standing-authorization.schema.json) and [synthetic example](../tests/Fixtures/standing-authorization.json) define application, target, environment, DEV|Production channel, source repository, build workflow/job, lineage, enablement and independent authorization. Use separate policies, target IDs and protected workflow environments for DEV and production. Infrastructure supplies a lineage compatible with the baseline's approval. Deployment/enrollment never creates or enables the policy. Initial setup/cutover, toolkit changes, downgrades and exceptional recovery require separate authority.

## Trusted Actions admission

The recommended [GitHub setup](github-setup.md) uses tag-driven release builds and trusted automatic deployment consumers from protected code. A consumer release workflow may permit `workflow_dispatch` for fresh builds against existing immutable tags; it is not a manual IIS deployment trigger. Successful completion still enters the same automatic verification/admission path. Infrastructure independently approves environment gates and activation; unattended routine deployment does not require per-run human review.

Restrict privileged runners and deployment credentials to reviewed protected workflow code. Verify GitHub repository identity, immutable tag/object and source commit, source eligibility, reviewed producer files, successful exact build run/attempt/job and immutable artifact ownership. Download only that artifact, verify the service transport SHA-256, inspect the inner package and exact manifest, and repeat tag/source/eligibility checks after queueing. Do not execute artifact scripts or PR code on the privileged host. Both a tag push and a fresh successful run against an existing immutable tag can qualify; the workflow owns GitHub event eligibility.

Use Test-ClcRelease -ReleaseTag for shared classification: v1.0.0-dev.1 is DEV, v1.0.0 is Production, beta/RC are ArtifactOnly. It returns numeric releaseSequence and a suggested tag-derived releaseId without host access or execution authority. The manifest/compiled application may keep its own safe releaseId, including a run-derived identity.

After verification, place unique ZIP and verified-release JSON files directly in the target inbox with approved access controls. Invoke the Automated parameter set in the integration contract. The JSON is an integrity/audit claim produced by trusted infrastructure code; an arbitrary downloaded JSON file or inspection result cannot authorize execution. Only protected standing policy plus the admitted elevated workflow identity can authorize the exact matching bytes. The toolkit cannot authenticate which code an already admitted administrator is executing.

## Exact approval, ordering and rebuilds

Admission requires clean durable state and a successful baseline. It verifies the complete ZIP and manifest inventory, source/build fields, policy scope and numeric tag ordering before publishing new authority. Approval IDs hash canonical target/lineage/tag/source/release/build/artifact/package identity and exact standing policy. Exact retry identities reuse the original immutable approval; conflicting existing approval evidence refuses. Original JSON bytes are retained at standing/<generatedApprovalId>.verified.json under protected catalog access, with their byte digest in admission. Equivalent fields with different JSON formatting reuse the original approval and evidence without overwriting it.

Each first admitted tag also publishes an immutable protected release-tag-binding under standing/tag-<SHA256>.json, binding target/application/lineage/tag/repository/commit. It prevents commit substitution even after an independently authorized rollback. Approval and tag binding are create-new records; no history is overwritten or automatically cleaned up. Published package/manual approval/current/journal formats are unchanged; the unmerged proposed schema-2 approval is replaced with admission.standingAuthorizationId/standingAuthorizationSha256/tag/verifiedReleaseSha256.

A later runId, or greater runAttempt within the same run, may rebuild the same tag/commit with new ZIP bytes and its own releaseId/exact approval. It retains the same numeric tag sequence. Older tags remain downgrades; older builds of the installed tag or changed bytes for the same run/attempt refuse. The normal engine decides Deployed versus exact current NoOp after fresh installed-byte/configuration/readiness checks. An independently approved baseline of the same numeric sequence must have the same repository/commit and an older build for automatic replacement.

## Interruption, revocation and recovery

A durable standing/<targetId>.pending intent precedes tag binding, retained inbox ZIP and exact approval effects. Atomic publication consumes the intent only after the retained material exists. A crash retains evidence and blocks routine retry; unknown/partial material requires infrastructure maintenance, never deletion of intent or editing journals to bypass refusal. Deployment then uses its existing phase journal, bounded stop/backup/replacement/start/readiness and explicit recovery rules. An incomplete deployment cannot be replaced by a fresh same-tag build.

Disable/remove or byte-change the protected policy to revoke routine authority. Generated approvals recheck the original exact enabled policy even when selected directly with ReleaseApprovalId. Fence changes against active processes holding policy handles. Existing approvals remain retained; re-enablement or policy replacement requires independent review and does not rewrite history.

Generated approvals never authorize exceptional recovery. Supply an independent schema-1 exact RecoveryApprovalId matching selected target/source/build/lineage/package identity. That recovery can proceed after standing revocation if all ordinary bytes, compatibility, backup and helper-quiescence requirements pass. No automatic restore, database rollback inference or reboot activation fence is introduced. See [deployment/recovery](deployment.md).

## Qualification and consumer handoff

Offline tests exercise actual NTFS inputs, exact approvals, canonical locking and durable lifecycle state with synthetic IIS/identity observations. Full package/distribution checks remain required. The reference ssrs-web architecture was inspected at fixed source cdba54d0a0dff2f8d0bef4c0c7adb81055cd4ac7; its separate task owns the adapter, workflow checks and compatible immutable toolkit pin. No consumer changes or live infrastructure activation are part of this toolkit task. The shared deployment-prerequisites validation workflow is outside this scope.

Actual Windows Server 2022/IIS, independent service-identity access enforcement, privileged runner admission and consumer deployment/recovery acceptance remain NOT RUN. Follow the [separately authorized real-host procedure](iis-verification.md).

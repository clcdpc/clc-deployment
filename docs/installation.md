# Toolkit installation and activation

Enter from [setup section 8](setup-guide.md#8-prepare-deployment-hosts) after host prerequisites. Initial order: bootstrap preparation → enrollment preparation/authorization → Apply installs/activates toolkit → verification below → first application deployment. Build-time `orchestration.sharedRevision` never authorizes host installation or activation.

The application-based ProgramData layout requires a newly published, independently approved format-3 distribution that implements it. Beta.4 derives the root from the target ID. Existing target-derived installations require independently scoped reconciliation before adopting the corrected layout. See the [distribution reference](contracts.md#toolkit-distribution-reference) and [beta.4 source](https://github.com/clcdpc/clc-deployment/tree/557192eff5eea651d6f1a393eb3b196053a985e5).

## Initial bootstrap provisioning

1. **On a trusted infrastructure workstation**, select the full version, source commit and producer run/job/artifact. Authenticate these through the reviewed upstream release process and retain the exact archive SHA-256 in infrastructure change evidence. Download the selected ZIP from its [release](https://github.com/clcdpc/clc-deployment/releases). Review the verifier, extractor and dependencies from that exact source through an already trusted channel, before executing them. An adjacent identity file or archive cannot authenticate its own verifier.

   An authenticated read-only GitHub CLI session can obtain identity claims for the selected release tag and download its exact versioned asset into a new local directory:

   ```powershell
   gh api "repos/clcdpc/clc-deployment/releases/tags/$selectedTag" `
       --jq '{tag: .tag_name, source: .target_commitish, assets: [.assets[] | {id, name, digest}]}'
   gh release download $selectedTag --repo clcdpc/clc-deployment `
       --pattern "Clc.Deployment-$selectedVersion.zip" --dir $newAcquisitionDirectory
   ```

   The ZIP asset's `sha256:` digest is the archive digest; an Actions transport ZIP has a different digest. Independently reconcile asset/source claims with the retained successful `build-test-publish` producer run/job/artifact and [release-manifest](releasing.md#version-identity), then approve the selected bytes. The version/source/digest variables below come from that independent decision, never automatic acceptance of adjacent metadata.

2. **On the intended host**, follow [host preparation steps 1–4](host-enrollment.md#1-inspect-and-prepare-the-host) through namespace creation, then return here for step 3. Keep the authenticated archive and reviewed tools in infrastructure-protected local preparation storage outside `Deployment`.
3. **In a fresh elevated PowerShell 7 process**, set `$reviewedTools` to that trusted tools directory; `$zip`, `$approvedDigest`, `$approvedSource`, `$approvedVersion` and `$changeReference` come from independent acquisition/installation review. Verify:

```powershell
$verified = & "$reviewedTools\Test-ToolkitDistribution.ps1" `
    -ArchivePath $zip -ExpectedSha256 $approvedDigest `
    -ExpectedSourceCommit $approvedSource -ExpectedVersion $approvedVersion `
    -RequireInfrastructureTools
$verified | Select-Object integrityVerified,authenticatedByThisCheck,formatVersion,
    moduleVersion,sourceCommit,distributionSha256,inventorySha256
```

Success is `integrityVerified=true`, `formatVersion=3`, matching identities, and `authenticatedByThisCheck=false`. The returned **inventorySha256** is the actual module inventory digest required by `activeToolkit`; it is neither the ZIP hash nor the bootstrap executable digest.

4. Prepare an unused infrastructure-owned `versions` staging directory **outside the target's Deployment tree**. `$preparedVersion` must be its new `<approvedVersion>` child. The existing extractor requires this shape; it is not a bootstrap installer:

```powershell
$extracted = & "$reviewedTools\Expand-ToolkitDistribution.ps1" `
    -ArchivePath $zip -ExpectedSha256 $approvedDigest `
    -ExpectedSourceCommit $approvedSource -ExpectedVersion $approvedVersion `
    -VersionRoot $preparedVersion -OperatorApprovalReference $changeReference
```

5. After successful extraction (`extracted=true`, `activated=false`), independently protect the extracted tree and its destination ancestors. Move the complete prepared directory to the **absent** `$bootstrapRoot` at native `%ProgramData%\clc-<application-id>\Deployment\bootstrap`. Use `Move-Item -LiteralPath $preparedVersion -Destination $bootstrapRoot` only after verifying both absolute paths and destination absence. Do not merge with an existing bootstrap. It contains exactly `Clc.Deployment`, `tools`, `source.commit` and `distribution.zip`. Failed extraction remains unactivated evidence outside Deployment.
6. Recheck installed bytes at the final location:

```powershell
$bootstrapVerified = & "$reviewedTools\Test-ToolkitDistribution.ps1" `
    -ArchivePath "$bootstrapRoot\distribution.zip" -ExpectedSha256 $approvedDigest `
    -ExpectedSourceCommit $approvedSource -ExpectedVersion $approvedVersion `
    -InstalledModuleRoot "$bootstrapRoot\Clc.Deployment" -RequireInfrastructureTools
```

Success: exact bytes, protected ownership/ancestors and expected four-entry layout. Never execute an arbitrary source checkout as the bootstrap. **Next:** [protect the enrollment handoff/configuration](host-enrollment.md#protect-the-handoff-and-configuration), then complete enrollment sections 2–5. Return to [verification below](#verification-and-activation) after Apply.

## First authorized toolkit installation

This is [enrollment section 5](host-enrollment.md#5-inspect-plan-apply-and-verify), after sections 1–4 prepare configuration, observations and protected independent authorization. Follow that procedure for Inspect/Plan/Apply; next, perform [verification below](#verification-and-activation).

Apply installs the independently approved immutable version under `Deployment\toolkit\versions\<version>`, creates protected policy/catalog/control/lock resources, activates the initial exact pin and publishes the verified target last. It never upgrades an existing active pin. Do not preinstall a version beneath Deployment before initial enrollment: partial toolkit/control/lock resources require reconciliation.

## Verification and activation

Prerequisite: enrollment Apply completed and [Get-ClcHostEnrollment](host-enrollment.md#5-inspect-plan-apply-and-verify) reports `Ready` and `ReadyForDeployment=true`. Initial activation already occurred in Apply. Independently compare protected `Deployment\toolkit\policy\host-policy.json` with the approved policy, including generation and every `activeToolkit` field. Verify the retained ZIP and installed module with `Test-ToolkitDistribution.ps1`, using the same command above and the installed version's paths.

Start a fresh `pwsh -NoLogo -NoProfile -NonInteractive` and import **that exact approved manifest** for deployment. Enrollment readiness does not approve a release or establish application readiness. **Next:** initial setup → [first application deployment](deployment.md#first-application-deployment), roadmap stage 6; approved upgrade → [routine operation](setup-guide.md#10-routine-operation).

## Later independently approved upgrades

For an existing installation only, under separate upgrade approval. Afterwards, repeat [verification](#verification-and-activation), then resume [normal operation](setup-guide.md#10-routine-operation).

1. Infrastructure fences deployment/enrollment processes and policy writers. Preserve previous distributions, policy history, approvals, current/journal, attempts and backups; review retained-state/application compatibility.
2. Authenticate the replacement archive. Extract to a new exact `Deployment\toolkit\versions\<version>` directory; never overwrite an installed version. Verify bytes, owner/DACL/ancestor replacement rights and effective runtime isolation.
3. Independently replace protected host policy with next generation and exact `activeToolkit` version/source/distribution digest/module inventory/absolute manifest. **No general activation command exists.** Extractor `OperatorApprovalReference` records a reference without authenticating approval or activating code.
4. Use a fresh process/new manifest and update the independent inspection handoff when needed. Inspect the target; prove an old inactive manifest refuses before effects. Interrupted publication/incompatible state requires fenced maintenance; retain both versions/evidence.

For the separately authorized disposable harness only, `Set-QualificationToolkit.ps1 -Operation Inspect` and its independently authorized `activate-compatible-toolkit` procedure retain campaign-specific policy/history checks. It is not a production installer. See [IIS verification](iis-verification.md) and [testing/toolchain evidence](testing.md). **Real IIS and compatible-toolkit recovery qualification remain NOT RUN.**

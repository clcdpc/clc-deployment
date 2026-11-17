# Toolkit installation and activation

Follow [setup](setup-guide.md) for the overall sequence and [host enrollment](host-enrollment.md) for exact authorization. Infrastructure installs each target independently. Build-time `orchestration.sharedRevision` selects packaging/workflow code; it never authorizes host installation or activation.

Published [v0.1.0-beta.4](https://github.com/clcdpc/clc-deployment/releases/tag/v0.1.0-beta.4), from [557192e](https://github.com/clcdpc/clc-deployment/tree/557192eff5eea651d6f1a393eb3b196053a985e5), includes format-3 `Clc.Deployment-0.1.0-beta.4.zip`. Publication is acquisition evidence, not installation approval. Historical format-1/2 distributions retain `CLC.Deployment` naming and cannot initialize this architecture. See [distribution reference](contracts.md#toolkit-distribution-reference) for format and reproduction details.

## Initial bootstrap provisioning

1. **On a trusted infrastructure workstation**, select the full version, source commit and producer run/job/artifact. Authenticate these through the reviewed upstream release process and retain the exact archive SHA-256 in infrastructure change evidence. Download the selected ZIP from its [release](https://github.com/clcdpc/clc-deployment/releases). Review the verifier, extractor and dependencies from that exact source through an already trusted channel, before executing them. An adjacent identity file or archive cannot authenticate its own verifier.

   For beta.4 acquisition, an already authenticated read-only GitHub CLI session can obtain public identity claims and download the selected asset into a new local directory:

   ```powershell
   gh api repos/clcdpc/clc-deployment/releases/tags/v0.1.0-beta.4 `
       --jq '{tag: .tag_name, source: .target_commitish, assets: [.assets[] | {id, name, digest}]}'
   gh release download v0.1.0-beta.4 --repo clcdpc/clc-deployment `
       --pattern Clc.Deployment-0.1.0-beta.4.zip --dir $newAcquisitionDirectory
   ```

   The ZIP asset's `sha256:` digest is the archive digest; an Actions transport ZIP has a different digest. Independently reconcile asset/source claims with the retained successful `build-test-publish` producer run/job/artifact and [release-manifest](releasing.md#version-identity), then approve the selected bytes. The version/source/digest variables below come from that independent decision, never automatic acceptance of adjacent metadata.

2. **On the intended host**, infrastructure creates/protects the target root, `Deployment`, `Config` and enrollment handoff as described in [enrollment prerequisites](host-enrollment.md#1-inspect-and-prepare-the-host). Use native ProgramData. Keep the authenticated archive and reviewed tools in an infrastructure-protected local preparation directory outside `Deployment`.
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

5. After successful extraction (`extracted=true`, `activated=false`), independently protect the extracted tree and its destination ancestors. Move the complete prepared directory to the **absent** `$bootstrapRoot`, the target's exact `Deployment\bootstrap`. Use `Move-Item -LiteralPath $preparedVersion -Destination $bootstrapRoot` only after verifying both absolute paths and destination absence. Do not merge with an existing bootstrap. It contains exactly `Clc.Deployment`, `tools`, `source.commit` and `distribution.zip`. Failed extraction remains unactivated evidence outside Deployment.
6. Recheck installed bytes at the final location:

```powershell
$bootstrapVerified = & "$reviewedTools\Test-ToolkitDistribution.ps1" `
    -ArchivePath "$bootstrapRoot\distribution.zip" -ExpectedSha256 $approvedDigest `
    -ExpectedSourceCommit $approvedSource -ExpectedVersion $approvedVersion `
    -InstalledModuleRoot "$bootstrapRoot\Clc.Deployment" -RequireInfrastructureTools
```

Success: exact bytes, protected ownership/ancestors and expected four-entry layout. Never execute an arbitrary source checkout as the bootstrap. [Enrollment preparation](host-enrollment.md#3-collect-observations-and-prepare-the-candidate) obtains the separate bootstrap executable inventory.

## First authorized toolkit installation

Complete [enrollment preparation and independent approval](host-enrollment.md#4-independently-approve-and-install-the-handoff) first, including configuration, native observations and the protected exact authorization. Then run Inspect and Plan, review their operations, and invoke the documented `Initialize-ClcHostEnrollment.ps1 -Operation Apply -DistributionPath` command.

Apply installs the independently approved immutable version under `Deployment\toolkit\versions\<version>`, creates protected policy/catalog/control/lock resources, activates the initial exact pin and publishes the verified target last. It never upgrades an existing active pin. Do not preinstall a version beneath Deployment before initial enrollment: partial toolkit/control/lock resources require reconciliation.

## Verification and activation

After Apply, [Get-ClcHostEnrollment](host-enrollment.md#5-inspect-plan-apply-and-verify) must report `Ready` and `ReadyForDeployment=true`. Independently compare protected `Deployment\toolkit\policy\host-policy.json` with the approved policy, including generation and every `activeToolkit` field. Verify the retained ZIP and installed module with `Test-ToolkitDistribution.ps1`, using the same command above and the installed version's paths.

Start a fresh `pwsh -NoLogo -NoProfile -NonInteractive` and import **that exact approved manifest** for deployment. Enrollment readiness does not approve a release or establish application readiness. Follow [first deployment](deployment.md#first-application-deployment) separately.

## Later independently approved upgrades

Infrastructure fences active deployment/enrollment processes and competing policy writers, preserving previous distributions, policy history, approvals, current/journal, attempts and backups. Review compatibility with retained state and application contracts. Authenticate the replacement archive and use the extractor above with a new exact `Deployment\toolkit\versions\<version>` directory. Never overwrite an installed version.

Verify installed bytes, owner/DACL/ancestor replacement rights and effective runtime isolation. Infrastructure then independently replaces the protected host policy with its next generation and exact `activeToolkit` version, source, distribution digest, module inventory and absolute manifest path. There is **no general activation command**. Installation's `OperatorApprovalReference` records a reference; it does not authenticate approval or activate code.

Use a fresh process with the new manifest. Obtain an updated independent enrollment inspection handoff when necessary, inspect the target and prove an old inactive manifest refuses before privileged effects. Interrupted publication or incompatible retained state requires fenced maintenance; keep both versions and evidence. DEV and Production policies can pin different versions on the same machine.

For the separately authorized disposable harness only, `Set-QualificationToolkit.ps1 -Operation Inspect` and its independently authorized `activate-compatible-toolkit` procedure retain campaign-specific policy/history checks. It is not a production installer. See [IIS verification](iis-verification.md) and [testing/toolchain evidence](testing.md). **Real IIS and compatible-toolkit recovery qualification remain NOT RUN.**

# Toolkit distribution, independent verification and activation

The shared release version comes from `v<version>` tags; root [`VERSION`](../VERSION) is the untagged development fallback. Stable and prerelease versions are supported; see [shared release rules](releasing.md). Publication does not approve installation or execution. Source commit, archive SHA-256 and module inventory distinguish immutable distributions; the version label alone never selects code. There is no automatic latest resolution or application-bundled engine. **Actual Server 2022/IIS qualification remains NOT RUN**; follow the [practical procedure](iis-verification.md) under separate authorization.

## Trust before first import

The infrastructure operator independently authenticates the exact repository revision, producer workflow/run/job/artifact and archive digest. Review the verifier scripts at that revision through an already trusted workstation/channel. Do not execute a verifier obtained from an unauthenticated archive to authenticate that archive. Adjacent `*.identity.json`, a build log, an inspection result and `distribution.json` are integrity claims. None grants installation or application execution authority.

The build and verifier are ordinary repository tools outside `CLC.Deployment`. They never import distribution code during inspection. Review [Distribution.Common](../tools/Distribution.Common.ps1), [build](../tools/New-ToolkitDistribution.ps1), [verify](../tools/Test-ToolkitDistribution.ps1) and [extract](../tools/Expand-ToolkitDistribution.ps1). The verifier uses trusted .NET metadata/native path readers, not the archive's scripts. SHA-256 supplied to verification must come from the independent approval procedure.

## Distribution formats and reproducibility

Format 1 contains exactly `CLC.Deployment/` runtime files, `source.commit` (40 lowercase ASCII bytes, no newline), and `distribution.json`. Existing approved format-1 installations remain verifiable/reusable. Format 2 adds the exact eight infrastructure files returned by `Get-DistInfrastructureNames` under `tools/`, including `tools/host/`; it is required for first automated installation. These files stay outside the module and app release packages. No tests, policy, approvals, targets, operational config, keys, credentials or generated state are installed in the module tree. `distribution.json` contains:

| Field | Meaning |
| --- | --- |
| distributionFormat / formatVersion | `clc-toolkit-distribution` / integer `1` or `2`; unsupported shapes refuse |
| sourceCommit / moduleVersion | Exact committed HEAD and full stable or prerelease module version |
| files / inventorySha256 | Complete module-relative path/length/SHA-256 inventory and digest matching the module's installed-tree algorithm |
| infrastructureFiles / infrastructureInventorySha256 | Format 2 only: complete version-relative infrastructure inventory, also checked against committed source; strict allowlist, no arbitrary scripts |
| sourceFiles / sourceInventorySha256 | Complete committed repository file inventory; source contents are not bundled as executable runtime dependencies |
| toolchain | Actual PowerShell, .NET runtime hosting PowerShell and Git versions |
| reproducibility | Fixed timestamps/stored entries/sorting and explicit cross-toolchain limitations |

The inventory digest hashes ordinal-sorted UTF-8 `path + NUL + invariant decimal length + NUL + lowercase sha256 + LF`. The archive cannot contain its own digest. The build returns its actual SHA-256 and writes a separate identity file. This is not a signature or authentication system.

The builder requires a full lowercase 40-character commit equal to HEAD, a clean tracked/untracked working tree, and an archive matching the complete Git tree. It verifies committed blob bytes, avoiding worktree CRLF conversion, then stamps the output manifest when `-ReleaseVersion <tag-version>` is supplied. All other module files must match the source inventory; the manifest version must match the expected release version. Output must be new. Two builds from the same commit, release version and toolchain must have identical ZIP bytes. Different Git/PowerShell/.NET versions recorded in metadata can change the archive digest. Rebuilt application artifacts are never asserted to be original retained artifacts.

Run from a reviewed checkout, with explicit absolute paths:

```powershell
$source = (git rev-parse HEAD).Trim()
& .\tools\New-ToolkitDistribution.ps1 -RepositoryRoot $repository -SourceCommit $source -OutputPath $candidateZip
& .\tools\Test-ToolkitDistribution.ps1 -ArchivePath $candidateZip -ExpectedSha256 $independentlyApprovedDigest -ExpectedSourceCommit $source -ExpectedVersion '0.1.0-dev.1'
```

Keep build output outside tracked source, or under ignored `artifacts/`. Verification rejects duplicate/ambiguous JSON, unknown/missing/extra archive entries, unsafe names, wrong bytes/source/version/inventory, and missing/modified/unexpected installed files or directories. Installed inspection also rejects NTFS aliases, reparse paths, hard links, named streams and unknown/case-sensitive directory mode. Deployment later repeats its stronger protected-policy/access observations. Integrity inspection deliberately returns `authenticatedByThisCheck=false`.

## Installation

Use the fixed [machine enrollment layout](host-enrollment.md#trust-and-prerequisites):

```text
<enrollment>/toolkit/versions/<full-version>/CLC.Deployment/...
<enrollment>/toolkit/versions/<full-version>/source.commit
<enrollment>/toolkit/versions/<full-version>/distribution.zip
<enrollment>/toolkit/policy/host-policy.json
<enrollment>/toolkit/policy/targets/<targetId>.json
<enrollment>/toolkit/policy/approvals/<approvalId>.json
<enrollment>/toolkit/policy/approvals/standing/<standingAuthorizationId>.json # optional
<enrollment>/locks/<actual-targetKey>.lock
<enrollment>/control/<actual-targetKey>/...
```

The fixed control root must fit the existing 71-character root budget; locks fit the 170-character budget. Application, inbox, external configuration directory, external keys, trust/policy, control and locks remain disjoint. The disposable harness applies a shorter root bound. Use paths from its checked local configuration; these diagrams invent no production location.

Optional [standing authorization](automated-deployments.md) requires a compatible installed toolkit and independently protected target-scoped policy. Trusted workflow code establishes GitHub provenance before host admission; no additional verifier or signing dependency is installed. Existing manual approvals/installations need no new directory or dependency. Generated approval schema 2 requires a compatible toolkit; retain that compatibility when independently planning toolkit replacement.

1. Authenticate source and exact archive through the independent infrastructure procedure. Review all changes and producer pins. For GitHub output, verify authenticated run/job/head/artifact ID and service transport digest, then independently inspect the inner toolkit ZIP. Retain those observations under infrastructure ownership and normal ACLs, with independent backups; deployment administrator containment is unavailable.
2. As infrastructure, create a new version directory with infrastructure ownership and read/execute-only deployment access. Its parent must prevent runtime replacement through delete-child, DACL or owner rights and reject unexpected structural write grants. Elevated deployment can inherit Administrators authority; do not add its direct SID as a protected writer or claim NTFS containment. Do not reuse or patch an installed version.
3. Use the independently reviewed extractor with independently approved source/digest/version. It creates only a new version under `versions`, verifies before extraction and after installation, retains the exact distribution and source identity, and imports nothing:

```powershell
& .\tools\Expand-ToolkitDistribution.ps1 -ArchivePath $candidateZip -ExpectedSha256 $approvedDigest -ExpectedSourceCommit $approvedSource -ExpectedVersion $approvedVersion -VersionRoot $newVersionRoot -OperatorApprovalReference $changeReference
```

4. Verify every installed byte and unexpected-directory rejection with `Test-ToolkitDistribution -InstalledModuleRoot`. Verify owner/DACL inheritance and all ancestor replacement rights under actual deployment/runtime tokens. Do not rely on descriptor inspection alone.
5. Independently update protected `host-policy.json` with its next generation and exact `activeToolkit` version/source/archive/inventory/absolute manifest path. The module does not create or authenticate that first-import trust. A failed extraction remains unactivated material for inspection.
6. Start a fresh approved `pwsh -NoLogo -NoProfile -NonInteractive` using that exact manifest. Invoke/Restore require the exact deployment SID and enabled elevated local Administrators role and recheck active identity/protected dependencies before execution; New/Test remain build/inspection commands. Approved app validation runs elevated. Independent approval stays outside the deployment command path. Test an old inactive manifest explicitly; it must refuse before application execution/IIS/content mutation.
7. Retain old distributions, source identities, producer evidence, approvals and all state needed for compatibility/recovery. Installation is not qualification; follow the [practical real-IIS procedure](iis-verification.md).

The [host enrollment interface](host-enrollment.md) automates first installation/activation and target provisioning under exact independent authority; it never upgrades an active pin. The qualification-only provisioning script combines these infrastructure steps for an authorized disposable campaign. It is outside the installed module. It neither provisions IIS from a public deployment command nor grants itself application approvals.

## Defective toolkit and compatible replacement

Fence the existing deployment process and independent writers before activation. Preserve A's exact distribution, source, protected policy, journal/current, original attempt and retained release/backup evidence. An active process can retain open policy handles; do not work around those protections.

Review and build B from a real committed revision, with a different full shared version and separate protected directory. Do not fabricate A or B identities. Review B's strict state/app contract support and old-state regressions. Use `Set-QualificationToolkit.ps1 -Operation Inspect` first. For an authorized disposable replacement, supply original and replacement local configurations plus a separately protected authorization for `activate-compatible-toolkit`; only the toolkit pin and approval reference may differ. The script independently verifies/extracts B, preserves prior policy/ownership records, advances the protected active pin and rebinds campaign metadata. It never edits application/current/journal evidence or recovers automatically. Interrupted policy/marker publication requires operator reconciliation, preserving both versions.

Use a fresh B process for preflight and explicit RestorePrevious/AcceptCandidate/RestoreEmpty as admissible. Recovery must preserve A's original execution pin and record B's actual pin. Independently prove A now refuses. If B cannot read supported retained state safely, stop and use the fenced maintenance procedure; no force/reset/migration is added. Actual compatible-toolkit replacement remains an unrun real-host gate.

## Producer and dependency evidence

Hosted verification remains Windows Server 2022, PowerShell **7.6.6** and Pester **5.7.1**, with the original independently verified [lock](../tools/dependencies.lock.json). Probe builds use SDK **10.0.403** / runtime **10.0.14**, whose Windows x64 ZIP SHA-512 is pinned from [Microsoft release metadata](https://builds.dotnet.microsoft.com/dotnet/release-metadata/10.0/releases.json) in [probe-sdk.lock.json](../tools/probe-sdk.lock.json). No NuGet package dependency is introduced; both projects retain locked framework graphs. SDK provisioning is local to the test job, with automatic development-certificate generation disabled; it does not install or trust certificates on the qualification host.

Checkout stays pinned at `08c6903cd8c0fde910a37f88322edcfb5dd907a8`. Candidate retention uses `actions/upload-artifact` v6.0.0 pinned to exact revision `b7c566a772e6b6bfb58ed0dc250532a479d7789f`, matching the current [build-test-publish workflow](../.github/workflows/build-test-publish.yaml). The PR job has contents-read permission, no infrastructure credentials, no privileged runner, no deployment job and no `pull_request_target` route. PR checkout explicitly selects its exact head. Successful hosted output retains two identical toolkit builds, installed-byte verification, two compatible probe releases, nine separately identified negative fixtures and `candidate-evidence.json`. Build output is unapproved until the independent procedure above.

Use the producing run's exact source/archive/inventory pins from `candidate-evidence.json`. A version label or a previous commit's checks cannot establish installed-byte identity, independent approval or host qualification.

## Automated setup and retained first-import boundary

The independently protected packaged bootstrap and fixed authorization handoff must be authenticated before code executes. Get/Plan read only; Apply installs exact approved format-2 bytes in the fixed machine enrollment, sets infrastructure ownership/ACLs, creates the v1 policy/catalog/control/lock structure, activates the exact initial pin and verifies it. Policy plus target publication and live facts establish initialization; no sentinel is created. The standalone extractor now holds the archive against write/delete across verification/extraction/retention and bounds streamed entries, total bytes and elapsed time. A failed version is retained and never overwritten. Existing valid active distributions are reused; a different supplied candidate is not an upgrade request. See the [runbook](host-enrollment.md) for all fixed paths, approvals, additional targets and stopped legacy cutover.

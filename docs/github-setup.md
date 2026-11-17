# GitHub setup reference

Use [setup sections 2–7](setup-guide.md#2-restrict-github-actions) for the configuration checklist. This reference covers policy interactions and privileged runner boundaries.

## Effective policies

GitHub [workflow execution policies](https://docs.github.com/en/actions/how-tos/administer/control-workflow-execution) layer across repository, organization and enterprise. **Restrict actors** controls who can trigger workflows; it does not authorize tag creation. Review policy insights and inherited scope. If API visibility is incomplete, inspect the effective policy in GitHub. The optional [checker](github-setup-check.md) reports CHECK MANUALLY for facts it cannot establish.

For [tag rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets), **Restrict creations** admits only bypass actors. Empty bypass blocks all matching creations; pull-request-only bypass cannot create a tag. Use **Always allow** for deliberately selected release creators. Keep update/deletion restrictions in another ruleset: bypass applies to every rule in its ruleset. A creator must satisfy every applicable creation restriction, including inherited rules, exclusions and repository permissions. Verify native team/role membership; CLC maintains no actor list.

[Release immutability](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases) protects published canonical assets separately from prepublication tag rules. Enabling it does not make an existing mutable Release immutable. Application publication requires actual API Boolean `immutable=true` for new, existing and racing published Releases. Missing/malformed/false evidence fails, retains the Release and blocks dependent deployment; there is no automatic deletion or repair. See [publication behavior](shared-release-orchestration.md#publication-and-deployment).

## Privileged runners

Deployment selects labels only: `self-hosted`, `Windows`, `X64`, `<applicationId>-dev|production`. Repository runners need no group. Organization runners require repository access; an inherited exact-workflow allowlist must permit the deliberately chosen tagged shared pin. No per-PR allowlist update or routing variable is part of routine setup.

Keep contributor PR CI and `pull_request_target` checkouts away from privileged hosts/credentials. Authorized release creators deliberately trust executable workflows, scripts, configuration and shared pins at their tagged source. DEV need not have merged or received PR approval. Production must belong to protected integration history. Approved validation/hooks run elevated without a sandbox; independent infrastructure approval is procedural against that administrator.

The existing single workflow qualifies its completed producer job, publishes and then deploys through success-dependent jobs. The producer can qualify while the overall run remains in progress. No default-branch `workflow_run` handoff, checker activation flag or manual release dispatch is needed. See [workflow integration](verified-workflow-integration.md).

Host [enrollment](host-enrollment.md), [baseline](deployment.md#first-application-deployment), [standing policy](automated-deployments.md) and exceptional recovery retain independent authority. GitHub configuration observations do not qualify an IIS host or consumer. Actual runner-policy and Windows/IIS acceptance remain **NOT RUN** by repository tests.

# GitHub setup reference

Use [setup sections 2–7](setup-guide.md#2-restrict-github-actions) for the configuration checklist. This reference covers policy interactions and privileged runner boundaries.

## Effective policies

Review repository, organization and enterprise [workflow execution policies](https://docs.github.com/en/actions/how-tos/administer/control-workflow-execution). **Restrict actors** controls workflow triggers; tag creation needs separate authority. Inspect insights/inherited scope in GitHub when APIs lack visibility; the [checker](github-setup-check.md) marks unverified facts CHECK MANUALLY.

For [tag rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets):

- **Restrict creations** admits only bypass actors. Empty bypass blocks matching tags; PR-only bypass cannot create them. Select release creators with **Always allow**.
- Separate update/deletion rules: bypass applies to every rule in its ruleset.
- Verify every applicable restriction, inherited rule, exclusion, repository permission and native team/role membership. CLC maintains no actor list.

[Release immutability](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases) separately protects published assets; enabling it leaves existing mutable Releases unchanged. New/existing/racing publication requires actual API Boolean `immutable=true`. Missing/malformed/false evidence preserves the Release and blocks deployment, without automatic deletion/repair. See [publication](shared-release-orchestration.md#publication-and-deployment).

## Privileged runners

| Runner setting | Requirement |
| --- | --- |
| Labels | `self-hosted`, `Windows`, `X64`, `<applicationId>-dev` or `<applicationId>-production` |
| Repository runner | No group required |
| Organization runner | Repository access; inherited exact-workflow allowlists admit chosen tagged shared pin |
| Routine routing | No per-PR allowlist update or routing variable |

Keep contributor PR CI/`pull_request_target` checkouts away from privileged hosts/credentials. Tag creators trust executable workflows/scripts/configuration/shared pins: DEV may be unmerged without PR approval; Production requires protected integration ancestry. Validators/hooks run elevated without sandboxing; independent approval against that administrator remains procedural.

The single workflow qualifies its completed producer job (overall run may remain in progress), publishes, then deploys through success-dependent jobs. No default-branch `workflow_run` handoff, checker activation flag or manual dispatch is needed; see [workflow integration](verified-workflow-integration.md).

Host [enrollment](host-enrollment.md), [baseline](deployment.md#first-application-deployment), [standing policy](automated-deployments.md) and exceptional recovery retain independent authority. GitHub configuration observations do not qualify an IIS host or consumer. Actual runner-policy and Windows/IIS acceptance remain **NOT RUN** by repository tests.

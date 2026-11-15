# Optional GitHub deployment setup check

This diagnostic answers whether the requested GitHub settings were observed and match the expected configuration. It grants no deployment authority and establishes no application security, compatibility or operational readiness. Start with the [Deployment Setup Guide](setup-guide.md); host preparation, deployment preflight, authorized deployment and application acceptance remain separate.

**Expect manual checks with the default `GITHUB_TOKEN`.** It cannot request repository Administration, Variables or organization Self-hosted runners permissions. Even a read-only GitHub App token cannot reliably reveal ruleset bypass actors. Missing evidence never becomes a configured result.

## API inventory and capabilities

The inventory below was checked against GitHub.com's current REST documentation before implementation. All requests are GETs. `R` means `/repos/{owner}/{repo}` for the caller from the Actions context; `O` means `/orgs/{owner}`. The checker supports GitHub.com, not Enterprise Server API variants.

| Category and endpoints | What can be established | Ordinary GITHUB_TOKEN | Optional read-only GitHub App | Manual GitHub UI inspection |
| --- | --- | --- | --- | --- |
| Branch: `R/branches`, `R/branches/{branch}/protection`, `R/rules/branches/{branch}`, `R/rulesets/{id}` | Existence, classic controls, active effective rules and visible bypass | Contents read lists branches; metadata reads active rules. Classic settings normally inaccessible | Repository Administration read adds classic protection; metadata reads rulesets | Settings > Rules > Rulesets and Settings > Branches; hidden bypass still requires review |
| Tags: `R/rulesets?includes_parents=true`, `R/rulesets/{id}` | Active creation/update/deletion rules for simple full-prefix coverage, including inherited rules | Metadata can read rulesets, but bypass may be hidden | Same bypass visibility limit; do not request write permission to improve diagnostics | Settings > Rules > Rulesets; inspect intended pattern, exclusions and bypass |
| Environment: `R/environments`, `R/environments/{name}/deployment-branch-policies` | Existence, visible protections and exact selected branch policy | Actions read, subject to plan and repository visibility | Repository Actions read; same plan limits | Settings > Environments > expected environment > Deployment branches and tags / Deployment protection rules |
| Runner group: `R` (visibility), `O/actions/runner-groups`, `O/actions/runner-groups/{id}/repositories` | Selected repository access, public eligibility and visible workflow restriction entries | Organization settings unavailable | Organization Self-hosted runners read; installation must have organization access | Organization Settings > Actions > Runner groups > expected group > Repository access / Workflow access |
| Runners: `O/actions/runner-groups/{id}/runners` | Registrations in that exact group, online state and labels | Organization settings unavailable | Organization Self-hosted runners read | Organization Settings > Actions > Runner groups > expected group > Runners |
| Variables: `R/actions/variables` | Requested repository names and selected runner variable values | Variables permission is not available in workflow permissions; normally inaccessible | Repository Variables read | Settings > Secrets and variables > Actions > Variables |
| Immutability: `R/immutable-releases` | Supported repository setting, including owner enforcement | Administration permission unavailable | Repository Administration read; `200` exposes `enabled` and `enforced_by_owner` | Settings > General > Releases > Release immutability > Enable release immutability |

Endpoint authorities: [branches](https://docs.github.com/en/rest/branches/branches#list-branches), [classic protection](https://docs.github.com/en/rest/branches/branch-protection#get-branch-protection), [effective rules and rulesets](https://docs.github.com/en/rest/repos/rules), [environments](https://docs.github.com/en/rest/deployments/environments#list-environments), [deployment branch policies](https://docs.github.com/en/rest/deployments/branch-policies#list-deployment-branch-policies), [runner groups and group runners](https://docs.github.com/en/rest/actions/self-hosted-runner-groups), [repository variables](https://docs.github.com/en/rest/actions/variables#list-repository-variables), [immutable-release setting](https://docs.github.com/en/rest/repos/repos#check-if-immutable-releases-are-enabled-for-a-repository).

An App installation should cover the consumer repository with only the read permissions needed above. It is optional and supplied as the single `inspection_token` secret; otherwise the checker uses `github.token`. No credential provisioning subsystem is provided. The credential stays on a GitHub-hosted runner and never appears in the report. No secrets API is used.

GitHub can conceal unauthorized resources with `404`. All denied/ambiguous responses, unsupported fields, malformed or contradictory data, incomplete lists and API failures become `CHECK MANUALLY`, with the affected UI path and expected setting. Only a complete successful list establishes absence. In particular, the documented immutability `404` for disabled releases is also ambiguous with insufficient permission and is always manual. An explicit boolean setting can establish a discrepancy. See [GitHub REST troubleshooting](https://docs.github.com/en/rest/using-the-rest-api/troubleshooting-the-rest-api#404-not-found-for-an-existing-resource).

## Supported checks and bounds

There is one report row for each of the seven categories above. Branch protection requires nonempty enforced status checks, no force pushes or deletion and no defeating visible bypass. Active effective rules come from GitHub's branch-rules endpoint, not a local glob evaluator. Classic administrator enforcement can independently establish these controls. Ruleset bypass omitted from a response needs manual inspection; an empty omitted list is never assumed.

Tag coverage supports the conventional `v*` pattern and other literal prefixes followed by `*`. A ruleset must include the exact expected pattern, a broader literal prefix, or `~ALL`, with no exclusions. Complex combinations need manual review. Separate active rulesets may supply the three restrictions. Evaluation-only rules do not enforce them. Narrow bypass actors require manual review; broad role bypass cannot independently establish a control.

The expected environment uses **Selected branches and tags**, exactly one branch rule matching `integration_branch`, and no tag rules. Required reviewers conflict with this unattended configuration; a valid wait timer remains unattended. Unknown custom protection behavior requires manual inspection. The runner group uses **Selected repositories**, admits the caller, restricts public eligibility appropriately and enforces **Selected workflows** with explicit workflow paths at full commits or `refs/heads/<integration_branch>`. The operator still reviews the exact allowlist; no workflow contents or deployment architecture are analyzed.

Runner labels are compared as case-insensitive sets, with all expected labels on one online runner in the selected group. Additional variable values have no semantics; a false activation variable is valid. No variables are requested if no names were supplied. `check_release_immutability: false` omits that optional category entirely, without inventing a fourth status.

Requests have timeouts, no redirects, at most ten pages per list and a shared request/time budget. Lists must complete with consistent totals where provided. Large/complex configurations need UI inspection rather than a larger rule engine. Unexpected programming or output-write failures fail the job.

## Run the checker

Copy the small [manual consumer example](examples/check-github-setup.yml), replacing its reviewed full revision placeholder and synthetic values. It has no automatic deployment dependencies and requires no deployment secrets, NuGet packages, configuration files or installed toolkit. Run separately for DEV and Production.

The reusable workflow is [check-github-setup.yml](../.github/workflows/check-github-setup.yml), displayed as **Check GitHub deployment setup**. It checks out a fixed reviewed implementation commit from this repository, never caller-selected code. Maintainers update that implementation pin when changing the checker. Caller repository identity comes only from `github.repository`.

| Input | Meaning / default |
| --- | --- |
| `integration_branch` | Expected branch; `master` by default |
| `environment_name` | Required explicit environment |
| `runner_group` | Required explicit organization group |
| `runner_labels` | Required comma-separated expected labels, e.g. `self-hosted,Windows,X64,example-dev` |
| `release_tag_pattern` | `v*` by default |
| `runner_group_variable` | Optional repository variable whose value must match the group |
| `runner_labels_variable` | Optional repository variable whose comma-separated labels must match |
| `additional_variable_names` | Optional comma-separated names; existence only |
| `check_release_immutability` | `true` by default |

## Interpret results

`CONFIGURED` means authoritative available observations establish the expected settings. `NEEDS CONFIGURATION` identifies a confirmed discrepancy. `CHECK MANUALLY` identifies missing evidence, why it is unavailable, the GitHub UI navigation and the expected setting. A completed inspection can finish successfully with any of these results.

Overall status is `NEEDS CONFIGURATION` if any category has a confirmed discrepancy, otherwise `CHECK MANUALLY` if any needs confirmation, otherwise `CONFIGURED`. The only machine outputs are `status`, `configured_count`, `needs_configuration_count` and `manual_count`; use the job summary for details. Do not use this optional diagnostic as a deployment gate. Activation may remain disabled even when all requested settings are configured.

The checker never inspects servers, toolkit installation, enrollment, IIS, identities, operational configuration, application readiness or database compatibility. It never analyzes workflow YAML, requires `.clc/release.json`, modifies GitHub, registers runners, creates tags/releases or authorizes deployment.

Pinned consumers continue using the old checker at their old immutable commits. Migrate callers deliberately to this workflow and its four outputs after review and merge; remove their old host/report-aggregation diagnostic jobs. SSRS Web and other consumer repositories are unchanged by this replacement, and manual versus automatic or shared versus direct deployment needs no checker compatibility model.

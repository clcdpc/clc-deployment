# GitHub setup

## 2. Restrict GitHub Actions

Pin reusable workflow and action revisions. Protect the privileged runner with runner access restrictions that exclude arbitrary branches, pull requests and untrusted workflows. Restrict release actors using repository or organization policies. Keep build and test jobs on GitHub-hosted runners.

## 3. Protect release tags

Restrict release tag creation to release operators or authorized workflows. Protect published tags from update or deletion. Enable immutable releases for the consumer repository.

## 4. Protect master

Use status checks and branch protections on master. Stable production releases require protected master ancestry. Authorized DEV tags may select unmerged commits.

## 5. Create deployment environments

Create separate DEV and Production environments. Set the nonsecret `CLC_RUNTIME_ACCOUNT` variable to each target's expected IIS account name. Use rules compatible with the selected tag channel and unattended release deployment.

## 6. Register deployment runners

Use separate dedicated Windows servers and runner labels for DEV and Production. Restrict each privileged runner to its owning application repository and eligible workflows. Labels route jobs. Runner access settings control which workflows may reach the runner. Configure the expected IIS host according to the [setup guide](setup-guide.md).

## 7. Configure the release workflow

Use the [shared release chain](shared-release-orchestration.md) and minimal workflow token permissions. For manual initialization, enforce the trusted protected branch before scheduling the Windows job. GitHub dispatch allows ref selection.

The optional [GitHub setup diagnostic](github-setup-check.md) reports GitHub settings. Perform [IIS acceptance](iis-verification.md) on a separately authorized target.

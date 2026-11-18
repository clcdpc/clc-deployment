# Windows Server 2022 and IIS acceptance

Actual Windows Server 2022/IIS and consumer acceptance are **NOT RUN** for the replacement. Run these checks only on a separately authorized isolated server and application. Capture operating system and Hosting Bundle versions, toolkit version or commit, expected release identities, safe result codes, site and pool state, worker counts, and attempt IDs.

| Check | Required observation |
| --- | --- |
| Initialization Preview | Exact canonical root and IIS settings, with no filesystem or IIS changes |
| Initialize | One dedicated site and pool, stopped with zero workers, zero bindings, and both auto-start flags disabled |
| Manual configuration | Correct expected account, HTTPS certificate, runtime access, external configuration and the configured DEV runtime or fixed Production runtime for the target |
| Read-only validation | ReadyForFirstDeployment with the configured site and pool still stopped |
| First tagged release | Correct source/target, readiness matching release and configuration, Started site and pool, one worker, both auto-start flags enabled |
| Routine upgrade | Verified prior inventory in the retained backup and intact external configuration, keys and logs |
| Failed activation | Test release passes validation and fails readiness. Attempt remains unresolved, no success is recorded, and cleanup reports actual IIS state |
| Explicit recovery | Verified previous bytes and readiness, or an empty stopped first-install state. The failure and recovery reason remain recorded |

Verify that the readiness hostname resolves from the deployment runner directly to the intended IIS server. Use the separately scoped negative tests for interrupted replacement, wrong runtime identity, path or ACL drift, and corrupt backups. Leave unsupported or unobserved scenarios marked NOT RUN. Preserve evidence with application secrets and raw validator output excluded. Follow the [deployment and recovery runbook](deployment.md).

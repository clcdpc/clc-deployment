# Windows Server 2022 and IIS acceptance

Actual Windows Server 2022/IIS commissioning and SSRS Web integration and acceptance remain **NOT RUN**. The server and application owners coordinate permission and scope for live checks on an isolated server and application. Capture operating system and Hosting Bundle versions, toolkit version or commit, expected release identities, safe result codes, site and pool state, worker counts, and attempt IDs.

| Check | Required observation |
| --- | --- |
| Initialization Preview | Exact canonical root and IIS settings, with no filesystem or IIS changes |
| Initialize | One dedicated site and pool, stopped with zero workers, zero bindings, and both auto-start flags disabled |
| Manual configuration | Correct expected account, HTTPS certificate, runtime access, external configuration and the configured DEV runtime or fixed Production runtime for the target |
| Read-only validation | ReadyForFirstDeployment with the configured site and pool still stopped |
| First tagged release | Correct source/target, readiness matching release and configuration, Started site and pool, one worker, both auto-start flags enabled |
| Routine upgrade | Verified prior inventory in the retained backup and intact external configuration, keys and logs |
| Failed deployment | Test release passes validation and fails readiness. Check for an unresolved attempt, the previous release or an empty first-install state in the current release record, and the observed IIS state in the cleanup result |
| Explicit recovery | Verified previous bytes and readiness, or an empty stopped first-install state. The failure and recovery reason remain recorded |

On an isolated qualification server, exercise two SNI names sharing port 443 and one nonstandard HTTPS port. Confirm the discovered addresses and certificate selections. With one valid alias temporarily unreachable, verify both readiness stages report it locally and deployment and prior-release recovery still verify the other endpoint. Test an untrusted chain, mismatched or expired certificate, missing private key, and a competing wildcard listener. Confirm read-only validation blocks each case. Change a binding during an attempt and verify drift prevents success. Add or remove a secondary hostname between attempts and compare the original host record bytes. Exercise schema 1 with its historical URL and schema 2. Record all outcomes as NOT RUN until observed.

Verify that every intended hostname resolves from the deployment runner directly to the intended IIS server. Exercise negative cases within the agreed scope, including interrupted replacement, wrong runtime identity, path or ACL drift, and corrupt backups. Leave unsupported or unobserved scenarios marked NOT RUN. Preserve evidence with application secrets and raw validator output excluded. [Deployment and recovery runbook](deployment.md)

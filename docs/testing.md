# Verification

Run `tools/Test-Foundation.ps1 -PesterManifestPath <independently-verified-Pester.psd1>` on Windows with the pinned PowerShell 7.6.6 and Pester 5.7.1. It checks syntax, schemas, module exports, dependency inventory and the complete offline/Windows suite. Hosted PR CI has no deployment credentials or privileged IIS runner.

Tests cover strict package/approval contracts, malicious archives, physical paths and access checks, exclusive locking, deployment, fresh-readiness NoOp, configuration restart, partial replacement, retained backups and all three explicit recovery modes. File/state/backup operations use owned NTFS fixtures; IIS and independent-identity observations are synthetic. Qualification-tool tests also use actual loopback Kestrel and current-user DPAPI. Passing these tests does not qualify a real IIS host or service token.

Application compatibility, consumer workflow/packaging checks and any compiled-application deployment bridge remain application-owned. For an authorized representative payload, measure deployment, backup and replacement time against the operation budgets in [public contracts](contracts.md). Local synthetic-IIS timing does not establish Server 2022/IIS throughput.

**Actual Windows Server 2022/IIS qualification remains NOT RUN.** Start with the [seven-check real-IIS procedure](iis-verification.md) under explicit host/application authorization. Actual lifecycle, independent identity/access, service-profile key continuity, TLS, reboot/storage faults and consumer acceptance require observed evidence. [Qualification tools](../tests/Qualification/README.md) support separately scoped checks; their scenario catalog is not a mandatory release campaign.

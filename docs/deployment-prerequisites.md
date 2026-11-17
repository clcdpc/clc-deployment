# Deployment prerequisites

The authoritative [CLC Deployment Setup Guide](setup-guide.md) defines the ten-section setup and routine operation sequence. Follow [GitHub setup](github-setup.md) for native actor/tag controls, Release immutability, unrestricted deployment environments and dedicated Windows runners. Consumer configuration version 2 derives routing; routine deployment has no checker activation flag or PR approval gate.

Infrastructure separately completes [toolkit installation](installation.md), protected target/host records, [host enrollment](host-enrollment.md), a successful exact approved baseline and then [standing authorization](automated-deployments.md). Application configuration, readiness and [hook compatibility](application-hooks.md) remain application-owned. [Explicit recovery](deployment.md) retains independent exact authority.

The optional [GitHub setup checker](github-setup-check.md) is a bounded GET-only diagnostic, independent of deployment admission. It neither inspects nor prepares hosts. The former deployment-readiness/checker activation workflow is historical and unsupported; do not restore its routing flags, workflow_run handoff or master equality gates.

Actual Windows Server 2022/IIS and independent-identity qualification remain **NOT RUN**. Follow the separately authorized [IIS deployment/recovery procedure](iis-verification.md); offline tests and GitHub configuration observations do not complete acceptance.

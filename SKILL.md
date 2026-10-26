---
name: tempo-earn
description: Integrate, deploy, or troubleshoot onchain Tempo Earn vaults, EarnShare approvals, and ERC-4626, Veda, or PropAMM engines. Use for applications adding yield through Tempo Earn, not for general investment recommendations or unrelated Tempo payments.
---

# Tempo Earn

Tempo Earn exposes one application-facing `EarnVault` and a native TIP-20 EarnShare. Its engine
holds shares in the underlying yield venue. Repository contributors must also follow
[AGENTS.md](earn/AGENTS.md).

Start with the [agent guide](docs/earn/integrations/agent-guide.md) and work through it from
[choosing the entry point](docs/earn/integrations/agent-guide.md#choose-the-entry-point) to
[validating and reporting](docs/earn/integrations/agent-guide.md#validate-and-report-the-boundary-reached).
Keep transaction signing and deployment broadcasts within the user's explicit authorization.

| Task                                                 | Reference                                                     |
| ---------------------------------------------------- | ------------------------------------------------------------- |
| Build public actions, approvals, quotes, and reverts | [Client integration](docs/earn/integrations/client.md)        |
| Compare engines and their exits                      | [Yield engines](docs/earn/integrations/engines.md)            |
| Deploy an Earn stack over an existing venue          | [Deployment lifecycle](docs/deployment/deployment.md)         |
| Find hosted deployments and validate them            | [Hosted environments](docs/deployment/hosted-environments.md) |
| Add private flows                                    | [Zone router](docs/earn/modules/zone-router.md)               |
| Operate an engine, access policy, rewards, migration | [Capability modules](docs/earn/README.md#capability-modules)  |

---
name: tempo-earn
description: Integrate, deploy, or troubleshoot onchain Tempo Earn vaults, EarnShare approvals, and ERC-4626, Veda, or PropAMM engines. Use for applications adding yield through Tempo Earn, not for general investment recommendations or unrelated Tempo payments.
---

# Tempo Earn

Tempo Earn exposes one application-facing `EarnVault` and a native TIP-20 EarnShare. Its engine
holds shares in the underlying yield venue. Repository contributors must also follow
[AGENTS.md](earn/AGENTS.md).

Start with the [agent guide](earn/docs/integrations/agent-guide.md) and work through it from
[choosing the entry point](earn/docs/integrations/agent-guide.md#choose-the-entry-point) to
[validating and reporting](earn/docs/integrations/agent-guide.md#validate-and-report-the-boundary-reached).
Keep transaction signing and deployment broadcasts within the user's explicit authorization.

| Task                                                 | Reference                                                          |
| ---------------------------------------------------- | ------------------------------------------------------------------ |
| Build public actions, approvals, quotes, and reverts | [Client integration](earn/docs/integrations/client.md)             |
| Compare engines and their exits                      | [Yield engines](earn/docs/integrations/engines.md)                 |
| Deploy an Earn stack over an existing venue          | [Deployment lifecycle](earn/docs/operations/deployment.md)         |
| Find hosted deployments and validate them            | [Hosted environments](earn/docs/operations/hosted-environments.md) |
| Add private flows                                    | [Zone router](earn/docs/modules/zone-router.md)                    |
| Operate an engine, access policy, rewards, migration | [Capability modules](earn/docs/README.md#capability-modules)       |

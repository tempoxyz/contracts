<br>
<br>

<p align="center">
  <a href="https://tempo.xyz">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="../../.github/assets/tempo-wordmark-white.svg">
      <img alt="Tempo wordmark" src="../../.github/assets/tempo-wordmark-black.svg" width="360">
    </picture>
  </a>
</p>

<br>
<br>

# Tempo Earn

[![Pull Request](https://github.com/tempoxyz/contracts/actions/workflows/pull-request.yml/badge.svg)](https://github.com/tempoxyz/contracts/actions/workflows/pull-request.yml)
[![Local E2E](https://github.com/tempoxyz/contracts/actions/workflows/local-zone.yml/badge.svg)](https://github.com/tempoxyz/contracts/actions/workflows/local-zone.yml)
[![Audited by Sigma Prime](https://img.shields.io/badge/audited_by-Sigma_Prime-2ea44f)](audit/README.md)

Tempo Earn is vault-backed stablecoin yield for [Tempo](https://tempo.xyz). Users deposit a
stablecoin into a persistent `EarnVault` and receive EarnShare, a non-rebasing
[TIP-20](https://docs.tempo.xyz/protocol/tip20/overview) token whose redemption value grows with the
yield. An engine contract holds the vault's position in its yield venue (an ERC-4626 vault, Veda, or
a PropAMM pool), and EarnShare can also be held and used privately inside a Tempo Zone.

```mermaid
flowchart LR
    User["User or app"] -->|deposit / redeem| Vault["EarnVault"]
    Zone["Tempo Zone"] -->|private deposit / redeem| Router["Zone router"] --> Vault
    Vault -->|mints and burns| Share["EarnShare (TIP-20)"]
    Vault --> Engine["Engine"] --> Venue["Yield venue"]
```

New to the terms? See the [glossary](glossary.md). The
[system architecture](architecture/system.md) explains the design and its invariants.

## Use it

`viem/tempo` exposes the Earn ABIs, reads, writes, and call builders. This reads the
[`e2e-moderato`](../../profiles/e2e-moderato/deployment.json) EarnVault, an open PATHUSD vault on the
Moderato testnet:

```ts
import { createClient, http } from 'viem/tempo'
import { tempoModerato } from 'viem/tempo/chains'

const client = createClient({
  chain: tempoModerato,
  transport: http(),
})

const earnVault = await client.earn.getVault({
  vault: '0x0eb6bc4711Bf400684Df14616e049F4b889eb025',
})

console.log(earnVault.assetToken, earnVault.engine.totalAssets)
```

This needs viem 2.55.10 or later; the repository uses viem 2.57.14.

- [Client integration](integrations/client.md): deposits, redemptions, quotes, simulation, and
  revert handling.
- [Tempo Zones](modules/zone-router.md): private deposits and redemptions.
- [Deployment](../deployment/deployment.md): deploy your own stack from a reviewed
  [profile](../../profiles/README.md) with `pnpm earn deploy`.

Tempo is EVM compatible with payment-specific differences; review
[EVM compatibility](https://docs.tempo.xyz/quickstart/evm-compatibility) before deploying contracts
or building transaction infrastructure.

## Contribute

[CONTRIBUTING.md](../../CONTRIBUTING.md) covers setup, per-area commands, and pull requests;
[development](../development/README.md) owns the toolchain, checks, and CI. The
[documentation index](README.md) lists the canonical page for every topic.

## Project layout

Earn is one domain of the repository's single Foundry project; paths below are relative to the
[repository](../../README.md) root, where its deployment modules (`deployments/modules/earn/`),
profiles, and the shared tooling also live.

| Path                   | Purpose                                                                                             |
| ---------------------- | --------------------------------------------------------------------------------------------------- |
| `src/earn/core/`       | Factory, persistent EarnVault, isolated fees, and fee math.                                         |
| `src/earn/engines/`    | Single-EarnVault [yield engines](integrations/engines.md), one per kind.                            |
| `src/earn/rewards/`    | Optional contribution orchestration and EarnShare-only Merkle reward settlement.                    |
| `src/interfaces/earn/` | Public Earn interfaces, grouped by core and engines; outside systems in `src/interfaces/external/`. |
| `src/demo/`            | Test-only venues, fixture funders, and par-oracle pool periphery (built, never deployed).           |
| `script/earn/deploy/`  | Foundry deployment scripts the shared profile lifecycle runs.                                       |
| `script/earn/local/`   | Local fixture contracts and scripts the root `localnet/` package deploys.                           |
| `test/earn/`           | Tests mirroring the Solidity production domains.                                                    |

## Project status

- The contracts, viem integration, application, deployment tooling, and local E2E suite are
  implemented, and Sigma Prime's two audits are complete ([Audits](#audits)).
- Tempo Zones are early infrastructure; private flows are experimental.
- `Simple4626Vault`, fixture minting, demo par pools, and permissive test policies are demo
  infrastructure. Production deployments bind an existing external venue and conversion pool.
- Hosted test deployments are listed in [hosted environments](../deployment/hosted-environments.md).

## Audits

[Sigma Prime](https://sigmaprime.io) completed two security reviews in August 2026, the Zones & Earn
Review v1.1 and the PropAMM & Earn Review v2.0, and every finding that affects Earn is resolved. The
[audits page](audit/README.md) lists each report's scope.

## Security

Report vulnerabilities privately as described in [SECURITY.md](../../SECURITY.md). The
[security and privacy model](architecture/security-and-privacy.md) documents privileged roles,
external dependencies, accounting protections, Zone visibility, and the production-readiness
checklist.

## License

Files carry their own SPDX license identifier, which governs that file. The repository is
available under either the [MIT License](../../LICENSE-MIT) or the [Apache License 2.0](../../LICENSE-APACHE),
at your option.

---

Working with an AI agent? Integrators start at [SKILL.md](../../SKILL.md); contributors' agents follow
[AGENTS.md](../../src/earn/AGENTS.md).

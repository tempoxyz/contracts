<br>
<br>

<p align="center">
  <a href="https://tempo.xyz">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset=".github/assets/tempo-wordmark-white.svg">
      <img alt="Tempo wordmark" src=".github/assets/tempo-wordmark-black.svg" width="360">
    </picture>
  </a>
</p>

<br>
<br>

# Tempo contracts

[![Pull Request](https://github.com/tempoxyz/contracts/actions/workflows/pull-request.yml/badge.svg)](https://github.com/tempoxyz/contracts/actions/workflows/pull-request.yml)
[![Local E2E](https://github.com/tempoxyz/contracts/actions/workflows/local-zone.yml/badge.svg)](https://github.com/tempoxyz/contracts/actions/workflows/local-zone.yml)

Tempo's contracts and the tooling they share, in one Foundry project at the repository root. Its
Solidity is split into domains, each with its own documentation and audits; they share one build,
deployment lifecycle, local Tempo L1 and Zone, E2E harness, and CI.

| Domain                   | What it is                                                                                                  |
| ------------------------ | ----------------------------------------------------------------------------------------------------------- |
| [src/earn/](src/earn/)   | [Tempo Earn](docs/earn/overview.md): vault-backed stablecoin yield, the EarnVault and EarnShare             |
| [src/zone/](src/zone/)   | [Zone router](docs/zone/README.md): Zone withdrawal callbacks for Earn and spends, its factory and spenders |
| [src/spend/](src/spend/) | [Card spend](docs/spend/README.md): provider-agnostic contracts and each card provider's (Bridge, Rain)     |

`src/earn/` imports neither of the others; `src/zone/` imports Earn's interfaces; `src/spend/` imports
Earn and the Zone router. Protocol precompiles and system contracts are part of the Tempo node, not
this repository.

## Repository layout

| Path                                         | Purpose                                                                                                                                                                             |
| -------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `foundry.toml`, `foundry.lock`, `solar.lock` | The Foundry project: profiles, remappings, pinned Solidity dependencies (`lib/`), and the solar compiler (`solar-solc`).                                                            |
| `src/`                                       | Contracts by domain: `earn/`, `zone/`, `spend/` (with `spend/providers/<provider>/`), `demo/` (built, never deployed), and `interfaces/` (`earn/`, `zone/`, `spend/`, `external/`). |
| `test/`, `script/`                           | Forge tests and scripts by domain (`earn/`, `zone/`, `spend/`).                                                                                                                     |
| `vendor/`                                    | Third-party contracts vendored unmodified: card providers' (`bridge/`, `rain/`) and the Zones runtime (`tempo-zones/`).                                                             |
| `snapshots/`                                 | Gas snapshots of the card spend TIP-20 paths.                                                                                                                                       |
| `deployments/`                               | Shared deployment lifecycle (`pnpm earn`), releases, ABIs, and modules (`modules/earn/`, `modules/zone-router/`); the `@tempoxyz/contracts` package.                                |
| `profiles/`                                  | Deployment profiles and generated records.                                                                                                                                          |
| `e2e/`                                       | Shared local and hosted integration harness and cases, and the card runs (`e2e/spend/`).                                                                                            |
| `localnet/`                                  | Disposable local Tempo L1 and Zone, shared by every E2E run.                                                                                                                        |
| `docs/`                                      | The [documentation index](docs/README.md); each domain's docs (`earn/`, `zone/`, `spend/`), and the shared `deployment/` and `development/`.                                        |
| `scripts/solidity-deps.sh`                   | Installs the pinned Solidity dependencies and the solar compiler (`pnpm deps`).                                                                                                     |

## Get started

```bash
git clone https://github.com/tempoxyz/contracts
cd contracts
pnpm install
pnpm deps     # pinned Solidity dependencies and the solar compiler
pnpm verify
```

[CONTRIBUTING.md](CONTRIBUTING.md) covers per-area commands and pull requests,
[development](docs/development/README.md) owns the toolchain, checks, and CI, and the
[documentation index](docs/README.md) names the canonical page for every topic.

## Add a domain

A new domain gets its own directories in the one Foundry project (`src/<domain>/`,
`src/interfaces/<domain>/`, `test/<domain>/`, `script/<domain>/`), an AGENTS.md in `src/<domain>/`, an
entry in the tables above, and its docs under `docs/<domain>/`. It imports another domain's contracts
by relative path, never a copy, and keeps the one-way import rules
([AGENTS.md](AGENTS.md#keep-domains-separate)).

## Security

Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## License

Files carry their own SPDX license identifier, which governs that file. The repository is
available under either the [MIT License](LICENSE-MIT) or the [Apache License 2.0](LICENSE-APACHE),
at your option.

---

Working with an AI agent? Tempo Earn integrators start at [SKILL.md](SKILL.md); contributors' agents
follow [AGENTS.md](AGENTS.md).

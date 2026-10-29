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

[![Pull Request](https://github.com/tempoxyz/earn/actions/workflows/pull-request.yml/badge.svg)](https://github.com/tempoxyz/earn/actions/workflows/pull-request.yml)
[![Local E2E](https://github.com/tempoxyz/earn/actions/workflows/local-zone.yml/badge.svg)](https://github.com/tempoxyz/earn/actions/workflows/local-zone.yml)

Tempo's contracts and the tooling they share. Each project is a separate Foundry project with its
own build settings, dependencies, documentation, and audits; they share one deployment lifecycle,
local Tempo L1 and Zone, E2E harness, and CI.

| Project                      | What it is                                                                                                    |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------- |
| [earn/](earn/)               | [Tempo Earn](earn/README.md): vault-backed stablecoin yield, the EarnVault and EarnShare                      |
| [zone-router/](zone-router/) | [Zone router](zone-router/README.md): Zone withdrawal callbacks for Earn and spends, its factory and settlers |
| [bridge/](bridge/)           | [Bridge integration](bridge/README.md): Bridge card spend on Tempo through Bridge's spender contracts         |

`earn/` imports neither of the others; `zone-router/` imports Earn's interfaces; `bridge/` imports
Earn and the Zone router. Protocol precompiles and system contracts are part of the Tempo node, not
this repository.

## Repository layout

| Path                       | Purpose                                                                                                                                               |
| -------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| `earn/`                    | Tempo Earn Foundry project (solar): contracts, tests, Forge scripts, and Earn's web app and Worker (`earn/app/`).                                     |
| `zone-router/`             | Zone router Foundry project (solc): `ZoneRouter`, its factory, `ISpendSettler`, and `SendSettler` and `BridgeSettler`.                                |
| `bridge/`                  | Bridge integration Foundry project (solc): vendored Bridge contracts, the "TS" handler, card harness, deploy scripts.                                 |
| `deployments/`             | Shared deployment lifecycle (`pnpm earn`), releases, ABIs, and modules (`modules/earn/`, `modules/zone-router/`); the `@tempoxyz/contracts` package.  |
| `profiles/`                | Deployment profiles and generated records.                                                                                                            |
| `e2e/`                     | Shared local and hosted integration harness and cases, and the Bridge integration's Zone run (`e2e/bridge/`).                                         |
| `localnet/`                | Disposable local Tempo L1 and Zone, shared by every E2E run.                                                                                          |
| `docs/`                    | The [documentation index](docs/README.md); each project's docs (`earn/`, `zone-router/`, `bridge/`), and the shared `deployment/` and `development/`. |
| `scripts/solidity-deps.sh` | Installs each Foundry project's pinned Solidity dependencies and Earn's solar compiler.                                                               |

## Get started

```bash
git clone https://github.com/tempoxyz/earn
cd earn
pnpm install
pnpm deps     # Solidity dependencies for earn/, zone-router/ and bridge/, and Earn's solar compiler
pnpm verify
```

[CONTRIBUTING.md](CONTRIBUTING.md) covers per-area commands and pull requests,
[development](docs/development/README.md) owns the toolchain, checks, and CI, and the
[documentation index](docs/README.md) names the canonical page for every topic.

## Add a project

A new project is its own Foundry directory at the root with its own `foundry.toml`, `foundry.lock`,
README, and AGENTS.md, an entry in `scripts/solidity-deps.sh` and in the tables above, its own CI
workflow, and its docs under `docs/<project>/`. It imports another project's contracts through a
remapping to that project's `src/`, never a copy ([AGENTS.md](AGENTS.md#keep-projects-separate)).

## Security

Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## License

Files carry their own SPDX license identifier, which governs that file. The repository is
available under either the [MIT License](LICENSE-MIT) or the [Apache License 2.0](LICENSE-APACHE),
at your option.

---

Working with an AI agent? Tempo Earn integrators start at [SKILL.md](SKILL.md); contributors' agents
follow [AGENTS.md](AGENTS.md).

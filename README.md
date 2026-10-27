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

Tempo's contract projects and the tooling they share. Each project is a separate Foundry project with
its own build settings, dependencies, documentation, and audits.

| Project            | What it is                                                                                      |
| ------------------ | ----------------------------------------------------------------------------------------------- |
| [earn/](earn/)     | [Tempo Earn](earn/README.md): vault-backed stablecoin yield, its deployment tooling, and app    |
| [spend/](spend/)   | [Tempo Spend](spend/README.md): card spend on Tempo through Bridge's spender contracts          |
| [router/](router/) | [Zone router](router/README.md): Zone withdrawal callbacks for Earn and spends, and its factory |

## Repository layout

| Path                       | Purpose                                                                                     |
| -------------------------- | ------------------------------------------------------------------------------------------- |
| `earn/`                    | Tempo Earn Foundry project: contracts, tests, and Forge scripts.                            |
| `spend/`                   | Tempo Spend Foundry project: Bridge spender handler, Zone receiver, and card harness.       |
| `router/`                  | Zone router Foundry project (solc): `ZoneRouter`, its factory, and `ISpendSettler`.         |
| `deployments/`             | Shared deployment lifecycle (`pnpm earn`), ABIs, and per-project modules (`modules/earn/`). |
| `profiles/`                | Deployment profiles and generated records.                                                  |
| `app/`                     | The web app and Cloudflare Worker.                                                          |
| `e2e/`                     | Shared local and hosted integration harness and cases, including Spend's Zone run.          |
| `localnet/`                | Disposable local Tempo L1 and Zone, shared by every E2E run.                                |
| `docs/`                    | `development/`, `deployment/`, `earn/`, `spend/`, and `router/` documentation.              |
| `scripts/solidity-deps.sh` | Installs each Foundry project's pinned Solidity dependencies and Earn's solar compiler.     |

## Get started

```bash
git clone https://github.com/tempoxyz/earn
cd earn
pnpm install
pnpm deps     # Solidity dependencies for earn/, spend/ and router/, and Earn's solar compiler
pnpm verify
```

[CONTRIBUTING.md](CONTRIBUTING.md) covers per-area commands and pull requests, and
[development](docs/development/README.md) owns the toolchain, checks, and CI.

## Security

Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## License

Files carry their own SPDX license identifier, which governs that file. The repository is
available under either the [MIT License](LICENSE-MIT) or the [Apache License 2.0](LICENSE-APACHE),
at your option.

---

Working with an AI agent? Integrators start at [SKILL.md](SKILL.md); contributors' agents follow
[AGENTS.md](AGENTS.md).

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

| Project          | What it is                                                                                   |
| ---------------- | -------------------------------------------------------------------------------------------- |
| [earn/](earn/)   | [Tempo Earn](earn/README.md): vault-backed stablecoin yield, its deployment tooling, and app |
| [spend/](spend/) | [Tempo Spend](spend/README.md): card spend on Tempo through Bridge's spender contracts       |

## Repository layout

| Path                       | Purpose                                                                        |
| -------------------------- | ------------------------------------------------------------------------------ |
| `earn/`                    | Tempo Earn: contracts, tests, deployment tooling, profiles, app, and docs.     |
| `spend/`                   | Tempo Spend: Bridge spender handler, Zone receiver, card harness, and docs.    |
| `localnet/`                | Disposable local Tempo L1 and Zone lifecycle, shared by the projects' tests.   |
| `e2e/`                     | Shared local and hosted integration harness and cases.                         |
| `scripts/solidity-deps.sh` | Installs each project's Solidity dependencies at its `foundry.lock` revisions. |
| `docs/`                    | Repository-wide development, checks, and CI.                                   |

## Get started

```bash
git clone https://github.com/tempoxyz/earn
cd earn
pnpm install
pnpm deps     # Solidity dependencies for earn/ and spend/
pnpm verify
```

[CONTRIBUTING.md](CONTRIBUTING.md) covers per-area commands and pull requests, and
[development](docs/development.md) owns the toolchain, checks, and CI.

## Security

Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## License

Files carry their own SPDX license identifier, which governs that file. The repository is
available under either the [MIT License](LICENSE-MIT) or the [Apache License 2.0](LICENSE-APACHE),
at your option.

---

Working with an AI agent? Integrators start at [SKILL.md](SKILL.md); contributors' agents follow
[AGENTS.md](AGENTS.md).

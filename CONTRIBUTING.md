# Contributing

Thanks for helping. This page covers how to build, test, and propose a change; the linked pages own
the details. Report security issues privately as described in [SECURITY.md](SECURITY.md), never in
an issue or pull request.

## Set up

Install the tools in the [toolchain](docs/development/README.md#toolchain): Foundry at the pinned version,
Node.js 22, and pnpm 11. Local end-to-end runs also need Docker.

```bash
git clone https://github.com/tempoxyz/earn
cd earn
pnpm install
pnpm deps   # each project's Solidity dependencies at its foundry.lock revisions, and Earn's solar
```

The clone needs no private access: Solidity dependencies are public repositories, and contract tests
and local stacks deploy a committed [DirectPropAMM fixture](docs/earn/modules/propamm.md#pinned-directpropamm-fixture).

## Work on one area

| Area                                                                  | Commands                                                                           |
| --------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| Earn contracts ([`earn/src/`](earn/src/), [`earn/test/`](earn/test/)) | `pnpm test:contracts`, or `forge test --match-path <path> -vvv` in `earn/`         |
| Deployment tooling ([`deployments/`](deployments/))                   | `pnpm --filter @tempoxyz/contracts test --run`, `check`, and `typecheck`           |
| App ([`earn/app/`](earn/app/))                                        | `pnpm --filter app test`; `pnpm dev:local` runs it against a local stack           |
| Local end-to-end ([`e2e/`](e2e/), [`localnet/`](localnet/)), Docker   | `pnpm e2e:local`; `pnpm dev:local -- --smoke` sets up and verifies a stack         |
| Zone router ([`zone-router/`](zone-router/))                          | `forge test` in `zone-router/`; see [zone-router/AGENTS.md](zone-router/AGENTS.md) |
| Bridge integration ([`bridge/`](bridge/))                             | `forge test` in `bridge/`; see [bridge/AGENTS.md](bridge/AGENTS.md)                |

`pnpm dev` runs the app against the hosted Moderato testnet and needs a Tempo API key
([app environment](docs/development/README.md#app-environment)); the local commands need no credentials.
The [test map](docs/development/README.md#test-map) shows where existing coverage lives, and
[development](docs/development/README.md) owns every other command.

## Before you open a pull request

1. Run `pnpm verify`. It runs formatting, lint, the contract build, size check, and tests, the ABI
   and gas snapshots, TypeScript checks and tests, the documentation link check, and the app build.
   CI adds the symbolic proofs, the PropAMM fixture rebuild, and local E2E
   ([required checks](docs/development/README.md#required-checks)).
2. Update the one page that owns the behavior you changed; the
   [documentation index](docs/earn/README.md#document-ownership) names it. Document current behavior
   only.
3. For contract changes, answer the [review checklist](docs/development/README.md#review-checklist) in the
   pull request.
4. Keep one logical change per commit, with no unrelated formatting or refactoring.

## Continuous integration

Pull requests run the secretless verification, security scan, and local end-to-end workflows
described in [continuous integration](docs/development/README.md#continuous-integration), and a pull
request from a fork can pass every required check. A fork gets no preview deployment, and a change
to `earn/test/fixtures/propamm/` from a fork fails CI until a maintainer re-verifies it from a branch in
this repository.

## Commits and pull requests

Commit subjects and pull request titles name the affected areas, then say what changed in the
lowercase imperative, for example:

```text
deployments, e2e: run the tooling against profiles that live in another repository
ci: run the symbolic proofs on stable Foundry
```

Areas are project or top-level directories (`earn`, `zone-router`, `bridge`, `e2e`, `localnet`), the Earn
subdirectory for a narrower change (`deployments`, `app`), or `ci`, `docs`, `repo`, and `chore`. Pull requests are squash-merged
with the title as the commit subject, so describe the change and its validation in the body.

## License

Files carry their own SPDX license identifier; the repository's terms are in the README's
[license section](README.md#license).

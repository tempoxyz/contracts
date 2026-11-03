# Card spend

Card spend on Tempo for every card provider, in one Foundry project. Three kinds of code, kept apart
so each is easy to find and review:

| Path                        | What it is                                                                                     |
| --------------------------- | ---------------------------------------------------------------------------------------------- |
| `src/core/`                 | Ours, provider-agnostic: `CardProgram`, `CardFactory`, `CardSpend`, `ICardIssuer`              |
| `src/providers/<provider>/` | Ours, for one provider: its `ICardIssuer` (`BridgeIssuer` with the "TS" handler; `RainIssuer`) |
| `vendor/<provider>/`        | The provider's own contracts, vendored unmodified (`vendor/bridge/`, `vendor/rain/`)           |

Tests and scripts follow the same split (`test/core/`, `test/<provider>/`, `script/<provider>/`). Core
tests run on [`test/core/harness/CoreEnv.sol`](test/core/harness/CoreEnv.sol) and a mock program, with no
provider; a provider's harness extends `CoreEnv`.
[README.md](README.md) maps the project; [docs/cards/design.md](../docs/cards/design.md) owns the
agnostic design and [docs/cards/bridge/](../docs/cards/bridge/README.md) and
[docs/cards/rain/](../docs/cards/rain/README.md) each provider's.

- Run every `forge` command from `cards/`, after `scripts/solidity-deps.sh cards` (from the repository
  root) installs `lib/` at the revisions `foundry.lock` pins. Never add this project's remappings,
  dependencies or hardfork to another project's `foundry.toml`: Earn's and the Zone router's feed the
  metadata hash of their releases, and tempoxyz/tempo builds `earn/src/`.
- Import Earn through `tempo-earn/` and the Zone router through `zone-router/`, never a copy. Nothing in
  `earn/` or `zone-router/` imports from here. A change to their interfaces that breaks this project is
  fixed in the same pull request.
- `src/core/` names no provider: no provider address, rule or import. A provider that needs evidence
  about a destination reads it from `CardSpend.destinationHint`, and learns whether a spend is private
  from the core's `isPrivate`, never by inspecting the payer. One provider's code never imports
  another's.
- `vendor/` holds providers' (and the Zones runtime's) sources unmodified, at the provenance in
  [vendor/VENDORED.md](vendor/VENDORED.md), except for the changes it lists; refresh them only by
  re-copying. Code whose exact pragma does not build here is deployed from fixtures:
  `test/rain/fixtures/rain.json`, rebuilt by `script/rain/build-fixture.sh` (`--check` compares it
  without the path-dependent metadata hashes; commit it with any vendor change), and
  `test/bridge/harness/fixtures/Permit2.json`.
- Programs are immutable: no upgrade, migration or setter beyond the guardian's pause. A change of issuer
  or settings is a new program.
- Bridge's "TS" handler, the `CardFactory` and a program's `BridgeIssuer` deploy at deterministic
  addresses that follow their build
  ([docs/cards/bridge/deploy.md](../docs/cards/bridge/deploy.md)): a change to their source, this
  project's remappings or its compiler settings moves them.
- No contract here emits or stores the Zone callback `senderTag` or a cardholder address on the private
  path; providers match private spends by the Portal's own events.

Validate with `forge fmt --check src test script`, `forge build`,
`forge lint --deny warnings src/core src/providers/rain src/providers/bridge/BridgeIssuer.sol`,
`forge build --sizes src`, `FOUNDRY_PROFILE=ci forge test` and `script/rain/build-fixture.sh --check`,
plus `python3 script/bridge/matrix.py --out reports/matrix.md` and a diff against
`../docs/cards/bridge/matrix.md` when Bridge card scenarios or setups change. The E2E runs need Docker:
`pnpm e2e:cards -- --earn` (Rain), `pnpm e2e:bridge -- --earn` and `script/bridge/smoke.sh` (Bridge).

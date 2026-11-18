# Card spend

Card spend on Tempo for every card provider, in the `spend` domain. This guide covers its sources,
tests (`test/spend/`), scripts (`script/spend/`), and vendored code (`vendor/`). Three kinds of code,
kept apart so each is easy to find and review:

| Path                                                            | What it is                                                                                           |
| --------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `src/spend/` (outside `providers/`) and `src/interfaces/spend/` | Ours, provider-agnostic: `CardSpender`, `CardFactory`, `CardSpend`, `ICardProvider`                  |
| `src/spend/providers/<provider>/`                               | Ours, for one provider: its `ICardProvider` (`BridgeProvider` with the "TS" handler; `RainProvider`) |
| `vendor/<provider>/`                                            | The provider's own contracts, vendored unmodified (`vendor/bridge/`, `vendor/rain/`)                 |

Tests and scripts follow the same split (`test/spend/core/`, `test/spend/<provider>/`,
`script/spend/<provider>/`). Core tests run a real `CardSpender` over mock providers on
[`test/spend/core/harness/CoreEnv.sol`](../../test/spend/core/harness/CoreEnv.sol); Rain's harness
extends `CoreEnv`, and Bridge's runs on its own `TempoEnv`.
[docs/spend/README.md](../../docs/spend/README.md) maps the domain,
[docs/spend/design.md](../../docs/spend/design.md) owns the agnostic design, and
[docs/spend/bridge/](../../docs/spend/bridge/README.md) and [docs/spend/rain/](../../docs/spend/rain/README.md)
each provider's.

- Run every `forge` command from the repository root. Spend tests need Tempo's real precompiles, so
  they run only under `FOUNDRY_PROFILE=spend` (or `spend-ci`), on the `tempo:T8` hardfork; the default
  profile skips `test/spend/`.
- Import Earn (`src/earn/`, `src/interfaces/earn/`) and the Zone router (`src/zone/`,
  `src/interfaces/zone/`) by relative path, never a copy. Nothing in `src/earn/` or `src/zone/` imports
  from here. A change to their interfaces that breaks this domain is fixed in the same pull request.
- The spend core names no provider: no provider address, rule or import. A provider that needs evidence
  about a destination reads it from `CardSpend.destinationHint`, and learns whether a spend is private
  from the core's `isPrivate`, never by inspecting the payer. One provider's code never imports
  another's.
- `vendor/` holds providers' (and the Zones runtime's) sources unmodified, at the provenance in
  [vendor/VENDORED.md](../../vendor/VENDORED.md), except for the changes it lists; refresh them only by
  re-copying. Code whose exact pragma does not build here is deployed from fixtures:
  `test/spend/rain/fixtures/rain.json`, rebuilt by `script/spend/rain/build-fixture.sh` (`--check`
  compares it without the path-dependent metadata hashes; commit it with any vendor change), and
  `test/spend/bridge/harness/fixtures/Permit2.json`.
- Programs are immutable: no upgrade, migration, setter or pause of their own (the provider's pause, read
  live, is the only one). A change of provider or settings is a new program.
- Bridge's "TS" handler, the `CardFactory` and a program's `BridgeProvider` deploy at deterministic
  addresses that follow their build
  ([docs/spend/bridge/deploy.md](../../docs/spend/bridge/deploy.md)): a change to their source, its
  path, the root `foundry.toml` remappings or its compiler settings moves them.
- No contract here emits or stores the Zone callback `senderTag` or a cardholder address on the private
  path; providers match private spends by the Portal's own events.

Validate from the repository root with `forge fmt --check`, `forge build`,
`forge lint --deny warnings src/spend`, `forge build --sizes src/spend`,
`FOUNDRY_PROFILE=spend-ci forge test` and `script/spend/rain/build-fixture.sh --check`, plus
`python3 script/spend/bridge/matrix.py --out reports/matrix.md` and a diff against
[`docs/spend/bridge/matrix.md`](../../docs/spend/bridge/matrix.md) when Bridge card scenarios or setups
change. The E2E runs need Docker: `pnpm e2e:cards -- --earn` (Rain), `pnpm e2e:bridge -- --earn` and
`script/spend/bridge/smoke.sh` (Bridge).

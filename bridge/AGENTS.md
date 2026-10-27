# Tempo's Bridge integration

Bridge card spend on Tempo: Bridge's card contracts vendored as they are, the "TS" handler
(`SpenderTempoSpend`) that runs inside Bridge's system, the card E2E harness, and the deploy
scripts Bridge runs. [README.md](README.md) maps the project and
[docs/bridge/design.md](../docs/bridge/design.md) owns the design.

- This is its own Foundry project. Run every `forge` command from `bridge/`, after
  `scripts/solidity-deps.sh bridge` (from the repository root) installs `lib/` at the revisions
  `foundry.lock` pins. Never add its remappings, dependencies, or hardfork to `earn/foundry.toml`
  or `zone-router/foundry.toml`: their remappings feed the metadata hash of their releases, and
  tempoxyz/tempo builds `earn/src/`.
- Import Earn through `tempo-earn/` (`earn/src/`) and the Zone router through `zone-router/`
  (`zone-router/src/`), never a copy. `BridgeSettler` and the `Spend` struct the handler settles
  live in the Zone router's `src/settlers/`; the Zone router never imports from here. A change to
  Earn's or the Zone router's interfaces that breaks this project is fixed in the same pull request.
- Bridge-specific code stays here; `earn/` stays customer-agnostic and never imports from
  `bridge/`.
- `vendor/` holds Bridge and Zone sources at the commits in [vendor/VENDORED.md](vendor/VENDORED.md),
  unmodified except for the changes it lists; refresh them only by re-copying.
- No contract here emits or stores the Zone callback `senderTag` or a cardholder address; Bridge
  matches private spends by the Portal's own events.

Validate with `forge fmt --check src test script`, `forge build`, and `FOUNDRY_PROFILE=ci forge test`
here, plus `python3 script/matrix.py --out reports/matrix.md` and a diff against
`../docs/bridge/matrix.md` when card scenarios or setups change. `script/smoke.sh` and
`pnpm e2e:bridge` need Docker ([Running it](README.md#running-it)).

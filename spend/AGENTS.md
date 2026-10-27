# Tempo Spend (Bridge card spend)

Card spend through Bridge's spender contracts: the `TS` handler, `BridgeSettler`, the card E2E
harness, and Bridge's deploy scripts. [README.md](README.md) maps the project and
[docs/spend/design.md](../docs/spend/design.md) owns the design.

- This is its own Foundry project. Run every `forge` command from `spend/`, after
  `scripts/solidity-deps.sh spend` (from the repository root) installs `lib/` at the revisions
  `foundry.lock` pins. Never add its
  remappings, dependencies, or hardfork to `earn/foundry.toml`: Earn's remappings feed the
  metadata hash of its reviewed releases, and tempoxyz/tempo builds `earn/src/`.
- Import Earn through `tempo-earn/` (`earn/src/`) and the router through `tempo-router/`
  (`router/src/`), never a copy. A change to Earn's interfaces
  that breaks this project is fixed in the same pull request.
- Bridge-specific code stays here; `earn/` stays customer-agnostic and never imports from
  `spend/`.
- `vendor/` holds Bridge and Zone sources at the commits in [vendor/VENDORED.md](vendor/VENDORED.md),
  unmodified except for the changes it lists; refresh them only by re-copying.
- No contract here emits or stores the Zone callback `senderTag` or a cardholder address; Bridge
  matches private spends by the Portal's own events.

Validate with `forge fmt --check src test script`, `forge build`, and `forge test` here, plus
`python3 script/matrix.py --out reports/matrix.md` and a diff against `../docs/spend/matrix.md` when card
scenarios or setups change. `script/smoke.sh` and `pnpm e2e:spend` need Docker
([Running it](README.md#running-it)).

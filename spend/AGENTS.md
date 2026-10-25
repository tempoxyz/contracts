# Tempo Spend (Bridge card spend)

Card spend through Bridge's spender contracts: the `TS` handler, the Zone receiver, the card E2E
harness, and Bridge's deploy scripts. [README.md](README.md) maps the project and
[docs/design.md](docs/design.md) owns the design.

- This is its own Foundry project. Run every `forge` command from `spend/`, after
  `scripts/solidity-deps.sh spend` (from the repository root) installs `lib/` at the revisions
  `foundry.lock` pins. Never add its
  remappings, dependencies, or hardfork to `earn/foundry.toml`: Earn's remappings feed the
  metadata hash of its reviewed releases, and tempoxyz/tempo builds `earn/src/`.
- Import Earn through `tempo-earn/` (`earn/src/`), never a copy. A change to Earn's interfaces
  that breaks this project is fixed in the same pull request.
- Bridge-specific code stays here; `earn/` stays customer-agnostic and never imports from
  `spend/`.
- `vendor/` holds unmodified Bridge and Zone sources at the commits in
  [vendor/VENDORED.md](vendor/VENDORED.md); refresh them only by re-copying.
- `ZoneSpendReceiver` emits the callback `senderTag`, which Bridge matches settlements by. This is a
  known exception to Earn's [privacy model](../earn/docs/architecture/security-and-privacy.md#privacy-model);
  do not extend it to other contracts.

Validate with `forge fmt --check src test script`, `forge build`, and `forge test` here, plus
`python3 script/matrix.py --out reports/matrix.md` and a diff against `docs/matrix.md` when card
scenarios or setups change. `script/smoke.sh` and `e2e/zone` need Docker
([Running it](README.md#running-it)).

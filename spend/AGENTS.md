# Tempo Spend (Bridge card spend)

Card spend through Bridge's spender contracts: the `TS` handler, the Zone receiver, the card E2E
harness, and Bridge's deploy scripts. [README.md](README.md) maps the project and
[docs/design.md](docs/design.md) owns the design.

- This is its own Foundry project. Run every `forge` command from `spend/`, after
  `script/deps.sh` installs `lib/` at the revisions `foundry.lock` pins (they are not submodules). Never add its
  remappings, dependencies, or hardfork to the root `foundry.toml`: the root remappings feed the
  metadata hash of Earn's reviewed releases, and tempoxyz/tempo builds the root `src/`.
- Import Earn through `tempo-earn/` (the root `src/`), never a copy. A change to Earn's interfaces
  that breaks this project is fixed in the same pull request.
- Bridge-specific code stays here; Earn's root `src/` stays customer-agnostic and never imports
  from `spend/`.
- `vendor/` holds unmodified Bridge and Zone sources at the commits in
  [vendor/VENDORED.md](vendor/VENDORED.md); refresh them only by re-copying.
- `ZoneSpendReceiver` emits the callback `senderTag`, which Bridge matches settlements by. This is a
  known exception to Earn's [privacy model](../docs/architecture/security-and-privacy.md#privacy-model);
  do not extend it to other contracts.

Validate with `forge fmt --check src test script`, `forge build`, and `forge test` here, plus
`python3 script/matrix.py --out reports/matrix.md` and a diff against `docs/matrix.md` when card
scenarios or setups change. `script/smoke.sh` and `e2e/zone` need Docker
([Running it](README.md#running-it)).

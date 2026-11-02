# Provider-agnostic card spend

`CardSpender`, `CardSettler` and `CardSpend` are provider-agnostic; each provider adds only an
`ICardProgram` adapter under `src/providers/<provider>/` and its vendored contracts under
`vendor/<provider>/`. [README.md](README.md) maps the project and
[docs/cards/design.md](../docs/cards/design.md) owns the design.

- This is its own Foundry project. Run every `forge` command from `cards/`, after
  `scripts/solidity-deps.sh cards` (from the repository root). Never add its remappings or settings to
  another project's `foundry.toml`.
- Import Earn through `tempo-earn/` and the Zone router through `zone-router/`, never a copy. Nothing in
  `earn/`, `zone-router/` or `bridge/` imports from here.
- Provider code never enters the agnostic contracts: no provider name, address or rule in
  `CardSpender`, `CardSettler` or `CardSpend`. A provider that needs evidence about a destination reads
  it from `CardSpend.destinationHint`.
- `vendor/` holds providers' sources unmodified at the provenance in [vendor/VENDORED.md](vendor/VENDORED.md).
  Rain's exact pragma (0.8.17) does not build here: tests and scripts deploy
  `test/fixtures/rain.json`, which `script/rain/build-fixture.sh` rebuilds (`--check` compares it
  without the metadata hashes, which differ by checkout path); commit it with any vendor change.
- No contract here emits or stores the Zone callback `senderTag` or a cardholder address on the private
  path.

Validate with `forge fmt --check src test script`, `forge build`, `forge lint --deny warnings src`,
`forge build --sizes src`, `FOUNDRY_PROFILE=ci forge test`, and `pnpm e2e:cards -- --earn` (Docker)
when a spend flow changes.

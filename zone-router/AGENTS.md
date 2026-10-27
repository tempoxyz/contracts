# Tempo Zone router

Zone withdrawal callbacks on Tempo: `ZoneRouter`, `ZoneRouterFactory`, the `ISpendSettler`
interface, and the settlers in `src/settlers/`. [README.md](README.md) maps the project and
[docs/zone-router/zone-router.md](../docs/zone-router/zone-router.md) owns the design.

- This is its own Foundry project, built with solc (not Earn's solar) so hosted deployments can
  source-verify it. Run every `forge` command from `zone-router/`, after `scripts/solidity-deps.sh zone-router`
  (from the repository root). Never add its remappings or settings to `earn/foundry.toml`. Its own
  remappings feed every contract's metadata hash, so a new one moves every release address.
- `src/` imports only Earn's interfaces, through `tempo-earn/` (`earn/src/`); tests may also use
  Earn's contracts through `tempo-earn/` and its test helpers through `earn-test/` (`earn/test/`).
  Never copy Earn code here.
- Settlers live in `src/settlers/`, each adapting one payee system. A settler may hold a minimal
  interface for the external system it pays into, under `src/settlers/<system>/` (as `bridge/` holds
  the `Spend` struct and the two Bridge calls `BridgeSettler` makes), but never vendored code. This
  project never imports from `bridge/`; `bridge/` imports `Spend` from here, so a change to it
  changes the "TS" handler's ABI too.
- Preserve the router's invariants: no owner or setters, a mode fixed at deployment, canonical
  Messenger, Zone and Portal authentication, conversion only at exact par with measured 1:1 output,
  no balance or approval left after a callback, and no `senderTag` emitted or stored. A settler
  gets at most the callback's `maxInput`; everything else returns through the source Portal.
- `SingleZoneEarnRouter` stays in `earn/` until its consumers move; ops 0 and 1 here must accept its
  callback data byte for byte.

Validate with `forge fmt --check`, `forge lint --deny warnings src`, `forge build --sizes src`,
and `FOUNDRY_PROFILE=ci forge test` here, plus `bridge/`'s tests when `ISpendSettler`, the callback
format, `BridgeSettler` or `settlers/bridge/` changes ([bridge/AGENTS.md](../bridge/AGENTS.md)), and
`pnpm --filter @tempoxyz/earn abis` after an interface change.

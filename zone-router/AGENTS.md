# Tempo Zone router

Zone withdrawal callbacks on Tempo: `ZoneRouter`, `ZoneRouterFactory`, the `ISpender`
interface, and the spenders in `src/spenders/`. [README.md](README.md) maps the project and
[docs/zone-router/zone-router.md](../docs/zone-router/zone-router.md) owns the design.

- This is its own Foundry project, built with solc (not Earn's solar) so hosted deployments can
  source-verify it. Run every `forge` command from `zone-router/`, after `scripts/solidity-deps.sh zone-router`
  (from the repository root). Never add its remappings or settings to `earn/foundry.toml`. Its own
  remappings feed every contract's metadata hash, so a new one moves every release address.
- `src/` imports only Earn's interfaces, through `tempo-earn/` (`earn/src/`); tests may also use
  Earn's contracts through `tempo-earn/` and its test helpers through `earn-test/` (`earn/test/`).
  Never copy Earn code here.
- Generic spenders live in `src/spenders/`, each adapting one payee system. A spender that belongs to
  another project lives there and implements `ISpender` from here, as the card project's
  `CardSpender` (`cards/src/core/`) does. This project never imports from `cards/`.
- Preserve the router's invariants: no owner or setters, a mode fixed at deployment, canonical
  Messenger, Zone and Portal authentication, conversion only at exact par with measured 1:1 output,
  no balance left after a callback and no approval except a spend's standing one to its own Zone's
  Portal, and no `senderTag` emitted or stored. A spender
  gets at most the callback's `maxInput`; everything else returns through the source Portal.
- `SingleZoneEarnRouter` stays in `earn/` until its consumers move; ops 0 and 1 here must accept its
  callback data byte for byte.

Validate with `forge fmt --check`, `forge lint --deny warnings src`, `forge build --sizes src`,
and `FOUNDRY_PROFILE=ci forge test` here, plus `cards/`'s tests when `ISpender` or the callback
format changes ([cards/AGENTS.md](../cards/AGENTS.md)), and
`pnpm --filter @tempoxyz/contracts abis` after an interface change.

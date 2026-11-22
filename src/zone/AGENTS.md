# Tempo Zone router

Zone withdrawal callbacks on Tempo: `ZoneRouter`, `ZoneRouterFactory`, the `ISpender` interface
(`src/interfaces/zone/`), and the spenders in `src/zone/spenders/`. This guide also covers their
tests (`test/zone/`) and deployment scripts (`script/zone/`). The
[Zone router overview](../../docs/zone/README.md) maps the domain and
[docs/zone/zone-router.md](../../docs/zone/zone-router.md) owns the design.

- `src/zone/` imports only Earn's interfaces (`src/interfaces/earn/`), by relative path; tests may
  also use Earn's contracts and test helpers (`test/earn/`). Never copy Earn code here.
- The remappings, source paths, and compiler settings in the root `foundry.toml` feed every
  contract's metadata hash, so changing them, or moving a source file, moves every release address.
- Generic spenders live in `src/zone/spenders/`, each adapting one payee system. A spender that belongs
  to another domain lives there and implements `ISpender` from here, as card spend's `CardSpender`
  (`src/spend/`) does. Nothing here imports from `src/spend/`.
- Preserve the router's invariants: no owner or setters, a mode fixed at deployment, canonical
  Messenger, Zone and Portal authentication, conversion only at exact par with measured 1:1 output,
  no balance left after a callback and no approval except a standing one to its own Zone's Portal
  (which moves the router's tokens only inside a `depositEncrypted` call the router makes) and
  standing maximums to the immutable EarnVault and pool (which pull only from `msg.sender`), and no
  `senderTag` emitted or stored. A spender gets at most the callback's `maxInput`; everything else
  returns through the source Portal.
- `SingleZoneEarnRouter` stays in `src/earn/router/` until its consumers move; ops 0 and 1 here must
  accept its callback data byte for byte.

Validate from the repository root with `forge fmt --check`, `forge lint --deny warnings src/zone`,
`forge build --sizes src/zone`, and `FOUNDRY_PROFILE=ci forge test --match-path 'test/zone/**'`,
plus the spend tests when `ISpender` or the callback format changes
([src/spend/AGENTS.md](../spend/AGENTS.md)), and `pnpm --filter @tempoxyz/contracts abis` after an
interface change.

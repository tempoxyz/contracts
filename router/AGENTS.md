# Tempo Zone router

Zone withdrawal callbacks on Tempo: `ZoneRouter`, `ZoneRouterFactory`, and the `ISpendSettler`
interface settlers implement. [README.md](README.md) maps the project and
[docs/router/zone-router.md](../docs/router/zone-router.md) owns the design.

- This is its own Foundry project, built with solc (not Earn's solar) so hosted deployments can
  source-verify it. Run every `forge` command from `router/`, after `scripts/solidity-deps.sh router`
  (from the repository root). Never add its remappings or settings to `earn/foundry.toml`.
- `src/` imports only Earn's interfaces, through `tempo-earn/` (`earn/src/`); tests may also use
  Earn's contracts through `tempo-earn/` and its test helpers through `earn-test/` (`earn/test/`).
  Never copy Earn code here.
- Integrator-specific code (Bridge's settler, card logic) stays in `spend/` or its own project; this
  project stays integrator-agnostic and never imports from `spend/`.
- Preserve the router's invariants: no owner or setters, a mode fixed at deployment, canonical
  Messenger, Zone and Portal authentication, conversion only at exact par with measured 1:1 output,
  no balance or approval left after a callback, and no `senderTag` emitted or stored. A settler
  gets at most the callback's `maxInput`; everything else returns through the source Portal.
- `SingleZoneEarnRouter` stays in `earn/` until its consumers move; ops 0 and 1 here must accept its
  callback data byte for byte.

Validate with `forge fmt --check`, `forge lint --deny warnings src`, `forge build --sizes src`, and
`FOUNDRY_PROFILE=ci forge test` here, plus spend's tests when `ISpendSettler` or the callback
format changes.

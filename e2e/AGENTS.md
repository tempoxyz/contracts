# Integration and hosted validation

[E2E environments](../docs/deployment/e2e-environments.md) owns commands, the module layout, case
selection, and hosted configuration; [profiles](../profiles/README.md#acceptance-and-test-fixtures)
owns the test fixture bootstrap.

- A capability's cases live only in its self-registering `modules/<group>/` folder and per-engine
  behavior only in `engines/<kind>/`; `harness/` never branches on either.
- Cases express reusable observable behavior and gate on a capability or an engine hook.
  Environment-specific fixtures and addresses belong in the environment loaders, not branches
  inside shared case logic.
- Hosted runs target a deployed profile through `harness/hosted.ts`; local runs consume typed
  `Environment.run` state. E2E owns fixtures and acceptance, not another engine/core/router deployer.
- Core Zones owns hosted Zone infrastructure, and the Zone administrator and pool owner their
  admission and inventory. Hosted E2E and benchmarks never hold either key, and never disable
  policy, admission, or gateway checks or repair Zone infrastructure to pass.
- Reuse the Zone transport in `harness/context.ts`. API-key runs do not prove caller-token RPC
  isolation.
- Before blaming Earn code, check canonical Zone identity, protocol compatibility, access controls,
  and output readiness against the canonical deployment record and the relevant integration case.
- Benchmarks finish setup before timing, stop when the user's result is observable, and need no
  deployment or access-role keys.

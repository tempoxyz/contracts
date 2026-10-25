# App deployment

This runbook covers how completed profiles reach the hosted app: the browser catalog the Worker
serves, its regeneration, and the preview and production deploys. Core deployment, verification,
and authority handoffs are in [the deployment runbook](deployment.md); what is deployed is in
[the hosted environments runbook](hosted-environments.md). Paths and commands are
repository-relative.

## Catalog boundaries

- The `catalog` constant in `app/deployments/generate.ts` is the catalog's only input. It names the
  default environment and, per served hosted environment, the listed profile IDs with the
  description the app renders, plus `zone: true` when the environment shows its Tempo-owned hosted
  Zone. The first listed profile is the environment's default stack. A hosted environment with no
  active reviewed stack is omitted. Chain IDs, RPC and explorer URLs, and the hosted Zone's ID and
  chain ID come from `hostedEnvironments` (`@tempoxyz/earn/deployments`); they are not configured.
- `app/deployments/generate.ts` writes `app/deployments/generated.json`, the browser-safe
  environment catalog, and formats it with `vp fmt`. The Worker bundles it and serves it at
  `/api/config`. A listed stack is the shared `EarnStack` allowlisted by `publicStack`
  (`@tempoxyz/earn/deployments`) plus its description; its operations, provenance, and E2E fixture
  never enter it, and `parsePublicStackCatalog` rejects them. A stack with a private route also
  carries `privateAssetMetadata`, the route asset's name, symbol, and decimals. Never edit
  `generated.json` directly. `pnpm dev:local` points the Vite alias at an ignored generated local
  catalog instead.
- The catalog lists only canonical PATHUSD vault stacks and their scoped private routes. A profile
  reaches it only through its `deployment.json` and live reads, never its `fixture.json`;
  operational test tokens, roles, and receipts never appear in the browser app. Protected access
  must reference an existing reusable TIP-403 policy, administered outside the catalog.
- Public-only deployments omit `contracts.earnRouter`; never substitute the EarnVault, zero address,
  or another contract. A profile with a Zone router gets `contracts.earnRouter`, a private mode, and
  the environment's Zone.
- Advertise only capabilities supported by the browser flow and the verified deployment. The
  catalog never advertises queued exits (`asyncRedeem` is always `false`): a Veda Queue's presence
  alone does not mean the browser implements them.
- Never publish RPC credentials in the catalog or browser configuration. Hosted L1 and Zone requests
  use `TEMPO_API_KEY` only in the same-origin Worker proxy ([runtime](../development/app-runtime.md)).
- Tempo mainnet is chain `4217` and has no faucet or app sponsor. Mainnet passkeys use viem's
  `tempoMainnet` chain with `testnet: false`; Privy and passkey transactions are self-funded. There
  is no tracked mainnet app dotenv template.

## Regenerating the catalog

After a listed profile is deployed or redeployed, or the `catalog` constant changes, run:

```bash
pnpm --filter app deployment:catalog
```

For each environment it checks that the public RPC serves the environment's chain and, with
`zone: true`, discovers the Zone's Portal, Messenger, and sequencers from the L1 ZoneFactory; that
Portal must enable PATHUSD. For each listed profile it loads the committed record and builds the
stack with the shared `loadHostedProfileStack` loader that hosted E2E uses, over the chain's public
RPC (engine periphery comes from the engine). It refuses a profile on another chain, a
non-PATHUSD asset, or a private route through a Zone the environment does not list, and runs the
same deployment inspection as `pnpm earn verify`: binding mismatches fail, and so does any
capability that reports `blocked`, such as a router whose pool admission, par price, oracle
freshness, inventory, or Portal token readiness is missing. It sends no transaction and needs no
key. Rerunning it against unchanged deployments reproduces `generated.json` exactly.

## Contract lifecycle

The app's own stack is an ordinary profile, `profiles/app-<environment>/profile.json`, deployed,
verified, and resumed by the shared lifecycle; app code only projects its completed record into the
catalog and never deploys contracts or keeps its own deployment state:

```bash
pnpm earn deploy earn/profiles/app-moderato/profile.json
pnpm --filter app deployment:catalog
```

When the lifecycle stops at an external handoff, it prints the instructions and exits. Pool
admission and inventory belong to the pool owner, and Zone token enablement and router
callback-gateway registration to the Zone administrator
([authority boundaries](deployment.md#authority-boundaries)); rerun after they act. Account admission
is a separate administrator operation; never disable enforcement for the app. Regenerate the catalog
only once the record's `contractVerification` is `verified`, and commit `generated.json` with the
profile's `deployment.json`. `pnpm earn deploy` and `verify` reject a record whose L1 genesis or
Zone Portal and Messenger no longer match the live chain, and catalog generation rejects a stale
Zone identity.

## Preview and production

The catalog ships inside the Worker bundle, so it changes only when the Worker is deployed:

- **Preview.** For a same-repository pull request, the `Pull Request` workflow builds the static
  client (`pnpm --filter app build:preview`) into a secretless artifact. When that workflow
  succeeds, `preview.yml` (a trusted `workflow_run` job) builds the preview Worker from the default
  branch, installs the pull request's client assets, uploads a Worker version with the alias
  `pr-<number>`, and comments the URL on the pull request. The preview's `/api/config` therefore
  serves the default branch's catalog, not the pull request's `generated.json`.
- **Production.** Every push to `main` runs `main.yml`: the shared `Verify` workflow, then
  `pnpm --filter app build` and `wrangler deploy --env production` in the `production` environment.

Both deploy jobs smoke-test `/` and `/health` and parse the live `/api/config` with the browser's
own loader (`app/deployments/check-live-config.ts`), so a catalog the app cannot render fails the
deploy. Credentials and the remaining CI jobs are in [development](../../../docs/development.md).

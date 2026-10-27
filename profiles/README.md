# Deployment profiles

Each `<id>/profile.json` is one complete, non-secret deployment intent, consumed directly by
`pnpm earn deploy` and profile E2E. This page owns the authored JSON, profiles kept in another
repository, and the hosted test-fixture bootstrap. The lifecycle, the generated `deployment.json`
beside each profile, verification, and authority handoffs are in the
[deployment runbook](../docs/deployment/deployment.md). RPC URLs, keys, receipts, generated
addresses, and progress never belong in the authored file.

## Identity

`id` names the profile directory and is the permanent deployment identity. `version` is its
positive onchain deployment revision. Factories derive their deterministic salt from
`<id>:v<version>`, so a new version is a fresh stack and the same version resumes the same stack.
Directory IDs follow `<deployment>-<l1-network>[-<zone>]`, for example `e2e-moderato`,
`veda-moderato`, and `app-moderato`; the Zone suffix is omitted without a `zone`.

`chainId` selects Tempo mainnet (`4217`) or Moderato (`42431`); no other chain parses. Runtime
values come from `.env.<id>` ([commands](../docs/deployment/deployment.md#commands)). The deployer
is derived from `DEPLOYER_PRIVATE_KEY` and the shared factory release from the reviewed per-chain
registry; both are pinned in the generated record, never authored.

## Schema

The smallest useful configuration is:

```json
{
  "version": 1,
  "id": "example-mainnet",
  "chainId": 4217,
  "engine": {
    "kind": "erc4626",
    "venue": "0x..."
  }
}
```

Disabled optional addresses, limits, fees, policy, Zone integration, and rewards are omitted, never
set to `null`; an empty `core` or `core.fees` object is rejected. Top-level keys:

- `engine`: `{ "kind": "erc4626", "venue": "0x..." }` provisions a factory-created ERC-4626 engine
  that inherits the venue's metadata. `{ "kind": "<kind>", "address": "0x..." }` reuses an
  existing, reviewed, unbound engine of any [engine kind](../docs/earn/integrations/engines.md).
- `owner`: the final engine owner, core operator, and optional periphery owner. Omitted, it
  defaults to the deployer; when explicit, the deployer binds and transfers atomically.
- `core`, omitted when it has no nondefault configuration, may contain:
  - `emergencyGuardian` and `asyncJanitor`;
  - `fees`: `fixed` lists operator-controlled fixed fees, `excess` the excess-return fee, and
    `protectedFixed` groups the one fee, distributor, and delay that form the protected unit; at
    most four fixed recipients in total ([fees](../docs/earn/architecture/fees.md)).

  Deployments start without a managed-asset limit; the operator sets one onchain when needed.

- `tip403PolicyId`: attaches an existing simple whitelist; omission means open access. Its
  [required members](../docs/earn/modules/access.md#required-members) are derived from the deployment.
- `zone`: the complete private integration: Zone `id`, `enableEarnShare: true`, and a nested
  `router` with the one immutable route. `router.privateAsset` is singular because one router
  supports exactly one pair; another private asset needs another router. With a conversion pool,
  `router.pool` is the DirectPropAMM pool that trades exactly that pair with equal decimals, and
  `router.customerId` is its nonzero bytes32 route identifier. When `privateAsset` is the vault
  asset, omit both `pool` and `customerId` (setting only one is rejected). The Zone chain ID is
  derived from `chainId` and `zone.id` using the protocol's reserved ranges.
- `zoneRouter`: one [`ZoneRouter`](../docs/zone-router/zone-router.md) mode and the factory that deploys
  it ([Zone routers](#zone-routers)).
- `targetYield` and `boostRewards`: optional reward periphery ([rewards](#rewards)).

Profiles are not lifecycle controls: removing a capability cannot disable or erase an
already-deployed immutable contract. Retire its Tempo API operations separately and preserve any
outstanding Merkle claim path. A changed optional component (`zone`, `targetYield`, `boostRewards`,
`zoneRouter`, or `zoneRouterFactory`) redeploys only that component's contracts; core and engine
never change in place.
Profiles that bind existing production infrastructure name only that infrastructure (venue,
private asset, pool, and customer ID); E2E derives the deployed base asset from `deployment.json`.

### Initially zero distributor fee

To reserve distributor authority without charging fees, configure `core.fees.protectedFixed` with
`recipient` set to the zero address, `rateBps: 0`, the intended nonzero `distributor`, and a nonzero
`updateDelaySeconds` (for example `"604800"` for seven days). The deployment emits no initial
fixed-fee entries, and no fee-recipient policy membership is needed while the fee is zero; the
distributor selects a recipient when it schedules activation. Omit initial operator fixed fees in
this configuration; the operator can configure its own fees after deployment, subject to the
protected-item and three-slot rules.

## Zone routers

`zoneRouter` deploys one [`ZoneRouter`](../docs/zone-router/zone-router.md#modes) through a
`ZoneRouterFactory`, from the separate [`zone-router/`](../zone-router/README.md) project. It sits beside
`zone`, whose `SingleZoneEarnRouter` it does not replace. Card and Earn on one Zone:

```json
{
  "zoneRouter": {
    "zoneId": 7,
    "ops": ["deposit", "redeem", "spend"],
    "earn": {
      "privateAsset": "0x...",
      "pool": "0x...",
      "customerId": "0x..."
    },
    "settlers": ["0x..."],
    "factory": "0x..."
  }
}
```

- `zoneId` is the one Zone whose callbacks it takes; its Factory-registered Portal is discovered and
  recorded as `zoneRouterPortal`.
- `ops` lists `deposit`, `redeem` and `spend` in that order, at least one; it is the mode's
  `enabledOps` bitmask.
- `earn` is required with `deposit` or `redeem` and rejected otherwise. The router binds the
  profile's own EarnVault; `privateAsset`, `pool` and `customerId` follow `zone.router`'s rules
  (omit both `pool` and `customerId` when the private asset is the vault asset).
- `settlers`, required with `spend` and rejected otherwise, lists the deployed `ISpendSettler`
  contracts, such as a `SendSettler` or a card program's `BridgeSettler` from
  [Zone Router Release](../docs/deployment/deployment.md#zone-router-releases), without repeats. Their order is part of the
  mode, so of the router's address.
- `factory` names an existing `ZoneRouterFactory`. Omitted, the lifecycle deploys one as its own
  `zoneRouterFactory` component, so a later mode change deploys only a new router through it.

A different mode is a new router at a new address, which the Zone must admit again
([lifecycle](../docs/zone-router/zone-router.md#deployment)).

## Rewards

`targetYield` deploys the contribution controller and `boostRewards` the Merkle distributor
([rewards](../docs/earn/modules/rewards.md)). Presence makes the vault-bound contract part of
deployment intent. Tempo API interprets and operates the configuration; this repository validates
and records it but does not fetch or persist rate observations. A minimal boost addition is:

```json
{
  "boostRewards": {
    "startTimestamp": 1788220800,
    "endTimestamp": 1790812800,
    "intervalSeconds": 60,
    "targetAnnualRateBps": 700,
    "perUserPrincipalCapAssets": "25000000000",
    "totalPrincipalCapAssets": "10000000000000",
    "treasury": "0x...",
    "funding": {
      "wallet": "0x..."
    }
  }
}
```

Rates are basis points, timestamps are UTC Unix seconds, and asset values are base-asset atomic
units as decimal strings (for a six-decimal asset, `$25,000` and `$10,000,000` above). Every
interval is 60 to 300 seconds, and each window must contain a whole positive number of intervals.
Optional `excludedAddresses` contains only integrator custody not derivable from the stack. The
per-user cap cannot exceed the total cap. The campaign ID derives from chain, profile ID, and
version, and the claim deadline is fixed at 30 days after `endTimestamp`.

For a benchmark with an ordered 1.5% provider contribution and remainder top-up, pair the boost
object with:

```json
{
  "targetYield": {
    "startTimestamp": 1788220800,
    "endTimestamp": 1790812800,
    "intervalSeconds": 60,
    "annualRate": {
      "morphoVault": "0xbeeF010f9cb27031ad51e3333f9aF9C6B1228183",
      "staleAfterSeconds": 300,
      "minBps": 0,
      "maxBps": 2000
    },
    "funding": [
      {
        "wallet": "0x...",
        "upToAnnualRate": { "bps": 150 }
      },
      {
        "wallet": "0x...",
        "remainder": true
      }
    ]
  }
}
```

`annualRate` is either a fixed `{ "bps": <n> }` or, as above, a Morpho vault rate source with its
staleness bound and clamp. Target-yield programs are finite, their funding wallets must be unique,
and the ordered waterfall must end with exactly one `remainder` source. Tempo API first confirms the
target-yield settlement for an interval, then computes the boost needed to reach
`targetAnnualRateBps`. When both capabilities are present, target yield must cover the complete
boost window and each boost boundary must align to a target-yield interval. Funding is bounded by
each wallet's balance and explicit allowance to its controller or distributor.

## Checked-in profiles

Each directory here is one deployment, and its generated `deployment.json` is the source of truth
for what is deployed. `pnpm check` (through `pnpm profiles`) rejects a profile without one unless
its deployment is in progress (`deployment.pending.json`), and rejects duplicate IDs. The
Tempo-owned test profiles are described in
[current availability](../docs/deployment/hosted-environments.md#current-availability). Before
going live with a Zone-integrated profile, use the
[go-live checklist](../docs/earn/modules/zone-router.md#go-live-checklist).

## Profiles in another repository

Profiles can also live in another repository that pins Earn as a Git submodule and
runs this tooling against its own `profiles/` directory. The tooling treats any
`<root>/profiles/<id>/profile.json` exactly like the profiles here: the record, pending state, and
`fixture.json` sit beside the profile, and `.env.<id>` sits at that `<root>`; Forge outputs are
[staged inside Earn](../docs/deployment/deployment.md#lifecycle) and synced back there. Relative paths
resolve from the directory the command starts in (pnpm's `INIT_CWD`), so from such a repository:

```bash
pnpm --dir earn earn verify profiles/<id>/profile.json
pnpm --dir earn e2e:profile profiles/<id>/profile.json --validate-only
pnpm --dir earn profiles --profiles profiles
```

`pnpm profiles --profiles <directory>` applies the checked-in-profile validation to that
directory; `--matrix` instead prints every recorded profile with its hosted chain's public RPC as
one line of JSON (the `profiles` output under GitHub Actions). Adding a profile there takes only
`<id>/profile.json`, its generated `deployment.json`, and the operator's ignored `.env.<id>` in
that repository.

## Acceptance and test fixtures

A disposable hosted test stack is an ordinary profile: bootstrap its test fixture, then deploy and
run acceptance with the same profile path. A production profile skips the bootstrap.

```bash
pnpm e2e:fixture --profile <profile-id> --network moderato             # plan only
pnpm e2e:fixture --profile <profile-id> --network moderato --broadcast
pnpm earn deploy profiles/<profile-id>/profile.json
pnpm e2e:profile profiles/<profile-id>/profile.json
```

Profile E2E derives its target and cases from the profile and its record, and rejects a record
whose intent no longer matches the profile
([profile acceptance](../docs/deployment/e2e-environments.md#profile-acceptance)). Run a reward
profile with `--local --group rewards` to exercise the reward contracts it configures.

`pnpm e2e:fixture --profile <id|path> --network <moderato|mainnet> [--broadcast]`
(`e2e/fixtures/bootstrap.ts`) provisions a disposable test profile's fixture with localnet's fixture
steps, one transaction each, owned by the deployer. A bare ID names a profile in Earn's own
`profiles/`; pass a path for a profile elsewhere. `--network` must match the profile's chain. What a
profile gets is its engine kind's `hostedFixture` in `localnet/src/engines/<kind>.ts`; a kind
without one is refused:

- A kind whose fixture runs over canonical PATHUSD (public profiles only) gets its localnet venue
  and engine, recorded as `engineFixtures`; the engine must source-verify against this checkout and
  pass its ready inspection, and the profile names it.
- Any other kind (testnets only) gets a test stablecoin pair, a `DemoStablecoinFunder` holding
  their issuer roles, a venue with locked seed liquidity, and, for a Zone profile, the router's
  conversion pool, so the lifecycle's `authorize-router` step admits the router.

Before anything is signed, it checks that the RPC serves the profile's chain and, when a
`deployment.json` exists, that `DEPLOYER_PRIVATE_KEY` signs as its `deployer`. A broadcast tops up
a deployer holding less than 1 PATHUSD from the faucet, or fails where there is none. After
provisioning it validates every fixture contract and binding: code at each address, the funder's
pair and issuer roles, the conversion pool's pair, oracle, registry, owner, and unpaused state, and
the kind's own fixture bindings. It then rewrites and re-parses the profile, writes `fixture.json`
beside it with each fixture contract's runtime code hash and the fixture transactions, and removes
a replaced `deployment.json`. Without `--broadcast` it only prints its plan. It is intentionally
separate from `pnpm earn deploy`, which never creates demo assets, pools, or authorities.
Production profiles have no `fixture.json`. An existing `deployment.json` is refused unless the
replacement is acknowledged with `--replace-existing-deployment --version <n>`, a new explicit
version.

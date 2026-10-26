# E2E environments

Every E2E environment prepares its own context, then runs the same case registry through the same
runner. Hosted availability and troubleshooting are in the
[hosted environments runbook](hosted-environments.md), and latency measurements in
[benchmarks](benchmarks.md).

| Environment                                 | Command                           | Stack                                             | Purpose                                 |
| ------------------------------------------- | --------------------------------- | ------------------------------------------------- | --------------------------------------- |
| `local`                                     | `pnpm e2e:local`                  | disposable chains and stack from `localnet/`      | deterministic full L1 + Zone validation |
| each hosted network (`moderato`, `mainnet`) | `pnpm e2e:profile <profile.json>` | one deployed profile                              | hosted public and private validation    |
| `devnet`                                    | `pnpm e2e:devnet`                 | a fresh localnet stack on an existing L1 and Zone | Zone protocol acceptance on a devnet    |

Hosted E2E has one environment per [hosted network](hosted-environments.md#adding-a-hosted-network)
and always runs against one deployed profile: `e2e/harness/hosted.ts` builds the run's `EarnStack`
from the profile, its generated `deployment.json`, an optional `fixture.json`, and live reads
(token metadata, roles, Zone sequencers, and the engine's periphery); there is no checked-in hosted
manifest. Local E2E consumes the typed localnet state directly.

## Cases and selection

Each capability is one module folder, [`e2e/modules/<group>/`](../../e2e/modules/), whose folder
name is its cases' group (`access`, `controls`, `fees`, `public`, `rewards`, `veda`, `zone`). Its
`module.ts` exports `cases` and may export `launchFeatures` (the launch features it owns),
`benchmark` (its part in the [latency benchmark](benchmarks.md)), `validate` (read-only checks of
what its cases assume, run before any case signs), and `integrity` (state every case must restore).
The Zone module's checks cover the router's flows, custody, allowances, conversion readiness, and
pool admission. The harness discovers every folder, so adding a module means adding its folder and
nothing else. Cases model one externally meaningful interaction: reusable actions contain
transaction mechanics, and cases own setup, assertions, and the coverage they declare.

Per-engine behavior lives in `e2e/engines/<kind>/engine.ts`, whose folder names must equal the
engine registry's kinds. Hosted test-fixture tooling is in `e2e/fixtures/`; the runner,
environments, selection, and context are in `e2e/harness/`, with shared helpers in
`e2e/harness/support/`. The harness imports a module only to discover it.

```bash
pnpm e2e:local -- --list       # every case ID, group, and description
pnpm e2e:local -- --case public-withdraw-exact-third-party
pnpm e2e:local -- --variant veda --all
pnpm e2e:local -- --variant all --launch
pnpm e2e:profile profiles/<profile-id>/profile.json --group zone
pnpm e2e:profile profiles/<profile-id>/profile.json --launch
```

A run takes at most one selector:

- no selector runs the `default: true` acceptance cases the target supports: a public lifecycle,
  plus the Zone lifecycle and protected-access acceptance cases when the stack offers them;
- `--case <id>` runs one case, the smallest isolating flow;
- `--group <module>` runs one module's cases;
- `--all` runs every case the target supports;
- `--launch` is the release gate: every `launch: true` case the target supports.

`--variant <engine kind|all>` picks the local stack's engine (default `erc4626`); a local run with
`--earn-file <profile.json>` uses the profile's engine instead. `--shard <index>/<count>` splits the
selection into `count` bins balanced by each case's `weight`.

A run's target is its engine, environment, capabilities, access kind, recorded periphery, and
active fees. Each case states what it needs from that target: a capability, protected access,
periphery, active fees, an engine hook, or an environment. Selection keeps only supported cases,
and naming an unsupported case with `--case` is an error. Module discovery rejects a default case
that depends on the environment, so a hosted default run leaves one out only when its profile does
not offer what the case needs. Before a `--launch` run, the launch cases the target supports must
cover every dimension of each launch feature that applies to it (`validateLaunchFeatureCoverage` in
`e2e/harness/modules.ts`, with each feature's `applies` predicate in its module). Unit tests require
every committed profile and every local variant to pass that gate, and every case that can run
locally to be selected by some variant's `--all` run, so CI cannot silently drop one.

Every selected case reports `PASS`, `FAIL`, or `BLOCKED`; `BLOCKED` (`E2ePrerequisiteError`) is
reserved for advertised behavior stopped by an external dependency. Cleanup runs in `finally`, and
post-case integrity checks verify that the EarnVault's pause, operator, and guardian state, the
EarnShare transfer policy, and each module's `integrity` state are unchanged. Every run writes a
JSON result under `e2e/.results/` (`schemaVersion: 2`) with environment, engine, deployment,
profile, source commit and dirty state, and per-case `id`, `status`, duration, and failure or
blocker. Cases that run a public deposit or redemption, or a Zone deposit or redemption, also print
`TIMING` lines and record those actions' [phases](benchmarks.md#phases) as `timings`, so every
environment's run reports the same latency split as the benchmark.

Local runs poll every 250 ms; hosted and devnet runs every two seconds. In CI, the `Local E2E`
workflow (`local-zone.yml`) runs on pull requests whose change `.github/actions/e2e-scope` selects:
`pnpm e2e:local -- --variant <kind> --all --shard <n>/2` for every engine kind and both shards,
aggregated as `Required / Local E2E`.

## Profile acceptance

The deployment profile is the hosted acceptance input: `pnpm e2e:profile <profile.json>` loads the
profile's adjacent `deployment.json` and runs the acceptance cases its stack supports. Before any
case, hosted validation repeats the shared deployment inspection and fails on what that inspection
only reports: a blocked capability or engine readiness, a contract other than EarnVault holding the
EarnShare issuer role, unaligned accounting, a proxy implementation without code, or a missing
required TIP-403 member. It then checks EarnVault custody at rest, the fixture's live runtime and
funder, and each module's `validate`.

`--validate-only` runs only these read-only validations, with no signer, funding, or cases, and
inspects the profile's live Zone when `TEMPO_API_KEY` or `ZONE_RPC_URL` is set
([rechecking deployed profiles](deployment.md#rechecking-deployed-profiles)).

`--local` deploys the profile on the disposable stack through the shared lifecycle, replacing only
external dependencies (chain, venue or engine, TIP-403 policy, Zone ID, router assets and pool) with
local equivalents; fees, access kind, principals, the router, and the reward
contracts its `targetYield` and `boostRewards` imply are deployed as authored, at different
deterministic addresses. Variant runs without a profile deploy both reward contracts so
`--group rewards` exercises the controller. Tempo API owns campaign calculation, registration,
scheduling, and distribution E2E coverage.

## Hosted Zone access

Hosted private acceptance reaches the Zone through Tempo API with `TEMPO_API_KEY`, or through an
explicit `ZONE_RPC_URL`, using the transport in `e2e/harness/context.ts`. With the API key it
matches the app Worker's path, so it validates signed transactions and contract permissions, not
caller-token RPC isolation. An HTTP 502 from the API's caller-token upstream differs from the Portal
error `AccountNotAllowed(address)` (`0xedd9a13e`), which needs account admission. Check admission
with the `zonePortalAbi` views `isAccessEnforced()`, `isGatewayOpen()` (`true` when
callback-gateway registration is not enforced), and `hasRole(account, role)` (`Account` is `2`,
`CallbackGateway` is `3`). Token enablement and TIP-403 membership do not replace Portal
permissions, newly generated accounts also need admission while enforcement is on, and CI never
changes Portal admission or enforcement.

On an access-enforced Zone, each router return's Tempo refund recipient must hold the Portal
`Account` role. The first time a hosted case needs a refund recipient, E2E reads the Portal's
`isAccessEnforced()` and each acting account's `hasRole(account, 2)`. An admitted account refunds
to itself. Only the primary E2E user may instead refund to the admitted EarnVault operator or
pending operator, which the integrator controls; the first router case fails when neither is
admitted, and any other unadmitted actor cannot submit a return. A delegated refund leaves the
user's custody, so cases that reclaim a bounced refund, such as
`zone-ineligible-private-deposit-bounces`, are blocked unless the user is admitted.

A case whose user lacks enough private balance is funded through a Portal entry by the stack's
fixture funder. A stack without one, such as a production profile, cannot fund it: the case throws
`E2ePrerequisiteError` asking for a manual Zone top-up of that account, then a rerun.

## Hosted configuration

Hosted commands load the profile's ignored `.env.<profile-id>` as
[deployment commands](deployment.md#commands) do; values in the process environment take
precedence. Start from the root [`.env.example`](../../.env.example), which documents the
credential surface, and replace its public fixture identities before hosted use. The L1 RPC
defaults to the hosted network's public RPC unless `TEMPO_RPC_URL` is set.

`DEPLOYER_PRIVATE_KEY` (required for a case run) is the operator and, unless
`END_USER_PRIVATE_KEY` or `EARN_ACCESS_ADMIN_PRIVATE_KEY` names a distinct key, also the positive
user and access administrator; the run says which roles fall back to it. The protected-access
outsider key is derived from the operator key and must stay private, because hosted runs top up
every actor's fees with the operator's PATHUSD where there is no faucet.

## Hosted test fixtures

Bootstrapping, deploying, and running a disposable hosted stack is in
[deployment profiles](../../profiles/README.md#acceptance-and-test-fixtures). Hosted cases read a
Veda fixture's `engineFixtures` exactly as local cases do
([Veda test stacks](../modules/veda.md#test-stacks)).

Production scripts never deploy fixture funders or demo pools. The E2E stack's `stablecoinFixture`
(`e2e/fixtures/profile-fixture.ts`) is the one in `fixture.json` when there is one, otherwise the
profile's own conversion pair with no funder, so E2E uses prefunded actors. App catalogs contain no
E2E fixture, role, receipt, or transaction history.

## Existing devnet chains

`pnpm e2e:devnet -- --group zone` runs the cases against an existing non-hosted L1 and Zone; this
is the entry point devnet automation runs. `deploy` in `localnet/src/devnet.ts` deploys the default
ERC-4626 fixture and profile through the same `createBase` and `create` path a local run uses, and
`e2e/harness/devnet.ts` reuses the local run's validation and context. Beyond enabling its fixture
tokens and registering its router as a callback gateway, it never starts, stops, or reconfigures
either chain, changes Portal access modes, or admits accounts.

The caller supplies `TEMPO_RPC_URL`, `EXPECTED_L1_CHAIN_ID`, `ZONE_RPC_URL`, `ZONE_ID`,
`ZONE_CHAIN_ID`, `ZONE_PORTAL_ADDRESS`, and funded `DEPLOYER_PRIVATE_KEY`, `END_USER_PRIVATE_KEY`,
`INELIGIBLE_USER_PRIVATE_KEY`, `EARN_ACCESS_ADMIN_PRIVATE_KEY`, and `ZONE_ADMIN_PRIVATE_KEY`;
nothing falls back to hosted defaults. Before deploying, the run refuses a hosted chain ID, checks
the live L1 chain ID, inspects the Zone from the canonical Factory, and requires that the supplied
Portal is the Factory's, that the Zone admin key administers it, and, when it enforces access, that
every test actor already holds the `Account` role. `ZONE_RPC_URL` carries every Zone read and
submission, so it must also answer unauthenticated chain ID and bytecode reads. Results land in
`e2e/.results/` like any other run, and external consumers read each case's `id` and `status`.

### Deploying a stack for another workflow

`pnpm devnet:deploy -- --out <dir> --eligible-account <address>` is the supported entry point for
workflows outside this repository, such as the Zones txgen load and canary jobs, that need a fresh
Earn stack on an existing devnet without running E2E cases. It runs the same `deploy` and the same
pre-deployment checks as `pnpm e2e:devnet`, and changes the chains no further.

It reads the topology variables, `DEPLOYER_PRIVATE_KEY`, and `ZONE_ADMIN_PRIVATE_KEY` above. The
fixture stablecoin addresses derive from the deployer, so each run needs a deployer that has not
deployed a fixture on that L1, such as a key derived per workflow run; the deployer also administers
the stack's TIP-403 whitelist. `--eligible-account` is the one account the caller drives: it joins
that whitelist and receives the revenue share, and when the Portal enforces access it must already
hold the `Account` role. A relative `--out` resolves from the directory the command starts in. The
checkout needs what a local run needs ([development](../development.md)).

After deploying, it writes one file per value to `--out`, each holding the bare value without a
trailing newline:

| File                   | Value                                                 |
| ---------------------- | ----------------------------------------------------- |
| `earn-input-token`     | the router's private input stablecoin                 |
| `earn-funding-helper`  | the `DemoStablecoinFunder` that mints the input token |
| `earn-token`           | the EarnShare                                         |
| `earn-vault`           | the EarnVault                                         |
| `earn-router`          | the Zone router                                       |
| `earn-source-revision` | the Earn commit that deployed the stack               |

`e2e/harness/workflows-contract.test.ts` pins both entry points, the `zone` group, these files, and
the run result's case `id` and `status`. Changing them, or the inputs above, is a breaking change for
those workflows.

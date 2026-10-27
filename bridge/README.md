# Tempo's Bridge integration

Bridge/Stripe Issuing card spend on Tempo, from balances cardholders keep in their own accounts:
public or private (in a Zone), in stablecoin or in Tempo Earn shares, built on Bridge's existing
card contracts.

This is a separate Foundry project beside [Earn](../earn/README.md) and the
[Zone router](../zone-router/README.md). It has its own build settings and dependencies, and imports
Earn from [`earn/src/`](../earn/src/) and the Zone router from
[`zone-router/src/`](../zone-router/src/) rather than copies. Neither of their builds compiles it
([`AGENTS.md`](AGENTS.md)).

## What is here

- **Bridge's card contracts as they are today.** `SpenderFactory`, its per-program clones and the
  EA (ERC-20), P2 (Permit2) and TF handlers, plus the EV handler from Bridge's unmerged PR #14,
  vendored with only import paths changed ([`vendor/VENDORED.md`](vendor/VENDORED.md)). They are
  the baseline.
- **One Tempo contract inside Bridge's system.** `SpenderTempoSpend` ("TS"), a spender handler
  Bridge registers like any other. Private spends reach it through the Zone router's
  [`BridgeSettler`](../zone-router/src/settlers/BridgeSettler.sol), which lives with the other
  settlers in `zone-router/`. See [`docs/bridge/design.md`](../docs/bridge/design.md).
- **A card E2E harness** that runs every Stripe/Bridge card scenario against any contract setup,
  so Bridge today and the Tempo handler are tested side by side. See
  [`docs/bridge/harness.md`](../docs/bridge/harness.md).
- **Bridge's deploy scripts**: the handler, a program's settler and Spend-mode router for E2E and
  local use, the role-gated factory calls, and a preflight.

## How it works

- Bridge spends from the cardholder's account with a Tempo access key the cardholder authorized,
  publicly and in a Zone. Public and private spend are the same `Spend`, settled by the same
  handler code in the program's Bridge clone.
- Public: one transaction from the cardholder's account approves the exact amount to the clone,
  calls `publicCall "PS"` and clears the approval.
- Private: Bridge's Zone key withdraws to the Zone's `ZoneRouter`, which transfers the
  cardholder's `maxInput` to the program's `BridgeSettler`. The settler settles the spend through
  the clone and hands back what it did not use, and the router returns the change to the Zone, so
  the settlement names no cardholder. Bridge approves the card on the Zone receipt, and the platform
  reserve covers a settlement that fails after approval.
- A spend pays from stablecoin, Earn shares, or both, and settles in the stablecoin the funds
  are held in. Bridge accepts any stablecoin, so nothing is converted.
- Bridge's factory governs everything: settlement destinations, pause and the vault allowlist.
  There are no new admin keys.

## Results

484 tests pass. The card matrix runs 35 scenarios against 11 setups, with no failures: 5 Bridge setups and 6 Tempo
setups. The full table is in [`docs/bridge/matrix.md`](../docs/bridge/matrix.md).

|                                                                    | Bridge (EA, P2, TF, and EV from PR #14) | TS, public | TS, private |
| ------------------------------------------------------------------ | --------------------------------------- | ---------- | ----------- |
| Purchases, tips, holds, incremental auth, fees, ATM, force capture | pass                                    | pass       | pass        |
| Refunds, disputes, declines, pause, reserve on failed pulls        | pass                                    | pass       | pass        |
| Spend from Earn shares                                             | TF, EV                                  | pass       | pass        |
| Share cost bounded against a quote                                 | no                                      | pass       | pass        |
| Periodic spend limit on chain                                      | no (lifetime allowance)                 | pass       | pass        |
| No standing allowance                                              | no                                      | pass       | pass        |
| Settlement names no cardholder                                     | n/a                                     | n/a        | pass        |

Three behaviors are decisions, not defects, and the matrix lists them so they stay visible:

- Bridge dedupes retried spends off chain.
- Refunds arrive as stablecoin, as Bridge returns funds today.
- A leaked Zone key can withdraw outside the program. Bridge accepts this risk.

## Running it

```bash
git clone https://github.com/tempoxyz/earn.git
cd earn
scripts/solidity-deps.sh bridge   # Solidity dependencies at the revisions bridge/foundry.lock pins
cd bridge
FOUNDRY_PROFILE=ci forge test
```

Requires Foundry v1.8.5 or later, which runs Tempo's precompiles natively (`hardfork = "tempo:T8"`)
and knows the hardforks live Tempo chains run.

**On a real Tempo node.** `script/smoke.sh` starts a dev node in Docker, deploys everything and
runs real transactions:

- a Bridge EA pull;
- TS spends from Earn, and split across stablecoin and Earn;
- an access-key batch spend;
- the deployment scripts: a replacement handler registered with the program's gated status kept,
  the program allowlisted again, then a spend through it;
- the calls a leaked access key must fail, each with its exact error: paying outside the program,
  transferring out, spending after governance takes the program off the gated handler's allowlist,
  exceeding its limit;
- the private path's `BridgeSettler` and Spend-mode router deployed through a `ZoneRouterFactory`,
  with the router taking callbacks only from the Zone messenger.

Every balance it reports is read back from the node after the transactions land.

```bash
script/smoke.sh
```

**On a real Tempo L1 and Zone.** [`e2e/bridge`](../e2e/bridge/) runs a private spend end to end
against a target: `local`, a disposable L1 and Zone from the images Earn's
[localnet](../localnet/fixtures/) pins (in CI), or `moderato`, Tempo's testnet and its hosted Zone 3.
It checks that:

- the deploy path matches production, `TS` gated with the program allowlisted, and the preflight
  reports no `todo` (local only);
- the settlement wallet is paid;
- no log in the settlement transaction names the cardholder;
- the private balance falls by exactly the spend and fees;
- a spend outside the program bounces back into the Zone in full, confirmed by the portal's
  `WithdrawalProcessed`;
- a Zone token's `transfer` reverts with `Unauthorized()`;
- a leaked Zone key can withdraw outside the program (local only);
- a spend from Earn shares in the Zone redeems exactly the spend, within Bridge's share quote, and
  returns the unused shares (Moderato, against Tempo Earn's e2e-moderato vault on Zone 3; locally
  with `--earn`, which deploys that profile on the disposable chain, as CI does).

It also logs the gas the router callback used, read from a trace of the settlement transaction
(local only), and times the card-approval path: Zone request to Zone receipt, Zone receipt to L1
settlement, and a public spend's one L1 transaction, sent with a Bridge access key
(`reports/zone-e2e-latency-<target>.json`).

Requires Node 22 and pnpm, plus Docker for `local`.

```bash
forge build
pnpm e2e:bridge             # from the repository root
pnpm e2e:bridge -- --earn   # also the Earn spend steps, against a local e2e-moderato stack
```

Moderato uses the test program recorded in `e2e/bridge/targets/moderato.json` and reads
`TEMPO_API_KEY` and an admitted `CARDHOLDER_PRIVATE_KEY` from `e2e/bridge/.env.moderato` (see
`.env.example`). `--deploy` also needs `DEPLOYER_PRIVATE_KEY`, a test-only key that deploys a new
test program and records it in `targets/moderato.json`. A run also needs it when the record has no
settler and router, which it then deploys and records, and to allow the Earn vault for the program.
Zone 3 enforces account admission and a closed callback gateway. A plain run never changes its
Portal: if the router, cardholder, program wallet or refund recipient lacks a role, the private
steps report `BLOCKED` with the call to make and the run exits with code 3 after the public steps.
`--admit` makes those grants with `ZONE_ADMIN_PRIVATE_KEY`, which must be the Portal admin or the
sole owner of the threshold-1 Safe that is, as in Tempo Earn's deployment tooling.

```bash
pnpm --filter e2e bridge:moderato   # --deploy re-records the program, --admit grants roles
```

## Layout

```text
src/
  SpenderTempoSpend.sol     "TS" handler: public and private spend, stablecoin and Earn
  interfaces/               Bridge factory and clone, Earn vault, Zone outbox
test/
  harness/                  Tempo, Earn, Bridge and Zone world, access keys, card program model
  rails/                    One adapter per contract setup
  e2e/                      Card scenarios and the setup matrix
  unit/                     Contract and security tests, including BridgeSettler against Bridge's factory
  fork/                     Private-spend callback gas on a Tempo mainnet fork (inert without one)
  smoke/                    A check that the harness world deploys
script/                     Deploy scripts, real-node smoke test, Zone E2E deploy, matrix generator
vendor/                     Pinned Bridge and Zones sources (VENDORED.md)
```

`BridgeSettler` and the `Spend` struct are in [`zone-router/src/settlers/`](../zone-router/src/settlers/);
Earn comes from `../earn/src`.

## Documents

- [`docs/bridge/design.md`](../docs/bridge/design.md): the design, flows, security model and decisions.
- [`docs/zone-router/zone-router.md`](../docs/zone-router/zone-router.md): the [Zone router](../zone-router/README.md)
  private spends go through, and its `BridgeSettler`.
- [`docs/bridge/deploy.md`](../docs/bridge/deploy.md): deploying into Bridge's factory, and the calls
  each role submits. The handler lands at a deterministic address, so Bridge running the deploy
  scripts and Tempo's Bridge Release workflow ([`bridge-release.yml`](../.github/workflows/bridge-release.yml))
  deploy the same contract; a program's `BridgeSettler` comes from Zone Router Release.
- [`docs/bridge/audit-scope.md`](../docs/bridge/audit-scope.md): what an audit covers, the invariants to check and where to look hardest.
- [`docs/bridge/bridge-integration.md`](../docs/bridge/bridge-integration.md): how Bridge's card backend uses the contracts: enrollment, authorization, settlement tracking, refunds and retries.
- [`docs/bridge/harness.md`](../docs/bridge/harness.md): what is real and what is modeled, and how to extend it.
- [`docs/bridge/scenarios.md`](../docs/bridge/scenarios.md): every card scenario and what it asserts.
- [`docs/bridge/bridge-today.md`](../docs/bridge/bridge-today.md): how Bridge moves card money on Tempo today.
- [`docs/bridge/matrix.md`](../docs/bridge/matrix.md): generated scenario × setup results.

# Latency benchmarks

The [user-perceived benchmark](#user-perceived-latency) measures Earn latency against a deployed
profile, reusing the [E2E](e2e-environments.md) harness and actions: it times deposit and redeem
round trips until the result is observable to the user, public and private. Zone exit latency, from
Zone submission to the L1 `processWithdrawals` block, is measured in
[tempoxyz/integrations](https://integrations.tempoxyz.net).

It writes JSON under `e2e/.results/`. Its workflow runs only from `main` (a dispatch from another
branch skips the job, so it never receives a credential), keeps the JSON artifact for 90 days, and
shows a summary table on the run page.

## User-perceived latency

```bash
pnpm e2e:benchmark -- --earn-file profiles/<profile-id>/profile.json --group public --samples 10

export TEMPO_API_KEY=...   # Zone access for the profile's Zone; private and all only
pnpm e2e:benchmark -- --earn-file profiles/<profile-id>/profile.json --group all --samples 10
```

| `--group`       | Measurements                                                       |
| --------------- | ------------------------------------------------------------------ |
| `public`        | direct EarnVault deposit and redeem                                |
| `private`       | private Zone deposit into Earn and private redemption back to Zone |
| `all` (default) | both, in each sample                                               |

`--samples` is 1 to 20 (default 10). Benchmark groups are separate from E2E case groups: the
`public` and `zone` E2E modules each register one group's round trip as their `benchmark`, and the
`access` module registers the eligibility check that runs before any sample.

The runner resolves every contract from the profile's record and live reads; private and all use
its Zone route over the same EarnVault. It always signs as the committed public test identity from
`.env.example`, funded through the faucet, so it runs only on a network with a faucet (Moderato);
that identity must stay eligible under a protected profile's policy and admitted on an
access-enforced Zone. It needs no deployment, Zone administrator, access administrator, or end-user
key. Because that key is public, anyone can transact as the account, so a sample can fail or record
noisy latency; this is accepted for a testnet measurement holding no value. A private sample fails
fast, before any timer starts, when the Zone RPC is inaccessible, required tokens are disabled,
settlement is stale, or the withdrawal queue is not progressing.

### Measurement boundary

Each timer begins immediately before the user action and stops when its result is observable to
that user. Faucet funding, synthetic asset funding, private fee funding, access-policy validation,
and Zone readiness checks complete before the timer starts. Private measurements include the full
user action through Zone settlement, not only the public router transaction.

| Measurement                        | Completion signal                                         |
| ---------------------------------- | --------------------------------------------------------- |
| public deposit (`public-deposit`)  | confirmed atomic approval plus Earn deposit receipt       |
| public redeem (`public-redeem`)    | confirmed Earn redeem receipt                             |
| private deposit (`zone-deposit`)   | returned private EarnShare balance is observable in Zone  |
| private redemption (`zone-redeem`) | returned private stablecoin balance is observable in Zone |

### Phases

Each measurement also records the phases its shared actions observed, so a Zone round trip splits
into the leg a user waits on and the legs that follow:

| Flow                              | Phase                         | Clock | Ends when                                         |
| --------------------------------- | ----------------------------- | ----- | ------------------------------------------------- |
| `zone-deposit`, `zone-redeem`     | `zone-submit-to-receipt`      | wall  | the Zone withdrawal transaction's receipt returns |
| `zone-deposit`, `zone-redeem`     | `zone-receipt-to-l1-callback` | chain | the L1 block that ran the router callback         |
| `zone-deposit`, `zone-redeem`     | `submit-to-zone-credit`       | wall  | the returned balance is observable in the Zone    |
| `public-deposit`, `public-redeem` | `submit-to-receipt`           | wall  | the receipt poll finds the L1 transaction         |

A `wall` phase runs on the harness's monotonic clock, so one that ends on a poll is quantized to the
polling interval. The `chain` phase is the difference between the Zone block's and the L1 block's
`timestampMillis`, independent of polling, and is dropped when either block read fails. Every E2E
run records the same phases for the cases that use these actions (`timings` on each case result).

### Output

The runner prints each measurement with its `TIMING` phases, then p50 and p95 per flow and phase.
The JSON (`*-benchmark-<engine>-<profile-id>.json`) holds `measurements` (every sample, with its
`phases` and any failure) and `summary` (per flow: samples, minimum, p50, p95, and maximum, with the
same statistics for each phase). Dashboard ingestion should read `summary` for aggregates and
`measurements` for samples, and keep `generatedAt`, `source.commit`, `deployment.id`,
`deployment.manifestSha256` (the SHA-256 of the profile's `deployment.json`), `engine`,
`environment.chainId`, `environment.zoneId`, `groupRequested`, and `samplesRequested`, so
infrastructure changes are distinguishable from latency changes. A non-null top-level `failure`
means the run stopped before completing every requested sample.

### CI

The `Earn E2E Benchmarks` workflow (`e2e-benchmarks.yml`) runs daily at 06:17 UTC against the
disposable [`e2e-moderato`](../../profiles/e2e-moderato/profile.json) Zone 3 stack with every
group and 10 samples. A manual dispatch may choose the profile, group, and sample count. Public runs
receive no secrets; private and all runs receive only `TEMPO_API_KEY`, which authenticates Tempo
API's Zone RPC. Runs share the `hosted-contracts-moderato` concurrency group, which queues rather
than replaces pending runs.

```bash
gh workflow run e2e-benchmarks.yml --repo tempoxyz/contracts --ref main -f group=all -f samples=10
gh run list --repo tempoxyz/contracts --workflow e2e-benchmarks.yml --limit 1
gh run download <run-id> --repo tempoxyz/contracts --name earn-e2e-benchmarks-<environment>-<group>-<run-id>
```

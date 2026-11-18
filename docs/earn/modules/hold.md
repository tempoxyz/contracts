# Hold engine

`HoldEngine` is a venue-less engine: it holds its EarnVault's base asset 1:1 and earns nothing on its
own. One engine share is one raw unit of the base asset, so `valueOf(s) == s`, and with no rewards one
EarnShare stays worth one unit of the base asset. The only thing that raises the EarnShare price is a
contribution: backing that arrives without new EarnShare supply.

Use it when an operator funds yield from its own balance sheet, for example paying a benchmark rate
such as SOFR plus a spread on stablecoin balances, and wants every holder, including private Zone
holders, to receive it without per-account claims.

Contract: [`HoldEngine.sol`](../../../earn/src/engines/hold/HoldEngine.sol). Tests:
[`HoldEngine.t.sol`](../../../earn/test/engines/hold/HoldEngine.t.sol).

## Accounting

| Read             | Value                                                                  |
| ---------------- | ---------------------------------------------------------------------- |
| `totalShares()`  | The base asset the engine holds, including unrecorded direct transfers |
| `totalAssets()`  | Same as `totalShares()`                                                |
| `valueOf(s)`     | `s`                                                                    |
| `deposit(a)`     | Pulls `a` from the EarnVault and returns `a` engine shares             |
| `redeem(s, …)`   | Pays `s` to the receiver                                               |
| `withdraw(a, …)` | Pays exactly `a` and burns `a` engine shares                           |

Every fund flow measures the engine's balance change and reverts with `InexactTransfer` unless it
matches, so the EarnVault's engine-share ledger moves with the holding. There is no venue, oracle,
pause, queue or expiring valuation; the engine advertises `IEarnEngine`, `IEarnEngineRedeem` and
`IEarnEngineExactWithdraw`, and not fee valuation.

The owner binds the engine once to an EarnVault with the same asset
(`initializeEarnVault(vault)` or `initializeEarnVault(vault, finalOwner)`). After binding only the
EarnVault can move funds.

## Funding yield

The funder approves the EarnVault and calls `EarnVault.contribute(assets)`. The EarnVault deposits
the assets into the engine and records them as backing without minting EarnShare, so every current
holder's EarnShare rises pro rata. Later entrants buy in at the raised price.

Never fund by plain transfer:

- base asset sent to the EarnVault creates no engine shares, cannot be absorbed and stays stranded,
  since no EarnVault or engine function moves it; and
- base asset sent to the engine is quarantined surplus that `absorbEngineShareSurplus` recognizes,
  but that function is permissionless, so anyone can deposit just before absorbing it, then redeem,
  and capture most of it.

### Limits on contributions

`contribute` reverts, and the pool earns nothing, when any of these holds:

- deposits are paused (`DepositsPaused`);
- the contribution would take `totalAssets` above a nonzero `maxManagedAssets`. Any depositor
  can fill the remaining capacity, so leave the cap at zero or keep it well above expected balances
  plus a year of yield;
- the pool has no EarnShare supply (`NoEarnShares`); or
- the EarnShare price would exceed 100× the reward-rate baseline (`RewardRateLimitExceeded`). The
  baseline is the price when the pool last emptied (or the engine was migrated), and the limit is
  cumulative, not per contribution. A benchmark-rate program takes centuries to reach it, but on a
  new or dust-sized pool anyone can spend the whole headroom, for example with `deposit(1)` then
  `contribute(99)`, and keep one unit to stop the baseline resetting.

So seed every pool with a meaningful operator-held first deposit before it is opened, keep that
seed in for the life of the pool, and use a protected EarnShare so only eligible accounts can hold
it. If the headroom is spent anyway, migrating to a fresh engine starts a new baseline.

### Fees

Fees accrue on any rise in value per EarnShare, contributions included. For holders to receive the
full funded rate, set the fixed fees to zero and leave the excess-return fee disabled: an enabled
excess-return fee charges contribution growth above its target rate.

### Timing

Contributions are paid on the holdings at the moment they land, and the engine redeems 1:1 at once,
so the funder must not pay for time nobody held. The example below pays each interval only on the
smaller of the pool's assets at the interval's start and at its end, so a deposit made just before a
top-up earns nothing for that interval, and time the pool sat empty is never paid. Contribute often
(every few minutes) so each step is small.

### Example top-up loop

The funder computes the contribution offchain and pushes it. This example targets an annual rate in
basis points on the EarnVault's assets:

```ts
import { erc20Abi } from 'viem'
import { earnVaultAbi } from '@tempoxyz/contracts/abis'

const YEAR = 365n * 24n * 60n * 60n

// state = { lastTopUp, lastAssets }, persisted between runs.
async function topUp({ client, wallet, vault, asset, rateBps, state }) {
  const now = BigInt(Math.floor(Date.now() / 1000))
  const assets = await client.readContract({
    address: vault,
    abi: earnVaultAbi,
    functionName: 'totalAssets',
  })
  const held = assets < state.lastAssets ? assets : state.lastAssets
  const amount = (held * rateBps * (now - state.lastTopUp)) / (10_000n * YEAR)
  if (amount > 0n) {
    const approval = await wallet.writeContract({
      address: asset,
      abi: erc20Abi,
      functionName: 'approve',
      args: [vault, amount],
    })
    await client.waitForTransactionReceipt({ hash: approval })
    const hash = await wallet.writeContract({
      address: vault,
      abi: earnVaultAbi,
      functionName: 'contribute',
      args: [amount],
    })
    const receipt = await client.waitForTransactionReceipt({ hash })
    if (receipt.status !== 'success') throw new Error(`contribute reverted: ${hash}`)
  }
  const after = await client.readContract({
    address: vault,
    abi: earnVaultAbi,
    functionName: 'totalAssets',
  })
  return { lastTopUp: now, lastAssets: after }
}
```

Run it on a schedule (for example every five minutes) and update `rateBps` when the benchmark moves.
Persist the returned state only after the call resolves: a failed or dropped contribution throws,
so the next run retries the same interval instead of skipping it. Start with
`lastAssets = 0n`, so the first interval pays nothing.

## Deployment

The engine has no factory. Deploy it unbound with the base asset, a setup owner, a name and a
symbol; deploy the EarnVault with it as an existing engine (`EarnFactory.deploy` rejects an engine
that is already bound); then the setup owner calls `initializeEarnVault(earnVault, finalOwner)`.
Seed the pool before opening it (see [Limits on contributions](#limits-on-contributions)). Registry,
localnet and E2E support for a venue-less kind is not wired yet.

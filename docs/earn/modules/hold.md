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

A plain transfer to the EarnVault or the engine does **not** raise the price: the EarnVault
quarantines unrecorded engine shares until an operator calls `absorbEngineShareSurplus`.

Each contribution is bounded by the EarnVault's reward-rate limit (`RewardRateLimitExceeded` above
100× the reward-rate baseline), far above any benchmark-rate program.

Contributions are paid on the holdings at the moment they land, so someone who enters just before a
contribution and exits just after captures that period's yield on their deposit. Contribute often
(every few minutes) so each step is negligible, and use a protected EarnShare where only eligible
accounts may hold it.

Set the deployment's fixed fees to zero if holders should receive the full rate: fees accrue on any
rise in value per EarnShare, contributions included.

### Example top-up loop

The funder computes the contribution offchain and pushes it. This example targets an annual rate in
basis points on the EarnVault's assets:

```ts
import { erc20Abi, earnVaultAbi } from "@tempoxyz/contracts";

const YEAR = 365n * 24n * 60n * 60n;

async function topUp({ client, wallet, vault, asset, rateBps, lastTopUp }) {
  const now = BigInt(Math.floor(Date.now() / 1000));
  const assets = await client.readContract({
    address: vault,
    abi: earnVaultAbi,
    functionName: "totalAssets",
  });
  const amount = (assets * rateBps * (now - lastTopUp)) / (10_000n * YEAR);
  if (amount === 0n) return lastTopUp;
  await wallet.writeContract({
    address: asset,
    abi: erc20Abi,
    functionName: "approve",
    args: [vault, amount],
  });
  await wallet.writeContract({
    address: vault,
    abi: earnVaultAbi,
    functionName: "contribute",
    args: [amount],
  });
  return now;
}
```

Run it on a schedule (for example every five minutes) and update `rateBps` when the benchmark moves.
Persist `lastTopUp` so a restart neither skips nor double-pays a period.

## Deployment

The engine has no factory: deploy it with the base asset, an owner, a name and a symbol, bind it to an
EarnVault, and deploy the EarnVault with the engine as an existing engine. Registry, localnet and E2E
support for a venue-less kind is not wired yet.

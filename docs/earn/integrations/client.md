# Client integration

This page is for developers building a wallet, backend, or contract that deposits into and exits a
Tempo Earn deployment. An application integrates two contracts: the `EarnVault`, which executes
deposits and exits, and EarnShare, the non-rebasing TIP-20 it mints and burns. The vault's backing
sits in a replaceable engine contract that integrates one venue; the
[engine table](engines.md#yield-engines) lists the kinds. The EarnVault and EarnShare addresses
survive engine changes, so they are the integration surface. See
[system architecture](../architecture/system.md) for the layout and the [glossary](../glossary.md)
for terms.

Examples use viem's `viem/tempo` Earn actions, call builders, and ABIs. They are written against
the viem build pinned in [`pnpm-workspace.yaml`](../../../pnpm-workspace.yaml); the actions, parameters,
and return shapes used here are the same in released viem 2.55.10 and later, except where noted.

## Read the deployment

Every address the integration needs comes from the EarnVault:

| Read                    | On        | Purpose                              |
| ----------------------- | --------- | ------------------------------------ |
| `asset()`               | EarnVault | Token to approve for a deposit       |
| `earnShare()`           | EarnVault | Token to approve for an exit         |
| `engine()`              | EarnVault | Approval target for in-kind deposits |
| `depositsPaused()`      | EarnVault | Whether the deposit path is open     |
| `isAccountingAligned()` | EarnVault | Whether supply matches its backing   |

Deposit is always available. Every other action is optional, and the engine advertises it through
ERC-165 `supportsInterface(bytes4)`:

| Action           | Interface                  | ID           | `getVault` capability |
| ---------------- | -------------------------- | ------------ | --------------------- |
| Immediate redeem | `IEarnEngineRedeem`        | `0x94a2d467` | `syncRedeem`          |
| Exact withdrawal | `IEarnEngineExactWithdraw` | `0x0adfb0b9` | `exactWithdraw`       |
| In-kind deposit  | `IEarnEngineInKindDeposit` | `0xce4790a9` | `inKindDeposit`       |
| Queued redeem    | `IEarnEngineAsyncRedeem`   | `0xa1a6a1d7` | `asyncRedeem`         |

`Actions.earn.getVault` performs these reads and returns the capabilities as booleans. It throws
`GetVaultEngineChangedError` if the engine changes between its reads. Later snippets reuse this
`client`, `account`, `earnVault`, and `vault`:

```ts
import { createClient, http } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { tempoModerato } from 'viem/chains'
import { Actions } from 'viem/tempo'

const account = privateKeyToAccount('0x...')
const client = createClient({ account, chain: tempoModerato, transport: http() })
const earnVault = '0x...'

const vault = await Actions.earn.getVault(client, { vault: earnVault })
// vault.assetToken, vault.shareToken, vault.engine.address, vault.depositsPaused,
// vault.isSynced (isAccountingAligned), vault.capabilities.{syncRedeem,exactWithdraw,inKindDeposit,asyncRedeem}
```

Verify the addresses against your deployment record before enabling writes. If the engine no longer
matches what you verified, pause writes and verify again. See
[deployment verification](../../deployment/deployment.md).

## Deposit

Amounts are base units of the respective token; the examples assume a 6-decimal asset. A deployment
may restrict EarnShare to TIP-403-eligible accounts. A deposit to an ineligible account then reverts
with the token's `PolicyForbids`.

`depositSync` batches the asset approval with the deposit, waits for the receipt, and decodes the
`Deposited` event into `{ assetAmount, caller, receipt, recipient, shareAmount }`:

```ts
const { shareAmount, receipt } = await Actions.earn.depositSync(client, {
  assetAmount: 100_000_000n,
  shareAmount: 99_900_000n, // quoted output; see “Positions and quotes”
  slippageBps: 50, // accept up to 0.5% under the quote
  vault: earnVault,
})
```

The deposit reverts rather than mint less than the floored quote. `recipient` defaults to the
signing account. `deposit` (without `Sync`) returns only the transaction hash. In viem 2.56.5 and
later, a `*Sync` action whose receipt is still `pending` returns only `{ receipt }`, so check
`receipt.status` before reading amounts.

In-kind entry (`depositVenueShares`) is `Actions.earn.depositShares`. It takes
`venueShareAmount`, the `venueShareToken` it approves, and `earnShareAmountMin` or
`earnShareAmount` plus `slippageBps`.

## Positions and quotes

`Actions.earn.getPosition` reads an account's asset and EarnShare balances, both allowances to the
EarnVault, and `value`, the position's current asset value from `previewRedeem`.

Exit quotes come from the vault, fees included. `previewRedeem(earnShares)` returns the assets paid
for a share input, and `previewWithdraw(assets)` returns the ceiling-rounded EarnShare cost of an
exact asset output. viem exposes them as `getRedeemQuote` and `getWithdrawQuote`. Each reverts with
`EngineCapabilityUnsupported` when the engine lacks that exit.

There is no EarnVault-level `previewDeposit`. Quote a deposit in two steps:

1. Get the engine shares the deposit mints from the venue:
   - **ERC-4626:** the venue's execution-aware `previewDeposit`.
   - **Veda:** mirror the yield-streaming Teller, which divides by the Accountant's safe rate plus
     one and deducts the asset's share premium.
   - **PropAMM:** quote the engine's own pool route.
2. Pass that amount to `convertEngineSharesToEarnShares` on the EarnVault.

Each engine's `quoteDeposit` in [`deployments/modules/engines/`](../../../deployments/modules/earn/engines/)
implements step 1 for its kind, and `quoteEarnDeposit` composes it with step 2.

## Redeem

Quote first, then redeem with a tolerance:

```ts
const quoted = await Actions.earn.getRedeemQuote(client, {
  shareAmount: 50_000_000n,
  vault: earnVault,
})

const { assetAmount } = await Actions.earn.redeemSync(client, {
  shareAmount: 50_000_000n,
  assetAmount: quoted, // floored by slippageBps
  slippageBps: 50,
  vault: earnVault,
})
```

`redeem` burns an exact EarnShare amount. `withdrawExact` pays an exact asset amount instead
(`Actions.earn.withdrawExact`, bounded by `shareAmountMax`). `requestRedeem` queues an exit on
engines that support it. viem has no action for `requestRedeem` or `cancelRedeem`, so encode them
with `Abis.earnVault`, as the [Veda queued request](../modules/veda.md#build-a-queued-request) does.
The [action reference](#action-reference) covers each exit.

## Approvals

Tempo transactions carry multiple calls natively, so submit the approval and the Earn action as one
transaction. The calls execute in order and revert together, so a failed action leaves no standing
allowance. If the wallet cannot batch, confirm the approval receipt before simulating the action,
and approve exact amounts.

| Action                                     | Token spent          | Approve   |
| ------------------------------------------ | -------------------- | --------- |
| `deposit`                                  | Base asset           | EarnVault |
| `depositVenueShares`                       | Engine's venue token | Engine    |
| `redeem`, `withdrawExact`, `requestRedeem` | EarnShare            | EarnVault |

The caller of the Earn action grants these approvals; the action's receiver never replaces it as
the source of funds or shares. For a contract-owned position, the application contract must grant
them: an end user's approval to that application does not authorize EarnVault to spend the
application's base assets or EarnShare. An asset allowance used for deposit does not cover a share
burn on exit. Use `earnShare()` to identify the token and approve EarnVault before calling `redeem`,
`withdrawExact`, or `requestRedeem`, bounding an exact withdrawal's allowance by its maximum
EarnShare spend; keep the approval and action in the same composed transaction where possible. See
the [agent integration guide](agent-guide.md#check-contract-owned-approvals-and-settlement) for
application-level validation.

In-kind deposits are the exception: the engine pulls the venue token directly from the caller, and
an engine migration changes that address. Read `engine()` when building the approval, not at
application start.

## Output bounds

Every write takes an explicit bound and reverts when it is missed: `deposit` and
`depositVenueShares` require a nonzero `minEarnShares`, `redeem` a nonzero `minAssets`,
`withdrawExact` a `maxEarnShares` input cap, and `cancelRedeem` a nonzero `minReceiverEarnShares`.
Derive the bound from a quote and a slippage tolerance, or take one supplied explicitly by your
caller.

A missed bound is a protective revert. Requote and ask the user to approve the new terms; a client
that widens the bound automatically converts that protection into a silent loss.

The viem actions accept the bound itself (`shareAmountMin`, `assetAmountMin`, `shareAmountMax`) or
a quote plus `slippageBps`. `redeem` and `withdrawExact` also accept `slippageBps` alone and read a
live quote. `withdrawExact`'s bound is a ceiling on input, so its quote is raised by the tolerance
rather than floored.

## Simulate before signing

For production writes, build the call batch once, simulate exactly that batch from the user's
account, and submit the same batch, so the signed transaction matches the simulation. Do not request
a signature for a transaction with a known failure.

viem's `simulateCalls` runs a stateful call batch through `eth_simulateV1` and returns per-call
results. The per-action `.simulate()` helpers cover only the single EarnVault call and assume the
allowance already exists, which is the wrong scope for a transaction that also contains an approval.
`Actions.simulate.simulateCalls` targets `tempo_simulateV1`, which the public Moderato RPC does not
serve.

```ts
import { BaseError, ContractFunctionRevertedError } from 'viem'
import { sendTransaction, simulateCalls, waitForTransactionReceipt } from 'viem/actions'
import { Actions } from 'viem/tempo'

/** Finds decoded custom-error data inside a nested viem error chain. */
function contractRevert(error: unknown) {
  if (!(error instanceof BaseError)) return undefined
  const cause = error.walk((candidate) => candidate instanceof ContractFunctionRevertedError)
  if (!(cause instanceof ContractFunctionRevertedError)) return undefined
  return { args: cause.data?.args, name: cause.data?.errorName, raw: cause.raw }
}

// The `.calls()` builders perform no reads: pass the token address and an explicit bound.
const calls = Actions.earn.deposit.calls({
  assetAmount: 100_000_000n,
  assetToken: vault.assetToken,
  shareAmountMin: 99_500_000n,
  recipient: account.address,
  vault: earnVault,
})

const simulation = await simulateCalls(client, {
  account: account.address,
  calls,
  // Moderato can reject validation-mode simulations above its block gas limit.
  validation: false,
})

const failure = simulation.results.find((result) => result.status === 'failure')
if (failure) {
  const revert = contractRevert(failure.error)
  if (revert?.name === 'MinimumEarnSharesNotMet')
    throw new Error('The deposit quote changed. Refresh it before retrying.', {
      cause: failure.error,
    })
  throw failure.error ?? new Error('Earn deposit simulation failed')
}

// Submit the batch that was simulated, not a rebuilt one.
const hash = await sendTransaction(client, { calls })
const receipt = await waitForTransactionReceipt(client, { hash })
if (receipt.status !== 'success') throw new Error(`Transaction ${hash} reverted`)
```

The high-level actions such as `Actions.earn.deposit` rebuild the batch from a fresh `asset()`
read, which is fine when nothing was simulated; after a simulation, submit the simulated `calls`
array unchanged. Submit once. If a hash may have reached the network, wait for its receipt rather
than resubmitting, and treat only a successful receipt as a completed action. Transactions with
expiring nonces all use nonce 0, so wait with `checkReplacement: false`; otherwise viem's
replacement check can return an earlier transaction's receipt.

## Decode reverts

A revert is a 4-byte selector followed by ABI-encoded arguments. Decode it against the EarnVault,
the current engine, the underlying venue, and the token ABIs. viem ships `Abis.earnVault`,
`Abis.erc4626Engine`, `Abis.vedaEngine`, and `Abis.tip20`; the PropAMM engine's ABI is
`propAMMEngineAbi` in [`deployments/abis/generated.ts`](../../../deployments/abis/generated.ts). A
selector that matches none of them is still a real failure: keep the raw bytes, surface a generic
error, and do not classify it as retryable.

In viem, walk the error chain for `ContractFunctionRevertedError` as the helper above does.
`data.errorName` and `data.args` are populated only when the supplied ABI contains the error;
otherwise only `raw` is available. Branch on the decoded name, never on `error.message`, and keep
the original error for logs.

| Response                  | Errors                                                                                                                      | Client behavior                                                                                        |
| ------------------------- | --------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| Fix the request           | `ZeroAmount`, `ZeroAddress`, `ZeroMinimumAssets`, `ZeroMinimumEarnShares`                                                   | Correct locally before requesting another signature.                                                   |
| Get fresh authorization   | `MinimumEarnSharesNotMet`, `MinimumAssetsNotMet`, `ExceedsMaxEarnShares`                                                    | Requote, recompute the bound, and have the user approve the new terms.                                 |
| Wait for availability     | `DepositsPaused`, `MaxManagedAssetsExceeded`, Veda `StaleAccountantRate`, PropAMM `InvalidOracle`                           | Surface the unavailable path. A `depositsPaused()` pre-check is optional; simulation is authoritative. |
| Offer another exit        | `EngineCapabilityUnsupported`, Veda `QueueUnavailable`, immediate venue-liquidity failures                                  | Fall back to another advertised immediate or queued path.                                              |
| Check access and approval | `TokenCallFailed`, `TokenCallFalse`, engine `TransferFailed`, token `PolicyForbids`                                         | Verify balance, approval target, token address, and TIP-403 eligibility.                               |
| Stop and investigate      | `ActiveSupplyWithoutBacking`, `ExcessiveConversionLoss`, `InsufficientOutput`, `ResidualBacking`, measured-delta mismatches | Do not retry unchanged. Follow the per-action notes below or escalate.                                 |

EarnVault reports a reverted token call as a bare `TokenCallFailed`, so an insufficient balance or
allowance on a transfer it makes surfaces under that name rather than as the token's own error.

## Action reference

The revert table above sets the client response; these notes add only action-specific meaning.

- `deposit(assets, receiver, minEarnShares)`: `ActiveSupplyWithoutBacking` means outstanding
  EarnShare has zero-valued backing; a user deposit must not recapitalize those holders, so recovery
  goes through the explicit contribution path. `MaxManagedAssetsExceeded(maximum, actual)` means the
  post-deposit engine value crosses the configured cap. `ExcessiveConversionLoss` rejects
  conversion-floor loss above one basis point; a larger amount can avoid coarse rounding. Veda's
  `StaleAccountantRate` and PropAMM's `InvalidOracle` block deposits, not exits, until a fresh
  report or price lands.
- `depositVenueShares(venueShares, receiver, minEarnShares)`: only `ERC4626Engine` advertises
  in-kind entry; its venue token is the ERC-4626 share exposed as `vault()` on the engine. Engine
  `NoVenueSharesReceived` or EarnVault `InsufficientOutput` means the wrong token, an ineffective
  transfer, or a mismatch between reported and measured custody.
- `redeem(earnShares, receiver, minAssets)`: deposit pauses and the managed-assets cap do not block
  exits. Engine `InsufficientAssetsReceived`, or PropAMM `InsufficientBacking`, is a missed output
  bound; a Veda immediate exit can also fail on a dry liquidity buffer. `UnexpectedVenueSharesBurned`
  is an invariant failure.
- `withdrawExact(assets, receiver, maxEarnShares)`: `ResidualBacking` blocks burning the last
  EarnShare while leaving backing behind; use `redeem` for a final exit. `UnexpectedAssetsReceived`
  and `UnexpectedVenueSharesBurned` mean incompatible token or venue behavior.
- `requestRedeem(earnShares, receiver, engineData)`: the EarnShare is burned when the request is
  created, so a successful receipt means the user holds a claim rather than a position; if the
  engine's request fails, the burn and approval roll back with it. `engineData` is interpreted by
  the engine; Veda's encoding, payout floor, and errors are in
  [Veda](../modules/veda.md#build-a-queued-request). The returned `requestId` (`bytes32`, also in
  the `RedeemRequested` event) identifies the claim.
- `cancelRedeem(requestId, minReceiverEarnShares)` remints EarnShare to the stored receiver at the
  active pool's current price, reverting with `MinimumEarnSharesNotMet` below the bound.
  `RequestNotOpen` means the request already finalized or cancelled, or the ID is wrong;
  `NotRequesterOrJanitor` means the caller may not cancel it.

## Track a queued redemption

A queued request is an onchain claim, not a pending transaction. Store the `requestId` and watch
the EarnVault for one of:

| Event             | Meaning                                                            |
| ----------------- | ------------------------------------------------------------------ |
| `RedeemFinalized` | The queue paid out; assets went to the stored receiver.            |
| `RedeemCancelled` | The request was cancelled; EarnShare was reminted to the receiver. |

Treat the events as the source of truth. The optional `IAsyncRedeemReceiver` callback on a contract
receiver is best-effort: a reverting callback is ignored and does not block settlement. Delay is
normal and is not a failed transaction. The requester or the configured janitor may cancel only
while the underlying queue claim is still open.

## Delegated self-recipient calls

To delegate automated deposits without allowing the signer to redirect EarnShare, use
`deposit(uint256,uint256)`, which fixes the receiver to `msg.sender`. A direct Tempo transaction
signed by an access key executes as the authorizing user account, so the user receives the shares.

[Tempo access-key scopes](https://github.com/tempoxyz/tempo/blob/main/tips/tip-1011.md) can restrict
contract addresses and function selectors. Their recipient constraints apply only to specific
TIP-20 transfer and approval methods, not to arbitrary EarnVault arguments. Setting `receiver` to
the user in a client call to the three-argument deposit does not enforce that restriction on the
key.

For a deposit-only key, authorize only the selected vault's `deposit(uint256,uint256)` selector. If
the key also creates the asset allowance, authorize the asset token's `approve(address,uint256)`
selector with its spender restricted to that vault. Do not grant the explicit-receiver deposit,
other vault operations, arbitrary token transfers, or unrestricted approvals. Configure key expiry
and token spending limits separately. The caller still chooses the amount, timing, and output
minimum; self-recipient scoping only fixes where the result goes.

The same option exists for `depositVenueShares(uint256,uint256)`, `redeem(uint256,uint256)`,
`withdrawExact(uint256,uint256)`, and `requestRedeem(uint256,bytes)`. Grant these only when the
integration needs them. Approval targets remain those in the [approval table](#approvals); in-kind
entry approves the current engine. Async finalization and cancellation use the receiver fixed at
request time.

viem's `Abis.earnVault` and call builders contain only the explicit-receiver overloads, so encode
the self-recipient calls with a minimal ABI rather than relying on an omitted `receiver` in an
existing helper:

```ts
import { encodeFunctionData, parseAbi } from 'viem'

const data = encodeFunctionData({
  abi: parseAbi([
    'function deposit(uint256 assets, uint256 minEarnShares) returns (uint256 earnShares)',
  ]),
  functionName: 'deposit',
  args: [assets, minEarnShares],
})
// Submit { to: earnVault, data } directly from the authorized user account.
```

For explicit-receiver async requests, prefer `requestRedeem(uint256,address,bytes)`, which orders
arguments as `(earnShares, receiver, engineData)` like the other entry and exit calls; the
`(earnShares, engineData, receiver)` overload in viem's ABI is equivalent. Both explicit-receiver
selectors allow redirection and must be excluded from self-recipient key scopes. Encode the
receiver-first overload with a minimal ABI.

Before provisioning keys, confirm that the deployment's EarnVault implementation includes the
self-recipient selectors, from its verified source or runtime code. The canonical sequences are in
[transaction flows](../architecture/flows.md#self-recipient-public-calls).

## Private Zone flows

A private deposit or redemption is a Zone withdrawal whose parent-chain callback runs the stack's
`SingleZoneEarnRouter`; a successful Zone transaction does not mean the Earn action succeeded. The
viem helpers, event correlation, router revert handling, and bounce-back behavior are in
[Tempo Zones](../modules/zone-router.md#client-integration).

## Validation in this repository

- **App:** [`app/src/public/Write.ts`](../../../app/src/public/Write.ts) implements this sequence.
  `prepare` revalidates the deployment, simulates the batch that the action's `calls` in
  [`app/src/earn/Actions.ts`](../../../app/src/earn/Actions.ts) builds, and `send` submits it
  unchanged. [`PublicActions.tsx`](../../../app/src/public/PublicActions.tsx) drives it, and
  [`app/src/Errors.ts`](../../../app/src/Errors.ts) decodes nested reverts.
- **Type check:** [`ClientExamples.test-d.ts`](../../../app/src/public/ClientExamples.test-d.ts) keeps
  this guide's viem calls, the [Veda request](../modules/veda.md#build-a-queued-request), and the
  [private Zone](../modules/zone-router.md#client-integration) examples compiling under
  `pnpm --filter app check:types`.
- **E2E:** `pnpm e2e:local -- --case public-bounds-roll-back` simulates an approval-plus-deposit
  batch, asserts that viem decodes the live `MinimumEarnSharesNotMet`, and confirms that a missed
  bound on deposit, in-kind entry, redemption, and exact withdrawal rolls back atomically.
  `pnpm e2e:local -- --case public-access-key-scopes` checks that self-recipient access-key scopes
  succeed only for their user and reject receiver redirection.

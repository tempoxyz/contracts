# Design

How Bridge/Stripe Issuing cards spend from balances a cardholder keeps on Tempo: in their own
account or privately in a Zone, in stablecoin or in Tempo Earn shares.

## Goal and constraints

- **The cardholder keeps custody.** Funds stay in the cardholder's account, or their Zone account,
  until a card spend pays a program destination. A Zone balance is also held by the Zone's
  operator, which can move or freeze it.
- **One experience, public and private.** A Zone account can only be spent from by a Tempo access
  key, so Tempo spend always uses access keys, and public spend works the same way.
- **Reuse Bridge.** Bridge's factory, clones, roles, destinations and pause govern Tempo spend.
  Bridge's backend submits spends the way it submits pulls today.
- **Card timing.** Bridge has about 2 seconds to answer an authorization, including its own
  processing. For a private spend Bridge approves on the Zone receipt, so a spend waits on one Zone
  request and never on the L1.
- **Minimal.** No signatures, nonces or on-chain bookkeeping that Bridge does not need today.

## The design

Two contracts, both on Tempo. Nothing is deployed inside a Zone.

### `SpenderTempoSpend` (the "TS" handler)

A Bridge spender handler, registered in Bridge's factory like EA or TF. It runs by delegatecall in
the program's clone. It has one public action, `publicCall "PS"`, which pays a `Spend` from the
caller:

```text
spenderId, token, amount, destination, vault, fromVault, maxShares, ref
```

- **Program and destination.** `spenderId` must be the ID `createSpender` deployed this clone for,
  which the handler checks against the clone's CREATE2 address, and `destination` one of its
  authorized destinations. A manager can register more IDs on an existing clone, each with its own
  destinations, and those cannot spend. So a clone migrated from another factory cannot use `TS`.
  Pause is checked by the clone.
- **Funding.** `amount - fromVault` is paid in `token`. `fromVault` is redeemed from an allowed Earn
  vault whose asset is `token`, burning at most `maxShares` (zero accepts the live price, but Bridge
  always sets it, since it also sizes the share approval or withdrawal). Unused
  shares go back to the payer.
- **Settlement token.** A spend settles in the stablecoin the funds are held in: an OUSD vault
  pays OUSD, a DLUSD balance pays DLUSD. Bridge accepts any stablecoin, so nothing is converted.
- **Reference.** `ref` is Bridge's own reference. It is emitted for reconciliation and never
  enforced.

The one governance action, `"UV"`, allows or disallows an Earn vault. A vault's `withdrawExact`
decides where redeemed value goes, so allowing one is as strong as adding a destination, and only
governance does either. `availableBalance` reports the
payer's balance of `token`, plus the value of its shares in an allowed vault that holds `token`.

Bridge's pull pipeline (`transferToDestination`) reverts. It needs a standing allowance and cannot
reach a Zone. Wallets that cannot use access keys stay on Bridge's EA and TF handlers.

### `ZoneSpendReceiver`

One per program and Zone, with no owner. Bridge's clone has no fallback, so it cannot receive a
Zone withdrawal callback itself. The receiver:

- accepts callbacks only from the Zone messenger, for its Zone and that Zone's canonical portal;
- approves the withdrawn input to the clone and calls `publicCall "PS"` with the `Spend` from the
  callback data, so the handler sees the receiver as the payer;
- checks the destination received exactly `amount`, so a replaced handler cannot look settled;
- returns unused input to the Zone as an encrypted deposit, which closed-loop Zones require, and
  reverts if the portal's deposit fee is above the `ZoneReturn`'s `maxDepositFee`;
- credits private refunds into the Zone as stablecoin (`refundPrivate`), paid by one of the
  program's destinations. Nobody else can call it, since the receiver may be a closed-loop Zone's
  callback gateway, and depositing through it would skip the Zone's admission.

Any revert bounces the input back into the Zone, and so does a callback in which the handler moved
nothing (`NothingSettled`). `refundPrivate` reverts while the factory is paused. `PrivateSpendSettled` carries the Zone's
`senderTag` (`keccak256(sender, txHash, fallbackNonce)`) and no cardholder address.

## Flows

### Public spend

```mermaid
sequenceDiagram
    participant S as Stripe Issuing
    participant B as Bridge
    participant A as Cardholder account
    participant C as Bridge clone (TS)
    participant D as Settlement wallet
    S->>B: authorize_and_transfer
    B->>A: Tempo tx signed by Bridge access key
    A->>C: approve(exact) + publicCall "PS" + approve(0)
    C->>D: stablecoin, Earn redemption, or both
    B-->>S: approved
```

### Private spend

```mermaid
sequenceDiagram
    participant B as Bridge
    participant Z as Cardholder (Zone)
    participant O as Zone outbox
    participant P as Zone portal (Tempo)
    participant R as ZoneSpendReceiver
    participant C as Bridge clone (TS)
    participant D as Settlement wallet
    B->>Z: Zone tx signed by Bridge Zone key
    Z->>O: approve + requestWithdrawal(to = receiver)
    Note over B: Bridge approves the card here
    O->>P: next batch
    P->>R: messenger callback
    R->>C: publicCall "PS"
    C->>D: pay amount
    R->>P: depositEncrypted(change)
    P-->>Z: change credited privately
```

Bridge approves the card once the Zone accepts the request. If the callback later reverts (pause,
a disabled handler, a removed destination, price move, illiquid venue), the input bounces back into
the Zone and the platform reserve pays the network. A callback that deposits anything back must
deposit at least the portal's deposit and bounce-back fees. A closed-loop Zone always requires a
return, and an Earn spend always returns its unused shares. So for either, Bridge withdraws the
input plus change of at least `depositFee + bouncebackFee + 1`, with a margin for fees that rise
before the batch, and the change returns to the cardholder net of the deposit fee.

### Latency

Bridge has about 2 seconds to answer an authorization, including its own processing. Neither path
waits on more than one block before Bridge can approve:

| Path                                    | What Bridge waits for                                    | Measured (`e2e/zone`)                              |
| --------------------------------------- | -------------------------------------------------------- | -------------------------------------------------- |
| Public                                  | One L1 transaction, submit to receipt                    | 461 to 508 ms (median 494, 5 runs)                 |
| Private                                 | The Zone transaction, request to receipt                 | 469 ms                                             |
| Private, after approval                 | Zone receipt to L1 settlement                            | 1,058 ms                                           |
| Public, Moderato                        | One L1 transaction over the public testnet RPC           | 400 to 1,070 ms (medians 455 and 502, 2 runs of 5) |
| Private, Moderato                       | Zone 3 transaction through Tempo API, request to receipt | 581 and 684 ms (2 runs)                            |
| Private, Moderato, after approval       | Zone receipt to L1 settlement                            | 1,483 and 1,677 ms (2 runs)                        |
| Private, mainnet Zone 2                 | Zone request to receipt                                  | 0.50 s p50, 0.77 s p90, 2.30 s max (100 runs)      |
| Private, mainnet Zone 2, after approval | Zone request to the L1 block that processes it           | 6.46 s p50, 6.83 s p90, 8.24 s max (100 runs)      |

The local rows use a local L1 and Zone with 500 ms blocks and no network distance. The Moderato rows
are the testnet and its hosted Zone 3, and the mainnet rows are Zone 2, timed on an Earn router
withdrawal, which takes the same Zone path as a spend. Most of the time after approval, 5.4 s at
p50, is the wait for Zone 2 to post its batch to the L1. Private settlement on the L1 is not on the
approval path: the reserve covers a callback that fails after approval.

### Callback gas

Bridge gives each private spend's callback 3M gas. The outbox allows up to 10M. Measured on a
mainnet fork against a production OUSD Earn vault and Zone 2, for a program's first spend to a
settlement wallet with no balance, which creates the most new storage:

- **Earn:** 2.02M, from $10 to $10,000. The amount moves it by under 100 gas.
- **DLUSD:** 0.98M.
- Both include returning unused input to the closed-loop Zone as an encrypted deposit.
- The callback data is 672 of the outbox's 1,024 bytes.

The withdrawal fee grows with the gas requested.

### Refunds

Refunds are stablecoin, as Bridge returns funds today:

- public refunds are a transfer from Bridge's program wallet to the cardholder;
- private refunds go through `refundPrivate`, paid by a program destination, and land in the Zone
  as an encrypted deposit.

## What a leaked key can do

| Key               | Scope                                                                        | What it can do                                                                                                                                                                                                                                                                                                                                                                                                         |
| ----------------- | ---------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Public access key | `approve` with the clone as recipient, and the clone's `publicCall`          | Pay program destinations, up to the key's periodic limit, through `PS`, the only `TS` action. This is the bound Bridge's debitor has today. The scope names `publicCall`, not a prefix, so the key also reaches the public actions of every other handler the program can use, such as a Tempo Earn handler's vault preference. None moves funds. Gating a handler closes this for every program not on its allowlist. |
| Zone access key   | `approve` with the outbox as recipient, and the outbox's `requestWithdrawal` | Withdraw up to its limit to any address in an open Zone, or to any admitted account in a closed-loop Zone. Accepted risk (decision 7).                                                                                                                                                                                                                                                                                 |

A withdrawal another Zone user sends to the receiver can only pay a program destination, from that
user's own funds.

## Decisions

1. Tempo spend is a Bridge handler, governed by Bridge's factory.
2. Access keys only, public and private. No standing-allowance pull path in `TS`.
3. No signatures and no on-chain action IDs. Bridge submits every spend and dedupes off chain.
4. Refunds are stablecoin: public to the wallet, private into the Zone.
5. A spend settles in the stablecoin it is funded from. Bridge accepts any stablecoin, so there is
   no conversion pool.
6. One receiver per program and Zone, with no owner.
7. The Zone key is scoped to the outbox, and its leaked-key risk is accepted.
8. Private spend settles on the L1, not inside the Zone. A Zone token's `transfer` reverts with
   `Unauthorized()`, while `approve` and the outbox work, so a Zone cannot pay Bridge directly and
   funds leave it only by withdrawal. Tempo disables Zone transfers only during the initial
   permissioned phase.
9. Bridge uses one access key per program, shared by its cardholders, so a leaked key reaches every
   cardholder of that program up to each one's limit.
10. Bridge sponsors every spend's gas as fee payer, on the L1 and in the Zone. A sponsored Zone
    request also has the outbox take its withdrawal fee from the fee payer, in the input token. The
    portal's deposit fee comes out of the change.
11. Each program's `refundRecipient` is a dedicated Bridge-controlled account, admitted on the Zone.
12. `TS` pays only for the ID a clone was created for, so a manager cannot add destinations to a
    live program by registering a second ID on its clone. Only governance allows Earn vaults, for
    the same reason.
13. Only a program destination can pay a private refund. Bridge's program wallet is one of them.
14. A spend from Earn settles in the vault's asset.
15. A private spend uses one balance: Earn shares if they cover it, otherwise stablecoin, otherwise
    Bridge declines. One authorization is one withdrawal.
16. The receiver checks the destination was paid and caps the portal's deposit fee, so neither a
    replaced handler nor a raised Zone fee can take a spend's value while it looks settled.

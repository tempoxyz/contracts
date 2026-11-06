# Deploying

The card integration deploys into Bridge's existing `SpenderFactory`: the "TS" handler, and for
each program its `CardSpender` with its `BridgeProvider`, deployed by a shared `CardFactory`, and the
program's Zone router. None has an owner, and a program has no pause of its own. The
handler, the `CardFactory` and each `BridgeProvider` land at deterministic release addresses, and a
program at the `CardFactory`'s CREATE2 address for its `spenderId` and provider, so Bridge
can deploy them with the scripts below or Tempo with the [Bridge Release workflow](#deploying-from-ci),
and either lands on the same contracts. Every factory change is a role-gated call, so the scripts
write those calls as calldata for the multisig that holds each role, instead of sending them.

Against a live chain, set the chain's current hardfork (`tempo_forkSchedule`) in
`FOUNDRY_HARDFORK`, for example `FOUNDRY_HARDFORK=tempo:T12`. The repo's tests pin `tempo:T8`, and forge cannot run the Zone factory
under it. The router deploy and
the preflight both read the Zone factory.

## 1. Deploy the handler (once)

```bash
FACTORY=0x... OUT=reports/tempo-spend.json \
  forge script script/bridge/deploy/DeployTempoSpend.s.sol --rpc-url $TEMPO_RPC --broadcast --account deployer
```

The script creates the handler through the CREATE2 deployer
(`0x4e59b44847b379578588920cA78FbF26c0B4956C`) with the salt of Earn's
[shared factory releases](../../deployment/deployment.md#shared-factory-releases)
([`BridgeRelease`](../../../cards/script/bridge/deploy/BridgeRelease.sol)), so the same build for the same
factory lands at the same address whoever deploys it. A handler already at that address is reused
and nothing is sent. The address follows this repository's build of `cards/`: a change to the
handler's source, including the `Spend` struct in `interfaces/IBridgeSpender.sol`, the compiler settings
or the project's remappings moves it.

The deploy scripts sign with forge's `--account` or `--ledger`. `DEPLOYER_PK` also works, for test
networks, and takes precedence over both when set. `OUT` is written only with `--broadcast`, but
forge writes it while running the script, before the deployment confirms. Check that `handler` has
code before submitting its calls. It holds the handler address, whether this run `created` it,
whether the factory's `"TS"` handler is already this one (`registered`), the prefix's `status`
before the deploy, and two calls to the factory:

| Field                   | Submitted by     | Call                                      |
| ----------------------- | ---------------- | ----------------------------------------- |
| `adminRegisterHandler`  | Admin (timelock) | `setSpenderHandler("TS", handler)`        |
| `governanceGateHandler` | Governance       | `updateSpenderHandlerStatus("TS", Gated)` |

A gated handler only runs for programs governance allowlists, so programs can be turned on one at
a time. Governance can later switch the status to `Enabled` for every program, or `Disabled` to
stop it.

Run the same script to replace a live handler with a new build; for an unchanged build it reuses
the existing handler, and once that one is registered the admin call changes nothing. The factory keeps the prefix's status across
`setSpenderHandler`, so `governanceGateHandler` is written only for a first registration while
`status` is `Disabled`. Otherwise it is empty (`0x`) and only the admin call is needed:

- on a replacement, a gate call would cut off every program that relies on `Enabled`;
- if `status` is `Enabled` before a first registration, the handler runs for every program once
  registered;
- if `status` is `Disabled`, a replacement stays off until governance changes it.

## 2. Deploy the program (once per program)

The program's clone exists already: Bridge's manager created it with `createSpender(spenderId,
destinations)`, with the settlement wallet as a destination.

```bash
FACTORY=0x... SPENDER_ID=0x... OUT=reports/bridge-program.json \
  forge script script/bridge/deploy/DeployBridgeProgram.s.sol --rpc-url $TEMPO_RPC --broadcast --account deployer
```

The script checks that the program's clone was created for its ID. It creates `CardFactory` and the
program's `BridgeProvider(factory, spenderId)` through the CREATE2 deployer with the release salt, as
the handler, reusing either one already there, then calls `cardFactory.deploy(spenderId, provider)`,
which returns the program if it exists. Only the factory's own pause stops the program. A program's
provider never changes, so a new provider contract means a new program. `OUT` holds `factory`,
`spenderId`, `clone`, `cardFactory`, `provider`, `program` and whether this run `created` the
program, and is written only with `--broadcast`. The program needs no factory call: the cardholders'
access keys and the Zone's router name it.

## 3. Turn it on for a program

`TS` must be registered, that is the admin's `setSpenderHandler` has executed.

```bash
FACTORY=0x... SPENDER_ID=0x... VAULTS=0xVault1,0xVault2 OUT=reports/program.json \
  forge script script/bridge/deploy/ProgramCalls.s.sol --rpc-url $TEMPO_RPC
```

Nothing is sent. The script refuses a spender ID that was added to an existing clone, which `TS`
rejects, and a vault whose engine lacks exact withdrawals, which every Earn spend makes, or redeem
previews, which `availableBalance` uses. Submit the calls in this order:

| Field                        | Submitted by | Call                                                           |
| ---------------------------- | ------------ | -------------------------------------------------------------- |
| `governanceAllowlistProgram` | Governance   | `updateSpenderHandlerAllowlist("TS", spenderId, true)`         |
| `governanceAllowVaults[]`    | Governance   | `governorCall(spenderId, "TS" "UV" 0x01 vault)`, one per vault |

The allowlist call goes first: while the handler is gated, the factory refuses the program's vault
calls until it is allowlisted. Leave `VAULTS` unset for a stablecoin-only program.

## 4. Deploy the router for each Zone

```bash
FOUNDRY_HARDFORK=tempo:T12 FACTORY=0x... SPENDER_ID=0x... ZONE_ID=7 ROUTER_FACTORY=0x... \
  OUT=reports/zone-router-7.json \
  forge script script/bridge/deploy/DeployZoneRouter.s.sol --rpc-url $TEMPO_RPC --broadcast --account deployer
```

The script checks that the program's clone was created for its ID, that `ZONE_ID` is a valid Zone
ID with a registered portal, and that `ROUTER_FACTORY` is set and has code. It deploys the program as in
[step 2](#2-deploy-the-program-once-per-program), or reuses it, then, through the
`ZoneRouterFactory`, a [`ZoneRouter`](../../zone-router/zone-router.md) whose mode allows only Spend,
only from `ZONE_ID`, with the program as its only spender. `ROUTER_FACTORY` is the release
`ZoneRouterFactory` ([Zone router releases](../../deployment/deployment.md#zone-router-releases)): the
program takes `spendFrom` only from that factory's routers that list it, and the release `CardFactory`,
and so the program's address, follow it. The script never deploys a factory of its own. `OUT` holds `factory`, `spenderId`, `clone`, `zoneId`, `portal`, `cardFactory`, `provider`,
`program`, `routerFactory` and `router`, and is written only with `--broadcast`.

For a hosted program, release the program with the Bridge Release workflow's `bridgeProgram`
([Deploying from CI](#deploying-from-ci)) or step 2's script. The router can then come from an Earn
deployment profile's `zoneRouter`, which lists the program and deploys, verifies and records the
router with `pnpm earn deploy`, or from Zone Router Release's `zoneRouter`. Through the same factory,
either adopts a router this script already deployed for that mode
([Zone router deployment](../../zone-router/zone-router.md#deployment)).

The router has no owner and needs no configuration. The Zone admin checks the router with the
factory's `isRouter(router)`, and the program with `CardFactory.isDeployed(program)` and
`program.ROUTER_FACTORY()`, which must be that factory, then grants roles:

- if the callback gateway is closed, `setGateway(router, true)`;
- if the gateway is open and access is enforced, `setAllowedAccount(router, true)`;
- if access is enforced, `setAllowedAccount(refundRecipient, true)` for the program's refund
  recipient, and `setAllowedAccount(programWallet, true)` for the program wallet, which deposits
  private refunds into the Zone.

An address holds one Zone role at a time. To move the router from the account role to the gateway
role, `setAllowedAccount(router, false)` first.

## 5. Check the program before it goes live

```bash
FOUNDRY_HARDFORK=tempo:T12 FACTORY=0x... SPENDER_ID=0x... SETTLEMENT=0x... TOKEN=0x... ZONE_ID=2 \
  ROUTER_FACTORY=0x... ROUTER=0x... REFUND_RECIPIENT=0x... PROGRAM_WALLET=0x... VAULTS=0xVault1 \
  forge script script/bridge/deploy/Preflight.s.sol --rpc-url $TEMPO_RPC
```

Nothing is sent. `ROUTER_FACTORY`, `ROUTER`, `REFUND_RECIPIENT` and `PROGRAM_WALLET` are optional,
and each one left out reports `todo`; the router checks need both `ROUTER_FACTORY` and `ROUTER`.
`VAULTS` is optional too: without it no vault is checked, as for a stablecoin-only program. It
prints `ok` or `todo` for each item, with who submits the fix. Advice that does not stop a spend reads
`warn` instead of `todo`: Bridge's timelock, the release-address check, and each gas-readiness item, whose
only cost is the larger callback gas:

- the program's clone was created for `SPENDER_ID`, which `TS` requires;
- `TS` is registered, has code, was built for this factory, and is usable by the program;
- the `TS` handler, the program and its provider are this repository's build: their code matches
  copies the script deploys in its own simulation, so one deployed from older code reads `todo`.
  Solc's metadata hash is left out, so a build from source that differs only in comments still
  matches;
- the settlement destination is authorized, and the factory has not paused the program;
- whether `SETTLEMENT` is a TIP-1022 virtual address, and if so the master its transfers credit, which
  must be registered. The policy and balance checks of the settlement wallet read that master. An
  Earn spend to a virtual settlement redeems the vault asset to the clone and forwards it, so the clone
  must also be authorized under the vault asset's policy and, for the callback gas figures, hold a seed
  of the vault asset;
- Bridge's trust anchors, which only Bridge can change and which are worth reviewing before going live:
  the factory's `defaultAdmin()`, whether it is a `TimelockController` and its `getMinDelay()`, and
  `defaultAdminDelay()`; the factory proxy's ERC-1967 implementation; whether `factory.implementation()`,
  the delegator every clone runs, is this repository's `SpenderDelegator`; and that the clone's ERC-1967
  beacon slot names the factory;
- the token's TIP-403 policy lets the settlement wallet receive, the router and program receive and
  send, the refund recipient receive, the program wallet send, the portal and its messenger send
  and receive, and the Zone admin, which the portal pays its deposit fee, receive. Under a
  blacklist this passes unless an address is listed. Under a whitelist the policy admin adds each
  one;
- the Zone has a registered portal, with `TOKEN` enabled and its deposits not paused, and its
  messenger is the canonical one;
- `ROUTER_FACTORY` deployed `ROUTER`, and `ROUTER` takes Spend callbacks from `ZONE_ID` through a
  `CardSpender` whose provider is a `BridgeProvider` for `FACTORY` and `SPENDER_ID`. Only a router the
  factory deployed is read, so an arbitrary address cannot pass. That `CardSpender` is the release
  program for `FACTORY`, `SPENDER_ID` and `ROUTER_FACTORY` (`bridgeProgramAddress`), and its
  `ROUTER_FACTORY()` is `ROUTER_FACTORY`, since it refuses `spendFrom` from any other factory's router;
- `ROUTER` has its Zone role. That is the callback gateway role when the gateway is closed, or the
  account role when it is open and access is enforced;
- `REFUND_RECIPIENT` is admitted, and `PROGRAM_WALLET` can deposit refunds into the Zone, which
  needs the account role when access is enforced;
- each vault in `VAULTS` is allowed, which reads `todo` until `TS` is usable, and its engine
  supports exact withdrawals and redeem previews;
- the gas readiness of [step 6](#6-prepare-the-program-for-low-callback-gas): the settlement wallet
  holds the stablecoin it receives (the vault asset for Earn), `program.warm(TOKEN)` and
  `router.warm(TOKEN)` are done, the program and the router each hold a seed of `TOKEN`, and for Earn
  the clone holds a seed of the share and has its standing approval to each vault in `VAULTS`. A
  program that pays directly, without a clone, also needs `program.warmVault(vault)` for each. The
  last line says whether every one is done; until then request 3M callback gas.

For Earn, run it again with `TOKEN` set to the vault's EarnShare and the vault in `VAULTS`. It then
checks the settlement and program wallets against the vault asset's policy, and that a private
refund in the asset can reach the Zone: the portal receives and sends, the Zone admin and refund
recipient receive, and the portal takes deposits of the asset. Against the share's policy it checks
the router, program, refund recipient, portal, messenger and Zone admin as for a stablecoin, and
that the clone receives and sends and the vault receives. EarnShare policies are whitelists, so
the policy admin adds whichever of the clone, vault, router, program, refund recipient, portal,
messenger and Zone admin are missing.

## 6. Prepare the program for low callback gas

Optional, and [preflight](#5-check-the-program-before-it-goes-live) reports each item. Anyone can do it,
once per token the program spends from a Zone (its stablecoin, and the EarnShare for Earn):
`router.warm(token)` and `program.warm(token)` set the router's standing approval to its
Zone's portal and the program's to its clone. Without them the program's first spend sets
them, which costs that spend about 250k more gas each. The clone's approval to each allowed vault is
set when governance allows it with `UV`.

For Earn, also send 1 unit of the EarnShare to the vault itself. `withdrawExact` pulls the shares it
burns into the vault before burning them, so without a seed every Earn spend creates and clears the
vault's own balance slot (about 250k). The vault never reads its own EarnShare balance, so the unit only
stays there (the last holder's full exit leaves it behind), and it serves every program on the vault.

For Earn, also send 1 unit of the EarnShare to the program's clone. The clone holds the shares an
Earn spend redeems, and the TS handler pays from its caller, never from the clone's own balance, so
the unit stays and no spend creates that balance slot again (about 245k). It cannot be recovered.
Under a whitelist policy the clone must already be admitted, as preflight checks.

Send the program and the router 1 unit of each token too. Each receives a private spend's input and
passes all of it on, so without a seed every spend creates its balance slot again. A seed is safe: the
program's `spendFrom` takes calls only from a router its `ROUTER_FACTORY` deployed that lists it, and
both count only what a callback brings, so neither can spend the seed. It cannot be recovered either.

The settlement wallet must also hold a balance of each token it receives (the stablecoin, and the
vault's asset for Earn) before the first spend, and Bridge must never sweep it to zero: a spend to a
wallet with no balance creates that slot, about 250k more gas. Send it 1 unit of each, or leave 1 unit
after every sweep.

The TF handler, on the same clone, clears that vault approval after each of its own Earn pulls,
so while TF pulls from the same vault the next private Earn spend sets it again, about 250k more gas.

Then request callback gas per spend type rather than one figure, sized for the worst case of a
prepared program: about 0.3M for a stablecoin spend (measured 0.19M) and 0.55M for an Earn spend
(measured 0.50M), or 0.8M while TF pulls from the same vault and clears the approval (about 250k
more). That fits 4 spends of each into a default withdrawal batch, or 3 at 0.8M
([design](design.md#callback-gas)). The figures hold only once all of
step 6 is done, the settlement wallet's balance included: a callback that runs out of gas bounces
after Bridge approved the card. Until then, and for a vault costlier than the OUSD vault, keep 3M or
measure the program's own vault first.

## Deploying from CI

The **Bridge Release** workflow ([`bridge-release.yml`](../../../.github/workflows/bridge-release.yml))
deploys the handler (`tempoSpend`) or a program (`bridgeProgram`) from `main`, with the same scripts
and so at the same deterministic addresses as a deploy by Bridge. Choose the network (Moderato or
mainnet), the contract, Bridge's factory, for a program its `spenderId` and `routerFactory` (the Zone router
release's `ZoneRouterFactory`, whose routers alone may call it), and whether to broadcast; without broadcast Forge only simulates. It runs
[`script/bridge/deploy/release.sh`](../../../cards/script/bridge/deploy/release.sh)
(`release.sh <moderato|mainnet|local> <tempoSpend|bridgeProgram> [--broadcast]`; `bridgeProgram` reads
`FACTORY`, `SPENDER_ID` and `ROUTER_FACTORY`), which:

- refuses an RPC serving another chain, and runs Forge at the chain's hardfork from
  `tempo_forkSchedule`;
- predicts each address from the locally compiled creation code and attributes creation only
  from matching successful receipts. `CardFactory` and `BridgeProvider` come from the CREATE2
  deployer; a program requires the matching `ProgramDeployed` event from `CardFactory.deploy`.
  A concurrent creation or successful call with no creation event is reuse, with `created: false`
  and no creation transaction hash passed to source verification;
- after a broadcast, source-verifies each one on Tempo's verifier (`https://contracts.tempo.xyz`),
  including a contract that already existed, and fails if the verifier has no source match. A
  program's release verifies all three.

The job summary lists the address, the transaction and the source match, and the admin and
governance calls above for Bridge to submit; the `bridge-release-<network>-<contract>-<attempt>`
artifact holds the result and Forge's broadcast files. The workflow never submits those calls:
registering and gating stay with Bridge's roles. A program needs no factory call; list it in the
Zone's Spend-mode router.

Dispatching it from `main` is the approval: the job runs in the `factory-release-<network>`
environment, which has no required reviewer and accepts only `main`, with the deployer key
and RPC credentials of the [factory releases](../../deployment/deployment.md#releasing-from-ci), and
shares their `hosted-contracts-<network>` queue. The handler, `CardFactory`, provider and program are
ownerless, so the key only pays fees. The script also runs locally, for example against a dev node:

```bash
FACTORY=0x... DEPLOYER_PRIVATE_KEY=0x... TEMPO_RPC_URL=http://127.0.0.1:8545 \
  script/bridge/deploy/release.sh local tempoSpend --broadcast
```

## Testing the scripts

`test/bridge/unit/DeployScripts.t.sol` runs each script against the harness's factory, submits the calls
it writes with the matching role, and settles a spend through the new handler.
`test/bridge/unit/DeterministicDeploy.t.sol` checks that the handler, `CardFactory`, `BridgeProvider` and
program land at their predicted addresses for any deployer, and that deploying again reuses them
without sending anything.

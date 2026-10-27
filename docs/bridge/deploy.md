# Deploying

The Bridge integration deploys into Bridge's existing `SpenderFactory`: the "TS" handler, each
program's `BridgeSettler` and the program's Zone router. None has an owner, so nothing changes after
deployment. The handler lands at a deterministic address, so Bridge can deploy it with the scripts
below or Tempo with the [Bridge Release workflow](#deploying-from-ci), and either lands on the same
contract. A program's `BridgeSettler` is a [Zone router settler](../zone-router/zone-router.md#bridgesettler):
its hosted release is the Zone router's ([`bridgeSettler`](../deployment/deployment.md#zone-router-releases)),
and the scripts here deploy one for E2E and local stacks. Every factory change is a role-gated call,
so the scripts write those calls as calldata for the multisig that holds each role, instead of
sending them.

Against a live chain, set the chain's current hardfork (`tempo_forkSchedule`) in
`FOUNDRY_HARDFORK`, for example `FOUNDRY_HARDFORK=tempo:T12`. The repo's tests pin `tempo:T8`, and forge cannot run the Zone factory
under it. The router deploy and
the preflight both read the Zone factory.

## 1. Deploy the handler (once)

```bash
FACTORY=0x... OUT=reports/tempo-spend.json \
  forge script script/deploy/DeployTempoSpend.s.sol --rpc-url $TEMPO_RPC --broadcast --account deployer
```

The script creates the handler through the CREATE2 deployer
(`0x4e59b44847b379578588920cA78FbF26c0B4956C`) with the salt of Earn's
[shared factory releases](../deployment/deployment.md#shared-factory-releases)
([`BridgeRelease`](../../bridge/script/deploy/BridgeRelease.sol)), so the same build for the same
factory lands at the same address whoever deploys it. A handler already at that address is reused
and nothing is sent. The address follows this repository's build of `bridge/`: a change to the
handler's source, including the `Spend` struct it imports from `zone-router/`, the compiler settings
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

## 2. Turn it on for a program

The program exists already: Bridge's manager created it with `createSpender(spenderId,
destinations)`, with the settlement wallet as a destination. `TS` must be
registered, that is the admin's `setSpenderHandler` has executed.

```bash
FACTORY=0x... SPENDER_ID=0x... VAULTS=0xVault1,0xVault2 OUT=reports/program.json \
  forge script script/deploy/ProgramCalls.s.sol --rpc-url $TEMPO_RPC
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

## 3. Deploy the settler and router for each Zone

```bash
FOUNDRY_HARDFORK=tempo:T12 FACTORY=0x... SPENDER_ID=0x... ZONE_ID=7 ROUTER_FACTORY=0x... \
  OUT=reports/zone-router-7.json \
  forge script script/deploy/DeployZoneRouter.s.sol --rpc-url $TEMPO_RPC --broadcast --account deployer
```

The script checks that the program's clone was created for its ID, that `ZONE_ID` is a valid Zone
ID with a registered portal, and that `ROUTER_FACTORY` has code. It deploys the program's
`BridgeSettler` through the CREATE2 deployer with the release salt, as the handler, or reuses the
one there, then, through the `ZoneRouterFactory`, a [`ZoneRouter`](../zone-router/zone-router.md)
whose mode allows only Spend, only from `ZONE_ID`, through that settler alone. The settler is
compiled with this project's settings, so it lands at a different address from the Zone Router
Release's `bridgeSettler`, which compiles it in `zone-router/`. Leave
`ROUTER_FACTORY` unset to deploy a new factory. `OUT` holds `factory`, `spenderId`, `clone`,
`zoneId`, `portal`, `settler`, `routerFactory` and `router`, and is written only with
`--broadcast`.

For a hosted program, release the settler alone with Zone Router Release
(`pnpm zone-router-release <network> bridgeSettler --parameters '{"factory": "<SpenderFactory>", "spenderId": "<bytes32>"}'`).
It checks that the factory has a clone for the program, not that the ID is the one the clone was
created for; the preflight below does. The router can then come from an Earn deployment profile's
`zoneRouter`, which lists the settler and deploys, verifies and records the router with
`pnpm earn deploy`, or from Zone Router Release's `zoneRouter`. Through the same factory, either
adopts a router this script already deployed for that mode
([Zone router deployment](../zone-router/zone-router.md#deployment)).

Neither contract has an owner or needs configuration. The Zone admin checks the router with the
factory's `isRouter(router)`, then grants roles:

- if the callback gateway is closed, `setGateway(router, true)`;
- if the gateway is open and access is enforced, `setAllowedAccount(router, true)`;
- if access is enforced, `setAllowedAccount(refundRecipient, true)` for the program's refund
  recipient, and `setAllowedAccount(programWallet, true)` for the program wallet, which deposits
  private refunds into the Zone.

An address holds one Zone role at a time. To move the router from the account role to the gateway
role, `setAllowedAccount(router, false)` first.

## 4. Check the program before it goes live

```bash
FOUNDRY_HARDFORK=tempo:T12 FACTORY=0x... SPENDER_ID=0x... SETTLEMENT=0x... TOKEN=0x... ZONE_ID=2 \
  ROUTER_FACTORY=0x... ROUTER=0x... REFUND_RECIPIENT=0x... PROGRAM_WALLET=0x... VAULTS=0xVault1 \
  forge script script/deploy/Preflight.s.sol --rpc-url $TEMPO_RPC
```

Nothing is sent. `ROUTER_FACTORY`, `ROUTER`, `REFUND_RECIPIENT` and `PROGRAM_WALLET` are optional,
and each one left out reports `todo`; the router checks need both `ROUTER_FACTORY` and `ROUTER`.
`VAULTS` is optional too: without it no vault is checked, as for a stablecoin-only program. It
prints `ok` or `todo` for each item, with who submits the fix:

- the program's clone was created for `SPENDER_ID`, which `TS` requires;
- `TS` is registered, has code, was built for this factory, and is usable by the program;
- the `TS` handler and the router's settler are this repository's build: their code matches copies
  the script deploys in its own simulation, so one deployed from older code reads `todo`. Solc's
  metadata hash is left out, so a build from source that differs only in comments, or a settler
  Zone Router Release compiled in `zone-router/`, still matches;
- the settlement destination is authorized, and the factory is not paused;
- the token's TIP-403 policy lets the settlement wallet receive, the router and settler receive and
  send, the refund recipient receive, the program wallet send, the portal and its messenger send
  and receive, and the Zone admin, which the portal pays its deposit fee, receive. Under a
  blacklist this passes unless an address is listed. Under a whitelist the policy admin adds each
  one;
- the Zone has a registered portal, with `TOKEN` enabled and its deposits not paused, and its
  messenger is the canonical one;
- `ROUTER_FACTORY` deployed `ROUTER`, and `ROUTER` takes Spend callbacks from `ZONE_ID` through a
  settler for this factory and program. Only a router the factory deployed is read, so an
  arbitrary address cannot pass;
- `ROUTER` has its Zone role. That is the callback gateway role when the gateway is closed, or the
  account role when it is open and access is enforced;
- `REFUND_RECIPIENT` is admitted, and `PROGRAM_WALLET` can deposit refunds into the Zone, which
  needs the account role when access is enforced;
- each vault in `VAULTS` is allowed, which reads `todo` until `TS` is usable, and its engine
  supports exact withdrawals and redeem previews.

For Earn, run it again with `TOKEN` set to the vault's EarnShare and the vault in `VAULTS`. It then
checks the settlement and program wallets against the vault asset's policy, and that a private
refund in the asset can reach the Zone: the portal receives and sends, the Zone admin and refund
recipient receive, and the portal takes deposits of the asset. Against the share's policy it checks
the router, settler, refund recipient, portal, messenger and Zone admin as for a stablecoin, and
that the clone receives and sends and the vault receives. EarnShare policies are whitelists, so
the policy admin adds whichever of the clone, vault, router, settler, refund recipient, portal,
messenger and Zone admin are missing.

## Deploying from CI

The **Bridge Release** workflow ([`bridge-release.yml`](../../.github/workflows/bridge-release.yml))
deploys the handler (`tempoSpend`) from `main`, with the same script and so at the same
deterministic address as a deploy by Bridge. Choose the network (Moderato or mainnet), Bridge's
factory, and whether to broadcast; without broadcast Forge only simulates. It runs
[`script/deploy/release.sh`](../../bridge/script/deploy/release.sh), which:

- refuses an RPC serving another chain, and runs Forge at the chain's hardfork from
  `tempo_forkSchedule`;
- predicts the address from the locally compiled creation code, and checks that the run created
  exactly that contract there from that code, or nothing when it already existed;
- after a broadcast, source-verifies it on Tempo's verifier (`https://contracts.tempo.xyz`),
  including a contract that already existed, and fails if the verifier has no source match.

The job summary lists the address, the transaction and the source match, and the admin and
governance calls above for Bridge to submit; the `bridge-release-<network>-<contract>-<attempt>`
artifact holds the result and Forge's broadcast files. The workflow never submits those calls:
registering and gating stay with Bridge's roles. A program's `BridgeSettler` releases through the
[Zone Router Release](../deployment/deployment.md#zone-router-releases) workflow instead, and
`release.sh` refuses it.

Dispatching it from `main` is the approval: the job runs in the `factory-release-<network>`
environment, which has no required reviewer and accepts only `main`, with the deployer key
and RPC credentials of the [factory releases](../deployment/deployment.md#releasing-from-ci), and
shares their `hosted-contracts-<network>` queue. The handler is ownerless, so the key only pays
fees. The script also runs locally, for example against a dev node:

```bash
FACTORY=0x... DEPLOYER_PRIVATE_KEY=0x... TEMPO_RPC_URL=http://127.0.0.1:8545 \
  script/deploy/release.sh local tempoSpend --broadcast
```

## Testing the scripts

`test/unit/DeployScripts.t.sol` runs each script against the harness's factory, submits the calls
it writes with the matching role, and settles a spend through the new handler.
`test/unit/DeterministicDeploy.t.sol` checks that the handler and the scripts' settler land at their
predicted release addresses for any deployer, and that deploying again reuses them without sending
anything. The Zone router's `test/DeployRouterRelease.t.sol` does the same for the released settler.

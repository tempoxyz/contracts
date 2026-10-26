# Deploying

Tempo spend deploys into Bridge's existing `SpenderFactory`. Anyone can deploy the two contracts.
Every factory change is a role-gated call, so the scripts write those calls as calldata for the
multisig that holds each role, instead of sending them.

Against a live chain, set the chain's current hardfork (`tempo_forkSchedule`) in
`FOUNDRY_HARDFORK`, for example `FOUNDRY_HARDFORK=tempo:T12`. The repo's tests pin `tempo:T8`, and forge cannot run the Zone factory
under it. The receiver deploy and
the preflight both read the Zone factory.

## 1. Deploy the handler (once)

```bash
FACTORY=0x... OUT=reports/tempo-spend.json \
  forge script script/deploy/DeployTempoSpend.s.sol --rpc-url $TEMPO_RPC --broadcast --account deployer
```

The deploy scripts sign with forge's `--account` or `--ledger`. `DEPLOYER_PK` also works, for test
networks, and takes precedence over both when set. `OUT` is written only with `--broadcast`, but
forge writes it while running the script, before the deployment confirms. Check that `handler` has
code before submitting its calls. It holds the handler address, the prefix's `status` before the deploy, and two calls to the
factory:

| Field                   | Submitted by     | Call                                      |
| ----------------------- | ---------------- | ----------------------------------------- |
| `adminRegisterHandler`  | Admin (timelock) | `setSpenderHandler("TS", handler)`        |
| `governanceGateHandler` | Governance       | `updateSpenderHandlerStatus("TS", Gated)` |

A gated handler only runs for programs governance allowlists, so programs can be turned on one at
a time. Governance can later switch the status to `Enabled` for every program, or `Disabled` to
stop it.

Run the same script to replace a live handler. The factory keeps the prefix's status across
`setSpenderHandler`, so `governanceGateHandler` is written only for a first registration while
`status` is `Disabled`. Otherwise it is empty (`0x`) and only the admin call is needed:

- on a replacement, a gate call would cut off every program that relies on `Enabled`;
- if `status` is `Enabled` before a first registration, the handler runs for every program once
  registered;
- if `status` is `Disabled`, a replacement stays off until governance changes it.

## 2. Turn it on for a program

The program exists already: Bridge's manager created it with `createSpender(spenderId,
destinations)`, with the settlement wallet and the program wallet as destinations. `TS` must be
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

## 3. Deploy a receiver for each Zone

```bash
FOUNDRY_HARDFORK=tempo:T12 FACTORY=0x... SPENDER_ID=0x... ZONE_ID=7 OUT=reports/receiver-7.json \
  forge script script/deploy/DeployZoneReceiver.s.sol --rpc-url $TEMPO_RPC --broadcast --account deployer
```

The script checks that the program's clone was created for its ID, that `ZONE_ID` is a valid Zone
ID, and that the Zone has a registered portal. The receiver has no owner and needs no
configuration. Then the Zone admin grants roles:

- if the callback gateway is closed, `setGateway(receiver, true)`;
- if the gateway is open and access is enforced, `setAllowedAccount(receiver, true)`;
- if access is enforced, `setAllowedAccount(refundRecipient, true)` for the program's refund
  recipient.

An address holds one Zone role at a time. To move the receiver from the account role to the
gateway role, `setAllowedAccount(receiver, false)` first.

## 4. Check the program before it goes live

```bash
FOUNDRY_HARDFORK=tempo:T12 FACTORY=0x... SPENDER_ID=0x... SETTLEMENT=0x... TOKEN=0x... ZONE_ID=2 \
  RECEIVER=0x... REFUND_RECIPIENT=0x... PROGRAM_WALLET=0x... VAULTS=0xVault1 \
  forge script script/deploy/Preflight.s.sol --rpc-url $TEMPO_RPC
```

Nothing is sent. `RECEIVER`, `REFUND_RECIPIENT`, `PROGRAM_WALLET` and `VAULTS` are optional, and
each one left out reports `todo`. It prints `ok` or `todo` for each item, with who submits the fix:

- the program's clone was created for `SPENDER_ID`, which `TS` requires;
- `TS` is registered, has code, was built for this factory, and is usable by the program;
- the `TS` handler and `RECEIVER` are this repo's build: their code matches copies the script
  deploys in its own simulation, so one deployed from older code reads `todo`. Solc's metadata
  hash is left out, so a build from source that differs only in comments still matches;
- the settlement destination is authorized, and the factory is not paused;
- `PROGRAM_WALLET`, which pays private refunds, is also a destination, since `refundPrivate`
  rejects any other caller;
- the token's TIP-403 policy lets the settlement wallet receive, the receiver receive and send,
  the refund recipient receive, the program wallet send, the portal and its messenger send and
  receive, and the Zone admin, which the portal pays its deposit fee, receive. Under a blacklist this passes unless an address is listed. Under a whitelist the policy
  admin adds each one;
- the Zone has a registered portal, with `TOKEN` enabled and its deposits not paused, and its
  messenger is the canonical one;
- `RECEIVER` was deployed for this factory, program and Zone, and has its Zone role. That is
  the callback gateway role when the gateway is closed, or the account role when it is open and
  access is enforced;
- `REFUND_RECIPIENT` is admitted;
- each vault in `VAULTS` is allowed, which reads `todo` until `TS` is usable, and its engine
  supports exact withdrawals and redeem previews.

For Earn, run it again with `TOKEN` set to the vault's EarnShare and the vault in `VAULTS`. It then
checks the settlement and program wallets against the vault asset's policy, and that a private
refund in the asset can reach the Zone: the receiver and portal receive and send, the Zone admin
receives, and the portal takes deposits of the asset. Against the share's policy it checks the same addresses as for a stablecoin, and
that the clone receives and sends and the vault receives. EarnShare policies are whitelists, so the
policy admin adds whichever of the clone, vault, receiver, refund recipient, portal, messenger and
Zone admin are missing.

## Testing the scripts

`test/unit/DeployScripts.t.sol` runs each script against the harness's factory, submits the calls
it writes with the matching role, and settles a spend through the new handler.

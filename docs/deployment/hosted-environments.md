# Hosted environments runbook

This runbook owns what is deployed on hosted networks, how a network is added, and hosted
troubleshooting. TIP-403 membership commands are in
[access policy](../earn/modules/access.md#deployment-and-operations), E2E in
[E2E environments](e2e-environments.md), the app catalog and app deploys in
[app deployment](app-deployment.md), and the Worker's Tempo API reads in the
[app runtime reference](../development/app-runtime.md#tempo-api-zone-reads).

A profile's `deployment.json` and the app catalog's listed stacks are authoritative; do not infer
availability from transaction history.

## Current availability

These are Tempo-owned test profiles; customer stacks are under
[customer deployments](#customer-deployments).

- [`app-moderato`](../../profiles/app-moderato/profile.json) is the Moderato app's default PATHUSD
  ERC-4626 stack with open access, listed with public and private modes. Its Zone 3 router converts
  AlphaUSD to PATHUSD at par through a DirectPropAMM pool over existing canonical tokens, so it has
  no `fixture.json`: the Moderato test deployer deployed the pool with a `DemoPropAMMParOracle` and
  an identity recipient registry, owns it (so `authorize-router` runs under its key), and funds
  both inventory sides. Zone 3 (chain `1424310003`, from `hostedEnvironments`) enables AlphaUSD and
  the EarnShare, registers the router as a callback gateway, and enforces account admission, so a
  browser account can act privately only after the Zone administrator grants it the Portal
  `Account` role; the app refuses the action before submitting it otherwise.
- [`veda-moderato`](../../profiles/veda-moderato/profile.json) is a public PATHUSD stack over a
  Tempo-owned Veda-compatible fixture ([Veda test stacks](../earn/modules/veda.md#test-stacks)), listed by
  the Moderato app and used for hosted Veda acceptance.
- [`e2e-moderato`](../../profiles/e2e-moderato/profile.json) is the disposable open-access Zone 3
  stack for hosted Zone E2E and the scheduled [benchmark](benchmarks.md), with a bootstrapped
  `fixture.json`; it is not listed in the app. Protected policies and alternate stablecoins remain
  E2E-only fixtures.
- [`veda-mainnet`](../../profiles/veda-mainnet/profile.json) is a retired test fixture. It is not
  listed in the app and must not be refilled or reused; its profile and record remain for
  provenance.

The app lists only Moderato; mainnet has no listed stack.

## Adding a hosted network

`hostedEnvironments` in [`deployments/chain/tempo.ts`](../../deployments/chain/tempo.ts) is the only
list of hosted networks. Profile parsing, deployment tooling, the app Worker and browser, and hosted
E2E all derive their network IDs, chain templates, testnet gating, faucet, fee token policy, and
sponsor from it. To add a network:

1. Add its entry: the `viem/tempo/chains` template (chain ID, public RPC, explorer), `testnet`,
   `faucet`, `defaultFeeToken` (whether sends keep the protocol's default fee token), the
   `sponsorUrl` if the app sponsors it, the Zone chain ID range (`zoneChainIdBase`,
   `zoneChainIdEnd`), and the hosted Zone's ID.
2. Add its entry, under the same ID, to `canonicalReleases` in the
   [release registry](../../deployments/core/releases.ts); type checking fails until it exists. One
   entry holds the reviewed [shared factory release](deployment.md#shared-factory-releases)
   (`factories`, with every engine factory key and `null` for a factory not yet released there).
3. When the network has an active reviewed stack to serve, list it in the app catalog
   ([catalog boundaries](app-deployment.md#catalog-boundaries)) and
   [regenerate the catalog](app-deployment.md#regenerating-the-catalog). A network with no active
   stack stays out of the catalog.

## Customer deployments

Customer stacks are not in this repository. Their profiles, generated records, and runbooks live in a
private deployments repository that pins Earn as a submodule and runs this tooling against them
([profiles in another repository](../../profiles/README.md#profiles-in-another-repository)), so Earn
lists no customers. Recheck one on demand with `pnpm earn verify <profile.json>` and
`pnpm e2e:profile <profile.json> --validate-only`, with `TEMPO_API_KEY` or `ZONE_RPC_URL` set for
the live Zone check ([rechecking deployed profiles](deployment.md#rechecking-deployed-profiles)).

## Troubleshooting

| Symptom                                  | Meaning                                                       | Action                                                                                            |
| ---------------------------------------- | ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| Private case cannot reach the Zone RPC   | `TEMPO_API_KEY` is absent or lacks access to that Zone        | configure `TEMPO_API_KEY` with access to the profile's Zone, or set `ZONE_RPC_URL`                |
| Deployment unavailable                   | the profile has no current `deployment.json`                  | deploy the profile with `pnpm earn deploy`                                                        |
| Portal, Messenger, or sequencer mismatch | the recorded or configured Zone identity is stale             | confirm the current Zone Factory registration and sequencers with Core Zones                      |
| Token disabled                           | Zone cannot receive an input, output, fee token, or EarnShare | ask the Zone administrator to enable it                                                           |
| Callback stops after `zones(id)`         | Messenger runtime is stale                                    | align Factory, Messenger, and nine-field ABI                                                      |
| `AccountNotAllowed(address)`             | Portal account admission is missing                           | have the Zone administrator admit the account ([details](e2e-environments.md#hosted-zone-access)) |
| TIP-403 rejection                        | a sender, refund recipient, or endpoint is absent             | update policy membership                                                                          |
| Router not admitted                      | the pool owner has not admitted the router as taker/recipient | have the pool owner admit it, then rerun the same profile                                         |
| Pool inventory is empty on one side      | private flow depleted the pool's vault or private asset       | have the pool owner rebalance and fund the depleted side                                          |

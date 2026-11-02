# Hosted environments runbook

This runbook owns what is deployed on hosted networks, how a network is added, and hosted
troubleshooting. TIP-403 membership commands are in
[access policy](../earn/modules/access.md#deployment-and-operations), and E2E in
[E2E environments](e2e-environments.md).

A profile's `deployment.json` is authoritative; do not infer
availability from transaction history.

## Current availability

These are Tempo-owned test profiles; other stacks are under
[external deployments](#external-deployments).

- [`veda-moderato`](../../profiles/veda-moderato/profile.json) is a public PATHUSD stack over a
  Tempo-owned Veda-compatible fixture ([Veda test stacks](../earn/modules/veda.md#test-stacks)), used for
  hosted Veda acceptance.
- [`e2e-moderato`](../../profiles/e2e-moderato/profile.json) is the disposable open-access Zone 3
  stack for hosted Zone E2E and the scheduled [benchmark](benchmarks.md), with a bootstrapped
  `fixture.json`. Protected policies and alternate stablecoins remain
  E2E-only fixtures.

## Adding a hosted network

`hostedEnvironments` in [`deployments/chain/tempo.ts`](../../deployments/chain/tempo.ts) is the only
list of hosted networks. Profile parsing, deployment tooling, and hosted
E2E all derive their network IDs, chain templates, testnet gating, faucet, fee token policy, and
sponsor from it. To add a network:

1. Add its entry: the `viem/tempo/chains` template (chain ID, public RPC, explorer), `testnet`,
   `faucet`, `defaultFeeToken` (whether sends keep the protocol's default fee token), the
   `sponsorUrl` of its fee sponsor, the Zone chain ID range (`zoneChainIdBase`,
   `zoneChainIdEnd`), and the hosted Zone's ID.
2. Add its entry, under the same ID, to `canonicalReleases` in the
   [release registry](../../deployments/core/releases.ts); type checking fails until it exists. One
   entry holds the reviewed [shared factory release](deployment.md#shared-factory-releases)
   (`factories`, with every engine factory key and `null` for a factory not yet released there).

## External deployments

Stacks deployed outside this repository keep their profiles, generated records, and runbooks in a
separate deployments repository that pins this repository as a submodule and runs this tooling against them
([profiles in another repository](../../profiles/README.md#profiles-in-another-repository)). Recheck one on demand with `pnpm earn verify <profile.json>` and
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

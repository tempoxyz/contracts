# Glossary

One line per term; each links to the page that owns it.

## Core stack

- **EarnVault:** the persistent contract users deposit into and redeem from; the sole EarnShare
  issuer, it keeps accounting stable across engine changes ([system](architecture/system.md#earnvault)).
- **EarnShare:** the native, non-rebasing TIP-20 token EarnVault mints for a deposit; yield raises
  the assets each EarnShare redeems for, not balances ([system](architecture/system.md#earnshare)).
- **Engine:** the single-EarnVault contract that holds the venue shares and adapts one venue to the
  shared engine interface; the operator can migrate to another ([yield engines](integrations/engines.md)).
- **Venue:** the external yield source an engine holds shares of: an ERC-4626 vault, a Veda
  BoringVault, or a DirectPropAMM pool ([yield engines](integrations/engines.md)).
- **Managed backing:** the engine shares EarnVault counts as backing active EarnShare
  ([accounting anchors](architecture/system.md#accounting-anchors)).
- **Quarantined surplus:** venue shares the engine holds beyond managed backing, such as donations
  or rounding remainders; excluded from fees, quotes, and exits until absorbed as a reward
  ([accounting anchors](architecture/system.md#accounting-anchors)).
- **Pending claim:** a queued redemption's fixed entitlement, recorded after its EarnShare is burned
  and excluded from active supply and backing until finalized or cancelled
  ([queued withdrawals](architecture/fees.md#queued-withdrawals)).

## Tempo and Zones

- **Tempo:** the EVM-compatible payments L1 Earn runs on; its differences are in
  [EVM compatibility](https://docs.tempo.xyz/quickstart/evm-compatibility).
- **Zone:** a private stablecoin ledger on Tempo that hides balances and history from outside
  observers ([Tempo Zones](modules/zone-router.md), [Tempo docs](https://docs.tempo.xyz/protocol/zones)).
- **Portal:** a Zone's L1 contract that holds the tokens deposited into the Zone, enables tokens,
  and admits accounts; the Earn router accepts only deliveries from a Zone Factory-recognized Portal
  ([authentication](modules/zone-router.md#authentication-and-callback)).
- **Sequencer:** the operator that orders a Zone's transactions and sees all Zone activity
  ([privacy model](architecture/security-and-privacy.md#privacy-model)).
- **Moderato:** the Tempo testnet, chain ID `42431`; mainnet is `4217`
  ([hosted environments](operations/hosted-environments.md#current-availability)).
- **Localnet vs devnet:** localnet is a disposable L1 and Zone this repository starts in Docker;
  a devnet is an existing non-hosted L1 and Zone run elsewhere that the tooling deploys onto
  ([localnet](development/localnet.md), [devnet chains](operations/e2e-environments.md#existing-devnet-chains)).
- **TIP-20:** Tempo's native token standard, which EarnShare and the base assets implement
  ([Tempo docs](https://docs.tempo.xyz/protocol/tip20/overview)).
- **TIP-403:** Tempo's transfer-policy registry; a protected EarnShare attaches one whitelist policy,
  an open one the always-allow policy `1` ([access policy](modules/access.md#open-and-protected-earnshare)).
- **PATHUSD:** Tempo's protocol USD stablecoin at `0x20C0…0000`, the base asset of the hosted
  stacks ([Tempo docs](https://docs.tempo.xyz/protocol/exchange/pathUSD)).
- **Par:** exact one-to-one conversion between two equal-decimal stablecoins; the router converts
  only at par and stops otherwise ([par conversion](modules/zone-router.md#par-conversion)).

## Venues

- **DirectPropAMM:** an oracle-priced, operator-funded AMM pool; the Zone router uses one for par
  conversion and `PropAMMEngine` uses one as its venue ([PropAMM](modules/propamm.md),
  [fixture](modules/propamm.md#pinned-directpropamm-fixture)).
- **Veda, BoringVault, Teller:** Veda's externally owned vault system: the BoringVault issues the
  shares `VedaEngine` holds, the Teller executes deposits and immediate exits, and an optional Queue
  handles queued exits ([Veda engine](modules/veda.md)).

## Deployment tooling

- **Profile:** a committed, non-secret `profile.json` describing one deployment's intent
  ([profiles](../profiles/README.md)).
- **Deployment record:** the generated `deployment.json` beside a profile, holding verified addresses
  and provenance; never edited by hand ([generated record](operations/deployment.md#generated-record)).
- **Fixture:** test-only contracts and tokens a disposable stack runs over, recorded in a test
  profile's `fixture.json` ([test fixtures](../profiles/README.md#acceptance-and-test-fixtures)).
- **Catalog:** the browser-safe list of stacks the app serves, generated from verified records
  ([app deployment](operations/app-deployment.md#catalog-boundaries)).
- **Slice:** a capability's browser-safe profile parsing, recorded addresses, and stack fields
  ([deployment package layout](../deployments/README.md#layout)).
- **Capability vs module:** a capability is a feature a stack advertises, such as `deposit`,
  `asyncRedeem`, or `privateRouting`; a module is the unit that implements an optional feature
  (an engine kind, the Zone router, access policy, rewards), with one code folder, E2E folder, and
  docs page ([capability modules](README.md#capability-modules)).
- **Handoff:** the typed stop the deployment lifecycle reports when a step needs an authority it
  does not hold, such as a pool owner or Zone administrator; rerun after that owner acts
  ([authority boundaries](operations/deployment.md#authority-boundaries)).

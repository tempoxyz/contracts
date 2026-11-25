# Security policy

## Reporting a vulnerability

Report vulnerabilities privately by email to [security@tempo.xyz](mailto:security@tempo.xyz). Never
report them in public issues, pull requests, or discussions.

Include:

- the affected project and contract, script, or package, and the commit you tested;
- the impact, such as lost, stranded, or misaccounted funds, broken authority, or a privacy leak;
- steps or a proof-of-concept test that reproduces it, for example a Foundry test; and
- any deployment, profile, or configuration the issue depends on.

Keep the report confidential until we have confirmed a fix and agreed on disclosure with you.

## Scope

In scope:

- Tempo Earn: the contracts in [`src/earn/`](src/earn/);
- the Zone router: the contracts in [`src/zone/`](src/zone/), including its spenders;
- card spend: [`src/spend/`](src/spend/), the provider-agnostic core and our code for each provider
  (Bridge's "TS" handler and `BridgeProvider`, Rain's `RainProvider`); and
- the deployment tooling: [`deployments/`](deployments/), `script/`, and the
  [profile lifecycle](docs/deployment/deployment.md) they implement.

Out of scope:

- `src/demo/` and test fixtures, including `test/`, `localnet/`, `e2e/`, and
  committed fixture artifacts, which are not production code;
- vendored third-party code, such as the card providers' contracts in `vendor/`, and third-party venues
  such as ERC-4626 vaults, Veda, and PropAMM. Report issues in them to their owners. A bug in how
  Tempo's contracts integrate with them is in scope, and so are the vendored Bridge files that compile
  into the deployed "TS" handler (`vendor/bridge/src/spenders/SpenderBase.sol`,
  `vendor/bridge/src/ISpenderHandler.sol` and `vendor/bridge/src/lib/IFactory.sol`).

Each project documents its trust assumptions, privileged roles, and privacy boundary: Earn's
[security and privacy model](docs/earn/architecture/security-and-privacy.md), the
[Zone router](docs/zone/zone-router.md), and card spend's
[design](docs/spend/design.md), and the [threat models](docs/threat-models/README.md) list each
system's accepted risks. Behavior documented there as trusted or visible is not a vulnerability by
itself.

## Bug bounty

These contracts have no bug bounty.

## Audits

The [audits page](docs/audits.md) lists the completed audits and, for every contract the repository
deploys, its last audit or that it has none, and whether it has changed since. Many deployed
contracts are not audited, or have changed since their audit.

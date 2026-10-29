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

- Tempo Earn: the contracts in [`earn/src/`](earn/src/), except `earn/src/demo/`;
- the Zone router: the contracts in [`zone-router/src/`](zone-router/src/), including its settlers;
- the Bridge integration: Tempo's "TS" handler, [`bridge/src/`](bridge/src/); and
- the deployment tooling: [`deployments/`](deployments/), each project's `script/`, and the
  [profile lifecycle](docs/deployment/deployment.md) they implement.

Out of scope:

- Earn's demo application in [`earn/app/`](earn/app/);
- `earn/src/demo/` and test fixtures, including every `test/` directory, `localnet/`, `e2e/`, and
  committed fixture artifacts, which are not production code;
- vendored third-party code, such as Bridge's contracts in `bridge/vendor/`, and third-party venues
  such as ERC-4626 vaults, Veda, and PropAMM. Report issues in them to their owners. A bug in how
  Tempo's contracts integrate with them is in scope.

Each project documents its trust assumptions, privileged roles, and privacy boundary: Earn's
[security and privacy model](docs/earn/architecture/security-and-privacy.md), the
[Zone router](docs/zone-router/zone-router.md), and the Bridge integration's
[design](docs/bridge/design.md). Behavior documented there as trusted or visible is not a
vulnerability by itself.

## Bug bounty

These contracts have no bug bounty.

## Audits

Earn's completed audits, their scope, and the contracts changed or added since are listed on its
[audits page](docs/earn/audit/README.md). The Bridge integration's
[audit scope](docs/bridge/audit-scope.md) covers the "TS" handler and `BridgeSettler`.

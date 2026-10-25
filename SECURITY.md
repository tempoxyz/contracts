# Security policy

## Reporting a vulnerability

Report vulnerabilities privately by email to [security@tempo.xyz](mailto:security@tempo.xyz). Never
report them in public issues, pull requests, or discussions.

Include:

- the affected contract, script, or package, and the commit you tested;
- the impact, such as lost, stranded, or misaccounted funds, broken authority, or a privacy leak;
- steps or a proof-of-concept test that reproduces it, for example a Foundry test; and
- any deployment, profile, or configuration the issue depends on.

Keep the report confidential until we have confirmed a fix and agreed on disclosure with you.

## Scope

In scope:

- the contracts in [`src/`](earn/src/), except `src/demo/`; and
- the deployment tooling: [`deployments/`](deployments/), [`script/`](earn/script/), and the
  [profile lifecycle](docs/deployment/deployment.md) they implement.

Out of scope:

- the demo application in [`app/`](app/);
- `src/demo/` and test fixtures, including `test/`, `localnet/`, and committed fixture artifacts,
  which are not production code;
- third-party venues and their contracts, such as ERC-4626 vaults, Veda, and PropAMM. Report issues
  in them to their owners. An Earn bug in how an engine or the router integrates with them is in
  scope.

The [security and privacy model](docs/earn/architecture/security-and-privacy.md) documents the trust
assumptions, privileged roles, and privacy boundary; behavior it documents as trusted or visible is
not a vulnerability by itself.

## Bug bounty

Tempo Earn has no bug bounty.

## Audits

Completed audits, their scope, and the contracts changed or added since are listed on the
[audits page](docs/earn/audit/README.md).

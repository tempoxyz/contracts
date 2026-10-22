# Contract tests

Tests share the Solidity [implementation rules](../src/AGENTS.md) and their specifications; the
[test map](../docs/development.md#test-map) locates existing coverage.

- Assert observable custody, supply, authority, rounding, and rollback properties, not merely a
  mocked return value. Exercise the production boundary with adversarial venues where relevant.
- A changed implementation is not sufficient reason to weaken an invariant or update the gas
  baseline; explain the intended behavior and account for the difference.
- Keep fixtures in the existing test domains; shared disposable L1/Zone fixtures belong in localnet.

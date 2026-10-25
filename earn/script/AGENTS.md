# Foundry deployment scripts

Read the [shared deployment guide](../deployments/AGENTS.md) and the
[deployment runbook](../docs/operations/deployment.md) before changing lifecycle behavior.

- Scripts implement the shared profile lifecycle; they never introduce a second authored plan or
  bypass typed authority handoffs and source verification.
- Script output is not proof of deployment until the reconciler verifies it onchain; keep output
  compatible with the shared pending-state and provenance boundary.

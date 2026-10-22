# Deployment profiles

[The profile reference](README.md) owns the schema; the shared lifecycle in
[deployments/](../deployments/AGENTS.md) owns reconciliation and verified records.

- Profiles are the sole authored intent. Generated addresses, receipts, and environment state stay
  in adjacent generated records, never back in the profile.
  Consumers use the typed handoff or completed record through `deployments/core/bundle.ts`; never
  parse `deployment.pending.json` or copy reduced record types.

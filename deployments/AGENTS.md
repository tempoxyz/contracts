# Shared deployment tooling

Use [the package reference](README.md), [profiles](../profiles/README.md), and the
[deployment runbook](../docs/deployment/deployment.md) for exports, schemas, and lifecycle behavior.

- `@tempoxyz/earn` owns repository deployment data and generated ABIs, not a parallel client SDK.
  Keep browser-safe code in the deployments export, Node tooling in `/node`, and operational
  metadata in `/operations`.
- Reject malformed input at the parsing boundary with the `core/parse.ts` kit. Reuse
  `core/inspection.ts` and each module's inspection for binding verification, `core/provenance.ts`
  and `core/verify.ts` for record and source evidence, and `chain/zone.ts` for Zone discovery;
  never accept a stale authored sequencer snapshot, and keep policy membership, Portal admission,
  and gateway access separate.
- Before broadcast, match locally compiled shared factory and implementation runtimes to the
  reviewed release; nonempty code is not sufficient. Never invent success or downgrade a
  verification failure.
- Never pass authority keys to Forge. Use the typed authority steps or emit a handoff for the actual
  owner, then verify completion onchain when resuming.
- Steps, recorded addresses, profile fields, capability hooks, subcommands, and engine-kind
  behavior each have one declaration site ([extending](README.md#extending)); never add a step-ID,
  per-contract, or `engine.kind` branch to a generic file. Lint limits `core/` and `chain/` to the
  module registries, and `modules/engines/boundary.test.ts` rejects engine-kind literals.

Dependency pins and exceptions live in [pnpm-workspace.yaml](../pnpm-workspace.yaml). When changing
the viem pin, verify Earn ABI/error parity and Zone behavior.

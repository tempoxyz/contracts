# Application boundary

Rules shared by the React browser, Hono Worker, app catalog, and build configuration. Read the child
guide before editing [browser](src/AGENTS.md) or [Worker](worker/AGENTS.md) code; for `local/`,
also read the [localnet guide](../localnet/AGENTS.md).

- Signing stays with the browser-owned account. Do not introduce server-side signing, custody,
  hardcoded private keys, databases, or arbitrary RPC proxying.
- App work stays within existing contract interfaces. If a flow needs a Solidity change, explain the
  blocker and smallest change, and get explicit authorization unless the request already includes it.
- Split modules at authority and lifecycle boundaries, keep pure domain logic out of UI and
  transport adapters, preserve error identity, and delete superseded implementations.
- The [app deployment runbook](../docs/deployment/app-deployment.md) owns the `deployments/`
  catalog projection and recovery; for shared behavior also read
  [the shared guide](../deployments/AGENTS.md). Catalog scripts run with `app/` as the working
  directory: resolve root artifacts relative to the module's `import.meta.url`, never
  `process.cwd()`.

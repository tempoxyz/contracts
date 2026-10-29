# Browser code

The [browser reference](../../../docs/development/app-browser.md) owns wallet sessions, SDK
workarounds, private settlement, and UI layout rules; read the sections relevant to the change.

- Components and hooks adapt domain modules (`earn/`, `public/`, `private/`, wallet, `deployments/`);
  they never own protocol calls, RPC construction, deployment verification, or session lifecycle.
- Keep public/private paths and each wallet mode's signing path separate. Privy writes use the
  ejected embedded account, never an injected connector or an address-only signer.
- Enable writes only after deployment/chain verification and complete-batch simulation, then submit
  exactly the simulated call array with fresh nonzero bounds and exact approvals.
- Never sign or publish an authorization on mount. Keep L1 and Zone key authorizations scoped to
  their exact chain IDs.
- Never log transaction payloads, digests, signatures, access tokens, wallet IDs, or email
  addresses.
- Mainnet is self-funded; never retry a funding fallback after a transaction may have broadcast.
- Use named functions, `.js` import extensions, and classes only for errors; avoid enums and double
  assertions. Name a namespace import after its file: `import * as Zone from './Zone.js'`.

Update [the typed client examples](public/ClientExamples.test-d.ts) with the
[client documentation](../../../docs/earn/integrations/client.md).

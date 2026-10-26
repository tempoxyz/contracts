# Browser implementation reference

This reference owns the browser's implementation constraints and SDK compatibility notes. Use the
sections relevant to the change; the [browser guide](../../app/src/AGENTS.md) lists only the rules
agents most often break. Paths beginning with `src/` in this document are relative
to `app/`. Dependency pins are owned by `pnpm-workspace.yaml`; recheck workarounds when upgrading.

## Wallet modes and module ownership

- Keep Public and Private transaction paths in separate modules. Do not model them with a boolean inside one transaction function.
- Wagmi owns read clients and the normal passkey account. Privy owns email OTP authentication and the optional embedded wallet.
- Resolve only the embedded Privy Ethereum connector and eject it with `toViemAccount` from `@privy-io/react-auth/tempo`; injected Privy connectors do not support the raw signing required by Tempo.
- Keep wallet modes isolated after shared validation: Privy writes use the ejected embedded account, while normal writes use the Wagmi passkey connector and its short-lived Zone access key.
- Offer Privy only when the selected public chain ID is Tempo mainnet (`4217`) or Tempo testnet
  (`42431`); localnet, unsupported chains, and Zone chain IDs are passkey-only. Gate on
  `hostedEnvironment(chainId)`, whose chain IDs come from viem's chain constants, rather than on
  environment labels.
- Deployless multicall is supported only on Tempo L1. Never enable viem deployless multicall for a
  Zone client; combine Zone reads with supported JSON-RPC batches or a Worker-owned aggregate
  endpoint instead.

- React components orchestrate application state and render UI; they must not own protocol calls,
  RPC construction, transaction preparation, deployment verification, or session lifecycle logic.
  Put those behaviors in their owning domain module and keep hooks and components as adapters.
- Split modules at authority and lifecycle boundaries, not by line count. Prefer one cohesive large
  module over several modules that share hidden state or require callers to understand their
  internals.
- One concept owns each rule. Earn conversion belongs under `src/earn/`, deployment metadata under
  `src/deployments/`, public transaction preparation under `src/public/`, and private Zone behavior
  under `src/private/`. Do not duplicate those rules in UI components. `src/stack/` renders the
  topology, flow canvas, configuration panel, and contract details; `src/workspace/` composes them
  with the action form and balances.
- Engine facts, reads, and copy (labels, contract names, venue description, periphery, exit
  solver, and the deposit quote through `quoteEarnDeposit`) come from `engineDefinitions`. The only
  app-specific engine behavior is extra deployment verification, keyed by engine kind in
  `src/earn/Verification.ts`. Every engine the shared package defines is offered; a choice is
  available when the catalog lists a stack for it.
- Everything the app does differently per Earn action lives in one `actions` entry in
  `src/earn/Actions.ts`: copy, the tokens it spends and returns, which of them the typed amount is
  in, availability, quote, calls, eligibility, canvas direction, and its optional private EarnRouter
  flow. An exact-input action quotes and bounds its minimum output; an exact-output action quotes
  and bounds its maximum input, and `limits` derives both sides and the call bound. Look the action
  up instead of branching on it; an action without a private flow is unavailable privately, and
  private flows are exact-input.
- Use TanStack Query with deployment- and account-specific keys for display reads. Keep display
  history separate from the authenticated state used for preparation and settlement checks.
- Separate deterministic models from rendering. Flow topology, configuration derivation, and other
  pure state transformations must be testable without React, canvas, wallet, or RPC setup.
- Top-level deployment verification only coordinates focused verification modules. Engine-specific,
  access-specific, and write-state checks stay isolated, and any unavailable required verification
  keeps writes disabled.
- Preserve useful error identity across boundaries. Preparation and orchestration code must not
  replace actionable RPC, simulation, or protocol errors with generic wrapper errors.
- Public Earn preparation must submit the exact `calls` array that passed batch simulation. Wagmi's
  generic wallet type erases Tempo's `calls` request extension; keep the narrow `as never`
  adaptation at the `sendTransaction` boundary in `send` (`src/public/Write.ts`), and never rebuild
  the batch through a high-level Earn action after simulation.
- `src/public/ClientExamples.test-d.ts` mirrors the viem API used by the client integration guide.
  Update that fixture with `docs/integrations/client.md` so pinned-SDK API drift fails app typecheck.

## Public transaction preparation

- Derive the asset, share token, and current engine from the selected earnVault and verify them against the selected catalog stack before enabling writes.
- Direct public deposits accept only `earnVault.asset()`. Integrator-token swaps belong to the
  deployment-scoped router's immutable private-asset and backend bindings; the EarnVault owns no
  route policy.
- Direct public deposits must refresh the expected EarnShare output at submission time and pass a nonzero tolerance-adjusted `minEarnShares` to the earnVault; a display-only preview is not transaction protection.
- Deposit previews must use the engine's execution-aware venue quote and the earnVault anchor:
  ERC-4626 `previewDeposit`, or for PropAMM the engine pool's `quoteExactInputFor` for the engine as
  taker and recipient, the exact purchase its deposit executes. Redemption previews must use the earnVault's fee-aware `previewRedeem`; submit the
  resulting nonzero `minAssets` bound only against a deployment advertising bounded redemption.
- Veda deposit previews derive raw BoringVault shares from the selected engine's `shareScale()`,
  safe Accountant base-asset rate plus the yield-streaming Teller's conservative denominator unit,
  and the active Teller's asset-specific share premium before
  applying the EarnVault anchor. Never call ERC-4626 `convertToShares` on a BoringVault.
- Enable public writes only for the current app deployment after relationship verification, selected-chain validation, complete-batch simulation, and deterministic exact approval-plus-action construction. Keep private writes separate.

## Zone identity and private execution

- Browser verification must authenticate every Zone through the Factory/Portal/Inbox binding that
  the shared `discoverZone` (`@tempoxyz/earn/tempo/zone`) checks, and use only the canonical router
  ABI. Do not retain standalone Portal identity branches or read Zone predeploys in app code.
- Address Worker RPC routes by environment slug, not numeric Zone identity alone; a hosted Zone may
  receive a new Zone ID and chain ID after regenesis.
- Before constructing private transactions, read the Zone identity at runtime and verify its Zone ID, chain ID, portal, and messenger against the expected configuration. Do not trust addresses supplied only by UI state or a manifest.
- Immediately before enabling or submitting private actions, require the Portal to report deposits
  active for every token the router can return: EarnShare for deposits and the configured private
  asset for redemptions. Token enablement alone is not callback-output readiness.
- The app refunds router returns to the acting user. Before the Zone withdrawal, it simulates the
  router's return `depositEncrypted` from the router and refuses the action when the Portal answers
  `AccountNotAllowed` for that user; the Portal has no admission getter. Any other simulation
  outcome leaves the action to the callback's own checks, so a refusal is never a guess.
- Deposit to Zone first simulates `depositEncrypted` from the depositor with an empty payload; the
  Portal checks the depositor's admission before anything else, so `AccountNotAllowed` for that
  depositor refuses the deposit with an admission message and any other outcome proceeds.
- Composable Zone withdrawals must provide the complete chain, gas, maximum-fee, priority-fee, and nonce fields explicitly; do not depend on a hosted Zone to fill omitted transaction fields.
- Treat `zone_getZoneInfo` as optional node metadata, not a readiness dependency. Read the Zone
  chain ID and Tempo progress from the authenticated Zone. For every Zone, validate the configured
  sequencers and read token enablement directly from the canonical L1 Portal.
- The app builds the EarnRouter callback with viem's `Actions.earn.privateDeposit.prepare` and
  `privateRedeem.prepare` against Tempo L1, which read only through `eth_*` and recheck the router's
  Zone, EarnVault, asset, EarnShare, and flow bindings, then submits the prepared withdrawal through
  `zone.requestWithdrawalSync`. Do not use the viem Earn `privateDeposit(Sync)` and
  `privateRedeem(Sync)` send actions: they call `zone_getZoneInfo` before delegating to that Zone
  action, and the Worker's Zone route forwards only `eth_*` methods
  ([Worker routes](app-runtime.md#routes-and-limits)).
- Zone privacy gates `AccountKeychain.getKey` by EVM caller, while viem's automatic pending-key
  lookup currently performs that read without `eth_call.from`. A first Zone write must pass its
  pending `keyAuthorization` explicitly, then remove it from the local manager only after the Zone
  transaction confirms; otherwise preparation reverts with the ambiguously decoded `Unauthorized()`
  error or later writes repeat an already-published authorization.
- Retain `requestWithdrawalSync`'s `senderTag` only in memory while the action is pending and use it
  to correlate the L1 Portal's `WithdrawalProcessed` event through the shared
  `waitForWithdrawalProcessed` (`@tempoxyz/earn/tempo/zone`). Fail immediately when
  `callbackSuccess` is false; after Portal success, read this EarnVault's EarnRouter event for the
  action from that processing receipt (`processedRouterEvent`). Never log, persist, or add the sender
  tag to app transaction progress.
- viem's withdrawal sender tag must include `fallbackNonce`; without it, a completed private action
  waits for an L1 event that never matches. Recheck this when moving the viem pin.
- Hosted Zone Portal processing can exceed three minutes even when the callback ultimately
  succeeds. Private settlement polling waits up to ten minutes; do not report an action as failed
  on the shorter transaction-confirmation timeout.
- Zone withdrawals name PATHUSD as their fee token, as private fees are paid in PATHUSD. Do not
  preflight a fixed PATHUSD fee buffer for them; submit the withdrawal and surface the Zone's actual
  transaction error if its fee policy rejects the request. Do refuse before signing when the Zone
  Outbox charges a withdrawal fee: the prepared withdrawal approves only its amount, so the Outbox's
  pull of amount plus fee would revert.
- A private action completes only when the returned token's Zone balance, measured after the
  withdrawal confirms, rises by the router event's full output; Zone funding completes only when
  the funded token rises by the deposited amount (`waitForZoneCredit`). The Zone importing the
  settling L1 block, or any smaller increase, could be an unrelated credit.
- Keep L1 and Zone key authorizations scoped to their exact chain IDs even though the client library describes `0` as chain-global.
- Tempo may persist a pending `KeyAuthorization` even when the transaction that first carried it
  later reverts. Once the Zone reports that key onchain, remove the retained pending authorization
  before the next write; attaching it again reverts with `KeyAlreadyExists`.
- Tempo API Zone balances and account transaction history are display reads only. Keep authenticated Zone RPC reads for runtime verification, transaction preparation, nonce and fee state, and post-settlement execution checks.
- Private balances and history come from the Worker's Tempo API Zone reads
  ([Worker reference](app-runtime.md#tempo-api-zone-reads)). Without them (the local catalog),
  balances fall back to Zone RPC reads and history is unavailable.

## Wallet sessions and fee sponsorship

- Moderato access-key publication is sponsored. Configure the Accounts provider fee payer with `precedence: 'user-first'`, but route local access-key transactions through the canonical `withRelay(..., { policy: 'sign-only' })` transport so the sponsor fills the transaction before the pending access key signs. Post-sign `eth_signRawTransaction` cannot add the sponsor-selected fee token to an envelope whose sender signature already omits it; that leaves the zero-balance passkey paying the fee.
- An environment with a faucet and no chain-compatible sponsor (of the catalog environments, only local)
  self-funds access-key publication and public-to-Zone funding. If either fails specifically for
  insufficient gas funds, fund the passkey from the faucet and retry the same transaction once; do
  not require users to discover the separate faucet action before enabling private mode.
- Hosted L1 encrypted deposits into a configured Zone are sponsored through the same sponsor-fill relay. Pass `feePayer: true` and omit a fixed gas override. Local app flows use the Accounts client directly and omit `feePayer`.
- The normal-wallet session key is unrestricted on both L1 and Zone: omit `limits` and `scopes`
  entirely. It may call any address and spend any token while its one-hour session is active. Use
  that same key for sponsored public-to-Zone funding and private Zone actions so Enable is the only
  root-passkey ceremony. When selecting a retained L1 key, probe an arbitrary self-call so scoped
  keys are not silently reused.
- “Continue with passkey” uses the named register flow, which reuses that locally remembered account; “Use existing passkey” invokes credential discovery for recovery. Do not fold private access-key authorization into this connection flow: the current SDK needs an additional ceremony when creating a new credential, making prompt behavior inconsistent between new and returning users.
- Wagmi restores persisted connector metadata before reconnecting the live connector on page load. Private actions must require `connection.status === 'connected'` and a callable `connector.getProvider`; a restored address alone is not a signable connection.
- Restore normal-mode private sessions only after that live connector is available. Reuse the
  already-published Accounts access key from IndexedDB, then verify the Zone key and deployment
  bindings without signing or writing. Missing, expired, revoked, or mismatched state must fall
  back to the explicit Enable flow; never call `wallet_authorizeAccessKey` or publish a transaction
  on mount.
- In normal mode, route browser-passkey traffic through `withRelay(http(rpcUrl), http(sponsorUrl), { policy: 'sign-only' })`, configure the passkey provider with `{ url: sponsorUrl, precedence: 'user-first' }`, and pass `feePayer: true` on every sponsored user transaction. Private local-access-key writes use the same direct-RPC plus sponsor relay transport; do not use `provider.getClient({ feePayer })` as its base transport because that re-enters the provider.
- Map hosted sponsors only when the fee payer is backed by the same L1. Tempo testnet uses
  `https://sponsor.moderato.tempo.xyz`; never reuse it for a different L1 based on a label alone.
- Public Earn writes never retry. Never apply the faucet fallback to mainnet or after a
  transaction may have broadcast.
- Privy writes are self-funded and must pass the complete ejected viem account in public action
  parameters. Passing only its address overrides the client's hoisted local account, causing viem
  to send `wallet_sendTransaction` to the read-only L1 RPC proxy. Privy's Tempo signer recognizes
  the public Tempo chain but not Zone chain IDs, so Zone writes must serialize with viem, sign the
  digest with the account's raw `sign`, and serialize the signature locally.

## Local browser acceptance

- `pnpm dev:local` lists the disposable stack with public and private modes. Its browser passkey
  is created after deployment and cannot be prelisted, so the local stack requests an open EarnShare
  policy; local E2E stays protected by default so access-policy coverage is unchanged.
- Local writes use the browser passkey with the generated chain ID and the direct local L1 RPC,
  without the sponsor relay or `feePayer`; the L1 faucet funds access-key publication.
- The browser never calls a local Zone RPC directly: the Worker proxies the local Zone's public
  RPC ([Worker routes](app-runtime.md#routes-and-limits)).
- To exercise private flows, give the passkey the local private asset by calling the
  permissionless fixture funder that `pnpm dev:local` prints (`fund(token, recipient, amount)`)
  from any faucet-funded local account, then use Enable, Deposit to Zone, private deposit, and
  private redeem. Rerun these flows, the app tests, and typecheck after changing the private path.

## UI behavior

- Use Regen primitives and semantic tokens before adding custom controls or CSS.
- Route transaction progress through `TransactionToastProvider`; it logs each failed update's
  original `error` to the developer console once, so error updates must retain it for the stack and
  nested cause. Never log transaction payloads, digests, signatures, access tokens, wallet IDs, or
  email addresses.
- Keep the configuration inspector in screen space above the topology transform so zooming or
  panning never scales or moves its controls. Topology nodes stay fixed while the canvas supports
  drag-to-pan only within a node-sized margin around the graph. Users never author deployment
  configurations that do not exist.
- Regen tooltips render through transformed `data-base-ui-portal` positioners without a tooltip
  ARIA role. Configuration tooltip labels must retain the `configuration-tooltip` marker so
  `app/src/styles.css` can keep their positioner above the inspector and wrap their copy.
  Compact inspector choices must retain visible default and selected surfaces.
- Normal mode emits separate setup toasts for each passkey approval used to enable a Zone. Privy
  mode connects its embedded wallet directly without publishing an access key.
- Treat the React Flow canvas as the primary Earn workspace. Keep configuration in its top-left
  screen-space panel and a right rail with vault interactions followed by the same-width compact
  balance panel. Render contract and routing details after the full canvas, with the Zone and Vault
  cards side by side on wide screens. On wide screens, keep React Flow full-bleed behind intrinsically
  sized floating panels; never inset the canvas into full-height inspector or right-rail columns.
  Measure the visible overlays and fit the selected action's path once into the unobstructed area
  with asymmetric `fitView` padding. Do not render the balance panel until a wallet is connected.
- Keep the Zone deposit trigger in the balance panel and expand its form immediately below the
  panel actions so the requested cross-network transfer remains visually attached to its trigger.
- Public/private access is configured only in the canvas configuration inspector. The vault
  interaction panel consumes that selection and must not duplicate an access or transaction-visibility
  control.
- Keep Moderato status and wallet controls in the page-header navigation opposite “Tempo Earn Playground”; do not add a redundant product heading above the workspace.
- The balance panel shows balances in one token-by-network table, with one row per configured token
  and columns for public Tempo L1 and the private Zone. Keep the faucet and public-to-Zone transfer
  actions in that panel without duplicating token labels. Keep private activity visually subordinate
  to the balance table by using the compact label typography for its heading, states, and
  transaction rows.
- The balance table lists every configured token, including the private route asset and the
  PATHUSD vault asset, followed by EarnShare. `app/deployments/tokens.ts` owns that display list and
  token metadata; keep it separate from the private mode's one `privateAsset` so PATHUSD does not
  become a private router input.
- Read the engine kind from the selected stack, never from its asset. Public actions are Deposit and Redeem, and the composer displays the relevant asset balance without a MAX action.
- Initialize the builder engine from the selected registered profile. A Veda profile with Teller
  deposit and withdrawal permissions is live for synchronous actions even when it has no Queue;
  describe only its asynchronous exits as unavailable.
- Keep the configuration inspector limited to deployed yield source and public/private access.
  Routing is derived from the selected access path. Keep venue metadata, action capabilities, fees,
  permissionless contributions, and control roles out of this configuration surface; show verified
  architecture details in the topology and contract details instead.
- Resolve stack support through `Support.resolve` in `src/deployments/Support.ts` across the
  complete public environment catalog. It returns `{ deploymentId }` for a selectable stack or
  `{ message }` explaining where the choice is available or why it is not; UI controls render that
  result instead of reimplementing deployment capability checks.
- Private actions use the deployment's single private asset (the router's fixed input), shown as a
  label rather than a token choice. Its name, symbol, and decimals come from the catalog stack's
  `privateAssetMetadata`; deployment verification checks its decimals against the live token.
- Deposit to Zone offers the tokens `zoneFundingTokens` (`app/deployments/tokens.ts`) returns: the
  private asset, plus PATHUSD when it is one of the deployment's balance tokens, so a user can fund
  the PATHUSD that private Zone fees are paid in.
- `network.explorerUrl` is optional: local stacks have none, so address and transaction links are
  hidden rather than pointed at the RPC.
- Keep registered contract addresses out of the builder controls and scaled node boxes. Attach
  addresses to their topology nodes, reveal the selected node's copyable address beside its
  screen-space description, and keep the full contract list in `src/stack/ProductArchitecture.tsx`. Never invent
  addresses for conceptual nodes. Put builder section guidance in Regen tooltips on accessible info
  buttons instead of persistent callouts.
- When the conversion-pool topology node is selected, derive its pool, customer ID, and fixed pair
  from the selected EarnRouter through `src/private/Liquidity.ts`, reading `liquidityStatus()`
  through the environment's L1 RPC route.
  Refresh only while that focus panel is mounted; do not persist pool inventory in the public app
  catalog.

## Compatibility and tests

- Tests cover security properties and stated requirements only; an extracted module does not need
  its own test. Test protocol logic in its pure domain module or through the nearest real
  application boundary, never only through component tests.
- Use inline snapshots for deterministic structured results and exact errors when snapshots make the contract clearer.
- Keep `@base-ui/react` pinned to `1.4.1` in the workspace overrides while Regen 0.5 imports `OTPFieldPreview`; newer Base UI releases removed that export and break the production bundle. Audit with `pnpm build` when upgrading Regen.
- Keep Regen's transitive Base UI, `use-sync-external-store`, and `eventemitter3` dependencies in `optimizeDeps.include`; use Vite's nested dependency syntax for `regen-ui > ox > eventemitter3`. The Regen source alias bypasses Vite's dependency scan, so missed CommonJS dependencies load as browser ESM and React never mounts.
- Keep `ssr: true` on `createWalletConfig`. Wagmi 3 otherwise hydrates during render, and changing wallet modes causes its connection-store update to trigger React's cross-component render warning.

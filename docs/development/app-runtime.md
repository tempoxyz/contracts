# App Worker and build reference

This reference owns the Hono Cloudflare Worker in `app/worker/` (its routes, limits,
configuration, and secrets) and the app's build and Cloudflare deployment tooling. Browser signing,
sessions, and UI live in [the browser reference](app-browser.md); the browser catalog the Worker
serves is owned by [app deployment](../operations/app-deployment.md).

## Routes and limits

The Worker answers these routes (`app/worker/index.ts`) and serves the static app for every other
`GET`; `run_worker_first` in `app/wrangler.jsonc` sends every request except `/assets/*` through it
first.

| Route                                                                   | Behavior                                                                                                                                                         |
| ----------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GET /health`                                                           | `{ "status": "ok" }`                                                                                                                                             |
| `GET /api/config`                                                       | The browser configuration: catalog environments with RPC URLs, sponsor URLs, Privy ID, and `tempoApiZoneReads`; 503 `missing_environment` without `PRIVY_APP_ID` |
| `POST /api/environments/:id/l1-rpc`, `.../zone-rpc`                     | JSON-RPC proxy to the environment's L1 or Zone (`app/worker/rpc-proxy.ts`)                                                                                       |
| `POST /api/environments/:id/zones/:zoneId/balances`, `.../transactions` | [Tempo API Zone reads](#tempo-api-zone-reads) (`app/worker/zone-reads.ts`)                                                                                       |

- Every POST body must be `application/json` (415 otherwise) and is read incrementally up to its
  route's limit before parsing: 1 MB for RPC, 1 KiB for Zone reads.
- An RPC body must be well-formed JSON-RPC 2.0. The Zone route forwards only `eth_*` methods; the L1
  route also forwards `tempo_*` and `faucet_*`.
- A Zone-read body is exactly `{ account, deploymentId }`, with a `deploymentId` of at most 128
  characters naming a private deployment in that environment and Zone.
- For a hosted environment, `/api/config` rewrites both RPC URLs to the same-origin proxy routes.
  For the local catalog, the L1 RPC stays the direct local URL and the Zone RPC is the proxy route
  over the local Zone's public RPC: its private RPC needs per-account authorization tokens and
  neither local Zone RPC answers CORS preflight, so the browser never calls either directly.

## Configuration and secrets

- Wrangler's `secrets.required` replaces `.env` secret inference. List every Worker secret there in
  the top-level, preview, and production environments; an undeclared secret is omitted from the
  Worker binding, leaving the same-origin proxy without its required upstream credential.
- Fresh Git worktrees do not inherit ignored `app/.env.local`. Without `TEMPO_API_KEY`, hosted RPC
  routes fail, which leaves deployment verification unavailable and makes passkey registration
  surface a generic `HTTP request failed` error. Production builds load ignored
  `app/.env.production` from the same template, and deployed Worker settings are Cloudflare
  secrets.
- Keep `TEMPO_API_KEY` Worker-only. The Worker attaches it only to Tempo API RPC URLs derived from
  the selected environment's registered L1 or Zone chain ID and to Tempo API's `/v1/transactions`
  history endpoint; the browser must not select an upstream or receive the key. Preview and
  production configure the key as a Worker secret with the matching L1 faucet and Zone write
  scopes, because the same proxy funds test accounts and broadcasts signed private transactions.
- Put local Worker secrets in ignored `app/.env.local`; Wrangler resolves that file beside `app/wrangler.jsonc`. Do not create `.dev.vars`, because its presence takes precedence over and disables Wrangler's default `.env` file discovery.
- A hosted network's fee sponsor is the `sponsorUrl` of its `hostedEnvironments` entry. The Worker
  serves it only for catalog environments on that chain, never for a local catalog, and adds its
  origin to the CSP `connect-src`.
- Every hosted L1 and Zone RPC uses Tempo API with the registered chain ID, but `pnpm dev:local`
  must preserve the generated disposable networks' direct RPC URLs; never route a local catalog
  through Tempo API.
- `worker-configuration.d.ts` is generated and ignored: `pnpm --filter app check:types` runs
  `wrangler types` before typechecking, and `pnpm --filter app gen:types` regenerates it alone for
  editors. Never edit or commit it.
- Select preview or production with `CLOUDFLARE_ENV` during both the Vite build and Wrangler deploy. The Cloudflare Vite plugin redirects Wrangler to a flattened generated config, so adding only `wrangler deploy --env ...` after a default build deploys the wrong variables.
- Vite development injects the React Refresh preamble inline and connects its HMR client over a
  localhost WebSocket. The CSP permits inline scripts only when `ENVIRONMENT=development`, and
  localhost `connect-src` sources (without `upgrade-insecure-requests`) only in development or for
  the local catalog; preview and production retain the strict policy.

## Tempo API Zone reads

The Worker serves private balance and transaction-history display reads from Tempo API. Balances
are one batched Zone `eth_call` of `balanceOf` per token, sent through Tempo API from the account; history is Tempo API `/v1/transactions`
for the account on the Zone's chain ID with `include=receipt`, the newest 10, with the response
capped at 256 KiB. Each Tempo API call times out after 10 seconds.

Derive balance-read coverage only through `app/deployments/tokens.ts`: the Worker and UI both
require the selected deployment's EarnShare, asset, and private asset and must not reconstruct that
set independently. Tempo API gives the Worker unredacted Zone access, so the browser-supplied
account address only limits accidental cross-account responses; it is not end-user authorization.
`pnpm dev:local` disables Tempo API
reads because the hosted API cannot reach its disposable Zone; the browser then reads balances over
Zone RPC and shows no history.

## Build

- `pnpm --filter app build` and `build:preview` set `CLOUDFLARE_ENV` to `production` or `preview`.
  The Worker bundle is one module (`codeSplitting: false` in `app/vite.config.ts`) because preview
  uploads it with `--no-bundle`.
- `pnpm --filter app test` runs the unit suite and then the Worker pool
  (`@cloudflare/vitest-pool-workers`).

## Cloudflare deployment tooling

- Keep Cloudflare configuration in `app/wrangler.jsonc`; comments should explain account, environment, asset-routing, or security choices that are not obvious from the values.
- Wrangler action `preCommands` runs each input line as a separate shell command and automatically prefixes only lines that begin with `wrangler` with the configured package-manager exec command. Keep compound preview guards in one folded command beginning with `wrangler`; do not split shell state or control flow across `preCommands` lines.
- Manual deployments use `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`; never commit either
  value. Which CI jobs receive the organization-scoped `DEV_CLOUDFLARE_*` secrets, and how preview
  deploys a trusted Worker with PR static assets, is in
  [continuous integration](../development.md#continuous-integration).

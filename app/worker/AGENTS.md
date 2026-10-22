# Worker transport boundary

The Worker handles transport and display data; the browser owns signing. Routes, limits,
configuration, and secrets are in the [Worker reference](../../docs/development/app-runtime.md).

- Never accept browser-supplied upstreams, credentials, or Zone authorization headers, and never
  expose credentials in responses, logs, errors, or browser configuration.
- A browser-supplied account address scopes display reads; it is not end-user authorization.
- Enforce route-specific byte limits while streaming, before parsing or forwarding, and keep explicit
  route and method allowlists.

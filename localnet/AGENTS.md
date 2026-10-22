# Disposable chain lifecycle

The [localnet reference](../docs/development/localnet.md) owns the details, including the
[image-pair upgrade](../docs/development/localnet.md#foundry-and-containers); exact pins live in
`src/config.ts` and `fixtures/runtime-lock.json`.

- Consumers run inside the `Environment.run` ready callback; a returned environment would expose
  stopped containers, so the layer (`src/layer.ts`) holds `ready` open until its `down()`.
- Keep generic network/fixture/deployment behavior here; app catalog/Vite behavior belongs in
  `app/local/`, E2E checks in `e2e/harness/local.ts`, and no customer policy belongs in this
  package.
- Only the browser consumer may request open access, and synthetic fixtures never stand in for
  production venues.

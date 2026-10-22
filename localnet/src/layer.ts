import { stringify, type Address } from 'viem'

import * as Environment from './environment.js'
import type * as Deployment from './deployment.js'

/**
 * The `@tempoxyz/localnet` layer contract, restated structurally so Earn does not depend on that
 * package. This v0 layer starts its own L1 and Zone, so it also writes the `network` section.
 */
export type Layer<Sections = Record<string, unknown>> = {
  name: string
  after?: string[]
  provides?: string[]
  up(context: {
    signal: AbortSignal
    log: (message: string) => void
    runId: string
  }): Promise<{ sections: Sections; down: () => Promise<void> }>
}

export type Account = Environment.Account

export type NetworkSection = {
  l1: { chainId: number; rpcUrl: string; wsUrl: string }
  zones: {
    id: number
    chainId: number
    portal: Address
    rpcUrl: string
    privateRpcUrl: string
  }[]
  /** Fresh keys per run; Earn signs with these and consumers may too. */
  accounts: Record<keyof Environment.State['accounts'], Account>
  images: { l1: string; zone: string }
}

type Json<T> = T extends bigint
  ? string
  : T extends readonly (infer Item)[]
    ? Json<Item>[]
    : T extends object
      ? { [Key in keyof T]: Json<T[Key]> }
      : T

/** `Deployment.State` with bigints as decimal strings. */
export type EarnSection = { version: 1; deployment: Json<Deployment.State> }

export type Sections = { network: NetworkSection; earn: EarnSection }

/**
 * Runs `Environment.run` and holds it open as a localnet layer: `up` resolves once Earn is
 * deployed, and `down` releases `ready`, which stops the containers.
 */
export function earn(options: earn.Options = {}): Layer<Sections> {
  return {
    name: 'earn',
    provides: ['network', 'earn'],
    async up({ runId, signal }) {
      signal.throwIfAborted()
      const release = deferred<void>()
      const ready = deferred<Sections>()
      const run = Environment.run({
        ...options,
        consumer: `localnet run ${runId}`,
        containers: {
          labels: { 'tempo.localnet.run': runId, 'tempo.localnet.layer': 'earn' },
          name: `tempo-localnet.${runId}`,
        },
        ready: async (environment) => {
          signal.throwIfAborted()
          ready.resolve(sections(environment))
          await release.promise
        },
      })
      run.catch(ready.reject)
      const down = async () => {
        release.resolve()
        await run
      }
      signal.addEventListener('abort', () => release.resolve(), { once: true })
      return { sections: await ready.promise, down }
    },
  }
}

export declare namespace earn {
  type Options = Pick<
    Environment.run.Options<void>,
    'access' | 'earnProfile' | 'engineKind' | 'sameAssetRoute'
  >
}

function deferred<T>() {
  let resolve!: (value: T) => void
  let reject!: (reason: unknown) => void
  const promise = new Promise<T>((onResolve, onReject) => {
    resolve = onResolve
    reject = onReject
  })
  return { promise, reject, resolve }
}

function sections(environment: Environment.State): Sections {
  const { accounts, deployment, l1, zone } = environment
  return {
    network: {
      l1: {
        chainId: deployment.chainId,
        rpcUrl: l1.rpcUrl,
        wsUrl: l1.rpcUrl.replace(/^http/, 'ws'),
      },
      zones: [
        {
          id: deployment.zoneId,
          chainId: deployment.zoneChainId,
          portal: deployment.zonePortal,
          rpcUrl: zone.publicRpcUrl,
          privateRpcUrl: zone.rpcUrl,
        },
      ],
      accounts,
      images: { l1: l1.image, zone: zone.image },
    },
    earn: {
      version: 1,
      deployment: JSON.parse(stringify(deployment)) as Json<Deployment.State>,
    },
  }
}

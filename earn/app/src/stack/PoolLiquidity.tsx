import { useQuery } from '@tanstack/react-query'
import type { PublicNetwork } from '@tempoxyz/contracts/deployments'
import { useMemo } from 'react'
import { formatUnits } from 'viem'

import type { CatalogStack } from '../../deployments/catalog.js'
import { actions } from '../earn/Actions.js'
import { ExplorerAddress, shortHex } from '../Explorer.js'
import * as Liquidity from '../private/Liquidity.js'
import * as Tempo from '../Tempo.js'

/** Reads and displays the live readiness and inventory of the router's DirectPropAMM pool. */
export function PoolLiquidity(options: PoolLiquidity.Props) {
  const client = useMemo(() => Tempo.createClient(options.network), [options.network])
  const query = useQuery({
    queryFn: () => Liquidity.readSnapshot(client, options.deployment),
    queryKey: [
      'router-pool-liquidity',
      options.network.chainId,
      options.deployment.id,
      options.deployment.contracts.earnRouter,
    ],
    refetchInterval: 15_000,
  })

  return (
    <section
      aria-label="Conversion pool live liquidity"
      aria-live="polite"
      className="flex min-w-0 flex-col gap-3 border border-border bg-surface px-3 py-3"
    >
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex items-center gap-2">
          <p className="text-label-12 font-medium">Live pool liquidity</p>
          {query.isFetching && query.data ? (
            <span className="text-label-12 text-foreground-tertiary">Refreshing…</span>
          ) : null}
        </div>
        {query.data ? (
          <span className="inline-flex min-w-0 items-center gap-2 text-label-12">
            <span className="text-foreground-tertiary">Pool</span>
            <ExplorerAddress
              address={query.data.pool}
              className="max-w-[18rem] text-foreground"
              copy
              explorerUrl={options.network.explorerUrl}
              min={6}
            />
          </span>
        ) : null}
      </div>

      {query.data ? (
        <PoolLiquidityValues explorerUrl={options.network.explorerUrl} snapshot={query.data} />
      ) : (
        <p className="text-label-12 text-foreground-secondary">
          {query.error ? 'Live pool liquidity unavailable.' : 'Reading live pool liquidity…'}
        </p>
      )}
    </section>
  )
}

export declare namespace PoolLiquidity {
  type Props = {
    deployment: CatalogStack
    network: PublicNetwork
  }
}

/** Presents an already-read pool readiness and inventory snapshot. */
function PoolLiquidityValues(options: PoolLiquidityValues.Props) {
  const { explorerUrl, snapshot } = options
  const reason = Liquidity.unavailableReason(snapshot.status)
  return (
    <div className="flex min-w-0 flex-col gap-3">
      <p className="text-label-12 text-foreground-secondary">
        {reason
          ? `Private conversion unavailable: ${reason}.`
          : 'Ready to convert 1:1 at par, up to the inventory below.'}
      </p>
      <div className="grid min-w-0 gap-3 sm:grid-cols-3">
        {snapshot.inventory.map((side) => (
          <div className="flex min-w-0 flex-col gap-1 border-l border-border pl-3" key={side.flow}>
            <span className="text-label-12 text-foreground-secondary">
              {side.symbol} for {actions[side.flow].noun}s
            </span>
            <strong className="text-label-13 font-medium">
              {formatAmount(side.balance, side.decimals)} {side.symbol}
            </strong>
            <ExplorerAddress
              address={side.token}
              className="max-w-full text-label-12 text-foreground-tertiary"
              copy
              explorerUrl={explorerUrl}
              min={4}
            />
          </div>
        ))}
        <div className="flex min-w-0 flex-col gap-1 border-l border-border pl-3">
          <span className="text-label-12 text-foreground-secondary">Customer ID</span>
          <code className="truncate text-label-12" title={snapshot.customerId}>
            {shortHex(snapshot.customerId)}
          </code>
        </div>
      </div>
    </div>
  )
}

declare namespace PoolLiquidityValues {
  type Props = {
    explorerUrl?: string | undefined
    snapshot: Liquidity.Snapshot
  }
}

function formatAmount(value: bigint, decimals: number) {
  const [whole = '0', fraction] = formatUnits(value, decimals).split('.')
  const grouped = whole.replace(/\B(?=(\d{3})+(?!\d))/g, ',')
  return fraction ? `${grouped}.${fraction}` : grouped
}

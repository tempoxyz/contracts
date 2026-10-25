import type { PublicNetwork } from '@tempoxyz/earn/deployments'
import { useMemo, useState, type ReactNode } from 'react'

import type { CatalogStack } from '../../deployments/catalog.js'
import type { Access } from '../deployments/Support.js'
import type { Action } from '../earn/Actions.js'
import { ExplorerAddress } from '../Explorer.js'
import { StackFlowCanvas } from './StackFlowCanvas.js'
import * as Topology from './Topology.js'
import { PoolLiquidity } from './PoolLiquidity.js'

/** Visualizes the live custody and capability shape of the selected stack and access path. */
export function StackPreview(options: StackPreview.Props) {
  const { access, action, deployment } = options
  const topology = useMemo(() => Topology.create({ access, deployment }), [access, deployment])
  const activeNodeIds = useMemo(() => flowNodeIds(access), [access])
  const [selectedId, setSelectedId] = useState<string>()
  const selectedNode = topology.nodes.find((node) => node.id === selectedId)
  const topologyKey = `${access}:${deployment.id}:${action}`

  const context = selectedNode ? (
    <div className="flex max-w-2xl shrink-0 flex-col gap-3 border border-border bg-surface p-3 shadow-lg">
      <div aria-live="polite" className="flex flex-wrap items-center gap-x-3 gap-y-1">
        <p className="text-label-12 text-foreground-secondary">
          {`${selectedNode.label} · ${Topology.categoryLabels[selectedNode.category]} — ${selectedNode.detail}`}
        </p>
        {selectedNode.address ? (
          <span className="inline-flex min-w-0 items-center gap-2 text-label-12">
            <span className="text-foreground-tertiary">Contract</span>
            <ExplorerAddress
              address={selectedNode.address}
              className="max-w-[20rem] text-foreground"
              copy
              explorerUrl={options.network.explorerUrl}
              min={6}
            />
          </span>
        ) : null}
      </div>

      {selectedNode.id === 'swaps' ? (
        <PoolLiquidity deployment={deployment} network={options.network} />
      ) : null}
    </div>
  ) : undefined

  return (
    <div aria-label="Configured Earn stack" className="min-w-0">
      <StackFlowCanvas
        action={action}
        activeNodeIds={activeNodeIds}
        balances={options.balances}
        context={context}
        inspector={options.inspector}
        interaction={options.interaction}
        key={topologyKey}
        onSelect={setSelectedId}
        topology={topology}
      />
    </div>
  )
}

export declare namespace StackPreview {
  type Props = {
    access: Access
    action: Action
    balances?: ReactNode | undefined
    deployment: CatalogStack
    inspector: ReactNode
    interaction: ReactNode
    network: PublicNetwork
  }
}

function flowNodeIds(access: Access) {
  const ids = new Set(['users', 'earnVault', 'engine', 'venue', 'earn-share'])
  if (access === 'private') {
    ids.add('zone')
    ids.add('earn-router')
    ids.add('swaps')
  } else ids.add('asset')
  return ids
}

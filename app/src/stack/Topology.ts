import type { Address } from 'viem'
import { engineDefinitions, type PublicEarnStack } from '@tempoxyz/earn/deployments'

import type * as Support from '../deployments/Support.js'

/** Width of one topology node. */
export const stackNodeWidth = 230

/** Height of one topology node. */
export const stackNodeHeight = 96

const horizontalGap = 160
const verticalGap = 56

export type StackNode = {
  address?: Address | undefined
  category: StackNodeCategory
  detail: string
  id: string
  label: string
  x: number
  y: number
}

export type StackNodeCategory = 'user' | 'metavault-core' | 'metavault-peripheral' | 'external'

/** Human-readable labels for topology node categories. */
export const categoryLabels: Record<StackNodeCategory, string> = {
  external: 'External venue / rail',
  'metavault-core': 'Earn core',
  'metavault-peripheral': 'Earn module',
  user: 'User / value flow',
}

type StackEdge = {
  from: string
  label: string
  to: string
}

export type StackTopology = {
  edges: readonly StackEdge[]
  height: number
  nodes: readonly StackNode[]
  width: number
}

/** Builds a staged topology containing every selected core and optional component. */
export function create(options: create.Options): StackTopology {
  const { access, deployment } = options
  const definition = engineDefinitions[deployment.engineKind]
  const horizontalStride = stackNodeWidth + horizontalGap
  const verticalStride = stackNodeHeight + verticalGap
  const mainY = verticalStride
  const main: Omit<StackNode, 'x' | 'y'>[] = [
    {
      category: 'user',
      detail: 'Depositors and integrators',
      id: 'users',
      label: 'Users',
    },
  ]
  if (access === 'private') {
    main.push(
      {
        category: 'external',
        detail: 'Private balance rail',
        id: 'zone',
        label: 'Tempo Zone',
      },
      {
        address: deployment.contracts.earnRouter,
        category: 'metavault-peripheral',
        detail: 'Zone-scoped private routing',
        id: 'earn-router',
        label: 'SingleZoneEarnRouter',
      },
    )
  }
  main.push(
    {
      address: deployment.contracts.earnVault,
      category: 'metavault-core',
      detail: 'Issuer and accounting',
      id: 'earnVault',
      label: 'EarnVault',
    },
    {
      address: deployment.contracts.engine,
      category: 'metavault-core',
      detail: 'Holds venue shares',
      id: 'engine',
      label: definition.engineContract,
    },
    {
      address: deployment.contracts.venue,
      category: 'external',
      detail: definition.venueDetail,
      id: 'venue',
      label: definition.venueLabel,
    },
  )

  const nodes: StackNode[] = main.map((node, index) => ({
    ...node,
    x: index * horizontalStride,
    y: mainY,
  }))
  const earnVault = nodes.find((candidate) => candidate.id === 'earnVault')!
  const engineNode = nodes.find((candidate) => candidate.id === 'engine')!
  const earnRouter = nodes.find((candidate) => candidate.id === 'earn-router')
  const edges: StackEdge[] = main.slice(0, -1).map((candidate, index) => ({
    from: candidate.id,
    label: edgeLabel(candidate.id, access),
    to: main[index + 1]!.id,
  }))

  nodes.push({
    address: deployment.contracts.earnShare,
    category: 'metavault-core',
    detail: 'Native TIP-20 ownership',
    id: 'earn-share',
    label: 'EarnShare',
    x: earnVault.x,
    y: 0,
  })
  edges.push({ from: 'earnVault', label: 'mints / burns', to: 'earn-share' })
  nodes.push({
    address: deployment.contracts.earnFees,
    category: 'metavault-core',
    detail: 'Positive-accrual fee accounting',
    id: 'earn-fees',
    label: 'EarnFees',
    x: earnVault.x,
    y: earnVault.y + verticalStride,
  })
  edges.push({ from: 'earnVault', label: 'checkpoints accrual', to: 'earn-fees' })

  const routingAnchor = earnRouter ?? earnVault
  if (access === 'private') {
    nodes.push({
      category: 'metavault-peripheral',
      detail: 'Immutable 1:1 par conversion',
      id: 'swaps',
      label: 'DirectPropAMM pool',
      x: routingAnchor.x,
      y: routingAnchor.y + verticalStride,
    })
    edges.push({ from: 'swaps', label: 'converts assets', to: routingAnchor.id })
  } else {
    nodes.push({
      address: deployment.contracts.asset,
      category: 'user',
      detail: 'Base asset',
      id: 'asset',
      label: deployment.expectedMetadata.asset.symbol,
      x: Math.max(0, routingAnchor.x - horizontalStride),
      y: routingAnchor.y + verticalStride,
    })
    edges.push({ from: 'asset', label: 'direct', to: routingAnchor.id })
  }

  nodes.push({
    category: 'user',
    detail: 'Adds backing without EarnShare',
    id: 'contributors',
    label: 'Contributors',
    x: access === 'private' ? earnVault.x : Math.max(0, earnVault.x - horizontalStride),
    y: earnVault.y + verticalStride * 2,
  })
  edges.push({ from: 'contributors', label: 'adds backing', to: 'earnVault' })

  nodes.push({
    category: 'metavault-peripheral',
    detail: 'Operator, guardian, and janitor',
    id: 'controls',
    label: 'Control roles',
    x: engineNode.x,
    y: earnVault.y + verticalStride,
  })
  edges.push({ from: 'controls', label: 'governs', to: 'earnVault' })

  if (definition.exitSolver) {
    nodes.push({
      category: 'metavault-peripheral',
      detail: 'Solves and forwards queued exits',
      id: 'solver',
      label: definition.exitSolver,
      x: engineNode.x,
      y: earnVault.y + verticalStride * 2,
    })
    edges.push({ from: 'solver', label: 'supports exits', to: 'engine' })
  }

  const height = Math.max(...nodes.map((candidate) => candidate.y + stackNodeHeight))
  return {
    edges,
    height,
    nodes,
    width: Math.max(...nodes.map((candidate) => candidate.x + stackNodeWidth)),
  }
}

export declare namespace create {
  type Options = {
    access: Support.Access
    deployment: PublicEarnStack
  }
}

function edgeLabel(id: string, access: Support.Access) {
  if (id === 'users') return access === 'private' ? 'enter privately' : 'deposit / redeem'
  if (id === 'zone') return 'authenticated callback'
  if (id === 'earn-router') return 'bounded Earn action'
  if (id === 'earnVault') return 'moves backing'
  return 'venue shares'
}

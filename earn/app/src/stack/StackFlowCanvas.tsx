import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import {
  applyNodeChanges,
  Background,
  BackgroundVariant,
  BaseEdge,
  Controls,
  EdgeLabelRenderer,
  Handle,
  Position,
  ReactFlow,
  getSmoothStepPath,
  useReactFlow,
  MarkerType,
  type Edge as ReactFlowEdge,
  type EdgeProps,
  type EdgeTypes,
  type NodeChange,
  type NodeProps,
  type NodeTypes,
  type Node as ReactFlowNode,
} from '@xyflow/react'
import { PanelLeftClose, SlidersHorizontal } from 'lucide-react'
import { Button, cx } from 'regen-ui'

import { actions, type Action } from '../earn/Actions.js'
import * as Topology from './Topology.js'

const nodeTypes = {
  stack: StackFlowNodeView,
} satisfies NodeTypes

/** Visual treatment for each topology node category. */
const categoryClassNames: Record<Topology.StackNodeCategory, string> = {
  external: 'border-[var(--stack-external-border)] bg-[var(--stack-external)]',
  'metavault-core': 'border-[var(--stack-core-border)] bg-[var(--stack-core)]',
  'metavault-peripheral': 'border-[var(--stack-peripheral-border)] bg-[var(--stack-peripheral)]',
  user: 'border-[var(--stack-user-border)] bg-[var(--stack-user)]',
}

const edgeTypes = {
  stack: StackFlowEdgeView,
} satisfies EdgeTypes

export function StackFlowCanvas(options: StackFlowCanvas.Props) {
  const { action, activeNodeIds, topology } = options
  const [inspectorOpen, setInspectorOpen] = useState(true)
  const canvasElement = useRef<HTMLDivElement>(null)
  const leftOverlayElement = useRef<HTMLDivElement>(null)
  const rightOverlayElement = useRef<HTMLElement>(null)
  const [padding, setPadding] = useState<FlowViewportPadding>(defaultPadding)
  const [nodes, setNodes] = useState(() => flowNodes(topology, activeNodeIds))
  // Only selection changes apply: the topology layout is fixed.
  const onNodesChange = useCallback((changes: NodeChange<Node>[]) => {
    setNodes((current) =>
      applyNodeChanges(
        changes.filter((change) => change.type !== 'position'),
        current,
      ),
    )
  }, [])
  const edges = useMemo(
    () => flowEdges({ action, activeNodeIds, topology }),
    [action, activeNodeIds, topology],
  )

  // On desktop the configuration and action panels overlay the canvas, so the fitted view keeps
  // the selected path clear of them.
  useEffect(() => {
    const canvas = canvasElement.current
    const left = leftOverlayElement.current
    const right = rightOverlayElement.current
    if (!canvas || !left || !right) return

    const update = () => {
      const desktop = canvas.getBoundingClientRect().width >= 1024
      const next = {
        ...defaultPadding,
        left: desktop ? left.getBoundingClientRect().width + margin : margin,
        right: desktop ? right.getBoundingClientRect().width + margin : margin,
      }
      setPadding((current) =>
        current.left === next.left && current.right === next.right ? current : next,
      )
    }
    const observer = new ResizeObserver(update)
    for (const element of [canvas, left, right]) observer.observe(element)
    update()

    return () => observer.disconnect()
  }, [inspectorOpen])

  return (
    <div
      aria-label="Interactive onchain topology"
      className="stack-flow-canvas relative flex min-w-0 flex-col overflow-hidden border border-border bg-pane"
      ref={canvasElement}
      role="region"
    >
      <div className="relative z-20 grid min-w-0 gap-3 p-3 lg:pointer-events-none lg:absolute lg:inset-x-0 lg:top-0 lg:grid-cols-[240px_minmax(0,1fr)_300px] xl:grid-cols-[292px_minmax(0,1fr)_360px]">
        <div className="pointer-events-auto min-w-0">
          <div className={inspectorOpen ? 'w-full' : 'w-fit'} ref={leftOverlayElement}>
            {options.inspector ? (
              inspectorOpen ? (
                <aside
                  aria-label="Earn stack configuration inspector"
                  className="flex max-h-[calc(100svh-8rem)] min-w-0 flex-col border border-border bg-surface shadow-lg"
                >
                  <div className="flex items-center justify-between gap-3 border-b border-border px-3 py-2">
                    <div className="flex items-center gap-2">
                      <SlidersHorizontal aria-hidden className="size-4" />
                      <span className="text-label-12 font-medium">Configuration inspector</span>
                    </div>
                    <Button.Icon
                      onClick={() => setInspectorOpen(false)}
                      size="xs"
                      title="Close configuration inspector"
                      type="button"
                      variant="plain"
                    >
                      <PanelLeftClose aria-hidden />
                    </Button.Icon>
                  </div>
                  <div className="min-h-0 flex-1 overflow-y-auto p-3">{options.inspector}</div>
                </aside>
              ) : (
                <Button
                  icon={<SlidersHorizontal aria-hidden />}
                  onClick={() => setInspectorOpen(true)}
                  size="small"
                  type="button"
                  variant="secondary"
                >
                  Configure
                </Button>
              )
            ) : null}
          </div>
        </div>

        <div aria-hidden className="hidden lg:block" />

        <aside
          className="pointer-events-auto flex min-w-0 flex-col gap-3 lg:max-h-[calc(100svh-8rem)] lg:overflow-y-auto"
          ref={rightOverlayElement}
        >
          {options.interaction}
          {options.balances}
          {options.context}
        </aside>
      </div>

      <div className="min-h-[560px] flex-1">
        <ReactFlow<Node, Edge>
          autoPanOnNodeFocus={false}
          colorMode="system"
          defaultEdgeOptions={{
            deletable: false,
            focusable: false,
            reconnectable: false,
            selectable: false,
          }}
          edges={edges}
          edgeTypes={edgeTypes}
          edgesFocusable={false}
          elementsSelectable
          maxZoom={1.5}
          minZoom={0.35}
          nodes={nodes}
          nodesConnectable={false}
          nodesDraggable={false}
          nodeTypes={nodeTypes}
          onNodeClick={(_, node) => options.onSelect(node.id)}
          onNodesChange={onNodesChange}
          onPaneClick={() => options.onSelect(undefined)}
          panActivationKeyCode={null}
          panOnDrag
          panOnScroll={false}
          proOptions={{ hideAttribution: true }}
          translateExtent={[
            [-Topology.stackNodeWidth, -Topology.stackNodeHeight],
            [topology.width + Topology.stackNodeWidth, topology.height + Topology.stackNodeHeight],
          ]}
        >
          <Background
            color="var(--border-color-border)"
            gap={24}
            size={1}
            variant={BackgroundVariant.Lines}
          />
          <FitSelectedPath nodeIds={[...activeNodeIds]} padding={padding} />
          <Controls
            className="lg:mr-[324px] xl:mr-[384px]"
            position="bottom-right"
            showFitView={false}
            showInteractive={false}
          />
        </ReactFlow>
      </div>
    </div>
  )
}

const margin = 24
const defaultPadding = { bottom: margin, left: margin, right: margin, top: margin }

type FlowViewportPadding = typeof defaultPadding

export declare namespace StackFlowCanvas {
  type Props = {
    action: Action
    activeNodeIds: ReadonlySet<string>
    balances?: ReactNode | undefined
    context?: ReactNode | undefined
    inspector?: ReactNode | undefined
    interaction?: ReactNode | undefined
    onSelect: (id: string | undefined) => void
    topology: Topology.StackTopology
  }
}

function StackFlowNodeView(props: NodeProps<Node>) {
  const { active, category, detail, label } = props.data
  return (
    <div
      className={cx(
        'stack-flow-node flex h-[96px] w-[230px] flex-col border text-left',
        !active && 'opacity-20',
        props.selected && 'ring-2 ring-inset ring-foreground',
      )}
      data-active={active}
    >
      <FlowHandles />
      <div className="flex min-h-0 flex-1 flex-col justify-center px-4 py-3">
        <span className="text-heading-16 text-foreground">{label}</span>
        <span className="mt-0.5 text-label-12 text-foreground-secondary">{detail}</span>
      </div>
      <div className="flex items-center gap-2 border-t border-border bg-pane/70 px-4 py-2 text-label-12 text-foreground-secondary">
        <span aria-hidden className={cx('size-2 border', categoryClassNames[category])} />
        {Topology.categoryLabels[category]}
      </div>
    </div>
  )
}

/** Each side's target and source handle; `edgeHandles` picks one pair per edge. */
const handleDefinitions = (['target', 'source'] as const).flatMap((type) =>
  [Position.Top, Position.Right, Position.Bottom, Position.Left].map((position) => ({
    id: `${position}-${type}`,
    position,
    type,
  })),
)

function FlowHandles() {
  return handleDefinitions.map(({ id, position, type }) => (
    <Handle className="stack-flow-handle" id={id} key={id} position={position} type={type} />
  ))
}

function StackFlowEdgeView(props: EdgeProps<Edge>) {
  const [edgePath, labelX, labelY] = getSmoothStepPath({
    borderRadius: 8,
    offset: 20,
    sourcePosition: props.sourcePosition,
    sourceX: props.sourceX,
    sourceY: props.sourceY,
    targetPosition: props.targetPosition,
    targetX: props.targetX,
    targetY: props.targetY,
  })
  const { active, label } = props.data!

  return (
    <>
      <BaseEdge
        id={props.id}
        markerEnd={props.markerEnd}
        markerStart={props.markerStart}
        path={edgePath}
        style={props.style}
      />
      {active ? (
        <EdgeLabelRenderer>
          <div
            className="nodrag nopan stack-flow-edge-label pointer-events-auto absolute"
            style={{ transform: `translate(-50%, -50%) translate(${labelX}px, ${labelY}px)` }}
          >
            <span className="stack-flow-edge-action">
              <span aria-hidden className="stack-flow-edge-mark">
                T
              </span>
              {label}
            </span>
          </div>
        </EdgeLabelRenderer>
      ) : null}
    </>
  )
}

/** Fits the selected action's path inside the area the overlay panels leave visible. */
function FitSelectedPath(props: { nodeIds: readonly string[]; padding: FlowViewportPadding }) {
  const { fitView } = useReactFlow()
  const key = props.nodeIds.join()

  useEffect(() => {
    void fitView({
      duration: 600,
      maxZoom: 1.25,
      nodes: key.split(',').map((id) => ({ id })),
      padding: {
        bottom: `${props.padding.bottom}px`,
        left: `${props.padding.left}px`,
        right: `${props.padding.right}px`,
        top: `${props.padding.top}px`,
      },
    })
  }, [fitView, key, props.padding])

  return null
}

/** React Flow node projected from the selected Earn topology. */
type Node = ReactFlowNode<Node.Data, 'stack'>

declare namespace Node {
  type Data = {
    active: boolean
    category: Topology.StackNodeCategory
    detail: string
    label: string
  }
}

/** React Flow edge projected from the selected Earn topology. */
type Edge = ReactFlowEdge<Edge.Data, 'stack'>

declare namespace Edge {
  type Data = {
    active: boolean
    label: string
  }
}

/** Projects topology nodes into fixed React Flow nodes. */
function flowNodes(topology: Topology.StackTopology, activeNodeIds: ReadonlySet<string>): Node[] {
  return topology.nodes.map((node) => ({
    ariaLabel: `${node.label}: ${node.detail}`,
    data: {
      active: activeNodeIds.has(node.id),
      category: node.category,
      detail: node.detail,
      label: node.label,
    },
    deletable: false,
    id: node.id,
    initialHeight: Topology.stackNodeHeight,
    initialWidth: Topology.stackNodeWidth,
    position: { x: node.x, y: node.y },
    style: {
      height: Topology.stackNodeHeight,
      width: Topology.stackNodeWidth,
    },
    type: 'stack',
  }))
}

/** Projects topology edges, highlighting the selected action's path. */
function flowEdges(options: flowEdges.Options): Edge[] {
  const { action, activeNodeIds, topology } = options
  return topology.edges.flatMap((edge) => {
    const from = topology.nodes.find((node) => node.id === edge.from)
    const to = topology.nodes.find((node) => node.id === edge.to)
    if (!from || !to) return []
    const active = activeNodeIds.has(from.id) && activeNodeIds.has(to.id)
    const color = active ? 'var(--text-color-foreground)' : 'var(--text-color-foreground-secondary)'
    const handles = edgeHandles(from, to)
    const marker = { color, height: 14, type: MarkerType.ArrowClosed, width: 14 } as const
    return [
      {
        ariaLabel: `${edge.label}: ${from.label} to ${to.label}`,
        data: { active, label: edge.label },
        id: `${edge.from}-${edge.to}-${edge.label}`,
        markerEnd: actions[action].direction === 'forward' ? marker : undefined,
        markerStart: actions[action].direction === 'reverse' ? marker : undefined,
        source: edge.from,
        sourceHandle: handles.source,
        style: {
          opacity: active ? 1 : 0.08,
          stroke: color,
          strokeWidth: active ? 2.5 : 1.5,
        },
        target: edge.to,
        targetHandle: handles.target,
        type: 'stack' as const,
      },
    ]
  })
}

declare namespace flowEdges {
  type Options = {
    action: Action
    activeNodeIds: ReadonlySet<string>
    topology: Topology.StackTopology
  }
}

function edgeHandles(from: Topology.StackNode, to: Topology.StackNode) {
  const fromCenterX = from.x + Topology.stackNodeWidth / 2
  const fromCenterY = from.y + Topology.stackNodeHeight / 2
  const toCenterX = to.x + Topology.stackNodeWidth / 2
  const toCenterY = to.y + Topology.stackNodeHeight / 2
  if (Math.abs(fromCenterX - toCenterX) < 1) {
    return toCenterY > fromCenterY
      ? { source: 'bottom-source', target: 'top-target' }
      : { source: 'top-source', target: 'bottom-target' }
  }
  return toCenterX > fromCenterX
    ? { source: 'right-source', target: 'left-target' }
    : { source: 'left-source', target: 'right-target' }
}

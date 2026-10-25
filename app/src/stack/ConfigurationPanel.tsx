import { Info as InfoIcon } from 'lucide-react'
import { Button, Choices, Info, Tag, Tooltip } from 'regen-ui'
import {
  engineDefinitions,
  engineKinds,
  type EngineKind,
  type PublicEarnStack,
} from '@tempoxyz/earn/deployments'

import type * as Support from '../deployments/Support.js'

/** Chooses the yield engine and access path among the stacks the catalog registers. */
export function ConfigurationPanel(options: ConfigurationPanel.Props) {
  const { access, blockedReason, deployment, resolve } = options
  return (
    <div className="flex min-w-0 flex-col gap-3">
      <div className="flex items-center justify-between gap-3">
        <h2 className="text-label-13 font-medium">Build your Earn stack</h2>
        <div className="flex items-center gap-2">
          <Tag intent={blockedReason ? 'warning' : 'positive'}>
            {blockedReason ? 'Preview' : 'Live'}
          </Tag>
          <Button onClick={options.onReset} size="small" type="button" variant="secondary">
            Reset
          </Button>
        </div>
      </div>

      <Step
        description="Switch between the deployed engine stacks available here."
        label="Yield source"
      >
        <Choices
          className="configuration-choice-group"
          items={engineKinds.map((engine) => {
            const resolution = resolve(engine, access)
            return {
              disabled: 'message' in resolution,
              label: optionLabel(engineDefinitions[engine].label, resolution),
              value: engine,
            }
          })}
          label="Yield engine"
          onChange={options.onEngineChange}
          value={deployment.engineKind}
          variant="compact"
        />
      </Step>

      <Step
        description="Public actions call EarnVault directly. Private actions enter through Tempo Zone and the deployment-scoped SingleZoneEarnRouter."
        label="Access"
      >
        <Choices
          className="configuration-choice-group"
          items={(['public', 'private'] as const).map((candidate) => {
            const resolution = resolve(deployment.engineKind, candidate)
            return {
              disabled: 'message' in resolution,
              label: optionLabel(candidate === 'public' ? 'Public' : 'Private', resolution),
              value: candidate,
            }
          })}
          label="Interaction path"
          onChange={options.onAccessChange}
          value={access}
          variant="compact"
        />
      </Step>

      {blockedReason ? <Info message={blockedReason} type="warning" /> : null}
    </div>
  )
}

export declare namespace ConfigurationPanel {
  type Props = {
    access: Support.Access
    blockedReason: string | undefined
    deployment: PublicEarnStack
    onAccessChange: (access: Support.Access) => void
    onEngineChange: (engine: EngineKind) => void
    onReset: () => void
    resolve: (engine: EngineKind, access: Support.Access) => Support.Resolution
  }
}

function Step(props: { children: React.ReactNode; description: string; label: string }) {
  return (
    <section className="flex flex-col gap-2 border-t border-border pt-3">
      <div className="flex items-center gap-1">
        <h3 className="text-label-13">{props.label}</h3>
        <Tooltip
          label={<span className="configuration-tooltip">{props.description}</span>}
          side="right"
        >
          <Button.Icon size="xs" title={`${props.label} information`} type="button" variant="plain">
            <InfoIcon aria-hidden />
          </Button.Icon>
        </Tooltip>
      </div>
      {props.children}
    </section>
  )
}

function optionLabel(label: string, resolution: Support.Resolution) {
  if (!('message' in resolution)) return label
  return (
    <Tooltip label={<span className="configuration-tooltip">{resolution.message}</span>}>
      <span className="pointer-events-auto inline-flex h-full w-full items-center justify-center">
        {label}
      </span>
    </Tooltip>
  )
}

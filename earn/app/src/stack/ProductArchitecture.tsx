import { Box, Info, Rows, Tag } from 'regen-ui'
import {
  engineDefinitions,
  type PublicEarnStack,
  type PublicNetwork,
} from '@tempoxyz/contracts/deployments'

import { privateRouteAsset } from '../../deployments/tokens.js'
import type { VerificationResult } from '../earn/Verification.js'
import { ExplorerAddress } from '../Explorer.js'

type Deployment = PublicEarnStack

/** Renders one registered deployment without exposing transaction controls. */
export function ProductArchitecture(props: ProductArchitecture.Props) {
  const { deployment, mode, verification, zone } = props
  const engine = engineDefinitions[deployment.engineKind]
  const privateMode = deployment.modes.private
  const alternateAsset = privateRouteAsset(deployment)
  return (
    <div className={mode === 'private' ? 'grid items-start gap-3 lg:grid-cols-2' : 'grid gap-3'}>
      {mode === 'private' ? (
        <Box className="flex flex-col gap-4" padding={16}>
          <PanelHeading description="Private execution configuration" title="Zone" />
          <Rows>
            {alternateAsset ? (
              <Rows.Row label="Alternate input token">
                <ExplorerAddress address={alternateAsset} copy explorerUrl={props.explorerUrl} />
              </Rows.Row>
            ) : null}
            <Rows.Row label="Status">{privateMode?.availability ?? 'Not configured'}</Rows.Row>
            <Rows.Row label="Zone">
              {privateMode && zone ? zone.name.toUpperCase() : 'Not configured'}
            </Rows.Row>
            {deployment.contracts.earnRouter ? (
              <Rows.Row label="EarnRouter">
                <ExplorerAddress
                  address={deployment.contracts.earnRouter}
                  copy
                  explorerUrl={props.explorerUrl}
                />
              </Rows.Row>
            ) : null}
            {privateMode && zone ? (
              <Rows.Row label="Portal">
                <ExplorerAddress address={zone.portal} copy explorerUrl={props.explorerUrl} />
              </Rows.Row>
            ) : null}
          </Rows>
          {privateMode ? (
            <Info
              message={
                privateMode.reason ??
                `Private infrastructure is ${privateMode.availability}; Zone readiness is not checked here.`
              }
              type={privateMode.availability === 'blocked' ? 'warning' : 'info'}
            />
          ) : (
            <Info message="Private execution is not configured for this product." type="warning" />
          )}
        </Box>
      ) : null}

      <Box className="flex flex-col gap-4" padding={16}>
        <div className="flex items-start justify-between gap-3">
          <PanelHeading description={deployment.description} title="Vault" />
          <div className="flex shrink-0 items-center gap-2">{healthTag(verification)}</div>
        </div>

        <Rows>
          <Rows.Row label={`${deployment.expectedMetadata.asset.symbol} asset`}>
            <ExplorerAddress
              address={deployment.contracts.asset}
              copy
              explorerUrl={props.explorerUrl}
            />
          </Rows.Row>
          <Rows.Row label={`${deployment.expectedMetadata.earnShare.symbol} EarnShare`}>
            <ExplorerAddress
              address={deployment.contracts.earnShare}
              copy
              explorerUrl={props.explorerUrl}
            />
          </Rows.Row>
          <Rows.Row label="EarnVault">
            <ExplorerAddress
              address={deployment.contracts.earnVault}
              copy
              explorerUrl={props.explorerUrl}
            />
          </Rows.Row>
          <Rows.Row label="EarnFees">
            <ExplorerAddress
              address={deployment.contracts.earnFees}
              copy
              explorerUrl={props.explorerUrl}
            />
          </Rows.Row>
          <Rows.Row label="Engine">
            <ExplorerAddress
              address={deployment.contracts.engine}
              copy
              explorerUrl={props.explorerUrl}
            />
          </Rows.Row>
          <Rows.Row label="Venue">
            <ExplorerAddress
              address={deployment.contracts.venue}
              copy
              explorerUrl={props.explorerUrl}
            />
          </Rows.Row>
          {engine.periphery.map(({ name, label }) => {
            const address = deployment.contracts.periphery?.[name]
            return address ? (
              <Rows.Row key={name} label={`${engine.label} ${label}`}>
                <ExplorerAddress address={address} copy explorerUrl={props.explorerUrl} />
              </Rows.Row>
            ) : null
          })}
        </Rows>

        {verificationInfo(verification)}
      </Box>
    </div>
  )
}

export declare namespace ProductArchitecture {
  type Props = {
    deployment: Deployment
    explorerUrl?: string | undefined
    mode: 'public' | 'private'
    verification: VerificationResult | 'verifying'
    zone?: PublicNetwork['zone']
  }
}

function PanelHeading(props: { description: string; title: string }) {
  return (
    <div className="min-w-0">
      <h3 className="text-heading-16 text-foreground">{props.title}</h3>
      <p className="mt-1 text-copy-14 text-foreground-secondary">{props.description}</p>
    </div>
  )
}

function healthTag(verification: VerificationResult | 'verifying') {
  if (verification === 'verifying') return <Tag intent="neutral">Verifying</Tag>
  if (verification.status === 'verified') return <Tag intent="positive">Verified</Tag>
  if (verification.status === 'mismatch') return <Tag intent="negative">Mismatch</Tag>
  return <Tag intent="warning">Unavailable</Tag>
}

function verificationInfo(verification: VerificationResult | 'verifying') {
  if (verification === 'verifying' || verification.status === 'verified') return null
  const [first = 'Deployment verification failed.'] = verification.issues
  const suffix = verification.issues.length > 1 ? ` (+${verification.issues.length - 1} more)` : ''
  return (
    <Info
      message={`${first}${suffix}`}
      type={verification.status === 'mismatch' ? 'error' : 'warning'}
    />
  )
}

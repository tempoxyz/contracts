import { Copy, cx, Hash } from 'regen-ui'
import type { Address } from 'viem'

/** Renders a copyable address linked to its network explorer when available. */
export function ExplorerAddress(props: ExplorerAddress.Props) {
  const { address, className, copy = false, explorerUrl, min } = props
  if (!explorerUrl) {
    return <Hash className={className} copy={copy} min={min} value={address} />
  }
  return (
    <span className={cx('inline-flex max-w-full items-center gap-1', className)}>
      <a
        aria-label={`View ${address} in Tempo Explorer`}
        className="min-w-0 underline decoration-current/40 underline-offset-2"
        href={`${base(explorerUrl)}/address/${address}`}
        rel="noreferrer"
        target="_blank"
      >
        <Hash min={min} value={address} />
      </a>
      {copy ? <Copy size="xs" value={address} variant="plain" /> : null}
    </span>
  )
}

export declare namespace ExplorerAddress {
  type Props = {
    address: Address
    className?: string | undefined
    copy?: boolean | undefined
    explorerUrl?: string | undefined
    min?: number | undefined
  }
}

/** Builds an explorer URL for one transaction receipt. */
export function receiptUrl(explorerUrl: string, hash: string) {
  return `${base(explorerUrl)}/receipt/${hash}`
}

/** Shortens a hash, address, or other long hex value for display. */
export function shortHex(value: string) {
  return `${value.slice(0, 8)}…${value.slice(-6)}`
}

function base(explorerUrl: string) {
  return explorerUrl.replace(/\/+$/, '')
}

import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react'
import { Button, Copy, Info } from 'regen-ui'

import { receiptUrl, shortHex } from '../Explorer.js'

const MAX_COMPLETED_TOASTS = 8
const TOAST_EXIT_DURATION = 160

/** One user-visible progress notice for a setup step or Earn transaction. */
export type TransactionToast = {
  detail?: string | undefined
  environment: string
  /** The failure behind an error notice; one error is reported once even if rethrown. */
  error?: unknown
  explorerUrl?: string | undefined
  hash?: string | undefined
  hashes?: readonly string[] | undefined
  id: string
  message: string
  steps?: readonly string[] | undefined
  status: 'error' | 'pending' | 'success'
}

type TransactionToastContextValue = {
  dismiss: (id: string) => void
  upsert: (toast: TransactionToast) => void
}

const TransactionToastContext = createContext<TransactionToastContextValue | undefined>(undefined)

/** Owns the app-wide stack of dismissible transaction progress notices. */
export function TransactionToastProvider(props: { children: React.ReactNode }) {
  const [toasts, setToasts] = useState<TransactionToast[]>([])
  const [exiting, setExiting] = useState<ReadonlySet<string>>(() => new Set())
  const dismissed = useRef(new Set<string>())
  const reported = useRef(new WeakSet<object>())
  const exitTimers = useRef(new Map<string, ReturnType<typeof setTimeout>>())
  const dismiss = useCallback((id: string) => {
    if (dismissed.current.has(id)) return
    dismissed.current.add(id)
    setExiting((current) => new Set(current).add(id))
    const timer = setTimeout(() => {
      setToasts((current) => current.filter((toast) => toast.id !== id))
      setExiting((current) => {
        const next = new Set(current)
        next.delete(id)
        return next
      })
      exitTimers.current.delete(id)
    }, TOAST_EXIT_DURATION)
    exitTimers.current.set(id, timer)
  }, [])
  const upsert = useCallback((next: TransactionToast) => {
    if (next.status === 'error' && next.error && typeof next.error === 'object') {
      if (reported.current.has(next.error)) return
      reported.current.add(next.error)
      console.error('[Tempo Earn]', next.environment, next.message, next.error)
    }
    if (dismissed.current.has(next.id)) return
    setToasts((current) => upsertTransactionToast(current, next))
  }, [])
  const value = useMemo(() => ({ dismiss, upsert }), [dismiss, upsert])
  useEffect(() => () => exitTimers.current.forEach(clearTimeout), [])
  return (
    <TransactionToastContext.Provider value={value}>
      {props.children}
      <ToastStack
        exiting={exiting}
        items={toasts}
        onDismiss={dismiss}
        onDismissAll={() => toasts.forEach((toast) => dismiss(toast.id))}
      />
    </TransactionToastContext.Provider>
  )
}

/** Returns the shared transaction-notification controller. */
export function useTransactionToasts() {
  const value = useContext(TransactionToastContext)
  if (!value) throw new Error('TransactionToastProvider is missing.')
  return value
}

/** Inserts a toast update and bounds only completed history. */
function upsertTransactionToast(current: readonly TransactionToast[], next: TransactionToast) {
  const existing = current.findIndex((toast) => toast.id === next.id)
  const updated =
    existing === -1
      ? [...current, next]
      : current.map((toast, index) => (index === existing ? next : toast))
  const completed = updated.filter((toast) => toast.status === 'success')
  if (completed.length <= MAX_COMPLETED_TOASTS) return updated
  const remove = new Set(
    completed.slice(0, completed.length - MAX_COMPLETED_TOASTS).map((toast) => toast.id),
  )
  return updated.filter((toast) => !remove.has(toast.id))
}

/** Renders a collapsible stack of transaction notifications. */
function ToastStack(props: {
  exiting: ReadonlySet<string>
  items: readonly TransactionToast[]
  onDismiss: (id: string) => void
  onDismissAll: () => void
}) {
  const [expanded, setExpanded] = useState(false)
  const latest = props.items.at(-1)
  useEffect(() => {
    if (props.items.length === 0) setExpanded(false)
  }, [props.items.length])

  if (!latest) return null
  const count = `${props.items.length} transaction ${props.items.length === 1 ? 'update' : 'updates'}`

  return (
    <div
      aria-label="Transaction activity"
      className="fixed inset-x-4 bottom-4 z-50 sm:left-auto sm:w-[440px]"
    >
      {expanded ? (
        <div
          className="transaction-toast-expanded flex max-h-[calc(100dvh-2rem)] flex-col gap-2"
          key="expanded"
        >
          <div className="flex shrink-0 items-center justify-between px-1">
            <span className="text-label-12 text-foreground-secondary">{count}</span>
            <Button.Text onClick={() => setExpanded(false)} size="small" type="button">
              Show less
            </Button.Text>
          </div>
          <div className="flex flex-col gap-2 overflow-y-auto">
            {[...props.items].reverse().map((item) => (
              <div
                aria-live={item.status === 'error' ? 'assertive' : 'polite'}
                aria-busy={item.status === 'pending'}
                className="transaction-toast"
                data-exiting={props.exiting.has(item.id) ? true : undefined}
                data-status={item.status}
                key={item.id}
                role={item.status === 'error' ? 'alert' : 'status'}
              >
                <ToastCard item={item} onDismiss={() => props.onDismiss(item.id)} />
              </div>
            ))}
          </div>
        </div>
      ) : (
        <div
          className="transaction-toast-collapsed flex flex-col gap-2"
          key={`collapsed-${latest.id}`}
        >
          <div className="flex shrink-0 items-center justify-between px-1">
            <span className="text-label-12 text-foreground-secondary">{count}</span>
            <Button.Text onClick={props.onDismissAll} size="small" type="button">
              Dismiss all
            </Button.Text>
          </div>
          <div
            aria-live={latest.status === 'error' ? 'assertive' : 'polite'}
            aria-busy={latest.status === 'pending'}
            className="transaction-toast transaction-toast-stack relative"
            data-exiting={props.exiting.has(latest.id) ? true : undefined}
            data-stack-size={Math.min(props.items.length, 3)}
            data-status={latest.status}
            role={latest.status === 'error' ? 'alert' : 'status'}
          >
            <ToastCard compact item={latest} />
            <button
              aria-expanded="false"
              aria-label={`Expand ${props.items.length} transaction ${props.items.length === 1 ? 'notification' : 'notifications'}`}
              className="absolute inset-0 z-10 cursor-pointer rounded-body focus-visible:outline-[2px] focus-visible:outline-offset-[2px] focus-visible:outline-focus"
              onClick={() => setExpanded(true)}
              type="button"
            />
          </div>
        </div>
      )}
    </div>
  )
}

function ToastCard(props: {
  compact?: boolean | undefined
  item: TransactionToast
  onDismiss?: (() => void) | undefined
}) {
  const { compact, item, onDismiss } = props
  const hashes = item.hashes ?? (item.hash ? [item.hash] : [])
  return (
    <Info
      action={onDismiss ? { label: 'Dismiss', onClick: onDismiss } : undefined}
      className="shadow-lg"
      message={
        <span className="flex flex-col gap-1">
          <span>
            <span className="font-medium">{item.environment}</span>
            {' · '}
            {item.message}
          </span>
          {item.detail ? (
            <span className="text-copy-12 text-foreground-secondary">{item.detail}</span>
          ) : null}
          {!compact && item.steps && item.steps.length > 0 ? (
            <details className="text-copy-12 text-foreground-secondary">
              <summary className="cursor-pointer font-medium">Transaction steps</summary>
              <ol className="mt-1 list-decimal space-y-0.5 pl-4">
                {item.steps.map((step) => (
                  <li key={step}>{step}</li>
                ))}
              </ol>
            </details>
          ) : null}
          {!compact && hashes.length > 0 ? (
            <span className="flex flex-wrap gap-x-3 gap-y-1">
              {hashes.map((hash, index) => (
                <span className="flex items-center gap-1" key={hash}>
                  {hashes.length > 1 ? (
                    <span className="text-copy-12 text-foreground-secondary">{index + 1}</span>
                  ) : null}
                  {item.explorerUrl ? (
                    <a
                      className="w-fit font-mono text-copy-12 underline decoration-current/40 underline-offset-2"
                      href={receiptUrl(item.explorerUrl, hash)}
                      rel="noreferrer"
                      target="_blank"
                    >
                      {shortHex(hash)}
                    </a>
                  ) : (
                    <span className="font-mono text-copy-12 text-foreground-secondary">
                      {shortHex(hash)}
                    </span>
                  )}
                  <Copy
                    size="xs"
                    title={`Copy ${item.environment} transaction hash`}
                    value={hash}
                    variant="plain"
                  />
                </span>
              ))}
            </span>
          ) : null}
        </span>
      }
      type={item.status === 'error' ? 'error' : 'info'}
    />
  )
}

import { formatUnits, parseUnits } from 'viem'
import { EarnShares } from 'viem/tempo'

import { message } from '../Errors.js'

/** Default tolerance applied to Earn transaction bounds. */
const slippageBps = 50

/** Returns whether a value is an empty or unsigned decimal input. */
export function isInput(value: string): boolean {
  return /^\d*(?:\.\d*)?$/.test(value)
}

/** Parses a positive decimal amount without accepting exponent or signed notation. */
export function parse(value: string, decimals: number): bigint {
  if (!/^(?:\d+)(?:\.\d+)?$/.test(value)) throw new Error('Enter a valid amount.')
  const fraction = value.split('.')[1]
  if (fraction && fraction.length > decimals) {
    throw new Error(`Amount supports at most ${decimals} decimal places.`)
  }
  const amount = parseUnits(value, decimals)
  if (amount <= 0n) throw new Error('Amount must be greater than zero.')
  return amount
}

/** Applies the Earn tolerance while preserving a nonzero onchain output bound. */
export function minimumOutput(expected: bigint) {
  return EarnShares.minimumOutput(expected, slippageBps)
}

/** Applies the Earn tolerance to an expected input, rounding the onchain input bound up. */
export function maximumInput(expected: bigint) {
  if (expected <= 0n) throw new Error('The expected input must be greater than zero.')
  const scale = BigInt(EarnShares.basisPointScale)
  return (expected * (scale + BigInt(slippageBps)) + scale - 1n) / scale
}

/** Parses an optional form amount into either its base units or the user-facing input error. */
export function parseInput(value: string, decimals: number) {
  if (value === '') return { amount: undefined, error: undefined }
  try {
    return { amount: parse(value, decimals), error: undefined }
  } catch (error) {
    return { amount: undefined, error: message(error) }
  }
}

/** Formats a balance, or `empty` while it is unknown. */
export function formatBalance(value: bigint | undefined, decimals: number, empty = 'Reading…') {
  return value === undefined ? empty : formatUnits(value, decimals)
}

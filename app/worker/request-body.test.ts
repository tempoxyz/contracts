import { describe, expect, test } from 'vitest'

import { boundedJsonBody } from './request-body.js'

describe('boundedJsonBody', () => {
  test('rejects an oversized declared content length before reading', async () => {
    const result = await boundedJsonBody(
      new Request('https://earn.example', {
        body: '{}',
        headers: { 'Content-Length': '100', 'Content-Type': 'application/json' },
        method: 'POST',
      }),
      32,
    )

    expect(result.response?.status).toBe(413)
  })

  test('stops an undeclared stream as soon as it exceeds the limit', async () => {
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(new TextEncoder().encode('1234'))
        controller.enqueue(new TextEncoder().encode('5678'))
        controller.close()
      },
    })
    const request = new Request('https://earn.example', {
      body: stream,
      headers: { 'Content-Type': 'application/json' },
      method: 'POST',
    })
    const result = await boundedJsonBody(request, 4)

    expect(result.response?.status).toBe(413)
  })
})

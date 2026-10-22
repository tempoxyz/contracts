type BodyResult = { body: Uint8Array; response?: never } | { body?: never; response: Response }

/** Reads a JSON request incrementally and stops before buffering more than the route limit. */
export async function boundedJsonBody(request: Request, maximumBytes: number): Promise<BodyResult> {
  const contentType = request.headers.get('content-type')?.split(';')[0]?.trim().toLowerCase()
  if (contentType !== 'application/json') {
    return { response: new Response('Expected application/json.', { status: 415 }) }
  }

  const contentLengthHeader = request.headers.get('content-length')
  if (contentLengthHeader !== null) {
    const contentLength = Number(contentLengthHeader)
    if (!Number.isSafeInteger(contentLength) || contentLength < 0) {
      return { response: new Response('Invalid Content-Length.', { status: 400 }) }
    }
    if (contentLength > maximumBytes) {
      return { response: new Response('Request body is too large.', { status: 413 }) }
    }
  }

  const body = await readCapped(request.body, maximumBytes)
  return body ? { body } : { response: new Response('Request body is too large.', { status: 413 }) }
}

/**
 * Reads a body stream, cancelling it as soon as it exceeds `maximumBytes`. Returns `undefined` for
 * an oversized body.
 */
export async function readCapped(
  stream: ReadableStream<Uint8Array> | null,
  maximumBytes: number,
): Promise<Uint8Array | undefined> {
  if (!stream) return new Uint8Array()
  const reader = stream.getReader()
  const chunks: Uint8Array[] = []
  let size = 0
  try {
    while (true) {
      const { done, value } = await reader.read()
      if (done) break
      size += value.byteLength
      if (size > maximumBytes) {
        await reader.cancel('Body exceeded its byte limit.')
        return undefined
      }
      chunks.push(value)
    }
  } catch (error) {
    await reader.cancel().catch(() => undefined)
    throw error
  }
  const body = new Uint8Array(size)
  let offset = 0
  for (const chunk of chunks) {
    body.set(chunk, offset)
    offset += chunk.byteLength
  }
  return body
}

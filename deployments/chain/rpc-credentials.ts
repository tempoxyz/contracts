/** Removes configured RPC URLs and credentials from diagnostics, including encoded forms. */
export function redactRpcCredentials(
  text: string,
  authenticatedUrl: string,
  environment: Readonly<Record<string, string | undefined>>,
) {
  const secrets = new Set<string>()
  for (const value of [
    environment.TEMPO_RPC_USERNAME,
    environment.TEMPO_RPC_PASSWORD,
    environment.ZONE_RPC_USERNAME,
    environment.ZONE_RPC_PASSWORD,
  ]) {
    addCredentialForms(secrets, value)
  }
  for (const prefix of ['TEMPO', 'ZONE']) {
    addBasicCredential(
      secrets,
      environment[`${prefix}_RPC_USERNAME`],
      environment[`${prefix}_RPC_PASSWORD`],
    )
  }
  for (const value of [
    authenticatedUrl,
    environment.TEMPO_RPC_URL,
    environment.ZONE_RPC_URL,
    environment.FOUNDRY_ETH_RPC_URL,
  ]) {
    if (!value) continue
    addCredentialForms(secrets, value)
    addCredentialForms(secrets, value.replace(/\/+$/, ''))
    try {
      const url = new URL(value)
      addCredentialForms(secrets, url.href)
      addCredentialForms(secrets, url.href.replace(/\/+$/, ''))
      addCredentialForms(secrets, url.username)
      addCredentialForms(secrets, url.password)
      const userinfo = { username: url.username, password: url.password }
      // viem moves userinfo into an auth header but still includes path/query tokens in errors.
      url.username = ''
      url.password = ''
      addCredentialForms(secrets, url.href)
      addCredentialForms(secrets, url.href.replace(/\/+$/, ''))
      const username = decodeURIComponent(userinfo.username)
      const password = decodeURIComponent(userinfo.password)
      addBasicCredential(secrets, username, password)
      // Each environment field can override URL userinfo independently, as rpcConfiguration does.
      for (const prefix of ['TEMPO', 'ZONE']) {
        addBasicCredential(
          secrets,
          environment[`${prefix}_RPC_USERNAME`] || username,
          environment[`${prefix}_RPC_PASSWORD`] || password,
        )
      }
    } catch {
      // Invalid URLs still need redaction; a URL parser error would retain its input.
    }
  }
  if (secrets.size === 0) return text
  // Match once, longest first, so URLs are removed whole and credentials cannot rewrite the mask.
  const pattern = [...secrets]
    .sort((left, right) => right.length - left.length)
    .map((secret) =>
      secret
        .replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
        // Percent-encoding is case-insensitive; the credential's other characters are not.
        .replace(/%[\da-f]{2}/gi, (encoded) =>
          encoded.replace(
            /[a-f]/gi,
            (letter) => `[${letter.toLowerCase()}${letter.toUpperCase()}]`,
          ),
        ),
    )
    .join('|')
  const redacted = text.replace(new RegExp(pattern, 'g'), '***')
  // Short asterisk credentials can expand an existing mask. Coalesce only after matching every
  // credential, since a URL or credential can itself contain mask-shaped text.
  return secrets.has('*') || secrets.has('**') ? redacted.replace(/\*{3,}/g, '***') : redacted
}

function addCredentialForms(secrets: Set<string>, value: string | undefined) {
  if (!value) return
  const forms = new Set([value])
  try {
    forms.add(decodeURIComponent(value))
  } catch {
    // Literal percent signs in raw credentials are not necessarily an encoding.
  }
  for (const form of forms) {
    secrets.add(form)
    // Subprocess diagnostics can quote an environment value as JSON rather than print it raw.
    secrets.add(JSON.stringify(form).slice(1, -1))
    try {
      secrets.add(encodeURIComponent(form))
    } catch {
      // Malformed Unicode must not replace the original failure with an encoding error.
    }
  }
}

function addBasicCredential(
  secrets: Set<string>,
  username: string | undefined,
  password: string | undefined,
) {
  if (username && password)
    addCredentialForms(secrets, Buffer.from(`${username}:${password}`).toString('base64'))
}

export interface RuntimeConfig {
  readonly appName: string
  readonly apiBasePath: string
  readonly demoMode: boolean
  readonly csrfCookieName: string
  readonly csrfHeaderName: string
}

interface ConfigResponse {
  readonly ok: boolean
  readonly status?: number
  json(): Promise<unknown>
}

type ConfigFetcher = (
  input: RequestInfo | URL,
  init?: RequestInit,
) => Promise<ConfigResponse>

const sameOriginPathPattern = /^\/[A-Za-z0-9._~!$&'()*+,;=:@%/-]*$/
const headerNamePattern = /^[A-Za-z0-9-]+$/
const cookieNamePattern = /^[A-Za-z0-9!#$%&'*+.^_`|~-]+$/

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function readRequiredString(
  source: Record<string, unknown>,
  key: string,
  maxLength: number,
): string {
  const value = source[key]
  if (typeof value !== 'string' || value.trim().length === 0 || value.length > maxLength) {
    throw new Error(`Configurazione runtime non valida: ${key}`)
  }
  return value.trim()
}

export function parseRuntimeConfig(value: unknown): RuntimeConfig {
  if (!isRecord(value)) throw new Error('Configurazione runtime non valida')

  const appName = readRequiredString(value, 'appName', 100)
  const apiBasePath = readRequiredString(value, 'apiBasePath', 128).replace(/\/$/, '')
  if (
    !sameOriginPathPattern.test(apiBasePath) ||
    apiBasePath.startsWith('//') ||
    apiBasePath.includes('\\') ||
    apiBasePath.includes('..')
  ) {
    throw new Error('apiBasePath deve essere un percorso same-origin sicuro')
  }
  if (typeof value.demoMode !== 'boolean') {
    throw new Error('Configurazione runtime non valida: demoMode')
  }

  const csrfCookieName =
    value.csrfCookieName === undefined
      ? '__Host-helios_csrf'
      : readRequiredString(value, 'csrfCookieName', 64)
  const csrfHeaderName =
    value.csrfHeaderName === undefined
      ? 'X-CSRF-Token'
      : readRequiredString(value, 'csrfHeaderName', 64)
  if (!cookieNamePattern.test(csrfCookieName) || !headerNamePattern.test(csrfHeaderName)) {
    throw new Error('I nomi CSRF contengono caratteri non consentiti')
  }

  return {
    appName,
    apiBasePath,
    demoMode: value.demoMode,
    csrfCookieName,
    csrfHeaderName,
  }
}

export async function loadRuntimeConfig(
  fetcher: ConfigFetcher = fetch,
): Promise<RuntimeConfig> {
  const response = await fetcher('/config/runtime-config.json', {
    cache: 'no-store',
    credentials: 'same-origin',
    headers: { Accept: 'application/json' },
  })
  if (!response.ok) {
    throw new Error(`Bootstrap runtime non disponibile (${response.status ?? 'errore'})`)
  }
  return parseRuntimeConfig(await response.json())
}

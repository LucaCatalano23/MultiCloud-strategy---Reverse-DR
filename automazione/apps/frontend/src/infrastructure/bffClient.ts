import type {
  PlatformServiceStatus,
  PlatformStatus,
  RecentActivity,
  SessionInfo,
  Ticket,
  TicketPriority,
  TicketStatus,
} from '../domain/types'
import type { HeliosGateway } from './types'
import type { RuntimeConfig } from './runtimeConfig'

type BffFetcher = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>

const priorities = new Set<TicketPriority>(['high', 'medium', 'low'])
const statuses = new Set<TicketStatus>([
  'open',
  'in_progress',
  'waiting_user',
  'waiting_third_party',
  'scheduled',
  'closed',
])
const serviceStatuses = new Set<PlatformServiceStatus>([
  'operational',
  'degraded',
  'unavailable',
])

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function stringField(source: Record<string, unknown>, key: string): string {
  const value = source[key]
  if (typeof value !== 'string' || value.length === 0) {
    throw new Error(`Risposta BFF non valida: ${key}`)
  }
  return value
}

function parseTicket(value: unknown): Ticket {
  if (!isRecord(value)) throw new Error('Risposta BFF ticket non valida')
  const priority = value.priority
  const status = value.status
  if (typeof priority !== 'string' || !priorities.has(priority as TicketPriority)) {
    throw new Error('Priorità ticket non valida')
  }
  if (typeof status !== 'string' || !statuses.has(status as TicketStatus)) {
    throw new Error('Stato ticket non valido')
  }
  return {
    id: stringField(value, 'id'),
    title: stringField(value, 'title'),
    description: stringField(value, 'description'),
    priority: priority as TicketPriority,
    status: status as TicketStatus,
    assignee:
      value.assignee === null
        ? null
        : stringField(value, 'assignee'),
    service: stringField(value, 'service'),
    environment: stringField(value, 'environment'),
    createdBy: stringField(value, 'createdBy'),
    createdAt: stringField(value, 'createdAt'),
    updatedAt: stringField(value, 'updatedAt'),
  }
}

function parseSession(value: unknown): SessionInfo {
  if (!isRecord(value) || typeof value.authenticated !== 'boolean' || !isRecord(value.site)) {
    throw new Error('Risposta sessione BFF non valida')
  }
  const mode = value.site.mode
  const identityProvider = value.site.identityProvider
  if (
    (mode !== 'primary' && mode !== 'dr') ||
    (identityProvider !== 'entra-id' && identityProvider !== 'keycloak')
  ) {
    throw new Error('Contesto sito BFF non valido')
  }

  let user: SessionInfo['user'] = null
  if (value.authenticated) {
    if (!isRecord(value.user)) throw new Error('Utente BFF mancante')
    if (!Array.isArray(value.user.roles) || !value.user.roles.every((role) => typeof role === 'string')) {
      throw new Error('Ruoli utente BFF non validi')
    }
    user = {
      id: stringField(value.user, 'id'),
      displayName: stringField(value.user, 'displayName'),
      email: stringField(value.user, 'email'),
      roles: value.user.roles,
    }
  }
  return {
    authenticated: value.authenticated,
    user,
    site: { mode, identityProvider, name: stringField(value.site, 'name') },
  }
}

function parseActivity(value: unknown): RecentActivity {
  if (!isRecord(value)) throw new Error('Attività BFF non valida')
  const kind = stringField(value, 'kind')
  if (!['ticket', 'comment', 'automation', 'sla', 'resolved'].includes(kind)) {
    throw new Error('Tipo attività BFF non valido')
  }
  return {
    id: stringField(value, 'id'),
    kind: kind as RecentActivity['kind'],
    title: stringField(value, 'title'),
    description: stringField(value, 'description'),
    actor: stringField(value, 'actor'),
    occurredAt: stringField(value, 'occurredAt'),
  }
}

function parsePlatformStatus(value: unknown): PlatformStatus {
  if (!isRecord(value) || !Array.isArray(value.services) || !Array.isArray(value.activities)) {
    throw new Error('Stato piattaforma BFF non valido')
  }
  if (typeof value.rpoMinutes !== 'number' || typeof value.rpoTargetMinutes !== 'number') {
    throw new Error('RPO BFF non valido')
  }
  const services = value.services.map((service) => {
    if (!isRecord(service)) throw new Error('Servizio piattaforma non valido')
    const status = stringField(service, 'status')
    if (!serviceStatuses.has(status as PlatformServiceStatus)) {
      throw new Error('Stato servizio non valido')
    }
    return {
      id: stringField(service, 'id'),
      name: stringField(service, 'name'),
      status: status as PlatformServiceStatus,
    }
  })
  return {
    services,
    rpoMinutes: value.rpoMinutes,
    rpoTargetMinutes: value.rpoTargetMinutes,
    activities: value.activities.map(parseActivity),
  }
}

async function bffErrorMessage(response: Response): Promise<string> {
  // Il BFF restituisce sempre un envelope {"error":{"code","message"}} con lo
  // status reale (401/403/422/502...). Fino a ieri lo scartavamo mostrando solo
  // il codice numerico: ora sfruttiamo il messaggio mappato lato server (che è
  // già sanitizzato, senza leak del body upstream). Fallback al solo status se
  // il body è assente o non è JSON, per non introdurre un nuovo fallimento.
  const fallback = `Richiesta BFF non riuscita (${response.status})`
  try {
    const body: unknown = await response.json()
    if (isRecord(body) && isRecord(body.error) && typeof body.error.message === 'string') {
      const message = body.error.message.trim()
      if (message.length > 0) return `${message} (${response.status})`
    }
  } catch {
    // corpo assente o non-JSON: usa il fallback col solo status
  }
  return fallback
}

function readCookie(name: string): string | null {
  const prefix = `${name}=`
  const match = document.cookie
    .split(';')
    .map((part) => part.trim())
    .find((part) => part.startsWith(prefix))
  if (!match) return null
  try {
    return decodeURIComponent(match.slice(prefix.length))
  } catch {
    throw new Error('Cookie CSRF non valido')
  }
}

export function createBffClient(
  config: RuntimeConfig,
  fetcher: BffFetcher = fetch,
): HeliosGateway {
  async function request<T>(
    path: string,
    parser: (value: unknown) => T,
    init: RequestInit = {},
  ): Promise<T> {
    const headers = new Headers(init.headers)
    headers.set('Accept', 'application/json')
    if (init.body !== undefined) headers.set('Content-Type', 'application/json')
    if (init.method && !['GET', 'HEAD'].includes(init.method)) {
      const csrfToken = readCookie(config.csrfCookieName)
      if (!csrfToken) throw new Error('Sessione CSRF non inizializzata. Ricarica la pagina.')
      headers.set(config.csrfHeaderName, csrfToken)
    }

    const response = await fetcher(`${config.apiBasePath}${path}`, {
      ...init,
      credentials: 'same-origin',
      headers,
    })
    if (!response.ok) {
      throw new Error(await bffErrorMessage(response))
    }
    if (response.status === 204) return parser(null)
    return parser(await response.json())
  }

  return {
    getSession: () => request('/session', parseSession),
    listTickets: () =>
      request('/tickets', (value) => {
        if (!isRecord(value) || !Array.isArray(value.data) || !isRecord(value.meta)) {
          throw new Error('Elenco ticket BFF non valido')
        }
        return value.data.map(parseTicket)
      }),
    getPlatformStatus: () =>
      request('/platform/status', (value) => {
        if (!isRecord(value) || !('data' in value)) {
          throw new Error('Envelope stato piattaforma non valido')
        }
        return parsePlatformStatus(value.data)
      }),
    createTicket: (input) =>
      request('/tickets', (value) => {
        if (!isRecord(value) || !('data' in value)) {
          throw new Error('Envelope creazione ticket non valido')
        }
        return parseTicket(value.data)
      }, {
        method: 'POST',
        body: JSON.stringify(input),
      }),
    updateTicket: (id, input) =>
      request(`/tickets/${encodeURIComponent(id)}`, (value) => {
        if (!isRecord(value) || !('data' in value)) {
          throw new Error('Envelope aggiornamento ticket non valido')
        }
        return parseTicket(value.data)
      }, {
        method: 'PATCH',
        body: JSON.stringify(input),
      }),
    deleteTicket: (id) =>
      request(`/tickets/${encodeURIComponent(id)}`, () => undefined, { method: 'DELETE' }),
    logout: () => request('/auth/logout', () => undefined, { method: 'POST' }),
    getLoginUrl: (returnTo) => {
      if (!returnTo.startsWith('/') || returnTo.startsWith('//') || returnTo.includes('\\')) {
        throw new Error('returnTo deve essere un percorso locale')
      }
      return `${config.apiBasePath}/auth/login?returnTo=${encodeURIComponent(returnTo)}`
    },
  }
}

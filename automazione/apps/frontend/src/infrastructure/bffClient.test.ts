import { describe, expect, it, vi } from 'vitest'
import { createBffClient } from './bffClient'
import type { RuntimeConfig } from './runtimeConfig'

const config: RuntimeConfig = {
  appName: 'Helios Desk',
  apiBasePath: '/api/v1',
  demoMode: false,
  csrfCookieName: '__Host-helios_csrf',
  csrfHeaderName: 'X-CSRF-Token',
}

describe('BFF client', () => {
  it('requests the session with same-origin cookies and no bearer token', async () => {
    const fetcher = vi.fn().mockResolvedValue(
      new Response(
        JSON.stringify({
          authenticated: false,
          user: null,
          site: {
            mode: 'primary',
            identityProvider: 'entra-id',
            name: 'Primario',
          },
        }),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      ),
    )

    await createBffClient(config, fetcher).getSession()

    const [url, request] = fetcher.mock.calls[0] as [string, RequestInit]
    expect(url).toBe('/api/v1/session')
    expect(request.credentials).toBe('same-origin')
    expect(new Headers(request.headers).has('Authorization')).toBe(false)
  })

  it('adds the double-submit CSRF header to mutations', async () => {
    document.cookie = '__Host-helios_csrf=csrf%20value; Secure; path=/'
    const fetcher = vi.fn().mockResolvedValue(
      new Response(
        JSON.stringify({ data: {
          id: 'TKT-2025-0579',
          title: 'Nuovo ticket',
          description: 'Descrizione completa',
          priority: 'high',
          status: 'open',
          assignee: 'Non assegnato',
          service: 'Ordini e-Commerce',
          environment: 'AWS – Primary',
          createdBy: 'Luca Conti',
          createdAt: '2026-07-22T10:00:00+02:00',
          updatedAt: '2026-07-22T10:00:00+02:00',
        } }),
        { status: 201, headers: { 'Content-Type': 'application/json' } },
      ),
    )

    await createBffClient(config, fetcher).createTicket({
      title: 'Nuovo ticket',
      description: 'Descrizione completa',
      priority: 'high',
      service: 'Ordini e-Commerce',
      environment: 'AWS – Primary',
    })

    const [url, request] = fetcher.mock.calls[0] as [string, RequestInit]
    const headers = new Headers(request.headers)
    expect(url).toBe('/api/v1/tickets')
    expect(request.method).toBe('POST')
    expect(request.credentials).toBe('same-origin')
    expect(headers.get('X-CSRF-Token')).toBe('csrf value')
    expect(headers.has('Authorization')).toBe(false)
  })

  it('updates a ticket via PATCH with the CSRF header and parses the creator', async () => {
    document.cookie = '__Host-helios_csrf=csrf%20value; Secure; path=/'
    const fetcher = vi.fn().mockResolvedValue(
      new Response(
        JSON.stringify({ data: {
          id: 'TKT-2025-0578',
          title: 'Aggiornato',
          description: 'Descrizione aggiornata',
          priority: 'medium',
          status: 'in_progress',
          assignee: 'Grace Hopper',
          service: 'Ordini e-Commerce',
          environment: 'On-prem DR',
          createdBy: 'Luca Conti',
          createdAt: '2026-07-22T10:00:00+02:00',
          updatedAt: '2026-07-22T11:00:00+02:00',
        } }),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      ),
    )

    const ticket = await createBffClient(config, fetcher).updateTicket('TKT-2025-0578', {
      title: 'Aggiornato',
      description: 'Descrizione aggiornata',
      priority: 'medium',
      status: 'in_progress',
      service: 'Ordini e-Commerce',
      environment: 'On-prem DR',
      assignee: 'Grace Hopper',
    })

    const [url, request] = fetcher.mock.calls[0] as [string, RequestInit]
    expect(url).toBe('/api/v1/tickets/TKT-2025-0578')
    expect(request.method).toBe('PATCH')
    expect(new Headers(request.headers).get('X-CSRF-Token')).toBe('csrf value')
    expect(ticket.createdBy).toBe('Luca Conti')
    expect(ticket.status).toBe('in_progress')
  })

  it('deletes a ticket via DELETE and tolerates a 204 empty body', async () => {
    document.cookie = '__Host-helios_csrf=csrf%20value; Secure; path=/'
    const fetcher = vi.fn().mockResolvedValue(new Response(null, { status: 204 }))

    await createBffClient(config, fetcher).deleteTicket('TKT-2025-0578')

    const [url, request] = fetcher.mock.calls[0] as [string, RequestInit]
    expect(url).toBe('/api/v1/tickets/TKT-2025-0578')
    expect(request.method).toBe('DELETE')
    expect(new Headers(request.headers).get('X-CSRF-Token')).toBe('csrf value')
  })

  it('surfaces the BFF error envelope message instead of only the status code', async () => {
    const fetcher = vi.fn().mockResolvedValue(
      new Response(
        JSON.stringify({ error: { code: 'upstream_forbidden', message: 'Permesso mancante' } }),
        { status: 403, headers: { 'Content-Type': 'application/json' } },
      ),
    )

    await expect(createBffClient(config, fetcher).listTickets()).rejects.toThrow(
      'Permesso mancante (403)',
    )
  })

  it('falls back to the status code when the error body is not a valid envelope', async () => {
    const fetcher = vi.fn().mockResolvedValue(new Response('gateway down', { status: 502 }))

    await expect(createBffClient(config, fetcher).listTickets()).rejects.toThrow(
      'Richiesta BFF non riuscita (502)',
    )
  })

  it('parses measured DR metrics and keeps a never-measured one as null', async () => {
    const fetcher = vi.fn().mockResolvedValue(
      new Response(
        JSON.stringify({
          data: {
            services: [{ id: 'ticket-service', name: 'Ticket Service', status: 'operational' }],
            dr: {
              backup: {
                lastSuccessAt: '2026-07-24T09:50:00+00:00',
                ageSeconds: 600,
                targetSeconds: 900,
                status: 'ok',
              },
              failover: {
                lastPromotionAt: null,
                durationSeconds: null,
                targetSeconds: 1800,
                status: 'unknown',
              },
            },
            activities: [],
          },
        }),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      ),
    )

    const platform = await createBffClient(config, fetcher).getPlatformStatus()

    expect(platform.dr.backup.ageSeconds).toBe(600)
    expect(platform.dr.backup.status).toBe('ok')
    // Un failover mai eseguito resta null: la UI lo dichiara, non lo inventa.
    expect(platform.dr.failover.durationSeconds).toBeNull()
    expect(platform.dr.failover.status).toBe('unknown')
  })

  it('rejects a DR metric payload with a negative measurement', async () => {
    const fetcher = vi.fn().mockResolvedValue(
      new Response(
        JSON.stringify({
          data: {
            services: [],
            dr: {
              backup: {
                lastSuccessAt: '2026-07-24T09:50:00+00:00',
                ageSeconds: -1,
                targetSeconds: 900,
                status: 'ok',
              },
              failover: {
                lastPromotionAt: null,
                durationSeconds: null,
                targetSeconds: 1800,
                status: 'unknown',
              },
            },
            activities: [],
          },
        }),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      ),
    )

    await expect(createBffClient(config, fetcher).getPlatformStatus()).rejects.toThrow(
      /Metrica DR non valida/,
    )
  })

  it('runs the ticket automation via POST with the CSRF header', async () => {
    document.cookie = '__Host-helios_csrf=csrf%20value; Secure; path=/'
    const fetcher = vi.fn().mockResolvedValue(
      new Response(
        JSON.stringify({
          data: {
            id: 'run-1',
            sourceEventId: 'event-1',
            provider: 'lambda-dr',
            status: 'succeeded',
            result: { runtime: 'lambda-rie-onprem' },
            errorCode: null,
            createdAt: '2026-07-24T10:00:00+00:00',
            updatedAt: '2026-07-24T10:00:01+00:00',
          },
        }),
        { status: 202, headers: { 'Content-Type': 'application/json' } },
      ),
    )

    const run = await createBffClient(config, fetcher).runTicketAutomation('TKT-2025-0578')

    const [url, request] = fetcher.mock.calls[0] as [string, RequestInit]
    expect(url).toBe('/api/v1/tickets/TKT-2025-0578/automation')
    expect(request.method).toBe('POST')
    expect(new Headers(request.headers).get('X-CSRF-Token')).toBe('csrf value')
    expect(run.provider).toBe('lambda-dr')
    expect(run.result.runtime).toBe('lambda-rie-onprem')
  })

  it('builds a relative login URL with a constrained return target', () => {
    const client = createBffClient(config, vi.fn())

    expect(client.getLoginUrl('/')).toBe('/api/v1/auth/login?returnTo=%2F')
    expect(() => client.getLoginUrl('https://evil.example')).toThrow(/returnTo/)
  })
})

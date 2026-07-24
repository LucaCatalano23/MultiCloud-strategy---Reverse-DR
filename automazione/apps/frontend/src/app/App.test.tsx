import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import { App } from './App'
import type { RuntimeConfig } from '../infrastructure/runtimeConfig'
import type { HeliosGateway } from '../infrastructure/types'

const runtimeConfig: RuntimeConfig = {
  appName: 'Helios Desk',
  apiBasePath: '/api/v1',
  demoMode: true,
  csrfCookieName: '__Host-helios_csrf',
  csrfHeaderName: 'X-CSRF-Token',
}

const session = {
  authenticated: true as const,
  user: {
    id: 'user-1',
    displayName: 'Luca Conti',
    email: 'luca.conti@example.test',
    roles: ['operatore'],
  },
  site: {
    mode: 'primary' as const,
    identityProvider: 'entra-id' as const,
    name: 'Primario',
  },
}

const tickets = [
  {
    id: 'TKT-2025-0578',
    title: 'Failover DB ordine non completato su AWS DR',
    description:
      'Il processo di failover del database ordini non si è completato correttamente.',
    priority: 'high' as const,
    status: 'in_progress' as const,
    assignee: 'Luca Conti',
    service: 'Ordini e-Commerce',
    environment: 'AWS – DR (eu-west-1)',
    createdBy: 'Luca Conti',
    createdAt: '2026-07-22T08:27:00+02:00',
    updatedAt: '2026-07-22T09:42:00+02:00',
  },
  {
    id: 'TKT-2025-0576',
    title: 'Autenticazione Entra ID intermittente per utenti esterni',
    description: 'Alcuni utenti non riescono ad autenticarsi.',
    priority: 'medium' as const,
    status: 'waiting_user' as const,
    assignee: 'Marco Rossi',
    service: 'Identity',
    environment: 'Entra ID',
    createdBy: 'Giulia Verdi',
    createdAt: '2026-07-22T08:20:00+02:00',
    updatedAt: '2026-07-22T08:55:00+02:00',
  },
]

function createGateway(overrides: Partial<HeliosGateway> = {}): HeliosGateway {
  return {
    getSession: vi.fn().mockResolvedValue(session),
    listTickets: vi.fn().mockResolvedValue(tickets),
    getPlatformStatus: vi.fn().mockResolvedValue({
      services: [
        { id: 'aws', name: 'AWS Primary', status: 'operational' },
        { id: 'identity', name: 'Entra ID', status: 'operational' },
      ],
      dr: {
        backup: {
          lastSuccessAt: '2026-07-22T09:38:00+02:00',
          ageSeconds: 240,
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
    }),
    createTicket: vi.fn().mockImplementation(async (input) => ({
      ...tickets[0],
      ...input,
      id: 'TKT-2025-0579',
      status: 'open',
      assignee: input.assignee ?? null,
      createdBy: 'Luca Conti',
    })),
    updateTicket: vi.fn().mockImplementation(async (id, input) => ({
      ...(tickets.find((ticket) => ticket.id === id) ?? tickets[0]),
      ...input,
      id,
      assignee: input.assignee ?? null,
    })),
    deleteTicket: vi.fn().mockResolvedValue(undefined),
    runTicketAutomation: vi.fn().mockResolvedValue({
      id: 'run-1',
      provider: 'aws-lambda',
      status: 'succeeded',
      errorCode: null,
      result: { runtime: 'aws-lambda-cloud', classification: 'incident' },
      updatedAt: '2026-07-24T10:00:01+00:00',
    }),
    logout: vi.fn().mockResolvedValue(undefined),
    getLoginUrl: vi.fn().mockReturnValue('/api/v1/auth/login?returnTo=%2F'),
    ...overrides,
  }
}

describe('Helios Desk dashboard', () => {
  it('renders the table-first operational view and platform status', async () => {
    render(<App gateway={createGateway()} runtimeConfig={runtimeConfig} />)

    expect(await screen.findByRole('heading', { name: 'Ticket operativi' })).toBeVisible()
    expect(screen.getByRole('navigation', { name: 'Navigazione principale' })).toBeVisible()
    // Metriche derivate dai ticket reali (2 non chiusi, 1 ad alta priorità),
    // non più valori hardcoded.
    const metrics = within(screen.getByRole('region', { name: 'Metriche operative' }))
    expect(metrics.getByText('2')).toBeVisible()
    expect(metrics.getByText('1')).toBeVisible()
    expect(screen.getByText('AWS Primary')).toBeVisible()
    expect(screen.getByRole('row', { name: /TKT-2025-0578/ })).toBeVisible()
  })

  it('filters ticket rows by free text and status', async () => {
    const user = userEvent.setup()
    render(<App gateway={createGateway()} runtimeConfig={runtimeConfig} />)
    await screen.findByRole('row', { name: /TKT-2025-0578/ })

    await user.type(screen.getByRole('searchbox', { name: 'Cerca ticket' }), 'Entra ID')
    expect(screen.queryByRole('row', { name: /TKT-2025-0578/ })).not.toBeInTheDocument()
    expect(screen.getByRole('row', { name: /TKT-2025-0576/ })).toBeVisible()

    await user.clear(screen.getByRole('searchbox', { name: 'Cerca ticket' }))
    await user.selectOptions(screen.getByLabelText('Filtra per stato'), 'in_progress')
    expect(screen.getByRole('row', { name: /TKT-2025-0578/ })).toBeVisible()
    expect(screen.queryByRole('row', { name: /TKT-2025-0576/ })).not.toBeInTheDocument()
  })

  it('opens and closes the selected ticket detail drawer', async () => {
    const user = userEvent.setup()
    render(<App gateway={createGateway()} runtimeConfig={runtimeConfig} />)
    await user.click(await screen.findByRole('row', { name: /TKT-2025-0576/ }))

    const drawer = screen.getByRole('complementary', { name: 'Dettaglio ticket TKT-2025-0576' })
    expect(within(drawer).getByText('Identity')).toBeVisible()
    await user.click(within(drawer).getByRole('button', { name: 'Chiudi dettagli' }))
    expect(screen.queryByRole('complementary', { name: /Dettaglio ticket/ })).not.toBeInTheDocument()
  })

  it('runs the platform function from the drawer and shows the executing runtime', async () => {
    // Arrange
    const user = userEvent.setup()
    const gateway = createGateway()
    render(<App gateway={gateway} runtimeConfig={runtimeConfig} />)
    await user.click(await screen.findByRole('row', { name: /TKT-2025-0576/ }))

    // Act
    const drawer = screen.getByRole('complementary', { name: 'Dettaglio ticket TKT-2025-0576' })
    const automation = within(drawer).getByRole('region', { name: 'Automazione di piattaforma' })
    await user.click(within(automation).getByRole('button', { name: 'Esegui' }))

    // Assert: il sito che ha eseguito la function è visibile all'operatore.
    expect(gateway.runTicketAutomation).toHaveBeenCalledWith('TKT-2025-0576')
    await waitFor(() => expect(within(automation).getByText('aws-lambda')).toBeVisible())
    expect(within(automation).getByText('aws-lambda-cloud')).toBeVisible()
  })

  it('reports a failed platform function without clearing the ticket detail', async () => {
    const user = userEvent.setup()
    const gateway = createGateway({
      runTicketAutomation: vi.fn().mockRejectedValue(new Error('Automazione non disponibile (502)')),
    })
    render(<App gateway={gateway} runtimeConfig={runtimeConfig} />)
    await user.click(await screen.findByRole('row', { name: /TKT-2025-0576/ }))

    const drawer = screen.getByRole('complementary', { name: 'Dettaglio ticket TKT-2025-0576' })
    const automation = within(drawer).getByRole('region', { name: 'Automazione di piattaforma' })
    await user.click(within(automation).getByRole('button', { name: 'Esegui' }))

    await waitFor(() =>
      expect(within(automation).getByRole('alert')).toHaveTextContent(
        'Automazione non disponibile (502)',
      ),
    )
    expect(within(drawer).getByText('Identity')).toBeVisible()
  })

  it('creates a ticket from the accessible dialog and adds it to the table', async () => {
    const user = userEvent.setup()
    const gateway = createGateway()
    render(<App gateway={gateway} runtimeConfig={runtimeConfig} />)
    await screen.findByRole('row', { name: /TKT-2025-0578/ })

    await user.click(screen.getByRole('button', { name: 'Nuovo ticket' }))
    const dialog = screen.getByRole('dialog', { name: 'Crea nuovo ticket' })
    await user.type(within(dialog).getByLabelText('Titolo'), 'Replica RDS non aggiornata')
    await user.type(
      within(dialog).getByLabelText('Descrizione'),
      'La replica supera la soglia RPO prevista.',
    )
    await user.selectOptions(within(dialog).getByLabelText('Priorità'), 'high')
    await user.selectOptions(within(dialog).getByLabelText('Servizio'), 'Database')
    await user.selectOptions(within(dialog).getByLabelText('Ambiente'), 'AWS – Primary')
    await user.click(within(dialog).getByRole('button', { name: 'Crea ticket' }))

    await waitFor(() => expect(gateway.createTicket).toHaveBeenCalledTimes(1))
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    expect(screen.getByRole('row', { name: /Replica RDS non aggiornata/ })).toBeVisible()
  })

  it('shows the real creator of the ticket in the detail drawer', async () => {
    const user = userEvent.setup()
    render(<App gateway={createGateway()} runtimeConfig={runtimeConfig} />)
    await user.click(await screen.findByRole('row', { name: /TKT-2025-0576/ }))

    const drawer = screen.getByRole('complementary', { name: 'Dettaglio ticket TKT-2025-0576' })
    expect(within(drawer).getByText('Creato da')).toBeVisible()
    expect(within(drawer).getByText('Giulia Verdi')).toBeVisible()
  })

  it('edits a ticket status through the edit dialog', async () => {
    const user = userEvent.setup()
    const gateway = createGateway()
    render(<App gateway={gateway} runtimeConfig={runtimeConfig} />)
    await user.click(await screen.findByRole('row', { name: /TKT-2025-0576/ }))

    const drawer = screen.getByRole('complementary', { name: 'Dettaglio ticket TKT-2025-0576' })
    await user.click(within(drawer).getByRole('button', { name: 'Modifica ticket' }))

    const dialog = screen.getByRole('dialog', { name: 'Modifica ticket' })
    await user.selectOptions(within(dialog).getByLabelText('Stato'), 'closed')
    await user.click(within(dialog).getByRole('button', { name: 'Salva modifiche' }))

    await waitFor(() => expect(gateway.updateTicket).toHaveBeenCalledTimes(1))
    expect(gateway.updateTicket).toHaveBeenCalledWith(
      'TKT-2025-0576',
      expect.objectContaining({ status: 'closed' }),
    )
  })

  it('deletes a ticket after confirmation and removes it from the table', async () => {
    const user = userEvent.setup()
    const gateway = createGateway()
    render(<App gateway={gateway} runtimeConfig={runtimeConfig} />)
    await user.click(await screen.findByRole('row', { name: /TKT-2025-0576/ }))

    const drawer = screen.getByRole('complementary', { name: 'Dettaglio ticket TKT-2025-0576' })
    await user.click(within(drawer).getByRole('button', { name: 'Elimina ticket' }))
    await user.click(within(drawer).getByRole('button', { name: 'Elimina' }))

    await waitFor(() => expect(gateway.deleteTicket).toHaveBeenCalledWith('TKT-2025-0576'))
    expect(screen.queryByRole('row', { name: /TKT-2025-0576/ })).not.toBeInTheDocument()
  })

  it('shows the BFF login action without loading protected resources', async () => {
    const gateway = createGateway({
      getSession: vi.fn().mockResolvedValue({
        authenticated: false,
        user: null,
        site: {
          mode: 'primary',
          identityProvider: 'entra-id',
          name: 'Primario',
        },
      }),
    })
    render(<App gateway={gateway} runtimeConfig={{ ...runtimeConfig, demoMode: false }} />)

    const login = await screen.findByRole('link', { name: 'Accedi con Entra ID' })
    expect(login).toHaveAttribute('href', '/api/v1/auth/login?returnTo=%2F')
    expect(gateway.listTickets).not.toHaveBeenCalled()
  })
})

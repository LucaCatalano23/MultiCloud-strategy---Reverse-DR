import { describe, expect, it } from 'vitest'
import { filterTickets } from './ticketFilter'
import type { Ticket } from './types'

const tickets: Ticket[] = [
  {
    id: 'TKT-2025-0578',
    title: 'Failover DB ordine non completato su AWS DR',
    description: 'Database ordini degradato',
    priority: 'high',
    status: 'in_progress',
    assignee: 'Luca Conti',
    service: 'Ordini e-Commerce',
    environment: 'AWS – DR (eu-west-1)',
    createdAt: '2026-07-22T08:27:00+02:00',
    updatedAt: '2026-07-22T09:42:00+02:00',
  },
  {
    id: 'TKT-2025-0576',
    title: 'Autenticazione Entra ID intermittente per utenti esterni',
    description: 'Login non affidabile',
    priority: 'medium',
    status: 'waiting_user',
    assignee: 'Marco Rossi',
    service: 'Identity',
    environment: 'Entra ID',
    createdAt: '2026-07-22T08:20:00+02:00',
    updatedAt: '2026-07-22T08:55:00+02:00',
  },
]

const allFilters = {
  query: '',
  status: 'all' as const,
  priority: 'all' as const,
  assignee: 'all',
  service: 'all',
}

describe('filterTickets', () => {
  it('matches query text across ticket identity and content', () => {
    expect(filterTickets(tickets, { ...allFilters, query: 'entra id' })).toEqual([
      tickets[1],
    ])
  })

  it('combines status, priority, assignee and service filters', () => {
    expect(
      filterTickets(tickets, {
        ...allFilters,
        status: 'in_progress',
        priority: 'high',
        assignee: 'Luca Conti',
        service: 'Ordini e-Commerce',
      }),
    ).toEqual([tickets[0]])
  })

  it('returns no rows when criteria do not match the same ticket', () => {
    expect(
      filterTickets(tickets, {
        ...allFilters,
        status: 'waiting_user',
        priority: 'high',
      }),
    ).toEqual([])
  })
})

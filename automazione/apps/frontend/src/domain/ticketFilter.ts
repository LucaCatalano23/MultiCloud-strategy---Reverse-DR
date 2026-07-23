import type { Ticket, TicketFilters } from './types'

function normalize(value: string): string {
  return value
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLocaleLowerCase('it-IT')
    .trim()
}

export function filterTickets(
  tickets: readonly Ticket[],
  filters: TicketFilters,
): Ticket[] {
  const query = normalize(filters.query)

  return tickets.filter((ticket) => {
    if (filters.status !== 'all' && ticket.status !== filters.status) return false
    if (filters.priority !== 'all' && ticket.priority !== filters.priority) return false
    if (filters.assignee !== 'all' && ticket.assignee !== filters.assignee) return false
    if (filters.service !== 'all' && ticket.service !== filters.service) return false
    if (!query) return true

    const searchableText = normalize(
      [
        ticket.id,
        ticket.title,
        ticket.description,
        ticket.assignee,
        ticket.service,
        ticket.environment,
      ].join(' '),
    )
    return searchableText.includes(query)
  })
}

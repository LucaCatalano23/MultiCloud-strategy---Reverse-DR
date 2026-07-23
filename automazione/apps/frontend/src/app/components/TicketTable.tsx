import { ChevronDown, ChevronLeft, ChevronRight } from 'lucide-react'
import { useEffect, useMemo, useState } from 'react'
import { formatUpdatedAt } from '../../domain/presentation'
import type { Ticket } from '../../domain/types'
import { PriorityBadge, StatusBadge } from './Badges'

interface TicketTableProps {
  readonly tickets: readonly Ticket[]
  readonly selectedTicketId: string | null
  readonly onSelectTicket: (ticket: Ticket) => void
}

function visiblePageNumbers(page: number, pageCount: number): number[] {
  if (pageCount <= 5) return Array.from({ length: pageCount }, (_, index) => index + 1)
  const start = Math.min(Math.max(page - 2, 1), pageCount - 4)
  return Array.from({ length: 5 }, (_, index) => start + index)
}

export function TicketTable({
  tickets,
  selectedTicketId,
  onSelectTicket,
}: TicketTableProps) {
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(10)
  const [sortDescending, setSortDescending] = useState(true)
  const [checkedIds, setCheckedIds] = useState<ReadonlySet<string>>(
    () => new Set(tickets.slice(0, 1).map((ticket) => ticket.id)),
  )

  const sortedTickets = useMemo(
    () =>
      [...tickets].sort((left, right) => {
        const delta = new Date(left.updatedAt).valueOf() - new Date(right.updatedAt).valueOf()
        return sortDescending ? -delta : delta
      }),
    [sortDescending, tickets],
  )
  const pageCount = Math.max(1, Math.ceil(sortedTickets.length / pageSize))
  const safePage = Math.min(page, pageCount)
  const startIndex = (safePage - 1) * pageSize
  const visibleTickets = sortedTickets.slice(startIndex, startIndex + pageSize)
  const visibleIds = visibleTickets.map((ticket) => ticket.id)
  const allVisibleChecked =
    visibleIds.length > 0 && visibleIds.every((ticketId) => checkedIds.has(ticketId))

  useEffect(() => {
    setPage(1)
  }, [tickets])

  const toggleAllVisible = () => {
    setCheckedIds((current) => {
      const next = new Set(current)
      if (allVisibleChecked) visibleIds.forEach((id) => next.delete(id))
      else visibleIds.forEach((id) => next.add(id))
      return next
    })
  }

  const toggleChecked = (ticketId: string) => {
    setCheckedIds((current) => {
      const next = new Set(current)
      if (next.has(ticketId)) next.delete(ticketId)
      else next.add(ticketId)
      return next
    })
  }

  const firstShown = tickets.length === 0 ? 0 : startIndex + 1
  const lastShown = Math.min(startIndex + pageSize, tickets.length)

  return (
    <section className="ticket-table-panel" aria-label="Elenco ticket">
      <div className="table-scroll-region">
        <table role="grid">
          <caption className="sr-only">Ticket operativi</caption>
          <thead>
            <tr>
              <th className="checkbox-column" scope="col">
                <input
                  type="checkbox"
                  aria-label="Seleziona ticket visibili"
                  checked={allVisibleChecked}
                  onChange={toggleAllVisible}
                />
              </th>
              <th scope="col">ID</th>
              <th scope="col">Titolo</th>
              <th scope="col">Priorità</th>
              <th scope="col">Stato</th>
              <th scope="col">Assegnatario</th>
              <th scope="col">
                <button
                  className="sort-button"
                  type="button"
                  aria-label={`Ordina per aggiornamento ${sortDescending ? 'crescente' : 'decrescente'}`}
                  onClick={() => setSortDescending((descending) => !descending)}
                >
                  Aggiornato
                  <ChevronDown
                    className={sortDescending ? '' : 'sort-button__icon--ascending'}
                    size={14}
                    aria-hidden="true"
                  />
                </button>
              </th>
            </tr>
          </thead>
          <tbody>
            {visibleTickets.length === 0 ? (
              <tr>
                <td className="empty-table" colSpan={7}>
                  Nessun ticket corrisponde ai filtri selezionati.
                </td>
              </tr>
            ) : (
              visibleTickets.map((ticket) => (
                // A selectable row follows the WAI-ARIA grid interaction pattern.
                <tr
                  key={ticket.id}
                  className={selectedTicketId === ticket.id ? 'ticket-row--selected' : ''}
                  aria-selected={selectedTicketId === ticket.id}
                  tabIndex={0}
                  onClick={() => onSelectTicket(ticket)}
                  onKeyDown={(event) => {
                    if (event.key === 'Enter' || event.key === ' ') {
                      event.preventDefault()
                      onSelectTicket(ticket)
                    }
                  }}
                >
                  <td className="checkbox-column">
                    <input
                      type="checkbox"
                      aria-label={`Seleziona ${ticket.id}`}
                      checked={checkedIds.has(ticket.id)}
                      onClick={(event) => event.stopPropagation()}
                      onChange={() => toggleChecked(ticket.id)}
                    />
                  </td>
                  <td className="ticket-id">{ticket.id}</td>
                  <td className="ticket-title">{ticket.title}</td>
                  <td>
                    <PriorityBadge priority={ticket.priority} />
                  </td>
                  <td>
                    <StatusBadge status={ticket.status} />
                  </td>
                  <td>{ticket.assignee ?? 'Non assegnato'}</td>
                  <td>{formatUpdatedAt(ticket.updatedAt)}</td>
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>

      <footer className="table-pagination">
        <span>
          {firstShown}–{lastShown} di {tickets.length} ticket
        </span>
        <div className="pagination-controls" aria-label="Paginazione ticket">
          <button
            className="page-arrow"
            type="button"
            aria-label="Pagina precedente"
            disabled={safePage === 1}
            onClick={() => setPage((current) => Math.max(1, current - 1))}
          >
            <ChevronLeft size={16} aria-hidden="true" />
          </button>
          {visiblePageNumbers(safePage, pageCount).map((pageNumber) => (
            <button
              key={pageNumber}
              className={`page-number ${safePage === pageNumber ? 'page-number--active' : ''}`}
              type="button"
              aria-label={`Pagina ${pageNumber}`}
              aria-current={safePage === pageNumber ? 'page' : undefined}
              onClick={() => setPage(pageNumber)}
            >
              {pageNumber}
            </button>
          ))}
          <button
            className="page-arrow"
            type="button"
            aria-label="Pagina successiva"
            disabled={safePage === pageCount}
            onClick={() => setPage((current) => Math.min(pageCount, current + 1))}
          >
            <ChevronRight size={16} aria-hidden="true" />
          </button>
        </div>
        <label className="page-size">
          <span className="sr-only">Ticket per pagina</span>
          <select
            aria-label="Ticket per pagina"
            value={pageSize}
            onChange={(event) => {
              setPageSize(Number(event.target.value))
              setPage(1)
            }}
          >
            <option value="10">10 / pagina</option>
            <option value="25">25 / pagina</option>
            <option value="50">50 / pagina</option>
          </select>
          <ChevronDown size={13} aria-hidden="true" />
        </label>
      </footer>
    </section>
  )
}

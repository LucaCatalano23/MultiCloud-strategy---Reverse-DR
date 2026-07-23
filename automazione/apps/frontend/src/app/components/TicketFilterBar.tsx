import { ChevronDown, Filter, Plus } from 'lucide-react'
import type { TicketFilters } from '../../domain/types'

interface TicketFilterBarProps {
  readonly filters: TicketFilters
  readonly assignees: readonly string[]
  readonly services: readonly string[]
  readonly onChange: (filters: TicketFilters) => void
  readonly onNewTicket: () => void
}

function SelectChevron() {
  return <ChevronDown className="select-chevron" size={14} aria-hidden="true" />
}

export function TicketFilterBar({
  filters,
  assignees,
  services,
  onChange,
  onNewTicket,
}: TicketFilterBarProps) {
  const reset = () =>
    onChange({ query: '', status: 'all', priority: 'all', assignee: 'all', service: 'all' })

  return (
    <div className="filter-bar">
      <button className="filter-summary" type="button" aria-label="Filtri disponibili: 2">
        <Filter size={16} aria-hidden="true" />
        <span>Filtri</span>
        <span className="filter-count">2</span>
      </button>

      <label className="select-control">
        <span className="sr-only">Filtra per stato</span>
        <select
          aria-label="Filtra per stato"
          value={filters.status}
          onChange={(event) =>
            onChange({ ...filters, status: event.target.value as TicketFilters['status'] })
          }
        >
          <option value="all">Stato: Tutti</option>
          <option value="open">Stato: Aperto</option>
          <option value="in_progress">Stato: In corso</option>
          <option value="waiting_user">Stato: In attesa utente</option>
          <option value="waiting_third_party">Stato: In attesa terze parti</option>
          <option value="scheduled">Stato: Programmato</option>
          <option value="closed">Stato: Chiuso</option>
        </select>
        <SelectChevron />
      </label>

      <label className="select-control">
        <span className="sr-only">Filtra per priorità</span>
        <select
          aria-label="Filtra per priorità"
          value={filters.priority}
          onChange={(event) =>
            onChange({ ...filters, priority: event.target.value as TicketFilters['priority'] })
          }
        >
          <option value="all">Priorità: Tutte</option>
          <option value="high">Priorità: Alta</option>
          <option value="medium">Priorità: Media</option>
          <option value="low">Priorità: Bassa</option>
        </select>
        <SelectChevron />
      </label>

      <label className="select-control select-control--wide">
        <span className="sr-only">Filtra per assegnatario</span>
        <select
          aria-label="Filtra per assegnatario"
          value={filters.assignee}
          onChange={(event) => onChange({ ...filters, assignee: event.target.value })}
        >
          <option value="all">Assegnatario: Tutti</option>
          {assignees.map((assignee) => (
            <option key={assignee} value={assignee}>
              {assignee}
            </option>
          ))}
        </select>
        <SelectChevron />
      </label>

      <label className="select-control">
        <span className="sr-only">Filtra per servizio</span>
        <select
          aria-label="Filtra per servizio"
          value={filters.service}
          onChange={(event) => onChange({ ...filters, service: event.target.value })}
        >
          <option value="all">Servizio: Tutti</option>
          {services.map((service) => (
            <option key={service} value={service}>
              {service}
            </option>
          ))}
        </select>
        <SelectChevron />
      </label>

      <button className="reset-filters" type="button" onClick={reset}>
        Ripristina filtri
      </button>
      <button className="primary-button" type="button" onClick={onNewTicket}>
        <Plus size={17} aria-hidden="true" />
        Nuovo ticket
      </button>
    </div>
  )
}

import { Check, MoreVertical, UserRoundPlus, X } from 'lucide-react'
import { useEffect, useState } from 'react'
import { formatUpdatedAt } from '../../domain/presentation'
import type { Ticket } from '../../domain/types'
import { PriorityBadge, StatusBadge } from './Badges'

type DetailTab = 'details' | 'activity'

interface TicketDrawerProps {
  readonly ticket: Ticket
  readonly onClose: () => void
}

// Solo le sezioni con una fonte dati reale nel contratto Ticket. Allegati,
// relazioni e audit trail non sono modellati dal BFF: mostrare tab con contenuto
// fabbricato violerebbe l'onestà tecnica del progetto, quindi non esistono.
const tabs = [
  { id: 'details' as const, label: 'Dettagli' },
  { id: 'activity' as const, label: 'Attività' },
]

export function TicketDrawer({ ticket, onClose }: TicketDrawerProps) {
  const [activeTab, setActiveTab] = useState<DetailTab>('details')
  const [actionNotice, setActionNotice] = useState('')

  useEffect(() => {
    setActiveTab('details')
    setActionNotice('')
  }, [ticket.id])

  return (
    <aside className="ticket-drawer" aria-label={`Dettaglio ticket ${ticket.id}`}>
      <header className="drawer-header">
        <strong>{ticket.id}</strong>
        <h2>{ticket.title}</h2>
        <StatusBadge status={ticket.status} />
        <div className="drawer-actions">
          <button
            type="button"
            aria-label="Azioni ticket"
            onClick={() =>
              setActionNotice('Azioni ticket non disponibili in questa build: capability non esposta dal BFF.')
            }
          >
            <MoreVertical size={18} aria-hidden="true" />
          </button>
          <button type="button" aria-label="Chiudi dettagli" onClick={onClose}>
            <X size={19} aria-hidden="true" />
          </button>
        </div>
      </header>

      <div className="drawer-tabs" role="tablist" aria-label="Sezioni dettaglio ticket">
        {tabs.map((tab) => (
          <button
            key={tab.id}
            type="button"
            role="tab"
            aria-selected={activeTab === tab.id}
            aria-controls={`ticket-panel-${tab.id}`}
            id={`ticket-tab-${tab.id}`}
            onClick={() => setActiveTab(tab.id)}
          >
            {tab.label}
          </button>
        ))}
      </div>

      {actionNotice ? (
        <p className="drawer-notice" role="status">
          {actionNotice}
        </p>
      ) : null}

      <div
        className="drawer-panel"
        role="tabpanel"
        id={`ticket-panel-${activeTab}`}
        aria-labelledby={`ticket-tab-${activeTab}`}
      >
        {activeTab === 'details' ? <DetailContent ticket={ticket} onNotice={setActionNotice} /> : null}
        {activeTab === 'activity' ? <TimelineContent ticket={ticket} /> : null}
      </div>
    </aside>
  )
}

function DetailContent({
  ticket,
  onNotice,
}: {
  readonly ticket: Ticket
  readonly onNotice: (notice: string) => void
}) {
  return (
    <div className="ticket-detail-grid">
      <dl className="ticket-facts">
        <div>
          <dt>Servizio</dt>
          <dd>{ticket.service}</dd>
        </div>
        <div>
          <dt>Ambiente</dt>
          <dd>{ticket.environment}</dd>
        </div>
        <div>
          <dt>Priorità</dt>
          <dd>
            <PriorityBadge priority={ticket.priority} />
          </dd>
        </div>
        <div>
          <dt>Stato</dt>
          <dd>
            <StatusBadge status={ticket.status} />
          </dd>
        </div>
      </dl>

      <dl className="ticket-description">
        <div>
          <dt>Descrizione</dt>
          <dd>{ticket.description}</dd>
        </div>
        <div>
          <dt>Creato</dt>
          <dd>{formatUpdatedAt(ticket.createdAt)}</dd>
        </div>
        <div>
          <dt>Ultimo aggiornamento</dt>
          <dd>{formatUpdatedAt(ticket.updatedAt)}</dd>
        </div>
      </dl>

      <section className="assignment-card" aria-label="Assegnazione ticket">
        <div>
          <span>Assegnatario</span>
          <strong>{ticket.assignee ?? 'Non assegnato'}</strong>
          <button
            type="button"
            onClick={() =>
              onNotice('Riassegnazione non disponibile: capability non esposta dal BFF.')
            }
          >
            <UserRoundPlus size={14} aria-hidden="true" />
            Riassegna
          </button>
        </div>
      </section>
    </div>
  )
}

function TimelineContent({ ticket }: { readonly ticket: Ticket }) {
  return (
    <ol className="drawer-timeline">
      <li>
        <Check size={15} aria-hidden="true" />
        <span>
          <strong>Ultimo aggiornamento</strong>
          {formatUpdatedAt(ticket.updatedAt)}
          {ticket.assignee ? ` · ${ticket.assignee}` : ''}
        </span>
      </li>
      <li>
        <Check size={15} aria-hidden="true" />
        <span>
          <strong>Ticket creato</strong>
          {formatUpdatedAt(ticket.createdAt)}
        </span>
      </li>
    </ol>
  )
}

import { Check, Pencil, Trash2, X } from 'lucide-react'
import { useEffect, useState } from 'react'
import { formatUpdatedAt } from '../../domain/presentation'
import type { Ticket } from '../../domain/types'
import { PriorityBadge, StatusBadge } from './Badges'

type DetailTab = 'details' | 'activity'

interface TicketDrawerProps {
  readonly ticket: Ticket
  readonly onClose: () => void
  readonly onEdit: () => void
  readonly onDelete: () => Promise<void>
}

// Solo le sezioni con una fonte dati reale nel contratto Ticket. Allegati,
// relazioni e audit trail non sono modellati dal BFF: mostrare tab con contenuto
// fabbricato violerebbe l'onestà tecnica del progetto, quindi non esistono.
const tabs = [
  { id: 'details' as const, label: 'Dettagli' },
  { id: 'activity' as const, label: 'Attività' },
]

export function TicketDrawer({ ticket, onClose, onEdit, onDelete }: TicketDrawerProps) {
  const [activeTab, setActiveTab] = useState<DetailTab>('details')
  const [confirmingDelete, setConfirmingDelete] = useState(false)
  const [deleting, setDeleting] = useState(false)
  const [error, setError] = useState('')

  useEffect(() => {
    setActiveTab('details')
    setConfirmingDelete(false)
    setDeleting(false)
    setError('')
  }, [ticket.id])

  const handleDelete = () => {
    setDeleting(true)
    setError('')
    void onDelete().catch((reason: unknown) => {
      setError(reason instanceof Error ? reason.message : 'Eliminazione ticket non riuscita')
      setDeleting(false)
      setConfirmingDelete(false)
    })
  }

  return (
    <aside className="ticket-drawer" aria-label={`Dettaglio ticket ${ticket.id}`}>
      <header className="drawer-header">
        <strong>{ticket.id}</strong>
        <h2>{ticket.title}</h2>
        <StatusBadge status={ticket.status} />
        <div className="drawer-actions">
          <button type="button" aria-label="Modifica ticket" onClick={onEdit}>
            <Pencil size={17} aria-hidden="true" />
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

      <div
        className="drawer-panel"
        role="tabpanel"
        id={`ticket-panel-${activeTab}`}
        aria-labelledby={`ticket-tab-${activeTab}`}
      >
        {activeTab === 'details' ? <DetailContent ticket={ticket} /> : null}
        {activeTab === 'activity' ? <TimelineContent ticket={ticket} /> : null}
      </div>

      <footer className="drawer-footer">
        {error ? (
          <p className="form-error" role="alert">
            {error}
          </p>
        ) : null}
        {confirmingDelete ? (
          <div className="drawer-confirm" role="group" aria-label="Conferma eliminazione">
            <span>Eliminare definitivamente questo ticket?</span>
            <div className="drawer-confirm-actions">
              <button
                className="secondary-button"
                type="button"
                onClick={() => setConfirmingDelete(false)}
                disabled={deleting}
              >
                Annulla
              </button>
              <button
                className="danger-button"
                type="button"
                onClick={handleDelete}
                disabled={deleting}
              >
                {deleting ? 'Eliminazione…' : 'Elimina'}
              </button>
            </div>
          </div>
        ) : (
          <button
            className="danger-button"
            type="button"
            onClick={() => setConfirmingDelete(true)}
          >
            <Trash2 size={15} aria-hidden="true" />
            Elimina ticket
          </button>
        )}
      </footer>
    </aside>
  )
}

function DetailContent({ ticket }: { readonly ticket: Ticket }) {
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
          <dt>Assegnatario</dt>
          <dd>{ticket.assignee ?? 'Non assegnato'}</dd>
        </div>
        <div>
          <dt>Creato da</dt>
          <dd>{ticket.createdBy}</dd>
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
          {formatUpdatedAt(ticket.createdAt)} · {ticket.createdBy}
        </span>
      </li>
    </ol>
  )
}

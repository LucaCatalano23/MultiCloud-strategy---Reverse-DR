import { Check, MoreVertical, UserRoundPlus, X } from 'lucide-react'
import { useEffect, useState } from 'react'
import { formatUpdatedAt } from '../../domain/presentation'
import type { Ticket } from '../../domain/types'
import { PriorityBadge, StatusBadge } from './Badges'

type DetailTab = 'details' | 'activity' | 'attachments' | 'relations' | 'audit'

interface TicketDrawerProps {
  readonly ticket: Ticket
  readonly onClose: () => void
}

const tabs = [
  { id: 'details' as const, label: 'Dettagli' },
  { id: 'activity' as const, label: 'Attività' },
  { id: 'attachments' as const, label: 'Allegati (2)' },
  { id: 'relations' as const, label: 'Relazioni (1)' },
  { id: 'audit' as const, label: 'Audit trail' },
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
            onClick={() => setActionNotice('Azioni avanzate disponibili dal menu contestuale.')}
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
        {activeTab === 'activity' ? (
          <TimelineContent ticket={ticket} />
        ) : null}
        {activeTab === 'attachments' ? (
          <SimpleList
            items={['log-failover-0578.txt · 24 KB', 'screenshot-monitoraggio.png · 182 KB']}
          />
        ) : null}
        {activeTab === 'relations' ? (
          <SimpleList items={['TKT-2025-0577 · Replica RDS lag superiore a soglia']} />
        ) : null}
        {activeTab === 'audit' ? (
          <SimpleList
            items={[
              '09:42 · Luca Conti ha cambiato lo stato in In corso',
              '08:27 · Marco Rossi ha creato il ticket',
            ]}
          />
        ) : null}
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
          <dt>SLA</dt>
          <dd>
            Entro 2h <span className="sla-deadline">Scadenza: Oggi, 11:42</span>
          </dd>
        </div>
      </dl>

      <dl className="ticket-description">
        <div>
          <dt>Descrizione</dt>
          <dd>{ticket.description}</dd>
        </div>
        <div>
          <dt>Impatto</dt>
          <dd>Utenti e-commerce impossibilitati a concludere ordini.</dd>
        </div>
        <div>
          <dt>Creato</dt>
          <dd>{formatUpdatedAt(ticket.createdAt)} da Marco Rossi</dd>
        </div>
        <div>
          <dt>Ultimo aggiornamento</dt>
          <dd>{formatUpdatedAt(ticket.updatedAt)} da {ticket.assignee ?? 'Non assegnato'}</dd>
        </div>
      </dl>

      <section className="assignment-card" aria-label="Assegnazione ticket">
        <div>
          <span>Assegnatario</span>
          <strong>{ticket.assignee ?? 'Non assegnato'}</strong>
          <button
            type="button"
            onClick={() => onNotice('Richiesta di riassegnazione pronta per la conferma.')}
          >
            <UserRoundPlus size={14} aria-hidden="true" />
            Riassegna
          </button>
        </div>
        <div>
          <span>Team</span>
          <strong>DR Operations</strong>
        </div>
        <div>
          <span>Watcher (3)</span>
          <span className="watchers" aria-label="Sara Bianchi, Marco Rossi, Giulia Verdi">
            <i>SB</i>
            <i>MR</i>
            <i>GV</i>
            <i>+</i>
          </span>
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
          <strong>Stato aggiornato</strong>
          {formatUpdatedAt(ticket.updatedAt)} · {ticket.assignee ?? 'Non assegnato'}
        </span>
      </li>
      <li>
        <Check size={15} aria-hidden="true" />
        <span>
          <strong>Ticket creato</strong>
          {formatUpdatedAt(ticket.createdAt)} · Marco Rossi
        </span>
      </li>
    </ol>
  )
}

function SimpleList({ items }: { readonly items: readonly string[] }) {
  return (
    <ul className="drawer-simple-list">
      {items.map((item) => (
        <li key={item}>{item}</li>
      ))}
    </ul>
  )
}

import { X } from 'lucide-react'
import { useEffect, useRef, useState } from 'react'
import type { Ticket, TicketPriority, TicketStatus, UpdateTicketInput } from '../../domain/types'

interface EditTicketDialogProps {
  readonly ticket: Ticket | null
  readonly onClose: () => void
  readonly onSave: (id: string, input: UpdateTicketInput) => Promise<void>
}

const statusOptions: ReadonlyArray<{ readonly value: TicketStatus; readonly label: string }> = [
  { value: 'open', label: 'Aperto' },
  { value: 'in_progress', label: 'In corso' },
  { value: 'waiting_user', label: 'In attesa utente' },
  { value: 'waiting_third_party', label: 'In attesa terze parti' },
  { value: 'scheduled', label: 'Programmato' },
  { value: 'closed', label: 'Chiuso' },
]

function toForm(ticket: Ticket): UpdateTicketInput {
  return {
    title: ticket.title,
    description: ticket.description,
    priority: ticket.priority,
    status: ticket.status,
    service: ticket.service,
    environment: ticket.environment,
    assignee: ticket.assignee,
  }
}

export function EditTicketDialog({ ticket, onClose, onSave }: EditTicketDialogProps) {
  const [form, setForm] = useState<UpdateTicketInput | null>(null)
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState('')
  const titleRef = useRef<HTMLInputElement>(null)

  useEffect(() => {
    if (!ticket) return
    setForm(toForm(ticket))
    setSubmitting(false)
    setError('')
    const frame = window.requestAnimationFrame(() => titleRef.current?.focus())
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') onClose()
    }
    document.addEventListener('keydown', onKeyDown)
    return () => {
      window.cancelAnimationFrame(frame)
      document.removeEventListener('keydown', onKeyDown)
    }
  }, [onClose, ticket])

  if (!ticket || !form) return null

  const assigneeValue = form.assignee ?? ''

  return (
    <div className="dialog-backdrop">
      <button
        className="dialog-dismiss-layer"
        type="button"
        aria-label="Chiudi finestra"
        onClick={onClose}
      />
      <section
        className="ticket-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="edit-ticket-title"
      >
        <header>
          <div>
            <h2 id="edit-ticket-title">Modifica ticket</h2>
            <p>{ticket.id}</p>
          </div>
          <button type="button" aria-label="Chiudi finestra" onClick={onClose}>
            <X size={20} aria-hidden="true" />
          </button>
        </header>

        <form
          onSubmit={(event) => {
            event.preventDefault()
            setSubmitting(true)
            setError('')
            void onSave(ticket.id, {
              ...form,
              title: form.title.trim(),
              description: form.description.trim(),
              assignee: assigneeValue.trim() === '' ? null : assigneeValue.trim(),
            })
              .then(onClose)
              .catch((reason: unknown) => {
                setError(reason instanceof Error ? reason.message : 'Aggiornamento ticket non riuscito')
                setSubmitting(false)
              })
          }}
        >
          <label>
            <span>Titolo</span>
            <input
              ref={titleRef}
              name="title"
              type="text"
              required
              minLength={3}
              maxLength={160}
              value={form.title}
              onChange={(event) => setForm({ ...form, title: event.target.value })}
            />
          </label>
          <label>
            <span>Descrizione</span>
            <textarea
              name="description"
              required
              minLength={1}
              maxLength={4000}
              rows={5}
              value={form.description}
              onChange={(event) => setForm({ ...form, description: event.target.value })}
            />
          </label>
          <div className="dialog-field-row">
            <label>
              <span>Priorità</span>
              <select
                name="priority"
                value={form.priority}
                onChange={(event) =>
                  setForm({ ...form, priority: event.target.value as TicketPriority })
                }
              >
                <option value="high">Alta</option>
                <option value="medium">Media</option>
                <option value="low">Bassa</option>
              </select>
            </label>
            <label>
              <span>Stato</span>
              <select
                name="status"
                value={form.status}
                onChange={(event) =>
                  setForm({ ...form, status: event.target.value as TicketStatus })
                }
              >
                {statusOptions.map((option) => (
                  <option key={option.value} value={option.value}>
                    {option.label}
                  </option>
                ))}
              </select>
            </label>
          </div>
          <div className="dialog-field-row">
            <label>
              <span>Servizio</span>
              <select
                name="service"
                value={form.service}
                onChange={(event) => setForm({ ...form, service: event.target.value })}
              >
                <option>Ordini e-Commerce</option>
                <option>Database</option>
                <option>Identity</option>
                <option>Backup</option>
                <option>Networking</option>
                <option>ERP</option>
              </select>
            </label>
            <label>
              <span>Ambiente</span>
              <select
                name="environment"
                value={form.environment}
                onChange={(event) => setForm({ ...form, environment: event.target.value })}
              >
                <option>AWS – Primary</option>
                <option>AWS – DR (eu-west-1)</option>
                <option>On-prem DR</option>
                <option>Entra ID</option>
              </select>
            </label>
          </div>
          <label>
            <span>Assegnatario</span>
            <input
              name="assignee"
              type="text"
              maxLength={255}
              placeholder="Non assegnato"
              value={assigneeValue}
              onChange={(event) => setForm({ ...form, assignee: event.target.value })}
            />
          </label>

          {error ? (
            <p className="form-error" role="alert">
              {error}
            </p>
          ) : null}
          <footer>
            <button className="secondary-button" type="button" onClick={onClose}>
              Annulla
            </button>
            <button className="primary-button" type="submit" disabled={submitting}>
              {submitting ? 'Salvataggio…' : 'Salva modifiche'}
            </button>
          </footer>
        </form>
      </section>
    </div>
  )
}

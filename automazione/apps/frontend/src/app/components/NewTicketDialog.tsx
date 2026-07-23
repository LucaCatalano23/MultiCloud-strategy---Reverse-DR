import { X } from 'lucide-react'
import { useEffect, useRef, useState } from 'react'
import type { CreateTicketInput, TicketPriority } from '../../domain/types'

interface NewTicketDialogProps {
  readonly open: boolean
  readonly onClose: () => void
  readonly onCreate: (input: CreateTicketInput) => Promise<void>
}

const initialForm: CreateTicketInput = {
  title: '',
  description: '',
  priority: 'medium',
  service: 'Ordini e-Commerce',
  environment: 'AWS – Primary',
  assignee: null,
}

export function NewTicketDialog({ open, onClose, onCreate }: NewTicketDialogProps) {
  const [form, setForm] = useState<CreateTicketInput>(initialForm)
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState('')
  const titleRef = useRef<HTMLInputElement>(null)

  useEffect(() => {
    if (!open) return
    setForm(initialForm)
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
  }, [onClose, open])

  if (!open) return null

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
        aria-labelledby="new-ticket-title"
      >
        <header>
          <div>
            <h2 id="new-ticket-title">Crea nuovo ticket</h2>
            <p>Inserisci le informazioni operative essenziali.</p>
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
            void onCreate({ ...form, title: form.title.trim(), description: form.description.trim() })
              .then(onClose)
              .catch((reason: unknown) => {
                setError(reason instanceof Error ? reason.message : 'Creazione ticket non riuscita')
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
              minLength={10}
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
          </div>
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
              {submitting ? 'Creazione…' : 'Crea ticket'}
            </button>
          </footer>
        </form>
      </section>
    </div>
  )
}

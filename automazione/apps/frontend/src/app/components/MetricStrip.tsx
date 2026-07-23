import { Bot, ClipboardList, Clock3, Flag } from 'lucide-react'
import { useMemo } from 'react'
import type { Ticket } from '../../domain/types'

interface MetricStripProps {
  readonly tickets: readonly Ticket[]
}

// Placeholder esplicito per le metriche che non hanno ancora una fonte dati nel
// BFF (SLA non è modellato; le automazioni dipendono dal ponte eventi
// ticket→automation non ancora implementato). Meglio dichiarare l'assenza che
// mostrare un numero finto accanto a dati reali.
const UNAVAILABLE = '—'

export function MetricStrip({ tickets }: MetricStripProps) {
  const openCount = useMemo(
    () => tickets.filter((ticket) => ticket.status !== 'closed').length,
    [tickets],
  )
  const highPriorityCount = useMemo(
    () => tickets.filter((ticket) => ticket.priority === 'high').length,
    [tickets],
  )

  const metrics = [
    {
      label: 'Ticket aperti',
      value: String(openCount),
      detail: 'Stato diverso da chiuso',
      tone: 'blue',
      icon: ClipboardList,
    },
    {
      label: 'Alta priorità',
      value: String(highPriorityCount),
      detail: 'Priorità alta',
      tone: 'red',
      icon: Flag,
    },
    {
      label: 'SLA a rischio',
      value: UNAVAILABLE,
      detail: 'Non disponibile in questa build',
      tone: 'orange',
      icon: Clock3,
    },
    {
      label: 'Automazioni oggi',
      value: UNAVAILABLE,
      detail: 'Non disponibile in questa build',
      tone: 'green',
      icon: Bot,
    },
  ] as const

  return (
    <section className="metric-strip" aria-label="Metriche operative">
      {metrics.map(({ label, value, detail, tone, icon: Icon }) => (
        <article className={`metric metric--${tone}`} key={label}>
          <div>
            <h2>{label}</h2>
            <strong>{value}</strong>
            <p>{detail}</p>
          </div>
          <span className="metric__icon" aria-hidden="true">
            <Icon size={24} strokeWidth={1.8} />
          </span>
        </article>
      ))}
    </section>
  )
}

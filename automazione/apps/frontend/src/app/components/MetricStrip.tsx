import { Bot, ClipboardList, Clock3, Flag } from 'lucide-react'

const metrics = [
  {
    label: 'Ticket aperti',
    value: '128',
    trend: '↓',
    detail: '−12% vs ieri',
    tone: 'blue',
    icon: ClipboardList,
  },
  {
    label: 'Alta priorità',
    value: '19',
    trend: '↗',
    detail: '+3 vs ieri',
    tone: 'red',
    icon: Flag,
  },
  {
    label: 'SLA a rischio',
    value: '7',
    trend: '↗',
    detail: '+2 vs ieri',
    tone: 'orange',
    icon: Clock3,
  },
  {
    label: 'Automazioni oggi',
    value: '24',
    trend: '↗',
    detail: '+8 vs ieri',
    tone: 'green',
    icon: Bot,
  },
] as const

export function MetricStrip() {
  return (
    <section className="metric-strip" aria-label="Metriche operative">
      {metrics.map(({ label, value, trend, detail, tone, icon: Icon }) => (
        <article className={`metric metric--${tone}`} key={label}>
          <div>
            <h2>{label}</h2>
            <strong>{value}</strong>
            <p>
              <span aria-hidden="true">{trend}</span> {detail}
            </p>
          </div>
          <span className="metric__icon" aria-hidden="true">
            <Icon size={24} strokeWidth={1.8} />
          </span>
        </article>
      ))}
    </section>
  )
}

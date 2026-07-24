import {
  Check,
  ChevronUp,
  CircleAlert,
  Clock3,
  Cloud,
  Diamond,
  Flag,
  MessageSquareText,
} from 'lucide-react'
import { useState } from 'react'
import { formatDuration, formatUpdatedAt } from '../../domain/presentation'
import type { DrMetricStatus, PlatformService, PlatformStatus } from '../../domain/types'

interface OperationsRailProps {
  readonly platform: PlatformStatus
}

const statusLabels = {
  operational: 'Operativo',
  degraded: 'Degradato',
  unavailable: 'Non disponibile',
} as const

const drStatusLabels: Readonly<Record<DrMetricStatus, string>> = {
  ok: 'Entro obiettivo',
  warning: 'Oltre obiettivo',
  critical: 'Critico',
  unknown: 'Mai misurato',
}

// La metrica DR ha quattro stati ma la pillola ne conosce tre: mappiamo su
// quelle esistenti invece di duplicare la scala cromatica.
const drStatusClasses: Readonly<Record<DrMetricStatus, string>> = {
  ok: 'operational',
  warning: 'degraded',
  critical: 'unavailable',
  unknown: 'unknown',
}

interface DrMetricRowProps {
  readonly label: string
  readonly value: number | null
  readonly targetSeconds: number
  readonly status: DrMetricStatus
  readonly measuredAt: string | null
  readonly note: string
}

function DrMetricRow({
  label,
  value,
  targetSeconds,
  status,
  measuredAt,
  note,
}: DrMetricRowProps) {
  return (
    <div className="platform-item platform-item--metric">
      <Clock3 size={30} strokeWidth={1.7} aria-hidden="true" />
      <div>
        <strong>
          {label} {formatDuration(value)}
        </strong>
        <span>
          Obiettivo {formatDuration(targetSeconds)}
          {measuredAt ? ` · ${formatUpdatedAt(measuredAt)}` : ''}
        </span>
        <span className="metric-note">{note}</span>
      </div>
      <span className={`health health--${drStatusClasses[status]}`}>
        <i aria-hidden="true" />
        {drStatusLabels[status]}
      </span>
    </div>
  )
}

function ServiceIcon({ service }: { readonly service: PlatformService }) {
  if (service.id === 'identity') {
    return <Diamond className="identity-icon" size={29} fill="currentColor" aria-hidden="true" />
  }
  return <Cloud className="aws-icon" size={29} aria-hidden="true" />
}

export function OperationsRail({ platform }: OperationsRailProps) {
  const [platformOpen, setPlatformOpen] = useState(true)
  const [showAllActivities, setShowAllActivities] = useState(false)
  const visibleActivities = showAllActivities
    ? platform.activities
    : platform.activities.slice(0, 5)

  return (
    <aside className="operations-rail" aria-label="Stato operativo">
      <section className="rail-panel platform-panel">
        <button
          type="button"
          className="rail-heading rail-heading--button"
          aria-expanded={platformOpen}
          onClick={() => setPlatformOpen((open) => !open)}
        >
          <span>Stato piattaforma</span>
          <ChevronUp
            className={platformOpen ? '' : 'rail-chevron--closed'}
            size={16}
            aria-hidden="true"
          />
        </button>
        {platformOpen ? (
          <div className="platform-list">
            {platform.services.map((service) => (
              <div className="platform-item" key={service.id}>
                <ServiceIcon service={service} />
                <div>
                  <strong>{service.name}</strong>
                  <span>Stato</span>
                </div>
                <span className={`health health--${service.status}`}>
                  <i aria-hidden="true" />
                  {statusLabels[service.status]}
                </span>
              </div>
            ))}
            <DrMetricRow
              label="RPO"
              value={platform.dr.backup.ageSeconds}
              targetSeconds={platform.dr.backup.targetSeconds}
              status={platform.dr.backup.status}
              measuredAt={platform.dr.backup.lastSuccessAt}
              note="Età dell'ultimo backup completato"
            />
            <DrMetricRow
              label="RTO"
              value={platform.dr.failover.durationSeconds}
              targetSeconds={platform.dr.failover.targetSeconds}
              status={platform.dr.failover.status}
              measuredAt={platform.dr.failover.lastPromotionAt}
              note="Durata dell'ultimo failover, rilevamento guasto escluso"
            />
          </div>
        ) : null}
      </section>

      <section className="rail-panel activity-panel">
        <header className="rail-heading">
          <span>Attività recenti</span>
          <button type="button" onClick={() => setShowAllActivities((all) => !all)}>
            {showAllActivities ? 'Riduci' : 'Vedi tutte'}
          </button>
        </header>
        <ol className="activity-list">
          {visibleActivities.map((activity) => (
            <li key={activity.id} className={`activity activity--${activity.kind}`}>
              <span className="activity__icon" aria-hidden="true">
                {activity.kind === 'comment' ? <MessageSquareText size={13} /> : null}
                {activity.kind === 'automation' || activity.kind === 'resolved' ? (
                  <Check size={13} />
                ) : null}
                {activity.kind === 'sla' ? <CircleAlert size={13} /> : null}
                {activity.kind === 'ticket' ? <Flag size={13} /> : null}
              </span>
              <div>
                <strong>{activity.title}</strong>
                <p>{activity.description}</p>
                <span className="activity__meta">
                  <span>{activity.actor}</span>
                  <time dateTime={activity.occurredAt}>{formatUpdatedAt(activity.occurredAt)}</time>
                </span>
              </div>
            </li>
          ))}
        </ol>
      </section>
    </aside>
  )
}

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
import { formatUpdatedAt } from '../../domain/presentation'
import type { PlatformService, PlatformStatus } from '../../domain/types'

interface OperationsRailProps {
  readonly platform: PlatformStatus
}

const statusLabels = {
  operational: 'Operativo',
  degraded: 'Degradato',
  unavailable: 'Non disponibile',
} as const

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
            <div className="platform-item platform-item--rpo">
              <Clock3 size={30} strokeWidth={1.7} aria-hidden="true" />
              <div>
                <strong>RPO {platform.rpoMinutes} min</strong>
                <span>Obiettivo {platform.rpoTargetMinutes} min</span>
              </div>
              <span className="health health--operational">
                <i aria-hidden="true" /> OK
              </span>
            </div>
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

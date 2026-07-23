import type { TicketPriority, TicketStatus } from '../../domain/types'
import { priorityLabels, statusLabels } from '../../domain/presentation'

export function PriorityBadge({ priority }: { readonly priority: TicketPriority }) {
  return <span className={`priority-badge priority-badge--${priority}`}>{priorityLabels[priority]}</span>
}

export function StatusBadge({ status }: { readonly status: TicketStatus }) {
  return (
    <span className={`status-badge status-badge--${status}`}>
      <span aria-hidden="true" />
      {statusLabels[status]}
    </span>
  )
}

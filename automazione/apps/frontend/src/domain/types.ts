export type TicketPriority = 'high' | 'medium' | 'low'

export type TicketStatus =
  | 'open'
  | 'in_progress'
  | 'waiting_user'
  | 'waiting_third_party'
  | 'scheduled'
  | 'closed'

export interface Ticket {
  readonly id: string
  readonly title: string
  readonly description: string
  readonly priority: TicketPriority
  readonly status: TicketStatus
  readonly assignee: string | null
  readonly service: string
  readonly environment: string
  readonly createdAt: string
  readonly updatedAt: string
}

export interface CreateTicketInput {
  readonly title: string
  readonly description: string
  readonly priority: TicketPriority
  readonly service: string
  readonly environment: string
  readonly assignee?: string | null
}

export interface AuthenticatedUser {
  readonly id: string
  readonly displayName: string
  readonly email: string
  readonly roles: readonly string[]
}

export interface SiteContext {
  readonly mode: 'primary' | 'dr'
  readonly identityProvider: 'entra-id' | 'keycloak'
  readonly name: string
}

export interface SessionInfo {
  readonly authenticated: boolean
  readonly user: AuthenticatedUser | null
  readonly site: SiteContext
}

export type PlatformServiceStatus = 'operational' | 'degraded' | 'unavailable'

export interface PlatformService {
  readonly id: string
  readonly name: string
  readonly status: PlatformServiceStatus
}

export interface RecentActivity {
  readonly id: string
  readonly kind: 'ticket' | 'comment' | 'automation' | 'sla' | 'resolved'
  readonly title: string
  readonly description: string
  readonly actor: string
  readonly occurredAt: string
}

export interface PlatformStatus {
  readonly services: readonly PlatformService[]
  readonly rpoMinutes: number
  readonly rpoTargetMinutes: number
  readonly activities: readonly RecentActivity[]
}

export interface TicketFilters {
  readonly query: string
  readonly status: TicketStatus | 'all'
  readonly priority: TicketPriority | 'all'
  readonly assignee: string
  readonly service: string
}

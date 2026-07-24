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
  readonly createdBy: string
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

export interface UpdateTicketInput {
  readonly title: string
  readonly description: string
  readonly priority: TicketPriority
  readonly status: TicketStatus
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

export type DrMetricStatus = 'ok' | 'warning' | 'critical' | 'unknown'

/**
 * Metriche DR misurate, non configurate.
 *
 * `ageSeconds`/`durationSeconds` sono `null` quando la misura non esiste
 * ancora (nessun backup registrato, nessun failover mai eseguito): la UI deve
 * mostrare "non disponibile", mai un placeholder numerico che sembrerebbe un
 * dato reale.
 */
export interface BackupMetric {
  readonly lastSuccessAt: string | null
  readonly ageSeconds: number | null
  readonly targetSeconds: number
  readonly status: DrMetricStatus
}

export interface FailoverMetric {
  readonly lastPromotionAt: string | null
  readonly durationSeconds: number | null
  readonly targetSeconds: number
  readonly status: DrMetricStatus
}

export interface DrMetrics {
  readonly backup: BackupMetric
  readonly failover: FailoverMetric
}

export interface PlatformStatus {
  readonly services: readonly PlatformService[]
  readonly dr: DrMetrics
  readonly activities: readonly RecentActivity[]
}

/** Esito dell'esecuzione della function di piattaforma su un ticket. */
export interface AutomationRun {
  readonly id: string
  readonly provider: string
  readonly status: 'running' | 'succeeded' | 'failed'
  readonly errorCode: string | null
  readonly result: Readonly<Record<string, unknown>>
  readonly updatedAt: string
}

export interface TicketFilters {
  readonly query: string
  readonly status: TicketStatus | 'all'
  readonly priority: TicketPriority | 'all'
  readonly assignee: string
  readonly service: string
}

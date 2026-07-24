import type {
  CreateTicketInput,
  PlatformStatus,
  SessionInfo,
  Ticket,
} from '../domain/types'
import type { HeliosGateway } from './types'

const primaryTicketSeeds: readonly Omit<Ticket, 'createdBy'>[] = [
  {
    id: 'TKT-2025-0578',
    title: 'Failover DB ordine non completato su AWS DR',
    description:
      'Il processo di failover del database ordini non si è completato correttamente sul sito DR. Il servizio applicativo è in stato degradato.',
    priority: 'high',
    status: 'in_progress',
    assignee: 'Luca Conti',
    service: 'Ordini e-Commerce',
    environment: 'AWS – DR (eu-west-1)',
    createdAt: '2026-07-22T08:27:00+02:00',
    updatedAt: '2026-07-22T09:42:00+02:00',
  },
  {
    id: 'TKT-2025-0577',
    title: 'Replica RDS lag superiore a soglia 2 min',
    description: 'La replica RDS ha superato la soglia operativa prevista dal runbook.',
    priority: 'high',
    status: 'open',
    assignee: 'Sara Bianchi',
    service: 'Database',
    environment: 'AWS – Primary',
    createdAt: '2026-07-22T09:02:00+02:00',
    updatedAt: '2026-07-22T09:15:00+02:00',
  },
  {
    id: 'TKT-2025-0576',
    title: 'Autenticazione Entra ID intermittente per utenti esterni',
    description: 'Alcuni utenti esterni ricevono timeout durante il login federato.',
    priority: 'medium',
    status: 'waiting_user',
    assignee: 'Marco Rossi',
    service: 'Identity',
    environment: 'Entra ID',
    createdAt: '2026-07-22T08:20:00+02:00',
    updatedAt: '2026-07-22T08:55:00+02:00',
  },
  {
    id: 'TKT-2025-0575',
    title: 'Test di ripristino applicazione ERP pianificato',
    description: 'Esecuzione programmata del test di ripristino trimestrale.',
    priority: 'low',
    status: 'scheduled',
    assignee: 'Giulia Verdi',
    service: 'ERP',
    environment: 'AWS – DR (eu-west-1)',
    createdAt: '2026-07-22T08:00:00+02:00',
    updatedAt: '2026-07-22T08:30:00+02:00',
  },
  {
    id: 'TKT-2025-0574',
    title: 'Alert backup fallito – S3 Glacier (Archivio)',
    description: 'Il job di archiviazione non ha completato il caricamento su Glacier.',
    priority: 'high',
    status: 'in_progress',
    assignee: 'Alessandro Neri',
    service: 'Backup',
    environment: 'AWS – Primary',
    createdAt: '2026-07-22T07:55:00+02:00',
    updatedAt: '2026-07-22T08:12:00+02:00',
  },
  {
    id: 'TKT-2025-0573',
    title: 'Verifica integrità snapshot EBS volumi critici',
    description: 'Verifica automatica degli snapshot relativi ai volumi critici.',
    priority: 'medium',
    status: 'open',
    assignee: 'Marta Colombo',
    service: 'Backup',
    environment: 'AWS – Primary',
    createdAt: '2026-07-22T07:30:00+02:00',
    updatedAt: '2026-07-22T07:58:00+02:00',
  },
  {
    id: 'TKT-2025-0572',
    title: 'Timeout connessione VPN sito secondario',
    description: 'Il tunnel VPN del sito secondario presenta timeout intermittenti.',
    priority: 'high',
    status: 'in_progress',
    assignee: 'Davide Ricci',
    service: 'Networking',
    environment: 'On-prem DR',
    createdAt: '2026-07-22T07:12:00+02:00',
    updatedAt: '2026-07-22T07:33:00+02:00',
  },
  {
    id: 'TKT-2025-0571',
    title: 'Aggiornamento runbook DR Windows Server',
    description: 'Allineamento completato del runbook di ripristino Windows Server.',
    priority: 'low',
    status: 'closed',
    assignee: 'Luca Conti',
    service: 'Runbook DR',
    environment: 'On-prem DR',
    createdAt: '2026-07-21T15:20:00+02:00',
    updatedAt: '2026-07-21T17:21:00+02:00',
  },
  {
    id: 'TKT-2025-0570',
    title: 'Spazio disco insufficiente su azionamento DR',
    description: 'La capacità libera del volume DR è scesa sotto la soglia di sicurezza.',
    priority: 'medium',
    status: 'waiting_third_party',
    assignee: 'Sara Bianchi',
    service: 'Storage',
    environment: 'On-prem DR',
    createdAt: '2026-07-21T15:10:00+02:00',
    updatedAt: '2026-07-21T16:40:00+02:00',
  },
  {
    id: 'TKT-2025-0569',
    title: 'Validazione RPO servizio Pagamenti',
    description: 'Verifica dell’obiettivo RPO del servizio Pagamenti dopo il backup.',
    priority: 'high',
    status: 'in_progress',
    assignee: 'Marco Rossi',
    service: 'Pagamenti',
    environment: 'AWS – Primary',
    createdAt: '2026-07-21T15:35:00+02:00',
    updatedAt: '2026-07-21T16:05:00+02:00',
  },
]

// Modalità dimostrativa: il creatore seed coincide, per plausibilità, con
// l'assegnatario. In produzione il valore arriva dal token dell'utente reale
// (vedi ticket-service _creator_identity).
const primaryTickets: readonly Ticket[] = primaryTicketSeeds.map((seed) => ({
  ...seed,
  createdBy: seed.assignee ?? 'Luca Conti',
}))

const generatedTitles = [
  'Verifica replica database applicativa',
  'Controllo esito backup incrementale',
  'Aggiornamento procedura di failback',
  'Analisi latenza collegamento secondario',
  'Rotazione certificato servizio interno',
] as const
const generatedServices = ['Database', 'Backup', 'Runbook DR', 'Networking', 'Identity'] as const
const generatedAssignees = [
  'Luca Conti',
  'Sara Bianchi',
  'Marco Rossi',
  'Giulia Verdi',
  'Alessandro Neri',
] as const
const generatedStatuses = ['open', 'in_progress', 'waiting_user', 'scheduled', 'closed'] as const
const generatedPriorities = ['high', 'medium', 'low'] as const

function buildGeneratedTickets(): Ticket[] {
  return Array.from({ length: 118 }, (_, index) => {
    const ticketNumber = 568 - index
    const variant = index % generatedTitles.length
    const priority = generatedPriorities[index % generatedPriorities.length] ?? 'medium'
    return {
      id: `TKT-2025-${String(ticketNumber).padStart(4, '0')}`,
      title: `${generatedTitles[variant] ?? generatedTitles[0]} #${ticketNumber}`,
      description: 'Ticket operativo generato per la vista dimostrativa di Helios Desk.',
      priority,
      status: generatedStatuses[variant] ?? 'open',
      assignee: generatedAssignees[variant] ?? 'Luca Conti',
      service: generatedServices[variant] ?? 'Database',
      environment: variant % 2 === 0 ? 'AWS – Primary' : 'On-prem DR',
      createdBy: generatedAssignees[variant] ?? 'Luca Conti',
      createdAt: '2026-07-20T08:00:00+02:00',
      updatedAt: `2026-07-${String(20 - (index % 8)).padStart(2, '0')}T12:00:00+02:00`,
    }
  })
}

const demoSession: SessionInfo = {
  authenticated: true,
  user: {
    id: 'demo-luca-conti',
    displayName: 'Luca Conti',
    email: 'luca.conti@example.test',
    roles: ['operatore'],
  },
  site: { mode: 'primary', identityProvider: 'entra-id', name: 'Primario' },
}

const demoPlatformStatus: PlatformStatus = {
  services: [
    { id: 'aws', name: 'AWS Primary', status: 'operational' },
    { id: 'identity', name: 'Entra ID', status: 'operational' },
  ],
  // In modalità dimostrativa non esiste né un CronJob di backup né un playbook
  // di failover: i valori sono verosimili ma inventati, esattamente come i
  // ticket seed. Con `demoMode: false` le stesse metriche arrivano dalla
  // tabella `dr_telemetry` scritta dai due orchestratori reali.
  dr: {
    backup: {
      lastSuccessAt: '2026-07-22T09:38:00+02:00',
      ageSeconds: 240,
      targetSeconds: 900,
      status: 'ok',
    },
    failover: {
      lastPromotionAt: '2026-07-19T02:14:00+02:00',
      durationSeconds: 1265,
      targetSeconds: 1800,
      status: 'ok',
    },
  },
  activities: [
    {
      id: 'activity-1',
      kind: 'ticket',
      title: 'TKT-2025-0578 aggiornato',
      description: 'Stato cambiato in In corso',
      actor: 'Luca Conti',
      occurredAt: '2026-07-22T09:42:00+02:00',
    },
    {
      id: 'activity-2',
      kind: 'comment',
      title: 'TKT-2025-0576 commentato',
      description: 'In attesa di conferma utente',
      actor: 'Marco Rossi',
      occurredAt: '2026-07-22T08:55:00+02:00',
    },
    {
      id: 'activity-3',
      kind: 'automation',
      title: 'Automazione completata',
      description: 'DR - Verifica backup giornaliera',
      actor: 'Helios Bot',
      occurredAt: '2026-07-22T08:30:00+02:00',
    },
    {
      id: 'activity-4',
      kind: 'sla',
      title: 'Cambio stato SLA',
      description: '7 ticket a rischio SLA',
      actor: 'Helios Bot',
      occurredAt: '2026-07-22T07:50:00+02:00',
    },
    {
      id: 'activity-5',
      kind: 'resolved',
      title: 'TKT-2025-0571 chiuso',
      description: 'Risolto e verificato',
      actor: 'Luca Conti',
      occurredAt: '2026-07-21T17:21:00+02:00',
    },
  ],
}

export function createDemoGateway(): HeliosGateway {
  let tickets: readonly Ticket[] = [...primaryTickets, ...buildGeneratedTickets()]
  let session = demoSession
  let nextTicketNumber = 579

  return {
    getSession: async () => ({ ...session, user: session.user ? { ...session.user } : null }),
    listTickets: async () => tickets.map((ticket) => ({ ...ticket })),
    getPlatformStatus: async () => ({
      ...demoPlatformStatus,
      services: demoPlatformStatus.services.map((service) => ({ ...service })),
      dr: {
        backup: { ...demoPlatformStatus.dr.backup },
        failover: { ...demoPlatformStatus.dr.failover },
      },
      activities: demoPlatformStatus.activities.map((activity) => ({ ...activity })),
    }),
    createTicket: async (input: CreateTicketInput) => {
      const now = new Date().toISOString()
      const created: Ticket = {
        ...input,
        id: `TKT-2025-${String(nextTicketNumber).padStart(4, '0')}`,
        status: 'open',
        assignee: input.assignee ?? null,
        createdBy: session.user?.displayName ?? 'Utente demo',
        createdAt: now,
        updatedAt: now,
      }
      nextTicketNumber += 1
      tickets = [created, ...tickets]
      return { ...created }
    },
    updateTicket: async (id, input) => {
      const existing = tickets.find((ticket) => ticket.id === id)
      if (!existing) throw new Error('Ticket non trovato')
      const updated: Ticket = {
        ...existing,
        ...input,
        id,
        assignee: input.assignee ?? null,
        updatedAt: new Date().toISOString(),
      }
      tickets = tickets.map((ticket) => (ticket.id === id ? updated : ticket))
      return { ...updated }
    },
    deleteTicket: async (id) => {
      tickets = tickets.filter((ticket) => ticket.id !== id)
    },
    runTicketAutomation: async (id) => {
      const ticket = tickets.find((item) => item.id === id)
      if (!ticket) throw new Error('Ticket non trovato')
      // Il provider dipende dal sito: è la stessa distinzione che in esecuzione
      // reale nasce da AUTOMATION_MODE lato automation service.
      const isPrimary = session.site.mode === 'primary'
      return {
        id: `demo-run-${id}`,
        provider: isPrimary ? 'aws-lambda' : 'lambda-dr',
        status: 'succeeded',
        errorCode: null,
        result: {
          eventType: 'helios.ticket.processed.v1',
          ticketId: id,
          classification: ticket.priority === 'high' ? 'incident' : 'service-request',
          runtime: isPrimary ? 'aws-lambda-cloud' : 'lambda-rie-onprem',
          processedAt: new Date().toISOString(),
        },
        updatedAt: new Date().toISOString(),
      }
    },
    logout: async () => {
      session = { ...session, authenticated: false, user: null }
    },
    getLoginUrl: (returnTo) => `/api/v1/auth/login?returnTo=${encodeURIComponent(returnTo)}`,
  }
}

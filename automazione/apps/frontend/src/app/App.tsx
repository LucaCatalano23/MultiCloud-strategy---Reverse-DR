import { useDeferredValue, useMemo, useState } from 'react'
import { filterTickets } from '../domain/ticketFilter'
import type { Ticket, TicketFilters } from '../domain/types'
import type { RuntimeConfig } from '../infrastructure/runtimeConfig'
import type { HeliosGateway } from '../infrastructure/types'
import { EditTicketDialog } from './components/EditTicketDialog'
import { ErrorState, LoadingState, LoginState } from './components/FullPageState'
import { MetricStrip } from './components/MetricStrip'
import { NewTicketDialog } from './components/NewTicketDialog'
import { OperationsRail } from './components/OperationsRail'
import { SectionPlaceholder } from './components/SectionPlaceholder'
import { Sidebar, type NavigationKey } from './components/Sidebar'
import { TicketDrawer } from './components/TicketDrawer'
import { TicketFilterBar } from './components/TicketFilterBar'
import { TicketTable } from './components/TicketTable'
import { TopBar } from './components/TopBar'
import { useDashboard } from './useDashboard'

const defaultFilters: TicketFilters = {
  query: '',
  status: 'all',
  priority: 'all',
  assignee: 'all',
  service: 'all',
}

const noTickets: readonly Ticket[] = []

const sectionTitles: Readonly<Record<NavigationKey, string>> = {
  overview: 'Panoramica operativa',
  tickets: 'Ticket operativi',
  automations: 'Automazioni',
  audit: 'Audit',
}

interface AppProps {
  readonly gateway: HeliosGateway
  readonly runtimeConfig: RuntimeConfig
}

export function App({ gateway, runtimeConfig }: AppProps) {
  const { state, reload, createTicket, updateTicket, deleteTicket, runTicketAutomation } =
    useDashboard(gateway)
  const [activeSection, setActiveSection] = useState<NavigationKey>('tickets')
  const [filters, setFilters] = useState<TicketFilters>(defaultFilters)
  const [selectedTicketId, setSelectedTicketId] = useState<string | null>(null)
  const [sidebarCollapsed, setSidebarCollapsed] = useState(false)
  const [mobileNavOpen, setMobileNavOpen] = useState(false)
  const [newTicketOpen, setNewTicketOpen] = useState(false)
  const [editTicketOpen, setEditTicketOpen] = useState(false)
  const deferredQuery = useDeferredValue(filters.query)

  const tickets = state.phase === 'ready' ? state.tickets : noTickets
  const filteredTickets = useMemo(
    () => filterTickets(tickets, { ...filters, query: deferredQuery }),
    [deferredQuery, filters, tickets],
  )
  const assignees = useMemo(
    () =>
      [...new Set(tickets.flatMap((ticket) => (ticket.assignee ? [ticket.assignee] : [])))].sort(
        (left, right) => left.localeCompare(right, 'it-IT'),
      ),
    [tickets],
  )
  const services = useMemo(
    () =>
      [...new Set(tickets.map((ticket) => ticket.service))].sort((left, right) =>
        left.localeCompare(right, 'it-IT'),
      ),
    [tickets],
  )
  const selectedTicket = useMemo(
    () => tickets.find((ticket) => ticket.id === selectedTicketId) ?? null,
    [selectedTicketId, tickets],
  )
  const highPriorityCount = useMemo(
    () => tickets.filter((ticket) => ticket.priority === 'high').length,
    [tickets],
  )

  if (state.phase === 'loading') return <LoadingState />
  if (state.phase === 'error') return <ErrorState message={state.message} onRetry={() => void reload()} />
  if (state.phase === 'unauthenticated') {
    const provider = state.session.site.identityProvider === 'entra-id' ? 'Entra ID' : 'Keycloak'
    return <LoginState loginUrl={gateway.getLoginUrl('/')} provider={provider} />
  }
  if (!state.session.user) {
    return <ErrorState message="La sessione autenticata non contiene un utente." onRetry={() => void reload()} />
  }

  const siteLabel = state.session.site.mode === 'primary' ? 'Cloud Primary' : 'On-prem DR'

  return (
    <div className={`app-shell ${sidebarCollapsed ? 'app-shell--sidebar-collapsed' : ''}`}>
      <Sidebar
        active={activeSection}
        collapsed={sidebarCollapsed}
        mobileOpen={mobileNavOpen}
        siteLabel={siteLabel}
        onNavigate={setActiveSection}
        onToggleCollapsed={() => setSidebarCollapsed((collapsed) => !collapsed)}
        onCloseMobile={() => setMobileNavOpen(false)}
      />
      <div className="app-workspace">
        <TopBar
          title={sectionTitles[activeSection]}
          query={filters.query}
          searchEnabled={activeSection === 'tickets'}
          site={state.session.site}
          user={state.session.user}
          highPriorityCount={highPriorityCount}
          onQueryChange={(query) => setFilters({ ...filters, query })}
          onOpenMobileNav={() => setMobileNavOpen(true)}
          onLogout={async () => {
            const endSessionUrl = await gateway.logout()
            if (endSessionUrl) {
              window.location.assign(endSessionUrl)
              return
            }
            await reload()
          }}
        />

        {activeSection === 'tickets' ? (
          <div className="dashboard-layout">
            <main className="ticket-workspace">
              <MetricStrip tickets={tickets} />
              <div className="ticket-command-surface">
                <TicketFilterBar
                  filters={filters}
                  assignees={assignees}
                  services={services}
                  onChange={setFilters}
                  onNewTicket={() => setNewTicketOpen(true)}
                />
                <TicketTable
                  tickets={filteredTickets}
                  selectedTicketId={selectedTicketId}
                  onSelectTicket={(ticket: Ticket) => setSelectedTicketId(ticket.id)}
                />
              </div>
              {selectedTicket ? (
                <TicketDrawer
                  ticket={selectedTicket}
                  onClose={() => setSelectedTicketId(null)}
                  onEdit={() => setEditTicketOpen(true)}
                  onDelete={async () => {
                    await deleteTicket(selectedTicket.id)
                    setSelectedTicketId(null)
                  }}
                  onRunAutomation={() => runTicketAutomation(selectedTicket.id)}
                />
              ) : null}
            </main>
            <OperationsRail platform={state.platform} />
          </div>
        ) : (
          <main className="placeholder-workspace">
            <SectionPlaceholder
              section={activeSection}
              onBack={() => setActiveSection('tickets')}
            />
          </main>
        )}
      </div>

      <NewTicketDialog
        open={newTicketOpen}
        onClose={() => setNewTicketOpen(false)}
        onCreate={async (input) => {
          const created = await createTicket(input)
          setFilters(defaultFilters)
          setSelectedTicketId(created.id)
        }}
      />
      <EditTicketDialog
        ticket={editTicketOpen ? selectedTicket : null}
        onClose={() => setEditTicketOpen(false)}
        onSave={async (id, input) => {
          await updateTicket(id, input)
        }}
      />
      <span className="sr-only" aria-live="polite">
        {runtimeConfig.demoMode ? 'Modalità dimostrativa attiva' : 'Sessione BFF attiva'}
      </span>
    </div>
  )
}

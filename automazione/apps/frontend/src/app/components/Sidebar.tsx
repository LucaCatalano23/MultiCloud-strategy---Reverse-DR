import {
  Bot,
  CheckSquare2,
  ChevronsLeft,
  LayoutDashboard,
  Menu,
  Ticket as TicketIcon,
  X,
} from 'lucide-react'

export type NavigationKey = 'overview' | 'tickets' | 'automations' | 'audit'

interface SidebarProps {
  readonly active: NavigationKey
  readonly collapsed: boolean
  readonly mobileOpen: boolean
  readonly siteLabel: string
  readonly onNavigate: (item: NavigationKey) => void
  readonly onToggleCollapsed: () => void
  readonly onCloseMobile: () => void
}

const items = [
  { id: 'overview' as const, label: 'Panoramica', icon: LayoutDashboard },
  { id: 'tickets' as const, label: 'Ticket', icon: TicketIcon },
  { id: 'automations' as const, label: 'Automazioni', icon: Bot },
  { id: 'audit' as const, label: 'Audit', icon: CheckSquare2 },
]

export function Sidebar({
  active,
  collapsed,
  mobileOpen,
  siteLabel,
  onNavigate,
  onToggleCollapsed,
  onCloseMobile,
}: SidebarProps) {
  return (
    <>
      {mobileOpen ? (
        <button
          className="sidebar-backdrop"
          type="button"
          aria-label="Chiudi navigazione"
          onClick={onCloseMobile}
        />
      ) : null}
      <aside
        className={`sidebar ${collapsed ? 'sidebar--collapsed' : ''} ${mobileOpen ? 'sidebar--mobile-open' : ''}`}
      >
        <div className="brand-row">
          <span className="brand-mark" aria-hidden="true">
            <span />
            <span />
          </span>
          <span className="brand-name">HELIOS DESK</span>
          <button
            className="mobile-nav-close"
            type="button"
            aria-label="Chiudi navigazione"
            onClick={onCloseMobile}
          >
            <X aria-hidden="true" size={20} />
          </button>
        </div>

        <nav aria-label="Navigazione principale" className="primary-nav">
          {items.map(({ id, label, icon: Icon }) => (
            <button
              key={id}
              type="button"
              className={`nav-item ${active === id ? 'nav-item--active' : ''}`}
              aria-current={active === id ? 'page' : undefined}
              aria-label={collapsed ? label : undefined}
              title={collapsed ? label : undefined}
              onClick={() => {
                onNavigate(id)
                onCloseMobile()
              }}
            >
              <Icon size={19} strokeWidth={1.8} aria-hidden="true" />
              <span>{label}</span>
            </button>
          ))}
        </nav>

        <div className="sidebar-footer">
          <span className="site-footprint">
            <span className="site-footprint__dot" aria-hidden="true" />
            <span>{siteLabel}</span>
          </span>
          <button
            className="collapse-button"
            type="button"
            onClick={onToggleCollapsed}
            aria-label={collapsed ? 'Espandi menu' : 'Riduci menu'}
          >
            {collapsed ? (
              <Menu size={18} aria-hidden="true" />
            ) : (
              <ChevronsLeft size={18} aria-hidden="true" />
            )}
            <span>{collapsed ? 'Espandi' : 'Riduci menu'}</span>
          </button>
        </div>
      </aside>
    </>
  )
}

import { Bell, ChevronDown, Menu, Search } from 'lucide-react'
import { useState } from 'react'
import type { AuthenticatedUser, SiteContext } from '../../domain/types'
import { userInitials, userRoleLabel } from '../../domain/presentation'

interface TopBarProps {
  readonly title: string
  readonly query: string
  readonly searchEnabled: boolean
  readonly site: SiteContext
  readonly user: AuthenticatedUser
  readonly onQueryChange: (query: string) => void
  readonly onOpenMobileNav: () => void
  readonly onLogout: () => Promise<void>
}

export function TopBar({
  title,
  query,
  searchEnabled,
  site,
  user,
  onQueryChange,
  onOpenMobileNav,
  onLogout,
}: TopBarProps) {
  const [profileOpen, setProfileOpen] = useState(false)
  const [notificationsOpen, setNotificationsOpen] = useState(false)

  return (
    <header className="topbar">
      <div className="topbar__title-group">
        <button
          className="mobile-nav-trigger"
          type="button"
          aria-label="Apri navigazione"
          onClick={onOpenMobileNav}
        >
          <Menu size={21} aria-hidden="true" />
        </button>
        <h1>{title}</h1>
      </div>

      <div className="topbar__actions">
        <label className={`global-search ${searchEnabled ? '' : 'global-search--disabled'}`}>
          <Search size={17} aria-hidden="true" />
          <span className="sr-only">Cerca ticket</span>
          <input
            type="search"
            aria-label="Cerca ticket"
            placeholder="Cerca ticket, ID, utente, servizio..."
            value={query}
            disabled={!searchEnabled}
            onChange={(event) => onQueryChange(event.target.value)}
          />
          <kbd>⌘ K</kbd>
        </label>

        <div className="site-switcher" aria-label={`Sito attivo: ${site.name}`}>
          <span className={`presence-dot presence-dot--${site.mode}`} aria-hidden="true" />
          <span>Sito: {site.name}</span>
          <ChevronDown size={15} aria-hidden="true" />
        </div>

        <div className="notification-menu">
          <button
            type="button"
            className="icon-button"
            aria-label="Notifiche"
            aria-expanded={notificationsOpen}
            onClick={() => setNotificationsOpen((open) => !open)}
          >
            <Bell size={18} aria-hidden="true" />
            <span className="notification-dot" aria-hidden="true" />
          </button>
          {notificationsOpen ? (
            <div className="topbar-popover topbar-popover--notifications" role="status">
              <strong>2 notifiche operative</strong>
              <span>Un ticket ad alta priorità richiede attenzione.</span>
            </div>
          ) : null}
        </div>

        <div className="profile-menu">
          <button
            type="button"
            className="profile-trigger"
            aria-expanded={profileOpen}
            onClick={() => setProfileOpen((open) => !open)}
          >
            <span className="profile-copy">
              <strong>{user.displayName}</strong>
              <span>{userRoleLabel(user)}</span>
            </span>
            <ChevronDown size={14} aria-hidden="true" />
            <span className="avatar" aria-hidden="true">
              {userInitials(user)}
            </span>
          </button>
          {profileOpen ? (
            <div className="topbar-popover profile-popover">
              <span>{site.identityProvider === 'entra-id' ? 'Entra ID' : 'Keycloak'}</span>
              <button type="button" onClick={() => void onLogout()}>
                Esci
              </button>
            </div>
          ) : null}
        </div>
      </div>
    </header>
  )
}

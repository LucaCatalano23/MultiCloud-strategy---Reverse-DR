import type { AuthenticatedUser, TicketPriority, TicketStatus } from './types'

export const priorityLabels: Readonly<Record<TicketPriority, string>> = {
  high: 'Alta',
  medium: 'Media',
  low: 'Bassa',
}

export const statusLabels: Readonly<Record<TicketStatus, string>> = {
  open: 'Aperto',
  in_progress: 'In corso',
  waiting_user: 'In attesa utente',
  waiting_third_party: 'In attesa terze parti',
  scheduled: 'Programmato',
  closed: 'Chiuso',
}

const italianTime = new Intl.DateTimeFormat('it-IT', {
  hour: '2-digit',
  minute: '2-digit',
})

const italianDate = new Intl.DateTimeFormat('it-IT', {
  day: '2-digit',
  month: 'short',
})

export function formatUpdatedAt(value: string, now = new Date()): string {
  const date = new Date(value)
  if (Number.isNaN(date.valueOf())) return 'Data non disponibile'

  const dateKey = `${date.getFullYear()}-${date.getMonth()}-${date.getDate()}`
  const nowKey = `${now.getFullYear()}-${now.getMonth()}-${now.getDate()}`
  const yesterday = new Date(now)
  yesterday.setDate(yesterday.getDate() - 1)
  const yesterdayKey = `${yesterday.getFullYear()}-${yesterday.getMonth()}-${yesterday.getDate()}`
  const time = italianTime.format(date)

  if (dateKey === nowKey) return `Oggi, ${time}`
  if (dateKey === yesterdayKey) return `Ieri, ${time}`
  return `${italianDate.format(date)}, ${time}`
}

export function userInitials(user: AuthenticatedUser): string {
  const initials = user.displayName
    .trim()
    .split(/\s+/)
    .slice(0, 2)
    .map((part) => part.at(0)?.toLocaleUpperCase('it-IT') ?? '')
    .join('')
  return initials || 'UT'
}

export function userRoleLabel(user: AuthenticatedUser): string {
  const preferredRole = user.roles.find((role) => role !== 'authenticated') ?? user.roles[0]
  if (!preferredRole) return 'Operatore'
  return preferredRole
    .replace(/^helios:/, '')
    .replace(/[-_]/g, ' ')
    .replace(/^./, (letter) => letter.toLocaleUpperCase('it-IT'))
}

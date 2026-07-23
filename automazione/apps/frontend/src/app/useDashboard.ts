import { useCallback, useEffect, useRef, useState } from 'react'
import type {
  CreateTicketInput,
  PlatformStatus,
  SessionInfo,
  Ticket,
  UpdateTicketInput,
} from '../domain/types'
import type { HeliosGateway } from '../infrastructure/types'

type DashboardState =
  | { readonly phase: 'loading' }
  | { readonly phase: 'unauthenticated'; readonly session: SessionInfo }
  | { readonly phase: 'error'; readonly message: string }
  | {
      readonly phase: 'ready'
      readonly session: SessionInfo
      readonly tickets: readonly Ticket[]
      readonly platform: PlatformStatus
    }

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : 'Errore inatteso durante il caricamento'
}

export function useDashboard(gateway: HeliosGateway) {
  const [state, setState] = useState<DashboardState>({ phase: 'loading' })
  const requestVersion = useRef(0)

  const load = useCallback(async () => {
    const version = requestVersion.current + 1
    requestVersion.current = version
    setState({ phase: 'loading' })
    try {
      const session = await gateway.getSession()
      if (requestVersion.current !== version) return
      if (!session.authenticated) {
        setState({ phase: 'unauthenticated', session })
        return
      }
      const [tickets, platform] = await Promise.all([
        gateway.listTickets(),
        gateway.getPlatformStatus(),
      ])
      if (requestVersion.current !== version) return
      setState({ phase: 'ready', session, tickets, platform })
    } catch (error) {
      if (requestVersion.current === version) {
        setState({ phase: 'error', message: errorMessage(error) })
      }
    }
  }, [gateway])

  useEffect(() => {
    void load()
    return () => {
      requestVersion.current += 1
    }
  }, [load])

  const createTicket = useCallback(
    async (input: CreateTicketInput) => {
      const created = await gateway.createTicket(input)
      setState((current) =>
        current.phase === 'ready'
          ? { ...current, tickets: [created, ...current.tickets] }
          : current,
      )
      return created
    },
    [gateway],
  )

  const updateTicket = useCallback(
    async (id: string, input: UpdateTicketInput) => {
      const updated = await gateway.updateTicket(id, input)
      setState((current) =>
        current.phase === 'ready'
          ? {
              ...current,
              tickets: current.tickets.map((ticket) =>
                ticket.id === updated.id ? updated : ticket,
              ),
            }
          : current,
      )
      return updated
    },
    [gateway],
  )

  const deleteTicket = useCallback(
    async (id: string) => {
      await gateway.deleteTicket(id)
      setState((current) =>
        current.phase === 'ready'
          ? { ...current, tickets: current.tickets.filter((ticket) => ticket.id !== id) }
          : current,
      )
    },
    [gateway],
  )

  return { state, reload: load, createTicket, updateTicket, deleteTicket }
}

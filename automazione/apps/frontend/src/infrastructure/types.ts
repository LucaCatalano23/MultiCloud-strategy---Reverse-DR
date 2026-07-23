import type {
  CreateTicketInput,
  PlatformStatus,
  SessionInfo,
  Ticket,
  UpdateTicketInput,
} from '../domain/types'

export interface HeliosGateway {
  getSession(): Promise<SessionInfo>
  listTickets(): Promise<readonly Ticket[]>
  getPlatformStatus(): Promise<PlatformStatus>
  createTicket(input: CreateTicketInput): Promise<Ticket>
  updateTicket(id: string, input: UpdateTicketInput): Promise<Ticket>
  deleteTicket(id: string): Promise<void>
  logout(): Promise<void>
  getLoginUrl(returnTo: string): string
}

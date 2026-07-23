import type {
  CreateTicketInput,
  PlatformStatus,
  SessionInfo,
  Ticket,
} from '../domain/types'

export interface HeliosGateway {
  getSession(): Promise<SessionInfo>
  listTickets(): Promise<readonly Ticket[]>
  getPlatformStatus(): Promise<PlatformStatus>
  createTicket(input: CreateTicketInput): Promise<Ticket>
  logout(): Promise<void>
  getLoginUrl(returnTo: string): string
}

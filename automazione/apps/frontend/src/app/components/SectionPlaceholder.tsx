import { ArrowLeft, Bot, CheckSquare2, LayoutDashboard } from 'lucide-react'
import type { NavigationKey } from './Sidebar'

const content = {
  overview: {
    title: 'Panoramica operativa',
    detail: 'La vista consolidata sarà alimentata dal read model del BFF.',
    icon: LayoutDashboard,
  },
  automations: {
    title: 'Automazioni',
    detail: 'Monitora le esecuzioni cloud e il runtime Lambda DR on-prem.',
    icon: Bot,
  },
  audit: {
    title: 'Audit',
    detail: 'Consulta gli eventi immutabili relativi a ticket, accessi e failover.',
    icon: CheckSquare2,
  },
} as const

export function SectionPlaceholder({
  section,
  onBack,
}: {
  readonly section: Exclude<NavigationKey, 'tickets'>
  readonly onBack: () => void
}) {
  const sectionContent = content[section]
  const Icon = sectionContent.icon
  return (
    <section className="section-placeholder">
      <Icon size={31} aria-hidden="true" />
      <h2>{sectionContent.title}</h2>
      <p>{sectionContent.detail}</p>
      <button type="button" className="secondary-button" onClick={onBack}>
        <ArrowLeft size={16} aria-hidden="true" /> Torna ai ticket
      </button>
    </section>
  )
}

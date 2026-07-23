import { createRoot } from 'react-dom/client'
import { App } from './app/App'
import { ErrorState } from './app/components/FullPageState'
import { createBffClient } from './infrastructure/bffClient'
import { createDemoGateway } from './infrastructure/demoGateway'
import { loadRuntimeConfig } from './infrastructure/runtimeConfig'
import './styles/tokens.css'
import './styles/base.css'
import './styles/shell.css'
import './styles/dashboard.css'
import './styles/tickets.css'
import './styles/dialog.css'

const rootElement = document.getElementById('root')
if (!rootElement) throw new Error('Elemento root non trovato')
const root = createRoot(rootElement)

async function bootstrap() {
  try {
    const runtimeConfig = await loadRuntimeConfig()
    document.title = runtimeConfig.appName
    const gateway = runtimeConfig.demoMode
      ? createDemoGateway()
      : createBffClient(runtimeConfig)
    root.render(<App runtimeConfig={runtimeConfig} gateway={gateway} />)
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Bootstrap non riuscito'
    root.render(
      <ErrorState message={message} onRetry={() => window.location.reload()} />,
    )
  }
}

void bootstrap()

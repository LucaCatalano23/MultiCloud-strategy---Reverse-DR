import { AlertTriangle, LoaderCircle, ShieldCheck } from 'lucide-react'

export function LoadingState() {
  return (
    <main className="full-page-state" aria-busy="true" aria-label="Caricamento Helios Desk">
      <LoaderCircle className="spinner" size={30} aria-hidden="true" />
      <h1>Helios Desk</h1>
      <p>Caricamento del contesto operativo…</p>
    </main>
  )
}

export function ErrorState({ message, onRetry }: { readonly message: string; readonly onRetry: () => void }) {
  return (
    <main className="full-page-state">
      <AlertTriangle className="state-icon state-icon--error" size={31} aria-hidden="true" />
      <h1>Helios Desk non è disponibile</h1>
      <p role="alert">{message}</p>
      <button className="primary-button" type="button" onClick={onRetry}>
        Riprova
      </button>
    </main>
  )
}

export function LoginState({ loginUrl, provider }: { readonly loginUrl: string; readonly provider: string }) {
  return (
    <main className="full-page-state login-state">
      <span className="login-brand">HELIOS DESK</span>
      <ShieldCheck className="state-icon" size={34} aria-hidden="true" />
      <h1>Accedi alla console operativa</h1>
      <p>La sessione è gestita dal gateway aziendale; nessuna credenziale viene salvata nel browser.</p>
      <a className="primary-button" href={loginUrl}>
        Accedi con {provider}
      </a>
    </main>
  )
}

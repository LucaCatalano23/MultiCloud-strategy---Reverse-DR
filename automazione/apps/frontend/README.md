# Helios Desk frontend

Dashboard React/Vite per le operazioni di reverse disaster recovery. Il browser parla soltanto con il BFF sullo stesso origin: la sessione resta in cookie `HttpOnly` e non vengono salvati token in `localStorage` o `sessionStorage`.

## Sviluppo

```bash
npm install
npm run dev
```

Il bootstrap locale in `public/config/runtime-config.json` abilita intenzionalmente il demo adapter. Il container production sostituisce sempre quel file all'avvio e usa `HELIOS_DEMO_MODE=false` come default fail-closed.

## Verifica

```bash
npm test
npm run test:coverage
npm run lint
npm run build
npm run test:e2e
```

## Container

```bash
docker build -t reverse-dr/helios-desk-frontend:local .
docker run --rm -p 8080:8080 \
  -e HELIOS_API_UPSTREAM=http://helios-bff:8000 \
  reverse-dr/helios-desk-frontend:local
```

Il servizio ascolta su `8080`; il probe è `GET /healthz`. La configurazione runtime pubblica è `GET /config/runtime-config.json` con cache disabilitata.

Variabili consentite:

- `HELIOS_API_UPSTREAM`: upstream nginx del BFF, default `http://helios-bff:8000`.
- `HELIOS_API_BASE_PATH`: path same-origin pubblico, default `/api/v1`.
- `HELIOS_DEMO_MODE`: `true` soltanto per ambienti dimostrativi espliciti; default `false`.
- `HELIOS_CSRF_COOKIE_NAME`: default `__Host-helios_csrf`.
- `HELIOS_CSRF_HEADER_NAME`: default `X-CSRF-Token`.

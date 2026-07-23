# Helios Desk on-prem DR

Questo overlay aggiunge al cluster k3s on-prem **esistente** un data plane Helios in cold standby e un identity plane Keycloak warm. Non installa un altro cluster e non sostituisce il playbook Ansible esistente.

## Decisioni architetturali

- `helios-desk` contiene React, BFF, ticket service e automation service. I quattro Deployment partono con `replicas: 0`.
- `helios-identity` contiene Keycloak e un PostgreSQL dedicato, entrambi con una replica. L'identita resta warm perche il failover non puo cambiare DNS prima che login, realm e JWKS siano disponibili.
- Il database Keycloak e separato dal database applicativo. Il restore dei ticket puo quindi ricreare lo schema applicativo senza cancellare realm, client, ruoli o credenziali.
- Il PostgreSQL applicativo resta quello ripristinato dalla procedura DR esistente. Il Secret `helios-app-database` contiene il suo `DATABASE_URL`; nella PoC punta normalmente a `postgres.helpdesk.svc.cluster.local:5432`.
- Il browser parla soltanto con React e BFF sullo stesso origin. Ticket e automation sono `ClusterIP`; nessun token viene consegnato al frontend.
- Keycloak usa l'immagine ufficiale in production mode, TLS terminato da Traefik, import di realm al primo avvio e storage PostgreSQL persistente. `KC_CACHE=local` e intenzionale per il cluster k3s a nodo singolo; prima di scalare Keycloak a piu repliche va introdotta una configurazione cache/HA supportata.

Il realm importato a startup viene ignorato quando il realm esiste gia. Questo rende i restart idempotenti e impedisce di sovrascrivere utenti operativi, ma significa che una modifica successiva del template deve essere applicata con una migrazione Keycloak controllata, non confidando in un restart.

## Contratto Entra ID / Keycloak

I due provider hanno issuer diversi e non devono essere mascherati come se fossero lo stesso IdP. Il BFF on-prem usa sempre:

| Contratto | Valore base della PoC | Integrazione Entra reale |
| --- | --- | --- |
| issuer | `https://auth.azienda.lan/realms/helios-desk` | issuer tenant Entra sul primary |
| audience | `api://reverse-dr-helpdesk` | GUID `api_application_client_id` dell'API Entra v2 |
| claim autorizzazioni | `roles` | `roles` |
| valori role | `tickets.read`, `tickets.write`, `automation.execute` | stessi valori nelle App Roles Entra |
| identita aziendale stabile | `employee_id` | claim equivalente derivato dall'employee ID, non dall'email |

`api://reverse-dr-helpdesk` e soltanto un default di laboratorio. Prima della prima inizializzazione del database Keycloak, un overlay di sito deve impostare **lo stesso GUID** in `HELIOS_API_AUDIENCE` e `OIDC_AUDIENCE`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../onprem
configMapGenerator:
  - name: helios-identity-config
    namespace: helios-identity
    behavior: merge
    literals:
      - HELIOS_API_AUDIENCE=<api_application_client_id>
  - name: helios-onprem-config
    namespace: helios-desk
    behavior: merge
    literals:
      - OIDC_AUDIENCE=<api_application_client_id>
```

Il resource client Keycloak mantiene l'ID interno `helios-api`; il mapper emette invece `HELIOS_API_AUDIENCE` nel claim `aud`. In questo modo i nomi dei client role restano stabili mentre l'audience segue l'output Entra dell'ambiente.

Il client `helios-bff` e confidential, richiede Authorization Code + PKCE S256, non abilita implicit flow, password grant o service account e accetta solo il callback HTTPS del BFF. Il suo secret entra nel realm tramite `${HELIOS_BFF_CLIENT_SECRET}` risolto da una variabile del Secret Kubernetes: il valore non compare nel ConfigMap o nel repository.

Il secret di cifratura sessione on-prem deve essere diverso da quello cloud. Dopo il cambio issuer, una sessione Entra non viene riutilizzata e l'utente effettua una nuova autenticazione Keycloak.

## Prerequisiti e secret

Servono record DNS per `helpdesk.azienda.lan` e `auth.azienda.lan`; il secondo punta sempre al k3s on-prem. I certificati devono includere gli hostname corrispondenti. Non sono presenti manifest `Secret` versionati.

Lo script `scripts/create-secrets.sh` legge valori dall'ambiente, usa file temporanei con `umask 077` e riconcilia i Secret con `kubectl create --dry-run=client | kubectl apply`. Richiede:

- `KEYCLOAK_DB_PASSWORD`, `KEYCLOAK_ADMIN_USERNAME`, `KEYCLOAK_ADMIN_PASSWORD`;
- `HELIOS_BFF_CLIENT_SECRET` e una `HELIOS_SESSION_ENCRYPTION_KEY` Fernet;
- `HELIOS_DATABASE_URL` per l'istanza PostgreSQL applicativa ripristinata;
- `HELIOS_DR_OPERATOR_USERNAME`, `HELIOS_DR_OPERATOR_PASSWORD`, `HELIOS_DR_OPERATOR_EMPLOYEE_ID`, `HELIOS_DR_OPERATOR_EMAIL`;
- `HELIOS_APP_TLS_CERT_FILE` / `HELIOS_APP_TLS_KEY_FILE` e `HELIOS_IDENTITY_TLS_CERT_FILE` / `HELIOS_IDENTITY_TLS_KEY_FILE`.

Una coppia wildcard puo essere fornita una sola volta con `HELIOS_TLS_CERT_FILE` e `HELIOS_TLS_KEY_FILE`. I file e i valori reali restano fuori da Git.

```bash
cd automazione/infra/onprem
bash scripts/create-secrets.sh
kubectl apply -k .
kubectl -n helios-identity rollout status statefulset/keycloak-postgres --timeout=300s
kubectl -n helios-identity rollout status deployment/keycloak --timeout=300s
bash scripts/provision-dr-operator.sh
```

Il bootstrap admin e temporaneo per natura e va ruotato/rimosso secondo il runbook operativo dopo aver creato un amministratore permanente con privilegi minimi. Non usare l'account applicativo DR come amministratore Keycloak.

## Provisioning identita utilizzabile nella PoC

Il realm non contiene utenti seed. `scripts/provision-dr-operator.sh` avvia un Job effimero con `kcadm`, alimentato esclusivamente dai Secret Kubernetes. Il Job:

1. crea o aggiorna per username l'operatore con `employee_id` stabile;
2. reimposta una password temporanea, da cambiare al primo login;
3. assegna in modo convergente `tickets.read`, `tickets.write` e `automation.execute` sul client `helios-api`.

Una nuova esecuzione riconcilia lo stesso utente e non crea duplicati. Un broker Keycloak verso Entra puo semplificare il login quando Internet e Entra sono disponibili, ma **non** garantisce autenticazione durante un'interruzione cloud; per questo la PoC mantiene almeno un'identita locale DR. In produzione e preferibile federare un LDAP/AD on-prem realmente disponibile durante il disastro e mappare i medesimi role/employee ID.

## Failover Ansible

`automazione/helpdesk-dr/ansible/playbooks/failover.yml` resta l'orchestratore. La promozione esegue nell'ordine:

1. restore e verifica checksum del database applicativo;
2. preflight Lambda/RIE esistente;
3. readiness di PostgreSQL Keycloak e Keycloak, quindi verifica del discovery issuer;
4. `DR_ACTIVE=true` sui workload configurati;
5. configurazione esplicita del BFF su Keycloak, scala e attende ticket, automation, BFF e web;
6. canary `/health/ready` attraverso il Service BFF;
7. solo alla fine aggiorna il DNS autorevole.

La lista e configurabile con `helios_dr_workloads` / `HELIOS_DR_WORKLOADS`. Il rescue riporta i Deployment a `DR_ACTIVE=false` e `replicas: 0`. Se l'overlay Helios non e ancora installato, gli script conservano il percorso legacy `helpdesk-api`.

`scripts/deploy/deploy-onprem-standby.sh` applica anche questo overlay al k3s esistente, verifica che i Secret siano gia presenti, lascia Keycloak warm e forza i quattro workload applicativi a zero.

## Network policy

Entrambi i namespace applicano default deny. Sono consentiti soltanto:

- Traefik -> React, BFF e Keycloak;
- BFF -> ticket, automation, Keycloak e PostgreSQL applicativo;
- ticket -> automation, Keycloak e PostgreSQL applicativo;
- automation -> Keycloak, PostgreSQL applicativo ed `event-adapter` nel namespace `lambda-dr`;
- Keycloak -> PostgreSQL Keycloak;
- DNS verso CoreDNS e il Job di provisioning -> Keycloak.

Se il database applicativo viene spostato fuori dal namespace `helpdesk`, la relativa egress policy deve essere aggiornata insieme al `DATABASE_URL`; cambiare soltanto il Secret produrrebbe correttamente un fail-closed.

## Validazione statica

```bash
bash scripts/validate.sh
```

Il gate renderizza Kustomize, verifica replica standby, realm/audience/role, assenza di Secret renderizzati, contratti React/BFF e collegamento Ansible. Esegue inoltre `bash -n` e, quando disponibile, `ansible-playbook --syntax-check`.

Per produzione, oltre a questo gate, fissare le immagini per digest, configurare snapshot/backup cifrati del PVC `data-keycloak-postgres-0`, monitorare scadenza certificati e provare periodicamente login e rotazione credenziali in un'esercitazione DR.

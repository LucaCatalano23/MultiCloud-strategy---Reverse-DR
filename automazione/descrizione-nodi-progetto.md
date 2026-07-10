# Descrizione dei nodi del progetto

Questo testo descrive i nodi della PoC dal punto di vista funzionale: software presente, ruolo nel sistema, responsabilita e modalita di comunicazione. Non entra nel dettaglio di LXC come tecnologia di virtualizzazione, perche ai fini della tesi ogni nodo va considerato come una macchina della rete aziendale o del cloud simulato.

## `cloud-k3s`

`cloud-k3s` rappresenta il sito primario in cloud. E una macchina Ubuntu con k3s installato, quindi ospita un cluster Kubernetes mononodo.

Su questo nodo girano i servizi primari dell'applicazione helpdesk:

- Ingress controller Traefik, usato per esporre HTTP il servizio `helpdesk.azienda.lan`.
- Deployment `helpdesk-api`, cioe l'applicazione helpdesk.
- Deployment `postgres`, cioe il database primario dell'applicazione.
- Service Kubernetes `helpdesk-api`, che porta il traffico HTTP dal cluster verso il pod applicativo.
- Service Kubernetes `postgres`, usato dall'applicazione per raggiungere il database.
- Backup SQL periodici o manuali in `/srv/helpdesk-backups`.

Il suo indirizzo principale e `10.20.0.10`. In stato normale il DNS aziendale risolve:

```text
helpdesk.azienda.lan -> 10.20.0.10
```

La comunicazione verso questo nodo avviene tramite HTTP, passando dall'Ingress Traefik. L'applicazione espone endpoint di controllo come:

```text
/health/live
/health/ready
/version
```

In modalita primaria la readiness e sempre abilitata se applicazione e database sono sani, perche `DR_READY_POLICY=always`.

## `k3s-datacenter`

`k3s-datacenter` rappresenta il sito secondario on-premise. E una macchina Ubuntu con k3s installato e ospita il cluster Kubernetes di disaster recovery.

Su questo nodo girano gli stessi componenti applicativi presenti nel cloud:

- Ingress controller Traefik.
- Deployment `helpdesk-api`.
- Deployment `postgres`.
- Service `helpdesk-api`.
- Service `postgres`.
- PVC `postgres-data` per i dati del database.

Il suo indirizzo principale e `10.10.3.10`.

In condizioni normali questo sito e in warm standby: l'applicazione puo essere deployata e il pod puo essere in esecuzione, ma non deve ricevere traffico utente. Per questo motivo la readiness del servizio on-prem e controllata da un marker:

```text
/dr-state/ready
```

Finche questo file non esiste, `/health/ready` non risponde come pronto. Durante il failover, dopo il restore del database, lo script di promozione crea il marker e rende il sito on-prem eleggibile al traffico.

Quando il DR e attivo, il DNS aziendale viene aggiornato cosi:

```text
helpdesk.azienda.lan -> 10.10.3.10
```

Da quel momento le richieste HTTP degli utenti interni arrivano al cluster on-prem.

## `server-dns`

`server-dns` e il DNS aziendale. E una macchina Ubuntu con Bind9 installato.

La sua funzione e essere il punto di controllo per la risoluzione dei nomi interni. In particolare gestisce la zona:

```text
azienda.lan
```

I record principali sono:

```text
server-dns.azienda.lan      -> 10.10.2.53
helpdesk.azienda.lan        -> cloud o on-prem, in base allo stato DR
git-server.azienda.lan      -> 10.10.3.70
cloud-helpdesk.azienda.lan  -> 10.20.0.10
onprem-helpdesk.azienda.lan -> 10.10.3.10
```

Il suo indirizzo e `10.10.2.53`.

In normal mode il record applicativo punta al cloud:

```text
helpdesk.azienda.lan -> 10.20.0.10
```

In DR mode punta al sito on-prem:

```text
helpdesk.azienda.lan -> 10.10.3.10
```

Gli script di failover comunicano con questo nodo per aggiornare la zona DNS, validarla con `named-checkzone` e riavviare il servizio `named`.

## `git-server`

`git-server` rappresenta il punto di verita del codice applicativo e dei manifest operativi. E una macchina Ubuntu con Git e `git-daemon` installati.

Il suo indirizzo e:

```text
10.10.3.70
```

Il repository principale e:

```text
/srv/git/helpdesk-dr.git
```

ed e pubblicato come:

```text
git://10.10.3.70/helpdesk-dr.git
```

In questa PoC il repository contiene:

- codice dell'applicazione helpdesk;
- manifest Kubernetes;
- script di deploy;
- script di backup;
- script di restore;
- script di failover;
- configurazione della PoC.

La sua funzione non e servire traffico utente, ma mantenere il riferimento operativo dell'applicazione. In uno scenario reale sarebbe integrato in un flusso GitOps o CI/CD.

## `ansible-node`

`ansible-node` e il nodo operativo. E una macchina Ubuntu con Ansible installato.

Il suo indirizzo e:

```text
10.10.3.100
```

La sua funzione e eseguire operazioni amministrative e runbook. Nel progetto viene usato come control node per:

- orchestrare backup;
- orchestrare restore;
- eseguire failover;
- verificare DNS;
- raggiungere i nodi interni;
- controllare il comportamento della rete aziendale dal punto di vista operativo.

Gli script della PoC possono essere clonati da `git-server` dentro:

```text
/opt/helpdesk-dr
```

Il bootstrap dedicato crea anche il comando:

```text
helpdesk-dr
```

che permette di eseguire i runbook direttamente dal nodo operativo, ad esempio:

```bash
lxc exec ansible-node -- helpdesk-dr poc/healthcheck
lxc exec ansible-node -- helpdesk-dr backup/backup-cloud
lxc exec ansible-node -- helpdesk-dr failover/failover-to-onprem
```

In questo modo `ansible-node` non e piu solo un placeholder: diventa il nodo da cui partono le operazioni di controllo.

Comunica con:

- `cloud-k3s`, per interrogare il cluster primario e prelevare backup;
- `k3s-datacenter`, per ripristinare il database e promuovere il sito DR;
- `server-dns`, per aggiornare il record `helpdesk.azienda.lan`;
- `git-server`, per pubblicare o leggere il repository sorgente.

## `pc-dipendente1`

`pc-dipendente1` rappresenta un client interno della rete aziendale.

Il suo indirizzo e:

```text
10.10.1.193
```

Non ospita servizi critici. Serve per simulare il punto di vista di un utente aziendale che vuole accedere all'applicazione helpdesk.

Il modo corretto di usarlo e interrogare il servizio tramite nome DNS:

```bash
curl http://helpdesk.azienda.lan/version
```

In normal mode, se il DNS punta al cloud, il client raggiunge il servizio primario. In DR mode, se il DNS punta a on-prem, il client raggiunge il sito secondario.

Questo nodo e utile per dimostrare che il failover non richiede modifiche lato client: cambia la risoluzione DNS, non il modo in cui l'utente accede al servizio.

## `router-dipendenti`

`router-dipendenti` e un router OpenWrt.

Ha due interfacce principali:

```text
10.10.1.1 sulla rete dipendenti
10.10.2.2 sulla DMZ
```

La sua funzione e collegare la rete utenti alla DMZ e al resto dell'infrastruttura. I client come `pc-dipendente1` usano questo router come gateway.

Non ospita servizi applicativi. La sua importanza e nel percorso di comunicazione: permette ai client interni di raggiungere DNS, datacenter e uscita verso il cloud.

## `router-datacenter`

`router-datacenter` e un router OpenWrt.

Ha due interfacce:

```text
10.10.3.1 sulla rete datacenter
10.10.2.3 sulla DMZ
```

La sua funzione e collegare i nodi del datacenter on-prem alla DMZ.

I nodi `k3s-datacenter`, `git-server`, `ansible-node`, `egress-proxy` e `proxy-keycloak` usano questo router come gateway logico per comunicare con le altre reti aziendali e con l'esterno.

## `router-dmz`

`router-dmz` e un router OpenWrt centrale.

Ha due interfacce:

```text
10.10.2.4 sulla DMZ
10.10.4.1 sulla rete transit
```

La sua funzione e mettere in comunicazione:

- rete dipendenti;
- rete datacenter;
- server DNS in DMZ;
- rete transit verso l'edge.

E il punto di passaggio principale tra le reti interne e l'edge. In questa PoC e fondamentale per far uscire il traffico interno verso il cloud simulato o verso Internet.

## `router-edge`

`router-edge` e il router OpenWrt di confine.

Ha due interfacce:

```text
10.10.4.2 sulla rete transit
eth1 su rete esterna/LXD, con indirizzo DHCP
```

La sua funzione e permettere comunicazioni in uscita dalla rete aziendale verso l'esterno. Implementa NAT outbound.

La scelta progettuale e importante: il traffico deve uscire dall'azienda verso Internet/cloud, ma non deve entrare dall'esterno verso la rete aziendale. Questo rappresenta un comportamento realistico per molte reti aziendali: gli host interni possono raggiungere servizi esterni, ma l'esposizione inbound e limitata o assente.

## `egress-proxy`

`egress-proxy` e un nodo Ubuntu previsto per controllare o filtrare traffico in uscita dal datacenter.

Il suo indirizzo e:

```text
10.10.3.60
```

Nel progetto attuale non e ancora il componente centrale del flusso helpdesk, ma rappresenta un punto naturale dove introdurre:

- proxy HTTP/HTTPS;
- logging del traffico uscente;
- allowlist di destinazioni;
- policy di sicurezza per l'egress.

In un'evoluzione della PoC, i workload on-prem potrebbero uscire verso cloud o repository passando da questo nodo.

## `proxy-keycloak`

`proxy-keycloak` e un nodo Ubuntu previsto per la componente di autenticazione o reverse proxy applicativo.

Il suo indirizzo e:

```text
10.10.3.50
```

Nel progetto attuale non e ancora integrato nel flusso principale dell'helpdesk, ma rappresenta il punto in cui introdurre:

- Keycloak;
- reverse proxy;
- autenticazione centralizzata;
- integrazione OIDC/SAML;
- protezione degli endpoint applicativi.

In una versione piu completa dell'architettura, il traffico verso l'applicazione potrebbe passare da un proxy autenticato prima di raggiungere `helpdesk-api`.

## Comunicazione tra i nodi

Il flusso principale in normal mode e:

```text
client interno -> DNS aziendale -> helpdesk.azienda.lan -> cloud-k3s -> helpdesk-api -> postgres cloud
```

Il flusso principale in DR mode e:

```text
client interno -> DNS aziendale -> helpdesk.azienda.lan -> k3s-datacenter -> helpdesk-api -> postgres on-prem
```

Il flusso operativo di backup e restore e:

```text
cloud-k3s/postgres -> backup SQL -> restore su k3s-datacenter/postgres
```

Il flusso di controllo DR e:

```text
dr-controller -> healthcheck cloud -> restore on-prem -> promote on-prem -> update DNS
```

## Stato finale della PoC

Dopo il failover testato, lo stato corretto e:

```text
.state/mode = dr
helpdesk.azienda.lan = 10.10.3.10
```

Questo significa che il servizio helpdesk viene risolto verso il sito on-prem e che la readiness del sito DR e attiva.

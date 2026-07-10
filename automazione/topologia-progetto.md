# Topologia progetto Reverse DR

Questo documento descrive la topologia LXC/Kubernetes della PoC: rete on-premise, cloud simulato, servizi applicativi, DNS, Git, backup e flusso di disaster recovery.

## Vista completa

```mermaid
flowchart LR
  internet["Internet / rete esterna"]

  subgraph cloudnet["cloud-net 10.20.0.0/24"]
    cloudk3s["cloud-k3s\n10.20.0.10\nK3s primario"]
    clouding["Traefik Ingress\nhelpdesk.azienda.lan\n10.20.0.10"]
    cloudapi["Pod helpdesk-api\nsite_role=primary\n/health/ready always"]
    cloudpg["Pod postgres\nDB helpdesk"]
    cloudbackup["Backup SQL\n/srv/helpdesk-backups"]
    cloudk3s --> clouding
    clouding --> cloudapi
    cloudapi --> cloudpg
    cloudpg --> cloudbackup
  end

  subgraph transit["lab-transit 10.10.4.0/24"]
    redge["router-edge OpenWrt\neth0 10.10.4.2\neth1 DHCP lxdbr0\nNAT outbound"]
    rdmz_t["router-dmz OpenWrt\neth1 10.10.4.1"]
  end

  subgraph dmz["lab-dmz 10.10.2.0/24"]
    rdmz["router-dmz OpenWrt\neth0 10.10.2.4"]
    rdip_d["router-dipendenti OpenWrt\neth1 10.10.2.2"]
    rdc_d["router-datacenter OpenWrt\neth1 10.10.2.3"]
    dns["server-dns\n10.10.2.53\nBind9 aziendale"]
  end

  subgraph dip["lab-dipendenti 10.10.1.0/24"]
    rdip["router-dipendenti OpenWrt\neth0 10.10.1.1"]
    pc1["pc-dipendente1\n10.10.1.193\nclient aziendale"]
  end

  subgraph dc["lab-datacenter 10.10.3.0/24"]
    rdc["router-datacenter OpenWrt\neth0 10.10.3.1"]
    onpremk3s["k3s-datacenter\n10.10.3.10\nK3s DR on-prem"]
    keycloak["proxy-keycloak\n10.10.3.50"]
    egress["egress-proxy\n10.10.3.60"]
    git["git-server\n10.10.3.70\nbare repo helpdesk-dr.git"]
    ansible["ansible-node\n10.10.3.100\nAnsible + DR controller"]
    onpreming["Traefik Ingress\nhelpdesk.azienda.lan\n10.10.3.10"]
    onpremapi["Pod helpdesk-api\nsite_role=standby\n/health/ready marker"]
    onprempg["Pod postgres\nDB restored da backup"]
    onpremk3s --> onpreming
    onpreming --> onpremapi
    onpremapi --> onprempg
  end

  internet <--> redge
  redge --- rdmz_t
  rdmz_t --- rdmz
  rdmz --- rdip_d
  rdmz --- rdc_d
  rdip_d --- rdip
  rdc_d --- rdc

  pc1 --> rdip
  rdip --> rdmz
  rdc --> rdmz
  onpremk3s --> rdc
  git --> rdc
  ansible --> rdc
  keycloak --> rdc
  egress --> rdc
  dns --> rdmz

  ansible -. "publish source of truth" .-> git
  ansible -. "backup / restore / failover scripts" .-> cloudk3s
  ansible -. "restore + promote" .-> onpremk3s
  dns -. "helpdesk.azienda.lan -> cloud or on-prem" .-> clouding
  dns -. "DR cutover" .-> onpreming
```

## Reti

| Rete LXD | Subnet | Gateway LXD | Gateway logico | Significato |
|---|---:|---:|---:|---|
| `lab-dipendenti` | `10.10.1.0/24` | `10.10.1.254` | `router-dipendenti 10.10.1.1` | LAN utenti/dipendenti |
| `lab-dmz` | `10.10.2.0/24` | `10.10.2.254` | `router-dmz 10.10.2.4` | DMZ aziendale |
| `lab-datacenter` | `10.10.3.0/24` | `10.10.3.254` | `router-datacenter 10.10.3.1` | Datacenter on-prem |
| `lab-transit` | `10.10.4.0/24` | `10.10.4.254` | `router-edge 10.10.4.2` | Rete transit verso edge |
| `cloud-net` | `10.20.0.0/24` | `10.20.0.1` | `cloud-k3s 10.20.0.10` | Cloud simulato esterno all'on-prem |
| `lxdbr0` | DHCP LXD | variabile | `router-edge eth1` | Uscita NAT verso Internet/host |

## Nodi LXC

| Nodo | OS / ruolo | Interfacce e IP | Servizi principali |
|---|---|---|---|
| `router-dipendenti` | OpenWrt router | `eth0 10.10.1.1`, `eth1 10.10.2.2` | routing LAN dipendenti verso DMZ/DC/edge |
| `router-datacenter` | OpenWrt router | `eth0 10.10.3.1`, `eth1 10.10.2.3` | routing datacenter verso DMZ/edge |
| `router-dmz` | OpenWrt router | `eth0 10.10.2.4`, `eth1 10.10.4.1` | router centrale DMZ, default route verso edge |
| `router-edge` | OpenWrt edge router | `eth0 10.10.4.2`, `eth1 DHCP lxdbr0` | NAT outbound verso Internet, nessun inbound intenzionale |
| `server-dns` | Ubuntu | `eth0 10.10.2.53` | Bind9, zona `azienda.lan`, record `helpdesk.azienda.lan` |
| `pc-dipendente1` | Ubuntu client | `eth0 10.10.1.193` | client interno |
| `k3s-datacenter` | Ubuntu + k3s | `eth0 10.10.3.10` | cluster Kubernetes on-prem DR |
| `proxy-keycloak` | Ubuntu | `eth0 10.10.3.50` | nodo previsto per proxy/autenticazione |
| `egress-proxy` | Ubuntu | `eth0 10.10.3.60` | nodo previsto per egress applicativo |
| `git-server` | Ubuntu | `eth0 10.10.3.70` | repository bare `helpdesk-dr.git`, `git-daemon` |
| `ansible-node` | Ubuntu | `eth0 10.10.3.100` | Ansible, runbook DR, controller DR |
| `cloud-k3s` | Ubuntu + k3s | `eth0 10.20.0.10` | cluster Kubernetes primario cloud simulato |

## Servizi applicativi

```mermaid
flowchart TB
  subgraph cloud["Cluster cloud-k3s 10.20.0.10"]
    cing["Ingress Traefik\nhost helpdesk.azienda.lan"]
    csvc["Service helpdesk-api:80"]
    capi["Deployment helpdesk-api\nimage python:3.12-slim\nuvicorn :8080\nSITE_ROLE=primary\nDR_READY_POLICY=always"]
    cpgsvc["Service postgres:5432"]
    cpg["Deployment postgres\nimage postgres:16-alpine\nPVC postgres-data 2Gi"]
    cing --> csvc --> capi --> cpgsvc --> cpg
  end

  subgraph onprem["Cluster k3s-datacenter 10.10.3.10"]
    oing["Ingress Traefik\nhost helpdesk.azienda.lan"]
    osvc["Service helpdesk-api:80"]
    oapi["Deployment helpdesk-api\nSITE_ROLE=standby\nDR_READY_POLICY=marker\nready solo con /dr-state/ready"]
    opgsvc["Service postgres:5432"]
    opg["Deployment postgres\nPVC postgres-data 2Gi\nrestore da backup"]
    oing --> osvc --> oapi --> opgsvc --> opg
  end

  dns["server-dns 10.10.2.53\nhelpdesk.azienda.lan"]
  dns -. "normal mode -> 10.20.0.10" .-> cing
  dns -. "DR mode -> 10.10.3.10" .-> oing
```

## Flusso normale

```mermaid
sequenceDiagram
  participant Client as pc-dipendente1 / utenti interni
  participant DNS as server-dns 10.10.2.53
  participant DMZ as router-dmz 10.10.2.4
  participant Edge as router-edge 10.10.4.2
  participant Cloud as cloud-k3s 10.20.0.10
  participant App as helpdesk-api primary
  participant DB as postgres primary

  Client->>DNS: resolve helpdesk.azienda.lan
  DNS-->>Client: A 10.20.0.10 in normal mode
  Client->>DMZ: HTTP verso helpdesk
  DMZ->>Edge: uscita verso cloud simulato/esterno
  Edge->>Cloud: traffico outbound
  Cloud->>App: Ingress Traefik -> Service
  App->>DB: query ticket/helpdesk
  DB-->>App: dati
  App-->>Client: risposta applicativa
```

## Flusso DR automatico

```mermaid
sequenceDiagram
  participant Controller as dr-controller su ansible-node
  participant Cloud as cloud-k3s primary
  participant Backup as /srv/helpdesk-backups
  participant OnPrem as k3s-datacenter standby
  participant DNS as server-dns
  participant Client as utenti interni

  loop ogni DR_CONTROLLER_INTERVAL_SECONDS
    Controller->>Cloud: GET /health/ready
  end

  Cloud--xController: failure per DR_CONTROLLER_FAILURE_THRESHOLD
  Controller->>Backup: seleziona ultimo helpdesk-*.sql
  Controller->>OnPrem: restore-onprem.sh
  OnPrem->>OnPrem: scala app, restore Postgres
  Controller->>OnPrem: promote-onprem.sh
  OnPrem->>OnPrem: crea /dr-state/ready
  Controller->>DNS: helpdesk.azienda.lan -> 10.10.3.10
  Client->>DNS: resolve helpdesk.azienda.lan
  DNS-->>Client: A 10.10.3.10
  Client->>OnPrem: traffico verso sito DR
```

## DNS

| Record | Valore in normal mode | Valore in DR mode | Note |
|---|---:|---:|---|
| `helpdesk.azienda.lan` | `10.20.0.10` | `10.10.3.10` | record aggiornato dagli script DR |
| `server-dns.azienda.lan` | `10.10.2.53` | `10.10.2.53` | DNS aziendale |
| `git-server.azienda.lan` | `10.10.3.70` | `10.10.3.70` | source of truth applicativo |
| `cloud-helpdesk.azienda.lan` | `10.20.0.10` | `10.20.0.10` | riferimento esplicito al primario |
| `onprem-helpdesk.azienda.lan` | `10.10.3.10` | `10.10.3.10` | riferimento esplicito al sito DR |

## Routing logico

| Origine | Default gateway | Rotte rilevanti |
|---|---:|---|
| LAN dipendenti `10.10.1.0/24` | `10.10.1.1` | verso DC via DMZ, default verso `10.10.2.4` |
| Datacenter `10.10.3.0/24` | `10.10.3.1` | verso dipendenti via `10.10.2.2`, default verso `10.10.2.4` |
| DMZ `10.10.2.0/24` | `10.10.2.4` | route verso dipendenti `10.10.2.2`, DC `10.10.2.3`, transit `10.10.4.2` |
| Transit `10.10.4.0/24` | `10.10.4.2` | uscita tramite `router-edge` |
| Cloud simulato `10.20.0.0/24` | `10.20.0.1` | rete LXD separata dall'on-prem |

## Componenti DR

| Componente | Dove gira | Responsabilita |
|---|---|---|
| `backup-cloud.sh` | host WSL / ansible-node operativo | genera backup SQL da Postgres cloud |
| `cloud-local-backup.sh` | `cloud-k3s` via timer | backup periodico locale nel cloud simulato |
| `restore-onprem.sh` | host WSL / ansible-node operativo | copia ultimo backup e ripristina Postgres on-prem |
| `promote-onprem.sh` | host WSL / ansible-node operativo | scala app on-prem, crea marker `/dr-state/ready`, aggiorna DNS |
| `demote-onprem.sh` | host WSL / ansible-node operativo | rimuove marker DR e riporta on-prem in standby |
| `dr-controller.sh` | host WSL / ansible-node operativo | monitora primary e attiva failover automatico |
| K8GB manifest | entrambi i cluster, futuro step | GSLB DNS failover basato su readiness |

## Scelta architetturale

La PoC separa tre responsabilita:

1. DNS/GSLB: `server-dns` oggi, K8GB in uno step successivo.
2. Orchestrazione DR: `dr-controller.sh` e runbook Ansible/script.
3. Stato applicativo: backup/restore Postgres, non replica active-active.

Questa separazione e intenzionale: K8GB decide quale sito pubblicare, ma non deve eseguire restore o playbook. La readiness on-prem diventa positiva solo dopo restore e promozione, quindi il traffico non viene mandato a un sito DR non pronto.


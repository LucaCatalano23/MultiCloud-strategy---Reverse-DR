# Topologia progetto Reverse DR

> Evoluzione production-like: `cloud-k3s` e il data plane EKS-like del sito cloud simulato; `ansible-node` mantiene un mirror off-cloud dei backup (oggi popolato manualmente) e orchestra il failover. La simulazione delle API AWS (EKS/S3/IAM/Lambda) via LocalStack e' stata rimossa: quella copertura resta solo nella generazione corrente con AWS reale. Il runbook operativo aggiornato e in [`RUNBOOK_SCENARIO_REALE.md`](RUNBOOK_SCENARIO_REALE.md).

Questo documento descrive la topologia LXC/Kubernetes della PoC: rete on-premise, cloud simulato, servizi applicativi, DNS, Git, backup e flusso di disaster recovery.

## Vista completa

```mermaid
flowchart LR
  internet["Internet / rete esterna"]

  subgraph cloudnet["cloud-net 10.20.0.0/24"]
    cloudk3s["cloud-k3s\n10.20.0.10\nK3s primario\ndata plane, nessuna app"]
    cloudbackup["Backup SQL\n/srv/helpdesk-backups"]
    cloudk3s --> cloudbackup
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
    git["git-server\n10.10.3.70\nbare repo helpdesk-dr.git"]
    vault["vault-openbao\n10.10.3.80\nOpenBao, segreti del sito DR"]
    ansible["ansible-node\n10.10.3.100\nAnsible + DR controller"]
    onpreming["Traefik Ingress\nheliospoc.terna.it\n10.10.3.10"]
    onpremapp["Workload Helios\nweb / bff / ticket / automation\nreplicas 0 a riposo"]
    onprempg["Pod postgres\nDB helios restored da backup"]
    onpremk3s --> onpreming
    onpreming --> onpremapp
    onpremapp --> onprempg
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
  vault --> rdc
  ansible --> rdc
  dns --> rdmz

  onpremk3s -. "External Secrets legge i segreti DR" .-> vault
  ansible -. "publish source of truth" .-> git
  ansible -. "backup / restore / failover scripts" .-> cloudk3s
  ansible -. "restore + promote" .-> onpremk3s
  ansible -. "preflight: vault dissigillato" .-> vault
  dns -. "normal mode -> cloud" .-> cloudk3s
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
| `server-dns` | Ubuntu | `eth0 10.10.2.53` | Bind9, zona lab `azienda.lan` e zona host-specific `heliospoc.terna.it` |
| `pc-dipendente1` | Ubuntu client | `eth0 10.10.1.193` | client interno |
| `k3s-datacenter` | Ubuntu + k3s | `eth0 10.10.3.10` | cluster Kubernetes on-prem DR |
| `git-server` | Ubuntu | `eth0 10.10.3.70` | repository bare `helpdesk-dr.git`, `git-daemon` |
| `vault-openbao` | Ubuntu | `eth0 10.10.3.80` | OpenBao, vault manager dei segreti del sito DR |
| `ansible-node` | Ubuntu | `eth0 10.10.3.100` | Ansible, runbook DR, controller DR |
| `cloud-k3s` | Ubuntu + k3s | `eth0 10.20.0.10` | cluster Kubernetes primario cloud simulato |

## Servizi applicativi

```mermaid
flowchart TB
  subgraph cloud["Cluster cloud-k3s 10.20.0.10"]
    cdp["Data plane Kubernetes\nnessun workload applicativo\nfailure domain del drill"]
  end

  subgraph onprem["Cluster k3s-datacenter 10.10.3.10"]
    oing["Ingress Traefik\nhost heliospoc.terna.it"]
    oweb["Deployment helios-web :8080\nreplicas 0 a riposo"]
    obff["Deployment helios-bff :8000\nSITE_MODE=dr in DR"]
    osvcs["helios-ticket-service :8001\nhelios-automation-service :8002\nClusterIP"]
    opgsvc["Service postgres:5432"]
    opg["Deployment postgres\nPVC postgres-data 2Gi\ndatabase helios restored"]
    oing --> oweb
    oing --> obff
    obff --> osvcs
    osvcs --> opgsvc --> opg
  end

  dns["server-dns 10.10.2.53\nheliospoc.terna.it"]
  dns -. "normal mode -> 10.20.0.10" .-> cdp
  dns -. "DR mode -> 10.10.3.10" .-> oing
```

Il monolite `helpdesk-api`, unica applicazione della prima versione della PoC, e'
stato rimosso: l'applicazione e' ora Helios, e il sito primario reale e' AWS EKS
(`automazione/infra/aws`). `cloud-k3s` resta come dominio di guasto spegnibile
nel drill, senza workload applicativi.

## Flusso normale

```mermaid
sequenceDiagram
  participant Client as pc-dipendente1 / utenti interni
  participant DNS as server-dns 10.10.2.53
  participant DMZ as router-dmz 10.10.2.4
  participant Edge as router-edge 10.10.4.2
  participant Cloud as sito primario (AWS EKS)
  participant App as helios-web / helios-bff
  participant DB as RDS PostgreSQL

  Client->>DNS: resolve heliospoc.terna.it
  DNS-->>Client: A del sito primario in normal mode
  Client->>DMZ: HTTPS verso helpdesk
  DMZ->>Edge: uscita verso il cloud
  Edge->>Cloud: traffico outbound
  Cloud->>App: ALB same-origin -> web e /api -> bff
  App->>DB: query ticket
  DB-->>App: dati
  App-->>Client: risposta applicativa
```

In laboratorio `cloud-k3s` non serve piu' questo flusso: dopo la rimozione del
monolite ospita solo il data plane Kubernetes usato come dominio di guasto. Il
percorso applicativo primario reale e' quello AWS descritto in
`automazione/infra/aws`.

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
  OnPrem->>OnPrem: imposta DR_ACTIVE=true
  Controller->>DNS: heliospoc.terna.it -> 10.10.3.10
  Client->>DNS: resolve heliospoc.terna.it
  DNS-->>Client: A 10.10.3.10
  Client->>OnPrem: traffico verso sito DR
```

## DNS

| Record | Valore in normal mode | Valore in DR mode | Note |
|---|---:|---:|---|
| `heliospoc.terna.it` | `10.20.0.10` | `10.10.3.10` | zona host-specific split-horizon aggiornata dagli script DR |
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
| `restore-onprem.sh` | host WSL / ansible-node operativo | copia ultimo backup dal mirror e ripristina Postgres on-prem |
| `promote-onprem.sh` | `ansible-node` | scala app on-prem, imposta `DR_ACTIVE=true`, verifica readiness e aggiorna DNS |
| `demote-onprem.sh` | `ansible-node` | imposta `DR_ACTIVE=false` e riporta on-prem in standby |
| `dr-controller.sh` | host WSL / ansible-node operativo | monitora primary e attiva failover automatico |
| K8GB manifest | entrambi i cluster, futuro step | GSLB DNS failover basato su readiness |

Il backup periodico del primary cloud verso S3 e il mirror automatico on-prem, prima orchestrati via LocalStack, sono stati rimossi insieme a LocalStack: il mirror consumato da `restore-onprem.sh` va oggi popolato manualmente su `ansible-node`.

## Scelta architetturale

La PoC separa tre responsabilita:

1. DNS/GSLB: `server-dns` oggi, K8GB in uno step successivo.
2. Orchestrazione DR: `dr-controller.sh` e runbook Ansible/script.
3. Stato applicativo: backup/restore Postgres, non replica active-active.

Questa separazione e intenzionale: K8GB decide quale sito pubblicare, ma non deve eseguire restore o playbook. La readiness on-prem diventa positiva solo dopo restore e promozione, quindi il traffico non viene mandato a un sito DR non pronto.

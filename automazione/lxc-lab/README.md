# LXC Lab Network on WSL

Questa directory ricrea in LXD/LXC la topologia mostrata nella foto.

## Topologia

| Container | Ruolo | Interfacce |
| --- | --- | --- |
| `ansible-node` | nodo di controllo con Ansible | `10.10.3.100/24` su datacenter |
| `git-server` | server Git reale con repo bare | `10.10.3.70/24` su datacenter |
| `k3s-datacenter` | nodo datacenter | `10.10.3.10/24` su datacenter |
| `pc-dipendente1` | client rete dipendenti | `10.10.1.193/24` su dipendenti |
| `vault-openbao` | Secret Vault OpenBao | `10.10.3.80/24` su datacenter |
| `router-datacenter` | router OpenWrt | `10.10.3.1/24` su datacenter, `10.10.2.3/24` su DMZ |
| `router-dipendenti` | router OpenWrt | `10.10.1.1/24` su dipendenti, `10.10.2.2/24` su DMZ |
| `router-dmz` | router OpenWrt | `10.10.2.4/24` su DMZ, `10.10.4.1/24` su transit |
| `router-edge` | router/firewall OpenWrt egress-only | `10.10.4.2/24` su transit, DHCP su `lxdbr0` |
| `server-dns` | server DNS Bind9 reale | `10.10.2.53/24` su DMZ |

Reti:

- `lab-dipendenti`: `10.10.1.0/24`
- `lab-dmz`: `10.10.2.0/24`
- `lab-datacenter`: `10.10.3.0/24`
- `lab-transit`: `10.10.4.0/24`, uscita Internet tramite `router-edge`

## Uscita Internet

La rete aziendale simulata esce su Internet solo attraverso `router-edge`:

```text
reti interne -> router-dmz -> lab-transit -> router-edge -> lxdbr0 -> Internet
```

`router-edge` applica NAT solo verso `lxdbr0` e accetta forwarding solo da `transit` verso `wan`. La `wan` rifiuta nuove connessioni in ingresso, quindi Internet non puo iniziare connessioni verso la rete lab; sono consentite solo le risposte a connessioni originate dall'interno.

`server-dns` inoltra le richieste ricorsive a `router-edge` (`10.10.4.2`), il
quale usa il resolver ricevuto via DHCP sulla WAN. In questo modo il lab segue
il DNS consentito dalla rete dell'host anche quando una VPN o una rete aziendale
blocca le query dirette verso resolver pubblici come `1.1.1.1`.

## Prerequisiti WSL

Usa Ubuntu su WSL con systemd abilitato. Verifica:

```bash
ps -p 1 -o comm=
```

Il risultato deve essere `systemd`.

Installa LXD se manca:

```bash
sudo snap install lxd
sudo lxd init --minimal
sudo usermod -aG lxd "$USER"
newgrp lxd
```

## Avvio

Da WSL, dentro questo repository:

```bash
cd /path/to/repository/automazione/lxc-lab
bash setup.sh
```

Se la tua installazione LXD usa un alias diverso per OpenWrt, trova quello disponibile:

```bash
lxc image list images: openwrt
```

Poi rilancia indicando l'alias corretto:

```bash
OPENWRT_IMAGE='images:openwrt/23.05/amd64' bash setup.sh
```

Verifica:

```bash
lxc list
bash healthcheck.sh
```

Per usare `server-dns` anche sullo host WSL (quindi avere il failover locale
`terna.it` anche nel browser/strumenti eseguiti sull'host), dopo il setup:

```ini
# /etc/wsl.conf: preservare eventuali altre sezioni gia presenti
[boot]
systemd=true

[network]
generateResolvConf=false
```

Dopo la modifica eseguire `wsl --shutdown` da PowerShell e riaprire WSL. La
seconda opzione impedisce a WSL di sovrascrivere al riavvio il collegamento a
`systemd-resolved` gestito dallo script. Quindi:

```bash
sudo bash host-dns.sh enable
```

È reversibile con `sudo bash host-dns.sh disable`. In alternativa, per
applicarlo all'interno del provisioning: `sudo -E LXC_LAB_HOST_DNS=true bash setup.sh`.

Lo script mantiene `10.255.255.254`, l'indirizzo predefinito del DNS tunneling
WSL, come `FallbackDNS` di `systemd-resolved`. Quando si esegue `disable`, questo
evita che il resolver rimanga senza alcun nameserver. Se in `.wslconfig` è stato
personalizzato `dnsTunnelingIpAddress`, passare lo stesso valore tramite
`WSL_DNS_TUNNEL_IP` sia a `enable` sia a `disable`.

Il setup è riconciliativo: può essere rilanciato. Per Terna Static DR confronta
il checksum dei manifest nel namespace `terna-static-dr` e quello del controller
su `ansible-node`; se Deployment, controller e configurazione sono già corretti,
salta l'applicazione/copia. Per usare una configurazione locale, crea
`../terna-static-dr/config.lxc-lab.env` dal relativo esempio prima di lanciare
`setup.sh`; il file resta fuori da Git.

Su OpenWrt 24.10 in LXC il comando `/etc/init.d/network restart` può bloccarsi
su `ubus call network.interface dump`. Il setup non usa quel percorso: salva la
configurazione persistente in UCI e applica indirizzi e rotte al runtime tramite
`ip`. Se un'esecuzione precedente si è interrotta lasciando i router in stato
parziale, dopo aver aggiornato gli script è sufficiente rilanciare `bash
setup.sh`; il reconcile Terna ripara anche il percorso interno senza riavviare
globalmente la rete OpenWrt.

Se un container non parte, raccogli subito la diagnostica:

```bash
bash diagnose.sh
```

Se LXD risponde con `Failed to begin transaction: context deadline exceeded`, aspetta 30-60 secondi e rilancia lo stesso comando: gli script fanno retry automatico, ma quel messaggio indica che il daemon LXD e ancora impegnato su operazioni locali di database, immagini o storage. Se persiste:

```bash
snap services lxd
sudo snap restart lxd
bash setup.sh
```

I router OpenWrt vengono configurati come container privilegiati con nesting abilitato. La scelta e necessaria per rendere affidabili init e networking OpenWrt dentro LXD su WSL; i nodi Ubuntu restano container di servizio separati e con configurazione minima.

Durante il provisioning i nodi Ubuntu ricevono anche una NIC temporanea `eth9` su `lxdbr0`: serve solo per scaricare pacchetti con `apt` tramite la NAT di LXD. Alla fine di `setup.sh` la NIC viene rimossa e resta solo la rete di laboratorio mostrata dalla topologia.

## Accesso ai servizi

Repository Git bare:

```bash
git clone git://10.10.3.70/infrastructure.git
```

DNS:

```bash
dig @10.10.2.53 git-server.lab.lxc
dig @10.10.2.53 ansible-node.lab.lxc
```

Ansible:

```bash
lxc exec ansible-node -- ansible --version
```

Router OpenWrt:

```bash
lxc exec router-dipendenti -- uci show network
lxc exec router-datacenter -- uci show network
lxc exec router-dmz -- uci show network
```

## Rimozione

```bash
bash teardown.sh
```

La rimozione elimina solo container e network con prefisso `lab-` definiti da questi script.

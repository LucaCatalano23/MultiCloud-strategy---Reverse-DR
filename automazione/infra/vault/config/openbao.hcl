# OpenBao del sito DR — configurazione di laboratorio.
#
# Perche' un nodo dedicato e non un workload k3s: il vault custodisce i segreti
# del cluster, quindi non deve dipendere dal cluster che protegge. Un rebuild di
# k3s-datacenter non deve comportare la perdita del materiale crittografico, e
# il vault resta un dominio di fiducia separato.

ui = false

# Storage su file: adeguato a un'istanza singola di laboratorio. Per produzione
# serve un backend con alta disponibilita' (Raft integrato con almeno 3 nodi):
# con `file` non esiste replica e il nodo e' un single point of failure
# dichiarato, esattamente come la NAT instance sul lato AWS.
storage "file" {
  path = "/var/lib/openbao/data"
}

listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_cert_file = "/etc/openbao/tls/tls.crt"
  tls_key_file  = "/etc/openbao/tls/tls.key"

  # TLS obbligatorio anche in laboratorio: External Secrets Operator preleva
  # da qui credenziali di database e chiavi di sessione attraverso la rete del
  # datacenter, quindi il canale non puo' essere in chiaro.
  tls_min_version = "tls12"
}

api_addr = "https://vault.azienda.lan:8200"

# Nessun blocco `seal`: il sigillo resta Shamir. Un auto-unseal via KMS del
# cloud reintrodurrebbe una dipendenza dal sito primario proprio nello scenario
# in cui il sito primario e' caduto, cioe' contraddirebbe la premessa del
# reverse DR. Il costo di questa scelta e' dichiarato nel README: dopo un
# riavvio del nodo l'unseal e' un'operazione manuale.

# mlock richiede CAP_IPC_LOCK, non concesso ai container LXC non privilegiati
# del lab. E' una concessione di laboratorio: in produzione va lasciato attivo
# per impedire che il materiale crittografico finisca nello swap.
disable_mlock = true

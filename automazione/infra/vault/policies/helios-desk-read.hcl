# Politica del namespace applicativo: sola lettura, solo i propri percorsi.
#
# Nessun permesso di scrittura: chi consuma i segreti non deve poterli
# modificare. La rotazione passa da `seed-secrets.sh`, che usa un token
# amministrativo separato e non risiede nel cluster.

path "helios/data/onprem/application/database" {
  capabilities = ["read"]
}

path "helios/data/onprem/application/bff-runtime" {
  capabilities = ["read"]
}

path "helios/data/onprem/application/tls" {
  capabilities = ["read"]
}

# Metadata in lettura: External Secrets Operator lo interroga per rilevare una
# nuova versione senza dover rileggere il valore a ogni ciclo di refresh.
path "helios/metadata/onprem/application/*" {
  capabilities = ["read", "list"]
}

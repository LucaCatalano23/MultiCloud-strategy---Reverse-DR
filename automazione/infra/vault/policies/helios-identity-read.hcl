# Politica del namespace identita': sola lettura, solo i propri percorsi.
#
# Separata da quella applicativa perche' i due namespace hanno cicli di vita
# diversi: un restore dei ticket non deve poter toccare realm, credenziali
# Keycloak o l'operatore DR, e viceversa.

path "helios/data/onprem/identity/keycloak-postgres" {
  capabilities = ["read"]
}

path "helios/data/onprem/identity/keycloak-bootstrap-admin" {
  capabilities = ["read"]
}

path "helios/data/onprem/identity/bff-oidc" {
  capabilities = ["read"]
}

path "helios/data/onprem/identity/dr-operator" {
  capabilities = ["read"]
}

path "helios/data/onprem/identity/tls" {
  capabilities = ["read"]
}

path "helios/metadata/onprem/identity/*" {
  capabilities = ["read", "list"]
}

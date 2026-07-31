#!/usr/bin/env bash
# =============================================================================
# provision.sh — provisioning del sito primario AWS della PoC Reverse DR
#                via AWS CLI, senza Terraform.
#
# Traduzione eseguibile di RUNBOOK_PROVISIONING_AWS.md. Ogni funzione `sNN_*`
# corrisponde a una sezione del runbook; il commento di apertura la richiama.
#
# NON e' un sostituto di Terraform: non ha uno state authoritative ne' un piano
# di diff. Le funzioni sono scritte per essere **ri-eseguibili** (create-if-not-
# exists via lookup per tag/nome, ID persistiti in uno state file), ma restano
# uno script di bootstrap, non un reconciler. Gli ID creati finiscono in
# ~/.reverse-dr/state.env, che ogni sezione ricarica: puoi eseguire una sezione
# alla volta e riprendere dopo un errore.
#
# USO:
#   ./provision.sh preflight        # verifiche (regione, servizi, tool)
#   ./provision.sh all              # tutte le sezioni infrastrutturali in ordine
#   ./provision.sh s04_network      # una sola sezione
#   ./provision.sh teardown         # distruzione guidata (richiede conferma)
#
# Le sezioni che richiedono passi manuali esterni (validazione DNS del
# certificato, valori Entra, PEM del certificato BFF) si fermano con un messaggio
# esplicito: sono input che non appartengono a questo account.
#
# Riferimenti architetturali deliberati (CLAUDE.md §3): single-AZ applicativo,
# NAT instance invece di NAT Gateway, subnet witness senza workload, RDS non
# multi-AZ. Lo script li rispetta; non "correggerli".
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# §1.2 — Variabili di sessione e naming
# -----------------------------------------------------------------------------
# Regione della PoC: eu-south-1 (Milano), opt-in (vedi preflight).
export AWS_REGION="${AWS_REGION:-eu-south-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"

PREFIX="${PREFIX:-reverse-dr-poc}"          # = project_name-environment
VPC_CIDR="10.42.0.0/16"
PRIMARY_PUBLIC_CIDR="10.42.0.0/24"
WITNESS_PUBLIC_CIDR="10.42.1.0/27"
PRIMARY_PRIVATE_CIDR="10.42.10.0/24"
WITNESS_PRIVATE_CIDR="10.42.11.0/28"

DB_NAME="helios"
DB_MASTER_USER="platform_admin"
DB_ENGINE_VERSION="16"
DB_INSTANCE_CLASS="db.t4g.micro"
NAT_INSTANCE_TYPE="t4g.nano"
NODE_INSTANCE_TYPE="t3.medium"
K8S_NAMESPACE="helios-desk"

# CloudWatch: nella PoC e' solo logging diagnostico, non tocca le metriche
# RPO/RTO (che vivono nella tabella dr_telemetry in PostgreSQL). Qui si sceglie
# quanto tenerne acceso. Default cost-conscious: solo l'authenticator del control
# plane EKS, utile proprio durante il bring-up manuale per capire perche' un
# principal viene rifiutato. Metti "api,audit,authenticator" per il set completo,
# o stringa vuota per spegnerlo del tutto.
EKS_LOG_TYPES="${EKS_LOG_TYPES:-authenticator}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"

# Percorso del repository, per build immagini e overlay Kubernetes.
REPO_ROOT="${REPO_ROOT:-/path/to/repository}"

# -----------------------------------------------------------------------------
# §2 / §3 — Input esterni. Lo script NON crea questi valori.
# -----------------------------------------------------------------------------
# Hostname applicativo: stesso valore del certificato ACM, del redirect URI
# registrato in Entra e del record DNS. Deciso una volta, non modificabile a
# costo zero dopo.
APP_HOST="${APP_HOST:-}"                      # es. helios.tuodominio.example

# ACM_SELF_SIGNED=1 per host interni/placeholder (es. *.azienda.lan): la CA
# pubblica di ACM non emette per domini non pubblici (il certificato va in
# FAILED). In questa modalita' lo script genera un certificato self-signed per
# APP_HOST e lo importa in ACM. Il browser mostra un avviso, ma TLS sull'ALB,
# login OIDC e cookie __Host-* funzionano: e' un limite PoC dichiarato, non un
# malfunzionamento. Con 0 si usa la validazione DNS pubblica.
ACM_SELF_SIGNED="${ACM_SELF_SIGNED:-0}"

# Valori consegnati dal team identita' aziendale (application registration
# demo-api-app-* e demo-bff-app-*). Sono non-secret.
# Il tenant NON e' una variabile a se': e' gia' dentro le cinque URL sotto
# (login.microsoftonline.com/<tenant>/...) e nessun campo del ConfigMap lo
# consuma separatamente, quindi non va chiesto due volte.
ENTRA_API_CLIENT_ID="${ENTRA_API_CLIENT_ID:-}"   # GUID, non api://...
ENTRA_BFF_CLIENT_ID="${ENTRA_BFF_CLIENT_ID:-}"
ENTRA_ISSUER_URL="${ENTRA_ISSUER_URL:-}"
ENTRA_JWKS_URL="${ENTRA_JWKS_URL:-}"
ENTRA_AUTHORIZATION_ENDPOINT="${ENTRA_AUTHORIZATION_ENDPOINT:-}"
ENTRA_TOKEN_ENDPOINT="${ENTRA_TOKEN_ENDPOINT:-}"
ENTRA_END_SESSION_ENDPOINT="${ENTRA_END_SESSION_ENDPOINT:-}"
ENTRA_API_SCOPE="${ENTRA_API_SCOPE:-}"           # es. api://<api-client-id>/access_as_user

# Credenziale confidenziale del BFF (private_key_jwt). Due modi, uno solo serve:
#  - BFF_PFX: un unico file PKCS#12 (.pfx), il formato tipico esportato da
#    Windows. Se impostato, s12 estrae chiave e certificato da solo, chiedendo
#    la password in modo interattivo.
#  - BFF_KEY_PEM / BFF_CERT_PEM: i due PEM gia' separati.
# Se BFF_PFX e' impostato ha precedenza sui due PEM.
BFF_PFX="${BFF_PFX:-}"
BFF_KEY_PEM="${BFF_KEY_PEM:-/tmp/bff-key.pem}"
BFF_CERT_PEM="${BFF_CERT_PEM:-/tmp/bff-cert.pem}"

# -----------------------------------------------------------------------------
# Infrastruttura di supporto: state file e helper
# -----------------------------------------------------------------------------
STATE_DIR="${STATE_DIR:-$HOME/.reverse-dr}"
STATE_FILE="$STATE_DIR/state.env"
mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
touch "$STATE_FILE"; chmod 600 "$STATE_FILE"
# shellcheck disable=SC1090
source "$STATE_FILE"

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[errore]\033[0m %s\n' "$*" >&2; exit 1; }

# save_state KEY VALUE — persiste una variabile e la esporta nella shell corrente.
save_state() {
  local key="$1" value="$2"
  # Rimuove una eventuale riga precedente per la stessa chiave, poi riaccoda.
  grep -v "^export ${key}=" "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null || true
  mv "${STATE_FILE}.tmp" "$STATE_FILE"
  printf 'export %s=%q\n' "$key" "$value" >> "$STATE_FILE"
  export "$key=$value"
}

need() { command -v "$1" >/dev/null 2>&1 || die "manca il tool richiesto: $1"; }

require_vars() {
  local missing=()
  for v in "$@"; do [ -n "${!v:-}" ] || missing+=("$v"); done
  [ ${#missing[@]} -eq 0 ] || die "variabili non impostate: ${missing[*]} (vedi la testa dello script)"
}

# tag_spec NAME — lista di tag in formato SHORTHAND per --tag-specifications.
# Deve restare shorthand ({Key=..,Value=..}) e non JSON: viene concatenata dentro
# "ResourceType=..,Tags=..", e l'AWS CLI non accetta JSON dentro lo shorthand.
# I valori non contengono spazi/virgole, quindi non serve quoting.
tag_spec() { printf '[{Key=Name,Value=%s},{Key=Project,Value=reverse-dr},{Key=Environment,Value=poc}]' "$1"; }

# =============================================================================
# preflight — §1.3 / §1.4: regione opt-in e disponibilita' servizi
# =============================================================================
preflight() {
  need aws; need jq; need kubectl; need docker; need helm

  log "Identita' AWS corrente:"
  aws sts get-caller-identity --output table
  save_state ACCOUNT_ID "$(aws sts get-caller-identity --query Account --output text)"
  save_state REGISTRY "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

  # §1.3 — eu-south-1 e' opt-in: va abilitata per account, e in una Organization
  # l'abilitazione puo' essere riservata al management account.
  local status
  status=$(aws account get-region-opt-status --region-name "$AWS_REGION" \
    --query RegionOptStatus --output text 2>/dev/null || echo "UNKNOWN")
  log "Stato regione $AWS_REGION: $status"
  if [ "$status" = "DISABLED" ]; then
    warn "La regione e' disabilitata. Provo ad abilitarla; se e' governata"
    warn "dall'organizzazione ricevi AccessDenied e va chiesta a chi la gestisce."
    aws account enable-region --region-name "$AWS_REGION"
    log "Attendo ENABLED (puo' richiedere qualche minuto)..."
    until [ "$(aws account get-region-opt-status --region-name "$AWS_REGION" \
        --query RegionOptStatus --output text)" = "ENABLED" ]; do sleep 30; done
  fi

  # §1.4 — disponibilita' istanze e AZ. La prima AZ e' la primaria, la seconda
  # la witness: lo script le sceglie qui e le persiste.
  log "Instance type disponibili (node + NAT):"
  aws ec2 describe-instance-type-offerings --location-type availability-zone \
    --filters "Name=instance-type,Values=${NODE_INSTANCE_TYPE},${NAT_INSTANCE_TYPE}" \
    --query 'InstanceTypeOfferings[].[InstanceType,Location]' --output table

  local azs
  azs=$(aws ec2 describe-availability-zones \
    --query 'AvailabilityZones[?State==`available`].ZoneName' --output text)
  save_state PRIMARY_AZ "$(echo "$azs" | tr '\t' '\n' | sort | sed -n '1p')"
  save_state WITNESS_AZ "$(echo "$azs" | tr '\t' '\n' | sort | sed -n '2p')"
  log "AZ primaria=$PRIMARY_AZ  witness=$WITNESS_AZ"

  aws rds describe-orderable-db-instance-options --engine postgres \
    --db-instance-class "$DB_INSTANCE_CLASS" \
    --query 'OrderableDBInstanceOptions[0].EngineVersion' --output text \
    || warn "Classe $DB_INSTANCE_CLASS non ordinabile in $AWS_REGION: verifica."
  log "preflight completato."
}

# _acm_self_signed — §3 (variante host interni): certificato self-signed per
# APP_HOST importato in ACM. ACM accetta l'import di certificati self-signed
# (sono issuer di se stessi, non serve catena). Limite PoC dichiarato: il
# browser mostra un avviso, ma il flusso funziona.
_acm_self_signed() {
  need openssl
  # Se lo stato punta gia' a un certificato IMPORTED, riusalo.
  if [ -n "${CERT_ARN:-}" ] && \
     aws acm describe-certificate --certificate-arn "$CERT_ARN" \
       --query 'Certificate.Type' --output text 2>/dev/null | grep -q IMPORTED; then
    log "Certificato self-signed gia' importato: $CERT_ARN"
    return
  fi
  umask 077
  local d="$STATE_DIR/selfsigned"; mkdir -p "$d"
  # SAN obbligatoria: i browser moderni ignorano il CN. 825 giorni di validita'.
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$d/key.pem" -out "$d/cert.pem" -days 825 \
    -subj "/CN=${APP_HOST}" -addext "subjectAltName=DNS:${APP_HOST}"
  local arn
  arn=$(aws acm import-certificate \
    --certificate "fileb://$d/cert.pem" \
    --private-key "fileb://$d/key.pem" \
    --tags "Key=Name,Value=${PREFIX}-selfsigned" \
    --query CertificateArn --output text)
  shred -u "$d/key.pem"
  save_state CERT_ARN "$arn"
  log "Certificato self-signed importato in ACM per ${APP_HOST}: $CERT_ARN"
  warn "Limite PoC: certificato self-signed. Il browser mostrera' un avviso di"
  warn "sicurezza da accettare una volta; login OIDC, cookie __Host-* e ALB"
  warn "funzionano comunque. Fai puntare ${APP_HOST} all'hostname dell'ALB via"
  warn "DNS interno o /etc/hosts (vedi verify)."
}

# =============================================================================
# s03_acm — §3: certificato ACM. Richiede un passo DNS manuale.
# =============================================================================
s03_acm() {
  require_vars APP_HOST
  [ "$ACM_SELF_SIGNED" = "1" ] && { _acm_self_signed; return; }
  # Riusa un certificato esistente SOLO se ISSUED o ancora in validazione. Un
  # certificato FAILED (validazione DNS mai completata) non si valida piu': va
  # richiesto di nuovo, non riciclato.
  local arn st
  arn=$(aws acm list-certificates \
    --query "CertificateSummaryList[?DomainName=='${APP_HOST}'].CertificateArn | [0]" \
    --output text)
  if [ "$arn" != "None" ] && [ -n "$arn" ]; then
    st=$(aws acm describe-certificate --certificate-arn "$arn" \
      --query 'Certificate.Status' --output text)
    case "$st" in
      ISSUED|PENDING_VALIDATION) : ;;  # riutilizzabile
      *) warn "Certificato esistente in stato $st: ne richiedo uno nuovo."; arn="None" ;;
    esac
  fi
  if [ "$arn" = "None" ] || [ -z "$arn" ]; then
    arn=$(aws acm request-certificate --domain-name "$APP_HOST" \
      --validation-method DNS --key-algorithm RSA_2048 \
      --query CertificateArn --output text)
    log "Certificato richiesto: $arn"
  fi
  save_state CERT_ARN "$arn"

  # ACM impiega qualche secondo a generare il record di validazione dopo la
  # richiesta: interrogarlo subito restituisce vuoto. Attendi che compaia.
  local rec="" i
  for i in $(seq 1 10); do
    rec=$(aws acm describe-certificate --certificate-arn "$CERT_ARN" \
      --query 'Certificate.DomainValidationOptions[0].ResourceRecord.Name' --output text 2>/dev/null)
    [ -n "$rec" ] && [ "$rec" != "None" ] && break
    sleep 3
  done
  log "Record CNAME di validazione da creare nel TUO DNS:"
  aws acm describe-certificate --certificate-arn "$CERT_ARN" \
    --query 'Certificate.DomainValidationOptions[].ResourceRecord' --output table

  local st
  st=$(aws acm describe-certificate --certificate-arn "$CERT_ARN" \
    --query 'Certificate.Status' --output text)
  if [ "$st" != "ISSUED" ]; then
    warn "Certificato in stato $st. Crea il CNAME sopra, poi rilancia questa"
    warn "sezione oppure attendi con:"
    warn "  aws acm wait certificate-validated --certificate-arn $CERT_ARN"
  else
    log "Certificato ISSUED."
  fi
}

# =============================================================================
# s04_network — §4: VPC, subnet, IGW, NAT instance, route table
# =============================================================================
s04_network() {
  require_vars PRIMARY_AZ WITNESS_AZ

  # VPC (lookup per tag Name, crea se assente)
  local vpc_id
  vpc_id=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${PREFIX}-vpc" \
    --query 'Vpcs[0].VpcId' --output text)
  if [ "$vpc_id" = "None" ]; then
    vpc_id=$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" \
      --tag-specifications "ResourceType=vpc,Tags=$(tag_spec "${PREFIX}-vpc")" \
      --query 'Vpc.VpcId' --output text)
    aws ec2 modify-vpc-attribute --vpc-id "$vpc_id" --enable-dns-support
    aws ec2 modify-vpc-attribute --vpc-id "$vpc_id" --enable-dns-hostnames
  fi
  save_state VPC_ID "$vpc_id"
  log "VPC $VPC_ID"

  # Quattro subnet. L'asimmetria e' deliberata (§4.2): witness minime.
  _subnet() { # nome AZ CIDR tier purpose extra_tags_json
    local name="$1" az="$2" cidr="$3"
    local id
    id=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=${name}" \
      --query 'Subnets[0].SubnetId' --output text)
    if [ "$id" = "None" ]; then
      id=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$cidr" \
        --availability-zone "$az" \
        --tag-specifications "ResourceType=subnet,Tags=$(tag_spec "$name")" \
        --query 'Subnet.SubnetId' --output text)
    fi
    echo "$id"
  }
  save_state PUB_PRIMARY_SUBNET  "$(_subnet "${PREFIX}-public-primary"  "$PRIMARY_AZ" "$PRIMARY_PUBLIC_CIDR")"
  save_state PUB_WITNESS_SUBNET  "$(_subnet "${PREFIX}-public-witness"  "$WITNESS_AZ" "$WITNESS_PUBLIC_CIDR")"
  save_state PRIV_PRIMARY_SUBNET "$(_subnet "${PREFIX}-private-primary" "$PRIMARY_AZ" "$PRIMARY_PRIVATE_CIDR")"
  save_state PRIV_WITNESS_SUBNET "$(_subnet "${PREFIX}-private-witness" "$WITNESS_AZ" "$WITNESS_PRIVATE_CIDR")"

  # Auto-assign IP pubblico sulle subnet pubbliche.
  aws ec2 modify-subnet-attribute --subnet-id "$PUB_PRIMARY_SUBNET" --map-public-ip-on-launch
  aws ec2 modify-subnet-attribute --subnet-id "$PUB_WITNESS_SUBNET" --map-public-ip-on-launch

  # Tag funzionali e documentali (§4.2). kubernetes.io/role/elb=1 e' cio' che
  # rende le subnet pubbliche scopribili dal controller ALB.
  aws ec2 create-tags --resources "$PUB_PRIMARY_SUBNET" "$PUB_WITNESS_SUBNET" \
    --tags "Key=kubernetes.io/role/elb,Value=1" "Key=Tier,Value=public"
  aws ec2 create-tags --resources "$PUB_WITNESS_SUBNET" --tags "Key=Workloads,Value=prohibited"
  aws ec2 create-tags --resources "$PRIV_PRIMARY_SUBNET" --tags "Key=Workloads,Value=allowed"  "Key=Tier,Value=private"
  aws ec2 create-tags --resources "$PRIV_WITNESS_SUBNET" --tags "Key=Workloads,Value=prohibited" "Key=Tier,Value=private"

  # Internet Gateway
  local igw_id
  igw_id=$(aws ec2 describe-internet-gateways \
    --filters "Name=tag:Name,Values=${PREFIX}-igw" \
    --query 'InternetGateways[0].InternetGatewayId' --output text)
  if [ "$igw_id" = "None" ]; then
    igw_id=$(aws ec2 create-internet-gateway \
      --tag-specifications "ResourceType=internet-gateway,Tags=$(tag_spec "${PREFIX}-igw")" \
      --query 'InternetGateway.InternetGatewayId' --output text)
    aws ec2 attach-internet-gateway --internet-gateway-id "$igw_id" --vpc-id "$VPC_ID"
  fi
  save_state IGW_ID "$igw_id"

  # Route table pubblica
  local rtb_pub
  rtb_pub=$(aws ec2 describe-route-tables \
    --filters "Name=tag:Name,Values=${PREFIX}-public" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'RouteTables[0].RouteTableId' --output text)
  if [ "$rtb_pub" = "None" ]; then
    rtb_pub=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
      --tag-specifications "ResourceType=route-table,Tags=$(tag_spec "${PREFIX}-public")" \
      --query 'RouteTable.RouteTableId' --output text)
    aws ec2 create-route --route-table-id "$rtb_pub" \
      --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID"
    aws ec2 associate-route-table --route-table-id "$rtb_pub" --subnet-id "$PUB_PRIMARY_SUBNET"
    aws ec2 associate-route-table --route-table-id "$rtb_pub" --subnet-id "$PUB_WITNESS_SUBNET"
  fi
  save_state RTB_PUBLIC "$rtb_pub"

  _nat_instance
  _private_route_table
  log "Rete pronta."
}

_nat_instance() {
  # §4.4 — NAT instance t4g.nano invece di NAT Gateway: scelta di costo con
  # limiti dichiarati (single point of failure). NON e' una baseline HA.
  local sg_id
  sg_id=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${PREFIX}-nat" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' --output text)
  if [ "$sg_id" = "None" ]; then
    sg_id=$(aws ec2 create-security-group --group-name "${PREFIX}-nat" \
      --description "Forward egress only from the primary private subnet" \
      --vpc-id "$VPC_ID" --query GroupId --output text)
    # Inbound solo dalla subnet privata primaria: impedisce alla NAT di
    # diventare un proxy aperto.
    aws ec2 authorize-security-group-ingress --group-id "$sg_id" \
      --ip-permissions "IpProtocol=-1,IpRanges=[{CidrIp=${PRIMARY_PRIVATE_CIDR}}]"
  fi
  save_state NAT_SG "$sg_id"

  local nat_id
  nat_id=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=${PREFIX}-nat" "Name=instance-state-name,Values=pending,running,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text)
  if [ "$nat_id" = "None" ]; then
    # AMI Amazon Linux 2023 arm64 dal parametro SSM pubblico: coerente con
    # t4g.nano (ARM). Se cambi a t3.nano (x86) cambia anche questo parametro.
    local ami
    ami=$(aws ssm get-parameter \
      --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-arm64 \
      --query 'Parameter.Value' --output text)
    local user_data
    user_data=$(base64 -w0 <<'UD'
#!/bin/bash
set -euxo pipefail
dnf install -y iptables-services
echo 'net.ipv4.ip_forward = 1' >/etc/sysctl.d/90-nat.conf
sysctl --system
default_interface="$(ip route show default | awk '{print $5; exit}')"
iptables -t nat -C POSTROUTING -o "$default_interface" -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -o "$default_interface" -j MASQUERADE
iptables-save >/etc/sysconfig/iptables
systemctl enable --now iptables
UD
)
    nat_id=$(aws ec2 run-instances --image-id "$ami" --instance-type "$NAT_INSTANCE_TYPE" \
      --subnet-id "$PUB_PRIMARY_SUBNET" --security-group-ids "$NAT_SG" \
      --associate-public-ip-address --user-data "$user_data" \
      --metadata-options "HttpTokens=required,HttpEndpoint=enabled,HttpPutResponseHopLimit=1" \
      --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":8,"VolumeType":"gp3","Encrypted":true,"DeleteOnTermination":true}}]' \
      --tag-specifications "ResourceType=instance,Tags=$(tag_spec "${PREFIX}-nat")" \
      --query 'Instances[0].InstanceId' --output text)
    aws ec2 wait instance-running --instance-ids "$nat_id"
    # Passo che si dimentica e rende la NAT inutile senza errori: disattivare il
    # source/dest check.
    aws ec2 modify-instance-attribute --instance-id "$nat_id" --no-source-dest-check
  fi
  save_state NAT_INSTANCE "$nat_id"

  # Elastic IP
  local eip_alloc
  eip_alloc=$(aws ec2 describe-addresses --filters "Name=tag:Name,Values=${PREFIX}-nat" \
    --query 'Addresses[0].AllocationId' --output text)
  if [ "$eip_alloc" = "None" ]; then
    eip_alloc=$(aws ec2 allocate-address --domain vpc \
      --tag-specifications "ResourceType=elastic-ip,Tags=$(tag_spec "${PREFIX}-nat")" \
      --query AllocationId --output text)
  fi
  aws ec2 associate-address --allocation-id "$eip_alloc" --instance-id "$NAT_INSTANCE" >/dev/null
  save_state NAT_EIP_ALLOC "$eip_alloc"
}

_private_route_table() {
  # §4.5 — route privata verso la NAT instance. La witness privata resta senza
  # egress: non deve ospitare workload.
  local rtb
  rtb=$(aws ec2 describe-route-tables \
    --filters "Name=tag:Name,Values=${PREFIX}-private-primary" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'RouteTables[0].RouteTableId' --output text)
  if [ "$rtb" = "None" ]; then
    rtb=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
      --tag-specifications "ResourceType=route-table,Tags=$(tag_spec "${PREFIX}-private-primary")" \
      --query 'RouteTable.RouteTableId' --output text)
    aws ec2 create-route --route-table-id "$rtb" \
      --destination-cidr-block 0.0.0.0/0 --instance-id "$NAT_INSTANCE"
    aws ec2 associate-route-table --route-table-id "$rtb" --subnet-id "$PRIV_PRIMARY_SUBNET"
  fi
  save_state RTB_PRIVATE "$rtb"
}

# =============================================================================
# s05_iam_eks — §5: ruoli IAM del cluster e dei nodi
# =============================================================================
s05_iam_eks() {
  _role_with_managed "${PREFIX}-eks-cluster" \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"eks.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
    arn:aws:iam::aws:policy/AmazonEKSClusterPolicy

  # Il ruolo dei nodi NON riceve AmazonEKS_CNI_Policy: il CNI usa un ruolo IRSA
  # dedicato (s06), cosi' i permessi di rete non vanno a ogni pod sul nodo.
  _role_with_managed "${PREFIX}-eks-node" \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
    arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy \
    arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly
}

_role_with_managed() { # role_name trust_json managed_arn...
  local name="$1" trust="$2"; shift 2
  aws iam get-role --role-name "$name" >/dev/null 2>&1 || \
    aws iam create-role --role-name "$name" --assume-role-policy-document "$trust" >/dev/null
  local arn
  for arn in "$@"; do
    aws iam attach-role-policy --role-name "$name" --policy-arn "$arn"
  done
  log "Ruolo $name pronto."
}

# =============================================================================
# s06_eks — §6: cluster, access entry, OIDC provider, add-on, node group
# =============================================================================
s06_eks() {
  require_vars ACCOUNT_ID PRIV_PRIMARY_SUBNET PRIV_WITNESS_SUBNET

  # Log group del control plane, solo se si e' scelto di tenerne acceso qualcuno.
  if [ -n "$EKS_LOG_TYPES" ]; then
    aws logs create-log-group --log-group-name "/aws/eks/${PREFIX}/cluster" 2>/dev/null || true
    aws logs put-retention-policy --log-group-name "/aws/eks/${PREFIX}/cluster" \
      --retention-in-days "$LOG_RETENTION_DAYS" 2>/dev/null || true
  fi

  if ! aws eks describe-cluster --name "$PREFIX" >/dev/null 2>&1; then
    local logging='{"clusterLogging":[{"types":["api","audit","authenticator"],"enabled":false}]}'
    if [ -n "$EKS_LOG_TYPES" ]; then
      local types_json
      types_json=$(printf '%s' "$EKS_LOG_TYPES" | jq -R 'split(",")')
      logging=$(jq -nc --argjson t "$types_json" '{clusterLogging:[{types:$t,enabled:true}]}')
    fi
    aws eks create-cluster --name "$PREFIX" \
      --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/${PREFIX}-eks-cluster" \
      --resources-vpc-config "subnetIds=${PRIV_PRIMARY_SUBNET},${PRIV_WITNESS_SUBNET},endpointPublicAccess=false,endpointPrivateAccess=true" \
      --access-config "authenticationMode=API,bootstrapClusterCreatorAdminPermissions=false" \
      --logging "$logging" >/dev/null
    log "Creazione cluster in corso (~10 min)..."
    aws eks wait cluster-active --name "$PREFIX"
  fi
  log "Cluster attivo."

  # §6.3 — access entry per il ruolo amministratore. Serve l'ARN del RUOLO,
  # non della sessione. Auto-rilevato per un ruolo SSO AdministratorAccess.
  local admin_arn="${EKS_ADMIN_ROLE_ARN:-}"
  if [ -z "$admin_arn" ]; then
    admin_arn=$(aws iam list-roles --path-prefix /aws-reserved/sso.amazonaws.com/ \
      --query 'Roles[?starts_with(RoleName, `AWSReservedSSO_AdministratorAccess`)].Arn | [0]' \
      --output text 2>/dev/null || echo "None")
  fi
  if [ "$admin_arn" != "None" ] && [ -n "$admin_arn" ]; then
    aws eks create-access-entry --cluster-name "$PREFIX" --principal-arn "$admin_arn" \
      --type STANDARD 2>/dev/null || true
    aws eks associate-access-policy --cluster-name "$PREFIX" --principal-arn "$admin_arn" \
      --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
      --access-scope type=cluster 2>/dev/null || true
    save_state EKS_ADMIN_ROLE_ARN "$admin_arn"
    log "Access entry per $admin_arn"
  else
    warn "Nessun ruolo admin rilevato: imposta EKS_ADMIN_ROLE_ARN e rilancia s06_eks,"
    warn "altrimenti non potrai usare kubectl (authentication_mode=API)."
  fi

  _oidc_provider
  _eks_addons
  _node_group
  log "EKS pronto."
}

_oidc_provider() {
  # §6.4 — provider OIDC per IRSA + ruoli degli add-on con condizione sul sub.
  local issuer host
  issuer=$(aws eks describe-cluster --name "$PREFIX" \
    --query 'cluster.identity.oidc.issuer' --output text)
  host="${issuer#https://}"
  save_state OIDC_ISSUER "$issuer"
  save_state OIDC_HOST "$host"

  if ! aws iam list-open-id-connect-providers \
      --query 'OpenIDConnectProviderList[].Arn' --output text | grep -q "$host"; then
    # --thumbprint-list OMESSO di proposito. Dal 2023 IAM recupera da solo il
    # thumbprint del CA dell'endpoint OIDC lato server; per gli endpoint EKS
    # (root CA Amazon) non viene comunque usato per la verifica. Cosi' si evita
    # una connessione TLS locale verso AWS via openssl, che su una rete
    # aziendale con proxy di egress fallisce ("Could not read certificate from
    # <stdin>"): i server IAM raggiungono l'endpoint anche quando la WSL no.
    if ! aws iam create-open-id-connect-provider --url "$issuer" \
        --client-id-list sts.amazonaws.com >/dev/null 2>&1; then
      # Fallback per ambienti che pretendono ancora il thumbprint e in cui la
      # connessione TLS locale funziona: calcolalo dalla catena (ultimo cert = CA).
      warn "Creazione senza thumbprint non riuscita; provo a calcolarlo via openssl."
      need openssl
      local thumb
      thumb=$(openssl s_client -servername "$host" -showcerts -connect "${host}:443" </dev/null 2>/dev/null \
        | awk '/-----BEGIN CERTIFICATE-----/{b=""} {b=b $0 "\n"} /-----END CERTIFICATE-----/{last=b} END{printf "%s", last}' \
        | openssl x509 -fingerprint -sha1 -noout 2>/dev/null \
        | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f')
      [ -n "$thumb" ] || die "Impossibile ottenere il thumbprint OIDC (rete/proxy?). Crea il provider a mano e rilancia s06_eks."
      aws iam create-open-id-connect-provider --url "$issuer" \
        --client-id-list sts.amazonaws.com --thumbprint-list "$thumb" >/dev/null
    fi
  fi
  save_state OIDC_ARN "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${host}"

  _irsa_role "${PREFIX}-vpc-cni" "kube-system" "aws-node" \
    arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
  _irsa_role "${PREFIX}-ebs-csi" "kube-system" "ebs-csi-controller-sa" \
    arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy
}

# _irsa_role role_name namespace service_account managed_arn...
# La condizione su :sub e' cio' che impedisce a qualsiasi service account di
# assumere il ruolo. Senza, IRSA e' decorativo.
_irsa_role() {
  local name="$1" ns="$2" sa="$3"; shift 3
  local trust
  trust=$(jq -nc --arg arn "$OIDC_ARN" --arg host "$OIDC_HOST" --arg sub "system:serviceaccount:${ns}:${sa}" '
    {Version:"2012-10-17",Statement:[{
      Effect:"Allow",
      Principal:{Federated:$arn},
      Action:"sts:AssumeRoleWithWebIdentity",
      Condition:{StringEquals:{($host+":aud"):"sts.amazonaws.com",($host+":sub"):$sub}}
    }]}')
  if aws iam get-role --role-name "$name" >/dev/null 2>&1; then
    aws iam update-assume-role-policy --role-name "$name" --policy-document "$trust"
  else
    aws iam create-role --role-name "$name" --assume-role-policy-document "$trust" >/dev/null
  fi
  local arn
  for arn in "$@"; do aws iam attach-role-policy --role-name "$name" --policy-arn "$arn"; done
}

_eks_addons() {
  _addon() { # addon_name [role_arn]
    local name="$1" role="${2:-}"
    aws eks describe-addon --cluster-name "$PREFIX" --addon-name "$name" >/dev/null 2>&1 && return 0
    if [ -n "$role" ]; then
      aws eks create-addon --cluster-name "$PREFIX" --addon-name "$name" \
        --service-account-role-arn "$role" --resolve-conflicts OVERWRITE >/dev/null
    else
      aws eks create-addon --cluster-name "$PREFIX" --addon-name "$name" \
        --resolve-conflicts OVERWRITE >/dev/null
    fi
  }
  _addon vpc-cni "arn:aws:iam::${ACCOUNT_ID}:role/${PREFIX}-vpc-cni"
  _addon kube-proxy
  _addon coredns
  _addon aws-ebs-csi-driver "arn:aws:iam::${ACCOUNT_ID}:role/${PREFIX}-ebs-csi"
}

_node_group() {
  # §6.5 — launch template per gp3 cifrato + IMDSv2, poi node group su UNA sola
  # subnet (la primaria): tutti i pod nella AZ primaria, per design.
  local lt_id
  lt_id=$(aws ec2 describe-launch-templates \
    --filters "Name=launch-template-name,Values=${PREFIX}-node" \
    --query 'LaunchTemplates[0].LaunchTemplateId' --output text 2>/dev/null || echo "None")
  if [ "$lt_id" = "None" ]; then
    lt_id=$(aws ec2 create-launch-template --launch-template-name "${PREFIX}-node" \
      --launch-template-data '{
        "MetadataOptions":{"HttpTokens":"required","HttpPutResponseHopLimit":2},
        "BlockDeviceMappings":[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":30,"VolumeType":"gp3","Encrypted":true,"DeleteOnTermination":true}}]
      }' --query 'LaunchTemplate.LaunchTemplateId' --output text)
  fi

  if ! aws eks describe-nodegroup --cluster-name "$PREFIX" --nodegroup-name "${PREFIX}-primary" >/dev/null 2>&1; then
    aws eks create-nodegroup --cluster-name "$PREFIX" --nodegroup-name "${PREFIX}-primary" \
      --node-role "arn:aws:iam::${ACCOUNT_ID}:role/${PREFIX}-eks-node" \
      --subnets "$PRIV_PRIMARY_SUBNET" \
      --capacity-type ON_DEMAND --instance-types "$NODE_INSTANCE_TYPE" \
      --ami-type AL2023_x86_64_STANDARD \
      --launch-template "id=${lt_id}" \
      --scaling-config minSize=1,maxSize=2,desiredSize=1 \
      --labels "reverse-dr.io/failure-domain=primary-az,reverse-dr.io/workload-tier=application" >/dev/null
    log "Creazione node group (~3 min)..."
    aws eks wait nodegroup-active --cluster-name "$PREFIX" --nodegroup-name "${PREFIX}-primary"
  fi
}

# =============================================================================
# s07_ecr — §7: cinque repository immutabili
# =============================================================================
s07_ecr() {
  local repo
  for repo in frontend bff ticket automation ticket-processor; do
    local name="${PREFIX}-${repo}"
    aws ecr describe-repositories --repository-names "$name" >/dev/null 2>&1 || \
      aws ecr create-repository --repository-name "$name" \
        --image-tag-mutability IMMUTABLE \
        --image-scanning-configuration scanOnPush=true \
        --encryption-configuration encryptionType=AES256 >/dev/null
    aws ecr put-lifecycle-policy --repository-name "$name" --lifecycle-policy-text '{
      "rules":[
        {"rulePriority":1,"description":"expire untagged after 7 days","selection":{"tagStatus":"untagged","countType":"sinceImagePushed","countUnit":"days","countNumber":7},"action":{"type":"expire"}},
        {"rulePriority":2,"description":"keep last 20","selection":{"tagStatus":"any","countType":"imageCountMoreThan","countNumber":20},"action":{"type":"expire"}}
      ]}' >/dev/null
  done
  log "ECR pronto."
}

# =============================================================================
# s08_rds — §8: PostgreSQL single-AZ, non pubblico
# =============================================================================
s08_rds() {
  require_vars VPC_ID PRIV_PRIMARY_SUBNET PRIV_WITNESS_SUBNET PRIMARY_AZ

  local sg_id
  sg_id=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${PREFIX}-postgres" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' --output text)
  if [ "$sg_id" = "None" ]; then
    sg_id=$(aws ec2 create-security-group --group-name "${PREFIX}-postgres" \
      --description "PostgreSQL ingress only from EKS workloads" \
      --vpc-id "$VPC_ID" --query GroupId --output text)
  fi
  save_state DB_SG "$sg_id"

  aws rds describe-db-subnet-groups --db-subnet-group-name "${PREFIX}-postgres" >/dev/null 2>&1 || \
    aws rds create-db-subnet-group --db-subnet-group-name "${PREFIX}-postgres" \
      --db-subnet-group-description "reverse-dr-poc postgres" \
      --subnet-ids "$PRIV_PRIMARY_SUBNET" "$PRIV_WITNESS_SUBNET" >/dev/null

  if ! aws rds describe-db-instances --db-instance-identifier "${PREFIX}-postgres" >/dev/null 2>&1; then
    # multi-az false e AZ fissata sulla primaria: il DB condivide il failure
    # domain dei workload, per design. manage-master-user-password mette la
    # password in Secrets Manager, illeggibile ai ruoli applicativi.
    aws rds create-db-instance --db-instance-identifier "${PREFIX}-postgres" \
      --engine postgres --engine-version "$DB_ENGINE_VERSION" \
      --db-instance-class "$DB_INSTANCE_CLASS" \
      --db-name "$DB_NAME" --master-username "$DB_MASTER_USER" \
      --manage-master-user-password \
      --allocated-storage 20 --max-allocated-storage 100 \
      --storage-type gp3 --storage-encrypted \
      --availability-zone "$PRIMARY_AZ" --no-multi-az --no-publicly-accessible \
      --db-subnet-group-name "${PREFIX}-postgres" --vpc-security-group-ids "$DB_SG" \
      --enable-iam-database-authentication \
      --backup-retention-period 7 --no-enable-performance-insights \
      --no-deletion-protection >/dev/null
      # Log exports RDS omessi di proposito: nessun log verso CloudWatch
      # (scelta cost-conscious, coerente con EKS_LOG_TYPES). Per abilitarli
      # aggiungere: --enable-cloudwatch-logs-exports postgresql upgrade
    log "Creazione RDS in corso (~8 min)..."
    aws rds wait db-instance-available --db-instance-identifier "${PREFIX}-postgres"
  fi
  save_state DB_HOST "$(aws rds describe-db-instances --db-instance-identifier "${PREFIX}-postgres" \
    --query 'DBInstances[0].Endpoint.Address' --output text)"
  log "RDS pronto: $DB_HOST"
}

# §8.3 — la regola di ingresso richiede il security group del cluster, quindi va
# eseguita DOPO s06_eks. Chiamata separata di proposito.
s08b_rds_ingress() {
  require_vars DB_SG
  local cluster_sg
  cluster_sg=$(aws eks describe-cluster --name "$PREFIX" \
    --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)
  aws ec2 authorize-security-group-ingress --group-id "$DB_SG" \
    --ip-permissions "IpProtocol=tcp,FromPort=5432,ToPort=5432,UserIdGroupPairs=[{GroupId=${cluster_sg}}]" \
    2>/dev/null || warn "Regola 5432 gia' presente."
  log "RDS raggiungibile dal cluster ($cluster_sg)."
}

# =============================================================================
# s09_s3 — §9: bucket backup e frontend
# =============================================================================
s09_s3() {
  require_vars ACCOUNT_ID
  save_state BACKUP_BUCKET   "${PREFIX}-backup-${ACCOUNT_ID}-${AWS_REGION}"
  save_state FRONTEND_BUCKET "${PREFIX}-frontend-${ACCOUNT_ID}-${AWS_REGION}"
  local b
  for b in "$BACKUP_BUCKET" "$FRONTEND_BUCKET"; do
    if ! aws s3api head-bucket --bucket "$b" >/dev/null 2>&1; then
      aws s3api create-bucket --bucket "$b" \
        --create-bucket-configuration "LocationConstraint=${AWS_REGION}" >/dev/null
    fi
    aws s3api put-bucket-versioning --bucket "$b" --versioning-configuration Status=Enabled
    aws s3api put-bucket-encryption --bucket "$b" \
      --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
    # In una Organization la public-access-block puo' essere gia' imposta a
    # livello account: se l'SCP nega la modifica per-bucket, i bucket nuovi sono
    # comunque gia' bloccati.
    aws s3api put-public-access-block --bucket "$b" \
      --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true \
      2>/dev/null || warn "put-public-access-block negata su $b (probabile SCP): i bucket nuovi nascono comunque bloccati."
  done
  # Lifecycle sul bucket di backup: Glacier IR a 30gg, scadenza a 365.
  aws s3api put-bucket-lifecycle-configuration --bucket "$BACKUP_BUCKET" \
    --lifecycle-configuration '{"Rules":[{"ID":"postgres-archive","Filter":{"Prefix":"postgres/"},"Status":"Enabled","Transitions":[{"Days":30,"StorageClass":"GLACIER_IR"}],"Expiration":{"Days":365}}]}'
  log "S3 pronto. Il bucket di backup e' l'artefatto che il sito DR ripristina."
}

# =============================================================================
# s10_secrets — §10: contenitori Secrets Manager (valori in s12)
# =============================================================================
s10_secrets() {
  local s
  for s in "${PREFIX}/application/database" "${PREFIX}/application/config"; do
    aws secretsmanager describe-secret --secret-id "$s" >/dev/null 2>&1 || \
      aws secretsmanager create-secret --name "$s" \
        --description "operator-managed placeholder" >/dev/null
  done
  log "Contenitori secret creati (vuoti). I valori arrivano in s12."
}

# =============================================================================
# s11_irsa — §11: quattro ruoli IRSA dei workload + ruolo ALB controller
# =============================================================================
s11_irsa() {
  require_vars ACCOUNT_ID OIDC_ARN OIDC_HOST BACKUP_BUCKET
  local db_arn cfg_arn
  db_arn="arn:aws:secretsmanager:${AWS_REGION}:${ACCOUNT_ID}:secret:${PREFIX}/application/database-*"
  cfg_arn="arn:aws:secretsmanager:${AWS_REGION}:${ACCOUNT_ID}:secret:${PREFIX}/application/config-*"

  _irsa_role "${PREFIX}-bff" "$K8S_NAMESPACE" "helios-bff"
  _put_inline "${PREFIX}-bff" application-secrets "$(jq -nc --arg db "$db_arn" --arg cfg "$cfg_arn" \
    '{Version:"2012-10-17",Statement:[{Effect:"Allow",Action:["secretsmanager:DescribeSecret","secretsmanager:GetSecretValue"],Resource:[$db,$cfg]}]}')"

  _irsa_role "${PREFIX}-ticket" "$K8S_NAMESPACE" "helios-ticket-service"
  _put_inline "${PREFIX}-ticket" database-and-events "$(jq -nc --arg db "$db_arn" --arg cfg "$cfg_arn" \
    --arg bus "arn:aws:events:${AWS_REGION}:${ACCOUNT_ID}:event-bus/${PREFIX}-application" \
    '{Version:"2012-10-17",Statement:[
      {Effect:"Allow",Action:["secretsmanager:DescribeSecret","secretsmanager:GetSecretValue"],Resource:[$db,$cfg]},
      {Effect:"Allow",Action:"events:PutEvents",Resource:$bus}]}')"

  _irsa_role "${PREFIX}-automation" "$K8S_NAMESPACE" "helios-automation-service"
  _put_inline "${PREFIX}-automation" secrets-queue-lambda "$(jq -nc --arg db "$db_arn" --arg cfg "$cfg_arn" \
    --arg q "arn:aws:sqs:${AWS_REGION}:${ACCOUNT_ID}:${PREFIX}-ticket-automation" \
    --arg fn "arn:aws:lambda:${AWS_REGION}:${ACCOUNT_ID}:function:${PREFIX}-ticket-automation" \
    '{Version:"2012-10-17",Statement:[
      {Effect:"Allow",Action:["secretsmanager:DescribeSecret","secretsmanager:GetSecretValue"],Resource:[$db,$cfg]},
      {Effect:"Allow",Action:["sqs:ReceiveMessage","sqs:DeleteMessage","sqs:GetQueueAttributes"],Resource:$q},
      {Effect:"Allow",Action:"lambda:InvokeFunction",Resource:$fn}]}')"

  _irsa_role "${PREFIX}-backup" "$K8S_NAMESPACE" "helios-postgres-backup"
  _put_inline "${PREFIX}-backup" db-and-backup-prefix "$(jq -nc --arg db "$db_arn" \
    --arg bkt "arn:aws:s3:::${BACKUP_BUCKET}" --arg obj "arn:aws:s3:::${BACKUP_BUCKET}/postgres/*" \
    '{Version:"2012-10-17",Statement:[
      {Effect:"Allow",Action:["secretsmanager:DescribeSecret","secretsmanager:GetSecretValue"],Resource:$db},
      {Effect:"Allow",Action:["s3:PutObject","s3:GetObject","s3:AbortMultipartUpload"],Resource:$obj},
      {Effect:"Allow",Action:"s3:ListBucket",Resource:$bkt,Condition:{StringLike:{"s3:prefix":"postgres/*"}}}]}')"

  # Ruolo IRSA del controller ALB (usato in s15). La policy e' quella verificata
  # v3.4.2 del repository, con ${vpc_arn} risolto.
  _irsa_role "${PREFIX}-aws-load-balancer-controller" "kube-system" "aws-load-balancer-controller"
  local vpc_arn policy_file
  vpc_arn="arn:aws:ec2:${AWS_REGION}:${ACCOUNT_ID}:vpc/${VPC_ID}"
  policy_file="${REPO_ROOT}/automazione/infra/aws/modules/eks/policies/aws-load-balancer-controller-v3.4.2.json.tftpl"
  _put_inline "${PREFIX}-aws-load-balancer-controller" alb-controller \
    "$(sed "s|\${vpc_arn}|${vpc_arn}|g" "$policy_file")"
  log "Ruoli IRSA pronti."
}

_put_inline() { # role_name policy_name policy_json
  aws iam put-role-policy --role-name "$1" --policy-name "$2" --policy-document "$3"
}

# _bff_pems_from_pfx — se e' stato fornito un .pfx (PKCS#12), estrae chiave e
# certificato in due PEM temporanei sotto $STATE_DIR (permessi 077) e reindirizza
# BFF_KEY_PEM/BFF_CERT_PEM su quelli. I PEM derivati sono marcati temporanei e
# vengono cancellati alla fine di s12. Se BFF_PFX non e' impostato, non fa nulla.
BFF_PEMS_ARE_TEMP=0
_bff_pems_from_pfx() {
  [ -n "$BFF_PFX" ] || return 0
  [ -r "$BFF_PFX" ] || die "PFX non leggibile: $BFF_PFX"
  need openssl

  local pw_file key_pem cert_pem pfx_pw
  key_pem="$STATE_DIR/bff-key.pem"
  cert_pem="$STATE_DIR/bff-cert.pem"
  pw_file="$STATE_DIR/.pfx-pass"
  ( umask 077; : > "$key_pem"; : > "$cert_pem"; : > "$pw_file" )

  # La password non passa mai in argv: la si legge in modo interattivo e la si
  # scrive in un file 077 letto da openssl con -passin file:, poi si distrugge.
  read -rsp "Password del .pfx (${BFF_PFX##*/}): " pfx_pw; echo
  printf '%s' "$pfx_pw" > "$pw_file"; unset pfx_pw

  # I due passaggi normalizzano l'output (openssl pkey / x509) rimuovendo le bag
  # attribute che load_pem_x509_certificate non gradisce. openssl 3 richiede
  # -legacy per i .pfx cifrati con algoritmi vecchi (RC2/3DES), comuni negli
  # export Windows: si prova senza, e in caso di errore si ripete con -legacy.
  _extract() { # flag_legacy (vuoto o "-legacy")
    local legacy="$1"
    openssl pkcs12 -in "$BFF_PFX" -passin "file:$pw_file" $legacy -nocerts -nodes 2>/dev/null \
      | openssl pkey -out "$key_pem" 2>/dev/null || return 1
    openssl pkcs12 -in "$BFF_PFX" -passin "file:$pw_file" $legacy -clcerts -nokeys 2>/dev/null \
      | openssl x509 -out "$cert_pem" 2>/dev/null || return 1
  }
  if ! _extract ""; then
    _extract "-legacy" || { shred -u "$pw_file"; die "Estrazione dal .pfx fallita: password errata o formato non supportato."; }
  fi
  shred -u "$pw_file"

  BFF_KEY_PEM="$key_pem"
  BFF_CERT_PEM="$cert_pem"
  BFF_PEMS_ARE_TEMP=1
  log "Chiave e certificato estratti dal .pfx."
}

# =============================================================================
# s12_bootstrap — §12: kubeconfig, utente DB applicativo, valori dei secret
# =============================================================================
s12_bootstrap() {
  require_vars DB_HOST ACCOUNT_ID
  need openssl
  _bff_pems_from_pfx
  [ -r "$BFF_KEY_PEM" ]  || die "PEM chiave BFF non leggibile: $BFF_KEY_PEM (imposta BFF_PFX o BFF_KEY_PEM, vedi §2.1)"
  [ -r "$BFF_CERT_PEM" ] || die "PEM certificato BFF non leggibile: $BFF_CERT_PEM (imposta BFF_PFX o BFF_CERT_PEM, vedi §2.1)"

  aws eks update-kubeconfig --name "$PREFIX"
  kubectl get nodes || die "kubectl non raggiunge il cluster: endpoint privato (§12.1) o access entry mancante."

  umask 077
  local master_arn master_pw app_pw master_url
  master_arn=$(aws rds describe-db-instances --db-instance-identifier "${PREFIX}-postgres" \
    --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text)
  master_pw=$(aws secretsmanager get-secret-value --secret-id "$master_arn" \
    --query SecretString --output text | jq -r .password)
  app_pw=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | cut -c1-32)
  master_url="postgresql://${DB_MASTER_USER}:$(printf '%s' "$master_pw" | jq -sRr @uri)@${DB_HOST}/${DB_NAME}?sslmode=require"

  kubectl create namespace "$K8S_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "$K8S_NAMESPACE" delete secret pg-bootstrap --ignore-not-found
  kubectl -n "$K8S_NAMESPACE" create secret generic pg-bootstrap \
    --from-literal=MASTER_URL="$master_url" --from-literal=APP_PASSWORD="$app_pw"

  # Utente applicativo ristretto: il master non va usato dai workload.
  kubectl -n "$K8S_NAMESPACE" run pg-bootstrap --rm -i --restart=Never \
    --image=postgres:16-alpine \
    --overrides='{"spec":{"containers":[{"name":"pg","image":"postgres:16-alpine","command":["sh","-c","psql \"$MASTER_URL\" -v ON_ERROR_STOP=1 -v pw=\"$APP_PASSWORD\" -f -"],"stdin":true,"envFrom":[{"secretRef":{"name":"pg-bootstrap"}}]}]}}' <<'SQL'
CREATE ROLE helios_app LOGIN PASSWORD :'pw';
GRANT CONNECT ON DATABASE helios TO helios_app;
GRANT USAGE, CREATE ON SCHEMA public TO helios_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO helios_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO helios_app;
SQL
  kubectl -n "$K8S_NAMESPACE" delete secret pg-bootstrap

  # §12.3 — valori dei due secret. La chiave privata via --rawfile per
  # preservare i newline PEM; OIDC_CLIENT_AUTH_METHOD=private_key_jwt sul primario.
  jq -n --arg url "postgresql+asyncpg://helios_app:${app_pw}@${DB_HOST}/${DB_NAME}?ssl=require" \
    '{DATABASE_URL:$url}' > /tmp/db-secret.json
  jq -n --arg key "$(openssl rand -base64 48)" \
    --rawfile pk "$BFF_KEY_PEM" --rawfile cert "$BFF_CERT_PEM" \
    '{OIDC_CLIENT_PRIVATE_KEY:$pk,OIDC_CLIENT_CERTIFICATE:$cert,SESSION_ENCRYPTION_KEY:$key}' > /tmp/config-secret.json

  aws secretsmanager put-secret-value --secret-id "${PREFIX}/application/database" --secret-string file:///tmp/db-secret.json >/dev/null
  aws secretsmanager put-secret-value --secret-id "${PREFIX}/application/config"   --secret-string file:///tmp/config-secret.json >/dev/null
  shred -u /tmp/db-secret.json /tmp/config-secret.json
  # I PEM estratti dal .pfx sono materiale confidenziale temporaneo: distruggili.
  # Quelli forniti direttamente dall'utente restano dove sono.
  [ "$BFF_PEMS_ARE_TEMP" = "1" ] && shred -u "$BFF_KEY_PEM" "$BFF_CERT_PEM" || true
  log "Utente helios_app creato e secret popolati."
}

# =============================================================================
# s13_events — §13: EventBridge bus/rule/archive e code SQS
# =============================================================================
s13_events() {
  require_vars ACCOUNT_ID
  local dlq_url q_url dlq_arn q_arn bus_arn
  dlq_url=$(aws sqs create-queue --queue-name "${PREFIX}-ticket-automation-dlq" \
    --attributes MessageRetentionPeriod=1209600 --query QueueUrl --output text)
  dlq_arn=$(aws sqs get-queue-attributes --queue-url "$dlq_url" \
    --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)
  q_url=$(aws sqs create-queue --queue-name "${PREFIX}-ticket-automation" \
    --attributes "$(jq -nc --arg dlq "$dlq_arn" \
      '{VisibilityTimeout:"180",MessageRetentionPeriod:"345600",RedrivePolicy:("{\"deadLetterTargetArn\":\""+$dlq+"\",\"maxReceiveCount\":\"5\"}")}')" \
    --query QueueUrl --output text)
  q_arn=$(aws sqs get-queue-attributes --queue-url "$q_url" \
    --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)
  save_state AUTOMATION_QUEUE_URL "$q_url"
  save_state AUTOMATION_QUEUE_ARN "$q_arn"

  aws events describe-event-bus --name "${PREFIX}-application" >/dev/null 2>&1 || \
    aws events create-event-bus --name "${PREFIX}-application" >/dev/null
  bus_arn="arn:aws:events:${AWS_REGION}:${ACCOUNT_ID}:event-bus/${PREFIX}-application"

  aws events describe-archive --archive-name "${PREFIX}-application" >/dev/null 2>&1 || \
    aws events create-archive --archive-name "${PREFIX}-application" \
      --event-source-arn "$bus_arn" --retention-days 7 >/dev/null

  # Pattern coerente con gli eventi emessi dal ticket service.
  aws events put-rule --name "${PREFIX}-ticket-automation" --event-bus-name "${PREFIX}-application" \
    --state ENABLED --event-pattern '{"source":["helios.ticket"],"detail-type":["helios.ticket.created.v1","helios.automation.requested.v1"]}' >/dev/null

  # La coda deve consentire a EventBridge di inviare messaggi.
  aws sqs set-queue-attributes --queue-url "$q_url" --attributes "$(jq -nc \
    --arg q "$q_arn" --arg rule "arn:aws:events:${AWS_REGION}:${ACCOUNT_ID}:rule/${PREFIX}-application/${PREFIX}-ticket-automation" '
    {Policy:({Version:"2012-10-17",Statement:[{Effect:"Allow",Principal:{Service:"events.amazonaws.com"},Action:"sqs:SendMessage",Resource:$q,Condition:{ArnEquals:{"aws:SourceArn":$rule}}}]}|tostring)}')"

  aws events put-targets --rule "${PREFIX}-ticket-automation" --event-bus-name "${PREFIX}-application" \
    --targets "Id=ticket-automation-queue,Arn=${q_arn}" >/dev/null
  log "EventBridge e SQS pronti."
}

# =============================================================================
# s14_images — §14: build/push 6 immagini + Lambda
# =============================================================================
s14_images() {
  require_vars REGISTRY
  cd "$REPO_ROOT"
  # Tag delle immagini. Preferenza: valore imposto via IMAGE_TAG, poi lo short
  # SHA di git, infine un timestamp. La copia di esecuzione puo' NON essere un
  # checkout git (file copiati senza .git): in quel caso `git rev-parse` fallisce
  # e senza fallback IMAGE_TAG resterebbe vuoto, producendo un tag docker rotto
  # (".../reverse-dr-poc-bff:" -> invalid reference format).
  local tag="${IMAGE_TAG:-}"
  [ -n "$tag" ] || tag="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || true)"
  [ -n "$tag" ] || tag="manual-$(date -u +%Y%m%d%H%M%S)"
  [ -n "$tag" ] || die "Impossibile determinare IMAGE_TAG."
  save_state IMAGE_TAG "$tag"
  save_state BACKUP_IMAGE_TAG "backup-${tag}"
  log "Tag immagini: $IMAGE_TAG"
  aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY"

  # §14.4 — immagine di backup: non esiste nel repo, va creata. pg_dump + psql
  # (per la metrica RPO) + AWS CLI. La scrive qui cosi' e' disponibile a _build_push.
  mkdir -p automazione/apps/backup
  cat > automazione/apps/backup/Dockerfile <<'DOCKERFILE'
FROM public.ecr.aws/docker/library/postgres:16-alpine
RUN apk add --no-cache aws-cli coreutils
USER 70:70
DOCKERFILE

  # I repository ECR sono IMMUTABLE: un tag gia' pubblicato non si sovrascrive.
  # _build_push salta build e push se il tag esiste gia', rendendo s14
  # ri-eseguibile. Se hai cambiato il codice, cambia IMAGE_TAG (tag = versione).
  local backend="automazione/apps/backend"
  _build_push "${PREFIX}-bff"        "$IMAGE_TAG"        -f "$backend/services/bff/Dockerfile" "$backend"
  _build_push "${PREFIX}-ticket"     "$IMAGE_TAG"        -f "$backend/services/ticket-service/Dockerfile" "$backend"
  _build_push "${PREFIX}-automation" "$IMAGE_TAG"        -f "$backend/services/automation-service/Dockerfile" "$backend"
  _build_push "${PREFIX}-frontend"   "$IMAGE_TAG"        automazione/apps/frontend
  _build_push "${PREFIX}-automation" "$BACKUP_IMAGE_TAG" -f automazione/apps/backup/Dockerfile automazione/apps/backup
  # ticket-processor NON usa _build_push: Lambda pretende un manifest singolo,
  # non l'image index che BuildKit produce di default (vedi _ensure_lambda_image).
  _ensure_lambda_image

  _lambda
  log "Immagini e Lambda pronte."
}

# _ensure_lambda_image — costruisce e pubblica l'immagine della function in un
# formato che AWS Lambda accetta. Il BuildKit di default aggiunge un'attestazione
# di provenance che crea un image index (manifest multiplo); Lambda lo rifiuta con
# "image manifest ... is not supported". Il builder legacy (DOCKER_BUILDKIT=0)
# produce un singolo manifest Docker v2 schema 2, accettato. Le immagini EKS non
# hanno questo vincolo, quindi il trattamento speciale resta isolato qui.
_ensure_lambda_image() {
  local repo="${PREFIX}-ticket-processor" tag="$IMAGE_TAG" mt
  if aws ecr describe-images --repository-name "$repo" --image-ids imageTag="$tag" >/dev/null 2>&1; then
    mt=$(aws ecr batch-get-image --repository-name "$repo" --image-ids imageTag="$tag" \
          --query 'images[0].imageManifestMediaType' --output text 2>/dev/null || echo "")
    if [ "$mt" = "application/vnd.docker.distribution.manifest.v2+json" ]; then
      log "Immagine Lambda ${repo}:${tag} gia' compatibile, salto."
      return 0
    fi
    # Tag immutabile ma formato non-Lambda: va cancellato per poter ripubblicare.
    warn "Immagine ${repo}:${tag} non compatibile con Lambda (${mt:-sconosciuto}): la ricreo."
    aws ecr batch-delete-image --repository-name "$repo" --image-ids imageTag="$tag" >/dev/null
  fi
  DOCKER_BUILDKIT=0 docker build -t "$REGISTRY/${repo}:${tag}" \
    -f automazione/apps/functions/ticket-processor/Dockerfile .
  docker push "$REGISTRY/${repo}:${tag}"
}

# _build_push REPO TAG [docker build args...] — costruisce e pubblica solo se il
# tag non e' gia' presente in ECR (repository immutabili).
_build_push() {
  local repo="$1" tag="$2"; shift 2
  if aws ecr describe-images --repository-name "$repo" \
       --image-ids imageTag="$tag" >/dev/null 2>&1; then
    log "ECR ${repo}:${tag} gia' presente, salto build e push."
    return 0
  fi
  docker build -t "$REGISTRY/${repo}:${tag}" "$@"
  docker push "$REGISTRY/${repo}:${tag}"
}

_lambda() {
  # §14.5 — ruolo, log group (se abilitato), function da digest, trigger SQS.
  _role_with_managed "${PREFIX}-ticket-automation-lambda" \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
    arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
  _put_inline "${PREFIX}-ticket-automation-lambda" read-secrets "$(jq -nc \
    --arg db "arn:aws:secretsmanager:${AWS_REGION}:${ACCOUNT_ID}:secret:${PREFIX}/application/database-*" \
    --arg cfg "arn:aws:secretsmanager:${AWS_REGION}:${ACCOUNT_ID}:secret:${PREFIX}/application/config-*" \
    '{Version:"2012-10-17",Statement:[{Effect:"Allow",Action:["secretsmanager:GetSecretValue"],Resource:[$db,$cfg]}]}')"

  [ -z "$EKS_LOG_TYPES" ] || aws logs create-log-group \
    --log-group-name "/aws/lambda/${PREFIX}-ticket-automation" 2>/dev/null || true

  local digest
  digest=$(aws ecr describe-images --repository-name "${PREFIX}-ticket-processor" \
    --image-ids imageTag="$IMAGE_TAG" --query 'imageDetails[0].imageDigest' --output text)
  if ! aws lambda get-function --function-name "${PREFIX}-ticket-automation" >/dev/null 2>&1; then
    # Un ruolo IAM appena creato non e' subito assumibile da Lambda: la
    # propagazione richiede alcuni secondi e create-function fallisce con "The
    # role defined for the function cannot be assumed by Lambda". Si ritenta solo
    # su quell'errore; ogni altro errore e' reale e ferma subito.
    local attempt out created=0
    for attempt in $(seq 1 12); do
      if out=$(aws lambda create-function --function-name "${PREFIX}-ticket-automation" \
          --package-type Image \
          --code "ImageUri=${REGISTRY}/${PREFIX}-ticket-processor@${digest}" \
          --role "arn:aws:iam::${ACCOUNT_ID}:role/${PREFIX}-ticket-automation-lambda" \
          --architectures x86_64 --memory-size 256 --timeout 30 2>&1); then
        created=1; break
      fi
      printf '%s' "$out" | grep -q "cannot be assumed" \
        || die "create-function fallita: $out"
      log "Ruolo IAM non ancora propagato, ritento ($attempt/12)..."
      sleep 5
    done
    [ "$created" = 1 ] || die "Ruolo Lambda non assumibile dopo ~60s."
    aws lambda wait function-active --function-name "${PREFIX}-ticket-automation"
  fi
  aws lambda put-function-concurrency --function-name "${PREFIX}-ticket-automation" \
    --reserved-concurrent-executions 2 >/dev/null || true
  aws lambda create-event-source-mapping --function-name "${PREFIX}-ticket-automation" \
    --event-source-arn "$AUTOMATION_QUEUE_ARN" --batch-size 10 \
    --maximum-batching-window-in-seconds 5 2>/dev/null || warn "Event source mapping gia' presente."
}

# =============================================================================
# s15_platform — §15: External Secrets e AWS Load Balancer Controller (helm)
# =============================================================================
s15_platform() {
  require_vars VPC_ID ACCOUNT_ID
  local k8s="${REPO_ROOT}/automazione/infra/aws/kubernetes"

  helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
  helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
  helm repo update >/dev/null

  helm upgrade --install external-secrets external-secrets/external-secrets \
    -n external-secrets --create-namespace \
    -f "${k8s}/external-secrets-values.yaml.example"
  kubectl -n external-secrets rollout status deploy/external-secrets

  local work="$STATE_DIR/render"; mkdir -p "$work"
  sed "s|REPLACE_LOAD_BALANCER_CONTROLLER_ROLE_ARN|arn:aws:iam::${ACCOUNT_ID}:role/${PREFIX}-aws-load-balancer-controller|" \
    "${k8s}/aws-load-balancer-controller-serviceaccount.yaml" > "${work}/alb-sa.yaml"
  kubectl -n kube-system apply -f "${work}/alb-sa.yaml"

  sed -e "s|REPLACE_VPC_ID|${VPC_ID}|" -e "s|^clusterName:.*|clusterName: ${PREFIX}|" \
      -e "s|^region:.*|region: ${AWS_REGION}|" \
    "${k8s}/aws-load-balancer-controller-values.yaml.example" > "${work}/alb-values.yaml"
  helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
    -n kube-system -f "${work}/alb-values.yaml"
  kubectl -n kube-system rollout status deploy/aws-load-balancer-controller
  log "Componenti di piattaforma pronti."
}

# =============================================================================
# s16_overlay — §16: rendering placeholder e apply dell'overlay applicativo
# =============================================================================
s16_overlay() {
  require_vars ACCOUNT_ID REGISTRY IMAGE_TAG BACKUP_IMAGE_TAG BACKUP_BUCKET CERT_ARN APP_HOST
  require_vars ENTRA_API_CLIENT_ID ENTRA_BFF_CLIENT_ID ENTRA_ISSUER_URL \
    ENTRA_JWKS_URL ENTRA_AUTHORIZATION_ENDPOINT ENTRA_TOKEN_ENDPOINT ENTRA_END_SESSION_ENDPOINT ENTRA_API_SCOPE
  local k8s="${REPO_ROOT}/automazione/infra/aws/kubernetes"
  local overlay="$STATE_DIR/overlay"; rm -rf "$overlay"; mkdir -p "$overlay"
  cp "$k8s"/*.yaml "$overlay/"
  rm -f "$overlay/aws-load-balancer-controller-serviceaccount.yaml"

  sed -i \
    -e "s|REPLACE_AWS_REGION|${AWS_REGION}|g" \
    -e "s|REPLACE_FRONTEND_ECR_REPOSITORY|${REGISTRY}/${PREFIX}-frontend|g" \
    -e "s|REPLACE_BFF_ECR_REPOSITORY|${REGISTRY}/${PREFIX}-bff|g" \
    -e "s|REPLACE_TICKET_ECR_REPOSITORY|${REGISTRY}/${PREFIX}-ticket|g" \
    -e "s|REPLACE_AUTOMATION_ECR_REPOSITORY|${REGISTRY}/${PREFIX}-automation|g" \
    -e "s|REPLACE_BACKUP_IMAGE_TAG|${BACKUP_IMAGE_TAG}|g" \
    -e "s|REPLACE_IMAGE_TAG|${IMAGE_TAG}|g" \
    -e "s|REPLACE_BFF_IRSA_ROLE_ARN|arn:aws:iam::${ACCOUNT_ID}:role/${PREFIX}-bff|g" \
    -e "s|REPLACE_TICKET_IRSA_ROLE_ARN|arn:aws:iam::${ACCOUNT_ID}:role/${PREFIX}-ticket|g" \
    -e "s|REPLACE_AUTOMATION_IRSA_ROLE_ARN|arn:aws:iam::${ACCOUNT_ID}:role/${PREFIX}-automation|g" \
    -e "s|REPLACE_BACKUP_IRSA_ROLE_ARN|arn:aws:iam::${ACCOUNT_ID}:role/${PREFIX}-backup|g" \
    -e "s|REPLACE_APPLICATION_DATABASE_SECRET_ARN|${PREFIX}/application/database|g" \
    -e "s|REPLACE_APPLICATION_CONFIG_SECRET_ARN|${PREFIX}/application/config|g" \
    -e "s|REPLACE_BACKUP_BUCKET_NAME|${BACKUP_BUCKET}|g" \
    -e "s|REPLACE_AUTOMATION_LAMBDA_FUNCTION_NAME|${PREFIX}-ticket-automation|g" \
    -e "s|REPLACE_ACM_CERTIFICATE_ARN|${CERT_ARN}|g" \
    -e "s|REPLACE_APP_HOSTNAME|${APP_HOST}|g" \
    -e "s|REPLACE_ENTRA_ISSUER_URL|${ENTRA_ISSUER_URL}|g" \
    -e "s|REPLACE_ENTRA_API_CLIENT_ID_GUID|${ENTRA_API_CLIENT_ID}|g" \
    -e "s|REPLACE_ENTRA_BFF_CLIENT_ID_GUID|${ENTRA_BFF_CLIENT_ID}|g" \
    -e "s|REPLACE_ENTRA_JWKS_URL|${ENTRA_JWKS_URL}|g" \
    -e "s|REPLACE_ENTRA_API_SCOPE|${ENTRA_API_SCOPE}|g" \
    -e "s|REPLACE_ENTRA_AUTHORIZATION_ENDPOINT|${ENTRA_AUTHORIZATION_ENDPOINT}|g" \
    -e "s|REPLACE_ENTRA_TOKEN_ENDPOINT|${ENTRA_TOKEN_ENDPOINT}|g" \
    -e "s|REPLACE_ENTRA_END_SESSION_ENDPOINT|${ENTRA_END_SESSION_ENDPOINT}|g" \
    "$overlay"/*.yaml

  if grep -rq "REPLACE_" "$overlay"; then
    grep -rn "REPLACE_" "$overlay"; die "Placeholder residui: non applico."
  fi
  kubectl kustomize "$overlay" > "$overlay/rendered.yaml"
  # Il render deve contenere solo ARN e riferimenti a ExternalSecret, mai segreti.
  if grep -inE "BEGIN (RSA|EC|PRIVATE)|password" "$overlay/rendered.yaml"; then
    die "Il render sembra contenere un valore segreto: il flusso e' stato aggirato."
  fi
  kubectl apply -f "$overlay/rendered.yaml"
  save_state OVERLAY_DIR "$overlay"
  log "Overlay applicato. I pod restano in CrashLoopBackOff finche' non giri s17."
}

# =============================================================================
# s17_migrations — §17: schema del database
# =============================================================================
s17_migrations() {
  # Le immagini non migrano all'avvio (scelta deliberata). apply-migrations.sh
  # ha DB_SECRET hardcoded al nome on-prem: su AWS il secret e' helios-bff-database.
  DB_SECRET=helios-bff-database bash "${REPO_ROOT}/automazione/infra/onprem/scripts/apply-migrations.sh" \
    || warn "Se lo script non accetta l'override DB_SECRET, replica il Job a mano (vedi §17)."
  kubectl -n "$K8S_NAMESPACE" rollout restart deploy/helios-bff deploy/helios-ticket-service deploy/helios-automation-service
  kubectl -n "$K8S_NAMESPACE" rollout status deploy/helios-bff
  log "Migrazioni applicate."
}

# =============================================================================
# verify — §18: DNS finale e verifica end-to-end
# =============================================================================
verify() {
  require_vars APP_HOST BACKUP_BUCKET
  log "Hostname ALB a cui puntare il record DNS di ${APP_HOST}:"
  kubectl -n "$K8S_NAMESPACE" get ingress helios-public \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'; echo

  kubectl -n "$K8S_NAMESPACE" get pods
  curl -sSf "https://${APP_HOST}/healthz" && echo " frontend OK" || warn "frontend non raggiungibile (DNS/cert?)"
  aws s3 ls "s3://${BACKUP_BUCKET}/postgres/" || warn "nessun backup ancora (il CronJob gira ogni 10')"
  curl -sS "https://${APP_HOST}/api/v1/platform/status" | jq . || true

  # §18 — verifica dell'architettura dichiarata: con provisioning manuale nulla
  # garantisce che la console corrisponda al target.
  log "Controlli architetturali:"
  aws rds describe-db-instances --db-instance-identifier "${PREFIX}-postgres" \
    --query 'DBInstances[0].[MultiAZ,AvailabilityZone,PubliclyAccessible]' --output text
  aws eks describe-nodegroup --cluster-name "$PREFIX" --nodegroup-name "${PREFIX}-primary" \
    --query 'nodegroup.subnets' --output text
  aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=${VPC_ID}" \
    --query 'NatGateways[?State==`available`]' --output text | grep -q . \
    && warn "Trovato un NAT Gateway: non dovrebbe esistere." || log "Nessun NAT Gateway: ok."
}

# =============================================================================
# teardown — §19: distruzione guidata. Richiede conferma esplicita.
# =============================================================================
teardown() {
  warn "TEARDOWN distrugge l'infrastruttura del sito primario."
  read -rp "Scrivi 'distruggi' per procedere: " ans
  [ "$ans" = "distruggi" ] || die "Annullato."

  # 1) Salva i backup: unico artefatto ripristinabile dal sito DR.
  if [ -n "${BACKUP_BUCKET:-}" ]; then
    mkdir -p "$STATE_DIR/backup-archive"
    aws s3 sync "s3://${BACKUP_BUCKET}/postgres/" "$STATE_DIR/backup-archive/" || true
  fi
  # 2) L'ALB lo elimina il controller alla rimozione dell'Ingress: senza,
  #    restano ENI orfane che bloccano la cancellazione della VPC.
  kubectl -n "$K8S_NAMESPACE" delete ingress helios-public --ignore-not-found || true
  sleep 90

  aws eks delete-nodegroup --cluster-name "$PREFIX" --nodegroup-name "${PREFIX}-primary" 2>/dev/null || true
  aws eks wait nodegroup-deleted --cluster-name "$PREFIX" --nodegroup-name "${PREFIX}-primary" 2>/dev/null || true
  aws eks delete-cluster --name "$PREFIX" 2>/dev/null || true
  aws eks wait cluster-deleted --name "$PREFIX" 2>/dev/null || true
  aws rds delete-db-instance --db-instance-identifier "${PREFIX}-postgres" \
    --skip-final-snapshot --delete-automated-backups 2>/dev/null || true
  aws lambda delete-function --function-name "${PREFIX}-ticket-automation" 2>/dev/null || true

  warn "Risorse residue da rimuovere a mano (l'ordine e i dettagli sono nel §19"
  warn "del runbook): code SQS, bus/archive EventBridge, repository ECR, bucket S3,"
  warn "secret, Elastic IP (${NAT_EIP_ALLOC:-?}), istanza NAT, ruoli IAM, OIDC"
  warn "provider, route table/subnet/IGW/VPC, log group CloudWatch, certificato ACM."
  warn "Verifica finale:"
  warn "  aws resourcegroupstaggingapi get-resources --tag-filters Key=Name,Values='${PREFIX}*'"
}

# =============================================================================
# Dispatcher
# =============================================================================
all() {
  preflight
  s03_acm
  s04_network
  s05_iam_eks
  s06_eks
  s07_ecr
  s08_rds            # crea il security group del DB
  s08b_rds_ingress   # dopo cluster E DB: unisce i due security group
  s09_s3
  s10_secrets
  s11_irsa
  s13_events
  s14_images
  s15_platform
  s12_bootstrap      # dopo update-kubeconfig e dopo i secret/ruoli
  s16_overlay
  s17_migrations
  verify
}

cmd="${1:-}"
[ -n "$cmd" ] || { grep -E '^# +\./provision\.sh' "$0" | sed 's/^# //'; exit 0; }
if declare -F "$cmd" >/dev/null; then shift; "$cmd" "$@"; else die "sezione sconosciuta: $cmd"; fi

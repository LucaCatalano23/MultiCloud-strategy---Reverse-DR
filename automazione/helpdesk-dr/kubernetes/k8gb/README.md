# K8GB overlay

Questo overlay non viene applicato dagli script base. Serve come PoC per la fase in cui installerai K8GB sui due cluster.

## Ruolo

K8GB deve decidere quale sito e pubblicabile via DNS globale. Non deve eseguire restore o playbook Ansible.

La logica operativa resta nel DR controller:

1. controlla `/health/ready` sul primario;
2. quando il primario supera la soglia di errore, esegue `scripts/failover-to-onprem.sh`;
3. il playbook ripristina il database, promuove on-prem e abilita la readiness;
4. K8GB vede on-prem ready e puo risolvere `helpdesk.azienda.lan` verso il sito DR.

## Prerequisiti

- K8GB installato su entrambi i cluster.
- `geoTag` coerenti con `cloud` e `onprem`.
- DNS autoritativo delegato a K8GB oppure provider supportato.
- Ingress class coerente con il cluster. Nel lab k3s e Traefik usano `traefik`.

## Uso

Applicare solo dopo aver installato K8GB:

```bash
kubectl apply -f kubernetes/k8gb/gslb-helpdesk.yaml
```

Nel lab locale senza delega DNS reale, gli script continuano ad aggiornare `server-dns` per simulare il comportamento del GSLB.

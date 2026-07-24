# Helpdesk DR scripts

Gli script sono organizzati per responsabilita operativa.

```text
scripts/
  common/     libreria condivisa e funzioni LXC/Kubernetes/DNS
  deploy/     deploy dello standby on-prem e del runtime lambda-dr
  backup/     backup manuale e timer del primary cloud
  restore/    restore dei dati sul sito on-prem
  failover/   promozione DR, cutback, telemetria e controller automatico
  poc/        setup della PoC, bootstrap ansible, healthcheck e teardown
```

`deploy/` non contiene piu' il deploy di un'applicazione cloud: il monolite
`helpdesk-api` e' stato rimosso e il sito primario reale e' AWS EKS
(`automazione/infra/aws`). Sono spariti `deploy-cloud-primary.sh` e
`build-helpdesk-image.sh`.

Usa sempre i percorsi canonici:

```bash
bash scripts/poc/healthcheck.sh
bash scripts/poc/ansible-run.sh failover/run-ansible-failover
```

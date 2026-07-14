# Helpdesk DR scripts

Gli script sono organizzati per responsabilita operativa.

```text
scripts/
  common/     libreria condivisa e funzioni LXC/Kubernetes/DNS
  deploy/     deploy del sito primary cloud e dello standby on-prem
  backup/     backup manuale e timer del primary cloud
  restore/    restore dei dati sul sito on-prem
  failover/   promozione DR, cutback e controller automatico
  poc/        setup della PoC, bootstrap ansible, healthcheck e teardown
```

Usa sempre i percorsi canonici:

```bash
bash scripts/poc/healthcheck.sh
bash scripts/poc/ansible-run.sh failover/run-ansible-failover
```

-- Telemetria DR verificabile mostrata dalla dashboard operativa.
--
-- Perche' una tabella e non una variabile d'ambiente: le metriche RPO/RTO
-- pubblicate in UI devono essere prodotte da chi l'evento lo ha eseguito
-- davvero (il CronJob di backup, il playbook Ansible di failover), non da un
-- valore statico deciso a mano nel ConfigMap. Il BFF e' un lettore puro.
--
-- Una riga per metrica: interessa sempre e solo l'ultimo evento riuscito, e
-- l'upsert su chiave primaria rende i writer idempotenti e senza crescita
-- illimitata. Lo storico non serve alla dashboard e resterebbe comunque
-- perso in un restore da dump.
CREATE TABLE IF NOT EXISTS dr_telemetry (
  metric varchar(64) PRIMARY KEY,
  recorded_at timestamptz NOT NULL,
  duration_seconds integer CHECK (duration_seconds IS NULL OR duration_seconds >= 0),
  detail jsonb NOT NULL DEFAULT '{}'::jsonb
);

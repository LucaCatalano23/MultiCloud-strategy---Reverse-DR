CREATE TABLE IF NOT EXISTS automation_runs (
  id uuid PRIMARY KEY,
  source_event_id uuid NOT NULL UNIQUE,
  provider varchar(80) NOT NULL,
  status varchar(16) NOT NULL CHECK (status IN ('running', 'succeeded', 'failed')),
  result jsonb NOT NULL DEFAULT '{}'::jsonb,
  error_code varchar(120),
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL
);

CREATE INDEX IF NOT EXISTS automation_runs_created_at_idx
  ON automation_runs (created_at DESC, id DESC);

CREATE TABLE IF NOT EXISTS automation_outbox (
  event_id uuid PRIMARY KEY,
  event_type varchar(160) NOT NULL,
  aggregate_type varchar(80) NOT NULL,
  aggregate_id varchar(255) NOT NULL,
  occurred_at timestamptz NOT NULL,
  payload jsonb NOT NULL,
  published_at timestamptz,
  attempts integer NOT NULL DEFAULT 0,
  last_error varchar(500)
);

CREATE INDEX IF NOT EXISTS automation_outbox_pending_idx
  ON automation_outbox (occurred_at, event_id)
  WHERE published_at IS NULL;

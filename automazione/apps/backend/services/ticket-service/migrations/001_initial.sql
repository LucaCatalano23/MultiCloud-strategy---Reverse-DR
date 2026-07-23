CREATE TABLE IF NOT EXISTS tickets (
  id uuid PRIMARY KEY,
  title varchar(160) NOT NULL,
  description varchar(4000) NOT NULL,
  priority varchar(16) NOT NULL CHECK (priority IN ('low', 'medium', 'high')),
  status varchar(32) NOT NULL CHECK (
    status IN ('open', 'in_progress', 'waiting_user', 'waiting_third_party', 'scheduled', 'closed')
  ),
  assignee varchar(255),
  service varchar(120) NOT NULL,
  environment varchar(80) NOT NULL,
  created_by varchar(255) NOT NULL,
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL
);

CREATE INDEX IF NOT EXISTS tickets_created_at_id_idx ON tickets (created_at DESC, id DESC);

CREATE TABLE IF NOT EXISTS ticket_outbox (
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

CREATE INDEX IF NOT EXISTS ticket_outbox_pending_idx
  ON ticket_outbox (occurred_at, event_id)
  WHERE published_at IS NULL;

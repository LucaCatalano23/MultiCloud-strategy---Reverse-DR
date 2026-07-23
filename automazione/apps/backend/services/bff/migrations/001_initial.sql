CREATE TABLE IF NOT EXISTS oauth_transactions (
  state_hash char(64) PRIMARY KEY,
  nonce varchar(128) NOT NULL,
  encrypted_code_verifier text NOT NULL,
  return_to varchar(2048) NOT NULL,
  expires_at timestamptz NOT NULL
);

CREATE INDEX IF NOT EXISTS oauth_transactions_expiry_idx
  ON oauth_transactions (expires_at);

CREATE TABLE IF NOT EXISTS bff_sessions (
  session_id_hash char(64) PRIMARY KEY,
  principal jsonb NOT NULL,
  encrypted_access_token text NOT NULL,
  csrf_hash char(64) NOT NULL,
  expires_at timestamptz NOT NULL
);

CREATE INDEX IF NOT EXISTS bff_sessions_expiry_idx ON bff_sessions (expires_at);

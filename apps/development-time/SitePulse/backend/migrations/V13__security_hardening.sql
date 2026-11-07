-- V13: Security hardening (report items C6, M8).

-- C6: durable idempotency for bank webhooks. A transaction id is claimed here
-- before any state changes, so a replayed delivery is ignored even after restart.
CREATE TABLE IF NOT EXISTS processed_bank_webhooks (
    transaction_id VARCHAR(100) PRIMARY KEY,
    received_at    TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- M8: invitation tokens are stored only as SHA-256 hex digests.
CREATE EXTENSION IF NOT EXISTS pgcrypto;
UPDATE invitation_tokens
SET token = encode(digest(token, 'sha256'), 'hex')
WHERE token !~ '^[0-9a-f]{64}$';

-- H3: receipt numbers come from a per-site counter row, incremented inside the
-- payment transaction (row lock), instead of MAX(sequence_number)+1.
CREATE TABLE IF NOT EXISTS receipt_counters (
    site_id       BIGINT PRIMARY KEY REFERENCES sites(id) ON DELETE RESTRICT,
    last_sequence BIGINT NOT NULL CHECK (last_sequence >= 0)
);
INSERT INTO receipt_counters (site_id, last_sequence)
SELECT site_id, MAX(sequence_number) FROM payment_receipts GROUP BY site_id
ON CONFLICT (site_id) DO UPDATE SET last_sequence = GREATEST(receipt_counters.last_sequence, EXCLUDED.last_sequence);

-- H9: client-supplied idempotency keys; a retried payment returns the first receipt.
CREATE TABLE IF NOT EXISTS payment_idempotency_keys (
    site_id         BIGINT NOT NULL REFERENCES sites(id) ON DELETE RESTRICT,
    idempotency_key VARCHAR(100) NOT NULL,
    receipt_id      BIGINT NOT NULL REFERENCES payment_receipts(id) ON DELETE RESTRICT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (site_id, idempotency_key)
);

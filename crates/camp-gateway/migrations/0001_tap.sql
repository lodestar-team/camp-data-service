-- TAP receipt and RAV storage for camp-gateway.
--
-- tap_receipts: one row per signed EIP-712 receipt received from a consumer.
--   Unique index on (signer_address, nonce) prevents replay attacks.
--
-- tap_ravs: one row per receipt-aggregate-voucher per payer.
--   Upserted on each aggregation cycle. redeemed=true after on-chain collect().

CREATE TABLE IF NOT EXISTS tap_receipts (
    id             BIGSERIAL PRIMARY KEY,
    signer_address TEXT   NOT NULL,
    payer_address  TEXT   NOT NULL,
    timestamp_ns   BIGINT NOT NULL,
    nonce          BIGINT NOT NULL,
    value          TEXT   NOT NULL,  -- u128 as decimal string
    signature      TEXT   NOT NULL,
    metadata       BYTEA  NOT NULL DEFAULT ''
);

CREATE INDEX  IF NOT EXISTS tap_receipts_payer_idx ON tap_receipts (payer_address);
CREATE INDEX  IF NOT EXISTS tap_receipts_ts_idx    ON tap_receipts (timestamp_ns);
-- Prevent replay: each (signer, nonce) pair is used exactly once.
CREATE UNIQUE INDEX IF NOT EXISTS tap_receipts_nonce_idx
    ON tap_receipts (signer_address, nonce);

CREATE TABLE IF NOT EXISTS tap_ravs (
    collection_id    TEXT    PRIMARY KEY,
    payer_address    TEXT    NOT NULL,
    service_provider TEXT    NOT NULL,
    data_service     TEXT    NOT NULL,
    timestamp_ns     BIGINT  NOT NULL,
    value_aggregate  TEXT    NOT NULL, -- u128 as decimal string
    signature        TEXT    NOT NULL,
    last_updated     BIGINT  NOT NULL,
    redeemed         BOOLEAN NOT NULL DEFAULT false
);

-- =============================================================================
-- V5__claims.sql
-- Accident / Hospital / Critical-Illness claims (SHARDED), RANGE-partitioned by
-- incurred_date so claim history reads stay fast and prune old partitions.
-- =============================================================================

CREATE TABLE claim (
    claim_id         UUID          NOT NULL DEFAULT gen_random_uuid(),
    policy_id        UUID          NOT NULL,
    policy_bound_at  TIMESTAMPTZ   NOT NULL,
    claim_type       VARCHAR(16)   NOT NULL
                     CHECK (claim_type IN ('ACCIDENT','HOSPITAL','CRITICAL_ILLNESS','AD_D')),
    incurred_date    DATE          NOT NULL,
    reported_date    DATE          NOT NULL DEFAULT CURRENT_DATE,
    amount           NUMERIC(14,2) NOT NULL DEFAULT 0,
    status           VARCHAR(16)   NOT NULL DEFAULT 'OPEN'
                     CHECK (status IN ('OPEN','IN_REVIEW','APPROVED','DENIED','PAID')),
    created_at       TIMESTAMPTZ   NOT NULL DEFAULT now(),
    PRIMARY KEY (claim_id, incurred_date),
    FOREIGN KEY (policy_id, policy_bound_at)
        REFERENCES policy(policy_id, bound_at)
) PARTITION BY RANGE (incurred_date);

CREATE TABLE claim_2026 PARTITION OF claim
    FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');
CREATE TABLE claim_2027 PARTITION OF claim
    FOR VALUES FROM ('2027-01-01') TO ('2028-01-01');
CREATE TABLE claim_default PARTITION OF claim DEFAULT;

CREATE INDEX ix_claim_policy ON claim(policy_id);
CREATE INDEX ix_claim_status ON claim(status);

-- =============================================================================
-- V3__quotes.sql
-- Persisted quote snapshots (SHARDED by Employer_Group_ID).
-- NOTE: the *in-progress* wizard state lives in Redis (session:{quoteId}, TTL 30m).
-- This table is the durable snapshot written when a quote is priced or bound.
-- =============================================================================

CREATE TABLE quote (
    quote_id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    employer_group_id      BIGINT      NOT NULL REFERENCES employer_group(employer_group_id),
    member_id              UUID        NOT NULL REFERENCES census_member(member_id),
    status                 VARCHAR(16) NOT NULL DEFAULT 'PRICED'
                            CHECK (status IN ('IN_PROGRESS','PRICED','BOUND','EXPIRED')),
    total_monthly_premium  NUMERIC(12,2) NOT NULL DEFAULT 0,
    wizard_step            SMALLINT    NOT NULL DEFAULT 5,   -- last completed step 1..5
    created_by             VARCHAR(64) NOT NULL,             -- Entra object id
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at             TIMESTAMPTZ
);
CREATE INDEX ix_quote_group_status ON quote(employer_group_id, status);
CREATE INDEX ix_quote_member       ON quote(member_id);

-- One row per selected plan / rider on the quote.
CREATE TABLE quote_coverage (
    quote_coverage_id  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    quote_id           UUID        NOT NULL REFERENCES quote(quote_id) ON DELETE CASCADE,
    plan_code          VARCHAR(32) NOT NULL,                 -- references plan on reference DB
    covered_tier       VARCHAR(16) NOT NULL DEFAULT 'SELF'
                        CHECK (covered_tier IN ('SELF','SPOUSE','CHILD','FAMILY')),
    monthly_premium    NUMERIC(10,2) NOT NULL,
    rate_id            BIGINT                                -- rate_table row used (audit)
);
CREATE INDEX ix_quote_cov_quote ON quote_coverage(quote_id);

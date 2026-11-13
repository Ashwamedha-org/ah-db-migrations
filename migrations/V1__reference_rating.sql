-- =============================================================================
-- V1__reference_rating.sql
-- Reference / rating data for the A&H platform.
-- These tables are IDENTICAL on every shard (and heavily cached in Redis).
-- They are immutable-ish: actuarial rate tables + plan benefit matrices +
-- state regulatory rules. Quote calculation reads ONLY from here (cache-first).
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid()

-- ---------------------------------------------------------------------------
-- Plans: the A&H products the user selects in the enrollment wizard.
--   product : ADD (Accidental Death & Dismemberment)
--             CI  (Critical Illness rider)
--             HI  (Hospital Indemnity)
-- ---------------------------------------------------------------------------
CREATE TABLE plan (
    plan_code     VARCHAR(32)  PRIMARY KEY,          -- e.g. 'AH-ADD-GOLD'
    product       VARCHAR(8)   NOT NULL CHECK (product IN ('ADD','CI','HI')),
    tier          VARCHAR(16)  NOT NULL CHECK (tier IN ('BRONZE','SILVER','GOLD','PLATINUM')),
    display_name  TEXT         NOT NULL,
    is_rider      BOOLEAN      NOT NULL DEFAULT FALSE,
    active        BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- Benefit matrix per plan (principal sums, daily hospital benefit, etc.)
CREATE TABLE plan_benefit (
    benefit_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    plan_code     VARCHAR(32)  NOT NULL REFERENCES plan(plan_code),
    benefit_type  VARCHAR(48)  NOT NULL,             -- e.g. 'ADD_PRINCIPAL_SUM'
    benefit_value NUMERIC(14,2) NOT NULL,
    unit          VARCHAR(16)  NOT NULL DEFAULT 'USD'
);
CREATE INDEX ix_plan_benefit_plan ON plan_benefit(plan_code);

-- ---------------------------------------------------------------------------
-- Age-banded, state-specific rate tables. THE hot read path for quoting.
-- Lookup key cached in Redis as: cache:rates:state:{ST}:plan:{plan_code}
-- ---------------------------------------------------------------------------
CREATE TABLE rate_table (
    rate_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    plan_code      VARCHAR(32) NOT NULL REFERENCES plan(plan_code),
    state_code     CHAR(2)     NOT NULL,
    age_band_low   SMALLINT    NOT NULL,
    age_band_high  SMALLINT    NOT NULL,
    monthly_rate   NUMERIC(10,4) NOT NULL,
    effective_date DATE        NOT NULL,
    expiry_date    DATE,
    CHECK (age_band_low <= age_band_high),
    CONSTRAINT uq_rate UNIQUE (plan_code, state_code, age_band_low, age_band_high, effective_date)
);

-- Covering index for the sub-15ms actuarial lookup
CREATE INDEX ix_rate_lookup
    ON rate_table (state_code, plan_code, age_band_low, age_band_high)
    INCLUDE (monthly_rate, effective_date, expiry_date);

-- ---------------------------------------------------------------------------
-- State regulatory rules (min age, dependent eligibility, required riders...).
-- Stored as JSONB so rule shapes can evolve without schema churn.
-- ---------------------------------------------------------------------------
CREATE TABLE state_regulatory_rule (
    rule_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    state_code     CHAR(2)     NOT NULL,
    rule_key       VARCHAR(64) NOT NULL,
    rule_value     JSONB       NOT NULL,
    effective_date DATE        NOT NULL DEFAULT CURRENT_DATE,
    CONSTRAINT uq_state_rule UNIQUE (state_code, rule_key, effective_date)
);
CREATE INDEX ix_state_rule ON state_regulatory_rule(state_code, rule_key);

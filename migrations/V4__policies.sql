-- =============================================================================
-- V4__policies.sql
-- Bound policies + coverages + dependents + beneficiaries (SHARDED).
-- `policy` is RANGE-partitioned by bound_at so Open-Enrollment write bursts land
-- in the current partition (less index bloat / lock contention per partition).
-- Child tables carry the partition key (policy_bound_at) to allow composite FKs.
-- =============================================================================

CREATE TABLE policy (
    policy_id              UUID          NOT NULL DEFAULT gen_random_uuid(),
    policy_number          VARCHAR(32)   NOT NULL,
    employer_group_id      BIGINT        NOT NULL REFERENCES employer_group(employer_group_id),
    member_id              UUID          NOT NULL REFERENCES census_member(member_id),
    quote_id               UUID,
    status                 VARCHAR(16)   NOT NULL DEFAULT 'PENDING'
                            CHECK (status IN ('PENDING','ACTIVE','LAPSED','CANCELLED')),
    effective_date         DATE          NOT NULL,
    total_monthly_premium  NUMERIC(12,2) NOT NULL DEFAULT 0,
    bound_at               TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by             VARCHAR(64)   NOT NULL,
    PRIMARY KEY (policy_id, bound_at),
    CONSTRAINT uq_policy_number UNIQUE (policy_number, bound_at)
) PARTITION BY RANGE (bound_at);

-- Concrete partitions (extend ahead of each Open-Enrollment window) + safety default.
CREATE TABLE policy_2026_q4 PARTITION OF policy
    FOR VALUES FROM ('2026-10-01') TO ('2027-01-01');
CREATE TABLE policy_2027_q1 PARTITION OF policy
    FOR VALUES FROM ('2027-01-01') TO ('2027-04-01');
CREATE TABLE policy_default  PARTITION OF policy DEFAULT;

CREATE INDEX ix_policy_group   ON policy(employer_group_id, status);
CREATE INDEX ix_policy_member  ON policy(member_id);

-- One row per covered plan / rider on the bound policy.
CREATE TABLE policy_coverage (
    coverage_id      UUID          NOT NULL DEFAULT gen_random_uuid(),
    policy_id        UUID          NOT NULL,
    policy_bound_at  TIMESTAMPTZ   NOT NULL,
    plan_code        VARCHAR(32)   NOT NULL,
    covered_tier     VARCHAR(16)   NOT NULL DEFAULT 'SELF'
                     CHECK (covered_tier IN ('SELF','SPOUSE','CHILD','FAMILY')),
    monthly_premium  NUMERIC(10,2) NOT NULL,
    principal_sum    NUMERIC(14,2),
    PRIMARY KEY (coverage_id),
    FOREIGN KEY (policy_id, policy_bound_at)
        REFERENCES policy(policy_id, bound_at) ON DELETE CASCADE
);
CREATE INDEX ix_policy_cov ON policy_coverage(policy_id);

-- Covered dependents (spouse / children).
CREATE TABLE dependent (
    dependent_id     UUID        NOT NULL DEFAULT gen_random_uuid(),
    policy_id        UUID        NOT NULL,
    policy_bound_at  TIMESTAMPTZ NOT NULL,
    relationship     VARCHAR(12) NOT NULL CHECK (relationship IN ('SPOUSE','CHILD')),
    first_name       TEXT        NOT NULL,
    last_name        TEXT        NOT NULL,
    dob              DATE        NOT NULL,
    PRIMARY KEY (dependent_id),
    FOREIGN KEY (policy_id, policy_bound_at)
        REFERENCES policy(policy_id, bound_at) ON DELETE CASCADE
);
CREATE INDEX ix_dependent_policy ON dependent(policy_id);

-- Beneficiaries for AD&D payouts (percentages should sum to 100 per policy).
CREATE TABLE beneficiary (
    beneficiary_id   UUID         NOT NULL DEFAULT gen_random_uuid(),
    policy_id        UUID         NOT NULL,
    policy_bound_at  TIMESTAMPTZ  NOT NULL,
    full_name        TEXT         NOT NULL,
    relationship     VARCHAR(24)  NOT NULL,
    percentage       NUMERIC(5,2) NOT NULL CHECK (percentage > 0 AND percentage <= 100),
    PRIMARY KEY (beneficiary_id),
    FOREIGN KEY (policy_id, policy_bound_at)
        REFERENCES policy(policy_id, bound_at) ON DELETE CASCADE
);
CREATE INDEX ix_beneficiary_policy ON beneficiary(policy_id);

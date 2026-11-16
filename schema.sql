-- =============================================================================
-- schema.sql  —  GOD SCHEMA (full current state of the A&H platform database)
-- -----------------------------------------------------------------------------
-- This single file represents the ENTIRE database as it stands today and is the
-- easy one-command bootstrap for a fresh LOCAL database.
--
--   Going forward:
--     * Every schema change is reflected HERE (this file always = current state)
--     * AND captured as a new migrations/V#__*.sql script (the change history)
--
-- Apply locally:
--   docker run -d --name ah-local-db -e POSTGRES_PASSWORD=pw -e POSTGRES_DB=ah \
--       -p 5432:5432 postgres:16
--   PGPASSWORD=pw psql -h localhost -p 5432 -U postgres -d ah -f schema.sql
--
-- Sections:
--   1. Extensions
--   2. Reference / rating data        (replicated to every shard, Redis-cached)
--   3. Core: shard directory, groups, members
--   4. Quotes
--   5. Policies (partitioned) + coverage/dependents/beneficiaries
--   6. Claims (partitioned)
--   7. User Management (platform/directory DB)
--   8. Read-optimized views (replica path)
--   9. Seed data (plans, rates, state rules, UM roles & permissions)
-- =============================================================================


-- =============================================================================
-- 1. EXTENSIONS
-- =============================================================================
CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid()


-- =============================================================================
-- 2. REFERENCE / RATING DATA
--    Identical on every shard. Quote calculation reads ONLY from here (cache-first).
-- =============================================================================

CREATE TABLE plan (
    plan_code     VARCHAR(32)  PRIMARY KEY,          -- e.g. 'AH-ADD-GOLD'
    product       VARCHAR(8)   NOT NULL CHECK (product IN ('ADD','CI','HI')),
    tier          VARCHAR(16)  NOT NULL CHECK (tier IN ('BRONZE','SILVER','GOLD','PLATINUM')),
    display_name  TEXT         NOT NULL,
    is_rider      BOOLEAN      NOT NULL DEFAULT FALSE,
    active        BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE plan_benefit (
    benefit_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    plan_code     VARCHAR(32)  NOT NULL REFERENCES plan(plan_code),
    benefit_type  VARCHAR(48)  NOT NULL,             -- e.g. 'ADD_PRINCIPAL_SUM'
    benefit_value NUMERIC(14,2) NOT NULL,
    unit          VARCHAR(16)  NOT NULL DEFAULT 'USD'
);
CREATE INDEX ix_plan_benefit_plan ON plan_benefit(plan_code);

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

CREATE TABLE state_regulatory_rule (
    rule_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    state_code     CHAR(2)     NOT NULL,
    rule_key       VARCHAR(64) NOT NULL,
    rule_value     JSONB       NOT NULL,
    effective_date DATE        NOT NULL DEFAULT CURRENT_DATE,
    CONSTRAINT uq_state_rule UNIQUE (state_code, rule_key, effective_date)
);
CREATE INDEX ix_state_rule ON state_regulatory_rule(state_code, rule_key);


-- =============================================================================
-- 3. CORE: SHARD DIRECTORY, EMPLOYER GROUPS, CENSUS MEMBERS
--    Sharded by Employer_Group_ID (shard_no 1 = NE/East, 2 = MW/South).
-- =============================================================================

CREATE TABLE shard_map (
    employer_group_id  BIGINT      PRIMARY KEY,
    shard_no           SMALLINT    NOT NULL CHECK (shard_no > 0),
    region             VARCHAR(16) NOT NULL,
    assigned_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_shard_map_shard ON shard_map(shard_no);

CREATE TABLE employer_group (
    employer_group_id  BIGINT      PRIMARY KEY,
    legal_name         TEXT        NOT NULL,
    state_code         CHAR(2)     NOT NULL,
    region             VARCHAR(16) NOT NULL,
    sic_code           VARCHAR(8),
    shard_no           SMALLINT    NOT NULL,
    employee_count     INTEGER     NOT NULL DEFAULT 0,
    status             VARCHAR(16) NOT NULL DEFAULT 'ACTIVE'
                        CHECK (status IN ('ACTIVE','PROSPECT','TERMINATED')),
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_employer_state ON employer_group(state_code);

CREATE TABLE census_member (
    member_id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    employer_group_id  BIGINT      NOT NULL REFERENCES employer_group(employer_group_id),
    external_ref       VARCHAR(64),
    first_name         TEXT        NOT NULL,
    last_name          TEXT        NOT NULL,
    dob                DATE        NOT NULL,
    gender             CHAR(1)     CHECK (gender IN ('M','F','X')),
    zip                VARCHAR(10) NOT NULL,
    state_code         CHAR(2)     NOT NULL,
    email              TEXT,
    hire_date          DATE,
    status             VARCHAR(16) NOT NULL DEFAULT 'ELIGIBLE'
                        CHECK (status IN ('ELIGIBLE','ENROLLED','WAIVED','TERMINATED')),
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_member_ext UNIQUE (employer_group_id, external_ref)
);
CREATE INDEX ix_member_group ON census_member(employer_group_id);
CREATE INDEX ix_member_name  ON census_member(employer_group_id, last_name, first_name);


-- =============================================================================
-- 4. QUOTES
--    Durable snapshot; the in-progress wizard state lives in Redis (TTL 30m).
-- =============================================================================

CREATE TABLE quote (
    quote_id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    employer_group_id      BIGINT      NOT NULL REFERENCES employer_group(employer_group_id),
    member_id              UUID        NOT NULL REFERENCES census_member(member_id),
    status                 VARCHAR(16) NOT NULL DEFAULT 'PRICED'
                            CHECK (status IN ('IN_PROGRESS','PRICED','BOUND','EXPIRED')),
    total_monthly_premium  NUMERIC(12,2) NOT NULL DEFAULT 0,
    wizard_step            SMALLINT    NOT NULL DEFAULT 5,
    created_by             VARCHAR(64) NOT NULL,
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at             TIMESTAMPTZ
);
CREATE INDEX ix_quote_group_status ON quote(employer_group_id, status);
CREATE INDEX ix_quote_member       ON quote(member_id);

CREATE TABLE quote_coverage (
    quote_coverage_id  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    quote_id           UUID        NOT NULL REFERENCES quote(quote_id) ON DELETE CASCADE,
    plan_code          VARCHAR(32) NOT NULL,
    covered_tier       VARCHAR(16) NOT NULL DEFAULT 'SELF'
                        CHECK (covered_tier IN ('SELF','SPOUSE','CHILD','FAMILY')),
    monthly_premium    NUMERIC(10,2) NOT NULL,
    rate_id            BIGINT
);
CREATE INDEX ix_quote_cov_quote ON quote_coverage(quote_id);


-- =============================================================================
-- 5. POLICIES  (RANGE-partitioned by bound_at)
--    Child tables carry the partition key (policy_bound_at) for composite FKs.
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

CREATE TABLE policy_2026_q4 PARTITION OF policy
    FOR VALUES FROM ('2026-10-01') TO ('2027-01-01');
CREATE TABLE policy_2027_q1 PARTITION OF policy
    FOR VALUES FROM ('2027-01-01') TO ('2027-04-01');
CREATE TABLE policy_default PARTITION OF policy DEFAULT;

CREATE INDEX ix_policy_group  ON policy(employer_group_id, status);
CREATE INDEX ix_policy_member ON policy(member_id);

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


-- =============================================================================
-- 6. CLAIMS  (RANGE-partitioned by incurred_date)
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


-- =============================================================================
-- 7. USER MANAGEMENT  (platform/directory DB — NOT sharded)
--    Entra ID groups are the source of truth for roles; these tables hold the
--    app-side profile, a projection of group->role, a permission matrix, audit.
-- =============================================================================

CREATE TABLE um_user (
    user_id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    entra_oid          VARCHAR(64) NOT NULL UNIQUE,
    email              TEXT        NOT NULL,
    display_name       TEXT,
    employer_group_id  BIGINT,
    status             VARCHAR(16) NOT NULL DEFAULT 'ACTIVE'
                        CHECK (status IN ('ACTIVE','DISABLED','INVITED')),
    last_login_at      TIMESTAMPTZ,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_um_user_email    ON um_user(email);
CREATE INDEX ix_um_user_employer ON um_user(employer_group_id);

CREATE TABLE um_role (
    role_id                 SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    role_key                VARCHAR(32) NOT NULL UNIQUE,     -- USER, ADMIN, UNDERWRITER, BROKER
    description             TEXT,
    entra_group_object_id   VARCHAR(64) UNIQUE               -- Entra security-group object id
);

CREATE TABLE um_permission (
    permission_id   SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    permission_key  VARCHAR(48) NOT NULL UNIQUE,
    description     TEXT
);

CREATE TABLE um_role_permission (
    role_id        SMALLINT NOT NULL REFERENCES um_role(role_id) ON DELETE CASCADE,
    permission_id  SMALLINT NOT NULL REFERENCES um_permission(permission_id) ON DELETE CASCADE,
    PRIMARY KEY (role_id, permission_id)
);

CREATE TABLE um_user_role (
    user_id      UUID        NOT NULL REFERENCES um_user(user_id) ON DELETE CASCADE,
    role_id      SMALLINT    NOT NULL REFERENCES um_role(role_id),
    source       VARCHAR(16) NOT NULL DEFAULT 'ENTRA_SYNC'
                 CHECK (source IN ('ENTRA_SYNC','MANUAL')),
    assigned_by  VARCHAR(64) NOT NULL,
    assigned_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, role_id)
);

CREATE TABLE um_role_audit (
    audit_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    target_user  UUID        NOT NULL REFERENCES um_user(user_id),
    old_role     VARCHAR(32),
    new_role     VARCHAR(32),
    action       VARCHAR(16) NOT NULL CHECK (action IN ('GRANT','REVOKE','SYNC')),
    changed_by   VARCHAR(64) NOT NULL,
    source       VARCHAR(16) NOT NULL DEFAULT 'MANUAL',
    changed_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_um_role_audit_user ON um_role_audit(target_user, changed_at DESC);

CREATE TABLE um_login_audit (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id     UUID        REFERENCES um_user(user_id),
    event       VARCHAR(16) NOT NULL CHECK (event IN ('LOGIN','LOGOUT','DENIED')),
    ip_address  INET,
    user_agent  TEXT,
    at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_um_login_audit_user ON um_login_audit(user_id, at DESC);


-- =============================================================================
-- 8. READ-OPTIMIZED VIEWS  (served from replicas)
-- =============================================================================

CREATE VIEW vw_policy_history AS
SELECT  p.policy_id,
        p.policy_number,
        p.employer_group_id,
        p.member_id,
        p.status,
        p.effective_date,
        p.bound_at,
        p.total_monthly_premium,
        count(pc.coverage_id) AS coverage_count
FROM    policy p
LEFT JOIN policy_coverage pc ON pc.policy_id = p.policy_id
GROUP BY p.policy_id, p.policy_number, p.employer_group_id, p.member_id,
         p.status, p.effective_date, p.bound_at, p.total_monthly_premium;

CREATE VIEW vw_group_enrollment AS
SELECT  eg.employer_group_id,
        eg.legal_name,
        eg.state_code,
        eg.employee_count,
        count(DISTINCT p.policy_id) FILTER (WHERE p.status = 'ACTIVE') AS active_policies,
        coalesce(sum(p.total_monthly_premium) FILTER (WHERE p.status = 'ACTIVE'), 0) AS monthly_premium
FROM    employer_group eg
LEFT JOIN policy p ON p.employer_group_id = eg.employer_group_id
GROUP BY eg.employer_group_id, eg.legal_name, eg.state_code, eg.employee_count;

CREATE VIEW vw_user_effective_permissions AS
SELECT  u.user_id,
        u.entra_oid,
        u.email,
        r.role_key,
        perm.permission_key
FROM    um_user u
JOIN    um_user_role ur       ON ur.user_id = u.user_id
JOIN    um_role r             ON r.role_id = ur.role_id
JOIN    um_role_permission rp ON rp.role_id = r.role_id
JOIN    um_permission perm    ON perm.permission_id = rp.permission_id
WHERE   u.status = 'ACTIVE';


-- =============================================================================
-- 9. SEED DATA  (idempotent — safe to re-run)
-- =============================================================================

INSERT INTO plan (plan_code, product, tier, display_name, is_rider) VALUES
    ('AH-ADD-SILVER', 'ADD', 'SILVER', 'Accidental Death & Dismemberment — Silver', FALSE),
    ('AH-ADD-GOLD',   'ADD', 'GOLD',   'Accidental Death & Dismemberment — Gold',   FALSE),
    ('AH-CI-SILVER',  'CI',  'SILVER', 'Critical Illness Rider — Silver',            TRUE),
    ('AH-CI-GOLD',    'CI',  'GOLD',   'Critical Illness Rider — Gold',              TRUE),
    ('AH-HI-GOLD',    'HI',  'GOLD',   'Hospital Indemnity — Gold',                  FALSE)
ON CONFLICT (plan_code) DO UPDATE
    SET display_name = EXCLUDED.display_name, tier = EXCLUDED.tier;

INSERT INTO rate_table (plan_code, state_code, age_band_low, age_band_high, monthly_rate, effective_date) VALUES
    ('AH-ADD-GOLD', 'NJ', 18, 29, 4.2500, DATE '2026-01-01'),
    ('AH-ADD-GOLD', 'NJ', 30, 44, 6.1000, DATE '2026-01-01'),
    ('AH-ADD-GOLD', 'NJ', 45, 64, 9.8000, DATE '2026-01-01'),
    ('AH-ADD-GOLD', 'TX', 18, 29, 3.9500, DATE '2026-01-01'),
    ('AH-ADD-GOLD', 'TX', 30, 44, 5.7500, DATE '2026-01-01'),
    ('AH-ADD-GOLD', 'TX', 45, 64, 9.1000, DATE '2026-01-01')
ON CONFLICT ON CONSTRAINT uq_rate DO UPDATE SET monthly_rate = EXCLUDED.monthly_rate;

INSERT INTO state_regulatory_rule (state_code, rule_key, rule_value) VALUES
    ('NJ', 'MIN_ENROLL_AGE',   '{"age": 18}'),
    ('NJ', 'CHILD_MAX_AGE',    '{"age": 26}'),
    ('TX', 'MIN_ENROLL_AGE',   '{"age": 18}'),
    ('TX', 'HI_REQUIRES_RIDER','{"required": false}')
ON CONFLICT (state_code, rule_key, effective_date) DO NOTHING;

INSERT INTO um_role (role_key, description, entra_group_object_id) VALUES
    ('USER',        'Self-service employee / broker access',  '00000000-0000-0000-0000-00000000user'),
    ('ADMIN',       'Full User Management + platform admin',  '00000000-0000-0000-0000-0000000admin'),
    ('UNDERWRITER', 'Read policies/claims, run reports',      NULL),
    ('BROKER',      'Manage own employer groups & quotes',    NULL)
ON CONFLICT (role_key) DO UPDATE SET description = EXCLUDED.description;

INSERT INTO um_permission (permission_key, description) VALUES
    ('um.user.read',    'View users'),
    ('um.user.manage',  'Create/disable users, assign roles'),
    ('quote.create',    'Create & price quotes'),
    ('policy.bind',     'Bind new policies'),
    ('policy.read',     'View policy history'),
    ('claim.read',      'View claim status'),
    ('report.view',     'View dashboards & reports')
ON CONFLICT (permission_key) DO NOTHING;

-- USER: self-service
INSERT INTO um_role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id FROM um_role r, um_permission p
WHERE  r.role_key = 'USER' AND p.permission_key IN ('quote.create','policy.read','claim.read')
ON CONFLICT DO NOTHING;

-- ADMIN: everything
INSERT INTO um_role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id FROM um_role r, um_permission p
WHERE  r.role_key = 'ADMIN'
ON CONFLICT DO NOTHING;

-- UNDERWRITER: read-heavy
INSERT INTO um_role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id FROM um_role r, um_permission p
WHERE  r.role_key = 'UNDERWRITER' AND p.permission_key IN ('policy.read','claim.read','report.view')
ON CONFLICT DO NOTHING;

-- BROKER: quoting + binding
INSERT INTO um_role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id FROM um_role r, um_permission p
WHERE  r.role_key = 'BROKER' AND p.permission_key IN ('quote.create','policy.bind','policy.read','report.view')
ON CONFLICT DO NOTHING;

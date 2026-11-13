-- =============================================================================
-- V2__core_groups_members.sql
-- Core transactional entities, SHARDED by Employer_Group_ID.
-- The ah-policy-data-service resolves the shard; every shard runs this schema.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Shard directory. Lives in the central "directory" database so the app can
-- resolve which physical shard owns a given employer group. Each shard also
-- keeps employer_group.shard_no denormalized for safety.
--   shard_no 1 = Northeast / East
--   shard_no 2 = Midwest / South
-- ---------------------------------------------------------------------------
CREATE TABLE shard_map (
    employer_group_id  BIGINT      PRIMARY KEY,
    shard_no           SMALLINT    NOT NULL CHECK (shard_no > 0),
    region             VARCHAR(16) NOT NULL,
    assigned_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_shard_map_shard ON shard_map(shard_no);

-- ---------------------------------------------------------------------------
-- Employer group (the broker's corporate client). Shard key source.
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- Census member (an employee on an employer's uploaded census file).
-- High write volume during Open Enrollment (50k+ members per upload).
-- ---------------------------------------------------------------------------
CREATE TABLE census_member (
    member_id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    employer_group_id  BIGINT      NOT NULL REFERENCES employer_group(employer_group_id),
    external_ref       VARCHAR(64),                       -- HR system id
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
CREATE INDEX ix_member_group  ON census_member(employer_group_id);
CREATE INDEX ix_member_name   ON census_member(employer_group_id, last_name, first_name);

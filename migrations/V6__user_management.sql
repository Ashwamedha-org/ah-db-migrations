-- =============================================================================
-- V6__user_management.sql
-- User Management (UM) schema. Lives in the platform / directory database
-- (NOT sharded by employer) because identity is cross-cutting.
--
-- Source of truth for ROLE assignment = Microsoft Entra ID security groups:
--   grp-ah-users   -> role USER
--   grp-ah-admins  -> role ADMIN
-- These tables store the app-side user profile, a projection of group->role,
-- a fine-grained permission matrix, and a full AUDIT trail of every change.
-- =============================================================================

-- Application users, keyed to the Entra object id carried in the JWT.
CREATE TABLE um_user (
    user_id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    entra_oid          VARCHAR(64) NOT NULL UNIQUE,         -- 'oid' claim from token
    email              TEXT        NOT NULL,
    display_name       TEXT,
    employer_group_id  BIGINT,                              -- set for employees/brokers
    status             VARCHAR(16) NOT NULL DEFAULT 'ACTIVE'
                        CHECK (status IN ('ACTIVE','DISABLED','INVITED')),
    last_login_at      TIMESTAMPTZ,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_um_user_email    ON um_user(email);
CREATE INDEX ix_um_user_employer ON um_user(employer_group_id);

-- Roles, each mapped to the Entra group that grants it.
CREATE TABLE um_role (
    role_id                 SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    role_key                VARCHAR(32) NOT NULL UNIQUE,     -- USER, ADMIN, UNDERWRITER, BROKER
    description             TEXT,
    entra_group_object_id   VARCHAR(64) UNIQUE               -- Entra security-group object id
);

-- Fine-grained permissions enforced on the APIs.
CREATE TABLE um_permission (
    permission_id   SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    permission_key  VARCHAR(48) NOT NULL UNIQUE,            -- e.g. 'um.user.manage'
    description     TEXT
);

-- Role -> permission matrix (what each role can do).
CREATE TABLE um_role_permission (
    role_id        SMALLINT NOT NULL REFERENCES um_role(role_id) ON DELETE CASCADE,
    permission_id  SMALLINT NOT NULL REFERENCES um_permission(permission_id) ON DELETE CASCADE,
    PRIMARY KEY (role_id, permission_id)
);

-- Projection of Entra group membership -> user role. Refreshed on login / sync.
-- Entra remains the source of truth; this is a queryable cache + override point.
CREATE TABLE um_user_role (
    user_id      UUID        NOT NULL REFERENCES um_user(user_id) ON DELETE CASCADE,
    role_id      SMALLINT    NOT NULL REFERENCES um_role(role_id),
    source       VARCHAR(16) NOT NULL DEFAULT 'ENTRA_SYNC'
                 CHECK (source IN ('ENTRA_SYNC','MANUAL')),
    assigned_by  VARCHAR(64) NOT NULL,                      -- admin entra_oid or 'system'
    assigned_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, role_id)
);

-- Immutable audit of every role change (who made an admin, when, how).
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

-- Login / access audit for security review.
CREATE TABLE um_login_audit (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id     UUID        REFERENCES um_user(user_id),
    event       VARCHAR(16) NOT NULL CHECK (event IN ('LOGIN','LOGOUT','DENIED')),
    ip_address  INET,
    user_agent  TEXT,
    at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_um_login_audit_user ON um_login_audit(user_id, at DESC);

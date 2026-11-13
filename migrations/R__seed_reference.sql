-- =============================================================================
-- R__seed_reference.sql   (Flyway repeatable migration — re-runs on checksum change)
-- Seed reference/rating data + UM roles & permissions. Safe to re-run (idempotent).
-- =============================================================================

-- ---------- Plans (ADD / CI / HI) ----------
INSERT INTO plan (plan_code, product, tier, display_name, is_rider) VALUES
    ('AH-ADD-SILVER', 'ADD', 'SILVER', 'Accidental Death & Dismemberment — Silver', FALSE),
    ('AH-ADD-GOLD',   'ADD', 'GOLD',   'Accidental Death & Dismemberment — Gold',   FALSE),
    ('AH-CI-SILVER',  'CI',  'SILVER', 'Critical Illness Rider — Silver',            TRUE),
    ('AH-CI-GOLD',    'CI',  'GOLD',   'Critical Illness Rider — Gold',              TRUE),
    ('AH-HI-GOLD',    'HI',  'GOLD',   'Hospital Indemnity — Gold',                  FALSE)
ON CONFLICT (plan_code) DO UPDATE
    SET display_name = EXCLUDED.display_name, tier = EXCLUDED.tier;

-- ---------- Example age-banded rates (NJ vs TX) ----------
INSERT INTO rate_table (plan_code, state_code, age_band_low, age_band_high, monthly_rate, effective_date) VALUES
    ('AH-ADD-GOLD', 'NJ', 18, 29, 4.2500, DATE '2026-01-01'),
    ('AH-ADD-GOLD', 'NJ', 30, 44, 6.1000, DATE '2026-01-01'),
    ('AH-ADD-GOLD', 'NJ', 45, 64, 9.8000, DATE '2026-01-01'),
    ('AH-ADD-GOLD', 'TX', 18, 29, 3.9500, DATE '2026-01-01'),
    ('AH-ADD-GOLD', 'TX', 30, 44, 5.7500, DATE '2026-01-01'),
    ('AH-ADD-GOLD', 'TX', 45, 64, 9.1000, DATE '2026-01-01')
ON CONFLICT ON CONSTRAINT uq_rate DO UPDATE SET monthly_rate = EXCLUDED.monthly_rate;

-- ---------- State regulatory rules ----------
INSERT INTO state_regulatory_rule (state_code, rule_key, rule_value) VALUES
    ('NJ', 'MIN_ENROLL_AGE',   '{"age": 18}'),
    ('NJ', 'CHILD_MAX_AGE',    '{"age": 26}'),
    ('TX', 'MIN_ENROLL_AGE',   '{"age": 18}'),
    ('TX', 'HI_REQUIRES_RIDER','{"required": false}')
ON CONFLICT (state_code, rule_key, effective_date) DO NOTHING;

-- ---------- UM roles (mapped to Entra security groups) ----------
INSERT INTO um_role (role_key, description, entra_group_object_id) VALUES
    ('USER',        'Self-service employee / broker access',  '00000000-0000-0000-0000-00000000user'),
    ('ADMIN',       'Full User Management + platform admin',  '00000000-0000-0000-0000-0000000admin'),
    ('UNDERWRITER', 'Read policies/claims, run reports',      NULL),
    ('BROKER',      'Manage own employer groups & quotes',    NULL)
ON CONFLICT (role_key) DO UPDATE SET description = EXCLUDED.description;

-- ---------- UM permissions ----------
INSERT INTO um_permission (permission_key, description) VALUES
    ('um.user.read',    'View users'),
    ('um.user.manage',  'Create/disable users, assign roles'),
    ('quote.create',    'Create & price quotes'),
    ('policy.bind',     'Bind new policies'),
    ('policy.read',     'View policy history'),
    ('claim.read',      'View claim status'),
    ('report.view',     'View dashboards & reports')
ON CONFLICT (permission_key) DO NOTHING;

-- ---------- Role -> permission matrix ----------
-- USER: self-service
INSERT INTO um_role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id
FROM   um_role r, um_permission p
WHERE  r.role_key = 'USER'
  AND  p.permission_key IN ('quote.create','policy.read','claim.read')
ON CONFLICT DO NOTHING;

-- ADMIN: everything
INSERT INTO um_role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id
FROM   um_role r, um_permission p
WHERE  r.role_key = 'ADMIN'
ON CONFLICT DO NOTHING;

-- UNDERWRITER: read-heavy
INSERT INTO um_role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id
FROM   um_role r, um_permission p
WHERE  r.role_key = 'UNDERWRITER'
  AND  p.permission_key IN ('policy.read','claim.read','report.view')
ON CONFLICT DO NOTHING;

-- BROKER: quoting + binding for own groups
INSERT INTO um_role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id
FROM   um_role r, um_permission p
WHERE  r.role_key = 'BROKER'
  AND  p.permission_key IN ('quote.create','policy.bind','policy.read','report.view')
ON CONFLICT DO NOTHING;

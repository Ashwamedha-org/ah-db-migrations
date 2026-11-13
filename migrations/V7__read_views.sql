-- =============================================================================
-- V7__read_views.sql
-- Read-optimized views for the REPLICA path (dashboards, history, UM screens).
-- ah-policy-data-service routes @Transactional(readOnly = true) here so the
-- sharded primaries stay free for policy binds.
-- =============================================================================

-- Policyholder / HR-admin policy history view.
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

-- Broker dashboard: enrollment counts per employer group.
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

-- UM: a user's effective permissions (role projection -> permission matrix).
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

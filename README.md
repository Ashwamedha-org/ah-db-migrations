# ah-db-migrations

> **Role:** The single source of truth for the **database layer** — all SQL schema definitions,
> table creations, indexes and versioned migrations for the **sharded primaries** and their
> **read replicas**.

Part of the **A&H Mass Rate-Quote Scalability PoC**:
[`ah-enrollment-ui`](../ah-enrollment-ui) · [`ah-quote-service`](../ah-quote-service) ·
[`ah-policy-data-service`](../ah-policy-data-service) · **`ah-db-migrations`**

---

## Two ways to build the database

| File(s) | What it is | When to use |
|---|---|---|
| [`schema.sql`](schema.sql) | **God schema** — the *entire current state* of the DB in one file | Bootstrap a fresh **local** database in one command; read it top-to-bottom to understand the whole model |
| [`migrations/`](migrations) | **Change history** — ordered `V#__*.sql` diffs | Safely upgrade databases that already hold data (teammates, staging, each Azure shard) |

> **Golden workflow:** every schema change is reflected in **`schema.sql`** (always = "now")
> **and** captured as a new **`migrations/V#__*.sql`** script (the diff that gets you there).
> `schema.sql` is a *snapshot*; `migrations/` is the *trail*. Keep both in sync.

### One-command local bootstrap

```bash
# 1. start a throwaway PostgreSQL 16
docker run -d --name ah-local-db -e POSTGRES_PASSWORD=pw -e POSTGRES_DB=ah \
    -p 5432:5432 postgres:16

# 2. build the ENTIRE database (27 tables incl. partitions, 3 views, seed data)
PGPASSWORD=pw psql -h localhost -p 5432 -U postgres -d ah -f schema.sql
```

`schema.sql` is **idempotent** on its seed data (`ON CONFLICT`), so re-running it never
errors on duplicate keys. It is validated to apply cleanly against PostgreSQL 16.

### What's inside `schema.sql` (9 sections)

| # | Section | Tables | Scalability idea it demonstrates |
|---|---|---|---|
| 1 | Extensions | `pgcrypto` | `gen_random_uuid()` → shards mint their own IDs (no central sequence) |
| 2 | Reference / rating | `plan`, `plan_benefit`, `rate_table`, `state_regulatory_rule` | Read-only, **Redis-cached**, copied to every shard; covering index `ix_rate_lookup` for sub-15 ms quotes |
| 3 | Core | `shard_map`, `employer_group`, `census_member` | **Sharded by `employer_group_id`** — keeps a company's data together on one shard |
| 4 | Quotes | `quote`, `quote_coverage` | Durable snapshot; live wizard state lives in Redis → **stateless app servers** |
| 5 | Policies | `policy` (+ `policy_coverage`, `dependent`, `beneficiary`) | **RANGE-partitioned by `bound_at`**; children carry `policy_bound_at` for composite FKs |
| 6 | Claims | `claim` | **RANGE-partitioned by `incurred_date`** → prune/archive old quarters cheaply |
| 7 | User Management | `um_user`, `um_role`, `um_permission`, `um_role_permission`, `um_user_role`, audit tables | **RBAC** driven by Entra ID groups; **not sharded** (identity is cross-cutting) |
| 8 | Read views | `vw_policy_history`, `vw_group_enrollment`, `vw_user_effective_permissions` | Heavy reads served from **replicas**, not the primary |
| 9 | Seed data | — | Idempotent plans, NJ/TX rates, state rules, roles & permission matrix |

> **One mental model:** *sharding* splits data **across servers** (by `employer_group_id`);
> *partitioning* splits a big table **within one server** (by date); *caching* and *replicas*
> keep reads off the write primary.

---

## Database topology

![Sharded primaries + replica fan-out animation](docs/db-topology.svg)

> The animation shows versioned migrations applied identically to **both shard primaries**,
> each streaming WAL changes to its **read replicas**.

```mermaid
flowchart TD
    RUN[Migration Runner\nFlyway / Liquibase] --> S1[(Shard 1 · Primary · NE)]
    RUN --> S2[(Shard 2 · Primary · MW/South)]
    S1 -. async WAL .-> R1a[(Replica 1a)]
    S1 -. async WAL .-> R1b[(Replica 1b)]
    S2 -. async WAL .-> R2a[(Replica 2a)]
    S2 -. async WAL .-> R2b[(Replica 2b)]
```

---

## Data model (ER overview)

> Full schema lives in [`migrations/`](migrations) and is validated against PostgreSQL 16.

### A&H domain (sharded by `Employer_Group_ID`)

```mermaid
erDiagram
    EMPLOYER_GROUP ||--o{ CENSUS_MEMBER : employs
    EMPLOYER_GROUP ||--o{ QUOTE : "quoted for"
    EMPLOYER_GROUP ||--o{ POLICY : holds
    CENSUS_MEMBER ||--o{ QUOTE : requests
    CENSUS_MEMBER ||--o{ POLICY : "insured on"
    QUOTE ||--o{ QUOTE_COVERAGE : includes
    POLICY ||--o{ POLICY_COVERAGE : includes
    POLICY ||--o{ DEPENDENT : covers
    POLICY ||--o{ BENEFICIARY : "pays out to"
    POLICY ||--o{ CLAIM : generates
    PLAN ||--o{ POLICY_COVERAGE : "chosen in"
    PLAN ||--o{ RATE_TABLE : "priced by"
    PLAN ||--o{ PLAN_BENEFIT : defines

    EMPLOYER_GROUP {
        bigint employer_group_id PK
        string legal_name
        char   state_code
        smallint shard_no
        int    employee_count
    }
    CENSUS_MEMBER {
        uuid   member_id PK
        bigint employer_group_id FK
        date   dob
        string zip
        string status
    }
    QUOTE {
        uuid   quote_id PK
        bigint employer_group_id FK
        uuid   member_id FK
        numeric total_monthly_premium
        string status
    }
    QUOTE_COVERAGE {
        uuid   quote_coverage_id PK
        uuid   quote_id FK
        string plan_code
        numeric monthly_premium
    }
    POLICY {
        uuid   policy_id PK
        bigint employer_group_id FK
        uuid   member_id FK
        string status
        timestamptz bound_at "partition key"
    }
    POLICY_COVERAGE {
        uuid   coverage_id PK
        uuid   policy_id FK
        string plan_code
        numeric monthly_premium
    }
    DEPENDENT {
        uuid   dependent_id PK
        uuid   policy_id FK
        string relationship
        date   dob
    }
    BENEFICIARY {
        uuid   beneficiary_id PK
        uuid   policy_id FK
        numeric percentage
    }
    CLAIM {
        uuid   claim_id PK
        uuid   policy_id FK
        string claim_type
        date   incurred_date "partition key"
        numeric amount
    }
    PLAN {
        string plan_code PK
        string product
        string tier
    }
    PLAN_BENEFIT {
        bigint benefit_id PK
        string plan_code FK
        string benefit_type
        numeric benefit_value
    }
    RATE_TABLE {
        bigint rate_id PK
        string plan_code FK
        char   state_code
        int    age_band_low
        int    age_band_high
        numeric monthly_rate
    }
```

### User Management (platform/directory DB — not sharded)

> Entra ID security groups are the **source of truth** for role assignment; these tables hold
> the app-side profile, a projection of group→role, a permission matrix, and audit trails.

```mermaid
erDiagram
    UM_USER ||--o{ UM_USER_ROLE : has
    UM_ROLE ||--o{ UM_USER_ROLE : "granted via"
    UM_ROLE ||--o{ UM_ROLE_PERMISSION : allows
    UM_PERMISSION ||--o{ UM_ROLE_PERMISSION : "granted by"
    UM_USER ||--o{ UM_ROLE_AUDIT : "changes logged"
    UM_USER ||--o{ UM_LOGIN_AUDIT : "logins logged"

    UM_USER {
        uuid   user_id PK
        string entra_oid "oid claim (unique)"
        string email
        bigint employer_group_id
        string status
    }
    UM_ROLE {
        smallint role_id PK
        string role_key "USER / ADMIN / ..."
        string entra_group_object_id "maps to AD group"
    }
    UM_PERMISSION {
        smallint permission_id PK
        string permission_key "um.user.manage ..."
    }
    UM_ROLE_PERMISSION {
        smallint role_id FK
        smallint permission_id FK
    }
    UM_USER_ROLE {
        uuid   user_id FK
        smallint role_id FK
        string source "ENTRA_SYNC / MANUAL"
    }
    UM_ROLE_AUDIT {
        bigint audit_id PK
        uuid   target_user FK
        string action "GRANT / REVOKE / SYNC"
        string changed_by
    }
    UM_LOGIN_AUDIT {
        bigint id PK
        uuid   user_id FK
        string event
        inet   ip_address
    }
```

### Sharding & indexing strategy

| Concern | Decision |
|---|---|
| **Shard key** | `Employer_Group_ID` → `hash(id) % 2` (extendable), or by `State_Code` region |
| **Shard 1 / Shard 2** | Northeast-East / Midwest-South groups, members, quotes, policies, claims |
| **Shard directory** | `shard_map` (central DB) resolves `employer_group_id → shard_no` |
| **Reference data** | `plan`, `plan_benefit`, `rate_table`, `state_regulatory_rule` replicated to every shard + cached in Redis |
| **Hot read index** | `ix_rate_lookup (state_code, plan_code, age_band_*)` INCLUDE `(monthly_rate)` → sub-15 ms quotes |
| **Partitioning** | `policy` RANGE by `bound_at`; `claim` RANGE by `incurred_date` → smaller indexes, easy pruning |
| **User Management** | Lives in the **platform/directory DB** (identity is cross-cutting, not sharded) |
| **Replicas** | Each primary streams async WAL to replicas serving history/dashboard/UM reads (see `V7__read_views.sql`) |

---

## Migration workflow

All files validated end-to-end against **PostgreSQL 16** (schema applies cleanly, composite FKs,
partition routing, and the repeatable seed are all green).

```
schema.sql                     -- GOD SCHEMA: full current state in one file (local bootstrap)
migrations/
  V1__reference_rating.sql     -- plan, plan_benefit, rate_table, state_regulatory_rule (+ hot index)
  V2__core_groups_members.sql  -- shard_map, employer_group, census_member
  V3__quotes.sql               -- quote, quote_coverage (durable snapshot; live state in Redis)
  V4__policies.sql             -- policy (partitioned) + policy_coverage, dependent, beneficiary
  V5__claims.sql               -- claim (partitioned by incurred_date)
  V6__user_management.sql      -- um_user, um_role, um_permission, um_user_role, audit tables
  V7__read_views.sql           -- replica-facing views (history, dashboards, effective permissions)
  R__seed_reference.sql        -- repeatable: seed plans, rates, state rules, UM roles & permissions
```

```bash
# Apply the same versioned schema to every shard primary
for DB in $SHARD1_URL $SHARD2_URL; do
  flyway -url="$DB" -locations=filesystem:./migrations migrate
done
# Replicas receive the schema automatically via streaming replication.

# Quick local validation (throwaway container)
docker run -d --name pg -e POSTGRES_PASSWORD=pw -e POSTGRES_DB=ahtest -p 55432:5432 postgres:16
for f in migrations/V*.sql migrations/R__*.sql; do
  PGPASSWORD=pw psql -h localhost -p 55432 -U postgres -d ahtest -v ON_ERROR_STOP=1 -f "$f"
done
```

> **Golden rule:** migrations are **additive and backward-compatible** (expand → migrate →
> contract) so stateless pods can roll without downtime during the Open Enrollment window.

---

## Azure deployment target

- **Azure Database for PostgreSQL – Flexible Server**, one server **per shard** with
  **read replicas**; private endpoints; secrets in **Key Vault**.
- Migrations run from **GitHub Actions / Azure DevOps** against each shard.
- Platform landing-zone + SSO details:
  [`ah-enrollment-ui`](../ah-enrollment-ui#azure-enterprise-landing-zone).

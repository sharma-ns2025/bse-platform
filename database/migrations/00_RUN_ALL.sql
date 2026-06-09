-- ============================================================================
-- BSE: MASTER RUN SCRIPT
-- Run this single file to build the entire database from scratch.
-- Idempotent: safe to re-run — all scripts use IF NOT EXISTS + ON CONFLICT.
--
-- PREREQUISITES (do these BEFORE running this file):
--   1. Create Aurora PostgreSQL cluster (see AWS_SETUP_GUIDE below)
--   2. Connect as master user: psql -h <endpoint> -U postgres -d postgres
--   3. Create the database: CREATE DATABASE bse;
--   4. Switch to it: \c bse
--   5. Run this file: \i 00_RUN_ALL.sql
--
-- ESTIMATED RUNTIME: ~15-30 seconds on a fresh DB
--
-- AWS AURORA SETUP (brand new account — 15 minute UI walkthrough):
-- ─────────────────────────────────────────────────────────────────
-- Step 1: Open https://console.aws.amazon.com/rds
-- Step 2: Click "Create database"
-- Step 3: Choose these options:
--   • Engine:               Amazon Aurora
--   • Edition:              Aurora PostgreSQL-Compatible
--   • Version:              PostgreSQL 15 (latest)
--   • Template:             Production (for Multi-AZ) OR Dev/Test (for Serverless)
--   • DB cluster ID:        bse-production
--   • Master username:      postgres
--   • Master password:      [generate strong password, save in AWS Secrets Manager]
--   • Instance type:        Serverless v2 (recommended for MVP cost)
--     OR db.t3.medium if you prefer fixed cost (~$60/mo)
--   • Min ACU:              0.5  (scales to near-zero when idle)
--   • Max ACU:              8    (handles ~500 concurrent users, increase later)
--   • VPC:                  Your VPC (or create new)
--   • Subnet group:         Private subnets only
--   • Public access:        NO
--   • VPC security group:   Allow port 5432 from your app servers only
--   • Encryption:           Enable (AWS KMS, default key is fine)
--   • Performance Insights: Enable (free tier, invaluable for debugging)
--   • Enhanced Monitoring:  Enable (60 second interval)
--   • Log exports:          PostgreSQL logs + Upgrade logs
-- Step 4: Click "Create database" → wait 5-10 minutes
-- Step 5: Note the "Writer endpoint" — this is your DB_HOST
-- Step 6: Save password in Secrets Manager:
--   • Open https://console.aws.amazon.com/secretsmanager
--   • "Store a new secret" → "Credentials for Amazon RDS database"
--   • Select your cluster → enter password → name: "bse/db/master"
--
-- CONNECT VIA BASTION (since DB is in private subnet):
--   Option A: AWS Cloud Shell (free, built-in)
--     1. Open CloudShell from AWS console toolbar
--     2. Install psql: sudo dnf install -y postgresql15
--     3. Connect: psql -h <writer-endpoint> -U postgres -d postgres
--
--   Option B: EC2 Bastion Host
--     1. Launch t3.micro EC2 in same VPC, public subnet
--     2. SSH to EC2, then psql to RDS from there
--
--   Option C: AWS Systems Manager Session Manager (no SSH needed)
--     1. Launch EC2 with SSM agent, no public IP
--     2. Use "Connect" → "Session Manager" in EC2 console
--
-- AZURE EQUIVALENT MAPPING (for your reference):
--   Aurora PostgreSQL    ↔  Azure Database for PostgreSQL Flexible Server
--   RDS Proxy           ↔  Azure Private Link
--   Secrets Manager     ↔  Azure Key Vault
--   Performance Insights↔  Azure Query Performance Insight
--   CloudWatch Logs     ↔  Azure Monitor / Log Analytics
-- ─────────────────────────────────────────────────────────────────
--
-- FILE EXECUTION ORDER:
-- ============================================================================

\echo '============================================================'
\echo 'BSE Database Setup Starting...'
\echo '============================================================'

-- ── 00: Extensions, schemas, roles, shared enums ─────────────────────────
\echo '[1/9] Master setup: schemas, roles, enums...'
\i schemas/00_master_setup.sql

-- ── 01: Auth schema (Firebase users, devices, wallets, payment methods) ──
\echo '[2/9] Auth schema...'
\i schemas/01_auth_schema.sql

-- ── 02: Core schema (stock tokens, NAV history, watchlist, price feed) ───
\echo '[3/9] Core schema...'
\i schemas/02_core_schema.sql

-- ── 03: Wallet schema (accounts, deposits, withdrawals, ledger) ───────────
\echo '[4/9] Wallet schema...'
\i schemas/03_wallet_schema.sql

-- ── 04: Trading schema (orders, holdings, positions, snapshots) ───────────
\echo '[5/9] Trading schema...'
\i schemas/04_trading_schema.sql

-- ── 05: Staking + Fund + Audit schemas ────────────────────────────────────
\echo '[6/9] Staking, Fund, Audit schemas...'
\i schemas/05_staking_fund_audit_schemas.sql

-- ── 06: API views (one view per Figma screen / API endpoint) ──────────────
\echo '[7/9] API views...'
\i views/06_api_views.sql

-- ── 07: Seed data (stock tokens) + Mock data Part 1 (users, wallets) ──────
\echo '[8/9] Seed and mock data (part 1)...'
\i seeds/07_seed_and_mock_data.sql

-- ── 08: Stored functions (ACID ops, NAV engine, reconcile) ────────────────
\echo '[9/10] Stored functions...'
\i functions/08_functions.sql

-- ── 09: Mock data Part 2 (orders, stakers, ledger, price feed) ────────────
\echo '[10/10] Mock data (part 2)...'
\i seeds/09_mock_data_part2.sql

-- ============================================================================
-- POST-SETUP VERIFICATION
-- Counts every table. Zero on any critical table = something failed.
-- ============================================================================
\echo ''
\echo '============================================================'
\echo 'VERIFICATION: Table row counts'
\echo '============================================================'

SELECT
  schemaname                          AS schema,
  relname                             AS table_name,
  n_live_tup                          AS approx_rows
FROM pg_stat_user_tables
WHERE schemaname IN ('auth','core','wallet','trading','staking','fund','audit')
ORDER BY schemaname, relname;

\echo ''
\echo 'VERIFICATION: Views created'
SELECT schemaname, viewname
FROM pg_views
WHERE schemaname IN ('auth','core','wallet','trading')
ORDER BY schemaname, viewname;

\echo ''
\echo 'VERIFICATION: Functions created'
SELECT routine_schema, routine_name, routine_type
FROM information_schema.routines
WHERE routine_schema IN ('auth','core','wallet','trading','staking','audit','public')
  AND routine_type IN ('FUNCTION','PROCEDURE')
ORDER BY routine_schema, routine_name;

\echo ''
\echo 'VERIFICATION: Audit partitions'
SELECT tablename FROM pg_tables
WHERE schemaname = 'audit' AND tablename LIKE 'events_%'
ORDER BY tablename;

\echo ''
\echo '============================================================'
\echo 'BSE Database Setup COMPLETE'
\echo '============================================================'
\echo ''
\echo 'NEXT STEPS:'
\echo '  1. Update Firebase UID in mock user rows (auth.users.firebase_uid)'
\echo '  2. Set DB password in AWS Secrets Manager: bse/db/master'
\echo '  3. Create app user passwords in Secrets Manager: bse/db/app'
\echo '  4. Configure backend .env: DB_HOST, DB_USER=bse_api_user'
\echo '  5. Test with: SELECT * FROM trading.v_dashboard_portfolio;'
\echo '  6. Schedule: CALL audit.create_monthly_partition(); (1st of each month)'
\echo ''

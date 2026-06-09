-- ============================================================================
-- BSE: MASTER SETUP SCRIPT
-- Run this file once against a brand-new AWS RDS PostgreSQL instance.
-- It bootstraps all extensions, schemas, roles, and then calls sub-scripts.
--
-- Recommended AWS DB: Aurora PostgreSQL Serverless v2 (explained at bottom)
-- Connect: psql -h <RDS_ENDPOINT> -U postgres -f 00_master_setup.sql
-- ============================================================================

-- ----------------------------------------------------------------------------
-- SECTION 1: EXTENSIONS
-- These add capabilities to PostgreSQL. Must run as superuser (postgres).
-- ----------------------------------------------------------------------------

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";     -- uuid_generate_v4()
CREATE EXTENSION IF NOT EXISTS "pgcrypto";      -- gen_random_uuid(), crypt()
CREATE EXTENSION IF NOT EXISTS "pg_trgm";       -- trigram index for fast LIKE/search
CREATE EXTENSION IF NOT EXISTS "btree_gist";    -- GiST index on scalar types (exclusion constraints)
CREATE EXTENSION IF NOT EXISTS "tablefunc";     -- crosstab() for pivot queries (reporting)

-- ----------------------------------------------------------------------------
-- SECTION 2: DATABASE ROLES (Least-privilege access per service)
-- Each backend microservice gets only the permissions it needs.
-- Never use the master 'postgres' user from application code.
-- ----------------------------------------------------------------------------

-- Read-only role (market data service, reporting)
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bse_reader') THEN
    CREATE ROLE bse_reader NOLOGIN;
  END IF;
END $$;

-- Application write role (all backend API services)
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bse_app') THEN
    CREATE ROLE bse_app NOLOGIN;
  END IF;
END $$;

-- Migration role (only for running schema changes, not the app)
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bse_migrate') THEN
    CREATE ROLE bse_migrate NOLOGIN;
  END IF;
END $$;

-- Audit read-only role (compliance, ops team queries)
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bse_audit_reader') THEN
    CREATE ROLE bse_audit_reader NOLOGIN;
  END IF;
END $$;

-- Application login users (one per service — use AWS Secrets Manager for passwords)
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bse_api_user') THEN
    CREATE USER bse_api_user PASSWORD 'CHANGE_ME_USE_SECRETS_MANAGER' IN ROLE bse_app;
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bse_migrate_user') THEN
    CREATE USER bse_migrate_user PASSWORD 'CHANGE_ME_USE_SECRETS_MANAGER' IN ROLE bse_migrate;
  END IF;
END $$;

-- ----------------------------------------------------------------------------
-- SECTION 3: SCHEMAS
-- Schema separation enforces logical boundaries and simplifies permission grants.
-- auth     → Firebase-synced user identity + sessions/devices
-- core     → Stock tokens, market data, NAV history
-- wallet   → Balances, deposits, withdrawals, double-entry ledger
-- trading  → Orders, holdings, positions, watchlist
-- staking  → Staker profiles, staked positions, rewards
-- fund     → Internal Alpaca hedge-fund pool management
-- mock     → Demo/test data — isolated from real data, DROP-safe
-- audit    → Immutable event log (append-only, no deletes ever)
-- ----------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS auth;
CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS wallet;
CREATE SCHEMA IF NOT EXISTS trading;
CREATE SCHEMA IF NOT EXISTS staking;
CREATE SCHEMA IF NOT EXISTS fund;
CREATE SCHEMA IF NOT EXISTS mock;
CREATE SCHEMA IF NOT EXISTS audit;

-- ----------------------------------------------------------------------------
-- SECTION 4: SCHEMA-LEVEL PERMISSIONS
-- ----------------------------------------------------------------------------

-- bse_app can use all business schemas
GRANT USAGE ON SCHEMA auth, core, wallet, trading, staking, fund TO bse_app;
-- bse_reader for market/core data only
GRANT USAGE ON SCHEMA core TO bse_reader;
-- audit reader
GRANT USAGE ON SCHEMA audit TO bse_audit_reader;
-- migrate gets everything
GRANT USAGE ON SCHEMA auth, core, wallet, trading, staking, fund, mock, audit TO bse_migrate;

-- Default privileges: any new table in these schemas is auto-granted to bse_app
ALTER DEFAULT PRIVILEGES IN SCHEMA auth     GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO bse_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA core     GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO bse_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA wallet   GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO bse_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA trading  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO bse_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA staking  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO bse_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA fund     GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO bse_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA core     GRANT SELECT ON TABLES TO bse_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA audit    GRANT SELECT ON TABLES TO bse_audit_reader;
-- audit schema: app can INSERT but NOT UPDATE or DELETE (immutability)
ALTER DEFAULT PRIVILEGES IN SCHEMA audit    GRANT SELECT, INSERT ON TABLES TO bse_app;

-- ----------------------------------------------------------------------------
-- SECTION 5: GLOBAL ENUMS
-- Defined once at database level, referenced across all schemas.
-- ----------------------------------------------------------------------------

-- User KYC verification status (from Figma Profile screen: "Verified KYC")
DO $$ BEGIN
  CREATE TYPE kyc_status_enum AS ENUM (
    'not_started',  -- user registered but has not begun KYC
    'pending',      -- KYC submitted, awaiting third-party verification
    'approved',     -- KYC passed, full trading access
    'rejected',     -- KYC failed, restricted access
    'expired'       -- Previously approved but needs re-verification (1 year)
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Crypto currencies supported (Figma: USDT, ETH, BTC shown in Balance and Deposit screens)
DO $$ BEGIN
  CREATE TYPE crypto_currency_enum AS ENUM ('USDT', 'ETH', 'BTC');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Deposit/withdrawal lifecycle (Figma Balance screen: "completed", "pending" status badges)
DO $$ BEGIN
  CREATE TYPE fund_transfer_status_enum AS ENUM (
    'initiated',    -- user submitted request
    'confirming',   -- awaiting blockchain confirmations
    'processing',   -- internal processing in progress
    'in_transit',   -- sent to broker, awaiting settlement
    'completed',    -- fully settled
    'failed',       -- failed, funds not moved
    'refunded',     -- failed after partial processing, refunded
    'cancelled'     -- cancelled by user before processing
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Order sides (Figma Stock detail: "Buy" / "Sell" toggle)
DO $$ BEGIN
  CREATE TYPE order_side_enum AS ENUM ('buy', 'sell');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Order execution status (Figma Trade > Preview Order: Place Order flow)
DO $$ BEGIN
  CREATE TYPE order_status_enum AS ENUM (
    'draft',        -- saved for later (Figma: "Save for later" button)
    'pending',      -- submitted, not yet in EOD batch
    'queued',       -- accepted into today's EOD batch
    'executed',     -- filled at NAV price
    'cancelled',    -- cancelled before execution
    'failed',       -- could not execute (insufficient supply/funds)
    'partial'       -- partially filled
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Order price types (Figma Trade screen: "Price type" field)
DO $$ BEGIN
  CREATE TYPE order_price_type_enum AS ENUM ('market', 'limit');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Order duration (Figma Trade screen: "Duration" field)
DO $$ BEGIN
  CREATE TYPE order_duration_enum AS ENUM ('good_for_day', 'good_till_cancelled', 'immediate_or_cancel');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Wallet/ledger transaction types
DO $$ BEGIN
  CREATE TYPE ledger_tx_type_enum AS ENUM (
    'deposit',           -- crypto deposited, BSE tokens credited
    'withdrawal',        -- BSE tokens debited, crypto sent out
    'buy_stock',         -- BSE tokens spent to buy stock tokens
    'sell_stock',        -- BSE tokens received from selling stock tokens
    'trading_fee',       -- flat $3.99 fee per trade
    'expense_ratio_fee', -- percentage fee (1-5%) on stock token value
    'staking_reward',    -- reward paid to staker
    'nav_adjustment',    -- portfolio value adjustment on NAV update
    'transfer_in',       -- internal transfer received
    'transfer_out',      -- internal transfer sent
    'refund'             -- refund credited
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Notification types (Figma Notifications screen: Successful Trades, Price Alerts, Security, Marketing)
DO $$ BEGIN
  CREATE TYPE notification_type_enum AS ENUM (
    'trade_executed',
    'trade_failed',
    'deposit_completed',
    'withdrawal_completed',
    'price_alert',
    'security_alert',
    'nav_updated',
    'marketing',
    'system'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Payment method types (Figma Payment Methods screen: Visa debit card, bank account)
DO $$ BEGIN
  CREATE TYPE payment_method_type_enum AS ENUM ('card', 'bank_account', 'crypto_wallet');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Wallet provider (Figma: MetaMask, WalletConnect, Coinbase Wallet)
DO $$ BEGIN
  CREATE TYPE wallet_provider_enum AS ENUM ('metamask', 'walletconnect', 'coinbase', 'other');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Staker status
DO $$ BEGIN
  CREATE TYPE staker_status_enum AS ENUM ('pending_verification', 'active', 'paused', 'suspended', 'inactive');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ----------------------------------------------------------------------------
-- SECTION 6: SHARED UTILITY FUNCTION
-- Reusable trigger function for auto-updating 'updated_at' columns.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  -- Automatically stamps updated_at with current UTC time on every UPDATE
  NEW.updated_at = NOW() AT TIME ZONE 'UTC';
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.set_updated_at() IS
  'Shared trigger function: stamps updated_at on every row UPDATE. '
  'Attach to any table with: CREATE TRIGGER trg_<table>_updated_at ...';

-- ----------------------------------------------------------------------------
-- NOTES: AWS DATABASE RECOMMENDATION
-- ============================================================================
-- RECOMMENDED: Amazon Aurora PostgreSQL Serverless v2
--
-- WHY over standard RDS PostgreSQL:
--   • Cost: Scales to 0.5 ACU when idle (~$0.06/hr vs $0.048/hr fixed for t3.medium)
--     At MVP with low traffic, Aurora Serverless v2 is ~60% cheaper
--   • Scale: Auto-scales from 0.5 to 128 ACUs — handles 1M users without instance resize
--   • No downtime for scaling (unlike RDS which requires a reboot for instance class change)
--   • Multi-AZ built-in via Aurora cluster (vs extra cost on RDS)
--   • Azure SQL equivalent: Azure SQL Serverless — same mental model you know
--
-- HOW TO CREATE (AWS Console — UI steps):
--   1. Go to: RDS Console → Create database
--   2. Choose: Amazon Aurora → PostgreSQL-Compatible
--   3. Template: Production
--   4. DB cluster ID: bse-production
--   5. Serverless v2: YES → Min ACU: 0.5, Max ACU: 16 (adjust up at scale)
--   6. Master username: postgres
--   7. VPC: your BSE VPC (private subnets only)
--   8. Publicly accessible: NO
--   9. Storage encryption: YES (KMS key)
--   10. Enable: Performance Insights, Enhanced Monitoring, Log exports
--
-- HOW TO CONNECT once created:
--   psql -h <cluster-endpoint>.rds.amazonaws.com -U postgres -d postgres
--   Then run: \i 00_master_setup.sql
--
-- COST ESTIMATE (MVP, us-east-1):
--   Aurora Serverless v2: ~$43-120/mo (depending on load)
--   Storage: ~$0.10/GB/mo
--   I/O: ~$0.20/million requests
--   Total MVP: ~$50-130/mo (vs $200/mo for RDS db.r6g.large Multi-AZ)
-- ============================================================================

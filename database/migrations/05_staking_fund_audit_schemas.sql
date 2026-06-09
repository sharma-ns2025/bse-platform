-- ============================================================================
-- SCHEMA: staking
-- PURPOSE: Staker onboarding, Alpaca-verified stock positions,
--          staking rewards distribution.
-- RUN ORDER: 05
-- ============================================================================

SET search_path TO staking, public;

CREATE TABLE IF NOT EXISTS staking.staker_profiles (
  id                        UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id                   UUID          NOT NULL UNIQUE REFERENCES auth.users(id) ON DELETE RESTRICT,

  -- Alpaca brokerage integration (encrypted at rest via AWS KMS)
  alpaca_account_id         VARCHAR(100),
    -- Alpaca account ID — verified via OAuth or API key exchange
  alpaca_key_ref            VARCHAR(200),
    -- AWS Secrets Manager ARN for this staker's Alpaca API key
    -- NEVER store raw keys in DB. Store the Secrets Manager reference only.
  alpaca_verified_at        TIMESTAMPTZ,

  is_whale_staker           BOOLEAN       NOT NULL DEFAULT FALSE,
    -- Whale stakers enable auto-staking (API dynamically adjusts qty)
  auto_staking_enabled      BOOLEAN       NOT NULL DEFAULT FALSE,
    -- Auto-staking: Alpaca API aligns staked qty to platform supply/demand

  status                    staker_status_enum NOT NULL DEFAULT 'pending_verification',
  total_earned_usd          NUMERIC(20, 8) NOT NULL DEFAULT 0,
  payout_wallet_address     VARCHAR(42),
    -- Where staking rewards are paid in USDT

  created_at                TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at                TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_staking_profiles_updated_at
  BEFORE UPDATE ON staking.staker_profiles
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ============================================================================
-- TABLE: staking.positions
-- Individual staked positions: which stocks, how many shares.
-- Verified against Alpaca API before staking is accepted.
-- ============================================================================
CREATE TABLE IF NOT EXISTS staking.positions (
  id                  UUID            PRIMARY KEY DEFAULT uuid_generate_v4(),
  staker_id           UUID            NOT NULL REFERENCES staking.staker_profiles(id),
  token_id            UUID            NOT NULL REFERENCES core.stock_tokens(id),
  symbol              VARCHAR(12)     NOT NULL,

  staked_qty          NUMERIC(20, 8)  NOT NULL DEFAULT 0 CHECK (staked_qty >= 0),
    -- Total shares verified as staked by Alpaca API
  matched_qty         NUMERIC(20, 8)  NOT NULL DEFAULT 0 CHECK (matched_qty >= 0),
    -- Currently matched to active token buyers
  available_qty       NUMERIC(20, 8)  GENERATED ALWAYS AS (staked_qty - matched_qty) STORED,
    -- Available for new buyers to purchase tokens against

  is_long_position    BOOLEAN         NOT NULL DEFAULT TRUE,
    -- Stakers MUST be in long position (own the shares, not short)
  reward_rate         NUMERIC(8, 6)   NOT NULL DEFAULT 0.007,
    -- Staker's share of the expense ratio (e.g., 70% of ratio)
  total_reward_usd    NUMERIC(20, 8)  NOT NULL DEFAULT 0,

  last_alpaca_sync_at TIMESTAMPTZ,
    -- When Alpaca last confirmed the staked position
  is_active           BOOLEAN         NOT NULL DEFAULT TRUE,

  created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

  CONSTRAINT uq_staking_position_staker_token UNIQUE (staker_id, token_id)
);

CREATE TRIGGER trg_staking_positions_updated_at
  BEFORE UPDATE ON staking.positions
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE INDEX IF NOT EXISTS idx_staking_positions_token_id ON staking.positions(token_id) WHERE is_active = TRUE;

-- ============================================================================
-- TABLE: staking.reward_payments
-- Each NAV engine run distributes staking rewards per token per staker.
-- Append-only record of every reward payment.
-- ============================================================================
CREATE TABLE IF NOT EXISTS staking.reward_payments (
  id              UUID            PRIMARY KEY DEFAULT uuid_generate_v4(),
  staker_id       UUID            NOT NULL REFERENCES staking.staker_profiles(id),
  position_id     UUID            NOT NULL REFERENCES staking.positions(id),
  nav_date        DATE            NOT NULL,
  reward_usd      NUMERIC(20, 8)  NOT NULL CHECK (reward_usd >= 0),
  expense_ratio   NUMERIC(8, 6)   NOT NULL,
  matched_volume  NUMERIC(20, 8)  NOT NULL,
    -- Volume of token trades that triggered this reward
  status          VARCHAR(20)     NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending', 'paid', 'failed')),
  paid_at         TIMESTAMPTZ,
  created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_staking_rewards_staker_id ON staking.reward_payments(staker_id, nav_date DESC);
CREATE INDEX IF NOT EXISTS idx_staking_rewards_pending   ON staking.reward_payments(status) WHERE status = 'pending';

COMMENT ON TABLE staking.reward_payments IS
  'Staker reward payouts per NAV calculation. Created by nav_engine after each EOD batch. '
  'Append-only. status: pending→paid after USDT transfer to staker wallet.';

-- ============================================================================
-- SCHEMA: fund
-- PURPOSE: BSE hedge fund pool — tracks the actual Alpaca portfolio that
--          backs all outstanding BSE stock tokens.
-- RUN ORDER: 06
-- ============================================================================

SET search_path TO fund, public;

-- Tracks the actual shares held in Alpaca for each stock symbol
CREATE TABLE IF NOT EXISTS fund.pool_positions (
  id                  UUID            PRIMARY KEY DEFAULT uuid_generate_v4(),
  token_id            UUID            NOT NULL UNIQUE REFERENCES core.stock_tokens(id),
  symbol              VARCHAR(12)     NOT NULL,
  base_ticker         VARCHAR(12)     NOT NULL,
  shares_held         NUMERIC(20, 8)  NOT NULL DEFAULT 0,
    -- Actual shares held in Alpaca brokerage account
  avg_cost_basis      NUMERIC(20, 8)  NOT NULL DEFAULT 0,
    -- Weighted average cost of all shares purchased
  current_market_value NUMERIC(20, 8) NOT NULL DEFAULT 0,
    -- = shares_held * current stock price (refreshed from Alpaca)
  unrealized_gain_usd NUMERIC(20, 8)  GENERATED ALWAYS AS
    (current_market_value - (shares_held * avg_cost_basis)) STORED,
  last_alpaca_sync_at TIMESTAMPTZ,
  updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_fund_pool_positions_updated_at
  BEFORE UPDATE ON fund.pool_positions
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Daily EOD batch order submitted to Alpaca
CREATE TABLE IF NOT EXISTS fund.alpaca_batch_orders (
  id                  UUID            PRIMARY KEY DEFAULT uuid_generate_v4(),
  nav_date            DATE            NOT NULL,
  token_id            UUID            NOT NULL REFERENCES core.stock_tokens(id),
  symbol              VARCHAR(12)     NOT NULL,
  base_ticker         VARCHAR(12)     NOT NULL,
  side                order_side_enum NOT NULL,
  net_qty             NUMERIC(20, 8)  NOT NULL,
    -- Net quantity = sum(buys) - sum(sells) for this day
  alpaca_order_id     VARCHAR(100)    UNIQUE,
  fill_price          NUMERIC(20, 8),
  fill_qty            NUMERIC(20, 8),
  commission_usd      NUMERIC(20, 8)  NOT NULL DEFAULT 0,
  status              VARCHAR(20)     NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending','submitted','filled','partial','cancelled','failed')),
  alpaca_raw_json     JSONB,
    -- Full Alpaca API response stored for debugging/reconciliation
  submitted_at        TIMESTAMPTZ,
  filled_at           TIMESTAMPTZ,
  created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_fund_batch_orders_nav_date ON fund.alpaca_batch_orders(nav_date DESC);
CREATE INDEX IF NOT EXISTS idx_fund_batch_orders_status   ON fund.alpaca_batch_orders(status) WHERE status IN ('pending','submitted');

COMMENT ON TABLE fund.alpaca_batch_orders IS
  'Daily net batch orders submitted to Alpaca. One row per stock per trading day. '
  'Stores full Alpaca JSON response for reconciliation. Append-only after filled.';

-- ============================================================================
-- SCHEMA: audit
-- PURPOSE: Immutable append-only event log. Captures WHO did WHAT, WHEN,
--          and FROM WHERE for every significant action in the system.
--          ACID: events are written in the SAME transaction as the data change.
--          No row is ever updated or deleted — this is a legal requirement.
-- RUN ORDER: 07
-- ============================================================================

SET search_path TO audit, public;

-- Main audit log — partitioned by month for performance at scale
CREATE TABLE IF NOT EXISTS audit.events (
  id              BIGSERIAL       NOT NULL,
    -- Sequential: guarantees ordering and is faster for time-range queries than UUID
  event_type      VARCHAR(100)    NOT NULL,
    -- Namespaced: 'user.registered', 'wallet.deposit.completed',
    -- 'trade.order.placed', 'auth.login.success', 'staker.position.added'
  severity        VARCHAR(10)     NOT NULL DEFAULT 'info'
                  CHECK (severity IN ('debug','info','warn','error','critical')),

  -- ── Who ───────────────────────────────────────────────────────────────────
  actor_user_id   UUID,
    -- NULL for system-generated events (nav_engine, scheduler)
  actor_role      VARCHAR(20),
    -- Snapshot of role at time of event
  actor_ip        INET,
  actor_user_agent TEXT,

  -- ── What ──────────────────────────────────────────────────────────────────
  target_type     VARCHAR(50),
    -- 'user', 'order', 'deposit', 'withdrawal', 'staker', 'nav'
  target_id       UUID,
    -- ID of the affected record
  payload         JSONB           NOT NULL DEFAULT '{}',
    -- Full context: old values, new values, request params
    -- Enables full audit reconstruction without joining other tables
  description     TEXT,
    -- Human-readable summary for audit log UI

  -- ── When / Where ──────────────────────────────────────────────────────────
  service_name    VARCHAR(50),
    -- 'auth-service', 'trade-service', 'nav-engine' etc.
  request_id      VARCHAR(100),
    -- Distributed trace request ID (correlates logs across services)
  created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

  PRIMARY KEY (id, created_at)  -- composite PK required for declarative partitioning

) PARTITION BY RANGE (created_at);

-- Create monthly partitions (add new ones monthly via scheduled script)
CREATE TABLE IF NOT EXISTS audit.events_2026_06 PARTITION OF audit.events
  FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');
CREATE TABLE IF NOT EXISTS audit.events_2026_07 PARTITION OF audit.events
  FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');
CREATE TABLE IF NOT EXISTS audit.events_2026_08 PARTITION OF audit.events
  FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
CREATE TABLE IF NOT EXISTS audit.events_2026_09 PARTITION OF audit.events
  FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');
CREATE TABLE IF NOT EXISTS audit.events_2026_10 PARTITION OF audit.events
  FOR VALUES FROM ('2026-10-01') TO ('2026-11-01');
CREATE TABLE IF NOT EXISTS audit.events_2026_11 PARTITION OF audit.events
  FOR VALUES FROM ('2026-11-01') TO ('2026-12-01');
CREATE TABLE IF NOT EXISTS audit.events_2026_12 PARTITION OF audit.events
  FOR VALUES FROM ('2026-12-01') TO ('2027-01-01');

-- Indexes on each partition (PostgreSQL propagates these automatically)
CREATE INDEX IF NOT EXISTS idx_audit_events_user_created
  ON audit.events(actor_user_id, created_at DESC)
  WHERE actor_user_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_audit_events_type_created
  ON audit.events(event_type, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_events_target
  ON audit.events(target_type, target_id, created_at DESC)
  WHERE target_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_audit_events_request_id
  ON audit.events(request_id)
  WHERE request_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_audit_events_severity
  ON audit.events(severity, created_at DESC)
  WHERE severity IN ('warn','error','critical');

-- ============================================================================
-- TABLE: audit.balance_snapshots
-- Written atomically WITH every wallet.accounts balance change.
-- Enables point-in-time balance reconstruction for reconciliation.
-- This is separate from wallet.ledger (which tracks changes) —
-- this records the RESULTING balance as a snapshot.
-- ============================================================================
CREATE TABLE IF NOT EXISTS audit.balance_snapshots (
  id                  BIGSERIAL       PRIMARY KEY,
  user_id             UUID            NOT NULL,
  account_id          UUID            NOT NULL,
  bse_balance         NUMERIC(20, 8)  NOT NULL,
  bse_in_transit      NUMERIC(20, 8)  NOT NULL,
  bse_reserved        NUMERIC(20, 8)  NOT NULL,
  total_portfolio_value NUMERIC(20, 8) NOT NULL,
  trigger_event       VARCHAR(100)    NOT NULL,
    -- What caused this snapshot: 'deposit', 'withdrawal', 'order_placed', 'nav_update'
  trigger_reference_id UUID,
    -- ID of the record that caused the balance change
  created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_audit_balance_snapshots_user
  ON audit.balance_snapshots(user_id, created_at DESC);

COMMENT ON TABLE audit.balance_snapshots IS
  'Point-in-time balance snapshots. Written atomically with every balance change. '
  'Enables reconciliation: query WHERE created_at <= <date> ORDER BY id DESC LIMIT 1 '
  'to reconstruct any user''s balance at any point in history.';

-- ============================================================================
-- TABLE: audit.nav_calculation_log
-- Full audit trail of every NAV engine run.
-- Written by nav_engine after each EOD batch.
-- ============================================================================
CREATE TABLE IF NOT EXISTS audit.nav_calculation_log (
  id                  UUID            PRIMARY KEY DEFAULT uuid_generate_v4(),
  nav_date            DATE            NOT NULL,
  token_id            UUID            NOT NULL,
  symbol              VARCHAR(12)     NOT NULL,
  engine_version      VARCHAR(20),
    -- nav_engine service version that ran this calculation
  input_snapshot      JSONB           NOT NULL,
    -- Complete inputs: stock price, pool shares, outstanding tokens etc.
  output_snapshot     JSONB           NOT NULL,
    -- Complete outputs: NAV, reserves, staking fees etc.
  orders_processed    INTEGER         NOT NULL DEFAULT 0,
    -- How many user orders were settled in this run
  execution_ms        INTEGER,
    -- How long the calculation took in milliseconds
  status              VARCHAR(20)     NOT NULL DEFAULT 'completed'
                      CHECK (status IN ('completed','failed','skipped')),
  error_details       TEXT,
  created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

  CONSTRAINT uq_nav_calc_log_token_date UNIQUE (token_id, nav_date)
);

COMMENT ON TABLE audit.nav_calculation_log IS
  'Complete audit trail of every NAV engine calculation. '
  'Input and output stored as JSON for full reproducibility. '
  'Required for dispute resolution and regulatory audit.';

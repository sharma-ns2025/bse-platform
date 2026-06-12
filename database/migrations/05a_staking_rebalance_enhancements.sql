-- ============================================================================
-- ENHANCEMENT: staking schema - Whale Staker Rebalance Audit Trail
-- PURPOSE: Track all rebalancing operations for whale stakers with full audit trail
--
-- This file extends staking schema with:
--   • staker_rebalance_history - complete audit trail of position changes
--   • alpaca_sync_logs - detailed Alpaca API sync records for troubleshooting
--   • staker_position_snapshots - daily position snapshots for reconciliation
--
-- RUN ORDER: After 05_staking_fund_audit_schemas.sql
-- ============================================================================

SET search_path TO staking, public;

-- ============================================================================
-- TABLE: staking.rebalance_history
-- Complete audit trail of ALL position changes for whale stakers.
-- Auto-rebalance: system-triggered when demand changes
-- Manual rebalance: staker or ops-triggered
-- Shows: old_qty → new_qty, why, when
-- ============================================================================
CREATE TABLE IF NOT EXISTS staking.rebalance_history (
  id                      UUID            PRIMARY KEY DEFAULT uuid_generate_v4(),
  staker_id               UUID            NOT NULL REFERENCES staking.staker_profiles(id),
  position_id             UUID            NOT NULL REFERENCES staking.positions(id),
  token_id                UUID            NOT NULL REFERENCES core.stock_tokens(id),
  symbol                  VARCHAR(12)     NOT NULL,

  -- ── Before Rebalance ──────────────────────────────────────────────────────
  qty_before              NUMERIC(20, 8)  NOT NULL,
    -- Previous staked_qty value
  matched_before          NUMERIC(20, 8)  NOT NULL,
    -- Previous matched_qty (shares currently matched to buyers)
  available_before        NUMERIC(20, 8)  GENERATED ALWAYS AS
    (qty_before - matched_before) STORED,
    -- Available for new buyers to purchase tokens against

  -- ── After Rebalance ───────────────────────────────────────────────────────
  qty_after               NUMERIC(20, 8)  NOT NULL,
    -- New staked_qty after rebalance
  matched_after           NUMERIC(20, 8)  NOT NULL,
    -- New matched_qty (usually unchanged unless partial liquidation)
  available_after         NUMERIC(20, 8)  GENERATED ALWAYS AS
    (qty_after - matched_after) STORED,

  qty_change              NUMERIC(20, 8)  GENERATED ALWAYS AS
    (qty_after - qty_before) STORED,
    -- Positive = added shares, Negative = removed shares

  -- ── Rebalance Trigger & Reason ────────────────────────────────────────────
  rebalance_reason        rebalance_reason_enum NOT NULL,
    -- daily_sync: periodic Alpaca reconciliation
    -- manual_rebalance: staker or ops manually adjusted
    -- auto_demand_adjust: system auto-adjusted due to platform demand change
    -- emergency_halt: emergency system halt/safety pause
    -- maintenance: platform maintenance rebalance
    -- position_liquidation: position was liquidated
  
  triggered_by            VARCHAR(50)     NOT NULL,
    -- 'automated_daily_sync', 'automated_demand_engine', 'staker_manual', 'ops_manual'
  
  operator_id             UUID REFERENCES auth.users(id),
    -- NULL if automated; set if manual by staker or ops
  
  -- ── Demand Context (captured at time of rebalance) ─────────────────────────
  demand_to_supply_ratio  NUMERIC(20, 8),
    -- Order book ratio at rebalance time (if auto-rebalance)
  platform_buy_orders_pending NUMERIC(20, 8),
    -- Total pending buy orders awaiting this stock's supply
  total_available_supply  NUMERIC(20, 8),
    -- Total supply across all stakers for this token

  -- ── Alpaca Integration ────────────────────────────────────────────────────
  alpaca_position_verified BOOLEAN         NOT NULL DEFAULT FALSE,
    -- TRUE = position verified against Alpaca broker account before applying
  alpaca_sync_id          UUID REFERENCES staking.alpaca_sync_logs(id),
    -- Reference to the Alpaca sync that triggered this (if applicable)
  alpaca_confirmed_at     TIMESTAMPTZ,

  -- ── Audit & Compliance ────────────────────────────────────────────────────
  audit_notes             TEXT,
    -- Why this rebalance happened, any special circumstances
  
  is_reversible           BOOLEAN         NOT NULL DEFAULT TRUE,
    -- FALSE = permanent change (e.g., after liquidation)
  reversal_id             UUID REFERENCES staking.rebalance_history(id),
    -- If this was a reversal of a previous rebalance, link to it

  created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW()
    -- Append-only: no updated_at
);

CREATE INDEX IF NOT EXISTS idx_rebalance_history_staker
  ON staking.rebalance_history(staker_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_rebalance_history_position
  ON staking.rebalance_history(position_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_rebalance_history_reason
  ON staking.rebalance_history(rebalance_reason, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_rebalance_history_timestamp
  ON staking.rebalance_history(created_at DESC);

COMMENT ON TABLE staking.rebalance_history IS
  'Complete audit trail for whale staker position rebalancing. Every change captured: '
  'qty_before/after, reason, who triggered, Alpaca verification status. '
  'Immutable record for compliance and troubleshooting. Used to answer: '
  '"Why did this staker''s position change on [date]?"';

-- ============================================================================
-- TABLE: staking.alpaca_sync_logs
-- Detailed logs of every Alpaca API sync operation.
-- Used for troubleshooting sync failures and auditing staker verifications.
-- ============================================================================
CREATE TABLE IF NOT EXISTS staking.alpaca_sync_logs (
  id                      UUID            PRIMARY KEY DEFAULT uuid_generate_v4(),
  staker_id               UUID            NOT NULL REFERENCES staking.staker_profiles(id),

  -- ── Sync Details ──────────────────────────────────────────────────────────
  sync_type               VARCHAR(20)     NOT NULL DEFAULT 'daily'
                          CHECK (sync_type IN ('daily', 'on_demand', 'emergency', 'verification')),
  
  sync_start_at           TIMESTAMPTZ     NOT NULL,
  sync_end_at             TIMESTAMPTZ,
    -- NULL until sync completes
  duration_seconds        NUMERIC(10, 3)  GENERATED ALWAYS AS
    (EXTRACT(EPOCH FROM (sync_end_at - sync_start_at))) STORED,

  -- ── API Results ───────────────────────────────────────────────────────────
  http_status_code        SMALLINT,
    -- 200 = success, 401 = auth failed, 429 = rate limited, 500 = server error
  
  positions_returned      INTEGER,
    -- Number of positions returned from Alpaca
  
  positions_validated     INTEGER,
    -- Number of positions successfully validated against staked positions
  
  validation_errors       INTEGER,
    -- Mismatches: Alpaca qty != staked qty
  
  api_response_data       JSONB,
    -- Full Alpaca API response (for debugging)
  
  error_message           TEXT,
    -- If sync failed, capture error text
  
  -- ── Outcome ───────────────────────────────────────────────────────────────
  status                  VARCHAR(20)     NOT NULL DEFAULT 'pending'
                          CHECK (status IN ('pending', 'in_progress', 'success', 'partial_success', 'failed')),
  
  -- ── Reconciliation Details ────────────────────────────────────────────────
  reconciliation_notes    TEXT,
    -- Summary of what was checked and any discrepancies
  
  was_reconciled          BOOLEAN         NOT NULL DEFAULT FALSE,
    -- TRUE = all positions matched, verified = TRUE set for staker
  
  reconciliation_issues   JSONB,
    -- {"issues": [{"token": "AAPL", "alpaca_qty": 100, "staked_qty": 95, "discrepancy": 5}]}

  synced_at               TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
  created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_alpaca_sync_staker
  ON staking.alpaca_sync_logs(staker_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_alpaca_sync_status
  ON staking.alpaca_sync_logs(status) WHERE status IN ('failed', 'partial_success');
CREATE INDEX IF NOT EXISTS idx_alpaca_sync_timestamp
  ON staking.alpaca_sync_logs(created_at DESC);

COMMENT ON TABLE staking.alpaca_sync_logs IS
  'Detailed Alpaca API sync logs for every staker verification. '
  'Records: request sent, response received, positions validated, any errors. '
  'Used to debug sync failures and audit the integrity of staker positions.';

-- ============================================================================
-- TABLE: staking.position_snapshots
-- Daily snapshots of each staker position.
-- Powers reconciliation and historical analysis.
-- One row per staker per token per date (append-only).
-- ============================================================================
CREATE TABLE IF NOT EXISTS staking.position_snapshots (
  id                      UUID            PRIMARY KEY DEFAULT uuid_generate_v4(),
  staker_id               UUID            NOT NULL REFERENCES staking.staker_profiles(id),
  position_id             UUID            NOT NULL REFERENCES staking.positions(id),
  token_id                UUID            NOT NULL REFERENCES core.stock_tokens(id),
  symbol                  VARCHAR(12)     NOT NULL,
  snapshot_date           DATE            NOT NULL,

  -- ── Position Snapshot ─────────────────────────────────────────────────────
  staked_qty              NUMERIC(20, 8)  NOT NULL,
    -- Snapshot of staker.positions.staked_qty on this date
  
  matched_qty             NUMERIC(20, 8)  NOT NULL,
    -- Snapshot of staker.positions.matched_qty on this date
  
  available_qty           NUMERIC(20, 8)  GENERATED ALWAYS AS
    (staked_qty - matched_qty) STORED,

  -- ── Alpaca Verification ──────────────────────────────────────────────────
  alpaca_verified_qty     NUMERIC(20, 8),
    -- Alpaca returned this qty for this position on snapshot_date
  
  verification_status     VARCHAR(20)
                          CHECK (verification_status IN ('verified', 'mismatch', 'not_checked', 'error')),
    -- verified = Alpaca qty matches staked_qty
    -- mismatch = Alpaca qty ≠ staked_qty (discrepancy)
    -- error = couldn't reach Alpaca

  verification_notes      TEXT,

  -- ── Financial Snapshot ───────────────────────────────────────────────────
  nav_price_usd           NUMERIC(20, 8),
    -- EOD NAV for this token on snapshot_date
  position_value_usd      NUMERIC(20, 8)  GENERATED ALWAYS AS
    (staked_qty * nav_price_usd) STORED,
    -- Total position value at NAV

  daily_rewards_earned_usd NUMERIC(20, 8),
    -- Rewards distributed to this position on snapshot_date

  -- ── Metadata ──────────────────────────────────────────────────────────────
  snapshot_at             TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
  created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

  -- One snapshot per staker per position per date
  CONSTRAINT uq_position_snapshot_daily UNIQUE (staker_id, position_id, snapshot_date)
);

CREATE INDEX IF NOT EXISTS idx_position_snapshots_staker_date
  ON staking.position_snapshots(staker_id, snapshot_date DESC);
CREATE INDEX IF NOT EXISTS idx_position_snapshots_position_date
  ON staking.position_snapshots(position_id, snapshot_date DESC);
CREATE INDEX IF NOT EXISTS idx_position_snapshots_verification
  ON staking.position_snapshots(verification_status) WHERE verification_status != 'verified';

COMMENT ON TABLE staking.position_snapshots IS
  'Daily position snapshots per staker per token. Immutable historical record. '
  'Used for reconciliation, reporting, and analyzing staker participation over time. '
  'Enables: "Show me this staker''s AAPL position history for the last 30 days."';

-- ============================================================================
-- TABLE: staking.reward_calculation_logs
-- Detailed logs of reward calculations per NAV run.
-- Powers audit trail: "Why did this staker earn $X on this date?"
-- ============================================================================
CREATE TABLE IF NOT EXISTS staking.reward_calculation_logs (
  id                      UUID            PRIMARY KEY DEFAULT uuid_generate_v4(),
  nav_date                DATE            NOT NULL,
  token_id                UUID            NOT NULL REFERENCES core.stock_tokens(id),
  symbol                  VARCHAR(12)     NOT NULL,

  -- ── Market Data ───────────────────────────────────────────────────────────
  nav_price_usd           NUMERIC(20, 8)  NOT NULL,
  total_matched_qty       NUMERIC(20, 8)  NOT NULL,
    -- Sum of all matched_qty for this token across all stakers
  total_trading_volume_usd NUMERIC(20, 8) NOT NULL,
    -- Total USD volume of trades for this token on nav_date
  total_expense_ratio_collected NUMERIC(20, 8) NOT NULL,
    -- Total fees collected from all orders for this token
  
  -- ── Reward Distribution ───────────────────────────────────────────────────
  staker_share_pct        NUMERIC(8, 6)   NOT NULL DEFAULT 0.70,
    -- Percentage of fees that goes to stakers (70% per project brief)
  total_staker_reward_pool NUMERIC(20, 8) NOT NULL,
    -- = total_expense_ratio_collected * staker_share_pct
  
  -- ── Distribution Per Staker ──────────────────────────────────────────────
  stakers_in_pool         INTEGER         NOT NULL,
    -- Number of stakers who had positions matched this day
  
  reward_calc_method      VARCHAR(50)     NOT NULL DEFAULT 'proportional_matched_qty'
                          CHECK (reward_calc_method IN ('proportional_matched_qty', 'equal_split', 'custom')),
    -- proportional_matched_qty = rewards split by each staker's matched_qty proportion
    -- equal_split = all stakers get equal share (fallback if no volume)
  
  calculation_notes       TEXT,

  -- ── Verification ─────────────────────────────────────────────────────────
  is_finalized            BOOLEAN         NOT NULL DEFAULT FALSE,
    -- FALSE = draft calculation, pending manual approval
    -- TRUE = calculation approved, rewards can be paid
  
  verified_by             UUID REFERENCES auth.users(id),
    -- Ops staff who reviewed and approved calculation
  verified_at             TIMESTAMPTZ,

  created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_reward_calc_logs_date
  ON staking.reward_calculation_logs(nav_date DESC);
CREATE INDEX IF NOT EXISTS idx_reward_calc_logs_token_date
  ON staking.reward_calculation_logs(token_id, nav_date DESC);
CREATE INDEX IF NOT EXISTS idx_reward_calc_logs_finalized
  ON staking.reward_calculation_logs(is_finalized) WHERE is_finalized = FALSE;

COMMENT ON TABLE staking.reward_calculation_logs IS
  'Detailed reward calculation logs per NAV per token. Captures: volumes, ratios, '
  'total pool, distribution method. Enables auditing: '
  '"Why did staker X earn $Y.ZZ on [date] for [token]?"';

-- ============================================================================
-- PERMISSION GRANTS
-- ============================================================================
ALTER DEFAULT PRIVILEGES IN SCHEMA staking GRANT SELECT, INSERT ON TABLES TO bse_app;
GRANT SELECT, INSERT ON staking.rebalance_history            TO bse_app;
GRANT SELECT, INSERT ON staking.alpaca_sync_logs             TO bse_app;
GRANT SELECT, INSERT ON staking.position_snapshots           TO bse_app;
GRANT SELECT, INSERT ON staking.reward_calculation_logs      TO bse_app;

-- Ops-only tables
GRANT SELECT, INSERT, UPDATE ON staking.reward_calculation_logs TO bse_migrate;

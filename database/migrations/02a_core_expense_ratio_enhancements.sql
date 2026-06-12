-- ============================================================================
-- ENHANCEMENT: core schema - Expense Ratio & Price Feed Management
-- PURPOSE: Add real-time expense ratio calculation tracking and intraday price caching
--
-- This file extends core schema with:
--   • expense_ratio_history - dynamic expense ratio per stock per day
--   • price_feed_cache - intraday prices from Alpaca (for UI display)
--   • expense_ratio_adjustments - track manual or emergency ratio changes
--
-- RUN ORDER: After 02_core_schema.sql (before trading)
-- ============================================================================

SET search_path TO core, public;

-- ============================================================================
-- TABLE: core.expense_ratio_history
-- Real-time expense ratio tracking per stock token per day.
-- Calculated dynamically based on order book supply/demand.
-- Figma p15 (Preview Order): shows expense ratio in order details.
-- ============================================================================
CREATE TABLE IF NOT EXISTS core.expense_ratio_history (
  id                      UUID            PRIMARY KEY DEFAULT uuid_generate_v4(),
  token_id                UUID            NOT NULL REFERENCES core.stock_tokens(id),
  symbol                  VARCHAR(12)     NOT NULL,
  nav_date                DATE            NOT NULL,

  -- ── Base Expense Ratio ────────────────────────────────────────────────────
  base_expense_ratio      NUMERIC(8, 6)   NOT NULL DEFAULT 0.01,
    -- Minimum ratio per project brief: 1%. Range: 1% - 5%
    -- Base is static unless manually adjusted by ops.

  -- ── Dynamic Supply/Demand Factors ─────────────────────────────────────────
  buy_volume_qty          NUMERIC(20, 8)  NOT NULL DEFAULT 0,
    -- Total BUY orders (in shares) pending execution or executed today
  sell_volume_qty         NUMERIC(20, 8)  NOT NULL DEFAULT 0,
    -- Total SELL orders (in shares) pending execution or executed today
  
  buy_pressure_score      NUMERIC(10, 4),
    -- Normalized: buy_volume / (buy_volume + sell_volume)
    -- 0.5 = balanced, >0.7 = heavy buying (raise ratio), <0.3 = heavy selling

  staker_supply_available_qty NUMERIC(20, 8),
    -- Sum of all staker positions.available_qty for this token
    -- Shows how many shares stakers have available to match
  
  pending_demand_qty      NUMERIC(20, 8),
    -- Sum of queued buy orders awaiting execution (orders.status = 'queued')
  
  demand_to_supply_ratio  NUMERIC(20, 8),
    -- pending_demand / staker_supply. >1 = undersubscribed, <1 = oversupplied
    -- Used by nav_engine to adjust applied_expense_ratio

  -- ── Applied Ratio (used for this day's orders) ────────────────────────────
  applied_expense_ratio   NUMERIC(8, 6)   NOT NULL,
    -- Final ratio applied to orders on nav_date
    -- = base_ratio + demand_adjustment
    -- Example: 0.01 base + 0.015 demand_adj = 0.025 (2.5%)
  
  demand_adjustment_pct   NUMERIC(8, 6)   NOT NULL DEFAULT 0,
    -- Percentage point adjustment: 0.005 = +0.5%
    -- Applied based on demand_to_supply_ratio
    -- Formula: demand_adj = 0.04 * (demand_supply_ratio - 1), capped at 0.04

  applied_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    -- When this ratio was activated

  -- ── Volume & Revenue Tracking ─────────────────────────────────────────────
  executed_buy_qty        NUMERIC(20, 8)  NOT NULL DEFAULT 0,
    -- Actual BUY orders executed (filled) today
  executed_sell_qty       NUMERIC(20, 8)  NOT NULL DEFAULT 0,
    -- Actual SELL orders executed (filled) today
  executed_trade_volume_usd NUMERIC(20, 8) NOT NULL DEFAULT 0,
    -- Total USD value of executed trades (buy + sell)
  total_fee_revenue_usd   NUMERIC(20, 8)  NOT NULL DEFAULT 0,
    -- Total expense ratio fees collected from orders on this stock today
    -- = sum(order.executed_total_usd * applied_expense_ratio) for each order

  -- ── Staker Reward Distribution ────────────────────────────────────────────
  staker_reward_pool_usd  NUMERIC(20, 8)  NOT NULL DEFAULT 0,
    -- Total pool of fees available for staker distribution (70% of total_fee_revenue)
    -- Distributed to stakers based on their matched_qty

  last_updated_at         TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
  created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
  updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

  -- One ratio per token per day (only one "official" rate per trading day)
  CONSTRAINT uq_expense_ratio_token_date UNIQUE (token_id, nav_date)
);

CREATE TRIGGER trg_core_expense_ratio_updated_at
  BEFORE UPDATE ON core.expense_ratio_history
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE INDEX IF NOT EXISTS idx_core_expense_ratio_token_date
  ON core.expense_ratio_history(token_id, nav_date DESC);
CREATE INDEX IF NOT EXISTS idx_core_expense_ratio_date
  ON core.expense_ratio_history(nav_date DESC);
CREATE INDEX IF NOT EXISTS idx_core_expense_ratio_active
  ON core.expense_ratio_history(nav_date DESC) WHERE nav_date = CURRENT_DATE;

COMMENT ON TABLE core.expense_ratio_history IS
  'Real-time expense ratio per stock token per day. Calculated dynamically based on '
  'order book supply/demand. Range: 1% - 5%. Higher demand = higher ratio = better staker rewards. '
  'Figma p15 (Preview Order) displays applied_expense_ratio to user before order confirmation.';
COMMENT ON COLUMN core.expense_ratio_history.demand_to_supply_ratio IS
  'Ratio > 1 indicates more buyers than staker supply available. nav_engine increases '
  'expense_ratio to incentivize more stakers. Example: ratio=2.0 → add 0.04 to base ratio.';

-- ============================================================================
-- TABLE: core.price_feed_cache
-- Intraday price caching from Alpaca market data API.
-- Refreshed frequently (every 5-15 min), used for UI display only.
-- NOT used for NAV calculations (those use nav_price_history).
-- Figma p12 (Stock Detail): shows "AAPL $190.40" current price from this table.
-- ============================================================================
CREATE TABLE IF NOT EXISTS core.price_feed_cache (
  id                      UUID            PRIMARY KEY DEFAULT uuid_generate_v4(),
  token_id                UUID            NOT NULL REFERENCES core.stock_tokens(id) ON DELETE CASCADE,
  symbol                  VARCHAR(12)     NOT NULL,
  base_ticker             VARCHAR(12)     NOT NULL,

  -- Alpaca real-time market data
  last_trade_price        NUMERIC(20, 8)  NOT NULL,
    -- Most recent trade price (Figma p12: "AAPL $190.40")
  bid_price               NUMERIC(20, 8),
    -- Current best bid (shown in Figma p14 as "Bid")
  ask_price               NUMERIC(20, 8),
    -- Current best ask (shown in Figma p14 as "Ask")
  bid_ask_spread          NUMERIC(20, 8)  GENERATED ALWAYS AS (ask_price - bid_price) STORED,
    -- Figma p14: shows spread

  volume_today            NUMERIC(20, 8)  NOT NULL DEFAULT 0,
    -- Today's total volume (shown in Figma p12: "Volume: 2.4M")
  volume_avg_30d          NUMERIC(20, 8),
    -- 30-day average volume (for comparison)

  day_high                NUMERIC(20, 8),
    -- Today's high (Figma p14: "Day High: $192.15")
  day_low                 NUMERIC(20, 8),
    -- Today's low (Figma p14: "Day Low: $188.50")
  
  day_change_amount       NUMERIC(20, 8)  GENERATED ALWAYS AS (last_trade_price - day_open_price) STORED,
    -- Dollar change today (Figma p10: "+$3.25")
  day_change_pct          NUMERIC(10, 6)  GENERATED ALWAYS AS (
    CASE WHEN day_open_price = 0 THEN 0
    ELSE ((last_trade_price - day_open_price) / day_open_price) * 100
    END
  ) STORED,
    -- Percentage change today (Figma p10: "+1.73%")

  day_open_price          NUMERIC(20, 8),
    -- Day's opening price
  previous_close_price    NUMERIC(20, 8),
    -- Yesterday's closing price

  -- Timestamp
  quote_timestamp         TIMESTAMPTZ     NOT NULL,
    -- When Alpaca provided this quote
  synced_at               TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    -- When we cached it in DB

  created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
  updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

  -- One latest price per token (overwrites on each sync)
  CONSTRAINT uq_price_feed_token UNIQUE (token_id)
);

CREATE TRIGGER trg_core_price_feed_updated_at
  BEFORE UPDATE ON core.price_feed_cache
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE INDEX IF NOT EXISTS idx_price_feed_updated
  ON core.price_feed_cache(updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_price_feed_symbol
  ON core.price_feed_cache(symbol);

COMMENT ON TABLE core.price_feed_cache IS
  'Intraday price cache from Alpaca market data API. Refreshed every 5-15 minutes. '
  'Used for UI display only (Figma p12, p14). NOT used for NAV calculations. '
  'last_trade_price shows current market price; day_change_pct shows today''s movement.';

-- ============================================================================
-- TABLE: core.expense_ratio_adjustments
-- Manual or emergency expense ratio adjustments made by ops team.
-- Audit trail for compliance: why was ratio changed, when, by whom?
-- ============================================================================
CREATE TABLE IF NOT EXISTS core.expense_ratio_adjustments (
  id                      UUID            PRIMARY KEY DEFAULT uuid_generate_v4(),
  token_id                UUID            NOT NULL REFERENCES core.stock_tokens(id),
  symbol                  VARCHAR(12)     NOT NULL,
  
  -- Previous and new ratio
  previous_ratio          NUMERIC(8, 6)   NOT NULL,
  new_ratio               NUMERIC(8, 6)   NOT NULL,
    -- Validation: new_ratio must be 0.01 - 0.05 (1% - 5%)
  
  -- Reason for adjustment
  adjustment_reason       rebalance_reason_enum NOT NULL,
    -- daily_sync, manual_rebalance, auto_demand_adjust, emergency_halt, maintenance
  
  triggered_by            VARCHAR(50),
    -- 'automated_nav_engine', 'ops_manual', 'emergency_system'
  
  operator_id             UUID REFERENCES auth.users(id),
    -- NULL if automated; set if manual by ops staff
  
  audit_notes             TEXT,
    -- Why this adjustment was made (compliance documentation)

  effective_at            TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
  created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_expense_adjustments_token
  ON core.expense_ratio_adjustments(token_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_expense_adjustments_timestamp
  ON core.expense_ratio_adjustments(effective_at DESC);

COMMENT ON TABLE core.expense_ratio_adjustments IS
  'Audit trail for expense ratio changes. Captures: previous ratio, new ratio, '
  'reason, timestamp, who made the change. Used for compliance review and troubleshooting. '
  'Emergency adjustments (e.g., to halt trading) are documented here.';

-- ============================================================================
-- VIEWS: Expense Ratio Real-Time API
-- ============================================================================

-- Get current expense ratio for a specific token
CREATE OR REPLACE VIEW core.v_current_expense_ratios AS
SELECT
  h.token_id,
  h.symbol,
  h.nav_date,
  h.base_expense_ratio,
  h.applied_expense_ratio,
  h.demand_to_supply_ratio,
  h.applied_at,
  h.total_fee_revenue_usd,
  h.staker_reward_pool_usd
FROM core.expense_ratio_history h
WHERE h.nav_date = CURRENT_DATE
ORDER BY h.symbol;

COMMENT ON VIEW core.v_current_expense_ratios IS
  'Current expense ratios for today''s trades. Used by trading engine '
  'to calculate fees for orders, and by frontend to display in order preview (Figma p15).';

-- Get historical expense ratios for charting (last 30 days)
CREATE OR REPLACE VIEW core.v_expense_ratio_history_30d AS
SELECT
  h.token_id,
  h.symbol,
  h.nav_date,
  h.base_expense_ratio,
  h.applied_expense_ratio,
  h.demand_to_supply_ratio,
  h.executed_trade_volume_usd,
  h.total_fee_revenue_usd
FROM core.expense_ratio_history h
WHERE h.nav_date >= (CURRENT_DATE - INTERVAL '30 days')
ORDER BY h.symbol, h.nav_date DESC;

COMMENT ON VIEW core.v_expense_ratio_history_30d IS
  'Expense ratio history for last 30 days. Used for charting trends, '
  'analyzing staker reward volatility, and understanding platform dynamics.';

-- ============================================================================
-- PERMISSION GRANTS
-- ============================================================================
ALTER DEFAULT PRIVILEGES IN SCHEMA core GRANT SELECT, INSERT, UPDATE ON TABLES TO bse_app;
GRANT SELECT, INSERT, UPDATE ON core.expense_ratio_history           TO bse_app;
GRANT SELECT, INSERT, UPDATE ON core.price_feed_cache                TO bse_app;
GRANT SELECT, INSERT ON core.expense_ratio_adjustments                TO bse_app;
GRANT SELECT ON core.v_current_expense_ratios                         TO bse_app;
GRANT SELECT ON core.v_expense_ratio_history_30d                      TO bse_app;

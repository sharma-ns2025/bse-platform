-- ============================================================================
-- SCHEMA: trading
-- PURPOSE: All order management, portfolio holdings, and trade execution.
--
-- FIGMA SCREENS COVERED:
--   • Page 10 (Dashboard): Your Holdings table — Stock, Shares, Avg Price,
--     Current, Total Value, Gain/Loss. Portfolio Stats (Total Stocks: 4,
--     Total Shares: 205, Transactions: 4). Portfolio Performance chart.
--   • Page 12 (Stock Detail): Buy Stock panel — Trading balance, Investment
--     Total slider (50%), Buy Price, Quantity, Total, Transaction Fee
--   • Page 14 (Trade Detail): Current Position (50 shares, Avg cost $185.30,
--     Total value $9,520.00), Action/Quantity/Price type/Limit/Duration fields,
--     Estimated Total, Remaining buying power. Snapshot/Positions/Orders tabs.
--   • Page 15 (Preview Order): BUY 1 SHARES AAPL, Limit, Good for day,
--     Account ****-2724, All or None: No, Principal $190.40, Commission $0.00,
--     Estimated Total $190.40. "Buying power will decrease from $5,214 to $5,023"
--
-- RUN ORDER: 04 (after 03_wallet_schema.sql)
-- ============================================================================

SET search_path TO trading, public;

-- ============================================================================
-- TABLE: trading.orders
-- Every buy/sell order placed by a user. Status lifecycle:
-- draft → pending → queued → executed | failed | cancelled
-- ============================================================================
CREATE TABLE IF NOT EXISTS trading.orders (
  id                      UUID            PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id                 UUID            NOT NULL REFERENCES auth.users(id),
  account_id              UUID            NOT NULL REFERENCES wallet.accounts(id),
  token_id                UUID            NOT NULL REFERENCES core.stock_tokens(id),
  symbol                  VARCHAR(12)     NOT NULL,
    -- Denormalized from stock_tokens for fast order history queries

  -- ── Order Intent ─────────────────────────────────────────────────────────
  side                    order_side_enum NOT NULL,
    -- Figma p12/p14: "Buy" / "Sell" toggle
  price_type              order_price_type_enum NOT NULL DEFAULT 'market',
    -- Figma p14: "Price type" field — 'market' or 'limit'
  duration                order_duration_enum   NOT NULL DEFAULT 'good_for_day',
    -- Figma p14/p15: "Duration: Good for day"

  -- ── Requested Amounts ─────────────────────────────────────────────────────
  requested_qty           NUMERIC(20, 8)  NOT NULL CHECK (requested_qty > 0),
    -- Figma p12: "Quantity: 10" | p14: "6" | p15: "BUY 1 SHARES"
  limit_price             NUMERIC(20, 8),
    -- Figma p14: "Limit price: 190.40" — only set for limit orders
    -- NULL for market orders
  investment_total_usd    NUMERIC(20, 8),
    -- Figma p12: "Investment Total: $5,000.00" — user can set dollar amount
    -- and qty is derived: qty = investment_total / buy_price
  pct_of_balance          NUMERIC(5, 2),
    -- Figma p12: slider at "50%" of trading balance
  is_all_or_none          BOOLEAN         NOT NULL DEFAULT FALSE,
    -- Figma p15: "All or None: No"

  -- ── Estimated Values (shown in Preview Order before confirmation) ──────────
  estimated_nav_usd       NUMERIC(20, 8),
    -- NAV at time of order submission (used for preview display)
  estimated_total_usd     NUMERIC(20, 8),
    -- Figma p15: "Estimated Total: $190.40" = shares × price
  estimated_principal_usd NUMERIC(20, 8),
    -- Figma p15: "Estimated Principal: $190.40"
  buying_power_before_usd NUMERIC(20, 8),
    -- Figma p15: "Buying power will decrease from $5,214.00..."
  buying_power_after_usd  NUMERIC(20, 8),
    -- Figma p15: "...to $5,023.60"

  -- ── Fee Breakdown ─────────────────────────────────────────────────────────
  platform_fee_usd        NUMERIC(20, 8)  NOT NULL DEFAULT 0,
    -- Figma p12/p15: "Transaction Fee: $0", "Commission: $0.00" currently
  expense_ratio           NUMERIC(8, 6),
    -- Snapshot of expense ratio at order time
  expense_ratio_fee_usd   NUMERIC(20, 8),
    -- Dollar amount of expense ratio charged

  -- ── Execution Results (populated by nav_engine at EOD) ────────────────────
  executed_qty            NUMERIC(20, 8),
    -- Actual quantity filled (may be < requested for partial fills)
  executed_nav_usd        NUMERIC(20, 8),
    -- The EOD NAV price used for execution
  executed_total_usd      NUMERIC(20, 8),
    -- = executed_qty * executed_nav_usd
  alpaca_order_ref        VARCHAR(100),
    -- Alpaca order ID from the pooled batch order
  nav_date                DATE,
    -- Which EOD batch this order was processed in

  -- ── Status ────────────────────────────────────────────────────────────────
  status                  order_status_enum NOT NULL DEFAULT 'pending',
    -- draft = "Save for later" (Figma p14)
    -- pending = submitted, awaiting EOD batch
    -- queued = in today's batch
    -- executed = filled at NAV
    -- cancelled / failed / partial
  failure_reason          TEXT,

  -- ── Brokerage Account Reference ───────────────────────────────────────────
  brokerage_account_mask  VARCHAR(10),
    -- Figma p14/p15: "Account: xxxxxxx" / "****-2724"
    -- Masked account number for display

  created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
  updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
  executed_at             TIMESTAMPTZ
);

CREATE TRIGGER trg_trading_orders_updated_at
  BEFORE UPDATE ON trading.orders
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE INDEX IF NOT EXISTS idx_trading_orders_user_id       ON trading.orders(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_trading_orders_token_id      ON trading.orders(token_id);
CREATE INDEX IF NOT EXISTS idx_trading_orders_status_batch  ON trading.orders(status, nav_date) WHERE status IN ('pending','queued');
CREATE INDEX IF NOT EXISTS idx_trading_orders_symbol        ON trading.orders(symbol, created_at DESC);

COMMENT ON TABLE trading.orders IS
  'All buy/sell orders. "draft" = saved for later (Figma p14). '
  'Orders execute at EOD NAV price. status=queued means locked into today batch; '
  'funds reserved in wallet.accounts.bse_reserved.';

-- ============================================================================
-- TABLE: trading.holdings
-- Current token holdings per user per stock.
-- This is the denormalized "position" shown in Figma p10 "Your Holdings" table.
-- Updated atomically every time an order executes or NAV refreshes.
-- ============================================================================
CREATE TABLE IF NOT EXISTS trading.holdings (
  id                      UUID            PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id                 UUID            NOT NULL REFERENCES auth.users(id),
  token_id                UUID            NOT NULL REFERENCES core.stock_tokens(id),
  symbol                  VARCHAR(12)     NOT NULL,

  -- ── Position ──────────────────────────────────────────────────────────────
  qty                     NUMERIC(20, 8)  NOT NULL DEFAULT 0
                          CHECK (qty >= 0),
    -- Figma p10 Holdings: "25 shares", "50 shares", "100 shares", "30 shares"
    -- 0 = position closed (row kept for history)
  avg_cost_per_token      NUMERIC(20, 8)  NOT NULL DEFAULT 0,
    -- Figma p10: "Avg Price: $165.50", "$350.20", "$138.40", "$251.30"
    -- Weighted average: recalculated on every buy using:
    -- new_avg = (old_qty * old_avg + new_qty * price) / (old_qty + new_qty)
  total_cost_basis        NUMERIC(20, 8)  NOT NULL DEFAULT 0,
    -- = sum of all buy executions. Used for realized gain/loss calculation.

  -- ── Current Value (refreshed by nav_engine daily) ─────────────────────────
  current_nav_per_token   NUMERIC(20, 8)  NOT NULL DEFAULT 0,
    -- Figma p10: "Current: $178.25", "$378.91", "$141.80", "$242.84"
  current_value_usd       NUMERIC(20, 8)  NOT NULL DEFAULT 0,
    -- Figma p10: "Total Value: $4,456.25", "$18,945.50", "$14,180.00", "$7,285.20"
    -- = qty * current_nav_per_token

  -- ── Gain/Loss (all computed columns, auto-maintained) ─────────────────────
  unrealized_gain_usd     NUMERIC(20, 8)  GENERATED ALWAYS AS
    (qty * current_nav_per_token - total_cost_basis) STORED,
    -- Figma p10: "+$318.75", "+$1,435.50", "+$340.00", "-$253.80"
  unrealized_gain_pct     NUMERIC(10, 6)  GENERATED ALWAYS AS (
    CASE WHEN total_cost_basis = 0 THEN 0
    ELSE ((qty * current_nav_per_token - total_cost_basis) / total_cost_basis) * 100
    END
  ) STORED,
    -- Figma p10: "+7.71%", "+8.19%", "+2.46%", "-3.37%"
  daily_gain_usd          NUMERIC(20, 8)  NOT NULL DEFAULT 0,
    -- Gain today only (vs yesterday's NAV). Updated by nav_engine.
    -- Figma p10: "+$1,840.45 (4.28%) Today" in portfolio header

  -- ── Realized P&L (updated when sell executes) ─────────────────────────────
  realized_gain_usd       NUMERIC(20, 8)  NOT NULL DEFAULT 0,
    -- Cumulative realized profit/loss from all historical sells of this token

  first_bought_at         TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
  last_traded_at          TIMESTAMPTZ,
  updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

  -- One holdings row per user per token
  CONSTRAINT uq_trading_holdings_user_token UNIQUE (user_id, token_id)
);

CREATE TRIGGER trg_trading_holdings_updated_at
  BEFORE UPDATE ON trading.holdings
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE INDEX IF NOT EXISTS idx_trading_holdings_user_id  ON trading.holdings(user_id);
CREATE INDEX IF NOT EXISTS idx_trading_holdings_token_id ON trading.holdings(token_id);
CREATE INDEX IF NOT EXISTS idx_trading_holdings_active   ON trading.holdings(user_id) WHERE qty > 0;

COMMENT ON TABLE trading.holdings IS
  'Current user holdings per token. Figma p10 "Your Holdings" table. '
  'unrealized_gain_usd/pct are generated columns — auto-computed by DB. '
  'Weighted avg cost updated on every buy execution.';

-- ============================================================================
-- TABLE: trading.portfolio_snapshots
-- Daily portfolio value snapshot per user.
-- Powers the "Portfolio Performance" chart (Figma p10, 1D/1W/6M/1Y tabs).
-- Append-only — one row per user per date.
-- ============================================================================
CREATE TABLE IF NOT EXISTS trading.portfolio_snapshots (
  id                  UUID            PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id             UUID            NOT NULL REFERENCES auth.users(id),
  snapshot_date       DATE            NOT NULL,

  -- ── Balances at EOD ───────────────────────────────────────────────────────
  bse_balance         NUMERIC(20, 8)  NOT NULL DEFAULT 0,
    -- Available BSE tokens (cash equivalent)
  total_invested_usd  NUMERIC(20, 8)  NOT NULL DEFAULT 0,
    -- Sum of all holdings at this day's NAV
  total_portfolio_value NUMERIC(20, 8) NOT NULL DEFAULT 0,
    -- = bse_balance + total_invested_usd
    -- Figma p10 chart: y-axis values (~$30,000 to $60,000)

  -- ── Daily Movement ────────────────────────────────────────────────────────
  day_gain_usd        NUMERIC(20, 8)  NOT NULL DEFAULT 0,
  day_gain_pct        NUMERIC(10, 6)  NOT NULL DEFAULT 0,
    -- Figma p10: "+1840.45 (4.28%) Today"

  -- ── Position Summary (for Portfolio Stats widget) ─────────────────────────
  total_stocks_held   SMALLINT        NOT NULL DEFAULT 0,
    -- Figma p10: "Total Stocks: 4"
  total_shares_held   NUMERIC(20, 8)  NOT NULL DEFAULT 0,
    -- Figma p10: "Total Shares: 205"
  total_transactions  INTEGER         NOT NULL DEFAULT 0,
    -- Figma p10: "Transactions: 4"

  calculated_at       TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

  CONSTRAINT uq_portfolio_snapshot_user_date UNIQUE (user_id, snapshot_date)
);

CREATE INDEX IF NOT EXISTS idx_trading_snapshots_user_date ON trading.portfolio_snapshots(user_id, snapshot_date DESC);

COMMENT ON TABLE trading.portfolio_snapshots IS
  'Daily EOD portfolio value snapshot per user. Powers performance chart (Figma p10). '
  'Append-only. Chart range tabs (1D/1W/6M/1Y) query with different date offsets.';

-- ============================================================================
-- TABLE: trading.positions
-- Figma p14: "Positions (1)" tab — shows current open positions in trade view.
-- This is a read-optimized summary of trading.holdings for the trade panel.
-- Refreshed on holdings change.
-- ============================================================================
CREATE TABLE IF NOT EXISTS trading.positions (
  id                  UUID            PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id             UUID            NOT NULL REFERENCES auth.users(id),
  token_id            UUID            NOT NULL REFERENCES core.stock_tokens(id),
  symbol              VARCHAR(12)     NOT NULL,

  -- Figma p14 Current Position section:
  shares_owned        NUMERIC(20, 8)  NOT NULL DEFAULT 0,
    -- "50 shares"
  avg_cost            NUMERIC(20, 8)  NOT NULL DEFAULT 0,
    -- "Avg. cost $185.30"
  total_value         NUMERIC(20, 8)  NOT NULL DEFAULT 0,
    -- "Total value $9,520.00"

  -- Figma p14 Snapshot tab stats:
  net_account_value   NUMERIC(20, 8),
    -- "$10,420.55"
  cash_purchasing_power NUMERIC(20, 8),
    -- "Cash Purchasing Power: $5,214.00"
  settled_balance     NUMERIC(20, 8),
    -- "Settled: $5,214.00"
  unsettled_balance   NUMERIC(20, 8),
    -- "Unsettled: $0.00"

  last_refreshed_at   TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

  CONSTRAINT uq_trading_positions_user_token UNIQUE (user_id, token_id)
);

CREATE TRIGGER trg_trading_positions_updated_at
  BEFORE UPDATE ON trading.positions
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE INDEX IF NOT EXISTS idx_trading_positions_user_id ON trading.positions(user_id);

COMMENT ON TABLE trading.positions IS
  'Trade-panel position view (Figma p14 "Positions" tab). '
  'Read-optimized denormalization of trading.holdings for fast trade UI load.';

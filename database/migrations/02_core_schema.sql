-- ============================================================================
-- SCHEMA: core
-- PURPOSE: Stock tokens, real-time market metadata, NAV price history,
--          and user watchlists. This is the "market data" layer.
--
-- FIGMA SCREENS COVERED:
--   • Page 10 (Dashboard): Watchlist widget — symbol, price, % change
--   • Page 12 (Stock Detail): AAPL $190.40, candlestick chart, About section
--     Market Cap, P/E Ratio, Dividend Yield, Volume, Key Metrics, Company Info
--   • Page 13 (Trade Stocks): All Stocks list — symbol, sector, price,
--     change, market cap, volume, starred watchlist
--   • Page 14 (Trade Detail): Current Position snapshot, bid/ask/spread,
--     Day's range, Dividend info, Snapshot/Positions/Orders tabs
--
-- IMPORTANT: current_nav_per_token changes DAILY (EOD batch).
--            Intraday display prices come from Alpaca market data API,
--            cached in Redis/DynamoDB — NOT from this table.
--
-- RUN ORDER: 02 (after 01_auth_schema.sql)
-- ============================================================================

SET search_path TO core, public;

-- ============================================================================
-- TABLE: core.stock_tokens
-- Master list of tradeable BSE stock tokens.
-- One row per listed stock (AAPL-T, MSFT-T, TSLA-T etc.)
-- NAV price is updated once per trading day by the nav_engine service.
-- ============================================================================
CREATE TABLE IF NOT EXISTS core.stock_tokens (
  id                      UUID            PRIMARY KEY DEFAULT uuid_generate_v4(),

  -- ── Token Identity ────────────────────────────────────────────────────────
  symbol                  VARCHAR(12)     NOT NULL UNIQUE,
    -- BSE internal symbol e.g. 'AAPL-T'. The '-T' suffix = BSE Token.
    -- Separates BSE tokens from real-world tickers to avoid confusion.
  base_ticker             VARCHAR(12)     NOT NULL,
    -- Real-world exchange ticker e.g. 'AAPL', 'MSFT', 'GOOGL'
  company_name            VARCHAR(255)    NOT NULL,
    -- Figma p12: "Apple Inc." full name displayed on stock detail page
  description             TEXT,
    -- Figma p12: "Apple Inc. designs, manufactures, and markets smartphones..."

  -- ── Classification (Figma p13: "Sector" column, p12: "Technology" badge) ─
  sector                  VARCHAR(100),
    -- "Technology", "Consumer Cyclical", "Communication Services", "Healthcare"
  industry                VARCHAR(100),
    -- More granular: "Consumer Electronics", "Software—Application" etc.
  exchange                VARCHAR(20)     NOT NULL DEFAULT 'NASDAQ',
    -- Figma p12: "Nasdaq • Apple Inc." header. 'NASDAQ', 'NYSE', 'LSE' etc.
  country_code            CHAR(2)         NOT NULL DEFAULT 'US',

  -- ── Company Metadata (Figma p12: Company Information section) ─────────────
  ceo                     VARCHAR(100),
    -- Figma p12: "Tim Cook"
  founded_year            SMALLINT,
    -- Figma p12: "1976"
  headquarters            VARCHAR(200),
    -- Figma p12: "Cupertino, California"
  employee_count          INTEGER,
    -- Figma p12: "161,000"
  website_url             TEXT,
    -- Figma p12: "Official Website" external link
  investor_relations_url  TEXT,
    -- Figma p12: "Investor Relations" external link
  sec_filings_url         TEXT,
    -- Figma p12: "SEC Filings" external link
  logo_url                TEXT,
    -- URL to company logo image (shown in Figma p12/p13 stock list)

  -- ── Current NAV Price (updated daily by nav_engine) ──────────────────────
  current_nav_per_token   NUMERIC(20, 8)  NOT NULL DEFAULT 0,
    -- Figma p10: "$178.25" next to AAPL in watchlist
    -- This is the BSE token price, not the raw stock price
  previous_nav_per_token  NUMERIC(20, 8),
    -- Yesterday's NAV — used to calculate daily % change displayed in UI
  nav_change_amount       NUMERIC(20, 8)  GENERATED ALWAYS AS
    (current_nav_per_token - COALESCE(previous_nav_per_token, current_nav_per_token)) STORED,
    -- Figma p10: "+$1.58" change amount — auto-computed
  nav_change_pct          NUMERIC(10, 6)  GENERATED ALWAYS AS (
    CASE WHEN COALESCE(previous_nav_per_token, 0) = 0 THEN 0
    ELSE ((current_nav_per_token - previous_nav_per_token) / previous_nav_per_token) * 100
    END
  ) STORED,
    -- Figma p10: "+0.84%" — auto-computed percentage
  nav_last_updated_at     TIMESTAMPTZ,

  -- ── Market Data Snapshot (from Alpaca, refreshed intraday) ───────────────
  -- These are cached here for fast dashboard loads (< 1s target).
  -- Source of truth is Alpaca API; this is a denormalized cache.
  last_market_price       NUMERIC(20, 8),
    -- Figma p12: "$190.40" — actual market price (different from NAV token price)
  bid_price               NUMERIC(20, 8),
    -- Figma p14: "Bid × size: $190.35 × 200"
  bid_size                INTEGER,
  ask_price               NUMERIC(20, 8),
    -- Figma p14: "Ask × size: $190.45 × 150"
  ask_size                INTEGER,
  bid_ask_spread          NUMERIC(10, 6),
    -- Figma p14: "Bid/Ask spread: $0.10 (0.053%)"
  day_range_low           NUMERIC(20, 8),
    -- Figma p14: "Day's range: 187.50 – 191.20"
  day_range_high          NUMERIC(20, 8),
  volume                  BIGINT,
    -- Figma p13: "Volume: 52.4M" — shown in stock list table
  market_cap_usd          NUMERIC(30, 2),
    -- Figma p13: "$2.95T", p12: "Market Cap: $2.95T"
  market_cap_display      VARCHAR(20),
    -- Pre-formatted: "$2.95T", "$789.2B" — avoids recalculating on frontend

  -- ── Financial Ratios (Figma p12: Key Metrics section) ────────────────────
  pe_ratio                NUMERIC(10, 4),
    -- Figma p12: "P/E Ratio: 31.20"
  dividend_yield_pct      NUMERIC(8, 4),
    -- Figma p12: "Dividend Yield: 0.52%"
  dividend_amount         NUMERIC(10, 4),
    -- Figma p14: "Dividend yield/amount: 0.52%/0.00"
  ex_dividend_date        DATE,
    -- Figma p14: "Ex-dividend date: 11/10/2025"
  dividend_payable_date   DATE,
    -- Figma p14: "Dividend payable date: 11/21/2025"
  week_52_high            NUMERIC(20, 8),
    -- Figma p12: "52-Week High: $199.62"
  week_52_low             NUMERIC(20, 8),
    -- Figma p12: "52-Week Low: $164.08"
  revenue_usd             NUMERIC(30, 2),
    -- Figma p12: "Revenue: $383.3B"
  net_income_usd          NUMERIC(30, 2),
    -- Figma p12: "Net Income: $97.0B"
  eps                     NUMERIC(10, 4),
    -- Figma p12: "EPS: $6.13"

  -- ── Price Performance (Figma p12: Price Performance section) ─────────────
  perf_1d_pct             NUMERIC(8, 4),  -- "+1.24%"
  perf_7d_pct             NUMERIC(8, 4),  -- "+2.84%"
  perf_30d_pct            NUMERIC(8, 4),  -- "+8.45%"
  perf_1y_pct             NUMERIC(8, 4),  -- "+32.18%"

  -- ── Pool / Staking Stats ──────────────────────────────────────────────────
  total_tokens_issued     NUMERIC(20, 8)  NOT NULL DEFAULT 0,
    -- Total BSE token units outstanding (equivalent to fund shares)
  total_staked_qty        NUMERIC(20, 8)  NOT NULL DEFAULT 0,
    -- Total real shares staked by all stakers for this symbol
  available_supply        NUMERIC(20, 8)  NOT NULL DEFAULT 0,
    -- Staked qty not yet matched to token buyers (staked - issued)
  current_expense_ratio   NUMERIC(8, 6)   NOT NULL DEFAULT 0.01
                          CHECK (current_expense_ratio >= 0.01 AND current_expense_ratio <= 0.05),
    -- Min 1%, max 5%, demand-driven. Formula: 0.01 + (issued/staked * 0.04)

  -- ── Listing State ─────────────────────────────────────────────────────────
  is_active               BOOLEAN         NOT NULL DEFAULT TRUE,
    -- FALSE = delisted, no new buy orders accepted
  is_featured             BOOLEAN         NOT NULL DEFAULT FALSE,
    -- Figma p10 Dashboard Watchlist: pre-populated featured stocks
  market_status           VARCHAR(20)     NOT NULL DEFAULT 'closed'
                          CHECK (market_status IN ('open', 'closed', 'pre_market', 'after_hours', 'halted')),
    -- Figma p14: "● Market Open" green indicator
  market_last_refreshed_at TIMESTAMPTZ,

  created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
  updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_core_stock_tokens_updated_at
  BEFORE UPDATE ON core.stock_tokens
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Expense ratio auto-recalculation trigger
CREATE OR REPLACE FUNCTION core.recalculate_expense_ratio()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  -- Recalculate expense ratio when supply/demand balance changes.
  -- Formula: 1% base + up to 4% based on demand pressure (issued/staked ratio)
  -- Example: 80% of supply taken → ratio = 1% + (0.8 * 4%) = 4.2%
  IF NEW.total_staked_qty > 0 THEN
    NEW.current_expense_ratio := GREATEST(0.01, LEAST(0.05,
      0.01 + ((NEW.total_tokens_issued / NULLIF(NEW.total_staked_qty, 0)) * 0.04)
    ));
  ELSE
    NEW.current_expense_ratio := 0.01; -- default to minimum when no stakers
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_core_expense_ratio_recalc
  BEFORE UPDATE OF total_tokens_issued, total_staked_qty ON core.stock_tokens
  FOR EACH ROW EXECUTE FUNCTION core.recalculate_expense_ratio();

CREATE INDEX IF NOT EXISTS idx_core_stock_tokens_symbol   ON core.stock_tokens USING gin(symbol gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_core_stock_tokens_ticker   ON core.stock_tokens(base_ticker);
CREATE INDEX IF NOT EXISTS idx_core_stock_tokens_active   ON core.stock_tokens(is_active, is_featured);
CREATE INDEX IF NOT EXISTS idx_core_stock_tokens_sector   ON core.stock_tokens(sector);
CREATE INDEX IF NOT EXISTS idx_core_stock_tokens_nav_desc ON core.stock_tokens(current_nav_per_token DESC);

COMMENT ON TABLE core.stock_tokens IS 'Master list of BSE tradeable stock tokens. NAV price updated daily by nav_engine. Intraday market data cached from Alpaca API.';

-- ============================================================================
-- TABLE: core.nav_history
-- Immutable daily NAV record for every stock token.
-- Source of truth for portfolio performance charts (Figma p10, p12 candlestick chart).
-- Append-only: rows are NEVER updated after insert.
-- ============================================================================
CREATE TABLE IF NOT EXISTS core.nav_history (
  id                      UUID            PRIMARY KEY DEFAULT uuid_generate_v4(),
  token_id                UUID            NOT NULL REFERENCES core.stock_tokens(id),
  symbol                  VARCHAR(12)     NOT NULL,
    -- Denormalized for query performance (avoids join on every chart load)
  nav_date                DATE            NOT NULL,
    -- The trading day this NAV applies to

  -- ── Real Stock Price Inputs ───────────────────────────────────────────────
  market_close_price      NUMERIC(20, 8)  NOT NULL,
    -- Alpaca market close price for this trading day
  market_open_price       NUMERIC(20, 8),
  market_high_price       NUMERIC(20, 8),
    -- Figma p12: candlestick chart needs OHLC data
  market_low_price        NUMERIC(20, 8),
  trading_volume          BIGINT,

  -- ── Pool Calculation Inputs ───────────────────────────────────────────────
  pool_shares_beginning   NUMERIC(20, 8)  NOT NULL DEFAULT 0,
    -- Shares in Alpaca pool at start of day
  pool_shares_net_change  NUMERIC(20, 8)  NOT NULL DEFAULT 0,
    -- Net shares bought/sold via Alpaca this day (from batch orders)
  pool_shares_ending      NUMERIC(20, 8)  NOT NULL DEFAULT 0,
    -- = beginning + net_change
  gross_pool_value_usd    NUMERIC(20, 8)  NOT NULL DEFAULT 0,
    -- = pool_shares_ending * market_close_price

  -- ── Cost/Reserve Deductions ───────────────────────────────────────────────
  tax_reserve_usd         NUMERIC(20, 8)  NOT NULL DEFAULT 0,
    -- 20% of realized gains reserved for tax liability
  staking_fee_reserve_usd NUMERIC(20, 8)  NOT NULL DEFAULT 0,
    -- Portion of expense ratio allocated to staker rewards
  platform_fee_reserve_usd NUMERIC(20, 8) NOT NULL DEFAULT 0,
    -- Portion of expense ratio kept by BSE platform
  expense_ratio_applied   NUMERIC(8, 6)   NOT NULL,
    -- The actual ratio used on this day

  -- ── Final NAV ─────────────────────────────────────────────────────────────
  net_pool_value_usd      NUMERIC(20, 8)  NOT NULL,
    -- = gross - tax_reserve - staking_fee - platform_fee
  total_tokens_issued     NUMERIC(20, 8)  NOT NULL,
    -- Total BSE tokens outstanding at time of calculation
  nav_per_token           NUMERIC(20, 8)  NOT NULL,
    -- = net_pool_value / total_tokens_issued — THE BSE TOKEN PRICE
  nav_change_amount       NUMERIC(20, 8)  NOT NULL DEFAULT 0,
    -- vs previous trading day NAV
  nav_change_pct          NUMERIC(10, 6)  NOT NULL DEFAULT 0,

  -- ── Alpaca Execution Reference ─────────────────────────────────────────────
  alpaca_order_id         VARCHAR(100),
    -- The Alpaca order ID for the net buy/sell executed this day
  alpaca_fill_price       NUMERIC(20, 8),
    -- Actual fill price from Alpaca (may differ slightly from close price)
  alpaca_executed_at      TIMESTAMPTZ,

  calculated_at           TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    -- When the nav_engine ran this calculation

  -- Enforce one NAV record per token per day
  CONSTRAINT uq_nav_history_token_date UNIQUE (token_id, nav_date)
);

-- NO update trigger — nav_history rows are immutable (append-only)
-- Attempting to UPDATE will be blocked at application layer

CREATE INDEX IF NOT EXISTS idx_core_nav_history_token_date ON core.nav_history(token_id, nav_date DESC);
CREATE INDEX IF NOT EXISTS idx_core_nav_history_symbol_date ON core.nav_history(symbol, nav_date DESC);
  -- Used by portfolio performance chart queries (Figma p10 chart: 1D/1W/6M/1Y)

COMMENT ON TABLE core.nav_history IS
  'Immutable daily NAV record per token. Append-only — rows never updated. '
  'Source of truth for portfolio performance charts and trade execution prices. '
  'Also stores OHLC market prices for candlestick charts (Figma p12).';

-- ============================================================================
-- TABLE: core.watchlist
-- Figma p10 Dashboard: Watchlist panel showing 5 starred stocks.
-- Figma p13 Trade Stocks: starred stocks shown at top in watchlist cards.
-- Figma p14: star icon on stock rows to add/remove from watchlist.
-- ============================================================================
CREATE TABLE IF NOT EXISTS core.watchlist (
  id              UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id         UUID        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  token_id        UUID        NOT NULL REFERENCES core.stock_tokens(id) ON DELETE CASCADE,
  symbol          VARCHAR(12) NOT NULL,
    -- Denormalized for fast watchlist queries
  sort_order      SMALLINT    NOT NULL DEFAULT 0,
    -- User-defined display order in watchlist panel
  added_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- One entry per user per stock
  CONSTRAINT uq_watchlist_user_token UNIQUE (user_id, token_id)
);

CREATE INDEX IF NOT EXISTS idx_core_watchlist_user_id ON core.watchlist(user_id, sort_order);

COMMENT ON TABLE core.watchlist IS 'User watchlists. Figma p10 dashboard watchlist widget and p13 starred stocks. Max recommended: 20 per user (UI shows 5).';

-- ============================================================================
-- TABLE: core.market_price_feed
-- Intraday price ticker shown in Figma header ticker bar:
-- "ADA/USD 615.75 ↓ -0.67%  ADA/USD 615.75 ↑ +0.78%..."
-- Written by a background job polling Alpaca every minute during market hours.
-- This table is a rolling window (last 24h only) — older rows purged daily.
-- ============================================================================
CREATE TABLE IF NOT EXISTS core.market_price_feed (
  id              UUID            PRIMARY KEY DEFAULT uuid_generate_v4(),
  symbol          VARCHAR(12)     NOT NULL,
    -- Can be stock symbol OR crypto pair (ADA/USD as shown in Figma header)
  price           NUMERIC(20, 8)  NOT NULL,
  change_amount   NUMERIC(20, 8)  NOT NULL DEFAULT 0,
  change_pct      NUMERIC(10, 6)  NOT NULL DEFAULT 0,
    -- Figma: "-0.67%" or "+0.78%" shown in scrolling ticker
  direction       CHAR(1)         NOT NULL CHECK (direction IN ('U', 'D', 'F')),
    -- 'U' = up (green arrow ↑), 'D' = down (red arrow ↓), 'F' = flat
  source          VARCHAR(20)     NOT NULL DEFAULT 'alpaca',
  recorded_at     TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

-- Partial index — only recent prices (last 2 hours) for fast ticker reads
CREATE INDEX IF NOT EXISTS idx_core_price_feed_recent
  ON core.market_price_feed(symbol, recorded_at DESC)
  WHERE recorded_at > NOW() - INTERVAL '2 hours';

COMMENT ON TABLE core.market_price_feed IS
  'Rolling intraday price feed. Powers the scrolling ticker bar in Figma header. '
  'Rows older than 24h are purged by a scheduled cleanup job.';

-- ============================================================================
-- DATABASE VIEWS — API-TO-DB MAPPING
-- PURPOSE: Pre-built views that map directly to each frontend screen/API.
--          Backend API services query these views instead of writing
--          complex JOINs inline. Simplifies API code and centralizes logic.
--
-- CONVENTION: view name = 'v_<screen>_<purpose>'
-- RUN ORDER: 06 (after all schemas)
-- ============================================================================

-- ============================================================================
-- VIEW: v_dashboard_portfolio
-- BACKEND API: GET /portfolio/{userId}
-- FIGMA: Page 10 — Dashboard Portfolio section
-- Returns: Total Portfolio Value, Available, In Transit, Invested, Portfolio Stats
-- ============================================================================
CREATE OR REPLACE VIEW trading.v_dashboard_portfolio AS
SELECT
  u.id                                          AS user_id,
  u.display_name,
  u.avatar_initials,
  u.last_active_at,

  -- Figma p10: Total Balance and breakdown
  wa.bse_balance                                AS available_balance,
  wa.bse_in_transit                             AS in_transit_balance,
  wa.total_invested_usd                         AS invested_balance,
  wa.bse_balance + wa.total_invested_usd        AS total_balance,

  -- Figma p10: Total Portfolio Value (top card)
  wa.total_portfolio_value,

  -- Figma p10: Portfolio Stats widget
  COUNT(DISTINCT th.token_id) FILTER (WHERE th.qty > 0)  AS total_stocks_held,
  SUM(th.qty)                 FILTER (WHERE th.qty > 0)  AS total_shares_held,
  (SELECT COUNT(*) FROM trading.orders o
   WHERE o.user_id = u.id
   AND o.status = 'executed')                            AS total_executed_trades,

  -- Today's portfolio movement (Figma p10: "+1840.45 (4.28%) Today")
  ps.day_gain_usd                               AS today_gain_usd,
  ps.day_gain_pct                               AS today_gain_pct,

  -- Last activity timestamp (Figma p10: "Last Activity 2 Nov, 2024 at 09:00 AM")
  GREATEST(wa.last_deposit_at, wa.last_transaction_at)   AS last_activity_at

FROM auth.users u
JOIN wallet.accounts  wa ON wa.user_id = u.id
LEFT JOIN trading.holdings th ON th.user_id = u.id
LEFT JOIN trading.portfolio_snapshots ps ON ps.user_id = u.id
  AND ps.snapshot_date = CURRENT_DATE
WHERE u.is_active = TRUE
GROUP BY u.id, u.display_name, u.avatar_initials, u.last_active_at,
         wa.bse_balance, wa.bse_in_transit, wa.total_invested_usd,
         wa.total_portfolio_value, ps.day_gain_usd, ps.day_gain_pct,
         wa.last_deposit_at, wa.last_transaction_at;

COMMENT ON VIEW trading.v_dashboard_portfolio IS
  'Dashboard portfolio summary. BACKEND: GET /portfolio/{userId}. FIGMA: p10 portfolio section.';

-- ============================================================================
-- VIEW: v_holdings_detail
-- BACKEND API: GET /portfolio/{userId}/holdings
-- FIGMA: Page 10 — "Your Holdings" table
-- Returns: per-stock row with shares, avg price, current price, total value, gain/loss
-- ============================================================================
CREATE OR REPLACE VIEW trading.v_holdings_detail AS
SELECT
  th.user_id,
  th.symbol,
  st.company_name,
  st.logo_url,
  st.sector,

  -- Figma p10 Holdings columns:
  th.qty                    AS shares,
  th.avg_cost_per_token     AS avg_price,
  st.current_nav_per_token  AS current_price,
  th.current_value_usd      AS total_value,
  th.unrealized_gain_usd    AS gain_loss_usd,
  th.unrealized_gain_pct    AS gain_loss_pct,
  th.daily_gain_usd,

  -- Additional for detail panel:
  th.total_cost_basis,
  th.realized_gain_usd,
  th.first_bought_at,
  th.last_traded_at

FROM trading.holdings th
JOIN core.stock_tokens st ON st.id = th.token_id
WHERE th.qty > 0   -- only active (non-zero) positions
ORDER BY th.current_value_usd DESC;

COMMENT ON VIEW trading.v_holdings_detail IS
  'Holdings table rows. BACKEND: GET /portfolio/{userId}/holdings. FIGMA: p10 Your Holdings.';

-- ============================================================================
-- VIEW: v_account_balance
-- BACKEND API: GET /wallet/balance/{userId}
-- FIGMA: Page 11 — Account Balance page
-- Returns: Total balance, balance history, crypto assets breakdown
-- ============================================================================
CREATE OR REPLACE VIEW wallet.v_account_balance AS
SELECT
  u.id                                   AS user_id,

  -- Figma p11: Total Balance card
  wa.bse_balance + wa.total_invested_usd AS total_balance_usd,
  wa.bse_balance                         AS available_usd,
  wa.bse_in_transit                      AS in_transit_usd,

  -- Figma p11: Crypto Assets (USDT shown)
  -- These values come from deposit/withdrawal records, computed here
  (SELECT SUM(d.bse_tokens_credited)
   FROM wallet.deposits d
   WHERE d.user_id = u.id
     AND d.crypto_currency = 'USDT'
     AND d.status = 'completed')         AS usdt_holdings,

  (SELECT SUM(d.bse_tokens_credited)
   FROM wallet.deposits d
   WHERE d.user_id = u.id
     AND d.crypto_currency = 'ETH'
     AND d.status = 'completed')         AS eth_holdings,

  -- Figma p11: Primary wallet address for display
  cw.wallet_address                      AS primary_wallet_address,
  cw.provider                            AS wallet_provider,
  cw.network                             AS wallet_network,

  wa.last_deposit_at,
  wa.updated_at

FROM auth.users u
JOIN wallet.accounts wa ON wa.user_id = u.id
LEFT JOIN auth.crypto_wallets cw ON cw.user_id = u.id AND cw.is_primary = TRUE;

COMMENT ON VIEW wallet.v_account_balance IS
  'Account Balance page data. BACKEND: GET /wallet/balance/{userId}. FIGMA: p11.';

-- ============================================================================
-- VIEW: v_recent_transactions
-- BACKEND API: GET /wallet/transactions/{userId}?limit=20&offset=0
-- FIGMA: Pages 10 & 11 — Recent Transactions table
-- Columns: Type, Crypto, Amount, USD Value, Status, Network, Tx Hash, Date & Time
-- Combines deposits + withdrawals + transfers into unified view
-- ============================================================================
CREATE OR REPLACE VIEW wallet.v_recent_transactions AS

-- Deposits
SELECT
  d.id,
  d.user_id,
  'Deposit'                AS type,
  d.crypto_currency::TEXT  AS crypto,
  d.crypto_amount          AS amount,
  d.gross_usd_amount       AS usd_value,
  d.status::TEXT           AS status,
  d.crypto_network         AS network,
  d.crypto_tx_hash         AS tx_hash,
  d.created_at             AS date_time,
  1                        AS sort_priority  -- deposits sort before same-time events
FROM wallet.deposits d

UNION ALL

-- Withdrawals
SELECT
  w.id,
  w.user_id,
  'Withdrawal'             AS type,
  w.crypto_currency::TEXT  AS crypto,
  w.crypto_amount_sent     AS amount,
  w.usd_value_at_request   AS usd_value,
  w.status::TEXT           AS status,
  w.destination_network    AS network,
  w.crypto_tx_hash         AS tx_hash,
  w.created_at             AS date_time,
  2                        AS sort_priority
FROM wallet.withdrawals w

UNION ALL

-- Transfers
SELECT
  t.id,
  t.from_user_id           AS user_id,
  'Transfer'               AS type,
  'BSE'                    AS crypto,
  t.amount_bse             AS amount,
  t.usd_value              AS usd_value,
  t.status::TEXT           AS status,
  'Internal'               AS network,
  NULL::VARCHAR            AS tx_hash,
  t.created_at             AS date_time,
  3                        AS sort_priority
FROM wallet.transfers t

ORDER BY date_time DESC, sort_priority;

COMMENT ON VIEW wallet.v_recent_transactions IS
  'Unified transaction history. BACKEND: GET /wallet/transactions/{userId}. FIGMA: p10/p11 Recent Transactions table.';

-- ============================================================================
-- VIEW: v_stock_list
-- BACKEND API: GET /market/stocks?sort=gainers|losers&search=<q>
-- FIGMA: Page 13 — Trade Stocks "All Stocks" table
-- Columns: Stock (logo, symbol, name), Sector, Price, Change, Market Cap, Volume, Watchlist star
-- ============================================================================
CREATE OR REPLACE VIEW core.v_stock_list AS
SELECT
  st.id                       AS token_id,
  st.symbol,
  st.base_ticker,
  st.company_name,
  st.logo_url,
  st.sector,

  -- Figma p13 Price column
  st.current_nav_per_token    AS price,

  -- Figma p13 Change column ("+$1.58 (+0.84%)")
  st.nav_change_amount        AS change_amount,
  st.nav_change_pct           AS change_pct,
  CASE WHEN st.nav_change_amount >= 0 THEN 'up' ELSE 'down' END AS direction,

  -- Figma p13 Market Cap column ("$2.95T")
  st.market_cap_display       AS market_cap,

  -- Figma p13 Volume column ("52.4M")
  st.volume,

  st.is_active,
  st.is_featured,
  st.market_status,
  st.current_expense_ratio,

  -- For "Top Gainers" / "Top Losers" filter tabs (Figma p13)
  RANK() OVER (ORDER BY st.nav_change_pct DESC) AS gainer_rank,
  RANK() OVER (ORDER BY st.nav_change_pct ASC)  AS loser_rank

FROM core.stock_tokens st
WHERE st.is_active = TRUE
ORDER BY st.market_cap_usd DESC NULLS LAST;

COMMENT ON VIEW core.v_stock_list IS
  'All Stocks list. BACKEND: GET /market/stocks. FIGMA: p13 Trade Stocks table.';

-- ============================================================================
-- VIEW: v_stock_detail
-- BACKEND API: GET /market/stocks/{symbol}
-- FIGMA: Page 12 — Stock Detail (AAPL page)
-- Returns: Full stock info, current position for logged-in user, metrics
-- ============================================================================
CREATE OR REPLACE VIEW core.v_stock_detail AS
SELECT
  st.id                       AS token_id,
  st.symbol,
  st.base_ticker,
  st.company_name,
  st.description,
  st.sector,
  st.industry,
  st.exchange,
  st.logo_url,

  -- Figma p12: Price header ("$190.40 +1.58 (+0.84%)")
  st.current_nav_per_token    AS current_price,
  st.nav_change_amount,
  st.nav_change_pct,

  -- Figma p12: Key metrics cards
  st.market_cap_display,
  st.pe_ratio,
  st.dividend_yield_pct,
  st.volume,

  -- Figma p12: Price Performance (Today/7D/30D/1Y)
  st.perf_1d_pct,
  st.perf_7d_pct,
  st.perf_30d_pct,
  st.perf_1y_pct,

  -- Figma p12: Key Metrics section
  st.week_52_high,
  st.week_52_low,
  st.revenue_usd,
  st.net_income_usd,
  st.eps,

  -- Figma p12: Company Information section
  st.ceo,
  st.founded_year,
  st.headquarters,
  st.employee_count,
  st.website_url,
  st.investor_relations_url,
  st.sec_filings_url,

  -- Figma p12: Buy Stock panel
  st.current_expense_ratio,
  st.available_supply,
  st.market_status,

  -- Figma p14: Bid/Ask/Spread
  st.bid_price,
  st.bid_size,
  st.ask_price,
  st.ask_size,
  st.bid_ask_spread,
  st.day_range_low,
  st.day_range_high,
  st.ex_dividend_date,
  st.dividend_payable_date,
  st.market_last_refreshed_at

FROM core.stock_tokens st
WHERE st.is_active = TRUE;

COMMENT ON VIEW core.v_stock_detail IS
  'Full stock detail. BACKEND: GET /market/stocks/{symbol}. FIGMA: p12 Stock Detail page.';

-- ============================================================================
-- VIEW: v_watchlist_with_prices
-- BACKEND API: GET /market/watchlist/{userId}
-- FIGMA: Page 10 Dashboard watchlist + Page 13 Trade Stocks starred cards
-- ============================================================================
CREATE OR REPLACE VIEW core.v_watchlist_with_prices AS
SELECT
  wl.user_id,
  wl.sort_order,
  wl.added_at,
  st.symbol,
  st.company_name,
  st.logo_url,
  st.current_nav_per_token    AS price,
  st.nav_change_amount,
  st.nav_change_pct,
  CASE WHEN st.nav_change_amount >= 0 THEN 'up' ELSE 'down' END AS direction
FROM core.watchlist wl
JOIN core.stock_tokens st ON st.id = wl.token_id
WHERE st.is_active = TRUE
ORDER BY wl.user_id, wl.sort_order, st.current_nav_per_token DESC;

COMMENT ON VIEW core.v_watchlist_with_prices IS
  'Watchlist with live prices. BACKEND: GET /market/watchlist/{userId}. FIGMA: p10 watchlist, p13 starred cards.';

-- ============================================================================
-- VIEW: v_order_preview
-- BACKEND API: POST /trade/orders/preview (before user confirms)
-- FIGMA: Page 15 — Preview Order modal
-- ============================================================================
CREATE OR REPLACE VIEW trading.v_order_preview AS
SELECT
  o.id                        AS order_id,
  o.user_id,
  o.symbol,
  st.company_name,
  st.logo_url,
  o.side,
  o.requested_qty,
  o.price_type,
  o.limit_price,
  o.duration,
  o.is_all_or_none,

  -- Figma p15: "Estimated Principal: $190.40"
  o.estimated_principal_usd,
  -- Figma p15: "Commission: $0.00"
  o.platform_fee_usd,
  -- Figma p15: "Estimated Total: $190.40"
  o.estimated_total_usd,
  -- Figma p15: "Buying power will decrease from $5,214.00 to $5,023.60"
  o.buying_power_before_usd,
  o.buying_power_after_usd,
  -- Figma p15: Account mask "****-2724"
  o.brokerage_account_mask,

  o.status,
  o.created_at

FROM trading.orders o
JOIN core.stock_tokens st ON st.id = o.token_id;

COMMENT ON VIEW trading.v_order_preview IS
  'Order preview data. BACKEND: POST /trade/orders/preview. FIGMA: p15 Preview Order modal.';

-- ============================================================================
-- VIEW: v_profile_summary
-- BACKEND API: GET /user/profile/{userId}
-- FIGMA: Page 19 — Profile & Settings sidebar card
-- Returns: name, email, status, joined date, avatar
-- ============================================================================
CREATE OR REPLACE VIEW auth.v_profile_summary AS
SELECT
  u.id,
  u.firebase_uid,
  u.email,
  u.first_name,
  u.last_name,
  u.display_name,
  u.avatar_url,
  u.avatar_initials,
  u.phone_number,
  u.address_line1,
  u.city,
  u.state_province,
  u.postal_code,
  u.country_code,

  -- Figma p19: "Status: Verified KYC" badge
  u.kyc_status,
  -- Figma p19: "Joined: Mar 2023"
  TO_CHAR(u.joined_at, 'Mon YYYY')     AS joined_display,
  u.joined_at,

  -- Figma p19: Account Preferences
  u.base_currency,
  u.language,
  u.timezone,

  -- Figma p20: 2FA status
  EXISTS (
    SELECT 1 FROM auth.user_devices ud
    WHERE ud.user_id = u.id
    AND ud.is_current = TRUE
  )                                    AS has_active_session,

  -- Figma p21: has payment methods
  (SELECT COUNT(*) FROM auth.payment_methods pm WHERE pm.user_id = u.id) AS payment_method_count,

  -- Connected wallets
  (SELECT COUNT(*) FROM auth.crypto_wallets cw WHERE cw.user_id = u.id AND cw.is_verified = TRUE) AS verified_wallet_count,

  u.role,
  u.is_onboarded

FROM auth.users u
WHERE u.is_active = TRUE;

COMMENT ON VIEW auth.v_profile_summary IS
  'Profile page summary card. BACKEND: GET /user/profile/{userId}. FIGMA: p19-p23 Profile & Settings.';

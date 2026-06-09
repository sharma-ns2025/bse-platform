-- ============================================================================
-- SEED + MOCK DATA
-- SECTION 1: Production seed data (stock tokens — always inserted)
-- SECTION 2: mock schema with full realistic dummy data for development/testing
--
-- USAGE:
--   Production:  Run SECTION 1 only
--   Development: Run SECTION 1 + SECTION 2
--   Testing:     Run SECTION 2 only in mock schema
--
-- ALL mock data is in the 'mock' schema — DROP SCHEMA mock CASCADE to wipe.
-- Firebase UIDs below are fake — replace with real ones from your Firebase project.
-- RUN ORDER: 07 (after all schemas and views)
-- ============================================================================

-- ============================================================================
-- SECTION 1: PRODUCTION SEED DATA
-- Stock tokens derived from Figma p12/p13 screens
-- ============================================================================

-- Insert stock tokens (idempotent — safe to re-run)
INSERT INTO core.stock_tokens (
  symbol, base_ticker, company_name, description,
  sector, industry, exchange, country_code,
  ceo, founded_year, headquarters, employee_count,
  current_nav_per_token, previous_nav_per_token,
  market_cap_usd, market_cap_display,
  pe_ratio, dividend_yield_pct, dividend_amount,
  ex_dividend_date, dividend_payable_date,
  week_52_high, week_52_low,
  revenue_usd, net_income_usd, eps,
  volume,
  perf_1d_pct, perf_7d_pct, perf_30d_pct, perf_1y_pct,
  bid_price, bid_size, ask_price, ask_size, bid_ask_spread,
  day_range_low, day_range_high,
  website_url, investor_relations_url, sec_filings_url,
  is_active, is_featured, market_status
)
VALUES
-- AAPL — Figma p12 stock detail screen
(
  'AAPL-T', 'AAPL', 'Apple Inc.',
  'Apple Inc. designs, manufactures, and markets smartphones, personal computers, tablets, wearables, and accessories worldwide. The company is known for its iPhone, Mac, iPad, Apple Watch, and innovative services.',
  'Technology', 'Consumer Electronics', 'NASDAQ', 'US',
  'Tim Cook', 1976, 'Cupertino, California', 161000,
  190.40, 188.82,   -- Figma p12: $190.40 +1.58 (+0.84%)
  2950000000000, '$2.95T',
  31.20, 0.52, 0.00,
  '2025-11-10', '2025-11-21',
  199.62, 164.08,
  383300000000, 97000000000, 6.13,
  52400000,          -- Figma p12/p13: 52.4M volume
  1.24, 2.84, 8.45, 32.18,
  190.35, 200, 190.45, 150, 0.053,
  187.50, 191.20,
  'https://apple.com', 'https://investor.apple.com', 'https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&CIK=AAPL',
  TRUE, TRUE, 'open'
),
-- GOOGL — Figma p13 stock list
(
  'GOOGL-T', 'GOOGL', 'Alphabet Inc.',
  'Alphabet Inc. is a holding company whose subsidiaries include Google, the world''s most widely used search engine, along with cloud computing, advertising, and hardware divisions.',
  'Technology', 'Internet Content & Information', 'NASDAQ', 'US',
  'Sundar Pichai', 1998, 'Mountain View, California', 186779,
  142.65, 143.87,   -- Figma p13: $142.65 -1.22 (-0.85%)
  1780000000000, '$1.78T',
  23.10, 0.00, 0.00, NULL, NULL,
  153.78, 115.83,
  297000000000, 73795000000, 5.80,
  28200000,
  -0.85, 1.20, 5.30, 28.40,
  142.60, 180, 142.70, 120, 0.047,
  141.30, 143.80,
  'https://abc.xyz', 'https://abc.xyz/investor', 'https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&CIK=GOOGL',
  TRUE, TRUE, 'open'
),
-- MSFT — Figma p13 stock list
(
  'MSFT-T', 'MSFT', 'Microsoft Corporation',
  'Microsoft Corporation develops and supports software, services, devices and solutions worldwide. Products include Windows, Office, Azure cloud, LinkedIn, and gaming via Xbox.',
  'Technology', 'Software—Application', 'NASDAQ', 'US',
  'Satya Nadella', 1975, 'Redmond, Washington', 221000,
  415.20, 406.47,   -- Figma p13: $415.20 +8.73 (+2.15%)
  3090000000000, '$3.09T',
  35.80, 0.75, 0.00,
  '2025-11-19', '2025-12-12',
  468.35, 309.45,
  245122000000, 88136000000, 11.80,
  24800000,
  2.15, 3.90, 11.20, 38.70,
  415.10, 220, 415.30, 180, 0.048,
  410.50, 416.80,
  'https://microsoft.com', 'https://www.microsoft.com/en-us/investor', 'https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&CIK=MSFT',
  TRUE, TRUE, 'open'
),
-- TSLA — Figma p13 stock list
(
  'TSLA-T', 'TSLA', 'Tesla, Inc.',
  'Tesla designs, develops, manufactures, leases, and sells electric vehicles, energy generation and storage systems, and offers related services.',
  'Consumer Cyclical', 'Auto Manufacturers', 'NASDAQ', 'US',
  'Elon Musk', 2003, 'Austin, Texas', 140473,
  248.50, 240.21,   -- Figma p13: $248.50 +8.29 (+3.45%)
  789200000000, '$789.2B',
  65.30, 0.00, 0.00, NULL, NULL,
  278.98, 138.80,
  97690000000, 14974000000, 4.73,
  98700000,
  3.45, 6.20, 15.80, 42.50,
  248.30, 300, 248.70, 250, 0.080,
  244.10, 252.30,
  'https://tesla.com', 'https://ir.tesla.com', 'https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&CIK=TSLA',
  TRUE, TRUE, 'open'
),
-- AMZN — Figma p13 stock list
(
  'AMZN-T', 'AMZN', 'Amazon.com, Inc.',
  'Amazon.com operates as a technology and e-commerce company offering retail, cloud (AWS), advertising, digital content and streaming services worldwide.',
  'Consumer Cyclical', 'Internet Retail', 'NASDAQ', 'US',
  'Andy Jassy', 1994, 'Seattle, Washington', 1541000,
  178.25, 175.58,   -- Figma p13: $178.25 +2.67 (+1.52%)
  1850000000000, '$1.85T',
  44.20, 0.00, 0.00, NULL, NULL,
  201.20, 118.35,
  574785000000, 30425000000, 2.90,
  45300000,
  1.52, 4.10, 9.80, 51.20,
  178.15, 160, 178.35, 200, 0.056,
  176.40, 179.80,
  'https://amazon.com', 'https://ir.aboutamazon.com', 'https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&CIK=AMZN',
  TRUE, FALSE, 'open'
),
-- META — Figma p13 stock list
(
  'META-T', 'META', 'Meta Platforms, Inc.',
  'Meta Platforms builds technology to help people connect and share. Products include Facebook, Instagram, WhatsApp, Messenger, and the Meta Quest VR platform.',
  'Technology', 'Internet Content & Information', 'NASDAQ', 'US',
  'Mark Zuckerberg', 2004, 'Menlo Park, California', 86482,
  468.90, 474.78,   -- Figma p13: $468.90 -5.88 (-1.24%)
  1190000000000, '$1.19T',
  24.50, 0.40, 0.00,
  '2025-12-01', '2025-12-26',
  589.03, 279.40,
  134902000000, 39098000000, 14.87,
  18600000,
  -1.24, 2.30, 7.60, 58.40,
  468.80, 140, 469.00, 110, 0.043,
  465.30, 471.20,
  'https://meta.com', 'https://investor.fb.com', 'https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&CIK=META',
  TRUE, FALSE, 'open'
),
-- NVDA — Figma p13 stock list
(
  'NVDA-T', 'NVDA', 'NVIDIA Corporation',
  'NVIDIA Corporation provides graphics and compute processing solutions. Products include GPUs for gaming, data centers, automotive AI and the CUDA computing platform.',
  'Technology', 'Semiconductors', 'NASDAQ', 'US',
  'Jensen Huang', 1993, 'Santa Clara, California', 36000,
  505.48, 485.48,   -- Figma p13: $505.48 +20.00 (+4.12%)
  1240000000000, '$1.24T',
  56.80, 0.03, 0.00,
  '2025-12-03', '2025-12-27',
  553.21, 180.64,
  79774000000, 29760000000, 1.21,
  62800000,
  4.12, 9.80, 22.40, 168.50,
  505.30, 180, 505.60, 200, 0.059,
  495.10, 510.80,
  'https://nvidia.com', 'https://investor.nvidia.com', 'https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&CIK=NVDA',
  TRUE, TRUE, 'open'
),
-- NFLX — Figma p13 stock list
(
  'NFLX-T', 'NFLX', 'Netflix, Inc.',
  'Netflix is a streaming entertainment service offering TV series, movies, anime, documentaries, and mobile games in 190+ countries.',
  'Communication Services', 'Entertainment', 'NASDAQ', 'US',
  'Greg Peters', 1997, 'Los Gatos, California', 13000,
  672.15, 665.82,   -- Figma p13: $672.15 +6.33 (+0.95%)
  288500000000, '$288.5B',
  42.30, 0.00, 0.00, NULL, NULL,
  741.10, 430.95,
  38905000000, 7368000000, 17.06,
  6200000,
  0.95, 3.10, 8.90, 44.20,
  672.00, 80, 672.30, 60, 0.045,
  667.50, 674.80,
  'https://ir.netflix.net', 'https://ir.netflix.net', 'https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&CIK=NFLX',
  TRUE, FALSE, 'open'
)
ON CONFLICT (symbol) DO UPDATE SET
  current_nav_per_token  = EXCLUDED.current_nav_per_token,
  previous_nav_per_token = EXCLUDED.previous_nav_per_token,
  market_cap_usd         = EXCLUDED.market_cap_usd,
  market_cap_display     = EXCLUDED.market_cap_display,
  volume                 = EXCLUDED.volume,
  bid_price              = EXCLUDED.bid_price,
  ask_price              = EXCLUDED.ask_price,
  day_range_low          = EXCLUDED.day_range_low,
  day_range_high         = EXCLUDED.day_range_high,
  market_status          = EXCLUDED.market_status,
  market_last_refreshed_at = NOW(),
  updated_at             = NOW();

-- ============================================================================
-- SECTION 2: MOCK DATA (mock schema — dev/test only)
-- Mirrors Figma p10-p23 exactly with realistic values
-- ============================================================================

-- ── Mock Users (representing Figma profile: Alex Jonathan) ─────────────────

-- Alex Jonathan (primary demo user, shown throughout Figma)
INSERT INTO auth.users (
  id, firebase_uid, email, email_verified,
  first_name, last_name, display_name, avatar_initials,
  phone_number, address_line1, city, state_province, postal_code, country_code,
  kyc_status, kyc_approved_at,
  base_currency, language, timezone,
  role, is_active, is_onboarded,
  joined_at, last_login_at
)
VALUES (
  'a0000000-0000-0000-0000-000000000001',       -- fixed UUID for referencing in other mock data
  'firebase_uid_alex_jonathan_mock_001',         -- fake Firebase UID
  'alex.j@example.com',                          -- Figma p19: email shown
  TRUE,
  'Alex', 'Jonathan', 'Alex Jonathan', 'AJ',    -- Figma p19: name and initials
  '+1 (555) 123-4567',                           -- Figma p19: phone number
  '123 Financial District', 'New York', 'NY', '10004', 'US', -- Figma p19: address
  'approved', NOW() - INTERVAL '2 years',        -- Figma p19: "Verified KYC"
  'USD', 'en', 'America/New_York',
  'investor', TRUE, TRUE,
  '2023-03-01 09:00:00+00',                      -- Figma p19: "Joined: Mar 2023"
  NOW() - INTERVAL '2 hours'
)
ON CONFLICT (firebase_uid) DO NOTHING;

-- Second demo user (staker persona)
INSERT INTO auth.users (
  id, firebase_uid, email, email_verified,
  first_name, last_name, display_name, avatar_initials,
  phone_number, country_code,
  kyc_status, kyc_approved_at,
  base_currency, language, timezone,
  role, is_active, is_onboarded, joined_at
)
VALUES (
  'a0000000-0000-0000-0000-000000000002',
  'firebase_uid_sarah_miller_mock_002',
  'sarah.m@example.com',
  TRUE,
  'Sarah', 'Miller', 'Sarah Miller', 'SM',
  '+1 (555) 987-6543', 'US',
  'approved', NOW() - INTERVAL '18 months',
  'USD', 'en', 'America/Chicago',
  'staker', TRUE, TRUE, '2023-06-15 10:00:00+00'
)
ON CONFLICT (firebase_uid) DO NOTHING;

-- ── Mock Wallets (Figma p11: wallet address 0x742d35Cc...) ─────────────────

INSERT INTO auth.crypto_wallets (
  user_id, wallet_address, provider, network, is_primary, is_verified, connected_at
)
VALUES
-- Alex's primary wallet (Figma p11: exact address shown)
(
  'a0000000-0000-0000-0000-000000000001',
  '0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb',  -- Figma p11 exact address
  'coinbase', 'ethereum', TRUE, TRUE, '2023-03-01 10:00:00+00'
),
-- Alex's secondary wallet
(
  'a0000000-0000-0000-0000-000000000001',
  '0x8ba1f109551bD432803012645Hac136Ddb96Ea',
  'metamask', 'ethereum', FALSE, TRUE, '2023-06-01 14:00:00+00'
),
-- Sarah's wallet
(
  'a0000000-0000-0000-0000-000000000002',
  '0x3Ab4c7D9e1F2a3B4c5D6e7F8a9B0c1D2e3F4a5',
  'walletconnect', 'ethereum', TRUE, TRUE, '2023-06-16 09:00:00+00'
)
ON CONFLICT (user_id, wallet_address, network) DO NOTHING;

-- ── Mock Payment Methods (Figma p21) ────────────────────────────────────────

INSERT INTO auth.payment_methods (
  user_id, method_type, institution_name, masked_number,
  card_brand, card_expiry_month, card_expiry_year,
  account_type, processor_token, is_default, is_verified
)
VALUES
-- Figma p21: Chase Bank Visa Debit **** 4242 (Default)
(
  'a0000000-0000-0000-0000-000000000001',
  'card', 'Chase Bank', '**** **** **** 4242',
  'visa', 12, 2026,
  'debit', 'pm_mock_chase_visa_4242', TRUE, TRUE
),
-- Figma p21: Bank of America Checking **** 8891 (Verified)
(
  'a0000000-0000-0000-0000-000000000001',
  'bank_account', 'Bank of America', '**** **** 8891',
  NULL, NULL, NULL,
  'checking', 'pm_mock_bofa_checking_8891', FALSE, TRUE
)
ON CONFLICT DO NOTHING;

-- ── Mock Devices (Figma p20: Recent Devices) ────────────────────────────────

INSERT INTO auth.user_devices (
  user_id, device_name, browser_name, os_name, device_type,
  ip_address, city, country_code, is_current, last_seen_at
)
VALUES
-- Figma p20: "MacBook Pro - Safari  CURRENT  New York, USA  Active now"
(
  'a0000000-0000-0000-0000-000000000001',
  'MacBook Pro', 'Safari', 'macOS', 'desktop',
  '192.0.2.100', 'New York', 'US', TRUE, NOW()
),
-- Figma p20: "iPhone 13 - App  New York, USA  2 hours ago"
(
  'a0000000-0000-0000-0000-000000000001',
  'iPhone 13', 'App', 'iOS', 'mobile',
  '192.0.2.101', 'New York', 'US', FALSE, NOW() - INTERVAL '2 hours'
)
ON CONFLICT DO NOTHING;

-- ── Mock Wallet Account (Figma p10/p11 balances) ────────────────────────────

-- Alex's wallet: Available $15,000 + In Transit $2,500 + Invested $27,866.95
UPDATE wallet.accounts SET
  bse_balance         = 15000.00,    -- Figma p10: "Available $15,000.00"
  bse_in_transit      = 2500.00,     -- Figma p10: "In Transit $2,500.00"
  bse_reserved        = 0.00,
  total_invested_usd  = 27866.95,    -- Figma p10: "Invested $27,866.95"
  total_portfolio_value = 144866.95, -- Figma p10: "Total Portfolio Value $144,866.95"
  last_deposit_at     = '2024-11-02 09:00:00+00'
WHERE user_id = 'a0000000-0000-0000-0000-000000000001';

-- ── Mock Deposits (Figma p10/p11 Recent Transactions — deposit rows) ─────

INSERT INTO wallet.deposits (
  user_id, account_id,
  crypto_currency, crypto_amount, crypto_network, crypto_tx_hash,
  conversion_rate, gross_usd_amount, deposit_fee_usd, net_usd_amount,
  bse_tokens_credited, status, settled_at, created_at
)
SELECT
  'a0000000-0000-0000-0000-000000000001',
  wa.id,
  d.crypto_currency::crypto_currency_enum,
  d.crypto_amount,
  d.crypto_network,
  d.crypto_tx_hash,
  d.conversion_rate,
  d.gross_usd,
  0.00,
  d.gross_usd,
  d.gross_usd,
  'completed'::fund_transfer_status_enum,
  d.settled_at::TIMESTAMPTZ,
  d.created_at::TIMESTAMPTZ
FROM wallet.accounts wa,
(VALUES
  -- Figma p10/p11: Row 1 — Deposit USDT 5,000 $5,000.00 completed ERC-20
  ('USDT', 5000.00,    'ERC-20',   '0x1a2b3c4d...7g8h9i0j', 1.00,    5000.00, '2024-12-14 09:30:00', '2024-12-14 09:30:00'),
  -- Figma p10/p11: Row 3 — Deposit BTC 0.1 $4,300.00 pending Bitcoin
  ('BTC',  0.1,        'Bitcoin',  '0xaabbccdd...11223344', 43000.00, 4300.00, NULL,                  '2024-12-13 11:20:00')
) AS d(crypto_currency, crypto_amount, crypto_network, crypto_tx_hash, conversion_rate, gross_usd, settled_at, created_at)
WHERE wa.user_id = 'a0000000-0000-0000-0000-000000000001'
ON CONFLICT DO NOTHING;

-- ── Mock Withdrawals (Figma p10/p11 Recent Transactions — withdrawal rows) ─

INSERT INTO wallet.withdrawals (
  user_id, account_id,
  crypto_currency, destination_address, destination_network,
  bse_tokens_debited, usd_value_at_request, withdrawal_fee_usd, net_usd_amount,
  crypto_amount_sent, crypto_tx_hash, status, settled_at, created_at
)
SELECT
  'a0000000-0000-0000-0000-000000000001',
  wa.id,
  w.crypto_currency::crypto_currency_enum,
  '0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb',
  w.network,
  w.usd_amount,
  w.usd_amount,
  0.00,
  w.usd_amount,
  w.crypto_amount,
  w.tx_hash,
  'completed'::fund_transfer_status_enum,
  w.settled_at::TIMESTAMPTZ,
  w.created_at::TIMESTAMPTZ
FROM wallet.accounts wa,
(VALUES
  -- Figma p10/p11: Row 2 — Withdrawal ETH 1.5 $3,427.50 completed
  ('ETH',  1.5,  'Ethereum', '0x9i8h7g6f...3c2b1a0j', 3427.50, '2024-12-13 15:45:00', '2024-12-13 15:45:00'),
  -- Figma p10/p11: Row 4 — Withdrawal USDT 2,000 $2,000.00 completed
  ('USDT', 2000.0, 'ERC-20', '0x55443322...eeddccbb', 2000.00, '2024-12-12 08:15:00', '2024-12-12 08:15:00')
) AS w(crypto_currency, crypto_amount, network, tx_hash, usd_amount, settled_at, created_at)
WHERE wa.user_id = 'a0000000-0000-0000-0000-000000000001'
ON CONFLICT DO NOTHING;

-- ── Mock Holdings (Figma p10: Your Holdings table — 4 rows) ─────────────────

INSERT INTO trading.holdings (
  user_id, token_id, symbol,
  qty, avg_cost_per_token, total_cost_basis,
  current_nav_per_token, current_value_usd,
  daily_gain_usd, first_bought_at, last_traded_at
)
SELECT
  'a0000000-0000-0000-0000-000000000001',
  st.id,
  h.symbol,
  h.qty,
  h.avg_cost,
  h.qty * h.avg_cost,
  st.current_nav_per_token,
  h.qty * st.current_nav_per_token,
  h.daily_gain,
  h.first_bought::TIMESTAMPTZ,
  NOW() - INTERVAL '3 days'
FROM core.stock_tokens st,
(VALUES
  -- Figma p10 Holdings Row 1: AAPL 25 shares, Avg $165.50, Current $178.25
  ('AAPL-T', 25.0,  165.50, 100.00, '2023-06-15'),
  -- Figma p10 Holdings Row 2: MSFT (shown as AAPL in design) 50 shares Avg $350.20
  ('MSFT-T', 50.0,  350.20, 400.00, '2023-07-20'),
  -- Figma p10 Holdings Row 3: GOOGL 100 shares Avg $138.40
  ('GOOGL-T', 100.0, 138.40, 150.00, '2023-09-01'),
  -- Figma p10 Holdings Row 4: TSLA 30 shares Avg $251.30 (loss position -3.37%)
  ('TSLA-T', 30.0,  251.30, -80.00, '2023-10-10')
) AS h(symbol, qty, avg_cost, daily_gain, first_bought)
WHERE st.symbol = h.symbol
ON CONFLICT (user_id, token_id) DO UPDATE SET
  qty                   = EXCLUDED.qty,
  avg_cost_per_token    = EXCLUDED.avg_cost_per_token,
  total_cost_basis      = EXCLUDED.total_cost_basis,
  current_nav_per_token = EXCLUDED.current_nav_per_token,
  current_value_usd     = EXCLUDED.current_value_usd,
  updated_at            = NOW();

-- ── Mock Watchlist (Figma p10: 5 items in watchlist panel) ──────────────────

INSERT INTO core.watchlist (user_id, token_id, symbol, sort_order)
SELECT
  'a0000000-0000-0000-0000-000000000001',
  st.id,
  w.symbol,
  w.sort_order
FROM core.stock_tokens st,
(VALUES
  ('AAPL-T',  1),  -- Figma p10 watchlist row 1: AAPL $178.25 +13.3%
  ('MSFT-T',  2),  -- Figma p10 watchlist row 2: MSFT $378.91 +1.52%
  ('GOOGL-T', 3),  -- Figma p10 watchlist row 3: Alphabet $141.80 +0.88%
  ('TSLA-T',  4),  -- Figma p10 watchlist row 4: Tesla $242.84 -1.31%
  ('AMZN-T',  5)   -- Figma p10 watchlist row 5: Amazon $151.94 -0.58%
) AS w(symbol, sort_order)
WHERE st.symbol = w.symbol
ON CONFLICT (user_id, token_id) DO NOTHING;

-- ── Mock NAV History (last 30 days for AAPL — powers p10 portfolio chart) ───

INSERT INTO core.nav_history (
  token_id, symbol, nav_date,
  market_close_price, market_open_price, market_high_price, market_low_price,
  trading_volume,
  pool_shares_beginning, pool_shares_net_change, pool_shares_ending,
  gross_pool_value_usd,
  tax_reserve_usd, staking_fee_reserve_usd, platform_fee_reserve_usd,
  expense_ratio_applied,
  net_pool_value_usd, total_tokens_issued, nav_per_token,
  nav_change_amount, nav_change_pct
)
SELECT
  st.id,
  'AAPL-T',
  gen_date::DATE,
  -- Simulate realistic price movement over 30 days ending at $190.40
  160.00 + (ROW_NUMBER() OVER (ORDER BY gen_date) * 1.01),
  159.50 + (ROW_NUMBER() OVER (ORDER BY gen_date) * 1.01),
  161.00 + (ROW_NUMBER() OVER (ORDER BY gen_date) * 1.01),
  158.50 + (ROW_NUMBER() OVER (ORDER BY gen_date) * 1.01),
  50000000 + (RANDOM() * 5000000)::BIGINT,
  200.0, 0.5, 200.5,
  (160.00 + (ROW_NUMBER() OVER (ORDER BY gen_date) * 1.01)) * 200.5,
  100.00, 50.00, 25.00,
  0.01,
  (160.00 + (ROW_NUMBER() OVER (ORDER BY gen_date) * 1.01)) * 200.5 - 175.00,
  25.0,
  ((160.00 + (ROW_NUMBER() OVER (ORDER BY gen_date) * 1.01)) * 200.5 - 175.00) / 25.0,
  1.01, 0.63
FROM core.stock_tokens st,
  GENERATE_SERIES(
    CURRENT_DATE - INTERVAL '30 days',
    CURRENT_DATE - INTERVAL '1 day',
    INTERVAL '1 day'
  ) AS gen_date
WHERE st.symbol = 'AAPL-T'
  AND EXTRACT(DOW FROM gen_date) NOT IN (0, 6)  -- skip weekends
ON CONFLICT (token_id, nav_date) DO NOTHING;

-- ── Mock Notification Preferences (already auto-created by trigger) ─────────
-- Just update marketing to enabled for demo purposes
UPDATE auth.notification_preferences SET
  marketing_email = TRUE,
  marketing_push  = FALSE
WHERE user_id = 'a0000000-0000-0000-0000-000000000001';

-- ── Mock Price Alerts (Figma p23 Price Alerts section) ──────────────────────
INSERT INTO auth.price_alerts (user_id, token_symbol, alert_direction, threshold_price)
VALUES
  ('a0000000-0000-0000-0000-000000000001', 'AAPL-T',  'above', 200.00),
  ('a0000000-0000-0000-0000-000000000001', 'TSLA-T',  'below', 220.00),
  ('a0000000-0000-0000-0000-000000000001', 'NVDA-T',  'above', 550.00)
ON CONFLICT DO NOTHING;

-- ── Mock Portfolio Snapshot (powers p10 performance chart) ──────────────────
INSERT INTO trading.portfolio_snapshots (
  user_id, snapshot_date,
  bse_balance, total_invested_usd, total_portfolio_value,
  day_gain_usd, day_gain_pct,
  total_stocks_held, total_shares_held, total_transactions
)
VALUES (
  'a0000000-0000-0000-0000-000000000001',
  CURRENT_DATE,
  15000.00,
  27866.95,
  144866.95,       -- Figma p10: Total Portfolio Value
  1840.45,         -- Figma p10: "+1840.45 (4.28%) Today"
  4.28,
  4,               -- Figma p10: "Total Stocks: 4"
  205,             -- Figma p10: "Total Stocks: 205 shares" (25+50+100+30)
  4                -- Figma p10: "Transactions: 4"
)
ON CONFLICT (user_id, snapshot_date) DO UPDATE SET
  bse_balance           = EXCLUDED.bse_balance,
  total_invested_usd    = EXCLUDED.total_invested_usd,
  total_portfolio_value = EXCLUDED.total_portfolio_value,
  day_gain_usd          = EXCLUDED.day_gain_usd,
  day_gain_pct          = EXCLUDED.day_gain_pct,
  total_stocks_held     = EXCLUDED.total_stocks_held,
  total_shares_held     = EXCLUDED.total_shares_held,
  total_transactions    = EXCLUDED.total_transactions;

-- ── Verification query: confirm mock data loaded correctly ───────────────────
DO $$
DECLARE
  v_user_count    INTEGER;
  v_token_count   INTEGER;
  v_holding_count INTEGER;
  v_deposit_count INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_user_count    FROM auth.users;
  SELECT COUNT(*) INTO v_token_count   FROM core.stock_tokens;
  SELECT COUNT(*) INTO v_holding_count FROM trading.holdings WHERE qty > 0;
  SELECT COUNT(*) INTO v_deposit_count FROM wallet.deposits;

  RAISE NOTICE '==================================';
  RAISE NOTICE 'Mock Data Load Summary:';
  RAISE NOTICE '  Users:         %', v_user_count;
  RAISE NOTICE '  Stock tokens:  %', v_token_count;
  RAISE NOTICE '  Holdings:      %', v_holding_count;
  RAISE NOTICE '  Deposits:      %', v_deposit_count;
  RAISE NOTICE '==================================';

  IF v_user_count < 2 THEN
    RAISE WARNING 'Expected 2+ users — check auth.users insert';
  END IF;
  IF v_token_count < 8 THEN
    RAISE WARNING 'Expected 8 stock tokens — check core.stock_tokens insert';
  END IF;
END $$;

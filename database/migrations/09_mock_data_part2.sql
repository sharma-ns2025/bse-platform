-- ============================================================================
-- MOCK DATA PART 2: Orders, Stakers, Ledger, Price Feed
-- These were missing from 07_seed_and_mock_data.sql
-- Completes all Figma screens not yet covered.
--
-- COVERS:
--   • Figma p14/p15: Order history + preview modal data
--   • Figma p14:     Staker positions and rewards
--   • Wallet ledger: Double-entry records for all mock transactions
--   • Header ticker: Market price feed (ADA/USD scrolling bar)
-- RUN ORDER: 09 (after 07_seed_and_mock_data.sql)
-- ============================================================================

-- ============================================================================
-- MOCK ORDERS
-- Figma p14: "Orders (0)" tab — current open orders
-- Figma p15: Preview Order modal — BUY 1 SHARES AAPL $190.40
-- History: 4 executed orders matching the 4 holdings rows
-- ============================================================================

-- Executed orders (the ones that created the current holdings)
INSERT INTO trading.orders (
  id,
  user_id,
  account_id,
  token_id,
  symbol,
  side,
  price_type,
  duration,
  requested_qty,
  executed_qty,
  estimated_nav_usd,
  executed_nav_usd,
  investment_total_usd,
  estimated_total_usd,
  executed_total_usd,
  platform_fee_usd,
  expense_ratio,
  buying_power_before_usd,
  buying_power_after_usd,
  brokerage_account_mask,
  status,
  nav_date,
  executed_at,
  created_at
)
SELECT
  o.order_id::UUID,
  'a0000000-0000-0000-0000-000000000001',
  wa.id,
  st.id,
  o.symbol,
  'buy',
  'market',
  'good_for_day',
  o.qty,
  o.qty,
  o.nav_price,
  o.nav_price,
  o.qty * o.nav_price,
  o.qty * o.nav_price,   -- $0 fee (Figma: "Commission: $0.00")
  o.qty * o.nav_price,
  0.00,                  -- Figma p15: "Commission: $0.00"
  0.01,                  -- 1% minimum expense ratio
  o.buying_power_before,
  o.buying_power_before - (o.qty * o.nav_price),
  '****-' || RIGHT('a0000000-0000-0000-0000-000000000001', 4),  -- "****-0001"
  'executed',
  o.nav_date::DATE,
  o.executed_at::TIMESTAMPTZ,
  o.created_at::TIMESTAMPTZ
FROM wallet.accounts wa,
(VALUES
  -- Order 1: 25 AAPL @ $165.50 — matches holdings row 1
  ('a1000000-0000-0000-0000-000000000001', 'AAPL-T', 25.0,  165.50, 20000.00, '2023-06-15', '2023-06-15 16:30:00', '2023-06-15 10:00:00'),
  -- Order 2: 50 MSFT @ $350.20 — matches holdings row 2
  ('a1000000-0000-0000-0000-000000000002', 'MSFT-T', 50.0,  350.20, 40000.00, '2023-07-20', '2023-07-20 16:30:00', '2023-07-20 11:00:00'),
  -- Order 3: 100 GOOGL @ $138.40 — matches holdings row 3
  ('a1000000-0000-0000-0000-000000000003', 'GOOGL-T', 100.0, 138.40, 30000.00, '2023-09-01', '2023-09-01 16:30:00', '2023-09-01 09:30:00'),
  -- Order 4: 30 TSLA @ $251.30 — matches holdings row 4 (loss position)
  ('a1000000-0000-0000-0000-000000000004', 'TSLA-T', 30.0,  251.30, 15000.00, '2023-10-10', '2023-10-10 16:30:00', '2023-10-10 14:00:00')
) AS o(order_id, symbol, qty, nav_price, buying_power_before, nav_date, executed_at, created_at)
JOIN core.stock_tokens st ON st.symbol = o.symbol
WHERE wa.user_id = 'a0000000-0000-0000-0000-000000000001'
ON CONFLICT DO NOTHING;

-- A draft order — Figma p14: "Save for later" button
INSERT INTO trading.orders (
  user_id, account_id, token_id, symbol,
  side, price_type, duration,
  requested_qty, limit_price,
  estimated_nav_usd, estimated_total_usd, estimated_principal_usd,
  buying_power_before_usd, buying_power_after_usd,
  platform_fee_usd, expense_ratio,
  brokerage_account_mask,
  status
)
SELECT
  'a0000000-0000-0000-0000-000000000001',
  wa.id, st.id, 'AAPL-T',
  'buy', 'limit', 'good_for_day',
  6, 190.40,                      -- Figma p14: "6 × $190.40"
  190.40, 1142.40, 1142.40,       -- Figma p14: "Estimated Total: $1142.40"
  5214.00, 4071.60,               -- Figma p14: "Remaining buying power: $4,071.60"
  0.00, 0.01,
  '****-0001',
  'draft'                          -- Figma p14: "Save for later"
FROM wallet.accounts wa, core.stock_tokens st
WHERE wa.user_id = 'a0000000-0000-0000-0000-000000000001'
  AND st.symbol = 'AAPL-T'
ON CONFLICT DO NOTHING;

-- ============================================================================
-- MOCK TRADE POSITIONS (Figma p14: Current Position panel)
-- "50 shares, Avg. cost $185.30, Total value $9,520.00"
-- ============================================================================

INSERT INTO trading.positions (
  user_id, token_id, symbol,
  shares_owned, avg_cost, total_value,
  net_account_value, cash_purchasing_power, settled_balance, unsettled_balance
)
SELECT
  'a0000000-0000-0000-0000-000000000001',
  st.id, 'AAPL-T',
  50, 185.30, 9520.00,            -- Figma p14: Current Position
  10420.55, 5214.00, 5214.00, 0.00  -- Figma p14: Account summary row
FROM core.stock_tokens st WHERE st.symbol = 'AAPL-T'
ON CONFLICT (user_id, token_id) DO UPDATE SET
  shares_owned          = EXCLUDED.shares_owned,
  avg_cost              = EXCLUDED.avg_cost,
  total_value           = EXCLUDED.total_value,
  net_account_value     = EXCLUDED.net_account_value,
  cash_purchasing_power = EXCLUDED.cash_purchasing_power;

-- ============================================================================
-- MOCK STAKER DATA (Sarah Miller is the demo staker)
-- Stakers provide the 1:1 backing for each BSE token issued
-- ============================================================================

-- Staker profile for Sarah
INSERT INTO staking.staker_profiles (
  user_id,
  alpaca_account_id,
  alpaca_key_ref,
  alpaca_verified_at,
  is_whale_staker,
  auto_staking_enabled,
  status,
  total_earned_usd,
  payout_wallet_address
)
VALUES (
  'a0000000-0000-0000-0000-000000000002',
  'alpaca_acct_sarah_mock_001',
  'arn:aws:secretsmanager:us-east-1:123456789:secret:bse/stakers/sarah_miller_alpaca',
  NOW() - INTERVAL '6 months',
  TRUE,     -- whale staker (auto-staking)
  TRUE,
  'active',
  4850.00,  -- Earned $4,850 so far in staking rewards
  '0x3Ab4c7D9e1F2a3B4c5D6e7F8a9B0c1D2e3F4a5'
)
ON CONFLICT (user_id) DO NOTHING;

-- Sarah's staked positions (she holds real AAPL + MSFT + NVDA via Alpaca)
INSERT INTO staking.positions (
  staker_id,
  token_id,
  symbol,
  staked_qty,
  matched_qty,
  is_long_position,
  reward_rate,
  total_reward_usd,
  last_alpaca_sync_at,
  is_active
)
SELECT
  sp.id,
  st.id,
  pos.symbol,
  pos.staked_qty,
  pos.matched_qty,
  TRUE,
  0.007,      -- 70% of expense ratio goes to staker
  pos.total_reward_usd,
  NOW() - INTERVAL '30 minutes',
  TRUE
FROM staking.staker_profiles sp,
(VALUES
  ('AAPL-T',  500.0, 205.0, 2800.00),  -- 500 AAPL staked, 205 matched (to Alex's 25+others)
  ('MSFT-T',  200.0,  50.0, 1400.00),  -- 200 MSFT staked, 50 matched
  ('NVDA-T',  100.0,  20.0,  650.00)   -- 100 NVDA staked, 20 matched
) AS pos(symbol, staked_qty, matched_qty, total_reward_usd)
JOIN core.stock_tokens st ON st.symbol = pos.symbol
WHERE sp.user_id = 'a0000000-0000-0000-0000-000000000002'
ON CONFLICT (staker_id, token_id) DO NOTHING;

-- Update core.stock_tokens with staked supply data
UPDATE core.stock_tokens SET
  total_staked_qty  = 500.0,
  available_supply  = 295.0,   -- 500 staked - 205 matched
  total_tokens_issued = 205.0
WHERE symbol = 'AAPL-T';

UPDATE core.stock_tokens SET
  total_staked_qty  = 200.0,
  available_supply  = 150.0,
  total_tokens_issued = 50.0
WHERE symbol = 'MSFT-T';

-- Mock staking reward payments (last 3 months)
INSERT INTO staking.reward_payments (
  staker_id, position_id,
  nav_date, reward_usd, expense_ratio, matched_volume, status, paid_at
)
SELECT
  sp.id,
  pos.id,
  gen_date::DATE,
  ROUND((RANDOM() * 50 + 20)::NUMERIC, 2),   -- $20-$70 reward per day
  0.01,
  ROUND((RANDOM() * 5000 + 1000)::NUMERIC, 2), -- $1k-$6k daily volume
  'paid',
  gen_date::TIMESTAMPTZ + INTERVAL '1 day'
FROM staking.staker_profiles sp
JOIN staking.positions pos ON pos.staker_id = sp.id
JOIN core.stock_tokens st ON st.id = pos.token_id AND st.symbol = 'AAPL-T',
GENERATE_SERIES(
  CURRENT_DATE - INTERVAL '30 days',
  CURRENT_DATE - INTERVAL '1 day',
  INTERVAL '1 day'
) AS gen_date
WHERE sp.user_id = 'a0000000-0000-0000-0000-000000000002'
  AND EXTRACT(DOW FROM gen_date) NOT IN (0, 6)  -- weekdays only
ON CONFLICT DO NOTHING;

-- ============================================================================
-- MOCK WALLET LEDGER ENTRIES
-- Double-entry records for all mock transactions above.
-- Reconciles to wallet.accounts balance of $15,000
-- ============================================================================

-- Ledger entry for initial large deposit (USDT $5,000)
INSERT INTO wallet.ledger (
  user_id, account_id, tx_type,
  amount, balance_after,
  reference_id, reference_type,
  description, idempotency_key,
  created_at
)
SELECT
  'a0000000-0000-0000-0000-000000000001',
  wa.id,
  tx.tx_type::ledger_tx_type_enum,
  tx.amount,
  tx.balance_after,
  tx.reference_id::UUID,
  tx.ref_type,
  tx.description,
  tx.idem_key,
  tx.created_at::TIMESTAMPTZ
FROM wallet.accounts wa,
(VALUES
  -- Initial deposit credited: +$5,000
  ('deposit',       5000.00,  5000.00,  'a2000000-0000-0000-0000-000000000001', 'deposit',    'USDT deposit $5,000 settled',               'deposit:a2000000-0000-0000-0000-000000000001',    '2024-12-14 09:35:00'),
  -- Buy AAPL 25 × $165.50 = -$4,137.50  balance 862.50
  ('buy_stock',    -4137.50,   862.50,  'a1000000-0000-0000-0000-000000000001', 'order',      'Buy 25 × AAPL-T @ $165.50',                 'buy_order:a1000000-0000-0000-0000-000000000001', '2023-06-15 16:30:00'),
  -- Large deposit to fund remaining buys: +$20,000
  ('deposit',      20000.00, 20862.50,  'a2000000-0000-0000-0000-000000000002', 'deposit',    'USDT deposit $20,000 settled',               'deposit:a2000000-0000-0000-0000-000000000002',   '2023-07-01 09:00:00'),
  -- Buy MSFT 50 × $350.20 = -$17,510.00  balance 3352.50
  ('buy_stock',   -17510.00,  3352.50,  'a1000000-0000-0000-0000-000000000002', 'order',      'Buy 50 × MSFT-T @ $350.20',                 'buy_order:a1000000-0000-0000-0000-000000000002', '2023-07-20 16:30:00'),
  -- Another deposit: +$20,000
  ('deposit',      20000.00, 23352.50,  'a2000000-0000-0000-0000-000000000003', 'deposit',    'USDT deposit $20,000 settled',               'deposit:a2000000-0000-0000-0000-000000000003',   '2023-08-15 09:00:00'),
  -- Buy GOOGL 100 × $138.40 = -$13,840.00  balance 9512.50
  ('buy_stock',   -13840.00,  9512.50,  'a1000000-0000-0000-0000-000000000003', 'order',      'Buy 100 × GOOGL-T @ $138.40',               'buy_order:a1000000-0000-0000-0000-000000000003', '2023-09-01 16:30:00'),
  -- Buy TSLA 30 × $251.30 = -$7,539.00  balance 1973.50
  ('buy_stock',    -7539.00,  1973.50,  'a1000000-0000-0000-0000-000000000004', 'order',      'Buy 30 × TSLA-T @ $251.30',                 'buy_order:a1000000-0000-0000-0000-000000000004', '2023-10-10 16:30:00'),
  -- Top-up deposit: +$13,026.50 → brings balance to $15,000
  ('deposit',      13026.50, 15000.00,  'a2000000-0000-0000-0000-000000000004', 'deposit',    'USDT deposit $13,026.50 settled',            'deposit:a2000000-0000-0000-0000-000000000004',   '2024-11-01 09:00:00')
) AS tx(tx_type, amount, balance_after, reference_id, ref_type, description, idem_key, created_at)
WHERE wa.user_id = 'a0000000-0000-0000-0000-000000000001'
ON CONFLICT (idempotency_key) DO NOTHING;

-- ============================================================================
-- MOCK FUND POOL POSITIONS
-- The actual Alpaca hedge fund positions backing all tokens
-- ============================================================================

INSERT INTO fund.pool_positions (
  token_id, symbol, base_ticker,
  shares_held, avg_cost_basis, current_market_value, last_alpaca_sync_at
)
SELECT
  st.id, p.symbol, p.base_ticker,
  p.shares_held, p.avg_cost, p.current_market_value,
  NOW() - INTERVAL '15 minutes'
FROM (VALUES
  ('AAPL-T',  'AAPL', 200.5, 172.30, 38194.20),
  ('MSFT-T',  'MSFT',  51.0, 380.10, 21180.60),
  ('GOOGL-T', 'GOOGL', 102.0, 131.50, 14550.30),
  ('TSLA-T',  'TSLA',  31.0, 245.80,  7703.50)
) AS p(symbol, base_ticker, shares_held, avg_cost, current_market_value)
JOIN core.stock_tokens st ON st.symbol = p.symbol
ON CONFLICT (token_id) DO UPDATE SET
  shares_held          = EXCLUDED.shares_held,
  current_market_value = EXCLUDED.current_market_value,
  last_alpaca_sync_at  = EXCLUDED.last_alpaca_sync_at;

-- ============================================================================
-- MOCK MARKET PRICE FEED
-- Powers the scrolling ticker bar in Figma header:
-- "ADA/USD 615.75 ↓ -0.67%  ADA/USD 615.75 ↑ +0.78%  ..."
-- ============================================================================

INSERT INTO core.market_price_feed (symbol, price, change_amount, change_pct, direction, source)
VALUES
  ('ADA/USD',  615.75, -4.16,  -0.67, 'D', 'alpaca'),   -- Figma: "ADA/USD 615.75 ↓ -0.67%"
  ('ADA/USD',  615.75,  4.78,  +0.78, 'U', 'alpaca'),   -- Figma: "ADA/USD 615.75 ↑ +0.78%"
  ('BTC/USD',  43250.00, 850.00, 2.01, 'U', 'alpaca'),
  ('ETH/USD',  2285.50, -32.10, -1.39, 'D', 'alpaca'),
  ('USDT/USD', 1.0001,  0.0001, 0.01, 'U', 'alpaca'),
  -- Stock prices in feed
  ('AAPL',    190.40,   1.58,  0.84, 'U', 'alpaca'),
  ('MSFT',    415.20,   8.73,  2.15, 'U', 'alpaca'),
  ('TSLA',    248.50,   8.29,  3.45, 'U', 'alpaca'),
  ('NVDA',    505.48,  20.00,  4.12, 'U', 'alpaca'),
  ('GOOGL',   142.65,  -1.22, -0.85, 'D', 'alpaca')
ON CONFLICT DO NOTHING;

-- ============================================================================
-- MOCK AUDIT EVENTS (sample events for compliance testing)
-- ============================================================================

INSERT INTO audit.events (event_type, actor_user_id, target_type, target_id, payload, severity, service_name)
VALUES
  ('user.registered',      'a0000000-0000-0000-0000-000000000001', 'user',    'a0000000-0000-0000-0000-000000000001',
   '{"method":"firebase","provider":"email"}'::JSONB, 'info', 'auth-service'),

  ('auth.login.success',   'a0000000-0000-0000-0000-000000000001', 'user',    'a0000000-0000-0000-0000-000000000001',
   '{"device":"MacBook Pro","location":"New York, US"}'::JSONB, 'info', 'auth-service'),

  ('wallet.deposit.completed', 'a0000000-0000-0000-0000-000000000001', 'deposit', 'a2000000-0000-0000-0000-000000000001',
   '{"crypto":"USDT","amount":5000,"usd_value":5000}'::JSONB, 'info', 'wallet-service'),

  ('kyc.approved',         'a0000000-0000-0000-0000-000000000001', 'user',    'a0000000-0000-0000-0000-000000000001',
   '{"provider":"jumio","country":"US"}'::JSONB, 'info', 'kyc-service'),

  ('staker.profile.activated', 'a0000000-0000-0000-0000-000000000002', 'user', 'a0000000-0000-0000-0000-000000000002',
   '{"alpaca_account":"alpaca_acct_sarah_mock_001","is_whale":true}'::JSONB, 'info', 'staking-service');

-- ============================================================================
-- FINAL VERIFICATION
-- Checks all 6 key table groups are populated
-- ============================================================================
DO $$
DECLARE
  v_checks JSONB;
BEGIN
  SELECT jsonb_build_object(
    'users',          (SELECT COUNT(*) FROM auth.users),
    'stock_tokens',   (SELECT COUNT(*) FROM core.stock_tokens),
    'wallet_accounts',(SELECT COUNT(*) FROM wallet.accounts),
    'holdings',       (SELECT COUNT(*) FROM trading.holdings WHERE qty > 0),
    'orders',         (SELECT COUNT(*) FROM trading.orders),
    'ledger_entries', (SELECT COUNT(*) FROM wallet.ledger),
    'staker_profiles',(SELECT COUNT(*) FROM staking.staker_profiles),
    'staked_positions',(SELECT COUNT(*) FROM staking.positions WHERE is_active),
    'nav_history',    (SELECT COUNT(*) FROM core.nav_history),
    'audit_events',   (SELECT COUNT(*) FROM audit.events),
    'price_feed',     (SELECT COUNT(*) FROM core.market_price_feed)
  ) INTO v_checks;

  RAISE NOTICE '=== BSE Mock Data Verification ===';
  RAISE NOTICE '%', v_checks::TEXT;
  RAISE NOTICE '===================================';
END $$;

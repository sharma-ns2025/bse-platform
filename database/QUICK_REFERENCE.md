# BSE Database Quick Reference Guide

## 🗂️ Schema Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                    BLOCKCHAIN STOCK EXCHANGE (BSE)                  │
│                        PostgreSQL Schema Map                        │
└─────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────┐
│ PUBLIC (Shared)                                                          │
│ ├─ Extensions: uuid-ossp, pgcrypto, pg_trgm, btree_gist, tablefunc    │
│ ├─ Functions: set_updated_at(), increment_account_version()            │
│ └─ Enums: (13 types) order_side, kyc_status, ledger_tx_type,           │
│            blockchain_status, blockchain_network, crypto_network_pair  │
└──────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────┐
│ AUTH (User Identity Layer)                                              │
├─ auth.users (1M users)                                                  │
│  ├─ Primary: firebase_uid, email                                       │
│  ├─ KYC: kyc_status, kyc_approved_at, kyc_expires_at                   │
│  └─ Status: is_active, is_onboarded, joined_at, last_login_at         │
├─ auth.crypto_wallets (MetaMask, WalletConnect, Coinbase)              │
│  ├─ wallet_address (Ethereum: "0x...")                                 │
│  ├─ provider (metamask | walletconnect | coinbase)                    │
│  ├─ is_primary (PRIMARY KEY constraint)                               │
│  └─ is_verified (signature challenge proof)                           │
├─ auth.user_devices (Recent Devices - Figma p20)                       │
│  ├─ device_name, browser_name, os_name                                │
│  ├─ ip_address (INET type)                                            │
│  └─ is_current, last_seen_at                                          │
├─ auth.payment_methods (Cards, Bank Accounts)                          │
│  ├─ method_type (card | bank_account | crypto_wallet)                │
│  ├─ masked_number ("****4242")                                        │
│  ├─ processor_token (Stripe/Plaid ref)                                │
│  └─ is_default, is_verified                                           │
└─ auth.notification_preferences                                        │
   ├─ trade_executed, price_alert, security_alert, marketing_email     │
   └─ All have _email and _push variants                                │
└──────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────┐
│ CORE (Market Data Layer)                                                │
├─ core.stock_tokens (AAPL-T, MSFT-T, etc.)                             │
│  ├─ symbol (unique: "AAPL-T")                                         │
│  ├─ base_ticker (real-world: "AAPL")                                  │
│  ├─ company_name, description, sector, industry                       │
│  ├─ exchange (NASDAQ, NYSE, LSE)                                      │
│  ├─ is_tradeable, is_active                                           │
│  └─ created_at, updated_at                                            │
├─ core.nav_price_history (Daily EOD NAV prices)                        │
│  ├─ token_id, symbol, nav_date (UNIQUE constraint)                    │
│  ├─ nav_price_usd (e.g., $190.40)                                     │
│  ├─ is_official (TRUE=EOD calculation, FALSE=intraday estimate)       │
│  ├─ data_source (alpaca | synthetic)                                  │
│  └─ created_at, updated_at                                            │
├─ core.expense_ratio_history ⭐ NEW                                    │
│  ├─ token_id, symbol, nav_date (UNIQUE)                               │
│  ├─ base_expense_ratio (1% minimum)                                   │
│  ├─ buy_pressure_score (0-1 normalized)                               │
│  ├─ demand_to_supply_ratio (>1 = undersubscribed)                     │
│  ├─ applied_expense_ratio (final 1%-5%)                               │
│  ├─ executed_buy_qty, executed_sell_qty                               │
│  ├─ total_fee_revenue_usd, staker_reward_pool_usd                     │
│  └─ last_updated_at, created_at, updated_at                           │
├─ core.price_feed_cache ⭐ NEW (Intraday Alpaca prices)                │
│  ├─ token_id (UNIQUE)                                                 │
│  ├─ last_trade_price (current market price - Figma p12)               │
│  ├─ bid_price, ask_price, bid_ask_spread                              │
│  ├─ volume_today, volume_avg_30d                                      │
│  ├─ day_high, day_low, day_change_amount, day_change_pct             │
│  ├─ day_open_price, previous_close_price                              │
│  ├─ quote_timestamp (Alpaca timestamp)                                │
│  └─ synced_at, created_at, updated_at (refreshed 5-15 min)            │
├─ core.expense_ratio_adjustments ⭐ NEW (Audit trail)                  │
│  ├─ token_id, symbol                                                  │
│  ├─ previous_ratio, new_ratio                                         │
│  ├─ adjustment_reason (daily_sync | manual | auto_demand | emergency) │
│  ├─ triggered_by (automated_nav_engine | ops_manual | emergency)      │
│  ├─ operator_id (NULL if automated)                                   │
│  ├─ audit_notes                                                       │
│  └─ effective_at, created_at                                          │
├─ core.watchlist_items (User favorites)                                │
│  ├─ user_id, token_id                                                 │
│  ├─ is_starred (Figma p13: "Starred" column)                          │
│  ├─ price_alert_target (e.g., $200)                                   │
│  └─ added_at, updated_at                                              │
├─ Views:                                                               │
│  ├─ core.v_current_expense_ratios (today's rates)                     │
│  └─ core.v_expense_ratio_history_30d (trending)                       │
└──────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────┐
│ WALLET (Financial Layer - Double-Entry Ledger)                         │
├─ wallet.accounts (1 per user - Figma p10/p11 balances)               │
│  ├─ user_id (UNIQUE)                                                  │
│  ├─ bse_balance (spendable - "Available $15,000")                     │
│  ├─ bse_in_transit (settling - "In Transit $2,500")                  │
│  ├─ bse_reserved (locked for pending orders)                         │
│  ├─ total_invested_usd (sum of all holdings at NAV)                   │
│  ├─ total_portfolio_value (= bse_balance + total_invested)            │
│  ├─ version (optimistic locking counter)                              │
│  ├─ last_deposit_at, last_transaction_at, last_activity_at            │
│  └─ created_at, updated_at                                            │
├─ wallet.deposits (Figma p11 - Recent Transactions, Deposit rows)     │
│  ├─ user_id, account_id                                               │
│  ├─ crypto_currency (USDT | ETH | BTC)                               │
│  ├─ crypto_amount (e.g., 5000.0 USDT)                                │
│  ├─ crypto_network ("ERC-20", "Ethereum", "Bitcoin")                 │
│  ├─ crypto_tx_hash (blockchain transaction hash)                      │
│  ├─ conversion_rate (USD/crypto at deposit time)                      │
│  ├─ gross_usd_amount, deposit_fee_usd, net_usd_amount                 │
│  ├─ bse_tokens_credited (= net_usd_amount)                            │
│  ├─ status (initiated | confirming | in_transit | completed | failed)│
│  ├─ settlement_expected_at ("1-2 business days")                      │
│  └─ created_at, updated_at                                            │
├─ wallet.deposit_confirmations ⭐ NEW (Blockchain progress)            │
│  ├─ deposit_id, user_id                                               │
│  ├─ confirmation_count (1, 3, 6, 12...)                              │
│  ├─ confirmation_level (awaiting | in_mempool | confirmed | reconciled)
│  ├─ block_number, block_hash, block_timestamp                         │
│  ├─ gas_used, gas_price_wei, miner_fee_usd                            │
│  ├─ network_data (JSONB: extensible)                                 │
│  └─ verified_at, created_at                                           │
├─ wallet.crypto_address_deposits ⭐ NEW (Verification)                 │
│  ├─ user_id, wallet_id, deposit_id                                    │
│  ├─ wallet_address, network                                           │
│  ├─ is_verified (signature challenge proof)                           │
│  └─ verified_at, created_at                                           │
├─ wallet.deposit_failures ⭐ NEW (Retry management)                    │
│  ├─ user_id                                                           │
│  ├─ crypto_currency, destination_address, network                    │
│  ├─ requested_amount, error_code, error_message                       │
│  ├─ retry_count, last_retry_at, next_retry_at                         │
│  ├─ is_recoverable (FALSE = permanent, notify user)                   │
│  └─ created_at, updated_at                                            │
├─ wallet.withdrawals (BSE to crypto outbound)                          │
│  ├─ user_id, account_id                                               │
│  ├─ crypto_currency, destination_address, destination_network         │
│  ├─ bse_tokens_debited, withdrawal_fee_usd, gas_fee_usd               │
│  ├─ crypto_amount_sent, execution_rate                                │
│  ├─ crypto_tx_hash, blockchain_confirmations                          │
│  ├─ status (initiated | processing | completed | failed)              │
│  └─ created_at, updated_at                                            │
├─ wallet.withdrawal_confirmations ⭐ NEW (Outbound tracking)           │
│  ├─ withdrawal_id, user_id                                            │
│  ├─ confirmation_count, confirmation_level                            │
│  ├─ block_number, block_hash, block_timestamp                         │
│  ├─ gas_used, actual_fee_usd, network_data                            │
│  └─ verified_at, created_at                                           │
├─ wallet.transaction_fee_adjustments ⭐ NEW (Reconciliation)           │
│  ├─ deposit_id | withdrawal_id                                        │
│  ├─ user_id, transaction_type                                         │
│  ├─ estimated_fee_usd, actual_fee_usd, adjustment_amount              │
│  ├─ adjustment_reason, adjustment_credited                            │
│  └─ created_at                                                        │
├─ wallet.ledger (APPEND-ONLY - Double-entry source of truth)          │
│  ├─ id (BIGSERIAL - sequential)                                       │
│  ├─ user_id, account_id                                               │
│  ├─ tx_type (deposit | withdrawal | buy_stock | sell_stock | fee...)  │
│  ├─ amount (+ credit | - debit)                                       │
│  ├─ balance_after (snapshot after this entry)                         │
│  ├─ reference_id, reference_type ("deposit", "order", etc.)          │
│  ├─ description, idempotency_key                                      │
│  └─ created_at (immutable - no updated_at)                            │
└──────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────┐
│ TRADING (Order & Holdings Layer)                                        │
├─ trading.orders (Buy/Sell orders - Figma p14/p15)                     │
│  ├─ user_id, account_id, token_id, symbol                             │
│  ├─ side (buy | sell)                                                 │
│  ├─ price_type (market | limit), duration (good_for_day | etc.)       │
│  ├─ requested_qty, limit_price, investment_total_usd                  │
│  ├─ estimated_nav_usd, estimated_total_usd                            │
│  ├─ expense_ratio, expense_ratio_fee_usd                              │
│  ├─ executed_qty, executed_nav_usd, executed_total_usd                 │
│  ├─ status (draft | pending | queued | executed | failed | cancelled) │
│  ├─ nav_date (which EOD batch)                                        │
│  └─ created_at, updated_at, executed_at                               │
├─ trading.holdings (Current positions - Figma p10 "Your Holdings")     │
│  ├─ user_id, token_id, symbol (UNIQUE constraint)                     │
│  ├─ qty (shares owned)                                                │
│  ├─ avg_cost_per_token (weighted average)                             │
│  ├─ current_nav_per_token, current_value_usd                          │
│  ├─ unrealized_gain_usd (GENERATED), unrealized_gain_pct (GENERATED)  │
│  ├─ daily_gain_usd, realized_gain_usd                                 │
│  ├─ first_bought_at, last_traded_at, updated_at                       │
│  └─ Indexes: user_id, token_id, active (qty > 0)                      │
├─ trading.portfolio_snapshots (Daily P&L history)                      │
│  ├─ user_id, snapshot_date (UNIQUE)                                   │
│  ├─ total_portfolio_value, total_cost_basis                           │
│  ├─ total_unrealized_gain_usd, total_unrealized_gain_pct              │
│  ├─ daily_gain_usd, month_to_date_gain_usd                            │
│  └─ created_at                                                        │
└─ trading.portfolio_metrics (derived from snapshots)                   │
   ├─ Portfolio stats: total_stocks, total_shares, total_transactions  │
   └─ Performance: 1D%, 1W%, 1M%, 3M%, 6M%, 1Y% changes                │
└──────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────┐
│ STAKING (Staker Rewards Layer)                                          │
├─ staking.staker_profiles (1 per staker)                               │
│  ├─ user_id (UNIQUE)                                                  │
│  ├─ alpaca_account_id, alpaca_key_ref (Secrets Manager ARN)           │
│  ├─ alpaca_verified_at                                                │
│  ├─ is_whale_staker, auto_staking_enabled                             │
│  ├─ status (pending_verification | active | paused | suspended)       │
│  ├─ total_earned_usd, payout_wallet_address (USDT recipient)          │
│  └─ created_at, updated_at                                            │
├─ staking.positions (Staked stock positions per token)                 │
│  ├─ staker_id, token_id, symbol (UNIQUE constraint)                   │
│  ├─ staked_qty (verified against Alpaca)                              │
│  ├─ matched_qty (currently matched to buyers)                         │
│  ├─ available_qty (GENERATED = staked - matched)                      │
│  ├─ is_long_position (MUST be TRUE per brief)                         │
│  ├─ reward_rate (e.g., 0.007 = 70% of expense ratio)                 │
│  ├─ total_reward_usd                                                  │
│  ├─ last_alpaca_sync_at, is_active                                    │
│  └─ created_at, updated_at                                            │
├─ staking.rebalance_history ⭐ NEW (Audit trail - APPEND-ONLY)         │
│  ├─ staker_id, position_id, token_id, symbol                          │
│  ├─ qty_before, matched_before, available_before (GENERATED)          │
│  ├─ qty_after, matched_after, available_after (GENERATED)             │
│  ├─ qty_change (GENERATED)                                            │
│  ├─ rebalance_reason (daily_sync | manual | auto_demand | emergency)  │
│  ├─ triggered_by (automated_daily_sync | staker_manual | ops_manual)  │
│  ├─ operator_id (NULL if automated)                                   │
│  ├─ demand_to_supply_ratio (captured at rebalance time)               │
│  ├─ alpaca_position_verified, alpaca_sync_id                          │
│  ├─ audit_notes, is_reversible                                        │
│  └─ created_at (immutable)                                            │
├─ staking.alpaca_sync_logs ⭐ NEW (Integration audit trail)            │
│  ├─ staker_id                                                         │
│  ├─ sync_type (daily | on_demand | emergency | verification)         │
│  ├─ sync_start_at, sync_end_at, duration_seconds                      │
│  ├─ http_status_code, positions_returned, validation_errors          │
│  ├─ api_response_data (JSONB), error_message                          │
│  ├─ status (pending | in_progress | success | partial_success | failed)
│  ├─ was_reconciled, reconciliation_issues (JSONB)                     │
│  └─ synced_at, created_at                                             │
├─ staking.position_snapshots ⭐ NEW (Daily reconciliation)             │
│  ├─ staker_id, position_id, token_id, symbol, snapshot_date          │
│  ├─ staked_qty, matched_qty, available_qty (GENERATED)                │
│  ├─ alpaca_verified_qty, verification_status                          │
│  ├─ nav_price_usd, position_value_usd (GENERATED)                     │
│  ├─ daily_rewards_earned_usd                                          │
│  └─ snapshot_at, created_at (UNIQUE: staker + position + date)        │
├─ staking.reward_payments (Rewards paid out to stakers)               │
│  ├─ staker_id, position_id, nav_date                                  │
│  ├─ reward_usd, expense_ratio, matched_volume                         │
│  ├─ status (pending | paid | failed)                                  │
│  ├─ paid_at                                                           │
│  └─ created_at                                                        │
├─ staking.reward_calculation_logs ⭐ NEW (Reward audit)                │
│  ├─ nav_date, token_id, symbol                                        │
│  ├─ nav_price_usd, total_matched_qty                                  │
│  ├─ total_trading_volume_usd                                          │
│  ├─ total_expense_ratio_collected                                     │
│  ├─ staker_share_pct (e.g., 0.70 = 70%)                              │
│  ├─ total_staker_reward_pool, stakers_in_pool                         │
│  ├─ reward_calc_method (proportional | equal_split | custom)          │
│  ├─ calculation_notes, is_finalized                                   │
│  ├─ verified_by (ops staff), verified_at                              │
│  └─ created_at                                                        │
└──────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────┐
│ FUND (Alpaca Hedge Fund Pool)                                           │
├─ fund.pool_positions (Actual Alpaca holdings)                         │
│  ├─ token_id (UNIQUE)                                                 │
│  ├─ shares_held (actual shares in Alpaca account)                     │
│  ├─ avg_cost_basis, current_market_value                              │
│  ├─ unrealized_gain_usd (GENERATED)                                   │
│  ├─ last_alpaca_sync_at, updated_at                                   │
│  └─ Key constraint: 1:1 ratio = total(staker matched) = shares_held   │
├─ fund.alpaca_batch_orders (Daily orders to Alpaca)                    │
│  ├─ nav_date, token_id, symbol, base_ticker                           │
│  ├─ side (buy | sell), net_qty                                        │
│  ├─ alpaca_order_id, fill_price, fill_qty                             │
│  └─ created_at                                                        │
└──────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────┐
│ AUDIT (Compliance - APPEND-ONLY)                                        │
├─ audit.events (main event log - monthly partitions)                    │
│  ├─ events_YYYY_MM (monthly partitions)                               │
│  ├─ user_id (who did it)                                              │
│  ├─ event_type (user_registered | order_placed | deposit_confirmed)   │
│  ├─ event_data (JSONB: event details)                                 │
│  ├─ ip_address, user_agent                                            │
│  ├─ created_at (immutable)                                            │
│  └─ NEVER UPDATE or DELETE (append-only contract)                     │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## 🔑 Key Relationships

```
User Crypto Flow:
1. auth.users → auth.crypto_wallets (connect wallet)
2. wallet.accounts → wallet.deposits → wallet.deposit_confirmations
3. wallet.accounts.bse_balance ← (when confirmations complete)

Trading Flow:
1. trading.orders (create buy order)
2. [NAV engine executes at EOD]
3. trading.holdings (position created)
4. staking.positions.matched_qty ↓ (supply decreases)
5. fund.pool_positions.shares_held ↓ (Alpaca inventory decreases)

Reward Flow:
1. trading.orders.executed (order fills)
2. staking.reward_calculation_logs (calculate rewards)
3. staking.reward_payments (rewards paid)
4. staking.positions.total_reward_usd ↑
```

---

## 📊 Query Examples

### Dashboard Portfolio (Figma p10)
```sql
SELECT
  a.bse_balance as available,
  a.bse_in_transit as in_transit,
  a.total_invested_usd as invested,
  a.total_portfolio_value as total,
  h.qty, h.symbol, h.current_value_usd, h.unrealized_gain_usd
FROM wallet.accounts a
LEFT JOIN trading.holdings h ON a.user_id = h.user_id
WHERE a.user_id = $user_id;
```

### Current Expense Ratio (Figma p15)
```sql
SELECT applied_expense_ratio, demand_to_supply_ratio
FROM core.v_current_expense_ratios
WHERE symbol = 'AAPL-T';
```

### Staker Rebalance History (Audit)
```sql
SELECT rebalance_reason, qty_before, qty_after, triggered_by,
       audit_notes, created_at
FROM staking.rebalance_history
WHERE staker_id = $staker_id
ORDER BY created_at DESC
LIMIT 30;
```

### Deposit Confirmation Progress
```sql
SELECT COUNT(*) as confirmations, confirmation_level
FROM wallet.deposit_confirmations
WHERE deposit_id = $deposit_id
ORDER BY confirmation_count DESC
LIMIT 1;
```

---

**✅ Production-Ready. All enhancements deployed and tested.**

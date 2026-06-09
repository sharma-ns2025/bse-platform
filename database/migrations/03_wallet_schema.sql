-- ============================================================================
-- SCHEMA: wallet
-- PURPOSE: All money movement. Double-entry ledger ensures every dollar
--          is accounted for. ACID compliance enforced via row-level locks
--          and optimistic versioning on the accounts table.
--
-- FIGMA SCREENS COVERED:
--   • Page 10 (Dashboard): Total Balance $44,866.95, Available $15,000,
--     In Transit $2,500, Invested $27,866.95, Add Money / Deposit widget
--   • Page 11 (Account Balance): Total Balance $29,377.65, Crypto Assets —
--     USDT 15,420.5, wallet address 0x742d35Cc..., Deposit/Withdraw buttons
--   • Page 16 (Deposit Money modal): "Deposit Money — zero commission fees"
--     Instant Deposits, 0% Commission, Secure & Insured features
--   • Both pages: Recent Transactions table — Type, Crypto, Amount,
--     USD Value, Status, Network, Transaction Hash, Date & Time
--
-- DOUBLE-ENTRY LEDGER RULE:
--   Every financial event creates TWO or more ledger rows that net to zero:
--   Deposit USDT $5,000 →
--     + $5,000 credit to user account (ledger row)
--     + $5,000 debit to platform liability account (ledger row)
--   This ensures wallet.accounts.bse_balance is always reconcilable.
--
-- RUN ORDER: 03 (after 02_core_schema.sql)
-- ============================================================================

SET search_path TO wallet, public;

-- ============================================================================
-- TABLE: wallet.accounts
-- One row per user. The live balance snapshot.
-- CONCURRENCY: Use SELECT FOR UPDATE + version check on every debit operation.
-- ============================================================================
CREATE TABLE IF NOT EXISTS wallet.accounts (
  id                  UUID            PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id             UUID            NOT NULL UNIQUE REFERENCES auth.users(id) ON DELETE RESTRICT,
    -- RESTRICT prevents deleting a user who has a wallet (data safety)

  -- ── BSE Token Balances (1 BSE token ≈ 1 USDT) ────────────────────────────
  bse_balance         NUMERIC(20, 8)  NOT NULL DEFAULT 0
                      CHECK (bse_balance >= 0),
    -- Figma p10/p11: "Available $15,000.00" — spendable BSE tokens
    -- Constraint prevents negative balance at DB level (safety net)

  bse_in_transit      NUMERIC(20, 8)  NOT NULL DEFAULT 0
                      CHECK (bse_in_transit >= 0),
    -- Figma p10: "In Transit $2,500.00 — Processing deposits take 1-2 business days"
    -- Crypto received but Alpaca settlement not yet complete (T+1 to T+7)

  bse_reserved        NUMERIC(20, 8)  NOT NULL DEFAULT 0
                      CHECK (bse_reserved >= 0),
    -- Funds locked for pending buy orders (queued but not executed)
    -- Prevents user from spending same funds twice before EOD settlement

  -- ── Portfolio Value Cache (updated daily by nav_engine) ──────────────────
  total_invested_usd  NUMERIC(20, 8)  NOT NULL DEFAULT 0
                      CHECK (total_invested_usd >= 0),
    -- Figma p10: "Invested $27,866.95" — sum of all active holdings at current NAV
    -- Denormalized for dashboard speed; recomputed by NAV engine each day

  total_portfolio_value NUMERIC(20, 8) NOT NULL DEFAULT 0,
    -- Figma p10: "Total Portfolio Value $144,866.95"
    -- = bse_balance + total_invested_usd

  -- ── Concurrency Control ───────────────────────────────────────────────────
  version             BIGINT          NOT NULL DEFAULT 0,
    -- Optimistic locking: increment on every balance change.
    -- Application checks: UPDATE ... WHERE version = $current_version
    -- If 0 rows affected → concurrent modification detected → retry

  -- ── Activity Tracking ─────────────────────────────────────────────────────
  last_deposit_at     TIMESTAMPTZ,
    -- Figma p10: "Last Activity 2 Nov, 2024 at 09:00 AM"
  last_transaction_at TIMESTAMPTZ,
  last_activity_at    TIMESTAMPTZ,

  created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_wallet_accounts_updated_at
  BEFORE UPDATE ON wallet.accounts
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Auto-increment version on every update (optimistic lock)
CREATE OR REPLACE FUNCTION wallet.increment_account_version()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.version := OLD.version + 1;
  RETURN NEW;
END;
$$;
CREATE TRIGGER trg_wallet_accounts_version
  BEFORE UPDATE ON wallet.accounts
  FOR EACH ROW EXECUTE FUNCTION wallet.increment_account_version();

-- Auto-create wallet account for every new user
CREATE OR REPLACE FUNCTION wallet.create_account_for_user()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO wallet.accounts (user_id)
  VALUES (NEW.id)
  ON CONFLICT (user_id) DO NOTHING;
  RETURN NEW;
END;
$$;
CREATE TRIGGER trg_auth_users_create_wallet
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION wallet.create_account_for_user();

COMMENT ON TABLE wallet.accounts IS
  'Live balance per user. bse_balance = spendable, bse_in_transit = settling deposits, '
  'bse_reserved = locked for pending orders. Use SELECT FOR UPDATE on any debit operation.';
COMMENT ON COLUMN wallet.accounts.version IS
  'Optimistic lock counter. Increment on every balance write. '
  'Application MUST check affected rows > 0 after UPDATE; if 0, retry from fresh read.';

-- ============================================================================
-- TABLE: wallet.deposits
-- Figma p11: Recent Transactions rows with Type=Deposit
-- Columns: Type, Crypto, Amount, USD Value, Status, Network, Transaction Hash, Date & Time
-- ============================================================================
CREATE TABLE IF NOT EXISTS wallet.deposits (
  id                      UUID            PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id                 UUID            NOT NULL REFERENCES auth.users(id),
  account_id              UUID            NOT NULL REFERENCES wallet.accounts(id),

  -- ── Crypto Side (what the user sent) ─────────────────────────────────────
  crypto_currency         crypto_currency_enum NOT NULL,
    -- Figma p11: "USDT", "ETH", "BTC" in Crypto column
  crypto_amount           NUMERIC(30, 18) NOT NULL CHECK (crypto_amount > 0),
    -- Figma p11: "5,000" (USDT), "1.5" (ETH), "0.1" (BTC)
    -- 18 decimal places = full ERC-20/Wei precision
  crypto_network          VARCHAR(30)     NOT NULL,
    -- Figma p11: "ERC-20", "Ethereum", "Bitcoin"
  crypto_tx_hash          VARCHAR(100),
    -- Figma p11: "0x1a2b3c4d...7g8h9i0j" — blockchain transaction hash
  crypto_from_address     VARCHAR(100),
    -- Sender wallet address (for verification/fraud checks)
  blockchain_confirmations INTEGER        NOT NULL DEFAULT 0,
    -- Number of block confirmations received. Typically need 6+ for USDT/ETH

  -- ── USD Conversion (at time of deposit) ───────────────────────────────────
  conversion_rate         NUMERIC(20, 8)  NOT NULL,
    -- Crypto/USD rate at moment of deposit (from CoinMarketCap/Chainlink)
  gross_usd_amount        NUMERIC(20, 8)  NOT NULL,
    -- Figma p11: "USD Value: $5,000.00" — gross_usd = crypto_amount * rate
  deposit_fee_usd         NUMERIC(20, 8)  NOT NULL DEFAULT 0,
    -- Platform deposit fee (currently 0% per Figma p16: "0% Commission")
  net_usd_amount          NUMERIC(20, 8)  NOT NULL,
    -- = gross_usd - deposit_fee. This is BSE tokens credited.

  -- ── BSE Credit ────────────────────────────────────────────────────────────
  bse_tokens_credited     NUMERIC(20, 8),
    -- NULL until deposit reaches 'completed' status
  credited_to_transit_at  TIMESTAMPTZ,
    -- When tokens moved to bse_in_transit (confirming → in_transit)
  credited_to_balance_at  TIMESTAMPTZ,
    -- When tokens moved to bse_balance (in_transit → completed)

  -- ── Status Lifecycle ──────────────────────────────────────────────────────
  status                  fund_transfer_status_enum NOT NULL DEFAULT 'initiated',
    -- Figma p11: green "✓ completed" or yellow "⏳ pending" badges
  settlement_expected_at  TIMESTAMPTZ,
    -- Figma p10: "Processing deposits will take 1-2 business days"
  settled_at              TIMESTAMPTZ,

  -- ── External References ───────────────────────────────────────────────────
  external_ref            VARCHAR(255),
    -- Coinbase Commerce, Fireblocks, or other payment provider reference
  alpaca_transfer_id      VARCHAR(100),
    -- Alpaca ACH/wire transfer ID once funds hit broker account
  failure_reason          TEXT,

  created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
  updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_wallet_deposits_updated_at
  BEFORE UPDATE ON wallet.deposits
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE INDEX IF NOT EXISTS idx_wallet_deposits_user_id    ON wallet.deposits(user_id);
CREATE INDEX IF NOT EXISTS idx_wallet_deposits_status     ON wallet.deposits(status) WHERE status NOT IN ('completed', 'failed', 'refunded');
CREATE INDEX IF NOT EXISTS idx_wallet_deposits_tx_hash    ON wallet.deposits(crypto_tx_hash) WHERE crypto_tx_hash IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_wallet_deposits_created    ON wallet.deposits(user_id, created_at DESC);

COMMENT ON TABLE wallet.deposits IS 'Crypto deposit records. Figma p11 Recent Transactions (deposit rows). Status moves: initiated→confirming→in_transit→completed. BSE tokens credited at completed.';

-- ============================================================================
-- TABLE: wallet.withdrawals
-- Figma p11: Recent Transactions rows with Type=Withdrawal
-- ============================================================================
CREATE TABLE IF NOT EXISTS wallet.withdrawals (
  id                      UUID            PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id                 UUID            NOT NULL REFERENCES auth.users(id),
  account_id              UUID            NOT NULL REFERENCES wallet.accounts(id),

  -- ── Requested Withdrawal ──────────────────────────────────────────────────
  crypto_currency         crypto_currency_enum NOT NULL,
    -- Figma p11: "ETH", "USDT" in Crypto column for withdrawals
  destination_address     VARCHAR(100)    NOT NULL,
    -- User's receiving wallet address
  destination_network     VARCHAR(30)     NOT NULL,
    -- "ERC-20", "Ethereum", "Bitcoin"

  -- ── BSE Token Debit ───────────────────────────────────────────────────────
  bse_tokens_debited      NUMERIC(20, 8)  NOT NULL CHECK (bse_tokens_debited > 0),
    -- BSE tokens removed from bse_balance when withdrawal initiated
  usd_value_at_request    NUMERIC(20, 8)  NOT NULL,
    -- USD equivalent at time withdrawal was requested

  -- ── Fee Calculation ───────────────────────────────────────────────────────
  withdrawal_fee_usd      NUMERIC(20, 8)  NOT NULL DEFAULT 0,
  gas_fee_usd             NUMERIC(20, 8),
    -- Blockchain gas fee estimate at time of request
  net_usd_amount          NUMERIC(20, 8)  NOT NULL,
    -- = bse_tokens_debited - withdrawal_fee - gas_fee

  -- ── Crypto Execution ──────────────────────────────────────────────────────
  crypto_amount_sent      NUMERIC(30, 18),
    -- Actual crypto amount sent (net_usd / rate at execution time)
  execution_rate          NUMERIC(20, 8),
    -- USD/crypto rate at execution
  crypto_tx_hash          VARCHAR(100),
    -- Figma p11: Transaction Hash column
  blockchain_confirmations INTEGER        NOT NULL DEFAULT 0,

  -- ── Status ────────────────────────────────────────────────────────────────
  status                  fund_transfer_status_enum NOT NULL DEFAULT 'initiated',
  failure_reason          TEXT,
  processed_at            TIMESTAMPTZ,
  settled_at              TIMESTAMPTZ,

  created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
  updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_wallet_withdrawals_updated_at
  BEFORE UPDATE ON wallet.withdrawals
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE INDEX IF NOT EXISTS idx_wallet_withdrawals_user_id ON wallet.withdrawals(user_id);
CREATE INDEX IF NOT EXISTS idx_wallet_withdrawals_status  ON wallet.withdrawals(status) WHERE status NOT IN ('completed','failed');

COMMENT ON TABLE wallet.withdrawals IS 'Crypto withdrawal records. BSE tokens debited immediately on request; crypto sent after processing. Figma p11 Recent Transactions (withdrawal rows).';

-- ============================================================================
-- TABLE: wallet.ledger
-- THE SOURCE OF TRUTH for all balance changes.
-- Double-entry bookkeeping: every financial event = ≥2 ledger rows.
-- This table is APPEND-ONLY. Rows are never updated or deleted.
-- ============================================================================
CREATE TABLE IF NOT EXISTS wallet.ledger (
  id              BIGSERIAL       PRIMARY KEY,
    -- BIGSERIAL (not UUID) for ledger: sequential ID guarantees ordering
    -- and is faster for range queries on financial reconciliation

  user_id         UUID            NOT NULL REFERENCES auth.users(id),
  account_id      UUID            NOT NULL REFERENCES wallet.accounts(id),

  -- ── Transaction Classification ────────────────────────────────────────────
  tx_type         ledger_tx_type_enum NOT NULL,
    -- deposit | withdrawal | buy_stock | sell_stock | trading_fee |
    -- expense_ratio_fee | staking_reward | nav_adjustment | refund

  -- ── Amount ────────────────────────────────────────────────────────────────
  amount          NUMERIC(20, 8)  NOT NULL,
    -- Positive = CREDIT (money added), Negative = DEBIT (money removed)
    -- Zero is disallowed: prevents phantom entries
  CHECK (amount != 0),

  -- ── Running Balance Snapshot ──────────────────────────────────────────────
  balance_after   NUMERIC(20, 8)  NOT NULL,
    -- Account bse_balance AFTER this ledger entry was applied.
    -- Enables point-in-time balance reconstruction and audit reconciliation.

  -- ── Cross-References ──────────────────────────────────────────────────────
  reference_id    UUID,
    -- FK to source record: deposit.id, withdrawal.id, order.id etc.
  reference_type  VARCHAR(30),
    -- 'deposit' | 'withdrawal' | 'order' | 'staking_reward' | 'manual'
  description     TEXT,
    -- Human-readable description for transaction history display

  -- ── Idempotency ───────────────────────────────────────────────────────────
  idempotency_key VARCHAR(100)    UNIQUE,
    -- Prevents duplicate ledger entries from retry logic.
    -- Format: '<type>:<reference_id>' e.g. 'deposit:uuid'

  created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW()
    -- Ledger rows have NO updated_at — they are immutable
);

-- Partial index for fast transaction history by user (paginated API)
CREATE INDEX IF NOT EXISTS idx_wallet_ledger_user_created   ON wallet.ledger(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_wallet_ledger_reference      ON wallet.ledger(reference_id, reference_type) WHERE reference_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_wallet_ledger_tx_type        ON wallet.ledger(tx_type, created_at DESC);

COMMENT ON TABLE wallet.ledger IS
  'Immutable double-entry ledger. Every balance change = minimum two rows. '
  'NEVER update or delete rows. balance_after enables balance reconstruction at any point in time. '
  'Reconcile: SUM(amount) for user should equal wallet.accounts.bse_balance.';

-- ============================================================================
-- TABLE: wallet.transfers
-- Figma p11: Recent Transactions row with Type="Transfer"
-- Internal user-to-user transfers (e.g. BSE token gifts, referral rewards)
-- ============================================================================
CREATE TABLE IF NOT EXISTS wallet.transfers (
  id              UUID            PRIMARY KEY DEFAULT uuid_generate_v4(),
  from_user_id    UUID            NOT NULL REFERENCES auth.users(id),
  to_user_id      UUID            NOT NULL REFERENCES auth.users(id),
  amount_bse      NUMERIC(20, 8)  NOT NULL CHECK (amount_bse > 0),
  usd_value       NUMERIC(20, 8)  NOT NULL,
  note            TEXT,
    -- Optional memo (e.g. "Referral bonus")
  status          fund_transfer_status_enum NOT NULL DEFAULT 'initiated',
  completed_at    TIMESTAMPTZ,
  created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_wallet_transfers_from ON wallet.transfers(from_user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_wallet_transfers_to   ON wallet.transfers(to_user_id,   created_at DESC);

COMMENT ON TABLE wallet.transfers IS 'Internal BSE token transfers between users. Figma p11 "Transfer" row type.';

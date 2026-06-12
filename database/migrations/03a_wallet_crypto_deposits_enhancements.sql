-- ============================================================================
-- ENHANCEMENT: wallet schema - Blockchain Deposits/Withdrawals & Crypto Tracking
-- PURPOSE: Add comprehensive blockchain transaction tracking for USDT, ETH, BTC
--          deposits and withdrawals with confirmation management.
--
-- This file extends wallet schema with:
--   • wallet_deposit_confirmations - blockchain confirmation tracking
--   • wallet_address_deposits - deposits linked to wallet addresses
--   • crypto_deposit_failures - failed transaction handling
--
-- RUN ORDER: After 03_wallet_schema.sql (before views)
-- ============================================================================

SET search_path TO wallet, public;

-- ============================================================================
-- TABLE: wallet.deposit_confirmations
-- Tracks blockchain confirmations for each deposit.
-- One row per deposit per confirmation checkpoint (1, 3, 6 confirmations).
-- Enables monitoring of confirmation progress real-time for UI.
-- ============================================================================
CREATE TABLE IF NOT EXISTS wallet.deposit_confirmations (
  id                  UUID            PRIMARY KEY DEFAULT uuid_generate_v4(),
  deposit_id          UUID            NOT NULL REFERENCES wallet.deposits(id) ON DELETE CASCADE,
  user_id             UUID            NOT NULL REFERENCES auth.users(id),

  -- Blockchain confirmation milestone
  confirmation_count  INTEGER         NOT NULL CHECK (confirmation_count > 0),
    -- 1, 3, 6, 12... confirmations reached
  confirmation_level  confirmation_status_enum NOT NULL,
    -- awaiting_broadcast, in_mempool, confirmed, reconciled
  
  -- Block information
  block_number        BIGINT,
    -- Block hash where transaction was included
  block_hash          VARCHAR(100),
  block_timestamp     TIMESTAMPTZ,
    -- When block was created on blockchain
  
  -- Gas details (for gas-based networks like Ethereum)
  gas_used            NUMERIC(30, 0),
    -- Actual gas used in transaction
  gas_price_wei       NUMERIC(30, 0),
    -- Gas price at time of confirmation (for cost tracking)
  miner_fee_usd       NUMERIC(20, 8),
    -- Computed fee in USD (might differ from initial estimate)

  -- Network-specific data
  network_data        JSONB,
    -- Extensible field for network-specific details:
    -- {"confirmations": 6, "network": "ethereum", "status": "confirmed"}

  verified_at         TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
  created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_deposit_confirmations_deposit_id
  ON wallet.deposit_confirmations(deposit_id);
CREATE INDEX IF NOT EXISTS idx_deposit_confirmations_confirmation_count
  ON wallet.deposit_confirmations(confirmation_count);
CREATE INDEX IF NOT EXISTS idx_deposit_confirmations_user_verified
  ON wallet.deposit_confirmations(user_id, verified_at DESC);

COMMENT ON TABLE wallet.deposit_confirmations IS
  'Blockchain confirmation milestones for deposits. Tracks real-time confirmation progress. '
  'One row per confirmation checkpoint. Enables UI to show "3/6 confirmations" progress.';

-- ============================================================================
-- TABLE: wallet.crypto_address_deposits
-- Link between user wallet addresses and their deposits.
-- Enables tracking: "which deposits came from which user wallet addresses?"
-- Useful for reconciliation and fraud detection.
-- ============================================================================
CREATE TABLE IF NOT EXISTS wallet.crypto_address_deposits (
  id                  UUID            PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id             UUID            NOT NULL REFERENCES auth.users(id),
  wallet_id           UUID            NOT NULL REFERENCES auth.crypto_wallets(id) ON DELETE CASCADE,
  deposit_id          UUID            NOT NULL REFERENCES wallet.deposits(id) ON DELETE CASCADE,

  -- Denormalized for quick lookup
  wallet_address      VARCHAR(100)    NOT NULL,
  network             VARCHAR(30)     NOT NULL,
    -- ethereum, polygon, bitcoin, arbitrum, etc.
  
  -- Verification
  is_verified         BOOLEAN         NOT NULL DEFAULT FALSE,
    -- User signature challenge to prove wallet ownership
  verified_at         TIMESTAMPTZ,

  created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

  -- One deposit per wallet (can't receive same deposit twice)
  CONSTRAINT uq_address_deposit UNIQUE (wallet_id, deposit_id)
);

CREATE INDEX IF NOT EXISTS idx_address_deposits_wallet_id
  ON wallet.crypto_address_deposits(wallet_id);
CREATE INDEX IF NOT EXISTS idx_address_deposits_deposit_id
  ON wallet.crypto_address_deposits(deposit_id);
CREATE INDEX IF NOT EXISTS idx_address_deposits_user
  ON wallet.crypto_address_deposits(user_id, created_at DESC);

COMMENT ON TABLE wallet.crypto_address_deposits IS
  'Links user wallet addresses to their deposits. Enables verification: '
  '"Is this deposit from a wallet the user controls?" Supports fraud detection.';

-- ============================================================================
-- TABLE: wallet.deposit_failures
-- Failed deposit attempts — captured for retry logic and customer support.
-- Append-only record of what went wrong.
-- ============================================================================
CREATE TABLE IF NOT EXISTS wallet.deposit_failures (
  id                  UUID            PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id             UUID            NOT NULL REFERENCES auth.users(id),

  -- Original request
  crypto_currency     crypto_currency_enum NOT NULL,
  destination_address VARCHAR(100)    NOT NULL,
  network             blockchain_network_enum NOT NULL,
  requested_amount    NUMERIC(30, 18) NOT NULL,
  
  -- Error details
  error_code          VARCHAR(50),
    -- e.g., 'INSUFFICIENT_BALANCE', 'INVALID_ADDRESS', 'NETWORK_ERROR'
  error_message       TEXT,
  failure_reason      rebalance_reason_enum,
    -- Why it failed: network timeout, validation error, etc.
  
  -- Linked deposit (if partially created)
  deposit_id          UUID REFERENCES wallet.deposits(id),

  -- Retry management
  retry_count         INTEGER         NOT NULL DEFAULT 0,
  last_retry_at       TIMESTAMPTZ,
  next_retry_at       TIMESTAMPTZ,
  is_recoverable       BOOLEAN         NOT NULL DEFAULT TRUE,
    -- FALSE = permanent failure, notify user to try different approach

  created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_deposit_failures_updated_at
  BEFORE UPDATE ON wallet.deposit_failures
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE INDEX IF NOT EXISTS idx_deposit_failures_user
  ON wallet.deposit_failures(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_deposit_failures_recoverable
  ON wallet.deposit_failures(is_recoverable) WHERE is_recoverable = TRUE;

COMMENT ON TABLE wallet.deposit_failures IS
  'Failed deposit attempts. Appended for every failure. '
  'Enables retry logic and customer support escalation. '
  'recoverable=FALSE = permanent, notify user to take action.';

-- ============================================================================
-- TABLE: wallet.withdrawal_confirmations
-- Similar to deposit_confirmations but for outbound withdrawals.
-- Tracks blockchain confirmations as user's crypto is delivered.
-- ============================================================================
CREATE TABLE IF NOT EXISTS wallet.withdrawal_confirmations (
  id                  UUID            PRIMARY KEY DEFAULT uuid_generate_v4(),
  withdrawal_id       UUID            NOT NULL REFERENCES wallet.withdrawals(id) ON DELETE CASCADE,
  user_id             UUID            NOT NULL REFERENCES auth.users(id),

  confirmation_count  INTEGER         NOT NULL CHECK (confirmation_count > 0),
  confirmation_level  confirmation_status_enum NOT NULL,
  
  block_number        BIGINT,
  block_hash          VARCHAR(100),
  block_timestamp     TIMESTAMPTZ,
  
  -- Gas details
  gas_used            NUMERIC(30, 0),
  actual_fee_usd      NUMERIC(20, 8),

  network_data        JSONB,

  verified_at         TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
  created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_withdrawal_confirmations_withdrawal_id
  ON wallet.withdrawal_confirmations(withdrawal_id);
CREATE INDEX IF NOT EXISTS idx_withdrawal_confirmations_user
  ON wallet.withdrawal_confirmations(user_id, verified_at DESC);

COMMENT ON TABLE wallet.withdrawal_confirmations IS
  'Blockchain confirmation milestones for withdrawals. Tracks outbound crypto. '
  'Shows user: "Your withdrawal has 4/6 confirmations on blockchain."';

-- ============================================================================
-- TABLE: wallet.transaction_fee_adjustments
-- Track gas fee adjustments and reconciliations.
-- When estimated gas differs from actual, record the difference.
-- ============================================================================
CREATE TABLE IF NOT EXISTS wallet.transaction_fee_adjustments (
  id                  UUID            PRIMARY KEY DEFAULT uuid_generate_v4(),
  deposit_id          UUID REFERENCES wallet.deposits(id),
  withdrawal_id       UUID REFERENCES wallet.withdrawals(id),
  user_id             UUID            NOT NULL REFERENCES auth.users(id),

  -- One must be non-null (XOR constraint at application level)
  transaction_type    VARCHAR(20)     NOT NULL CHECK (transaction_type IN ('deposit', 'withdrawal')),

  -- Fee adjustment
  estimated_fee_usd   NUMERIC(20, 8)  NOT NULL,
  actual_fee_usd      NUMERIC(20, 8)  NOT NULL,
  adjustment_amount   NUMERIC(20, 8)  GENERATED ALWAYS AS (actual_fee_usd - estimated_fee_usd) STORED,
    -- Positive = user charged more, Negative = user charged less

  adjustment_reason   TEXT,
    -- "Gas price increased during transaction", "Network congestion"
  
  adjustment_credited BOOLEAN         NOT NULL DEFAULT FALSE,
    -- TRUE = discrepancy credited/debited to user's account
  
  created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_fee_adjustments_user
  ON wallet.transaction_fee_adjustments(user_id, created_at DESC);

COMMENT ON TABLE wallet.transaction_fee_adjustments IS
  'Track gas fee reconciliation between estimate and actual. '
  'When crypto network gas prices change, adjust user account if needed.';

-- ============================================================================
-- PERMISSION GRANTS
-- ============================================================================
ALTER DEFAULT PRIVILEGES IN SCHEMA wallet GRANT SELECT, INSERT, UPDATE ON TABLES TO bse_app;
GRANT SELECT, INSERT ON wallet.deposit_confirmations         TO bse_app;
GRANT SELECT, INSERT ON wallet.crypto_address_deposits       TO bse_app;
GRANT SELECT, INSERT ON wallet.deposit_failures              TO bse_app;
GRANT SELECT, INSERT ON wallet.withdrawal_confirmations      TO bse_app;
GRANT SELECT, INSERT ON wallet.transaction_fee_adjustments   TO bse_app;

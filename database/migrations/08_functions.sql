-- ============================================================================
-- BSE: STORED FUNCTIONS & PROCEDURES
-- All critical business logic enforced at the database layer.
-- These functions are called by backend API services — not inline SQL.
--
-- WHY IN THE DB (not application code):
--   • ACID guarantee: function + ledger write + balance update = one transaction
--   • Race-condition safe: row-level locks inside the function
--   • Audit trail written atomically — cannot be skipped by buggy app code
--   • Single source of truth: all services share the same logic
--
-- RUN ORDER: 08 (after all schemas)
-- ============================================================================

-- ============================================================================
-- FUNCTION: wallet.debit_balance
-- Called by: trade-service (buy order), withdrawal-service
-- Purpose: Atomically debit BSE balance with full double-entry ledger entry.
--          Uses SELECT FOR UPDATE + version check to prevent double-spend.
--          Writes audit.balance_snapshots in same transaction.
--
-- RETURNS: JSON with {success, new_balance, ledger_id, error}
-- ACID:    All-or-nothing. If any step fails, entire transaction rolls back.
-- ============================================================================
CREATE OR REPLACE FUNCTION wallet.debit_balance(
  p_user_id         UUID,
  p_amount          NUMERIC,        -- Amount to debit (must be positive)
  p_tx_type         ledger_tx_type_enum,
  p_reference_id    UUID,           -- FK to order.id, withdrawal.id etc.
  p_reference_type  VARCHAR(30),
  p_description     TEXT,
  p_idempotency_key VARCHAR(100)    -- Caller must supply unique key to prevent duplicate debits
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
  v_account         wallet.accounts%ROWTYPE;
  v_ledger_id       BIGINT;
  v_new_balance     NUMERIC(20,8);
BEGIN
  -- ── Step 1: Acquire row-level lock on account ──────────────────────────
  -- FOR UPDATE locks this row until transaction commits/rolls back.
  -- Any concurrent debit on the same user blocks here, preventing double-spend.
  SELECT * INTO v_account
  FROM wallet.accounts
  WHERE user_id = p_user_id
  FOR UPDATE;  -- CRITICAL: do not remove this lock

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'account_not_found');
  END IF;

  -- ── Step 2: Validate sufficient balance ───────────────────────────────
  IF v_account.bse_balance < p_amount THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'insufficient_balance',
      'available', v_account.bse_balance,
      'required', p_amount
    );
  END IF;

  -- ── Step 3: Check idempotency — prevent duplicate ledger entries ───────
  IF EXISTS (
    SELECT 1 FROM wallet.ledger WHERE idempotency_key = p_idempotency_key
  ) THEN
    -- Already processed — return existing ledger entry (safe retry)
    SELECT id, balance_after INTO v_ledger_id, v_new_balance
    FROM wallet.ledger WHERE idempotency_key = p_idempotency_key;

    RETURN jsonb_build_object(
      'success', true,
      'idempotent_replay', true,
      'new_balance', v_new_balance,
      'ledger_id', v_ledger_id
    );
  END IF;

  v_new_balance := v_account.bse_balance - p_amount;

  -- ── Step 4: Update account balance with optimistic version check ────────
  UPDATE wallet.accounts
  SET
    bse_balance         = v_new_balance,
    last_transaction_at = NOW(),
    last_activity_at    = NOW()
    -- version is auto-incremented by trigger trg_wallet_accounts_version
  WHERE user_id = p_user_id
    AND version  = v_account.version;  -- Optimistic lock: fails if concurrent update happened

  IF NOT FOUND THEN
    -- Another transaction modified this account between our SELECT and UPDATE.
    -- Caller should retry from fresh read.
    RETURN jsonb_build_object('success', false, 'error', 'concurrent_modification_retry');
  END IF;

  -- ── Step 5: Write immutable ledger entry ──────────────────────────────
  INSERT INTO wallet.ledger (
    user_id, account_id, tx_type,
    amount, balance_after,
    reference_id, reference_type,
    description, idempotency_key
  )
  VALUES (
    p_user_id, v_account.id, p_tx_type,
    -p_amount,            -- NEGATIVE = debit
    v_new_balance,
    p_reference_id, p_reference_type,
    p_description, p_idempotency_key
  )
  RETURNING id INTO v_ledger_id;

  -- ── Step 6: Write audit balance snapshot ──────────────────────────────
  INSERT INTO audit.balance_snapshots (
    user_id, account_id,
    bse_balance, bse_in_transit, bse_reserved,
    total_portfolio_value,
    trigger_event, trigger_reference_id
  )
  SELECT
    user_id, id,
    bse_balance, bse_in_transit, bse_reserved,
    total_portfolio_value,
    p_reference_type || '.debit', p_reference_id
  FROM wallet.accounts WHERE user_id = p_user_id;

  -- ── Step 7: Write audit event ─────────────────────────────────────────
  INSERT INTO audit.events (
    event_type, actor_user_id, target_type, target_id,
    payload, service_name
  )
  VALUES (
    'wallet.balance.debited',
    p_user_id,
    p_reference_type, p_reference_id,
    jsonb_build_object(
      'amount',         p_amount,
      'balance_before', v_account.bse_balance,
      'balance_after',  v_new_balance,
      'tx_type',        p_tx_type,
      'ledger_id',      v_ledger_id
    ),
    'wallet-service'
  );

  RETURN jsonb_build_object(
    'success',      true,
    'new_balance',  v_new_balance,
    'ledger_id',    v_ledger_id
  );

EXCEPTION WHEN OTHERS THEN
  -- Any unexpected error rolls back the entire transaction automatically.
  -- Log and return structured error.
  RETURN jsonb_build_object(
    'success', false,
    'error',   'unexpected_error',
    'detail',  SQLERRM
  );
END;
$$;

COMMENT ON FUNCTION wallet.debit_balance IS
  'ACID wallet debit. SELECT FOR UPDATE prevents double-spend. '
  'Writes ledger + balance_snapshot atomically. Idempotent via idempotency_key. '
  'Returns JSON — caller checks success field before committing.';

-- ============================================================================
-- FUNCTION: wallet.credit_balance
-- Called by: deposit-service (on settlement), sell-order execution, refunds
-- Mirrors debit_balance but credits. Simpler — no balance check needed.
-- ============================================================================
CREATE OR REPLACE FUNCTION wallet.credit_balance(
  p_user_id         UUID,
  p_amount          NUMERIC,
  p_tx_type         ledger_tx_type_enum,
  p_reference_id    UUID,
  p_reference_type  VARCHAR(30),
  p_description     TEXT,
  p_idempotency_key VARCHAR(100)
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
  v_account     wallet.accounts%ROWTYPE;
  v_ledger_id   BIGINT;
  v_new_balance NUMERIC(20,8);
BEGIN
  SELECT * INTO v_account FROM wallet.accounts WHERE user_id = p_user_id FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'account_not_found');
  END IF;

  -- Idempotency check
  IF EXISTS (SELECT 1 FROM wallet.ledger WHERE idempotency_key = p_idempotency_key) THEN
    SELECT id, balance_after INTO v_ledger_id, v_new_balance
    FROM wallet.ledger WHERE idempotency_key = p_idempotency_key;
    RETURN jsonb_build_object('success', true, 'idempotent_replay', true,
                              'new_balance', v_new_balance, 'ledger_id', v_ledger_id);
  END IF;

  v_new_balance := v_account.bse_balance + p_amount;

  UPDATE wallet.accounts
  SET bse_balance = v_new_balance, last_transaction_at = NOW(), last_activity_at = NOW()
  WHERE user_id = p_user_id AND version = v_account.version;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'concurrent_modification_retry');
  END IF;

  INSERT INTO wallet.ledger (
    user_id, account_id, tx_type, amount, balance_after,
    reference_id, reference_type, description, idempotency_key
  )
  VALUES (
    p_user_id, v_account.id, p_tx_type,
    p_amount,             -- POSITIVE = credit
    v_new_balance,
    p_reference_id, p_reference_type, p_description, p_idempotency_key
  )
  RETURNING id INTO v_ledger_id;

  INSERT INTO audit.balance_snapshots (
    user_id, account_id, bse_balance, bse_in_transit, bse_reserved,
    total_portfolio_value, trigger_event, trigger_reference_id
  )
  SELECT user_id, id, bse_balance, bse_in_transit, bse_reserved,
         total_portfolio_value, p_reference_type || '.credit', p_reference_id
  FROM wallet.accounts WHERE user_id = p_user_id;

  INSERT INTO audit.events (event_type, actor_user_id, target_type, target_id, payload, service_name)
  VALUES ('wallet.balance.credited', p_user_id, p_reference_type, p_reference_id,
    jsonb_build_object('amount', p_amount, 'balance_before', v_account.bse_balance,
                       'balance_after', v_new_balance, 'tx_type', p_tx_type), 'wallet-service');

  RETURN jsonb_build_object('success', true, 'new_balance', v_new_balance, 'ledger_id', v_ledger_id);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'unexpected_error', 'detail', SQLERRM);
END;
$$;

COMMENT ON FUNCTION wallet.credit_balance IS
  'ACID wallet credit. Mirrors debit_balance. Idempotent. '
  'Used for deposit settlement, sell proceeds, refunds, staking rewards.';

-- ============================================================================
-- FUNCTION: trading.place_buy_order
-- Called by: trade-service  POST /trade/orders
-- Purpose: Validate + reserve funds + create order atomically.
--          Does NOT execute the trade — that happens at EOD by nav_engine.
--
-- Flow:
--   1. Validate user KYC approved
--   2. Check stock token available supply
--   3. Lock + validate wallet balance (calls wallet.debit_balance internally)
--   4. Create order record (status = queued)
--   5. Reserve staked supply on stock token
--   6. Write audit event
-- ============================================================================
CREATE OR REPLACE FUNCTION trading.place_buy_order(
  p_user_id       UUID,
  p_symbol        VARCHAR(12),
  p_qty           NUMERIC,
  p_price_type    order_price_type_enum DEFAULT 'market',
  p_limit_price   NUMERIC DEFAULT NULL,
  p_duration      order_duration_enum DEFAULT 'good_for_day',
  p_is_aon        BOOLEAN DEFAULT FALSE
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
  v_user          auth.users%ROWTYPE;
  v_token         core.stock_tokens%ROWTYPE;
  v_account       wallet.accounts%ROWTYPE;
  v_order_id      UUID;
  v_order_value   NUMERIC(20,8);
  v_platform_fee  NUMERIC(20,8) := 0.00;  -- $0 per Figma "0% Commission"
  v_total_cost    NUMERIC(20,8);
  v_nav_date      DATE;
  v_debit_result  JSONB;
  v_idempotency   VARCHAR(100);
BEGIN
  -- ── Step 1: Validate user KYC ──────────────────────────────────────────
  SELECT * INTO v_user FROM auth.users WHERE id = p_user_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'user_not_found');
  END IF;
  IF v_user.kyc_status != 'approved' THEN
    RETURN jsonb_build_object('success', false, 'error', 'kyc_not_approved',
                              'kyc_status', v_user.kyc_status);
  END IF;

  -- ── Step 2: Lock stock token, validate supply ──────────────────────────
  SELECT * INTO v_token FROM core.stock_tokens
  WHERE symbol = p_symbol AND is_active = TRUE
  FOR UPDATE;  -- Lock to prevent overselling available supply

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'token_not_found_or_inactive');
  END IF;
  IF v_token.available_supply < p_qty THEN
    RETURN jsonb_build_object('success', false, 'error', 'insufficient_supply',
                              'available', v_token.available_supply, 'requested', p_qty);
  END IF;
  IF v_token.market_status NOT IN ('open', 'pre_market') THEN
    RETURN jsonb_build_object('success', false, 'error', 'market_closed',
                              'market_status', v_token.market_status);
  END IF;

  -- ── Step 3: Calculate order cost ──────────────────────────────────────
  v_order_value := p_qty * v_token.current_nav_per_token;
  v_total_cost  := v_order_value + v_platform_fee;
  v_nav_date    := CASE
    WHEN CURRENT_TIME AT TIME ZONE 'America/New_York' < '16:00:00'
    THEN CURRENT_DATE
    ELSE CURRENT_DATE + 1  -- After market close → next trading day
  END;

  -- ── Step 4: Debit wallet (ACID, locked) ───────────────────────────────
  v_order_id      := uuid_generate_v4();
  v_idempotency   := 'buy_order:' || v_order_id::TEXT;

  -- Get account for reference
  SELECT * INTO v_account FROM wallet.accounts WHERE user_id = p_user_id;

  v_debit_result := wallet.debit_balance(
    p_user_id, v_total_cost,
    'buy_stock'::ledger_tx_type_enum,
    v_order_id, 'order',
    'Buy ' || p_qty || ' × ' || p_symbol || ' @ ' || v_token.current_nav_per_token,
    v_idempotency
  );

  IF NOT (v_debit_result->>'success')::BOOLEAN THEN
    RETURN v_debit_result;  -- Propagate error (insufficient_balance etc.)
  END IF;

  -- ── Step 5: Create order record ───────────────────────────────────────
  INSERT INTO trading.orders (
    id, user_id, account_id, token_id, symbol,
    side, price_type, duration, is_all_or_none,
    requested_qty, limit_price,
    investment_total_usd,
    estimated_nav_usd, estimated_total_usd, estimated_principal_usd,
    buying_power_before_usd, buying_power_after_usd,
    platform_fee_usd, expense_ratio,
    status, nav_date,
    brokerage_account_mask
  )
  VALUES (
    v_order_id, p_user_id, v_account.id, v_token.id, p_symbol,
    'buy', p_price_type, p_duration, p_is_aon,
    p_qty, p_limit_price,
    v_order_value,
    v_token.current_nav_per_token, v_total_cost, v_order_value,
    v_account.bse_balance,                                    -- buying_power before
    v_account.bse_balance - v_total_cost,                     -- buying_power after
    v_platform_fee, v_token.current_expense_ratio,
    'queued', v_nav_date,
    '****-' || RIGHT(v_account.id::TEXT, 4)
  );

  -- ── Step 6: Reserve supply on token (prevent overselling) ─────────────
  UPDATE core.stock_tokens
  SET
    available_supply    = available_supply    - p_qty,
    total_tokens_issued = total_tokens_issued + p_qty
  WHERE id = v_token.id;

  -- ── Step 7: Audit event ───────────────────────────────────────────────
  INSERT INTO audit.events (
    event_type, actor_user_id, target_type, target_id, payload, service_name
  )
  VALUES (
    'trade.order.placed', p_user_id, 'order', v_order_id,
    jsonb_build_object(
      'symbol', p_symbol, 'qty', p_qty, 'side', 'buy',
      'nav_price', v_token.current_nav_per_token,
      'total_cost', v_total_cost, 'nav_date', v_nav_date
    ),
    'trade-service'
  );

  RETURN jsonb_build_object(
    'success',          true,
    'order_id',         v_order_id,
    'symbol',           p_symbol,
    'qty',              p_qty,
    'estimated_total',  v_total_cost,
    'nav_date',         v_nav_date,
    'buying_power_after', v_account.bse_balance - v_total_cost
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'unexpected_error', 'detail', SQLERRM);
END;
$$;

COMMENT ON FUNCTION trading.place_buy_order IS
  'ACID buy order placement. Validates KYC + supply + balance, '
  'debits wallet, creates order, reserves supply — all in one transaction. '
  'Returns structured JSON. Execution happens at EOD via nav_engine.';

-- ============================================================================
-- FUNCTION: trading.execute_order_at_nav
-- Called by: nav_engine (EOD batch processor) — NOT the API
-- Purpose: Execute a queued order at the calculated NAV price.
--          Updates holdings with weighted average cost.
--          Handles partial fills and failed executions.
-- ============================================================================
CREATE OR REPLACE FUNCTION trading.execute_order_at_nav(
  p_order_id    UUID,
  p_nav_price   NUMERIC,
  p_fill_qty    NUMERIC,          -- May be < requested for partial fills
  p_nav_date    DATE,
  p_alpaca_ref  VARCHAR(100)
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
  v_order       trading.orders%ROWTYPE;
  v_holding     trading.holdings%ROWTYPE;
  v_new_qty     NUMERIC(20,8);
  v_new_avg     NUMERIC(20,8);
  v_fill_value  NUMERIC(20,8);
  v_refund_amt  NUMERIC(20,8) := 0;
BEGIN
  SELECT * INTO v_order FROM trading.orders
  WHERE id = p_order_id AND status = 'queued'
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'order_not_queued_or_not_found');
  END IF;

  v_fill_value := p_fill_qty * p_nav_price;

  -- ── Update or create holdings with weighted average cost ──────────────
  SELECT * INTO v_holding FROM trading.holdings
  WHERE user_id = v_order.user_id AND token_id = v_order.token_id
  FOR UPDATE;

  IF FOUND THEN
    -- Existing position: recalculate weighted average cost
    -- Formula: new_avg = (old_qty * old_avg + fill_qty * fill_price) / new_total_qty
    v_new_qty := v_holding.qty + p_fill_qty;
    v_new_avg := (v_holding.qty * v_holding.avg_cost_per_token + p_fill_qty * p_nav_price)
                 / NULLIF(v_new_qty, 0);

    UPDATE trading.holdings SET
      qty                  = v_new_qty,
      avg_cost_per_token   = v_new_avg,
      total_cost_basis     = total_cost_basis + v_fill_value,
      current_nav_per_token = p_nav_price,
      current_value_usd    = v_new_qty * p_nav_price,
      last_traded_at       = NOW()
    WHERE user_id = v_order.user_id AND token_id = v_order.token_id;

  ELSE
    -- New position
    INSERT INTO trading.holdings (
      user_id, token_id, symbol,
      qty, avg_cost_per_token, total_cost_basis,
      current_nav_per_token, current_value_usd,
      first_bought_at, last_traded_at
    )
    VALUES (
      v_order.user_id, v_order.token_id, v_order.symbol,
      p_fill_qty, p_nav_price, v_fill_value,
      p_nav_price, v_fill_value,
      NOW(), NOW()
    );
  END IF;

  -- ── Handle partial fill: refund unfilled portion ───────────────────────
  IF p_fill_qty < v_order.requested_qty THEN
    v_refund_amt := (v_order.requested_qty - p_fill_qty) * v_order.estimated_nav_usd;

    PERFORM wallet.credit_balance(
      v_order.user_id, v_refund_amt,
      'refund'::ledger_tx_type_enum,
      p_order_id, 'order',
      'Partial fill refund: ' || (v_order.requested_qty - p_fill_qty) || ' × ' || v_order.symbol,
      'partial_refund:' || p_order_id::TEXT
    );
  END IF;

  -- ── Update order to executed ───────────────────────────────────────────
  UPDATE trading.orders SET
    status           = CASE WHEN p_fill_qty = requested_qty THEN 'executed' ELSE 'partial' END,
    executed_qty     = p_fill_qty,
    executed_nav_usd = p_nav_price,
    executed_total_usd = v_fill_value,
    nav_date         = p_nav_date,
    alpaca_order_ref = p_alpaca_ref,
    executed_at      = NOW()
  WHERE id = p_order_id;

  INSERT INTO audit.events (event_type, actor_user_id, target_type, target_id, payload, service_name)
  VALUES ('trade.order.executed', v_order.user_id, 'order', p_order_id,
    jsonb_build_object('symbol', v_order.symbol, 'requested_qty', v_order.requested_qty,
                       'fill_qty', p_fill_qty, 'nav_price', p_nav_price,
                       'fill_value', v_fill_value, 'refund', v_refund_amt),
    'nav-engine');

  RETURN jsonb_build_object(
    'success',     true,
    'order_id',    p_order_id,
    'fill_qty',    p_fill_qty,
    'nav_price',   p_nav_price,
    'fill_value',  v_fill_value,
    'refund_amt',  v_refund_amt
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION trading.execute_order_at_nav IS
  'EOD order execution at NAV price. Called only by nav_engine. '
  'Upserts holdings with weighted avg cost. Handles partial fills with auto-refund.';

-- ============================================================================
-- FUNCTION: wallet.reconcile_user_balance
-- Called by: ops team, scheduled nightly reconciliation job
-- Purpose: Verify wallet.accounts.bse_balance matches sum of wallet.ledger
--          Returns discrepancies for investigation.
-- ============================================================================
CREATE OR REPLACE FUNCTION wallet.reconcile_user_balance(p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
  v_account_balance   NUMERIC(20,8);
  v_ledger_sum        NUMERIC(20,8);
  v_discrepancy       NUMERIC(20,8);
  v_last_snapshot     audit.balance_snapshots%ROWTYPE;
BEGIN
  -- Current balance in accounts table
  SELECT bse_balance INTO v_account_balance
  FROM wallet.accounts WHERE user_id = p_user_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'account_not_found');
  END IF;

  -- Sum of all ledger entries (the ground truth)
  SELECT COALESCE(SUM(amount), 0) INTO v_ledger_sum
  FROM wallet.ledger WHERE user_id = p_user_id;

  v_discrepancy := v_account_balance - v_ledger_sum;

  -- Most recent audit snapshot for cross-check
  SELECT * INTO v_last_snapshot FROM audit.balance_snapshots
  WHERE user_id = p_user_id ORDER BY created_at DESC LIMIT 1;

  -- Write reconciliation audit event
  INSERT INTO audit.events (
    event_type, actor_user_id, target_type, target_id,
    payload, severity, service_name
  )
  VALUES (
    'wallet.reconciliation.run', p_user_id, 'user', p_user_id,
    jsonb_build_object(
      'account_balance',  v_account_balance,
      'ledger_sum',       v_ledger_sum,
      'discrepancy',      v_discrepancy,
      'is_balanced',      v_discrepancy = 0
    ),
    CASE WHEN v_discrepancy = 0 THEN 'info' ELSE 'error' END,
    'reconciliation-job'
  );

  RETURN jsonb_build_object(
    'user_id',           p_user_id,
    'account_balance',   v_account_balance,
    'ledger_sum',        v_ledger_sum,
    'discrepancy',       v_discrepancy,
    'is_balanced',       v_discrepancy = 0,
    'last_snapshot_at',  v_last_snapshot.created_at,
    'last_snapshot_bal', v_last_snapshot.bse_balance
  );
END;
$$;

COMMENT ON FUNCTION wallet.reconcile_user_balance IS
  'Verify account balance matches ledger sum. Flags discrepancies. '
  'Run nightly via scheduled job. Results written to audit.events.';

-- ============================================================================
-- PROCEDURE: audit.create_monthly_partition
-- Called by: EventBridge scheduler (1st of each month, 00:01 UTC)
-- Purpose: Auto-create next month's audit.events partition.
--          Prevents "no partition" errors if partitions aren't pre-created.
-- ============================================================================
CREATE OR REPLACE PROCEDURE audit.create_monthly_partition(p_target_month DATE DEFAULT NULL)
LANGUAGE plpgsql
AS $$
DECLARE
  v_month         DATE;
  v_partition     VARCHAR(50);
  v_start_date    DATE;
  v_end_date      DATE;
  v_sql           TEXT;
BEGIN
  -- Default: create partition for 2 months from now (safety buffer)
  v_month      := DATE_TRUNC('month', COALESCE(p_target_month, CURRENT_DATE + INTERVAL '2 months'));
  v_start_date := v_month;
  v_end_date   := v_month + INTERVAL '1 month';
  v_partition  := 'audit.events_' || TO_CHAR(v_month, 'YYYY_MM');

  -- Check if partition already exists
  IF EXISTS (
    SELECT 1 FROM pg_tables
    WHERE schemaname = 'audit'
    AND tablename = 'events_' || TO_CHAR(v_month, 'YYYY_MM')
  ) THEN
    RAISE NOTICE 'Partition % already exists — skipping.', v_partition;
    RETURN;
  END IF;

  v_sql := format(
    'CREATE TABLE IF NOT EXISTS %s PARTITION OF audit.events FOR VALUES FROM (%L) TO (%L)',
    v_partition, v_start_date, v_end_date
  );

  EXECUTE v_sql;

  RAISE NOTICE 'Created partition: % (% to %)', v_partition, v_start_date, v_end_date;

  -- Log the partition creation itself
  INSERT INTO audit.events (event_type, payload, severity, service_name)
  VALUES (
    'audit.partition.created',
    jsonb_build_object('partition', v_partition, 'start', v_start_date, 'end', v_end_date),
    'info', 'partition-scheduler'
  );
END;
$$;

COMMENT ON PROCEDURE audit.create_monthly_partition IS
  'Auto-creates next audit.events partition. Schedule on 1st of month via EventBridge. '
  'Creates 2 months ahead by default for safety buffer.';

-- ============================================================================
-- FUNCTION: core.update_holdings_nav
-- Called by: nav_engine after each token NAV update
-- Purpose: Batch-refresh all holdings current_value_usd and daily_gain_usd
--          for a given token after its NAV price changes.
--          More efficient than per-user updates from application code.
-- ============================================================================
CREATE OR REPLACE FUNCTION core.update_holdings_nav(
  p_token_id    UUID,
  p_new_nav     NUMERIC,
  p_old_nav     NUMERIC
)
RETURNS INTEGER  -- Number of holdings updated
LANGUAGE plpgsql
AS $$
DECLARE
  v_updated_count INTEGER;
BEGIN
  UPDATE trading.holdings
  SET
    current_nav_per_token = p_new_nav,
    current_value_usd     = qty * p_new_nav,
    -- Daily gain = difference between new and old NAV * qty held
    daily_gain_usd        = qty * (p_new_nav - COALESCE(p_old_nav, p_new_nav)),
    updated_at            = NOW()
  WHERE token_id = p_token_id
    AND qty > 0;

  GET DIAGNOSTICS v_updated_count = ROW_COUNT;

  RETURN v_updated_count;
END;
$$;

COMMENT ON FUNCTION core.update_holdings_nav IS
  'Batch-update all holdings for a token after NAV changes. '
  'Called by nav_engine. Returns count of holdings updated.';

-- ============================================================================
-- FUNCTION: trading.cancel_order
-- Called by: trade-service  DELETE /trade/orders/{orderId}
-- Cancels a pending/queued order and refunds reserved funds.
-- ============================================================================
CREATE OR REPLACE FUNCTION trading.cancel_order(
  p_order_id  UUID,
  p_user_id   UUID,
  p_reason    TEXT DEFAULT 'user_cancelled'
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
  v_order     trading.orders%ROWTYPE;
  v_refund    NUMERIC(20,8);
BEGIN
  SELECT * INTO v_order FROM trading.orders
  WHERE id = p_order_id AND user_id = p_user_id AND status IN ('pending', 'queued', 'draft')
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error',
      'order_not_found_or_not_cancellable');
  END IF;

  -- Refund the reserved amount back to available balance
  v_refund := COALESCE(v_order.estimated_total_usd, 0);

  IF v_refund > 0 THEN
    PERFORM wallet.credit_balance(
      p_user_id, v_refund,
      'refund'::ledger_tx_type_enum,
      p_order_id, 'order',
      'Cancelled order refund: ' || v_order.symbol,
      'cancel_refund:' || p_order_id::TEXT
    );
  END IF;

  -- Release reserved supply back to available
  UPDATE core.stock_tokens SET
    available_supply    = available_supply    + v_order.requested_qty,
    total_tokens_issued = total_tokens_issued - v_order.requested_qty
  WHERE id = v_order.token_id;

  UPDATE trading.orders SET
    status         = 'cancelled',
    failure_reason = p_reason,
    updated_at     = NOW()
  WHERE id = p_order_id;

  INSERT INTO audit.events (event_type, actor_user_id, target_type, target_id, payload, service_name)
  VALUES ('trade.order.cancelled', p_user_id, 'order', p_order_id,
    jsonb_build_object('reason', p_reason, 'refund_amount', v_refund, 'symbol', v_order.symbol),
    'trade-service');

  RETURN jsonb_build_object('success', true, 'order_id', p_order_id, 'refund_amount', v_refund);
END;
$$;

COMMENT ON FUNCTION trading.cancel_order IS
  'Cancel pending/queued/draft order. Refunds reserved funds and releases supply. '
  'ACID: refund + supply release + status update in one transaction.';

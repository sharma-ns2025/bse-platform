-- ============================================================================
-- SCHEMA: auth
-- PURPOSE: Stores all user identity data synced FROM Firebase Authentication.
--          Firebase owns the login/password/OAuth flow. This DB stores the
--          extended profile, KYC, devices, preferences, and notification settings
--          that Firebase does not manage.
--
-- FIGMA SCREENS COVERED:
--   • Page 19: Profile & Settings → Personal Info (name, email, phone, address)
--   • Page 20: Profile & Settings → Security (2FA status, recent devices)
--   • Page 21: Profile & Settings → Payment Methods (cards, bank accounts)
--   • Page 22: Connect Wallet (MetaMask, WalletConnect, Coinbase)
--   • Page 23: Profile & Settings → Notification Preferences
--
-- FIREBASE INTEGRATION PATTERN:
--   1. User registers/logs in via Firebase (frontend)
--   2. Firebase issues a JWT with uid (firebase_uid)
--   3. Backend API verifies the JWT, then upserts auth.users using firebase_uid
--   4. All extended profile/settings data lives here in PostgreSQL
--   5. firebase_uid is the permanent cross-system link
--
-- RUN ORDER: 01 (after 00_master_setup.sql)
-- ============================================================================

SET search_path TO auth, public;

-- ============================================================================
-- TABLE: auth.users
-- Central user record. Created on first successful Firebase login.
-- One row per unique Firebase UID.
-- ============================================================================
CREATE TABLE IF NOT EXISTS auth.users (

  -- ── Primary Identity ──────────────────────────────────────────────────────
  id                    UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),

  -- Firebase UID — the permanent cross-system link.
  -- Populated from Firebase JWT claim 'sub' or 'uid'.
  -- UNIQUE + NOT NULL enforced: one Firebase account = one BSE account.
  firebase_uid          VARCHAR(128)  NOT NULL UNIQUE,

  -- ── Contact Info (Figma p19: Personal Information section) ───────────────
  email                 VARCHAR(255)  NOT NULL UNIQUE,
  email_verified        BOOLEAN       NOT NULL DEFAULT FALSE,
    -- TRUE when Firebase marks the email as verified

  first_name            VARCHAR(100),
    -- Figma p19: "First Name" input field
  last_name             VARCHAR(100),
    -- Figma p19: "Last Name" input field
  phone_number          VARCHAR(30),
    -- Figma p19: "+1 (555) 123-4567" — E.164 format preferred
  phone_verified        BOOLEAN       NOT NULL DEFAULT FALSE,
  address_line1         VARCHAR(255),
    -- Figma p19: "123 Financial District, New York, NY 10004"
  address_line2         VARCHAR(100),
  city                  VARCHAR(100),
  state_province        VARCHAR(100),
  postal_code           VARCHAR(20),
  country_code          CHAR(2),
    -- ISO 3166-1 alpha-2 e.g. 'US', 'GB', 'NG'

  -- ── Avatar / Profile Display ──────────────────────────────────────────────
  display_name          VARCHAR(150),
    -- Derived from first_name + last_name or set manually.
    -- Used in navbar avatar (Figma: top-right profile photo with "AJ" initials)
  avatar_url            TEXT,
    -- URL to profile photo (Firebase Storage or S3)
  avatar_initials       CHAR(2),
    -- Computed: "AJ" from Alex Jonathan — shown as fallback when no photo

  -- ── KYC (Figma p19: "Status: Verified KYC" badge) ───────────────────────
  kyc_status            kyc_status_enum NOT NULL DEFAULT 'not_started',
  kyc_provider_ref      VARCHAR(100),
    -- Reference ID from external KYC provider (e.g. Jumio, Onfido)
  kyc_approved_at       TIMESTAMPTZ,
  kyc_expires_at        TIMESTAMPTZ,
    -- KYC re-verification required annually in most jurisdictions
  kyc_rejection_reason  TEXT,

  -- ── Account Preferences (Figma p19: Account Preferences section) ─────────
  base_currency         VARCHAR(10)   NOT NULL DEFAULT 'USD',
    -- Display currency for portfolio values. Currently USD only; future multi-currency
  language              VARCHAR(10)   NOT NULL DEFAULT 'en',
    -- BCP 47 language tag e.g. 'en', 'es', 'fr'
  timezone              VARCHAR(50)   NOT NULL DEFAULT 'America/New_York',

  -- ── Account State ─────────────────────────────────────────────────────────
  role                  VARCHAR(20)   NOT NULL DEFAULT 'investor'
                        CHECK (role IN ('investor', 'staker', 'admin', 'ops')),
    -- 'investor': standard trading user
    -- 'staker': also has staker_profile record
    -- 'admin'/'ops': internal staff
  is_active             BOOLEAN       NOT NULL DEFAULT TRUE,
    -- FALSE = soft-deleted or suspended account
  is_onboarded          BOOLEAN       NOT NULL DEFAULT FALSE,
    -- TRUE after user completes wallet connection step (Figma p22)
  joined_at             TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    -- Figma p19: "Joined: Mar 2023"
  last_login_at         TIMESTAMPTZ,
  last_active_at        TIMESTAMPTZ,

  -- ── Timestamps ────────────────────────────────────────────────────────────
  created_at            TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at            TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

-- Trigger: auto-stamp updated_at on every change
CREATE TRIGGER trg_auth_users_updated_at
  BEFORE UPDATE ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Indexes for common lookup patterns
CREATE INDEX IF NOT EXISTS idx_auth_users_firebase_uid  ON auth.users(firebase_uid);
CREATE INDEX IF NOT EXISTS idx_auth_users_email         ON auth.users(email);
CREATE INDEX IF NOT EXISTS idx_auth_users_kyc_status    ON auth.users(kyc_status) WHERE kyc_status != 'approved';
CREATE INDEX IF NOT EXISTS idx_auth_users_role          ON auth.users(role) WHERE role != 'investor';

COMMENT ON TABLE  auth.users IS 'Core user identity table. Synced from Firebase Auth on first login. Extended with BSE-specific profile, KYC, and preferences.';
COMMENT ON COLUMN auth.users.firebase_uid IS 'Firebase Authentication UID (from JWT claim uid). Permanent cross-system link. Never changes after account creation.';
COMMENT ON COLUMN auth.users.kyc_status   IS 'KYC verification state. Must be approved before user can deposit, buy, or withdraw. Figma shows "Verified KYC" badge on profile.';
COMMENT ON COLUMN auth.users.role         IS 'Coarse-grained access role. Fine-grained permissions handled at API layer. staker role requires a staking.staker_profiles record.';

-- ============================================================================
-- TABLE: auth.user_devices
-- Tracks devices that have authenticated. Maps to Figma p20 "Recent Devices"
-- (MacBook Pro - Safari CURRENT, iPhone 13 - App)
-- ============================================================================
CREATE TABLE IF NOT EXISTS auth.user_devices (
  id              UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id         UUID          NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,

  -- Device identity (from Firebase SDK or User-Agent parsing on backend)
  device_name     VARCHAR(100),
    -- "MacBook Pro", "iPhone 13" — parsed from User-Agent or sent by client
  browser_name    VARCHAR(50),
    -- "Safari", "Chrome", "App" (for native mobile)
  os_name         VARCHAR(50),
    -- "macOS", "iOS", "Android", "Windows"
  device_type     VARCHAR(20)
                  CHECK (device_type IN ('desktop', 'mobile', 'tablet', 'unknown'))
                  NOT NULL DEFAULT 'unknown',

  -- Location (shown in Figma p20: "New York, USA")
  ip_address      INET,
    -- Stored as PostgreSQL INET type — supports both IPv4 and IPv6
  city            VARCHAR(100),
  country_code    CHAR(2),

  -- Session state
  is_current      BOOLEAN       NOT NULL DEFAULT FALSE,
    -- TRUE = the device making the current request
  last_seen_at    TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  firebase_token  TEXT,
    -- FCM push notification token for this device (for push alerts)

  created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_auth_user_devices_updated_at
  BEFORE UPDATE ON auth.user_devices
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE INDEX IF NOT EXISTS idx_auth_devices_user_id ON auth.user_devices(user_id);
CREATE INDEX IF NOT EXISTS idx_auth_devices_ip      ON auth.user_devices(ip_address);

COMMENT ON TABLE auth.user_devices IS 'Authenticated devices per user. Shown in Profile > Security > Recent Devices (Figma p20). Enables "Sign Out" from specific device.';

-- ============================================================================
-- TABLE: auth.crypto_wallets
-- Connected crypto wallets. Figma p22: Connect Wallet step with
-- MetaMask, WalletConnect, Coinbase Wallet options.
-- ============================================================================
CREATE TABLE IF NOT EXISTS auth.crypto_wallets (
  id              UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id         UUID          NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,

  -- Figma p11: wallet address shown as "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb"
  wallet_address  VARCHAR(42)   NOT NULL,
    -- Ethereum address, EIP-55 checksum format, 42 chars including '0x'
  provider        wallet_provider_enum NOT NULL,
    -- metamask | walletconnect | coinbase | other
  network         VARCHAR(30)   NOT NULL DEFAULT 'ethereum',
    -- 'ethereum', 'polygon' etc — for future multi-chain support
  is_primary      BOOLEAN       NOT NULL DEFAULT FALSE,
    -- The wallet used for deposits/withdrawals by default
  is_verified     BOOLEAN       NOT NULL DEFAULT FALSE,
    -- TRUE after signature challenge verified (proves wallet ownership)
  connected_at    TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  last_used_at    TIMESTAMPTZ,

  created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),

  -- One address per network per user (can't link same wallet twice)
  CONSTRAINT uq_crypto_wallet_user_address UNIQUE (user_id, wallet_address, network)
);

CREATE TRIGGER trg_auth_crypto_wallets_updated_at
  BEFORE UPDATE ON auth.crypto_wallets
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Partial index: enforce only one primary wallet per user
CREATE UNIQUE INDEX IF NOT EXISTS uq_auth_wallet_primary_per_user
  ON auth.crypto_wallets(user_id)
  WHERE is_primary = TRUE;

CREATE INDEX IF NOT EXISTS idx_auth_wallets_user_id        ON auth.crypto_wallets(user_id);
CREATE INDEX IF NOT EXISTS idx_auth_wallets_address        ON auth.crypto_wallets(wallet_address);

COMMENT ON TABLE auth.crypto_wallets IS 'User-connected crypto wallets (MetaMask, WalletConnect, Coinbase). Figma p22. wallet_address is the Ethereum address; verified via sign-challenge before use.';

-- ============================================================================
-- TABLE: auth.payment_methods
-- Figma p21: Payment Methods → Chase Bank (Visa Debit) and Bank of America
-- (Checking Account). Stores masked card/bank data — actual tokens in
-- payment processor vault (Stripe/Plaid).
-- ============================================================================
CREATE TABLE IF NOT EXISTS auth.payment_methods (
  id                    UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id               UUID          NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  method_type           payment_method_type_enum NOT NULL,
    -- 'card' (Visa debit), 'bank_account' (checking), 'crypto_wallet'

  -- Display data (Figma p21 shows last 4 digits and institution name)
  institution_name      VARCHAR(100),
    -- "Chase Bank", "Bank of America"
  masked_number         VARCHAR(20),
    -- "**** **** **** 4242" for card, "**** **** 8891" for bank
  card_brand            VARCHAR(20),
    -- "visa", "mastercard", "amex" — null for bank accounts
  card_expiry_month     SMALLINT      CHECK (card_expiry_month BETWEEN 1 AND 12),
  card_expiry_year      SMALLINT,
    -- Figma p21: "Expires 12/26"
  account_type          VARCHAR(20),
    -- "debit", "checking", "savings" — null for cards

  -- Payment processor references (never store raw card numbers)
  processor_token       VARCHAR(255),
    -- Stripe payment_method ID or Plaid processor_token
  processor_type        VARCHAR(20) DEFAULT 'stripe',
    -- 'stripe', 'plaid'

  is_default            BOOLEAN       NOT NULL DEFAULT FALSE,
    -- Figma p21: "Default" badge on Chase Bank card
  is_verified           BOOLEAN       NOT NULL DEFAULT FALSE,
    -- Figma p21: "Verified" label on Bank of America account

  created_at            TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at            TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_auth_payment_methods_updated_at
  BEFORE UPDATE ON auth.payment_methods
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Enforce only one default payment method per user
CREATE UNIQUE INDEX IF NOT EXISTS uq_auth_payment_default_per_user
  ON auth.payment_methods(user_id)
  WHERE is_default = TRUE;

CREATE INDEX IF NOT EXISTS idx_auth_payment_methods_user_id ON auth.payment_methods(user_id);

COMMENT ON TABLE auth.payment_methods IS 'Saved payment methods (cards, bank accounts). Figma p21 Payment Methods tab. Raw card data never stored — only processor tokens from Stripe/Plaid.';

-- ============================================================================
-- TABLE: auth.notification_preferences
-- Figma p23: Notification Preferences
-- Four categories × two channels (Email, Push) = 8 boolean flags per user.
-- ============================================================================
CREATE TABLE IF NOT EXISTS auth.notification_preferences (
  id                          UUID    PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id                     UUID    NOT NULL UNIQUE REFERENCES auth.users(id) ON DELETE CASCADE,
    -- UNIQUE: exactly one preferences row per user

  -- Figma p23: "Successful Trades — Receive alerts when your trades execute"
  trade_executed_email        BOOLEAN NOT NULL DEFAULT TRUE,
  trade_executed_push         BOOLEAN NOT NULL DEFAULT TRUE,

  -- Figma p23: "Price Alerts — Get notified when assets in your watchlist hit target prices"
  price_alert_email           BOOLEAN NOT NULL DEFAULT TRUE,
  price_alert_push            BOOLEAN NOT NULL DEFAULT TRUE,

  -- Figma p23: "Security Alerts — Important notifications about your account security"
  security_alert_email        BOOLEAN NOT NULL DEFAULT TRUE,
  security_alert_push         BOOLEAN NOT NULL DEFAULT TRUE,
    -- Security alerts always default TRUE — important for fraud prevention

  -- Figma p23: "Marketing Updates — News, feature updates, and promotional offers"
  marketing_email             BOOLEAN NOT NULL DEFAULT FALSE,
  marketing_push              BOOLEAN NOT NULL DEFAULT FALSE,
    -- Marketing defaults to FALSE per GDPR/CAN-SPAM best practice

  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_auth_notification_prefs_updated_at
  BEFORE UPDATE ON auth.notification_preferences
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

COMMENT ON TABLE auth.notification_preferences IS 'Per-user notification channel settings. Figma p23. Auto-created with defaults on user registration via trigger.';

-- ============================================================================
-- FUNCTION + TRIGGER: Auto-create default notification_preferences on new user
-- When a user row is inserted, immediately create their preferences row.
-- Prevents "no preferences record" bugs in the notification service.
-- ============================================================================
CREATE OR REPLACE FUNCTION auth.create_default_notification_prefs()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  -- Insert default notification preferences for every new user.
  -- ON CONFLICT DO NOTHING: safe to re-run on upsert flows.
  INSERT INTO auth.notification_preferences (user_id)
  VALUES (NEW.id)
  ON CONFLICT (user_id) DO NOTHING;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_auth_users_create_prefs
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION auth.create_default_notification_prefs();

COMMENT ON FUNCTION auth.create_default_notification_prefs() IS
  'Auto-creates notification_preferences row with safe defaults on new user insert.';

-- ============================================================================
-- TABLE: auth.price_alerts
-- Figma p23: "Price Alerts — Get notified when assets in your watchlist hit target prices"
-- Stores the actual alert threshold per stock per user.
-- ============================================================================
CREATE TABLE IF NOT EXISTS auth.price_alerts (
  id              UUID            PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id         UUID            NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  token_symbol    VARCHAR(12)     NOT NULL,
    -- Stock token symbol e.g. 'AAPL-T', referenced to core.stock_tokens
  alert_direction VARCHAR(5)      NOT NULL CHECK (alert_direction IN ('above', 'below')),
    -- 'above': notify when price rises above threshold
    -- 'below': notify when price falls below threshold
  threshold_price NUMERIC(20, 8)  NOT NULL CHECK (threshold_price > 0),
  is_active       BOOLEAN         NOT NULL DEFAULT TRUE,
  triggered_at    TIMESTAMPTZ,
    -- Stamped when the alert fires; is_active set to FALSE after single-fire
  created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_auth_price_alerts_updated_at
  BEFORE UPDATE ON auth.price_alerts
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE INDEX IF NOT EXISTS idx_auth_price_alerts_user_id ON auth.price_alerts(user_id);
CREATE INDEX IF NOT EXISTS idx_auth_price_alerts_active  ON auth.price_alerts(token_symbol, is_active) WHERE is_active = TRUE;

COMMENT ON TABLE auth.price_alerts IS 'User-defined price alert thresholds per stock token. Checked by NAV engine after each EOD calculation.';

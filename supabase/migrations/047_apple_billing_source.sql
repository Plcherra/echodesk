-- Apple In-App Purchase columns on subscriptions.
-- Existing Stripe rows are labeled billing_source = 'stripe' when they have a
-- provider subscription id. Comped rows (comp_source = 'manual_comp_no_stripe',
-- when that column exists) are left with billing_source NULL so they are not
-- treated as Stripe or Apple. billing_source stays nullable for that reason.

ALTER TABLE public.subscriptions
  ADD COLUMN IF NOT EXISTS billing_source TEXT,
  ADD COLUMN IF NOT EXISTS apple_original_transaction_id TEXT,
  ADD COLUMN IF NOT EXISTS apple_transaction_id TEXT,
  ADD COLUMN IF NOT EXISTS apple_product_id TEXT,
  ADD COLUMN IF NOT EXISTS apple_environment TEXT,
  ADD COLUMN IF NOT EXISTS apple_app_account_token TEXT,
  ADD COLUMN IF NOT EXISTS expires_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS apple_billing_grace BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS apple_last_notification_type TEXT,
  ADD COLUMN IF NOT EXISTS apple_last_notification_uuid TEXT,
  ADD COLUMN IF NOT EXISTS apple_signed_date_ms BIGINT;

-- Allow grace_period without rejecting current Stripe statuses.
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT conname
    FROM pg_constraint
    WHERE conrelid = 'public.subscriptions'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%status%'
      AND conname <> 'subscriptions_billing_source_check'
  LOOP
    EXECUTE format('ALTER TABLE public.subscriptions DROP CONSTRAINT %I', r.conname);
  END LOOP;
END $$;

ALTER TABLE public.subscriptions
  ADD CONSTRAINT subscriptions_status_check
  CHECK (status IN ('trialing', 'active', 'past_due', 'canceled', 'grace_period'));

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'subscriptions_billing_source_check'
      AND conrelid = 'public.subscriptions'::regclass
  ) THEN
    ALTER TABLE public.subscriptions
      ADD CONSTRAINT subscriptions_billing_source_check
      CHECK (billing_source IS NULL OR billing_source IN ('stripe', 'apple'));
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS subscriptions_apple_original_transaction_id_uidx
  ON public.subscriptions (apple_original_transaction_id)
  WHERE apple_original_transaction_id IS NOT NULL;

-- Label real Stripe rows. Do not label manual comps, even if a provider id is set.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'subscriptions'
      AND column_name = 'comp_source'
  ) THEN
    EXECUTE $sql$
      UPDATE public.subscriptions
      SET billing_source = 'stripe'
      WHERE billing_source IS NULL
        AND billing_provider_subscription_id IS NOT NULL
        AND COALESCE(comp_source, '') IS DISTINCT FROM 'manual_comp_no_stripe'
    $sql$;
  ELSE
    UPDATE public.subscriptions
    SET billing_source = 'stripe'
    WHERE billing_source IS NULL
      AND billing_provider_subscription_id IS NOT NULL;
  END IF;
END $$;

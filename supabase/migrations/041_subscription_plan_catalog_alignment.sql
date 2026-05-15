-- Align Supabase plan catalog with the mobile/backend Stripe plans used in production.

ALTER TABLE public.plans DROP CONSTRAINT IF EXISTS plans_code_check;

DELETE FROM public.plans
WHERE code = 'enterprise';

ALTER TABLE public.plans ADD CONSTRAINT plans_code_check
  CHECK (code IN ('starter', 'growth', 'pro', 'business', 'dev_test', 'payg'));

INSERT INTO public.plans (
  code,
  name,
  monthly_fee_cents,
  included_minutes,
  overage_rate_cents_per_minute,
  is_active,
  metadata_json
)
VALUES
  ('starter', 'Starter', 6900, 300, 8, true, '{"billing_plan": "subscription_starter"}'::jsonb),
  ('growth', 'Growth', 5900, 800, 8, false, '{"billing_plan": "subscription_growth", "legacy": true}'::jsonb),
  ('pro', 'Pro', 14900, 1800, 8, true, '{"billing_plan": "subscription_pro"}'::jsonb),
  ('business', 'Business', 24900, 1500, 8, true, '{"billing_plan": "subscription_business"}'::jsonb),
  ('dev_test', 'DEV test', 100, 50, 8, true, '{"billing_plan": "subscription_dev_test", "internal": true}'::jsonb),
  ('payg', 'Pay As You Go', 0, 0, 8, false, '{"billing_plan": "subscription_payg", "legacy": true}'::jsonb)
ON CONFLICT (code) DO UPDATE SET
  name = EXCLUDED.name,
  monthly_fee_cents = EXCLUDED.monthly_fee_cents,
  included_minutes = EXCLUDED.included_minutes,
  overage_rate_cents_per_minute = EXCLUDED.overage_rate_cents_per_minute,
  is_active = EXCLUDED.is_active,
  metadata_json = EXCLUDED.metadata_json;

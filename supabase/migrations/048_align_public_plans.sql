-- Align the public plan catalog with the iOS subscription group.
-- Starter $69 / 250 min, Growth $149 / 750 min, Business $249 / 1,500 min.
-- Stripe overage is $0.25, $0.20, and $0.18 per minute. Apple billing does not
-- use these rates.
--
-- This updates catalog rows only. It does not rewrite subscriptions, user_plans,
-- or comped accounts (including comp_source = 'manual_comp_no_stripe').

UPDATE public.plans
SET
  name = 'Starter',
  monthly_fee_cents = 6900,
  included_minutes = 250,
  overage_rate_cents_per_minute = 25,
  is_active = true,
  metadata_json = '{"billing_plan": "subscription_starter"}'::jsonb
WHERE code = 'starter';

UPDATE public.plans
SET
  name = 'Growth',
  monthly_fee_cents = 14900,
  included_minutes = 750,
  overage_rate_cents_per_minute = 20,
  is_active = true,
  metadata_json = '{"billing_plan": "subscription_growth"}'::jsonb
WHERE code = 'growth';

UPDATE public.plans
SET
  name = 'Business',
  monthly_fee_cents = 24900,
  included_minutes = 1500,
  overage_rate_cents_per_minute = 18,
  is_active = true,
  metadata_json = '{"billing_plan": "subscription_business"}'::jsonb
WHERE code = 'business';

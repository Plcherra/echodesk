# Stripe products Pedro needs to create

The app does not create these in Stripe. Create one recurring monthly Price for each public plan, then put the Price id in the environment. Overage is invoiced by the backend from `overage_rate_cents`; it is not a second Stripe Price unless you also set the optional `STRIPE_PRICE_OVERAGE`.

Do not change comped accounts. Migration `048_align_public_plans.sql` updates the plan catalog only.

| Plan | Env var | Monthly price | Included minutes | Overage |
|------|---------|---------------|------------------|---------|
| Starter | `STRIPE_PRICE_STARTER` | $69.00 | 250 | $0.25 / minute |
| Growth | `STRIPE_PRICE_GROWTH` | $149.00 | 750 | $0.20 / minute |
| Business | `STRIPE_PRICE_BUSINESS` | $249.00 | 1,500 | $0.18 / minute |

Product settings:

- Type: recurring
- Interval: month
- Currency: USD
- No trial on the Price itself. Checkout adds `trial_period_days = 14` for a customer who is not already active, trialing, or in billing grace. The trial includes 50 minutes. The first paid invoice uses the full minute allowance above.

Leave the existing legacy price ids (`STRIPE_PRICE_PRO`, `STRIPE_PRICE_ENTERPRISE`, `STRIPE_PRICE_DEV_TEST`, `STRIPE_PRICE_PAYG`) mapped if those subscriptions still exist. `dev_test` stays debug-only and does not get the 14-day trial.

After the new Price ids are in the server environment, new Checkout sessions use them. Existing Stripe subscriptions keep the minutes stored on the account until Stripe sends a subscription update.

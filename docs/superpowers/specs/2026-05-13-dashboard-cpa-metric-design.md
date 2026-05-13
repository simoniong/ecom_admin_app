# Dashboard CPA Metric — Design Spec

**Date**: 2026-05-13
**Branch**: `feature/dashboard-cpa-metric`
**Target**: `staging`

## Goal

Add two cost-efficiency metrics to the company dashboard so operators can continuously monitor ad acquisition cost alongside existing Orders / Revenue / AOV / Ad Spend / ROAS cards:

- **CPA** = Ad Spend ÷ Orders
- **New Customer CPA** = Ad Spend ÷ New Customer Orders

Both should support the same date-range selector (today / yesterday / 7d / this month / last month / 30d / custom) and surface the previous-period delta badge like other cards. Because lower is better, both cards use `invert_color: true`.

## Non-goals

- No per-campaign or per-ad-account CPA breakdown (out of scope; that lives on `/ad_campaigns`).
- No alerting / threshold notifications. Pure display.
- No historical recomputation older than the backfill window.

## Definition: New Customer

A new-customer order is an order whose `customer.numberOfOrders == 1` **at the moment the order was created in Shopify**. This matches Shopify's own Acquisition reports and avoids depending on whether local DB has imported the customer's full history.

Implementation reads `customer { numberOfOrders }` from the Shopify GraphQL Order node during the daily sync. The value is captured into `shopify_daily_metrics.new_customer_orders_count` at sync time and never recomputed (the underlying Shopify value drifts as the customer places more orders, so we must snapshot at sync time, not query time).

## Data Layer

### Migration

```ruby
add_column :shopify_daily_metrics, :new_customer_orders_count, :integer, default: 0, null: false
```

No index needed — the column is only read inside an existing date-range scan that is already indexed by `(shopify_store_id, date)`.

### Model

`ShopifyDailyMetric`:

```ruby
validates :new_customer_orders_count,
          numericality: { only_integer: true, greater_than_or_equal_to: 0 }
```

## Sync Layer

### `ShopifyAnalyticsService#fetch_orders_via_graphql`

Modify the GraphQL query node selection to include the customer:

```graphql
node {
  subtotalPriceSet { shopMoney { amount } }
  totalShippingPriceSet { shopMoney { amount } }
  totalTaxSet { shopMoney { amount } }
  customer { numberOfOrders }
}
```

Inside the edge loop:

```ruby
total_count += 1
total_new_customer_count += 1 if node.dig("customer", "numberOfOrders").to_i == 1
```

Return `[total_count, gross_revenue, total_new_customer_count]`. Orders with no associated customer (guest checkout edge cases) do not count as new-customer acquisitions — treat `nil` customer as 0.

`sync_date` writes the new field:

```ruby
metric.assign_attributes(
  sessions: 0,
  orders_count: orders_count,
  new_customer_orders_count: new_customer_orders_count,
  revenue: gross_revenue - refunds_total,
  conversion_rate: 0
)
```

### Backfill

New rake task:

```ruby
# lib/tasks/shopify_backfill.rake
namespace :shopify do
  desc "Backfill new_customer_orders_count for the past N days (default 90)"
  task :backfill_new_customer_orders, [ :days ] => :environment do |_, args|
    days = (args[:days] || "90").to_i
    # validate days >= 1 and abort with a clear message otherwise
    # iterate stores, then each date in the window, calling sync_date
    # log progress per store/date; rescue + continue on errors
  end
end
```

Behavior:
- Iterates every `ShopifyStore` × every date in a `days`-long window ending today (i.e. `(Date.current - (days - 1).days)..Date.current`)
- Validates `days >= 1`; aborts with a clear message on bad input (prevents silent no-op when `args[:days]` is non-numeric)
- Re-runs `ShopifyAnalyticsService#sync_date` per date — idempotent because `sync_date` does `find_or_initialize_by` + `assign_attributes` + `save!`
- Logs `[backfill] store=<domain> date=<date> ok` on success and `... error=<message>` on failure
- Rescues per-iteration so one store failing doesn't abort the run

Not scheduled automatically. Operator runs `bundle exec rake "shopify:backfill_new_customer_orders[90]"` once after deploy.

## Service Layer

`DashboardMetricsService#aggregate_metrics` adds:

```ruby
new_customer_orders = shopify.sum(:new_customer_orders_count)
# ...
cpa: orders > 0 && ad_spend > 0 ? (ad_spend / orders).round(2) : nil,
new_customer_cpa: new_customer_orders > 0 && ad_spend > 0 ? (ad_spend / new_customer_orders).round(2) : nil,
new_customer_orders: new_customer_orders
```

`nil` (not 0) signals "cannot compute" to the view so it can render `—`. Returning 0 would be ambiguous (true zero vs missing data).

The existing previous-period comparison logic works unchanged because `previous_range` already returns a comparable scope.

## View Layer

`app/views/dashboard/show.html.erb`:

1. Change grid from `lg:grid-cols-5` → `lg:grid-cols-4`. Result: row 1 = Orders / Revenue / AOV / Ad Spend; row 2 = ROAS / CPA / New Customer CPA. The bottom row has 3 filled cells + 1 trailing empty slot, which is acceptable visually (cards left-align by default).
2. Add two `render "dashboard/metric_card"` invocations after ROAS:

```erb
<%= render "dashboard/metric_card",
    title: t("dashboard.cpa"),
    value: @metrics[:current][:cpa] ? number_to_currency(@metrics[:current][:cpa]) : "—",
    previous: @metrics[:previous][:cpa],
    current_raw: @metrics[:current][:cpa],
    invert_color: true %>

<%= render "dashboard/metric_card",
    title: t("dashboard.new_customer_cpa"),
    value: @metrics[:current][:new_customer_cpa] ? number_to_currency(@metrics[:current][:new_customer_cpa]) : "—",
    previous: @metrics[:previous][:new_customer_cpa],
    current_raw: @metrics[:current][:new_customer_cpa],
    invert_color: true %>
```

`_metric_card.html.erb` currently guards with `if previous && previous != 0`, but if `current_raw` is nil while `previous` is non-nil, line 7 will raise on `nil - previous`. Update the partial's guard to:

```erb
<% if previous && previous != 0 && current_raw %>
```

This is a small, in-scope improvement to the partial because the new metrics legitimately can be nil while a previous period has a real value (e.g., this week has 0 orders, last week had 10).

## i18n

`config/locales/en.yml`:
```yml
dashboard:
  cpa: "CPA"
  new_customer_cpa: "New Customer CPA"
```

`config/locales/zh-TW.yml` (and any other present locales):
```yml
dashboard:
  cpa: "CPA"
  new_customer_cpa: "新客 CPA"
```

## Tests

All new tests follow the existing RSpec + FactoryBot conventions. No mocks against the DB. External Shopify GraphQL calls are stubbed via WebMock or the existing test pattern in `shopify_analytics_service_spec.rb`.

### `spec/models/shopify_daily_metric_spec.rb`
- `new_customer_orders_count` is non-negative integer
- defaults to 0

### `spec/services/dashboard_metrics_service_spec.rb`
- CPA = ad_spend / orders when both positive
- CPA = nil when orders == 0
- CPA = nil when ad_spend == 0
- New Customer CPA = ad_spend / new_customer_orders_count
- New Customer CPA = nil when new_customer_orders_count == 0
- Previous-period CPA computed against `previous_range`

### `spec/services/shopify_analytics_service_spec.rb`
- Given a stubbed GraphQL response with three orders where two have `customer: { numberOfOrders: 1 }` and one has `numberOfOrders: 5`, `new_customer_orders_count` written is 2
- Guest checkout (`customer: null`) is not counted as new
- Idempotent re-run updates existing metric in place

### `spec/requests/dashboard_request_spec.rb`
- Page renders CPA and New Customer CPA card titles
- Page renders `—` when no data
- Card shows currency-formatted value when data present

### `spec/tasks/shopify_backfill_new_customer_orders_spec.rb` (new file)
- Iterates configured store + date range
- Calls `ShopifyAnalyticsService#sync_date` per (store, date)
- Continues on per-iteration failure
- Default window is 90 days when no arg given

Run `bundle exec rspec` after implementation; coverage must stay ≥ 95%.

## Migration & Deployment Sequence

1. Branch `feature/dashboard-cpa-metric` from `origin/staging`
2. Migration → service → view → i18n → tests on the branch
3. PR to `staging`
4. After staging deploy, operator runs `rake "shopify:backfill_new_customer_orders[90]"` once
5. PR `staging` → `main` for production

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Shopify rate limits during backfill | Per-iteration rescue + sync_date already has its own error handling; operator can re-run if some days fail |
| `customer.numberOfOrders` is the value *after* this order (counts include current order) | Shopify's documented behavior: numberOfOrders includes the order being queried, so first-ever order returns `1`. This is the intended definition |
| `_metric_card` partial raises when `current_raw` is nil and `previous` is non-nil | Update partial guard to also check `current_raw` — see View Layer section |
| 7 cards on narrow screens | Grid degrades to `grid-cols-2` on mobile, so layout already handles wrap |

## Out of Scope (future)

- CPA per ad campaign / per ad account
- Lifetime-value-adjusted CPA (CAC payback)
- Channel-attributed CPA (Meta vs Google etc.)

# Dashboard CPA Metric Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add CPA (Ad Spend ÷ Orders) and New Customer CPA (Ad Spend ÷ New Customer Orders) to the company dashboard, capturing new-customer signal from Shopify's `customer.numberOfOrders` field at daily sync time.

**Architecture:** Snapshot new-customer order count into a new `shopify_daily_metrics.new_customer_orders_count` column during the existing daily Shopify GraphQL sync. The dashboard service aggregates this into two derived metrics. A rake task backfills the past 90 days by re-running the sync, which is idempotent.

**Tech Stack:** Rails 8.1, PostgreSQL (UUIDs), RSpec + FactoryBot, Shopify GraphQL Admin API, Hotwire/Turbo Frames, Tailwind CSS.

**Branch:** `feature/dashboard-cpa-metric` (already cut from `origin/staging`).

**Spec:** `docs/superpowers/specs/2026-05-13-dashboard-cpa-metric-design.md`.

---

## Task 1: Migration — add `new_customer_orders_count` column

**Files:**
- Create: `db/migrate/20260513000001_add_new_customer_orders_count_to_shopify_daily_metrics.rb`

- [ ] **Step 1: Write the migration**

```ruby
class AddNewCustomerOrdersCountToShopifyDailyMetrics < ActiveRecord::Migration[8.1]
  def change
    add_column :shopify_daily_metrics, :new_customer_orders_count, :integer, default: 0, null: false
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `bin/rails db:migrate`
Expected: `add_column(:shopify_daily_metrics, :new_customer_orders_count, :integer, ...)` and a `Migrated` line.

- [ ] **Step 3: Run the test DB prep**

Run: `bin/rails db:test:prepare`
Expected: silent success.

- [ ] **Step 4: Commit**

```bash
git add db/migrate/20260513000001_add_new_customer_orders_count_to_shopify_daily_metrics.rb db/schema.rb
git commit -m "feat: add new_customer_orders_count column to shopify_daily_metrics"
```

---

## Task 2: Model — validation for new column

**Files:**
- Modify: `app/models/shopify_daily_metric.rb`
- Test: `spec/models/shopify_daily_metric_spec.rb`

- [ ] **Step 1: Write the failing tests**

Add inside `RSpec.describe ShopifyDailyMetric, type: :model do` block in `spec/models/shopify_daily_metric_spec.rb`, after the existing `it "validates orders_count is non-negative"` example:

```ruby
  it "validates new_customer_orders_count is non-negative" do
    metric.new_customer_orders_count = -1
    expect(metric).not_to be_valid
  end

  it "defaults new_customer_orders_count to 0" do
    fresh = described_class.new(shopify_store: store, date: Date.current)
    expect(fresh.new_customer_orders_count).to eq(0)
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/models/shopify_daily_metric_spec.rb -e "new_customer_orders_count"`
Expected: 2 failures — the validation example fails because no validation exists; the default example passes (column default `0` from migration handles it).

- [ ] **Step 3: Add the validation**

Update `app/models/shopify_daily_metric.rb` to:

```ruby
class ShopifyDailyMetric < ApplicationRecord
  belongs_to :shopify_store

  validates :date, presence: true
  validates :sessions, numericality: { greater_than_or_equal_to: 0 }
  validates :orders_count, numericality: { greater_than_or_equal_to: 0 }
  validates :new_customer_orders_count,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :revenue, numericality: true

  scope :for_date_range, ->(range) { where(date: range) }
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/models/shopify_daily_metric_spec.rb`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add app/models/shopify_daily_metric.rb spec/models/shopify_daily_metric_spec.rb
git commit -m "feat: validate new_customer_orders_count on shopify_daily_metric"
```

---

## Task 3: Factory — default new column

**Files:**
- Modify: `spec/factories/shopify_daily_metrics.rb`

- [ ] **Step 1: Update factory**

Replace contents of `spec/factories/shopify_daily_metrics.rb` with:

```ruby
FactoryBot.define do
  factory :shopify_daily_metric do
    association :shopify_store
    date { Date.current }
    sessions { 500 }
    orders_count { 20 }
    new_customer_orders_count { 5 }
    revenue { 1500.00 }
    conversion_rate { 0.04 }
  end
end
```

- [ ] **Step 2: Run model specs to confirm factory still builds**

Run: `bundle exec rspec spec/models/shopify_daily_metric_spec.rb`
Expected: all green.

- [ ] **Step 3: Commit**

```bash
git add spec/factories/shopify_daily_metrics.rb
git commit -m "test: include new_customer_orders_count default in factory"
```

---

## Task 4: Sync service — capture new-customer count from GraphQL

**Files:**
- Modify: `app/services/shopify_analytics_service.rb`
- Test: `spec/services/shopify_analytics_service_spec.rb`

- [ ] **Step 1: Update the shared GraphQL helper in the spec to accept new_customer flag**

In `spec/services/shopify_analytics_service_spec.rb`, replace the existing `orders_graphql_response` helper with the version below (additive — adds optional `:number_of_orders` per order, default keeps old tests working):

```ruby
  def orders_graphql_response(orders)
    edges = orders.map.with_index do |o, i|
      number_of_orders = o.key?(:number_of_orders) ? o[:number_of_orders] : 5
      customer_node = number_of_orders.nil? ? nil : { "numberOfOrders" => number_of_orders }
      {
        "cursor" => "cursor_#{i}",
        "node" => {
          "subtotalPriceSet" => { "shopMoney" => { "amount" => o[:subtotal] } },
          "totalShippingPriceSet" => { "shopMoney" => { "amount" => o[:shipping] } },
          "totalTaxSet" => { "shopMoney" => { "amount" => o[:tax] } },
          "customer" => customer_node
        }
      }
    end
    { "data" => { "orders" => { "edges" => edges, "pageInfo" => { "hasNextPage" => false } } } }
  end
```

(Default `:number_of_orders` is `5` so existing tests treat every order as a returning customer; tests that care override it.)

- [ ] **Step 2: Write failing tests for new-customer counting**

Add this `describe` block to `spec/services/shopify_analytics_service_spec.rb` inside the top-level `RSpec.describe ShopifyAnalyticsService do` block, after the existing `describe "#sync_date" do` block closes (i.e. as a sibling describe block):

```ruby
  describe "#sync_date new-customer counting" do
    it "counts orders where customer.numberOfOrders is 1 as new-customer orders" do
      stub_graphql([
        orders_graphql_response([
          { subtotal: "100.00", shipping: "0", tax: "0", number_of_orders: 1 },
          { subtotal: "100.00", shipping: "0", tax: "0", number_of_orders: 1 },
          { subtotal: "100.00", shipping: "0", tax: "0", number_of_orders: 7 }
        ]),
        empty_graphql_response
      ])

      service.sync_date(Date.current)

      metric = ShopifyDailyMetric.last
      expect(metric.orders_count).to eq(3)
      expect(metric.new_customer_orders_count).to eq(2)
    end

    it "treats orders with no customer as not new (guest checkout)" do
      stub_graphql([
        orders_graphql_response([
          { subtotal: "100.00", shipping: "0", tax: "0", number_of_orders: nil },
          { subtotal: "100.00", shipping: "0", tax: "0", number_of_orders: 1 }
        ]),
        empty_graphql_response
      ])

      service.sync_date(Date.current)

      metric = ShopifyDailyMetric.last
      expect(metric.new_customer_orders_count).to eq(1)
    end

    it "is idempotent: re-running updates the same metric row in place" do
      stub_graphql([
        orders_graphql_response([
          { subtotal: "100.00", shipping: "0", tax: "0", number_of_orders: 1 }
        ]),
        empty_graphql_response,
        orders_graphql_response([
          { subtotal: "100.00", shipping: "0", tax: "0", number_of_orders: 1 },
          { subtotal: "100.00", shipping: "0", tax: "0", number_of_orders: 1 }
        ]),
        empty_graphql_response
      ])

      service.sync_date(Date.current)
      expect { service.sync_date(Date.current) }.not_to change(ShopifyDailyMetric, :count)

      expect(ShopifyDailyMetric.last.new_customer_orders_count).to eq(2)
    end
  end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bundle exec rspec spec/services/shopify_analytics_service_spec.rb -e "new-customer"`
Expected: 3 failures — `new_customer_orders_count` is always 0 because service doesn't read it.

- [ ] **Step 4: Update the service to capture new-customer count**

In `app/services/shopify_analytics_service.rb`:

Replace the `sync_date` method body to receive three values from the orders fetch and write the new field:

```ruby
  def sync_date(date)
    min_time = @timezone.parse(date.to_s).beginning_of_day.utc
    max_time = @timezone.parse(date.to_s).end_of_day.utc

    client = build_graphql_client
    orders_count, gross_revenue, new_customer_orders_count =
      fetch_orders_via_graphql(client, min_time, max_time)

    refunds_total = fetch_refunds_via_graphql(client, min_time, max_time)

    metric = ShopifyDailyMetric.find_or_initialize_by(
      shopify_store_id: @store_id, date: date
    )
    metric.assign_attributes(
      sessions: 0,
      orders_count: orders_count,
      new_customer_orders_count: new_customer_orders_count,
      revenue: gross_revenue - refunds_total,
      conversion_rate: 0
    )
    metric.save!
  rescue => e
    Rails.logger.error("[ShopifyAnalytics] Failed to sync for #{date}: #{e.message}")
  end
```

Replace `fetch_orders_via_graphql` to also select `customer { numberOfOrders }` and tally the new-customer count:

```ruby
  def fetch_orders_via_graphql(client, min_time, max_time)
    cursor = nil
    total_count = 0
    total_revenue = BigDecimal("0")
    total_new_customer_count = 0

    loop do
      after_clause = cursor ? ", after: \"#{cursor}\"" : ""
      query = <<~GQL
        {
          orders(first: 100#{after_clause}, query: "created_at:>='#{min_time.iso8601}' AND created_at:<='#{max_time.iso8601}'") {
            edges {
              cursor
              node {
                subtotalPriceSet { shopMoney { amount } }
                totalShippingPriceSet { shopMoney { amount } }
                totalTaxSet { shopMoney { amount } }
                customer { numberOfOrders }
              }
            }
            pageInfo { hasNextPage }
          }
        }
      GQL

      response = client.query(query: query)
      data = response.body.dig("data", "orders")
      break unless data

      edges = data["edges"] || []
      break if edges.empty?

      edges.each do |edge|
        node = edge["node"]
        total_count += 1
        total_revenue += node.dig("subtotalPriceSet", "shopMoney", "amount").to_d +
          node.dig("totalShippingPriceSet", "shopMoney", "amount").to_d +
          node.dig("totalTaxSet", "shopMoney", "amount").to_d
        total_new_customer_count += 1 if node.dig("customer", "numberOfOrders").to_i == 1
      end

      break unless data.dig("pageInfo", "hasNextPage")
      cursor = edges.last["cursor"]
    end

    [ total_count, total_revenue, total_new_customer_count ]
  end
```

- [ ] **Step 5: Run all analytics service specs to verify**

Run: `bundle exec rspec spec/services/shopify_analytics_service_spec.rb`
Expected: all green (existing tests still pass because helper default is `number_of_orders: 5`; new tests pass).

- [ ] **Step 6: Commit**

```bash
git add app/services/shopify_analytics_service.rb spec/services/shopify_analytics_service_spec.rb
git commit -m "feat: capture new-customer order count during Shopify daily sync"
```

---

## Task 5: Dashboard metrics service — compute CPA and new-customer CPA

**Files:**
- Modify: `app/services/dashboard_metrics_service.rb`
- Test: `spec/services/dashboard_metrics_service_spec.rb`

- [ ] **Step 1: Write failing tests**

Append to the `describe "#call" do` block in `spec/services/dashboard_metrics_service_spec.rb`, before the closing `end` of the describe:

```ruby
    it "calculates CPA as ad_spend divided by orders" do
      create(:shopify_daily_metric, shopify_store: store, date: Date.current, sessions: 100, orders_count: 10, new_customer_orders_count: 4, revenue: 500)
      create(:ad_daily_metric, ad_account: ad_account, date: Date.current, spend: 50)

      result = described_class.new(user, range_key: "today").call
      expect(result[:current][:cpa]).to eq(5.0)
    end

    it "returns nil CPA when there are no orders" do
      create(:ad_daily_metric, ad_account: ad_account, date: Date.current, spend: 50)

      result = described_class.new(user, range_key: "today").call
      expect(result[:current][:cpa]).to be_nil
    end

    it "returns nil CPA when there is no ad spend" do
      create(:shopify_daily_metric, shopify_store: store, date: Date.current, orders_count: 10, new_customer_orders_count: 4, revenue: 500)

      result = described_class.new(user, range_key: "today").call
      expect(result[:current][:cpa]).to be_nil
    end

    it "calculates new_customer_cpa as ad_spend divided by new_customer_orders_count" do
      create(:shopify_daily_metric, shopify_store: store, date: Date.current, orders_count: 10, new_customer_orders_count: 4, revenue: 500)
      create(:ad_daily_metric, ad_account: ad_account, date: Date.current, spend: 80)

      result = described_class.new(user, range_key: "today").call
      expect(result[:current][:new_customer_cpa]).to eq(20.0)
    end

    it "returns nil new_customer_cpa when new_customer_orders_count is zero" do
      create(:shopify_daily_metric, shopify_store: store, date: Date.current, orders_count: 10, new_customer_orders_count: 0, revenue: 500)
      create(:ad_daily_metric, ad_account: ad_account, date: Date.current, spend: 80)

      result = described_class.new(user, range_key: "today").call
      expect(result[:current][:new_customer_cpa]).to be_nil
    end

    it "exposes new_customer_orders so the view can render context" do
      create(:shopify_daily_metric, shopify_store: store, date: Date.current, orders_count: 10, new_customer_orders_count: 4, revenue: 500)

      result = described_class.new(user, range_key: "today").call
      expect(result[:current][:new_customer_orders]).to eq(4)
    end

    it "computes previous-period CPA against the previous range" do
      create(:shopify_daily_metric, shopify_store: store, date: Date.current, orders_count: 10, new_customer_orders_count: 4, revenue: 500)
      create(:ad_daily_metric, ad_account: ad_account, date: Date.current, spend: 50)
      create(:shopify_daily_metric, shopify_store: store, date: Date.yesterday, orders_count: 5, new_customer_orders_count: 2, revenue: 250)
      create(:ad_daily_metric, ad_account: ad_account, date: Date.yesterday, spend: 100)

      result = described_class.new(user, range_key: "today").call
      expect(result[:current][:cpa]).to eq(5.0)
      expect(result[:previous][:cpa]).to eq(20.0)
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/services/dashboard_metrics_service_spec.rb -e "CPA"`
Expected: 7 failures (`:cpa`, `:new_customer_cpa`, `:new_customer_orders` are absent from result).

- [ ] **Step 3: Update the service**

Replace `aggregate_metrics` in `app/services/dashboard_metrics_service.rb`:

```ruby
  def aggregate_metrics(range)
    shopify = ShopifyDailyMetric.for_date_range(range)
    ad = AdDailyMetric.for_date_range(range)

    if @scope.respond_to?(:shopify_stores)
      shopify = shopify.where(shopify_store_id: @scope.shopify_stores.select(:id))
    end
    if @scope.respond_to?(:ad_accounts)
      ad = ad.where(ad_account_id: @scope.ad_accounts.select(:id))
    end

    sessions = shopify.sum(:sessions)
    orders = shopify.sum(:orders_count)
    new_customer_orders = shopify.sum(:new_customer_orders_count)
    revenue = shopify.sum(:revenue)
    ad_spend = ad.sum(:spend)

    {
      sessions: sessions,
      orders: orders,
      new_customer_orders: new_customer_orders,
      revenue: revenue,
      avg_order_value: orders > 0 ? (revenue / orders).round(2) : 0,
      conversion_rate: sessions > 0 ? (orders.to_f / sessions * 100).round(2) : 0,
      ad_spend: ad_spend,
      roas: ad_spend > 0 ? (revenue / ad_spend).round(2) : 0,
      cpa: (orders > 0 && ad_spend > 0) ? (ad_spend / orders).round(2) : nil,
      new_customer_cpa: (new_customer_orders > 0 && ad_spend > 0) ? (ad_spend / new_customer_orders).round(2) : nil
    }
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/services/dashboard_metrics_service_spec.rb`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add app/services/dashboard_metrics_service.rb spec/services/dashboard_metrics_service_spec.rb
git commit -m "feat: compute CPA and new-customer CPA in dashboard metrics service"
```

---

## Task 6: View — render two CPA cards + grid layout change

**Files:**
- Modify: `app/views/dashboard/show.html.erb`
- Modify: `app/views/dashboard/_metric_card.html.erb`
- Modify: `config/locales/en.yml`
- Modify: `config/locales/zh-TW.yml`
- Modify: `config/locales/zh-CN.yml`
- Test: `spec/requests/dashboard_spec.rb`

- [ ] **Step 1: Add i18n keys**

In `config/locales/en.yml`, replace the dashboard section's `roas: "ROAS"` line and the line that follows it. Old:

```yml
    ad_spend: "Ad Spend"
    roas: "ROAS"
    apply: "Apply"
```

New:

```yml
    ad_spend: "Ad Spend"
    roas: "ROAS"
    cpa: "CPA"
    new_customer_cpa: "New Customer CPA"
    apply: "Apply"
```

In `config/locales/zh-TW.yml`, same insertion point:

```yml
    ad_spend: "廣告花費"
    roas: "ROAS"
    cpa: "獲客成本"
    new_customer_cpa: "新客獲客成本"
    apply: "查詢"
```

In `config/locales/zh-CN.yml`:

```yml
    ad_spend: "广告花费"
    roas: "ROAS"
    cpa: "获客成本"
    new_customer_cpa: "新客获客成本"
    apply: "查询"
```

- [ ] **Step 2: Write failing request spec**

Append to `spec/requests/dashboard_spec.rb` inside the `describe "GET / (authenticated root)" do` block (before its closing `end`):

```ruby
    it "displays CPA and new customer CPA card titles" do
      sign_in user
      get authenticated_root_path
      expect(response.body).to include(I18n.t("dashboard.cpa"))
      expect(response.body).to include(I18n.t("dashboard.new_customer_cpa"))
    end

    it "renders em-dash placeholder when CPA cannot be computed" do
      store = create(:shopify_store, user: user)
      create(:shopify_daily_metric, shopify_store: store, date: Date.current, orders_count: 0, new_customer_orders_count: 0, revenue: 0)

      sign_in user
      get authenticated_root_path(range: "today")
      expect(response.body).to include("—")
    end

    it "renders a currency-formatted CPA when data is present" do
      store = create(:shopify_store, user: user)
      ad_account = create(:ad_account, user: user)
      create(:shopify_daily_metric, shopify_store: store, date: Date.current, orders_count: 10, new_customer_orders_count: 4, revenue: 500)
      create(:ad_daily_metric, ad_account: ad_account, date: Date.current, spend: 50)

      sign_in user
      get authenticated_root_path(range: "today")
      expect(response.body).to include("$5.00") # 50 / 10 = 5.00
      expect(response.body).to include("$12.50") # 50 / 4 = 12.50
    end
```

- [ ] **Step 3: Run request spec to verify failure**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb -e "CPA"`
Expected: 3 failures (i18n already exists but view does not yet render the cards or `—` correctly).

- [ ] **Step 4: Update the metric card partial to guard nil current_raw**

In `app/views/dashboard/_metric_card.html.erb`, change line 6 from:

```erb
    <% if previous && previous != 0 %>
```

to:

```erb
    <% if previous && previous != 0 && current_raw %>
```

- [ ] **Step 5: Update the dashboard view**

In `app/views/dashboard/show.html.erb`:

Change the grid class on line 50 from `lg:grid-cols-5` to `lg:grid-cols-4`:

```erb
    <div class="grid grid-cols-2 lg:grid-cols-4 gap-4">
```

After the ROAS card (currently ends at line 85), and before the closing `</div>` on line 86, insert:

```erb

      <%# CPA %>
      <%= render "dashboard/metric_card",
          title: t("dashboard.cpa"),
          value: @metrics[:current][:cpa] ? number_to_currency(@metrics[:current][:cpa]) : "—",
          previous: @metrics[:previous][:cpa],
          current_raw: @metrics[:current][:cpa],
          invert_color: true %>

      <%# New Customer CPA %>
      <%= render "dashboard/metric_card",
          title: t("dashboard.new_customer_cpa"),
          value: @metrics[:current][:new_customer_cpa] ? number_to_currency(@metrics[:current][:new_customer_cpa]) : "—",
          previous: @metrics[:previous][:new_customer_cpa],
          current_raw: @metrics[:current][:new_customer_cpa],
          invert_color: true %>
```

- [ ] **Step 6: Run dashboard request spec to verify pass**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb`
Expected: all green.

- [ ] **Step 7: Run full request suite quickly to catch regressions**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb spec/services/dashboard_metrics_service_spec.rb`
Expected: all green.

- [ ] **Step 8: Commit**

```bash
git add app/views/dashboard/show.html.erb app/views/dashboard/_metric_card.html.erb \
        config/locales/en.yml config/locales/zh-TW.yml config/locales/zh-CN.yml \
        spec/requests/dashboard_spec.rb
git commit -m "feat: render CPA and new customer CPA cards on dashboard"
```

---

## Task 7: Backfill rake task

**Files:**
- Create: `lib/tasks/shopify_backfill.rake`
- Test: `spec/lib/tasks/shopify_backfill_spec.rb`

- [ ] **Step 1: Create the spec directory and write failing spec**

Run: `mkdir -p spec/lib/tasks`

Create `spec/lib/tasks/shopify_backfill_spec.rb`:

```ruby
require "rails_helper"
require "rake"

RSpec.describe "shopify:backfill_new_customer_orders", type: :task do
  before(:all) do
    Rake.application.rake_require("tasks/shopify_backfill", [ Rails.root.join("lib").to_s ])
    Rake::Task.define_task(:environment)
  end

  let(:task) { Rake::Task["shopify:backfill_new_customer_orders"] }

  before { task.reenable }

  it "calls sync_date on each active store for each date in the window" do
    store_a = create(:shopify_store, shop_domain: "a.myshopify.com")
    store_b = create(:shopify_store, shop_domain: "b.myshopify.com")

    instance_a = instance_double(ShopifyAnalyticsService)
    instance_b = instance_double(ShopifyAnalyticsService)
    allow(ShopifyAnalyticsService).to receive(:new).with(hash_including(store_id: store_a.id)).and_return(instance_a)
    allow(ShopifyAnalyticsService).to receive(:new).with(hash_including(store_id: store_b.id)).and_return(instance_b)
    expect(instance_a).to receive(:sync_date).exactly(3).times
    expect(instance_b).to receive(:sync_date).exactly(3).times

    task.invoke("3")
  end

  it "defaults to 90 days when no argument is passed" do
    store = create(:shopify_store)
    instance = instance_double(ShopifyAnalyticsService)
    allow(ShopifyAnalyticsService).to receive(:new).and_return(instance)
    expect(instance).to receive(:sync_date).exactly(90).times

    task.invoke
  end

  it "continues to the next iteration when one sync raises" do
    store = create(:shopify_store)
    instance = instance_double(ShopifyAnalyticsService)
    allow(ShopifyAnalyticsService).to receive(:new).and_return(instance)
    allow(instance).to receive(:sync_date).and_raise(StandardError, "boom")

    expect { task.invoke("2") }.not_to raise_error
  end
end
```

Note: `instance_double` and `allow`/`expect(...).to receive` for the rake task are acceptable here because the rake task is a thin orchestration shell — the underlying `ShopifyAnalyticsService` is exercised by its own real-DB tests in Task 4. The project rule is "tests must hit real database"; mocking the HTTP boundary keeps the DB real.

- [ ] **Step 2: Run the spec to verify failure**

Run: `bundle exec rspec spec/lib/tasks/shopify_backfill_spec.rb`
Expected: failure — `LoadError`/`Don't know how to build task 'shopify:backfill_new_customer_orders'`.

- [ ] **Step 3: Create the rake task**

Create `lib/tasks/shopify_backfill.rake`:

```ruby
namespace :shopify do
  desc "Backfill new_customer_orders_count by re-running ShopifyAnalyticsService#sync_date for the past N days (default 90)"
  task :backfill_new_customer_orders, [ :days ] => :environment do |_, args|
    days = (args[:days] || "90").to_i
    window = (Date.current - (days - 1).days)..Date.current

    ShopifyStore.find_each do |store|
      service = ShopifyAnalyticsService.new(
        shop_domain: store.shop_domain,
        access_token: store.access_token,
        store_id: store.id,
        timezone: store.try(:timezone) || "UTC"
      )

      window.each do |date|
        begin
          service.sync_date(date)
          Rails.logger.info("[backfill] store=#{store.shop_domain} date=#{date} ok")
        rescue => e
          Rails.logger.error("[backfill] store=#{store.shop_domain} date=#{date} error=#{e.message}")
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the spec to verify pass**

Run: `bundle exec rspec spec/lib/tasks/shopify_backfill_spec.rb`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add lib/tasks/shopify_backfill.rake spec/lib/tasks/shopify_backfill_spec.rb
git commit -m "feat: add rake task to backfill new_customer_orders_count for past N days"
```

---

## Task 8: Full-suite verification

**Files:** none modified.

- [ ] **Step 1: Run linter**

Run: `bin/rubocop`
Expected: no offenses. If any appear, run `bin/rubocop -a` and review the diff, then commit fixes with message `style: rubocop autocorrect`.

- [ ] **Step 2: Run security scan**

Run: `bin/brakeman --no-pager -q`
Expected: no new warnings.

- [ ] **Step 3: Run full RSpec**

Run: `bundle exec rspec`
Expected: all green. Investigate any failure — the changes are additive and other tests should not be impacted.

- [ ] **Step 4: Spot-check coverage**

Run: `COVERAGE=true bundle exec rspec spec/models/shopify_daily_metric_spec.rb spec/services/shopify_analytics_service_spec.rb spec/services/dashboard_metrics_service_spec.rb spec/requests/dashboard_spec.rb spec/lib/tasks/shopify_backfill_spec.rb`
Expected: coverage stays ≥ 95% per project rule. If simplecov isn't wired, skip and rely on full-suite green.

- [ ] **Step 5: Manual browser smoke test**

Start the server: `bin/dev`

Visit `http://localhost:3000/`. Sign in. Verify:
1. Dashboard renders 7 metric cards in 2 rows on a wide viewport.
2. The two new cards titled "CPA" and "New Customer CPA" appear.
3. Without data, both show `—`.
4. With seeded data (use `bin/rails console` to create a `:shopify_daily_metric` + `:ad_daily_metric` for today), the cards show currency-formatted values and the delta badge.

Stop the server: Ctrl-C.

- [ ] **Step 6: Push and open PR**

```bash
git push -u origin feature/dashboard-cpa-metric
gh pr create --base staging --title "feat: add CPA and new customer CPA to dashboard" --body "$(cat <<'EOF'
## Summary
- Snapshot Shopify `customer.numberOfOrders == 1` into `shopify_daily_metrics.new_customer_orders_count` at daily sync time
- Add CPA (Ad Spend / Orders) and New Customer CPA (Ad Spend / New Customer Orders) cards to the dashboard, with previous-period deltas and `invert_color`
- Rake task `shopify:backfill_new_customer_orders[90]` to backfill historical days after deploy
- Grid layout `lg:grid-cols-5` → `lg:grid-cols-4` to fit 7 cards in two rows

## Test plan
- [ ] CI green (Brakeman, RuboCop, RSpec)
- [ ] On staging, run `rake "shopify:backfill_new_customer_orders[90]"` once after deploy
- [ ] Verify dashboard renders both cards with realistic data
EOF
)"
```

Expected: PR opened against `staging`. Capture the URL in chat for the operator.

---

## Post-merge operational notes

After staging deploy, operator runs:

```bash
bundle exec rake "shopify:backfill_new_customer_orders[90]"
```

The task is idempotent. Re-running is safe.

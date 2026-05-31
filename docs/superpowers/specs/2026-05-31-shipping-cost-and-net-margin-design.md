# Shipping Cost + Accurate Net Margin Dashboard — Design

**Date**: 2026-05-31
**Status**: Draft for review
**Branch**: `feature/shipping-cost-dashboard-design`

## Goal

Today's dashboard reports gross profit as `revenue − COGS`, but doesn't include shipping cost. For a Chinese-mainland-sourced e-commerce business shipping internationally, shipping is a meaningful part of margin (often 10-30% of revenue). The dashboard's net margin needs to factor it in.

We're keeping ad attribution as today (aggregate ad spend ÷ orders); the goal of this spec is purely to add shipping cost into the cost stack.

## Decisions captured during brainstorming

| Decision | Choice |
|---|---|
| Shipping cost source | Estimated from `weight_kg × per-kg rate + flat fee`, looked up against a rate-card table per country × service type × weight band × effective date |
| Service type selection | Per shop: `shopify_stores.default_service_type`. All orders from a store use that one service. |
| Rate card scope | Company-level (`companies.id` FK) so multi-store companies share rate cards |
| Rate card maintenance | Admin UI with **direct in-page editing**: new-row form at top, inline click-to-edit cells per row, per-row delete |
| Currency | Rate cards stored in CNY; sync converts to store currency at order sync time using `shopify_stores.cost_fx_rate` |
| Frozen snapshot | `orders.estimated_shipping_cost` is frozen at sync time (same snapshot semantics as `unit_cost_snapshot`); editing rate cards does NOT retroactively change historical orders |
| Versioning | Rate cards come in **named versions**. A version is `(country, service, name, effective_from, effective_to)` and owns many weight-band rates. When estimating cost for an order, the calculator picks the newest version whose `effective_from <= order_date` (and `effective_to` is null or >= order_date). Names make audit / change tracking possible (e.g. "Q4 2025 US Battery Rates"). |
| Estimated vs actual | This spec covers **estimated** shipping cost only (computed from rate cards). A separate future spec will add **actual** shipping cost imported from carrier invoice CSVs. Schema reserves both columns so the future work doesn't reshape this one. The dashboard picks `actual` when present and falls back to `estimated`. |
| Ad attribution | **No change**: still aggregate `ad_spend / orders` in the existing dashboard |

## Schema

Two tables: a **version** is one rate update for a country × service combo (carries name and effective dates), and a **rate** is a single weight band inside a version.

### New table `shipping_rate_card_versions`

```ruby
create_table :shipping_rate_card_versions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
  t.uuid    :company_id, null: false
  t.string  :name, null: false                  # e.g., "Q4 2025 US Battery Rates"
  t.string  :country_code, null: false          # ISO-3166-1 alpha-2, e.g., "US", "CA", "GB"
  t.string  :service_type, null: false          # admin-defined string, e.g., "standard_with_battery"
  t.date    :effective_from, null: false
  t.date    :effective_to                       # nullable; null = "until superseded"
  t.timestamps
end
add_index :shipping_rate_card_versions,
          [:company_id, :country_code, :service_type, :effective_from],
          name: "idx_rate_versions_lookup"
add_foreign_key :shipping_rate_card_versions, :companies
```

### New table `shipping_rate_card_rates`

```ruby
create_table :shipping_rate_card_rates, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
  t.uuid    :version_id, null: false
  t.decimal :weight_min_kg,   precision: 8,  scale: 3, null: false
  t.decimal :weight_max_kg,   precision: 8,  scale: 3, null: false
  t.decimal :per_kg_rate_cny, precision: 10, scale: 2, null: false
  t.decimal :flat_fee_cny,    precision: 10, scale: 2, default: 0, null: false
  t.timestamps
end
add_index :shipping_rate_card_rates, :version_id
add_foreign_key :shipping_rate_card_rates, :shipping_rate_card_versions, column: :version_id
```

### `shopify_stores` additions

```ruby
add_column :shopify_stores, :default_service_type, :string
```

### `orders` additions

```ruby
add_column :orders, :estimated_shipping_cost, :decimal, precision: 10, scale: 2
add_column :orders, :actual_shipping_cost,    :decimal, precision: 10, scale: 2
```

- `estimated_shipping_cost` is set by `ShippingCostCalculator` at sync time (frozen once set).
- `actual_shipping_cost` is reserved for a future CSV importer that ingests carrier-reported per-shipment costs. This spec does NOT populate it.

### Band semantics — important

The source spreadsheets use intervals `min < W ≤ max` (e.g., `0.05 < W ≤ 0.2`, then `0.201 < W ≤ 0.45`). We store `weight_min_kg = 0.05`, `weight_max_kg = 0.2`, and lookup uses `weight_min_kg < W AND weight_max_kg >= W`. Same semantics — bands cleanly tile by 0.001 kg gaps.

### Version fallback semantics

If no version explicitly covers an order's date, we **fall back to the most recent past version**. Example:

- Version A: name "Q1 2026 US Battery", `effective_from = 2026-03-22`, `effective_to = nil`
- Today's order date: 2026-04-15 → picks Version A
- Admin adds Version B: name "Q2 2026 US Battery", `effective_from = 2026-05-01`, `effective_to = nil`
- Order on 2026-04-15 still picks A; order on 2026-05-10 picks B

This means admins don't need to backfill `effective_to` on the old version when adding a new one — the lookup orders by `effective_from DESC` and just takes the first one that's already active.

If the admin DOES set `effective_to`, the version stops applying after that date.

No DB-level uniqueness/overlap constraint — admins can technically create overlapping versions; the lookup picks newest `effective_from` to break ties.

## Models

```ruby
class ShippingRateCardVersion < ApplicationRecord
  belongs_to :company
  has_many :rates, class_name: "ShippingRateCardRate", foreign_key: :version_id, dependent: :destroy

  validates :name, :country_code, :service_type, :effective_from, presence: true
  validate  :effective_to_after_from

  scope :for_lookup, ->(country:, service_type:, on_date:) {
    where(country_code: country, service_type: service_type)
      .where("effective_from <= ?", on_date)
      .where("effective_to IS NULL OR effective_to >= ?", on_date)
      .order(effective_from: :desc)
  }

  def self.lookup(company:, country:, service_type:, on_date:)
    where(company_id: company.id)
      .for_lookup(country: country, service_type: service_type, on_date: on_date)
      .first
  end

  private

  def effective_to_after_from
    return unless effective_from && effective_to
    errors.add(:effective_to, "must be on or after effective_from") if effective_to < effective_from
  end
end

class ShippingRateCardRate < ApplicationRecord
  belongs_to :version, class_name: "ShippingRateCardVersion", foreign_key: :version_id, inverse_of: :rates
  has_one :company, through: :version

  validates :weight_min_kg,   presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :weight_max_kg,   presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :per_kg_rate_cny, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :flat_fee_cny,    presence: true, numericality: { greater_than_or_equal_to: 0 }
  validate  :weight_max_greater_than_min

  scope :for_weight, ->(kg) {
    where("weight_min_kg < ? AND weight_max_kg >= ?", kg, kg)
  }

  private

  def weight_max_greater_than_min
    return unless weight_min_kg && weight_max_kg
    errors.add(:weight_max_kg, "must be greater than weight_min_kg") if weight_max_kg <= weight_min_kg
  end
end
```

Extension to existing models:

```ruby
class Order
  # existing: total_price, cogs_total, gross_profit, ...

  # Prefer real carrier-reported cost when available; fall back to our estimate.
  def effective_shipping_cost
    actual_shipping_cost || estimated_shipping_cost
  end

  def net_profit_per_order
    return nil unless total_price
    total_price - cogs_total - (effective_shipping_cost || 0)
  end

  def shipping_complete?
    effective_shipping_cost.present?
  end

  def shipping_is_actual?
    actual_shipping_cost.present?
  end
end

class Company
  has_many :shipping_rate_cards, dependent: :destroy
end
```

## Services

### `ShippingCostCalculator` (new)

Pure function. Takes an Order, returns the estimated shipping cost in store currency, or `nil` if any input is missing.

```ruby
class ShippingCostCalculator
  def self.estimate(order)
    new(order).call
  end

  def initialize(order)
    @order = order
    @store = order.shopify_store
  end

  def call
    return nil unless @store.cost_fx_rate&.positive?
    return nil unless @store.default_service_type.present?

    country = country_code_from_order
    return nil unless country

    weight_kg = total_weight_kg
    return nil if weight_kg <= 0

    version = ShippingRateCardVersion.lookup(
      company:      @store.company,
      country:      country,
      service_type: @store.default_service_type,
      on_date:      @order.ordered_at.to_date
    )
    return nil unless version

    rate = version.rates.for_weight(weight_kg).first
    return nil unless rate

    cost_cny = (weight_kg * rate.per_kg_rate_cny) + rate.flat_fee_cny
    (cost_cny / @store.cost_fx_rate).round(2)
  end

  private

  def country_code_from_order
    @order.shopify_data&.dig("shipping_address", "country_code") ||
      @order.shopify_data&.dig("billing_address", "country_code")
  end

  def total_weight_kg
    @order.order_line_items.includes(:product_variant).sum do |li|
      ((li.product_variant&.weight_grams || 0) * li.quantity)
    end / 1000.0
  end
end
```

### `SyncAllOrdersService` modification

After `sync_line_items`, before `sync_fulfillments`, call a small helper that snapshots **estimated** shipping cost. Frozen once set. (Actual shipping cost is filled by the future CSV importer, on a separate column.)

```ruby
sync_line_items(order, shopify_order)
sync_estimated_shipping_cost(order)   # NEW
sync_fulfillments(order, shopify_order)
# ...

def sync_estimated_shipping_cost(order)
  return if order.estimated_shipping_cost.present?  # frozen once set
  cost = ShippingCostCalculator.estimate(order)
  order.update!(estimated_shipping_cost: cost) if cost
end
```

### `BackfillOrderLineItemsService` extension

Extended to also fill `orders.estimated_shipping_cost` for historical orders (only if currently null). Same idempotency semantics. Does NOT touch `actual_shipping_cost`.

```ruby
def call
  Rails.logger.info("[BackfillLineItems] start store=#{@store.shop_domain}")
  @store.orders.find_each(batch_size: 200) do |order|
    (order.shopify_data&.dig("line_items") || []).each { |li| upsert_line_item(order, li) }
    backfill_estimated_shipping(order)                              # NEW
    @processed += 1
  end
  Rails.logger.info("[BackfillLineItems] done orders=#{@processed} snapshotted=#{@snapshotted} shipping=#{@shipping_filled}")
  { orders: @processed, snapshotted: @snapshotted, shipping_filled: @shipping_filled }
end

private

def backfill_estimated_shipping(order)
  return if order.estimated_shipping_cost.present?
  cost = ShippingCostCalculator.estimate(order)
  return unless cost
  order.update!(estimated_shipping_cost: cost)
  @shipping_filled += 1
end
```

## Routes

```ruby
resources :shipping_rate_card_versions, only: [:index, :create, :update, :destroy] do
  resources :rates, only: [:create, :update, :destroy],
            controller: "shipping_rate_card_rates"
end
```

Versions own their weight-band rates as a nested resource. No `:new` / `:edit` — both happen on the index page (inline new-version + new-rate forms, click-to-edit cells).

## Controllers

### `ShippingRateCardVersionsController` (new)

```ruby
class ShippingRateCardVersionsController < AdminController
  before_action :require_owner!, only: [:create, :update, :destroy]
  before_action :set_version, only: [:update, :destroy]

  def index
    versions = current_company.shipping_rate_card_versions.includes(:rates)
    @countries = versions.distinct.pluck(:country_code).sort
    @services  = versions.distinct.pluck(:service_type).sort

    versions = versions.where(country_code: params[:country_code]) if params[:country_code].present?
    versions = versions.where(service_type: params[:service_type]) if params[:service_type].present?

    @selected_country = params[:country_code]
    @selected_service = params[:service_type]
    @versions = versions.order(country_code: :asc, service_type: :asc, effective_from: :desc)
  end

  def create
    version = current_company.shipping_rate_card_versions.new(version_params)
    if version.save
      redirect_to shipping_rate_card_versions_path, notice: t("shipping_rate_cards.version_created")
    else
      redirect_to shipping_rate_card_versions_path, alert: version.errors.full_messages.join(", ")
    end
  end

  def update
    if @version.update(version_params)
      respond_to do |format|
        format.turbo_stream  # replaces the version's header row
        format.html { redirect_to shipping_rate_card_versions_path, notice: t("shipping_rate_cards.version_updated") }
      end
    else
      respond_to do |format|
        format.turbo_stream { render :update, status: :unprocessable_entity }
        format.html { redirect_to shipping_rate_card_versions_path, alert: @version.errors.full_messages.join(", ") }
      end
    end
  end

  def destroy
    @version.destroy
    redirect_to shipping_rate_card_versions_path, notice: t("shipping_rate_cards.version_deleted")
  end

  private

  def set_version
    @version = current_company.shipping_rate_card_versions.find(params[:id])
  end

  def version_params
    params.require(:shipping_rate_card_version).permit(
      :name, :country_code, :service_type, :effective_from, :effective_to
    )
  end

  def require_owner!
    redirect_to(shipping_rate_card_versions_path, alert: t("companies.no_permission")) unless current_membership&.owner?
  end
end
```

### `ShippingRateCardRatesController` (new)

Nested. Each action affects one weight-band row inside a specific version.

```ruby
class ShippingRateCardRatesController < AdminController
  before_action :require_owner!
  before_action :set_version
  before_action :set_rate, only: [:update, :destroy]

  def create
    rate = @version.rates.new(rate_params)
    if rate.save
      redirect_to shipping_rate_card_versions_path, notice: t("shipping_rate_cards.rate_created")
    else
      redirect_to shipping_rate_card_versions_path, alert: rate.errors.full_messages.join(", ")
    end
  end

  def update
    if @rate.update(rate_params)
      respond_to do |format|
        format.turbo_stream  # replaces the single weight-band row
        format.html { redirect_to shipping_rate_card_versions_path, notice: t("shipping_rate_cards.rate_updated") }
      end
    else
      respond_to do |format|
        format.turbo_stream { render :update, status: :unprocessable_entity }
        format.html { redirect_to shipping_rate_card_versions_path, alert: @rate.errors.full_messages.join(", ") }
      end
    end
  end

  def destroy
    @rate.destroy
    redirect_to shipping_rate_card_versions_path, notice: t("shipping_rate_cards.rate_deleted")
  end

  private

  def set_version
    @version = current_company.shipping_rate_card_versions.find(params[:shipping_rate_card_version_id])
  end

  def set_rate
    @rate = @version.rates.find(params[:id])
  end

  def rate_params
    params.require(:shipping_rate_card_rate).permit(:weight_min_kg, :weight_max_kg, :per_kg_rate_cny, :flat_fee_cny)
  end

  def require_owner!
    redirect_to(shipping_rate_card_versions_path, alert: t("companies.no_permission")) unless current_membership&.owner?
  end
end
```

### `ShopifyStoresController` modification

Add a new branch in `update` for `default_service_type` (owner-only, mirrors the FX rate branch added in PR #135):

```ruby
if params[:shopify_store].is_a?(ActionController::Parameters) && params[:shopify_store].key?(:default_service_type)
  return redirect_to(shopify_store_path(@shopify_store), alert: t("companies.no_permission")) unless current_membership&.owner?

  if @shopify_store.update(shopify_store_service_params)
    redirect_to shopify_store_path(@shopify_store), notice: t("shopify_stores.service_type_updated")
  else
    redirect_to shopify_store_path(@shopify_store), alert: @shopify_store.errors.full_messages.join(", ")
  end
  return
end
```

```ruby
def shopify_store_service_params
  params.require(:shopify_store).permit(:default_service_type)
end
```

### Authorization mapping

`AdminController::PERMISSION_KEY_MAP` gains two entries:

```ruby
"shipping_rate_card_versions" => "shopify_stores",
"shipping_rate_card_rates"    => "shopify_stores"
```

Anyone with `shopify_stores` access can VIEW the page; mutating actions (create / update / destroy) are gated to owner inside each controller.

## UI

### Shop detail page additions

Below the existing "Cost FX rate" section, owner-only block for service type:

```
Default shipping service type
Used when estimating shipping cost for orders from this store.
[ standard_with_battery ▾ ]   (dropdown filled from rate cards' distinct service_types)  [ Save ]
```

Non-owners see the chosen service as read-only text.

### Shipping rate cards page (`/shipping_rate_card_versions`)

Each VERSION is a card. Inside each card is its weight-band rate table. New versions and new rates within a version are both added inline.

```
Shipping Rate Cards (Versions)

Filter:  Country [All ▾]    Service [All ▾]

┌──────────────────────── New version (owner only) ─────────────────────────────────────┐
│ Name: [Q1 2026 US Battery_______________]                                             │
│ Country: [US]  Service: [standard_with_battery]                                       │
│ Effective from: [2026-03-22]    Until: [        ] (blank = "until superseded")        │
│                                                                  [+ Create version]   │
└────────────────────────────────────────────────────────────────────────────────────────┘

┌─ Version: [Q1 2026 US Battery]  ·  [US] [standard_with_battery]  ·  [2026-03-22] → [—] · 🗑 ┐
│                                                                                              │
│   ┌──────────┬──────────┬─────────┬─────────┬───┐                                            │
│   │ Min kg   │ Max kg   │ ¥/kg    │ ¥/pkg   │   │                                            │
│   ├──────────┼──────────┼─────────┼─────────┼───┤                                            │
│   │ [0.05]   │ [0.200]  │ [92.00] │ [25.00] │ 🗑 │                                            │
│   │ [0.201]  │ [0.450]  │ [92.00] │ [23.00] │ 🗑 │                                            │
│   │ [0.451]  │ [0.700]  │ [92.00] │ [22.00] │ 🗑 │                                            │
│   │   ... add new band: [____] – [____]  ¥/kg [_____]  ¥/pkg [_____]   [+ Add band]          │
│   └──────────┴──────────┴─────────┴─────────┴───┘                                            │
└──────────────────────────────────────────────────────────────────────────────────────────────┘

┌─ Version: [Q4 2025 US Battery]  ·  [US] [standard_with_battery]  ·  [2025-12-29] → [2026-03-21] · 🗑 ┐
│ ...                                                                                                   │
└────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

**Version header row** (name, country, service, dates): each cell uses `cell_edit_controller.js` → click to edit → blur/Enter saves via `PATCH /shipping_rate_card_versions/:id`.

**Rate band row** (min, max, per_kg, flat_fee): same `cell_edit_controller.js` pattern → `PATCH /shipping_rate_card_versions/:version_id/rates/:id`.

The controller is extended to support three input types:
- `number` (existing) — for weight_min/max, per_kg, flat_fee
- `text` — for name, country_code, service_type
- `date` — for effective_from, effective_to (blank input means null)

New-version form and new-band form are regular `form_with` POSTs, owner-only.

Non-owners see read-only — no edit, no add, no delete buttons.

### Dashboard cards

Add to the existing grid:

| Card | Value | Notes |
|---|---|---|
| **Shipping Cost** | `number_to_currency(@metrics[:current][:shipping_cost])` | new; invert color (higher = worse). Uses `effective_shipping_cost` (actual ∥ estimated). |
| **Net Profit** | revised: `revenue − cogs − effective_shipping − ad_spend` | already exists; formula change |
| **Net Margin** | revised: `net_profit / revenue * 100` | already exists; formula change |

Coverage indicator below grid (extend existing `cogs_coverage` line):

```
COGS coverage: 92.3%   ·   Shipping coverage: 86.5%  (actual: 12.0% · estimated: 74.5%)
```

`shipping_coverage_pct` = `count(orders with effective_shipping_cost) / count(orders in range)`.

Optional breakdown numbers:
- `shipping_coverage_actual_pct` = orders with `actual_shipping_cost` / total
- `shipping_coverage_estimated_pct` = orders with `estimated_shipping_cost` only (no actual) / total

This way as the future CSV importer adds actuals, the dashboard transparently shows the data-quality shift from "all estimates" to "actuals".

## Dashboard service extension

`DashboardMetricsService.aggregate_metrics` adds:

```ruby
shipping_total, shipping_breakdown = aggregate_shipping(store_scope, range)
net_profit = revenue - cogs - shipping_total - ad_spend

{
  # existing keys...
  shipping_cost:                  shipping_total,
  shipping_coverage_pct:          shipping_breakdown[:coverage],
  shipping_coverage_actual_pct:   shipping_breakdown[:actual],
  shipping_coverage_estimated_pct:shipping_breakdown[:estimated_only],
  net_profit:                     net_profit,
  net_margin_pct:                 revenue > 0 ? (net_profit / revenue * 100).round(2) : nil
}

def aggregate_shipping(store_scope, range)
  total = BigDecimal("0")
  count_total = 0
  count_actual = 0
  count_estimated_only = 0

  store_scope.find_each do |store|
    tz = store.active_timezone
    start_utc = tz.local(range.first.year, range.first.month, range.first.day).utc
    end_utc   = tz.local(range.last.year,  range.last.month,  range.last.day).end_of_day.utc

    orders = Order.where(shopify_store_id: store.id, ordered_at: start_utc..end_utc)

    # Prefer actual; fall back to estimated. SQL: COALESCE(actual, estimated, 0)
    total += orders.sum("COALESCE(actual_shipping_cost, estimated_shipping_cost, 0)")
    count_total          += orders.count
    count_actual         += orders.where.not(actual_shipping_cost: nil).count
    count_estimated_only += orders.where(actual_shipping_cost: nil).where.not(estimated_shipping_cost: nil).count
  end

  pct = ->(n) { count_total > 0 ? (n.to_f / count_total * 100).round(1) : nil }
  [
    total,
    {
      coverage:       pct.call(count_actual + count_estimated_only),
      actual:         pct.call(count_actual),
      estimated_only: pct.call(count_estimated_only)
    }
  ]
end
```

## I18n keys (en / zh-TW / zh-CN)

```yaml
shipping_rate_cards:
  title: "Shipping Rate Cards"
  filter_country: "Country"
  filter_service: "Service"
  filter_all: "All"
  new_version_title: "New version"
  create_version: "+ Create version"
  add_band: "+ Add band"
  version_created: "Version created"
  version_updated: "Version updated"
  version_deleted: "Version deleted"
  rate_created: "Rate band added"
  rate_updated: "Rate band updated"
  rate_deleted: "Rate band deleted"
  empty: "No rate card versions yet — create one above"
  columns:
    name: "Name"
    country: "Country"
    service: "Service"
    weight_min: "Min kg"
    weight_max: "Max kg"
    per_kg: "¥/kg"
    flat_fee: "¥/pkg"
    effective_from: "From"
    effective_to: "Until"
shopify_stores:
  default_service_type: "Default shipping service type"
  default_service_hint: "Used when estimating shipping cost for orders from this store"
  service_type_updated: "Default service type updated"
  service_type_owner_only: "(Only owners can change this)"
dashboard:
  shipping_cost: "Shipping cost"
  shipping_coverage: "Shipping coverage"
```

## Data entry workflow

Admins create a **version** first, then add weight-band **rates** inside it.

- Version `name`: free text (`Q4 2025 US Battery`, `2026-Mar Yanwen Cosmetics`, etc.)
- `country_code`: uppercase ISO-3166-1 alpha-2 (`US`, `CA`, `GB`)
- `service_type`: admin-defined string (`standard_with_battery`, `general`)
- `effective_from`: required
- `effective_to`: blank = "until superseded by a newer version"; only set explicitly if you want to deactivate a version

Typical workflow when rates change:

1. (Optional) Filter to the country + service being updated
2. Click "+ Create version" → fill name + dates → submit
3. Inside the new version's card, add weight bands one by one
4. **Don't touch the old version** — lookup automatically uses the newer version once its `effective_from` arrives

This is much easier than maintaining `effective_to` on every old row: old versions remain unchanged history, new version takes over from its start date.

## Testing

### Model specs
- `shipping_rate_card_version_spec.rb`:
  - presence validations on name / country / service / effective_from
  - `effective_to >= effective_from` (when both present)
  - `.lookup` returns the newest applicable version
  - `.lookup` falls back to most recent past version when no version explicitly contains the date
  - `.lookup` returns nil when no version covers the date
  - destroying a version cascades to its rates
- `shipping_rate_card_rate_spec.rb`:
  - presence / numericality validations
  - `weight_max > weight_min`
  - `for_weight` scope picks the right band
  - belongs to version; through to company

### Service specs
- `shipping_cost_calculator_spec.rb`:
  - happy path: USD store, 0.3 kg US order → looks up newest applicable version → correct band → returns CNY/fx_rate value
  - older version still applies when no newer version yet exists
  - newer version takes over for orders on or after its `effective_from`
  - missing variant weights → nil
  - missing country in shipping_address → falls back to billing_address; else nil
  - no version covers date → nil
  - version exists but no rate band matches the weight → nil
  - store missing `default_service_type` → nil
  - store missing `cost_fx_rate` → nil
- `sync_all_orders_service_spec.rb` extend:
  - syncs an order with weighted variants + active version → orders.estimated_shipping_cost set
  - re-sync does not overwrite existing estimated_shipping_cost
  - never touches actual_shipping_cost
- `backfill_order_line_items_service_spec.rb` extend:
  - backfill fills estimated_shipping_cost when null; counts returned
  - does not touch actual_shipping_cost

### Request specs
- `shipping_rate_card_versions_spec.rb`:
  - GET /shipping_rate_card_versions — 200, filters work, shows versions with their rates
  - POST (owner) — creates version
  - POST (non-owner) — 302 + alert, nothing created
  - PATCH (owner) — updates single field, returns Turbo Stream
  - PATCH (non-owner) — alert
  - DELETE (owner) — gone (and cascade-deletes rates)
  - DELETE (non-owner) — alert
  - Cross-company: another company's version → 404
- `shipping_rate_card_rates_spec.rb`:
  - POST nested under version (owner) — creates rate row
  - POST (non-owner) — alert
  - PATCH (owner) — returns Turbo Stream
  - DELETE (owner) — gone
  - Cross-version: trying to PATCH a rate belonging to another company's version → 404
- `shopify_stores_spec.rb` extend:
  - PATCH default_service_type (owner) — updates
  - PATCH default_service_type (non-owner) — blocked

### System spec
- `shipping_rate_cards_spec.rb` system: visit page, fill new-version form, see version card; add a rate band, click a cell, change value, blur, see updated

### Dashboard spec
- `dashboard_metrics_service_spec.rb` extend:
  - `:shipping_cost` aggregates `COALESCE(actual, estimated, 0)` over range
  - actual-only order → counted under `shipping_coverage_actual_pct`
  - estimated-only order → counted under `shipping_coverage_estimated_pct`
  - both nil → counted as missing
  - `:net_profit` = revenue - cogs - effective_shipping - ad_spend

## Architecture summary

```
Admin (owner)
  │
  ├── GET    /shipping_rate_card_versions                (versions list + filters)
  ├── POST   /shipping_rate_card_versions                (create version)
  ├── PATCH  /shipping_rate_card_versions/:id            (inline edit version header)
  ├── DELETE /shipping_rate_card_versions/:id            (delete version + cascade rates)
  ├── POST   /shipping_rate_card_versions/:vid/rates     (add weight band to a version)
  ├── PATCH  /shipping_rate_card_versions/:vid/rates/:id (inline edit rate band)
  ├── DELETE /shipping_rate_card_versions/:vid/rates/:id (delete rate band)
  │
  ├── PATCH /shopify_stores/:id with default_service_type
  │     └─ ShopifyStore#default_service_type
  │
  └── (existing) PATCH cost_fx_rate, etc.

Order sync (SyncAllOrdersService)
  └─ sync_order
       ├─ sync_line_items     (existing, snapshots COGS)
       ├─ sync_shipping_cost  (NEW)
       │    └─ ShippingCostCalculator
       │         ├─ weight from line_items × variant.weight_grams
       │         ├─ country from order.shopify_data.shipping_address
       │         ├─ ShippingRateCardVersion.lookup → newest applicable version
       │         ├─ version.rates.for_weight(kg) → matching band
       │         ├─ cost CNY / store.cost_fx_rate → store currency
       │         └─ orders.estimated_shipping_cost (frozen)
       └─ sync_fulfillments   (existing)

Backfill (BackfillOrderLineItemsService)
  └─ for each order: also runs sync_shipping_cost equivalent

DashboardMetricsService (existing, extended)
  └─ aggregate_metrics
       ├─ existing cogs / gross_profit
       ├─ shipping_cost = SUM(COALESCE(actual, estimated, 0)) in range   ← NEW
       ├─ net_profit    = revenue - cogs - shipping_cost - ad_spend      ← FORMULA CHANGE
       └─ shipping_coverage_pct (+ actual / estimated_only breakdowns)   ← NEW

Future spec (NOT in this PR):
  ImportCarrierInvoiceService
    └─ writes orders.actual_shipping_cost from a CSV of carrier-reported shipments
```

## Out of scope

- Per-product / per-variant service-type override (only store-level today)
- Multi-zone rate cards (column exists in some logistics tables; not modeled here)
- "Minimum chargeable weight" (`最低計費重`) and "weight rounding step" (`進位制`) from the logistics spreadsheets — assume `weight_kg` is used as-is and bands are `min < W ≤ max`
- Source attribution for ad spend per order (UTM / source_name) — stays aggregate
- Bulk CSV import for rate cards — admins use the new-row form (or Rails console for initial seed)
- Currency for rate cards other than CNY
- **Actual** shipping cost ingestion from carrier invoices — a separate future spec will add `ImportCarrierInvoiceService` that writes `orders.actual_shipping_cost`. This PR only reserves the column.

## Rollout / operator steps

1. Deploy migrations (2 new tables)
2. Owner: visit a shop detail page → set `default_service_type` (e.g., `standard_with_battery`)
3. Owner: visit `/shipping_rate_card_versions` → create first version (name + country + service + effective_from) → add weight bands one by one inside that version
4. New orders auto-snapshot `shipping_cost` from now on
5. In Rails console: `BackfillOrderLineItemsService.new(store).call` — also fills historical `shipping_cost`
6. When rates change: create a NEW version with a new `effective_from`. Old version stays untouched as history — calculator picks newest applicable version automatically.

For initial seeding of many rows, admin can also use Rails console to bulk-create versions + rates — the UI is the primary path but Ruby remains available for first-time setup if rate tables are large.

## Estimated work

| Section | Effort |
|---|---|
| Migrations (2 tables) + 2 models + specs | 45 min |
| Calculator service + spec (two-level lookup) | 40 min |
| Sync integration + spec | 20 min |
| Backfill extension + spec | 15 min |
| 2 controllers (versions + rates) + routes + i18n | 50 min |
| Index page UI: versions list + nested rates table + new-row forms | 60 min |
| Cell edit controller extension (text + date input types) | 30 min |
| Shop detail page service-type form | 20 min |
| Dashboard service extension + cards + spec | 30 min |
| System spec for new-version + add-band + cell edit | 30 min |
| Total | **~6 hours** |

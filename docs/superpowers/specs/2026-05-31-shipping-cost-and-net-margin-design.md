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
| Frozen snapshot | `orders.shipping_cost` is frozen at sync time (same snapshot semantics as `unit_cost_snapshot`); editing rate cards does NOT retroactively change historical orders |
| Ad attribution | **No change**: still aggregate `ad_spend / orders` in the existing dashboard |

## Schema

### New table `shipping_rate_cards`

```ruby
create_table :shipping_rate_cards, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
  t.uuid    :company_id, null: false
  t.string  :country_code, null: false          # ISO-3166-1 alpha-2, e.g., "US", "CA", "GB"
  t.string  :service_type, null: false          # admin-defined string, e.g., "standard_with_battery", "general"
  t.decimal :weight_min_kg,   precision: 8,  scale: 3, null: false
  t.decimal :weight_max_kg,   precision: 8,  scale: 3, null: false
  t.decimal :per_kg_rate_cny, precision: 10, scale: 2, null: false
  t.decimal :flat_fee_cny,    precision: 10, scale: 2, default: 0, null: false
  t.date    :effective_from, null: false
  t.date    :effective_to                       # nullable; null = still current
  t.timestamps
end
add_index :shipping_rate_cards,
          [:company_id, :country_code, :service_type, :effective_from],
          name: "idx_rate_cards_lookup"
add_foreign_key :shipping_rate_cards, :companies
```

### `shopify_stores` additions

```ruby
add_column :shopify_stores, :default_service_type, :string
```

### `orders` additions

```ruby
add_column :orders, :shipping_cost, :decimal, precision: 10, scale: 2
```

### Band semantics — important

The source spreadsheets use intervals `min < W ≤ max` (e.g., `0.05 < W ≤ 0.2`, then `0.201 < W ≤ 0.45`). We store `weight_min_kg = 0.05`, `weight_max_kg = 0.2`, and lookup uses `weight_min_kg < W AND weight_max_kg >= W`. Same semantics — bands cleanly tile by 0.001 kg gaps.

No DB-level uniqueness/overlap constraint — admins can technically create overlapping rows; the lookup returns the most-recent `effective_from` to break ties.

## Models

```ruby
class ShippingRateCard < ApplicationRecord
  belongs_to :company

  validates :country_code, :service_type, presence: true
  validates :weight_min_kg, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :weight_max_kg, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :per_kg_rate_cny, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :flat_fee_cny,    presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :effective_from, presence: true
  validate  :weight_max_greater_than_min
  validate  :effective_to_after_from

  scope :effective_on, ->(date) {
    where("effective_from <= ?", date)
      .where("effective_to IS NULL OR effective_to >= ?", date)
  }

  def self.lookup(company:, country:, service_type:, weight_kg:, on_date:)
    where(company_id: company.id, country_code: country, service_type: service_type)
      .effective_on(on_date)
      .where("weight_min_kg < ? AND weight_max_kg >= ?", weight_kg, weight_kg)
      .order(effective_from: :desc)
      .first
  end

  private

  def weight_max_greater_than_min
    return unless weight_min_kg && weight_max_kg
    errors.add(:weight_max_kg, "must be greater than weight_min_kg") if weight_max_kg <= weight_min_kg
  end

  def effective_to_after_from
    return unless effective_from && effective_to
    errors.add(:effective_to, "must be on or after effective_from") if effective_to < effective_from
  end
end
```

Extension to existing models:

```ruby
class Order
  # existing: total_price, cogs_total, gross_profit, ...

  def net_profit_per_order
    return nil unless total_price
    total_price - cogs_total - (shipping_cost || 0)
  end

  def shipping_complete?
    shipping_cost.present?
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

    rate = ShippingRateCard.lookup(
      company:      @store.company,
      country:      country,
      service_type: @store.default_service_type,
      weight_kg:    weight_kg,
      on_date:      @order.ordered_at.to_date
    )
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

After `sync_line_items`, before `sync_fulfillments`, call a small helper that snapshots shipping cost. Frozen once set.

```ruby
sync_line_items(order, shopify_order)
sync_shipping_cost(order)   # NEW
sync_fulfillments(order, shopify_order)
# ...

def sync_shipping_cost(order)
  return if order.shipping_cost.present?  # frozen once set
  cost = ShippingCostCalculator.estimate(order)
  order.update!(shipping_cost: cost) if cost
end
```

### `BackfillOrderLineItemsService` extension

Extended to also fill `orders.shipping_cost` for historical orders (only if currently null). Same idempotency semantics.

```ruby
def call
  Rails.logger.info("[BackfillLineItems] start store=#{@store.shop_domain}")
  @store.orders.find_each(batch_size: 200) do |order|
    (order.shopify_data&.dig("line_items") || []).each { |li| upsert_line_item(order, li) }
    backfill_shipping_cost(order)                                  # NEW
    @processed += 1
  end
  Rails.logger.info("[BackfillLineItems] done orders=#{@processed} snapshotted=#{@snapshotted} shipping=#{@shipping_filled}")
  { orders: @processed, snapshotted: @snapshotted, shipping_filled: @shipping_filled }
end

private

def backfill_shipping_cost(order)
  return if order.shipping_cost.present?
  cost = ShippingCostCalculator.estimate(order)
  return unless cost
  order.update!(shipping_cost: cost)
  @shipping_filled += 1
end
```

## Routes

```ruby
resources :shipping_rate_cards, only: [:index, :create, :update, :destroy]
```

Standard REST CRUD. No `:new` / `:edit` — both happen on the index page (new-row form at top, inline cell edit on existing rows).

## Controllers

### `ShippingRateCardsController` (new)

Standard CRUD. All mutating actions require owner role.

```ruby
class ShippingRateCardsController < AdminController
  before_action :require_owner!, only: [:create, :update, :destroy]
  before_action :set_card, only: [:update, :destroy]

  def index
    cards = current_company.shipping_rate_cards
    @countries = cards.distinct.pluck(:country_code).sort
    @services  = cards.distinct.pluck(:service_type).sort

    cards = cards.where(country_code: params[:country_code]) if params[:country_code].present?
    cards = cards.where(service_type: params[:service_type]) if params[:service_type].present?

    @selected_country = params[:country_code]
    @selected_service = params[:service_type]
    @cards = cards.order(:country_code, :service_type, :effective_from, :weight_min_kg)
    @new_card = current_company.shipping_rate_cards.new  # for the new-row form
  end

  def create
    card = current_company.shipping_rate_cards.new(card_params)
    if card.save
      redirect_to shipping_rate_cards_path(request.query_parameters.slice(:country_code, :service_type)),
                  notice: t("shipping_rate_cards.created")
    else
      redirect_to shipping_rate_cards_path, alert: card.errors.full_messages.join(", ")
    end
  end

  def update
    if @card.update(card_params)
      respond_to do |format|
        format.turbo_stream  # replaces the single row
        format.html { redirect_to shipping_rate_cards_path, notice: t("shipping_rate_cards.updated") }
      end
    else
      respond_to do |format|
        format.turbo_stream { render :update, status: :unprocessable_entity }
        format.html { redirect_to shipping_rate_cards_path, alert: @card.errors.full_messages.join(", ") }
      end
    end
  end

  def destroy
    @card.destroy
    redirect_to shipping_rate_cards_path, notice: t("shipping_rate_cards.deleted")
  end

  private

  def set_card
    @card = current_company.shipping_rate_cards.find(params[:id])
  end

  def card_params
    params.require(:shipping_rate_card).permit(
      :country_code, :service_type,
      :weight_min_kg, :weight_max_kg,
      :per_kg_rate_cny, :flat_fee_cny,
      :effective_from, :effective_to
    )
  end

  def require_owner!
    redirect_to(shipping_rate_cards_path, alert: t("companies.no_permission")) unless current_membership&.owner?
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

`AdminController::PERMISSION_KEY_MAP` gains `"shipping_rate_cards" => "shopify_stores"` so anyone with shopify_stores access can VIEW the page; mutating actions (create / update / destroy) are gated to owner inside the controller.

## UI

### Shop detail page additions

Below the existing "Cost FX rate" section, owner-only block for service type:

```
Default shipping service type
Used when estimating shipping cost for orders from this store.
[ standard_with_battery ▾ ]   (dropdown filled from rate cards' distinct service_types)  [ Save ]
```

Non-owners see the chosen service as read-only text.

### Shipping rate cards page (`/shipping_rate_cards`)

Single page combining: filter at top, **new-row form** that posts to `create`, and a table where each existing row is **inline-editable cell by cell**.

```
Shipping Rate Cards

Filter:  Country [All ▾]    Service [All ▾]

┌──────────────────────────────────────── New rate card (owner only) ───────────────────────────────┐
│ Country: [US____]  Service: [standard_with_battery_]                                              │
│ Weight: [0.05_] kg – [0.200] kg    ¥/kg: [92.00]   ¥/pkg: [25.00]                                 │
│ Effective from: [2025-12-29]    Until: [          ] (blank = current)            [+ Add row]      │
└────────────────────────────────────────────────────────────────────────────────────────────────────┘

┌──────────┬──────────────────────────┬─────────┬─────────┬───────┬───────┬─────────────┬─────────────┬───┐
│ Country  │ Service                  │ Min kg  │ Max kg  │ ¥/kg  │ ¥/pkg │ From        │ Until       │   │
├──────────┼──────────────────────────┼─────────┼─────────┼───────┼───────┼─────────────┼─────────────┼───┤
│ [US]     │ [standard_with_battery]  │ [0.05]  │ [0.200] │ [92]  │ [25]  │ [2025-12-29]│ [—]         │ 🗑 │
│ [US]     │ [standard_with_battery]  │ [0.201] │ [0.450] │ [92]  │ [23]  │ [2025-12-29]│ [—]         │ 🗑 │
│ ...                                                                                                       │
└──────────┴──────────────────────────┴─────────┴─────────┴───────┴───────┴─────────────┴─────────────┴───┘
                                              ← Prev    Next →   Per page [50 ▾]
```

Every existing cell uses the **`cell_edit_controller.js` pattern** introduced in PR #136 (text default → click to swap to input → blur or Enter saves via PATCH that returns a Turbo Stream replacing the row → Escape cancels). The controller is extended to support three input types:

- `number` (existing) — for weight_min/max, per_kg, flat_fee
- `text` — for country_code, service_type
- `date` — for effective_from, effective_to (blank input means null)

All edits go to `PATCH /shipping_rate_cards/:id` with one field at a time, same as `/product_variants/:id`.

The new-row form is a regular `form_with` POSTing to `create`, visible only to owners. Non-owners see the table read-only, no new-row form, no delete buttons.

### Dashboard cards

Add to the existing grid:

| Card | Value | Notes |
|---|---|---|
| **Shipping Cost** | `number_to_currency(@metrics[:current][:shipping_cost])` | new; invert color (higher = worse) |
| **Net Profit** | revised: `revenue − cogs − shipping_cost − ad_spend` | already exists; formula change |
| **Net Margin** | revised: `net_profit / revenue * 100` | already exists; formula change |

Coverage indicator below grid (extend existing `cogs_coverage` line):

```
COGS coverage: 92.3%   ·   Shipping coverage: 86.5%
```

`shipping_coverage_pct` = `count(orders with shipping_cost) / count(orders in range)`.

## Dashboard service extension

`DashboardMetricsService.aggregate_metrics` adds:

```ruby
shipping_cost, shipping_coverage = aggregate_shipping(store_scope, range)
net_profit = revenue - cogs - shipping_cost - ad_spend

{
  # existing keys...
  shipping_cost:         shipping_cost,
  shipping_coverage_pct: shipping_coverage,
  net_profit:            net_profit,
  net_margin_pct:        revenue > 0 ? (net_profit / revenue * 100).round(2) : nil
}

def aggregate_shipping(store_scope, range)
  total = BigDecimal("0")
  count_total = 0
  count_covered = 0

  store_scope.find_each do |store|
    tz = store.active_timezone
    start_utc = tz.local(range.first.year, range.first.month, range.first.day).utc
    end_utc   = tz.local(range.last.year,  range.last.month,  range.last.day).end_of_day.utc

    orders = Order.where(shopify_store_id: store.id, ordered_at: start_utc..end_utc)
    total          += orders.sum("COALESCE(shipping_cost, 0)")
    count_total    += orders.count
    count_covered  += orders.where.not(shipping_cost: nil).count
  end

  coverage = count_total > 0 ? (count_covered.to_f / count_total * 100).round(1) : nil
  [ total, coverage ]
end
```

## I18n keys (en / zh-TW / zh-CN)

```yaml
shipping_rate_cards:
  title: "Shipping Rate Cards"
  filter_country: "Country"
  filter_service: "Service"
  filter_all: "All"
  new_row_title: "New rate card"
  add_row: "+ Add row"
  created: "Rate card added"
  updated: "Rate card updated"
  deleted: "Rate card deleted"
  empty: "No rate cards yet — add the first row above"
  columns:
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

Admins enter rate cards one row at a time through the new-row form, then click to edit existing cells.

- `country_code`: uppercase ISO-3166-1 alpha-2 (`US`, `CA`, `GB`)
- `service_type`: admin-defined string; reuse the same string across rows that share a service (the form's `service_type` input could autosuggest from existing rows in a later iteration)
- `flat_fee_cny`: defaults to 0
- `effective_to`: blank means "still current" — when rates change, edit the previous row to set its `effective_to`, then add the new rows

Typical workflow for a rate update:

1. Filter to the country + service being updated
2. Edit each existing row's `effective_to` to the day before the new rates kick in
3. Use the new-row form to add new rows for the new effective period

## Testing

### Model specs
- `shipping_rate_card_spec.rb`:
  - presence / numericality validations
  - `weight_max > weight_min`
  - `effective_to >= effective_from` (when both present)
  - `effective_on` scope
  - `.lookup` returns the matching card; returns most recent on ties
  - `.lookup` returns nil when weight outside all bands

### Service specs
- `shipping_cost_calculator_spec.rb`:
  - happy path: USD store, 0.3 kg US order → looks up correct band → returns CNY/fx_rate value
  - missing variant weights → nil
  - missing country in shipping_address → falls back to billing_address; else nil
  - missing rate card → nil
  - store missing `default_service_type` → nil
  - store missing `cost_fx_rate` → nil
- `sync_all_orders_service_spec.rb` extend:
  - syncs an order with weighted variants + rate card → orders.shipping_cost set
  - re-sync does not overwrite existing shipping_cost
- `backfill_order_line_items_service_spec.rb` extend:
  - backfill fills shipping_cost when null; counts returned

### Request specs
- `shipping_rate_cards_spec.rb`:
  - GET /shipping_rate_cards — 200, filters work
  - POST /shipping_rate_cards (owner) — creates
  - POST /shipping_rate_cards (non-owner) — 302 + alert, nothing created
  - PATCH /shipping_rate_cards/:id (owner) — updates single field, returns Turbo Stream
  - PATCH /shipping_rate_cards/:id (non-owner) — alert, nothing updated
  - DELETE /shipping_rate_cards/:id (owner) — gone
  - DELETE /shipping_rate_cards/:id (non-owner) — alert
  - Cross-company guard: trying to PATCH another company's card → 404
- `shopify_stores_spec.rb` extend:
  - PATCH default_service_type (owner) — updates
  - PATCH default_service_type (non-owner) — blocked

### System spec
- `shipping_rate_cards_spec.rb` system: visit page, fill new-row form, see row added; click a cell on the new row, change value, blur, see updated value

### Dashboard spec
- `dashboard_metrics_service_spec.rb` extend:
  - `:shipping_cost` aggregates orders.shipping_cost over range
  - `:net_profit` = revenue - cogs - shipping - ad_spend
  - `:shipping_coverage_pct` correct

## Architecture summary

```
Admin (owner)
  │
  ├── GET   /shipping_rate_cards         (table + new-row form, filters)
  ├── POST  /shipping_rate_cards         (create from new-row form)
  ├── PATCH /shipping_rate_cards/:id     (inline cell edit → Turbo Stream replace row)
  ├── DELETE /shipping_rate_cards/:id    (per-row delete)
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
       │         ├─ ShippingRateCard.lookup → per_kg + flat
       │         ├─ cost CNY / store.cost_fx_rate → store currency
       │         └─ orders.shipping_cost (frozen)
       └─ sync_fulfillments   (existing)

Backfill (BackfillOrderLineItemsService)
  └─ for each order: also runs sync_shipping_cost equivalent

DashboardMetricsService (existing, extended)
  └─ aggregate_metrics
       ├─ existing cogs / gross_profit
       ├─ shipping_cost = SUM(orders.shipping_cost in range)            ← NEW
       ├─ net_profit    = revenue - cogs - shipping_cost - ad_spend     ← FORMULA CHANGE
       └─ shipping_coverage_pct = orders_with_shipping / total_orders   ← NEW
```

## Out of scope

- Per-product / per-variant service-type override (only store-level today)
- Multi-zone rate cards (column exists in some logistics tables; not modeled here)
- "Minimum chargeable weight" (`最低計費重`) and "weight rounding step" (`進位制`) from the logistics spreadsheets — assume `weight_kg` is used as-is and bands are `min < W ≤ max`
- Source attribution for ad spend per order (UTM / source_name) — stays aggregate
- Bulk CSV import — admins use the new-row form (or Rails console for initial seed)
- Currency for rate cards other than CNY

## Rollout / operator steps

1. Deploy migrations
2. Owner: visit a shop detail page → set `default_service_type` (e.g., `standard_with_battery`)
3. Owner: visit `/shipping_rate_cards` → fill new-row form for each weight band (1 country × 1 service × N bands)
4. New orders auto-snapshot `shipping_cost` from now on
5. In Rails console: `BackfillOrderLineItemsService.new(store).call` — also fills historical `shipping_cost`
6. Dashboard shipping coverage % approaches 100% as historical orders get backfilled

For initial seeding of many rows, admin can also use Rails console to bulk-create — the UI is the primary path but Ruby remains available for first-time setup if rate tables are large.

## Estimated work

| Section | Effort |
|---|---|
| Migrations + model + spec | 30 min |
| Calculator service + spec | 30 min |
| Sync integration + spec | 20 min |
| Backfill extension + spec | 15 min |
| Controller (CRUD) + routes + i18n | 40 min |
| Index page UI: new-row form + table | 45 min |
| Cell edit controller extension (text + date input types) | 30 min |
| Shop detail page service-type form | 20 min |
| Dashboard service extension + cards + spec | 30 min |
| System spec for new-row + cell edit | 30 min |
| Total | **~5 hours** |

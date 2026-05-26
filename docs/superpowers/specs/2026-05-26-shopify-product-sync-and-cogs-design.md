# Shopify Product Sync + Editable COGS / Weight — Design

**Date**: 2026-05-26
**Status**: Draft for review
**Branch**: `feature/product-sync-and-cogs-design`

## Goal

Sync Shopify products at the shop dimension so admins can:

1. Edit a **cost of goods sold (COGS)** value per SKU in our backend.
2. Edit a **weight in grams** per SKU in our backend.
3. See gross-profit / net-profit metrics on the dashboard.
4. Compute per-order profit using a snapshotted unit cost (locked at sale time).

## Decisions captured during brainstorming

| Decision | Choice |
|---|---|
| COGS use case | Dashboard 毛利指標 + 訂單利潤計算 |
| Historical cost behavior | Snapshot `unit_cost` onto order line items at sync time. Once frozen, never overwritten. |
| Product sync trigger | Manual button on shop detail page. No recurring job, no webhook. |
| Sync data scope | Product (title/handle/status/image) + Variant (sku/title/price/inventory_item_id/weight/Shopify cost) + our own editable `unit_cost` and `weight_grams`. |
| Existing orders | Backfill is a console-run service (`BackfillOrderLineItemsService.new(store).call`). No UI button. |
| UI editing | Per-page selector (25/50/100/200/300/500). Store dropdown when multiple stores. Inline "always-edit" inputs that auto-save on blur. Bulk update across filtered selection. |
| Dashboard COGS rollup | On-the-fly aggregation from `order_line_items`, no new column on `shopify_daily_metrics`. |

## Schema

Three new tables, all UUID PK (per existing project convention).

### `products`

```ruby
create_table :products, id: :uuid do |t|
  t.uuid     :shopify_store_id, null: false
  t.bigint   :shopify_product_id, null: false
  t.string   :title
  t.string   :handle
  t.string   :status                          # active / draft / archived
  t.string   :image_url
  t.jsonb    :shopify_data, default: {}
  t.timestamps
  t.index [:shopify_store_id, :shopify_product_id], unique: true
  t.index :shopify_store_id
end
add_foreign_key :products, :shopify_stores
```

### `product_variants`

```ruby
create_table :product_variants, id: :uuid do |t|
  t.uuid     :product_id, null: false
  t.bigint   :shopify_variant_id, null: false
  t.bigint   :shopify_inventory_item_id
  t.string   :sku
  t.string   :title
  t.decimal  :price, precision: 10, scale: 2
  t.string   :currency
  t.decimal  :shopify_cost,         precision: 10, scale: 2     # read-only from Shopify
  t.decimal  :unit_cost,            precision: 10, scale: 2     # editable COGS
  t.decimal  :shopify_weight_grams, precision: 12, scale: 3     # read-only from Shopify
  t.decimal  :weight_grams,         precision: 12, scale: 3     # editable
  t.jsonb    :shopify_data, default: {}
  t.timestamps
  t.index [:product_id, :shopify_variant_id], unique: true
  t.index :sku
  t.index :shopify_inventory_item_id
end
add_foreign_key :product_variants, :products
```

### `order_line_items`

```ruby
create_table :order_line_items, id: :uuid do |t|
  t.uuid     :order_id, null: false
  t.uuid     :product_variant_id                            # nullable; SKU may not match
  t.bigint   :shopify_line_item_id, null: false
  t.string   :sku_at_sale
  t.string   :title_at_sale
  t.integer  :quantity, null: false
  t.decimal  :unit_price,          precision: 10, scale: 2
  t.decimal  :unit_cost_snapshot,  precision: 10, scale: 2  # FROZEN once set
  t.string   :currency
  t.jsonb    :shopify_data, default: {}
  t.timestamps
  t.index [:order_id, :shopify_line_item_id], unique: true
  t.index :product_variant_id
end
add_foreign_key :order_line_items, :orders
add_foreign_key :order_line_items, :product_variants
```

### `shopify_stores` additions

```ruby
add_column :shopify_stores, :products_synced_at, :datetime
add_column :shopify_stores, :currency, :string  # populated during product sync from /shop.json
```

### Performance index (for dashboard COGS aggregation)

```ruby
add_index :orders, [:shopify_store_id, :ordered_at]  # if absent
```

## Models

```ruby
class ShopifyStore
  has_many :products, dependent: :destroy
end

class Product < ApplicationRecord
  belongs_to :shopify_store
  has_many   :product_variants, dependent: :destroy
  validates :shopify_product_id, presence: true
end

class ProductVariant < ApplicationRecord
  belongs_to :product
  has_one    :shopify_store, through: :product
  has_many   :order_line_items, dependent: :nullify
  validates :shopify_variant_id, presence: true
  validates :unit_cost,    numericality: { greater_than_or_equal_to: 0, allow_nil: true }
  validates :weight_grams, numericality: { greater_than: 0,            allow_nil: true }
end

class OrderLineItem < ApplicationRecord
  belongs_to :order
  belongs_to :product_variant, optional: true
  validates :shopify_line_item_id, presence: true
  validates :quantity, presence: true, numericality: { greater_than: 0 }
end

class Order
  has_many :order_line_items, dependent: :destroy

  def cogs_total
    order_line_items.sum("quantity * COALESCE(unit_cost_snapshot, 0)")
  end

  def gross_profit
    return nil unless total_price
    total_price - cogs_total
  end

  def gross_margin_pct
    return nil unless total_price && total_price.positive?
    (gross_profit / total_price * 100).round(2)
  end

  def cogs_complete?
    !order_line_items.where(unit_cost_snapshot: nil).exists?
  end
end
```

### Why `unit_cost_snapshot` and `unit_cost` are separate

- `product_variants.unit_cost` — current COGS, edited via the admin UI.
- `order_line_items.unit_cost_snapshot` — frozen at the moment the line item is first written. Future edits to `unit_cost` never touch historical orders.
- Dashboard gross profit uses `SUM(quantity * unit_cost_snapshot)`.

### Why `sku_at_sale` / `title_at_sale` are stored

Shopify lets merchants rename SKUs and variant titles. Storing the string at sale time preserves historical truth.

## Shopify API additions (`ShopifyService`)

```ruby
def fetch_all_products(limit: 250, since_id: nil)
  params = { limit: limit, order: "id asc" }
  params[:since_id] = since_id if since_id
  response = get("/products.json", **params)
  response["products"] || []
end

# Shopify cap: max 100 inventory_item ids per call
def fetch_inventory_items(ids:)
  return [] if ids.empty?
  response = get("/inventory_items.json", ids: ids.join(","))
  response["inventory_items"] || []
end

def fetch_shop
  response = get("/shop.json")
  response["shop"] || {}
end
```

Variant payloads from `/products.json` already include `grams`, so weight does not require a second call. **Cost is not on the variant**; it lives on `inventory_items.cost` and must be fetched separately.

## Services

### `SyncShopifyProductsService` (new)

```ruby
class SyncShopifyProductsService
  INVENTORY_BATCH = 100

  def initialize(shopify_store)
    @store = shopify_store
    @shopify = ShopifyService.new(shopify_store)
    @synced_products = 0
    @synced_variants = 0
  end

  def call
    sync_started_at = Time.current
    update_store_currency
    sync_all_products
    apply_inventory_costs
    @store.update!(products_synced_at: sync_started_at)
    { products: @synced_products, variants: @synced_variants }
  end

  private

  def update_store_currency
    shop = @shopify.fetch_shop
    @store.update!(currency: shop["currency"]) if shop["currency"].present?
  end

  def sync_all_products
    since_id = nil
    loop do
      batch = @shopify.fetch_all_products(since_id: since_id)
      break if batch.empty?
      batch.each { |sp| upsert_product(sp) }
      since_id = batch.last["id"]
      break if batch.size < 250
    end
  end

  def upsert_product(sp)
    product = @store.products.find_or_initialize_by(shopify_product_id: sp["id"])
    product.assign_attributes(
      title: sp["title"], handle: sp["handle"], status: sp["status"],
      image_url: sp.dig("image", "src"), shopify_data: sp
    )
    product.save!
    @synced_products += 1

    (sp["variants"] || []).each { |sv| upsert_variant(product, sv) }
  end

  def upsert_variant(product, sv)
    variant = product.product_variants.find_or_initialize_by(shopify_variant_id: sv["id"])
    # NEVER overwrite admin-edited unit_cost / weight_grams
    variant.assign_attributes(
      shopify_inventory_item_id: sv["inventory_item_id"],
      sku: sv["sku"], title: sv["title"],
      price: sv["price"], currency: @store.currency,
      shopify_weight_grams: sv["grams"], shopify_data: sv
    )
    variant.save!
    @synced_variants += 1
  end

  def apply_inventory_costs
    variants = ProductVariant.joins(:product)
                             .where(products: { shopify_store_id: @store.id })
                             .where.not(shopify_inventory_item_id: nil)
    variants.pluck(:shopify_inventory_item_id).uniq.each_slice(INVENTORY_BATCH) do |ids|
      @shopify.fetch_inventory_items(ids: ids).each do |item|
        ProductVariant.where(shopify_inventory_item_id: item["id"])
                      .update_all(shopify_cost: item["cost"])
      end
    end
  end
end
```

### `SyncAllOrdersService` modification

Within `sync_order`, after the existing `save!` and before `sync_fulfillments`, call `sync_line_items(order, shopify_order)`:

```ruby
def sync_line_items(order, shopify_order)
  (shopify_order["line_items"] || []).each do |li|
    variant = variant_lookup[li["variant_id"]]

    line_item = order.order_line_items.find_or_initialize_by(shopify_line_item_id: li["id"])
    line_item.assign_attributes(
      product_variant: variant,
      sku_at_sale:   li["sku"],
      title_at_sale: li["title"],
      quantity:      li["quantity"],
      unit_price:    li["price"],
      currency:      shopify_order["currency"],
      shopify_data:  li
    )

    # Fill snapshot only when still null. NEVER overwrite frozen snapshots.
    if line_item.unit_cost_snapshot.nil? && variant&.unit_cost.present?
      line_item.unit_cost_snapshot = variant.unit_cost
    end

    line_item.save!
  end
end

def variant_lookup
  @variant_lookup ||= ProductVariant.joins(:product)
                                    .where(products: { shopify_store_id: @store.id })
                                    .index_by(&:shopify_variant_id)
end
```

### `BackfillOrderLineItemsService` (new, console-run)

```ruby
class BackfillOrderLineItemsService
  def initialize(shopify_store)
    @store = shopify_store
    @processed = 0
    @snapshotted = 0
  end

  def call
    @store.orders.find_each(batch_size: 200) do |order|
      (order.shopify_data&.dig("line_items") || []).each { |li| upsert_line_item(order, li) }
      @processed += 1
    end
    { orders: @processed, snapshotted: @snapshotted }
  end

  private

  def upsert_line_item(order, li)
    variant = variant_lookup[li["variant_id"]]
    line_item = order.order_line_items.find_or_initialize_by(shopify_line_item_id: li["id"])
    line_item.assign_attributes(
      product_variant: variant,
      sku_at_sale: li["sku"], title_at_sale: li["title"],
      quantity: li["quantity"], unit_price: li["price"],
      currency: order.currency, shopify_data: li
    )
    if line_item.unit_cost_snapshot.nil? && variant&.unit_cost.present?
      line_item.unit_cost_snapshot = variant.unit_cost
      @snapshotted += 1
    end
    line_item.save!
  end

  def variant_lookup
    @variant_lookup ||= ProductVariant.joins(:product)
                                      .where(products: { shopify_store_id: @store.id })
                                      .index_by(&:shopify_variant_id)
  end
end
```

**Workflow**:

1. Admin clicks "Sync products" on a store → products + variants are created (`unit_cost` null).
2. Admin edits `unit_cost` (and `weight_grams`) per SKU in `/products` UI.
3. Admin runs `BackfillOrderLineItemsService.new(ShopifyStore.find(id)).call` in console — this expands existing orders' line items and snapshots the current `unit_cost` for any line item whose snapshot is still null.
4. Future order syncs auto-snapshot on creation.

Backfill is **idempotent and re-runnable**. Snapshots are never overwritten.

## Jobs

```ruby
# app/jobs/sync_shopify_products_job.rb
class SyncShopifyProductsJob < ApplicationJob
  queue_as :default
  def perform(shopify_store_id)
    SyncShopifyProductsService.new(ShopifyStore.find(shopify_store_id)).call
  end
end
```

(No backfill job — invoked from Rails console.)

## Routes

```ruby
resources :shopify_stores, only: [:index, :show, :update, :destroy] do
  member do
    post :sync_products
  end
end

resources :products, only: [:index]

resources :product_variants, only: [:update] do
  collection do
    post :bulk_update
    get  :matching_ids
  end
end
```

## Controllers

### `ShopifyStoresController#sync_products`

```ruby
before_action :set_shopify_store, only: [:show, :update, :destroy, :sync_products]

def sync_products
  SyncShopifyProductsJob.perform_later(@shopify_store.id)
  redirect_to shopify_store_path(@shopify_store),
              notice: t("shopify_stores.sync_products_enqueued")
end
```

### `ProductsController#index`

```ruby
class ProductsController < AdminController
  PER_PAGE_DEFAULT = 50
  PER_PAGE_OPTIONS = [25, 50, 100, 200, 300, 500].freeze

  def index
    @search = params[:search].presence
    @page   = [params[:page].to_i, 1].max

    per_page = Integer(params[:per_page], exception: false)
    @per_page = PER_PAGE_OPTIONS.include?(per_page) ? per_page : PER_PAGE_DEFAULT

    @shopify_store = current_shopify_store || visible_shopify_stores.first
    return redirect_to(shopify_stores_path, alert: t("products.no_store")) unless @shopify_store

    variants = filtered_variants
    @total_count = variants.count
    @total_pages = (@total_count.to_f / @per_page).ceil
    @page = [@page, @total_pages].min if @total_pages > 0

    @variants = variants.order("products.title ASC, product_variants.title ASC")
                        .offset((@page - 1) * @per_page).limit(@per_page)
  end

  private

  def filtered_variants
    scope = ProductVariant.joins(:product)
                          .where(products: { shopify_store_id: @shopify_store.id })
                          .includes(:product)
    return scope unless @search
    q = "%#{ActiveRecord::Base.sanitize_sql_like(@search)}%"
    scope.where(
      "product_variants.sku ILIKE :q OR product_variants.title ILIKE :q OR products.title ILIKE :q",
      q: q
    )
  end
end
```

### `ProductVariantsController`

```ruby
class ProductVariantsController < AdminController
  before_action :set_variant, only: :update

  def update
    if @variant.update(variant_params)
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            helpers.dom_id(@variant),
            partial: "product_variants/row", locals: { variant: @variant }
          )
        end
        format.html { redirect_to products_path, notice: t("product_variants.updated") }
      end
    else
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            helpers.dom_id(@variant),
            partial: "product_variants/row", locals: { variant: @variant }
          ), status: :unprocessable_entity
        end
        format.html { redirect_to products_path, alert: @variant.errors.full_messages.join(", ") }
      end
    end
  end

  def bulk_update
    ids = Array(params[:variant_ids]).map(&:to_s)
    return redirect_to(products_path, alert: t("product_variants.bulk_no_selection")) if ids.empty?

    updates = {}
    updates[:unit_cost]    = params[:unit_cost]    if params[:unit_cost].to_s.strip.present?
    updates[:weight_grams] = params[:weight_grams] if params[:weight_grams].to_s.strip.present?
    return redirect_to(products_path, alert: t("product_variants.bulk_no_fields")) if updates.empty?

    scope = scoped_variants.where(id: ids)
    count = 0
    ProductVariant.transaction do
      scope.find_each do |v|
        v.assign_attributes(updates)
        v.save!
        count += 1
      end
    end
    redirect_to products_path(request.query_parameters.slice(:store_id, :search, :per_page, :page)),
                notice: t("product_variants.bulk_updated", count: count)
  rescue ActiveRecord::RecordInvalid => e
    redirect_to products_path, alert: e.record.errors.full_messages.join(", ")
  end

  def matching_ids
    store = visible_shopify_stores.find_by(id: params[:store_id]) || visible_shopify_stores.first
    return render(json: { ids: [] }) unless store

    scope = ProductVariant.joins(:product).where(products: { shopify_store_id: store.id })
    if params[:search].present?
      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(params[:search])}%"
      scope = scope.where(
        "product_variants.sku ILIKE :q OR product_variants.title ILIKE :q OR products.title ILIKE :q",
        q: pattern
      )
    end
    render json: { ids: scope.pluck(:id) }
  end

  private

  def scoped_variants
    store_ids = visible_shopify_stores.pluck(:id)
    ProductVariant.joins(:product).where(products: { shopify_store_id: store_ids })
  end

  def set_variant
    @variant = scoped_variants.find(params[:id])
  end

  def variant_params
    params.require(:product_variant).permit(:unit_cost, :weight_grams)
  end
end
```

**Authorization**: every query is scoped through `visible_shopify_stores`, preventing cross-company access.

## UI

### Shop detail page additions

A new section on `shopify_stores/show.html.erb`:

```
Products
Last synced: 2026-05-26 14:30
[ Sync products ]   [ Manage products & costs → ]
```

### Products index (`/products`)

```
┌─────────────────────────────────────────────────────────────────────────┐
│ Search: [______________]   Store: [shop.myshopify.com ▾]   Per-page: 50 ▾ │
└─────────────────────────────────────────────────────────────────────────┘

(visible only when ≥1 row selected)
┌─────────────────────────────────────────────────────────────────────────┐
│ 3 selected   [Select all 1,234 matching]   [Clear selection]            │
│ Set COGS:   [______]    Set weight (g): [______]    [ Apply to selected]│
└─────────────────────────────────────────────────────────────────────────┘

┌─┬──────┬──────────────┬──────────────┬───────┬─────────┬──────────┬────────┬─────────┬────────┐
│☐│ Img  │ Product      │ Variant      │ SKU   │ Price   │ Shop $   │ OurCOGS│ Shop g  │ Our g  │
├─┼──────┼──────────────┼──────────────┼───────┼─────────┼──────────┼────────┼─────────┼────────┤
│☑│ [📷] │ Paint Kit A  │ Black/Large  │ PK-BL │ $29.00  │ $12.50   │[12.50] │ 450 g   │ [450]  │
│☐│ [📷] │ Paint Kit A  │ Black/Small  │ PK-BS │ $24.00  │ $10.00   │[_____] │ 320 g   │ [____] │
└─┴──────┴──────────────┴──────────────┴───────┴─────────┴──────────┴────────┴─────────┴────────┘
                                                        [ ← Prev ]  [ Next → ]
```

### Editable cells

Each row is its own Turbo Frame. `unit_cost` and `weight_grams` are always-edit inputs. A Stimulus `auto-submit` controller submits the form on blur. On 422, the row partial re-renders with errors.

```js
// app/javascript/controllers/auto_submit_controller.js
import { Controller } from "@hotwired/stimulus"
export default class extends Controller {
  submit() { this.element.requestSubmit() }
}
```

### Bulk selection

A Stimulus `bulk-select` controller manages:
- Per-row checkbox state, header "select all on page" toggle.
- "Select all N matching" → `fetch(matching_ids_product_variants_path?store_id=…&search=…)` → injects hidden `variant_ids[]` inputs.
- Shows/hides the bulk action bar based on selection count.

The bulk form wraps the table and posts to `bulk_update_product_variants_path`.

### Store dropdown (only when `visible_shopify_stores.count > 1`)

Selects via `params[:store_id]`, reusing the existing `current_shopify_store` helper that already reads this param.

### Per-page selector

Mirrors `app/views/shipments/index.html.erb:744-755`. Options: 25 / 50 / 100 / 200 / 300 / 500. Default 50.

## Dashboard integration

### `DashboardMetricsService` extension

Compute COGS on the fly. For each store in scope, query `OrderLineItem` joined to `Order`, filter by `ordered_at` within the store's local-tz range, aggregate `SUM(quantity * COALESCE(unit_cost_snapshot, 0))`.

```ruby
def aggregate_cogs(store_scope, range)
  total_cogs = BigDecimal("0")
  total_lines = 0
  covered_lines = 0

  store_scope.find_each do |store|
    tz = store.active_timezone
    start_utc = tz.local(range.first.year, range.first.month, range.first.day).utc
    end_utc   = tz.local(range.last.year,  range.last.month,  range.last.day).end_of_day.utc

    line_items = OrderLineItem.joins(:order)
                              .where(orders: { shopify_store_id: store.id,
                                               ordered_at: start_utc..end_utc })

    total_cogs    += line_items.sum("quantity * COALESCE(unit_cost_snapshot, 0)")
    total_lines   += line_items.count
    covered_lines += line_items.where.not(unit_cost_snapshot: nil).count
  end

  coverage = total_lines > 0 ? (covered_lines.to_f / total_lines * 100).round(1) : nil
  [total_cogs, coverage]
end
```

New keys returned by `aggregate_metrics`:

| Key | Definition |
|---|---|
| `cogs` | Sum of `quantity * unit_cost_snapshot` across the range |
| `gross_profit` | `revenue - cogs` |
| `gross_margin_pct` | `gross_profit / revenue * 100` |
| `net_profit` | `gross_profit - ad_spend` |
| `net_margin_pct` | `net_profit / revenue * 100` |
| `cogs_coverage_pct` | Percent of line items with a non-null snapshot |

### Dashboard UI

Three new cards: Gross Profit, Net Profit, and a small COGS coverage indicator. Coverage < 100% nudges the admin to fill missing SKU costs (linking back to `/products` is a follow-up, not required for this design).

## Testing strategy

WebMock stubs Shopify HTTP. FactoryBot. No mocks for ActiveRecord. Target 95%+ coverage per CLAUDE.md.

### Model specs

- `product_spec.rb`: presence, associations.
- `product_variant_spec.rb`: presence, `unit_cost >= 0`, `weight_grams > 0`, associations.
- `order_line_item_spec.rb`: presence, `quantity > 0`, optional `product_variant`.
- `order_spec.rb` (extend): `#cogs_total`, `#gross_profit`, `#gross_margin_pct`, `#cogs_complete?`.

### Service specs

- `sync_shopify_products_service_spec.rb`:
  - Stub `/products.json` (two pages) and `/inventory_items.json` (one batch).
  - Verify products / variants created; `shopify_cost` populated; idempotent re-run does not duplicate; **`unit_cost` and `weight_grams` survive resync**.
- `sync_all_orders_service_spec.rb` (extend):
  - Order with line items → `OrderLineItem` rows created with correct `unit_cost_snapshot`.
  - Variant missing → `product_variant_id` is null but row still saved.
  - Re-sync the same order → snapshots are not overwritten.
- `backfill_order_line_items_service_spec.rb` (new):
  - Seed order with `shopify_data["line_items"]` → backfill expands to `OrderLineItem`.
  - Snapshot = current `unit_cost` when variant exists.
  - Re-running does not duplicate or overwrite.
- `dashboard_metrics_service_spec.rb` (extend):
  - Compute `cogs`, `gross_profit`, `net_profit`, `coverage` across multiple stores and timezones.

### Request specs

- `products_spec.rb`: scoped to own company; pagination, per-page, search.
- `product_variants_spec.rb`:
  - `PATCH /product_variants/:id` updates `unit_cost` / `weight_grams`; cross-company 404.
  - `POST /product_variants/bulk_update` with ids + values; missing fields → alert; cross-company ids silently filtered.
  - `GET /product_variants/matching_ids` returns only the current store's ids.
- `shopify_stores_spec.rb` (extend): `POST /shopify_stores/:id/sync_products` enqueues `SyncShopifyProductsJob`.

### System specs

- `products_spec.rb` (new):
  - Edit a cell, blur, see the row update.
  - Multi-select, fill bulk cost, apply, see updates.
  - "Select all matching", apply, all affected.
  - Change store dropdown → list re-scopes.
  - Change per-page → row count changes.

### Job spec

- `sync_shopify_products_job_spec.rb` — service invocation.

## Architecture summary

```
Admin
  │
  ├── POST /shopify_stores/:id/sync_products
  │       └─ SyncShopifyProductsJob → SyncShopifyProductsService
  │            ├─ ShopifyService.fetch_shop          (currency)
  │            ├─ ShopifyService.fetch_all_products  (Products + Variants upsert)
  │            └─ ShopifyService.fetch_inventory_items (shopify_cost backfill)
  │
  ├── GET /products
  │       └─ ProductsController#index (filtered/paginated variants for current store)
  │
  ├── PATCH /product_variants/:id        (inline edit)
  ├── POST /product_variants/bulk_update (bulk edit, scoped)
  └── GET /product_variants/matching_ids (full-filter id set for "select all matching")

SyncAllOrdersService (existing, modified)
  └─ sync_order
       └─ sync_line_items → OrderLineItem with unit_cost_snapshot (frozen)

BackfillOrderLineItemsService (console-run, idempotent)
  └─ Expand orders.shopify_data["line_items"] into OrderLineItem rows; snapshot current unit_cost

DashboardMetricsService (modified)
  └─ aggregate_cogs (per-store TZ-aware) → adds gross_profit / net_profit / coverage
```

## Out of scope

- Webhook-driven product updates.
- Recurring product sync.
- Multi-currency cost handling.
- Writing edited `unit_cost` back to Shopify's `inventory_items`.
- Linking back from dashboard coverage indicator to filtered products UI.
- Per-order profit display in `/orders` index list (only on `/orders/:id` show via `#gross_profit`).
- Bulk delete / archive of products.

## Migration / rollout notes

1. Migrations run against `staging` first, verify schema diff.
2. After deploy, admin manually triggers product sync per store.
3. Admin fills SKU costs and weights via `/products`.
4. Run `BackfillOrderLineItemsService.new(store).call` per store in console (one-off).
5. Dashboard gross / net profit appears as coverage approaches 100%.
